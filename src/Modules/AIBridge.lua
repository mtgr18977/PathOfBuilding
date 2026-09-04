-- Path of Building
--
-- Module: AIBridge
-- Runs the AI assistant: owns the MCP server subscript, drives the `claude` child process,
-- and dispatches tool calls against the live build.
--
-- Everything here runs in the main Lua state, on the UI thread. Two rules follow from that:
--
--  1. Never block. Tool calls are queued and serviced from main.onFrameFuncs, a slice per
--     frame, so a multi-second simulation cannot drop the frame rate.
--  2. Answers to the MCP server go out as files. A subscript can call in here (that is how
--     tool calls and `claude` output arrive) but cannot receive a return value -- established
--     by the Phase 0 spike, and the reason the spool directory exists at all.

local dkjson = require("dkjson")

local AIBridge = {}

AIBridge.status = "stopped"        -- stopped | starting | ready | failed
AIBridge.statusMessage = nil
AIBridge.port = nil
AIBridge.busy = false              -- a claude turn is in flight
AIBridge.sessionId = nil           -- for --resume, so the chat keeps its context
AIBridge.model = "claude-opus-5"

local SERVER_NAME = "path-of-building"
local SERVER_VERSION = "0.1.0"
local FRAME_BUDGET_MS = 8          -- leave the rest of a 16ms frame to the app

local queue = {}                   -- pending tool calls, FIFO
local listeners = {}               -- event sinks (the Assistant tab subscribes)
local aiPath, spoolPath, sessionPath

--------------------------------------------------------------------------- utilities

local function toWindowsPath(path)
	return (path:gsub("/", "\\"))
end

local function writeFile(path, text)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(text)
	f:close()
	return true
end

local function emit(event)
	for _, fn in ipairs(listeners) do
		local errMsg = PCall(fn, event)
		if errMsg then
			ConPrintf("[AIBridge] listener error: %s", errMsg)
		end
	end
end

--- Subscribe to assistant events. The tab uses this to render the transcript.
--- Event kinds: status, text, tool_use, tool_result, propose, result, error.
function AIBridge:Subscribe(fn)
	table.insert(listeners, fn)
end

--- Pending one-click changes offered by the assistant. Holding them here rather than applying
--- them directly is the whole safety model: the assistant can propose anything, and nothing
--- reaches the build without the user pressing Apply.
AIBridge.proposals = {}

function AIBridge:AddProposal(proposal)
	table.insert(self.proposals, proposal)
	emit({ kind = "propose", proposal = proposal })
end

function AIBridge:RemoveProposal(proposal)
	for index, candidate in ipairs(self.proposals) do
		if candidate == proposal then
			table.remove(self.proposals, index)
			return
		end
	end
end

function AIBridge:ClearProposals()
	self.proposals = {}
end

local function setStatus(status, message)
	AIBridge.status = status
	AIBridge.statusMessage = message
	emit({ kind = "status", status = status, message = message })
end

--------------------------------------------------------------------------- tool results

-- The MCP server splices this straight into the JSON-RPC envelope, so what lands here is the
-- `result` object of a tools/call: a content array plus an error flag.
local function publishResult(reqId, ok, payload)
	local text
	if type(payload) == "string" then
		text = payload
	else
		text = dkjson.encode(payload, { indent = false })
	end
	local result = {
		content = { { type = "text", text = text } },
		isError = not ok,
	}
	local body = dkjson.encode(result, { indent = false })
	local tmp = spoolPath .. "/resp_" .. reqId .. ".tmp"
	local final = spoolPath .. "/resp_" .. reqId .. ".json"
	-- Rename into place so the server can never observe a half-written file.
	if writeFile(tmp, body) then
		os.remove(final)
		os.rename(tmp, final)
	end
end

--------------------------------------------------------------------------- queue

--- Serviced once per frame. Runs whole handlers when they are cheap, and steps coroutines
--- when they are not, so a long simulation spreads across frames instead of stalling one.
local function processQueue()
	if #queue == 0 then return end
	local deadline = GetTime() + FRAME_BUDGET_MS
	while #queue > 0 and GetTime() < deadline do
		local job = queue[1]

		if not job.started then
			job.started = true
			local handler = AITools.handlers[job.name]
			if not handler then
				publishResult(job.reqId, false, "Unknown tool: " .. tostring(job.name))
				table.remove(queue, 1)
				goto continue
			end
			local args = dkjson.decode(job.argsJson or "{}") or {}
			job.args = args
			emit({ kind = "tool_use", name = job.name, args = args })
			-- A handler may return a coroutine to be stepped across frames.
			local errMsg, a, b = PCall(handler, args)
			if errMsg then
				publishResult(job.reqId, false, "Tool error: " .. tostring(errMsg))
				emit({ kind = "tool_result", name = job.name, ok = false, summary = tostring(errMsg) })
				table.remove(queue, 1)
				goto continue
			end
			if type(a) == "thread" then
				job.co = a
			else
				publishResult(job.reqId, a ~= false, b)
				emit({ kind = "tool_result", name = job.name, ok = a ~= false, summary = b })
				table.remove(queue, 1)
				goto continue
			end
		end

		if job.co then
			local alive, a, b = coroutine.resume(job.co)
			if not alive then
				publishResult(job.reqId, false, "Tool error: " .. tostring(a))
				emit({ kind = "tool_result", name = job.name, ok = false, summary = tostring(a) })
				table.remove(queue, 1)
			elseif coroutine.status(job.co) == "dead" then
				publishResult(job.reqId, a ~= false, b)
				emit({ kind = "tool_result", name = job.name, ok = a ~= false, summary = b })
				table.remove(queue, 1)
			else
				-- still working; yield the frame back to the app
				break
			end
		end

		::continue::
	end
end

--------------------------------------------------------------------------- claude output

local function handleClaudeEvent(evt)
	local kind = evt.type

	if kind == "system" and evt.subtype == "init" then
		AIBridge.sessionId = evt.session_id
		emit({ kind = "session", sessionId = evt.session_id, tools = evt.tools })

		-- If the MCP server did not attach, the model has no way to see the build -- and it
		-- will answer anyway, inventing a class, a level and a full stat block that look
		-- entirely plausible. That happened during development and is far worse than an
		-- error, so refuse the turn rather than let a fabricated answer through.
		local connected = false
		for _, name in ipairs(evt.tools or {}) do
			if name:find("^mcp__pob__") then connected = true break end
		end
		if not connected then
			emit({ kind = "error", text =
				"The assistant could not reach Path of Building's tools, so it cannot see " ..
				"your build. Stopping rather than answering from guesswork." })
			AIBridge:Abort()
		end

	elseif kind == "assistant" and evt.message and evt.message.content then
		for _, block in ipairs(evt.message.content) do
			if block.type == "text" and block.text and block.text ~= "" then
				emit({ kind = "text", text = block.text })
			end
		end

	elseif kind == "result" then
		AIBridge.busy = false
		AIBridge.sessionId = evt.session_id or AIBridge.sessionId
		emit({
			kind = "result",
			ok = not evt.is_error,
			durationMs = evt.duration_ms,
			turns = evt.num_turns,
			costUSD = evt.total_cost_usd,
			text = evt.result,
		})

	elseif kind == "rate_limit_event" then
		local info = evt.rate_limit_info or {}
		if info.status and info.status ~= "allowed" then
			emit({ kind = "error", text = "Rate limit: " .. tostring(info.status) })
		end
	end
end

--------------------------------------------------------------------------- doorbells
-- Globals, because launch:OnSubCall dispatches through _G.

--- Called by the MCP server subscript once it has a port.
function PoBAI_ServerReady(port)
	AIBridge.port = port
	local config = dkjson.encode({
		mcpServers = {
			pob = { type = "http", url = "http://127.0.0.1:" .. port .. "/mcp" },
		},
	}, { indent = true })
	writeFile(aiPath .. "/pob-mcp.json", config)
	setStatus("ready", "MCP server on 127.0.0.1:" .. port)
end

--- Called by the MCP server subscript for every tools/call.
function PoBAI_ToolCall(reqId, name, argsJson)
	table.insert(queue, { reqId = reqId, name = name, argsJson = argsJson })
end

--- Called by the `claude` subscript for each NDJSON line on stdout.
function PoBAI_ClaudeLine(line)
	if not line or line == "" then return end
	local evt = dkjson.decode(line)
	if type(evt) ~= "table" then
		-- Not JSON: claude writes plain text to stderr on startup failures, and that is
		-- exactly the case where swallowing the line would leave the user staring at nothing.
		emit({ kind = "error", text = line })
		return
	end
	local errMsg = PCall(handleClaudeEvent, evt)
	if errMsg then
		ConPrintf("[AIBridge] event handler error: %s", errMsg)
	end
end

--------------------------------------------------------------------------- lifecycle

function AIBridge:Init()
	aiPath = main.userPath .. "AI"
	spoolPath = aiPath .. "/spool"
	sessionPath = aiPath .. "/session"
	MakeDir(aiPath)
	MakeDir(spoolPath)
	MakeDir(sessionPath)
	main.onFrameFuncs["AIBridge"] = function()
		local errMsg = PCall(processQueue)
		if errMsg then
			ConPrintf("[AIBridge] queue error: %s", errMsg)
		end
	end
end

function AIBridge:Start()
	if self.status == "ready" or self.status == "starting" then return end
	setStatus("starting")

	writeFile(aiPath .. "/persona.md", AITools.persona)

	local toolsJson = dkjson.encode(AITools:BuildSchemas(), { indent = false })
	local f = io.open(GetScriptPath() .. "/AIServer.lua", "r")
	if not f then
		setStatus("failed", "AIServer.lua not found")
		return
	end
	local serverSource = f:read("*a")
	f:close()

	self.serverSub = LaunchSubScript(serverSource,
		"",                                        -- funcList (host natives)
		"ConPrintf,PoBAI_ServerReady,PoBAI_ToolCall",
		spoolPath, toolsJson, SERVER_NAME, SERVER_VERSION)
	if not self.serverSub then
		setStatus("failed", "could not launch the MCP server subscript")
		return
	end
	launch:RegisterSubScript(self.serverSub, function(_, errMsg)
		-- The serve loop only ends on abort or failure.
		if errMsg then
			setStatus("failed", tostring(errMsg))
		else
			setStatus("stopped")
		end
		AIBridge.serverSub = nil
	end)
end

function AIBridge:Stop()
	if self.claudeSub then AbortSubScript(self.claudeSub) self.claudeSub = nil end
	if self.serverSub then AbortSubScript(self.serverSub) self.serverSub = nil end
	self.busy = false
	self.port = nil
	setStatus("stopped")
end

--- Cancel the turn in flight, leaving the server up.
function AIBridge:Abort()
	if self.claudeSub then
		AbortSubScript(self.claudeSub)
		self.claudeSub = nil
	end
	self.busy = false
	emit({ kind = "aborted" })
end

--------------------------------------------------------------------------- sending

--- Ask the assistant something about the open build.
function AIBridge:Send(userText)
	if self.status ~= "ready" then
		emit({ kind = "error", text = "Assistant is not ready (" .. tostring(self.status) .. ")" })
		return false
	end
	if self.busy then
		emit({ kind = "error", text = "A response is already in progress" })
		return false
	end

	local promptFile = aiPath .. "/prompt.txt"
	if not writeFile(promptFile, userText) then
		emit({ kind = "error", text = "Could not write the prompt file" })
		return false
	end

	local allowed = {}
	for _, schema in ipairs(AITools:BuildSchemas()) do
		table.insert(allowed, "mcp__pob__" .. schema.name)
	end

	-- Measured against the naive invocation during Phase 0: these flags take the exposed tool
	-- surface from 90 tools to exactly ours, and cut a turn and ~14x the cost off every call.
	local blocked = "ToolSearch,Bash,PowerShell,Write,Edit,Read,Glob,Grep,WebFetch,WebSearch," ..
		"Task,NotebookEdit,Skill,SendMessage,Monitor,CronCreate,CronDelete,CronList," ..
		"TaskCreate,TaskGet,TaskList,TaskOutput,TaskStop,TaskUpdate,DesignSync," ..
		"EnterWorktree,ExitWorktree,PushNotification,RemoteTrigger,ReportFindings,ScheduleWakeup"

	local parts = {
		'type "' .. toWindowsPath(promptFile) .. '"',
		'| claude -p',
		'--output-format stream-json --verbose',
		'--model ' .. self.model,
		'--mcp-config "' .. toWindowsPath(aiPath .. "/pob-mcp.json") .. '"',
		'--strict-mcp-config',
		-- Trailing '=' rather than a separate "" argument: cmd passes an empty quoted token
		-- through literally, and claude rejects it as an invalid setting source, which kills
		-- the whole run (including the MCP connection).
		'--setting-sources=',
		'--system-prompt-file "' .. toWindowsPath(aiPath .. "/persona.md") .. '"',
		'--allowedTools "' .. table.concat(allowed, ",") .. '"',
		'--disallowedTools "' .. blocked .. '"',
	}
	if self.sessionId then
		table.insert(parts, '--resume ' .. self.sessionId)
	end
	local command = table.concat(parts, " ") .. " 2>&1"

	local runner = [[
		local command, workDir = ...
		local f = io.popen('cd /d "' .. workDir .. '" && ' .. command, "r")
		if not f then return "POPEN_FAILED" end
		for line in f:lines() do
			PoBAI_ClaudeLine(line)
		end
		f:close()
		return "DONE"
	]]

	self.busy = true
	emit({ kind = "user", text = userText })
	self.claudeSub = LaunchSubScript(runner, "", "ConPrintf,PoBAI_ClaudeLine",
		command, toWindowsPath(sessionPath))
	if not self.claudeSub then
		self.busy = false
		emit({ kind = "error", text = "Could not launch the claude subscript" })
		return false
	end
	launch:RegisterSubScript(self.claudeSub, function(status)
		AIBridge.claudeSub = nil
		AIBridge.busy = false
		if status == "POPEN_FAILED" then
			emit({ kind = "error", text = "Could not run `claude`. Is Claude Code installed and on PATH?" })
		end
		emit({ kind = "turn_finished" })
	end)
	return true
end

return AIBridge
