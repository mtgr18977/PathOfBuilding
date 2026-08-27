-- TEMPORARY dev harness: end-to-end smoke test for the AI assistant, driven without a human.
-- Enabled by setting POB_AI_SPIKE=1; writes a transcript to POB_AI_SPIKE_OUT.
-- Not part of the feature. Delete before merge.
--
-- There is no luajit or Docker on this machine, so the busted suite cannot run locally. This
-- harness is the substitute: it drives the real subscripts, the real MCP server and the real
-- `claude` binary against a real build, with the Assistant tab actually rendering each frame,
-- and leaves a file behind saying what happened.

local dkjson = require("dkjson")

local out = {}
local resultPath = os.getenv("POB_AI_SPIKE_OUT") or "ai-spike-result.txt"
local startedAt = GetTime()
local TIMEOUT_MS = 240000

local function flush()
	local f = io.open(resultPath, "w")
	if f then
		f:write(table.concat(out, "\n"), "\n")
		f:close()
	end
end

-- Flush on every line: a harness that only writes once everything succeeds tells you nothing
-- about the run that hung, which is the run you most need to see.
local function emit(fmt, ...)
	local line = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
	table.insert(out, line)
	ConPrintf("[AISMOKE] %s", line)
	flush()
end

local function shorten(text, limit)
	if type(text) == "table" then text = dkjson.encode(text, { indent = false }) end
	text = tostring(text):gsub("%s+", " ")
	if #text > limit then return text:sub(1, limit) .. "..." end
	return text
end

emit("=== AI assistant smoke test ===")

local phase = "boot"
local finished = false
local toolsCalled = {}
local lifeBefore, allocBefore

local function finish(ok, reason)
	if reason then emit(reason) end
	emit("=== END (%s) ===", ok and "passed" or "failed")
	finished = true
end

local function countAllocated(build)
	local count = 0
	for _ in pairs(build.spec.allocNodes) do count = count + 1 end
	return count
end

AIBridge:Subscribe(function(event)
	if event.kind == "status" then
		emit("[status] %s%s", event.status, event.message and (" - " .. event.message) or "")
	elseif event.kind == "session" then
		emit("[session] id=%s tools=%d", tostring(event.sessionId), #(event.tools or {}))
	elseif event.kind == "user" then
		emit("[user] %s", shorten(event.text, 300))
	elseif event.kind == "tool_use" then
		toolsCalled[event.name] = true
		emit("[tool_use] %s %s", event.name, shorten(event.args or {}, 220))
	elseif event.kind == "tool_result" then
		emit("[tool_result] %s ok=%s -> %s", event.name, tostring(event.ok), shorten(event.summary, 500))
	elseif event.kind == "text" then
		emit("[assistant] %s", shorten(event.text, 700))
	elseif event.kind == "propose" then
		emit("[propose] %s (%s pts) - %s", event.proposal.title,
			tostring(event.proposal.pointCost), shorten(event.proposal.summary, 200))
	elseif event.kind == "error" then
		emit("[error] %s", shorten(event.text, 500))
	elseif event.kind == "result" then
		emit("[result] ok=%s turns=%s duration=%sms cost=%s",
			tostring(event.ok), tostring(event.turns), tostring(event.durationMs), tostring(event.costUSD))
		phase = "verify"
	end
end)

main.onFrameFuncs["AISmoke"] = function()
	if finished then
		main.onFrameFuncs["AISmoke"] = nil
		return
	end

	-- Any Lua error inside a tab's Draw surfaces here. Catching it explicitly is the point of
	-- rendering the tab during the test rather than only exercising the bridge.
	if launch.promptMsg then
		finish(false, "RUNTIME ERROR: " .. tostring(launch.promptMsg))
		main.onFrameFuncs["AISmoke"] = nil
		return
	end

	if GetTime() - startedAt > TIMEOUT_MS then
		finish(false, string.format("FAIL: timed out in phase '%s'", phase))
		main.onFrameFuncs["AISmoke"] = nil
		return
	end

	if phase == "boot" then
		-- Wait for the item DBs; opening a build before they land throws.
		if not main.onFrameFuncs["LoadItems"] then
			emit("item DBs loaded, opening a build")
			main:SetMode("BUILD", false, "AI smoke test")
			phase = "opening"
		end

	elseif phase == "opening" then
		if main.mode == "BUILD" and main.modes["BUILD"].spec then
			local build = main.modes["BUILD"]
			-- Render the Assistant tab for the rest of the run, so its Draw path is under test.
			build.viewMode = "ASSISTANT"
			emit("build open: class=%s level=%s, Assistant tab active",
				tostring(build.spec.curClassName), tostring(build.characterLevel))
			AIBridge:Start()
			phase = "starting"
		end

	elseif phase == "starting" then
		if AIBridge.status == "ready" then
			local build = main.modes["BUILD"]
			emit("server ready on port %s; life before = %s",
				tostring(AIBridge.port), tostring(build.calcsTab.mainOutput.Life))
			AIBridge:Send("Find the cheapest passive that raises maximum life on this build. " ..
				"Measure it, then offer it with pob_propose so I can apply it.")
			phase = "waiting"
		elseif AIBridge.status == "failed" then
			finish(false, "FAIL: server did not start: " .. tostring(AIBridge.statusMessage))
		end

	elseif phase == "verify" then
		phase = "verifying"
		local build = main.modes["BUILD"]
		local missing = {}
		for _, required in ipairs({ "pob_get_build", "pob_search_tree", "pob_propose" }) do
			if not toolsCalled[required] then table.insert(missing, required) end
		end
		if not (toolsCalled["pob_simulate"] or toolsCalled["pob_simulate_batch"]) then
			table.insert(missing, "pob_simulate(_batch)")
		end
		if #missing > 0 then
			finish(false, "ASSERT FAILED: never called " .. table.concat(missing, ", ") ..
				" - the answer cannot be trusted")
			return
		end
		if #AIBridge.proposals == 0 then
			finish(false, "ASSERT FAILED: no proposal reached the UI")
			return
		end

		-- Exercise the Apply path: the only place the assistant can change the real build.
		local proposal = AIBridge.proposals[1]
		lifeBefore = build.calcsTab.mainOutput.Life
		allocBefore = countAllocated(build)
		emit("applying proposal %q (%s pts); life=%s allocated=%d",
			proposal.title, tostring(proposal.pointCost), tostring(lifeBefore), allocBefore)
		AITools.ApplyProposal(build, proposal)
		phase = "applied"

	elseif phase == "applied" then
		-- Recalculation lands on the frame after buildFlag is set.
		local build = main.modes["BUILD"]
		if not build.buildFlag then
			local lifeAfter = build.calcsTab.mainOutput.Life
			local allocAfter = countAllocated(build)
			emit("after apply: life=%s allocated=%d", tostring(lifeAfter), allocAfter)
			if allocAfter <= allocBefore then
				finish(false, "ASSERT FAILED: apply did not allocate any node")
			elseif lifeAfter <= lifeBefore then
				finish(false, string.format("ASSERT FAILED: life did not increase (%s -> %s)",
					tostring(lifeBefore), tostring(lifeAfter)))
			else
				emit("apply verified: life %s -> %s, +%d nodes",
					tostring(lifeBefore), tostring(lifeAfter), allocAfter - allocBefore)
				finish(true)
			end
		end
	end
end
