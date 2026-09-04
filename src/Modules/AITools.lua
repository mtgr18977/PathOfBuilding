-- Path of Building
--
-- Module: AITools
-- The tools the assistant can call against the open build, and their MCP schemas.
--
-- Design rule: answers are compact. The passive tree alone is 2.8MB of Lua (~700k tokens), so
-- nothing here dumps bulk data -- the assistant narrows down with searches and asks for detail.
--
-- A handler returns either
--     ok, payload            -- answered immediately
--     coroutine              -- stepped across frames by AIBridge, finally returning ok, payload
-- `payload` is JSON-encoded for the model, so keep keys short and values already rounded.

local AITools = {}

AITools.handlers = {}

local m_min = math.min
local m_max = math.max
local m_floor = math.floor

--------------------------------------------------------------------------- persona

AITools.persona = [[
You are the build assistant built into Path of Building (PoB), the Path of Exile build planner.
You are talking to the user about the build they currently have open.

You reach that build only through the `pob_*` tools. You have no filesystem, no shell and no web
access. Reply in whatever language the user writes in.

How to work:

- Never state a numeric gain you have not measured. `pob_simulate` runs the real PoB calculation
  engine against a throwaway copy of the build, so measuring is cheap and changes nothing. A
  guessed number is worse than no number, because the user cannot tell the two apart.
- Never invent a passive name. Find it with `pob_search_tree` and use the id it returns.
- A typical answer: `pob_get_build` to see where things stand, `pob_search_tree` to find
  candidates, then one `pob_simulate_batch` to measure several at once. Batch rather than
  simulating one at a time.
- Lead with the answer. Give a few concrete options rather than an essay, and for each one state
  the point cost and the measured stat change.
- Watch for trade-offs the user did not ask about: a path that caps resistances but costs 300
  life is worth saying out loud.
- When the user pastes an item and asks whether it is worth it, do not eyeball the mods: send
  the pasted text to `pob_simulate` as `item`. That equips it on a throwaway copy and tells you
  what actually moves, which is usually not what the mod list suggests. To compare several
  candidates, or the same item across different slots, batch them.
- Say plainly when something is outside what you can simulate. Gem swaps and configuration
  changes are, today; passive nodes, items and flasks are not. Item swaps can be measured but
  not applied for the user -- `pob_propose` only carries passive tree changes, so tell them to
  make the swap themselves.
- The user can see the build. Do not recite stats back at them unless the number is the point.
]]

--------------------------------------------------------------------------- helpers

--- dkjson encodes an empty Lua table as `[]`. JSON Schema requires `properties` to be an
--- object, and a schema with `"properties": []` is rejected outright -- the tool silently
--- vanishes from the model's tool list, which looks exactly like "the server never connected".
--- Tagging the table makes dkjson emit `{}`.
local function jsonObject(tbl)
	return setmetatable(tbl or {}, { __jsontype = "object" })
end
AITools.jsonObject = jsonObject

--- PoB embeds colour codes in display strings: "^7" (palette index) and "^xRRGGBB" (literal).
--- Both have to go before text reaches the model.
local function stripColors(text)
	if type(text) ~= "string" then return text end
	return (text:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
end
AITools.stripColors = stripColors

local function round(value)
	if type(value) ~= "number" then return value end
	if value ~= value or value == math.huge or value == -math.huge then return 0 end
	return m_floor(value * 100 + 0.5) / 100
end

--- The open build, or nil plus a message suitable for handing straight back to the model.
local function currentBuild()
	if main.mode ~= "BUILD" then
		return nil, "No build is open in Path of Building right now."
	end
	local build = main.modes["BUILD"]
	if not build or not build.spec then
		return nil, "No build is open in Path of Building right now."
	end
	return build
end
AITools.currentBuild = currentBuild

--- Wraps a handler so every tool gets the build (or a clean error) without repeating the check.
local function withBuild(fn)
	return function(args)
		local build, errMsg = currentBuild()
		if not build then return false, errMsg end
		return fn(build, args or {})
	end
end

--- Nodes reachable only through unallocated ones get pathDist 1000; treat that as "no path".
local UNREACHABLE = 1000

local function nodeKind(node)
	if node.isKeystone or node.type == "Keystone" then return "keystone" end
	if node.isNotable or node.type == "Notable" then return "notable" end
	if node.isJewelSocket or node.type == "Socket" then return "socket" end
	if node.isMastery or node.type == "Mastery" then return "mastery" end
	return "normal"
end

--- Nodes the assistant has no business suggesting: other classes' ascendancies, proxies,
--- and the structural start nodes.
local function isSuggestable(spec, node)
	if not node.dn or node.dn == "" then return false end
	if node.type == "ClassStart" or node.type == "AscendClassStart" then return false end
	if node.ascendancyName and node.ascendancyName ~= spec.curAscendClassName then return false end
	return true
end

--------------------------------------------------------------------------- stat diffing

--- Snapshot of every numeric stat PoB is willing to display, keyed by its display label.
local function statSnapshot(build, output)
	local snap = {}
	for _, statData in ipairs(build.displayStats) do
		if statData.stat and statData.label then
			local value = output[statData.stat]
			if value ~= nil and statData.childStat then
				value = value[statData.childStat]
			end
			if type(value) == "number" then
				snap[statData.label] = value
			end
		end
	end
	return snap
end

--- Only what actually moved. PoB's own comparison ignores deltas under 0.001 for the same
--- reason: floating-point noise reads as a real change to anyone (or anything) skimming.
local function statDiff(before, after)
	local changes = {}
	for label, afterValue in pairs(after) do
		local beforeValue = before[label]
		if beforeValue and math.abs(afterValue - beforeValue) > 0.001 then
			table.insert(changes, {
				stat = label,
				before = round(beforeValue),
				after = round(afterValue),
				delta = round(afterValue - beforeValue),
			})
		end
	end
	table.sort(changes, function(a, b)
		return math.abs(a.delta) > math.abs(b.delta)
	end)
	return changes
end

--------------------------------------------------------------------------- change resolution

--- Turns a list of node ids into the set calcFunc wants, pulling in each node's path so the
--- reported cost is what the user would actually pay, not just the target node.
local function expandNodes(spec, ids, includePath)
	local set, unknown, cost = {}, {}, 0
	for _, rawId in ipairs(ids or {}) do
		local node = spec.nodes[tonumber(rawId)]
		if not node then
			table.insert(unknown, rawId)
		else
			local chain = (includePath ~= false and node.path and #node.path > 0) and node.path or { node }
			for _, step in ipairs(chain) do
				if not set[step] then
					set[step] = true
					if not step.alloc then cost = cost + 1 end
				end
			end
		end
	end
	return set, unknown, cost
end

--- Builds the calcFunc override for one candidate change, plus a human-readable cost.
local function buildOverride(build, change)
	local spec = build.spec
	local override, notes = {}, {}
	local cost = 0

	if change.add_nodes and #change.add_nodes > 0 then
		local set, unknown, addCost = expandNodes(spec, change.add_nodes, change.include_path)
		if #unknown > 0 then
			return nil, "Unknown node ids: " .. table.concat(unknown, ", ") ..
				". Use pob_search_tree to get valid ids."
		end
		override.addNodes = set
		cost = cost + addCost
	end

	if change.remove_nodes and #change.remove_nodes > 0 then
		local set, unknown = {}, {}
		for _, rawId in ipairs(change.remove_nodes) do
			local node = spec.nodes[tonumber(rawId)]
			if not node then
				table.insert(unknown, rawId)
			else
				set[node] = true
				if node.alloc then cost = cost - 1 end
			end
		end
		if #unknown > 0 then
			return nil, "Unknown node ids: " .. table.concat(unknown, ", ")
		end
		override.removeNodes = set
	end

	if change.toggle_flask then
		local slot = build.itemsTab.slots[change.toggle_flask]
		if not slot then
			return nil, "Unknown flask slot: " .. tostring(change.toggle_flask)
		end
		override.toggleFlask = build.itemsTab.items[slot.selItemId]
		table.insert(notes, "toggled " .. change.toggle_flask)
	end

	if change.item and change.item ~= "" then
		-- The calculation engine already knows how to stand one item in for another
		-- (CalcSetup's repSlotName/repItem), including clearing Weapon 2 when a two-hander
		-- goes into Weapon 1. All we add is parsing the text the user pasted.
		local itemsTab = build.itemsTab
		local item = new("Item"):Item(change.item)
		if not item.base then
			return nil, "Could not parse that item text. Paste the whole block copied from " ..
				"the game, starting at 'Item Class:' or the rarity line."
		end
		item:NormaliseQuality()
		item:BuildModList()

		-- GetPrimarySlot is what the items UI uses to pick a default home for an item.
		local slotName = change.slot or item:GetPrimarySlot()
		local slot = itemsTab.slots[slotName]
		if not slot then
			return nil, "Unknown slot: " .. tostring(slotName)
		end
		if not itemsTab:IsItemValidForSlot(item, slotName) then
			return nil, ("A %s cannot go in %s."):format(tostring(item.type), slotName)
		end

		override.repSlotName = slotName
		override.repItem = item
		local current = itemsTab.items[slot.selItemId]
		table.insert(notes, ("%s into %s (replacing %s)"):format(
			item.name or item.baseName or "item", slotName,
			current and (current.name or current.baseName) or "an empty slot"))
	end

	if not override.addNodes and not override.removeNodes and not override.toggleFlask
			and not override.repItem then
		return nil, "Nothing to simulate: supply add_nodes, remove_nodes, toggle_flask or item."
	end

	return override, nil, cost, notes
end

--------------------------------------------------------------------------- schemas

local schemas = {
	{
		name = "pob_ping",
		description = "Health check for the link between Path of Building and this assistant. " ..
			"Returns the PoB version and whether a build is open. Only worth calling if you " ..
			"suspect the connection is broken.",
		inputSchema = { type = "object", properties = jsonObject(), required = {} },
	},
	{
		name = "pob_get_build",
		description = "Overview of the build currently open: class, ascendancy, level, passive " ..
			"points used and available, the main skill, and the stat panel exactly as the user " ..
			"sees it (life, energy shield, resistances, DPS, EHP and so on). Start here for " ..
			"almost any question about the build.",
		inputSchema = { type = "object", properties = jsonObject(), required = {} },
	},
	{
		name = "pob_search_tree",
		description = "Search the passive tree by name or by the text of the modifiers a node " ..
			"grants -- for example 'resistance', 'maximum life', 'attack speed'. Returns each " ..
			"match with its node id, what it grants, and `cost`: how many NEW passive points " ..
			"reaching it would take from where the build stands now (0 means already " ..
			"allocated). This is the only way to get valid node ids; never guess one.",
		inputSchema = {
			type = "object",
			properties = jsonObject({
				query = { type = "string", description = "Words that must all appear in the node name or its modifiers." },
				kind = { type = "string", enum = { "any", "notable", "keystone", "normal" }, description = "Restrict to a node kind. Default 'any'." },
				max_cost = { type = "integer", description = "Only nodes reachable within this many new passive points." },
				only_unallocated = { type = "boolean", description = "Skip nodes the build already has. Default false." },
				limit = { type = "integer", description = "Maximum results, default 15, cap 40." },
			}),
			required = { "query" },
		},
	},
	{
		name = "pob_path_to_node",
		description = "The cheapest route from the build's current allocation to a given node: " ..
			"which passives would be taken along the way and how many new points that costs.",
		inputSchema = {
			type = "object",
			properties = jsonObject({
				node_id = { type = "integer", description = "Node id from pob_search_tree." },
			}),
			required = { "node_id" },
		},
	},
	{
		name = "pob_get_tree",
		description = "What the build has already allocated in the passive tree: every notable " ..
			"and keystone by name, plus counts. Use it to see what the build is already " ..
			"committed to before suggesting more.",
		inputSchema = { type = "object", properties = jsonObject(), required = {} },
	},
	{
		name = "pob_get_items",
		description = "Equipped items and their modifiers. Returns every slot by default; pass " ..
			"a slot name to narrow it down.",
		inputSchema = {
			type = "object",
			properties = jsonObject({
				slot = { type = "string", description = "For example 'Ring 1', 'Body Armour', 'Amulet'." },
			}),
			required = {},
		},
	},
	{
		name = "pob_get_skills",
		description = "The build's socket groups: which gems are linked together, their level " ..
			"and quality, and which group drives the main skill.",
		inputSchema = { type = "object", properties = jsonObject(), required = {} },
	},
	{
		name = "pob_simulate",
		description = "Measure what a change would do, WITHOUT touching the user's build. Runs " ..
			"the real Path of Building calculation engine on a throwaway copy and returns every " ..
			"stat that moved, plus the passive point cost. Adding a node automatically includes " ..
			"the path to reach it. This is how you get real numbers -- use it before claiming any " ..
			"gain. When the user pastes an item and asks whether it is an upgrade, pass that text " ..
			"as 'item': that measures the swap against their current gear.",
		inputSchema = {
			type = "object",
			properties = jsonObject({
				add_nodes = { type = "array", items = { type = "integer" }, description = "Node ids to allocate." },
				remove_nodes = { type = "array", items = { type = "integer" }, description = "Node ids to unallocate." },
				include_path = { type = "boolean", description = "Include the path to each added node. Default true; set false to price the node alone." },
				toggle_flask = { type = "string", description = "Flask slot to flip, e.g. 'Flask 1'." },
				item = { type = "string", description = "Raw item text, exactly as copied from the game or pasted by the user (the whole block, starting at 'Item Class:' or the rarity line). Measures equipping it in place of what is worn now. This is how you price a weapon or any other piece of gear the user is asking about." },
				slot = { type = "string", description = "Slot for 'item', e.g. 'Weapon 1', 'Ring 2'. Defaults to the item's natural slot, so only set it to disambiguate rings, or to test an off-hand." },
			}),
			required = {},
		},
	},
	{
		name = "pob_simulate_batch",
		description = "Measure several alternative changes in one call and get them back " ..
			"side by side. Strongly preferred over repeated pob_simulate calls when comparing " ..
			"options: one round trip, one shared baseline, and the results are directly " ..
			"comparable. Up to 10 variants.",
		inputSchema = {
			type = "object",
			properties = jsonObject({
				variants = {
					type = "array",
					description = "Each entry takes the same fields as pob_simulate, plus a short 'label'.",
					items = {
						type = "object",
						properties = jsonObject({
							label = { type = "string" },
							add_nodes = { type = "array", items = { type = "integer" } },
							remove_nodes = { type = "array", items = { type = "integer" } },
							include_path = { type = "boolean" },
							toggle_flask = { type = "string" },
							item = { type = "string", description = "Raw item text to equip for this variant." },
							slot = { type = "string", description = "Slot for 'item'; defaults to the item's natural slot." },
						}),
					},
				},
				stats = {
					type = "array",
					items = { type = "string" },
					description = "Only report these stat labels, exactly as PoB names them, e.g. ['Total Life','Fire Resistance','Hit DPS']. A label that does not exist is reported back rather than silently dropped. Omit for everything that changed.",
				},
			}),
			required = { "variants" },
		},
	},
}

table.insert(schemas, {
	name = "pob_propose",
	description = "Offer the user a concrete tree change they can apply with one click. This " ..
		"does NOT modify the build -- it puts a card in the assistant panel with an Apply " ..
		"button, and the user decides. Simulate first and quote the measured numbers in the " ..
		"summary; a proposal the user cannot check is worse than none. Send one call per " ..
		"option you are recommending.",
	inputSchema = {
		type = "object",
		properties = jsonObject({
			title = { type = "string", description = "Short name, e.g. 'Cap resistances via Sanctity'." },
			summary = { type = "string", description = "One or two lines: what it costs and what it measurably gains." },
			add_nodes = { type = "array", items = { type = "integer" }, description = "Node ids to allocate (paths are included automatically)." },
			remove_nodes = { type = "array", items = { type = "integer" }, description = "Node ids to unallocate." },
		}),
		required = { "title", "summary" },
	},
})

--- The MCP tools/list payload. Also the source of the --allowedTools allowlist.
function AITools:BuildSchemas()
	return schemas
end

--------------------------------------------------------------------------- pob_ping

AITools.handlers["pob_ping"] = function()
	local build = currentBuild()
	return true, {
		pob = launch.versionNumber,
		buildOpen = build ~= nil,
		buildName = build and build.buildName or nil,
	}
end

--------------------------------------------------------------------------- pob_get_build

-- The sidebar list is the highest-fidelity summary that exists: PoB has already filtered it by
-- the active skill's flags and formatted every number the way the user is reading it right now.
-- Re-deriving it from mainOutput would mean re-implementing that filtering and drifting from it.
local function sidebarStats(build)
	local stats = {}
	for _, row in ipairs(build.controls.statBox.list or {}) do
		local label, value = row[1], row[2]
		if type(label) == "string" and type(value) == "string" and value ~= "" then
			label = stripColors(label):gsub(":%s*$", "")
			value = stripColors(value)
			if label ~= "" then
				table.insert(stats, { label, value })
			end
		end
	end
	return stats
end

AITools.handlers["pob_get_build"] = withBuild(function(build)
	local spec = build.spec
	local used, ascUsed = spec:CountAllocNodes()
	local extra = (build.calcsTab.mainOutput and build.calcsTab.mainOutput.ExtraPoints) or 0
	local maxPoints = 99 + 23 + extra

	local mainSkill
	local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if group and group.displaySkillList and group.mainActiveSkill then
		local active = group.displaySkillList[group.mainActiveSkill]
		if active and active.activeEffect and active.activeEffect.grantedEffect then
			mainSkill = active.activeEffect.grantedEffect.name
		end
	end

	return true, {
		name = build.buildName,
		class = spec.curClassName,
		ascendancy = spec.curAscendClassName ~= "None" and spec.curAscendClassName or nil,
		level = build.characterLevel,
		treeVersion = spec.treeVersion,
		points = { used = used, max = maxPoints, spare = maxPoints - used, ascUsed = ascUsed },
		mainSkill = mainSkill,
		stats = sidebarStats(build),
	}
end)

--------------------------------------------------------------------------- pob_search_tree

AITools.handlers["pob_search_tree"] = withBuild(function(build, args)
	local query = tostring(args.query or ""):lower()
	local terms = {}
	for word in query:gmatch("[%w%%+%-']+") do
		table.insert(terms, word)
	end
	if #terms == 0 then
		return false, "pob_search_tree needs a 'query', e.g. 'maximum life' or 'fire resistance'."
	end

	local spec = build.spec
	local kind = args.kind or "any"
	local maxCost = tonumber(args.max_cost)
	local limit = m_min(tonumber(args.limit) or 15, 40)
	local results = {}

	for _, node in pairs(spec.nodes) do
		if isSuggestable(spec, node) then
			local thisKind = nodeKind(node)
			if kind == "any" or kind == thisKind then
				if not (args.only_unallocated and node.alloc) then
					local cost = node.alloc and 0 or (node.pathDist or UNREACHABLE)
					if cost < UNREACHABLE and (not maxCost or cost <= maxCost) then
						local haystack = (node.dn .. " " .. table.concat(node.sd or {}, " ")):lower()
						local matched = true
						for _, term in ipairs(terms) do
							if not haystack:find(term, 1, true) then matched = false break end
						end
						if matched then
							table.insert(results, {
								id = node.id,
								name = node.dn,
								kind = thisKind,
								grants = node.sd,
								cost = cost,
								allocated = node.alloc and true or nil,
								ascendancy = node.ascendancyName,
							})
						end
					end
				end
			end
		end
	end

	-- Cheapest first: what the user can actually afford is the more useful half of the answer.
	table.sort(results, function(a, b)
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.name < b.name
	end)

	local total = #results
	while #results > limit do table.remove(results) end
	return true, {
		matches = results,
		shown = #results,
		totalMatches = total,
		note = total > #results and "More matches exist; narrow the query or raise 'limit'." or nil,
	}
end)

--------------------------------------------------------------------------- pob_path_to_node

AITools.handlers["pob_path_to_node"] = withBuild(function(build, args)
	local node = build.spec.nodes[tonumber(args.node_id)]
	if not node then
		return false, "No node with id " .. tostring(args.node_id) .. ". Use pob_search_tree."
	end
	if node.alloc then
		return true, { id = node.id, name = node.dn, cost = 0, alreadyAllocated = true }
	end
	local dist = node.pathDist or UNREACHABLE
	if dist >= UNREACHABLE then
		return true, {
			id = node.id,
			name = node.dn,
			reachable = false,
			note = "Not reachable from the current allocation without changing class or jewels.",
		}
	end
	local steps = {}
	for _, step in ipairs(node.path or {}) do
		if not step.alloc then
			table.insert(steps, { id = step.id, name = step.dn, kind = nodeKind(step) })
		end
	end
	return true, { id = node.id, name = node.dn, cost = dist, newNodes = steps }
end)

--------------------------------------------------------------------------- pob_get_tree

AITools.handlers["pob_get_tree"] = withBuild(function(build)
	local spec = build.spec
	local notables, keystones, ascendancy = {}, {}, {}
	local normalCount, masteryCount = 0, 0

	for _, node in pairs(spec.allocNodes) do
		local kind = nodeKind(node)
		if node.ascendancyName then
			if node.dn and node.type ~= "AscendClassStart" then
				table.insert(ascendancy, node.dn)
			end
		elseif kind == "keystone" then
			table.insert(keystones, node.dn)
		elseif kind == "notable" then
			table.insert(notables, { id = node.id, name = node.dn, grants = node.sd })
		elseif kind == "mastery" then
			masteryCount = masteryCount + 1
		elseif kind == "normal" then
			normalCount = normalCount + 1
		end
	end

	table.sort(keystones)
	table.sort(ascendancy)
	table.sort(notables, function(a, b) return a.name < b.name end)

	local used, ascUsed = spec:CountAllocNodes()
	return true, {
		class = spec.curClassName,
		ascendancy = spec.curAscendClassName ~= "None" and spec.curAscendClassName or nil,
		pointsUsed = used,
		ascendancyPointsUsed = ascUsed,
		keystones = keystones,
		ascendancyNodes = ascendancy,
		notables = notables,
		smallPassives = normalCount,
		masteries = masteryCount,
	}
end)

--------------------------------------------------------------------------- pob_get_items

local function itemSummary(item)
	local mods = {}
	local function collect(lines)
		for _, modLine in ipairs(lines or {}) do
			if modLine.line and not modLine.disabled then
				table.insert(mods, stripColors(modLine.line))
			end
		end
	end
	collect(item.enchantModLines)
	collect(item.implicitModLines)
	collect(item.explicitModLines)
	collect(item.crucibleModLines)
	return {
		name = item.name,
		base = item.baseName,
		rarity = item.rarity,
		itemLevel = item.itemLevel,
		quality = item.quality,
		corrupted = item.corrupted or nil,
		mods = mods,
	}
end

AITools.handlers["pob_get_items"] = withBuild(function(build, args)
	local itemsTab = build.itemsTab
	local wanted = args.slot
	local items, empty = {}, {}

	for _, slot in ipairs(itemsTab.orderedSlots) do
		if not slot.inactive and (not wanted or slot.slotName == wanted) then
			local item = itemsTab.items[slot.selItemId]
			if item then
				local summary = itemSummary(item)
				summary.slot = slot.slotName
				table.insert(items, summary)
			elseif not slot.nodeId then
				-- Jewel sockets are tree nodes, not gear. Listing ~60 empty ones buries the
				-- dozen equipment slots that the question is actually about.
				table.insert(empty, slot.slotName)
			end
		end
	end

	if wanted and #items == 0 and #empty == 0 then
		return false, "No such slot: " .. tostring(wanted)
	end
	return true, { items = items, emptySlots = empty }
end)

--------------------------------------------------------------------------- pob_get_skills

AITools.handlers["pob_get_skills"] = withBuild(function(build)
	local groups = {}
	for index, socketGroup in ipairs(build.skillsTab.socketGroupList) do
		local gems = {}
		for _, gem in ipairs(socketGroup.gemList or {}) do
			local name = (gem.gemData and gem.gemData.name) or gem.nameSpec
			if name and name ~= "" then
				table.insert(gems, {
					name = name,
					level = gem.level,
					quality = gem.quality,
					enabled = gem.enabled ~= false or nil,
				})
			end
		end
		table.insert(groups, {
			index = index,
			label = socketGroup.label ~= "" and socketGroup.label or nil,
			slot = socketGroup.slot,
			enabled = socketGroup.enabled ~= false,
			isMain = index == build.mainSocketGroup or nil,
			gems = gems,
		})
	end
	return true, { socketGroups = groups, mainSocketGroup = build.mainSocketGroup }
end)

--------------------------------------------------------------------------- simulation

--- Runs one candidate change against a throwaway calculation. Nothing here mutates the build:
--- calcFunc builds its own environment from the override and hands back only the output.
local function simulateOne(build, calcFunc, baseline, change, statFilter)
	local override, errMsg, cost, notes = buildOverride(build, change)
	if not override then
		return { label = change.label, error = errMsg }
	end

	local output = calcFunc(override)
	local changes = statDiff(baseline, statSnapshot(build, output))

	local unknownStats
	if statFilter then
		local keep, filtered = {}, {}
		for _, label in ipairs(statFilter) do keep[label] = true end
		for _, entry in ipairs(changes) do
			if keep[entry.stat] then table.insert(filtered, entry) end
		end
		-- A label that matches no stat at all would otherwise come back as an empty result,
		-- which reads exactly like "nothing moved" -- the difference between "no effect" and
		-- "you asked for a stat that does not exist" is the whole answer.
		for _, label in ipairs(statFilter) do
			if baseline[label] == nil then
				unknownStats = unknownStats or {}
				table.insert(unknownStats, label)
			end
		end
		changes = filtered
	end

	-- When the build is in automatic level mode, PoB derives the character level from how many
	-- passive points are spent. Spending points therefore also levels the character, which adds
	-- life and mana that this measurement does not include -- the simulation holds level fixed.
	-- Left unsaid, the user applies a change and sees a bigger number than we promised, which
	-- quietly undermines every number the assistant reports.
	local levelNote
	if cost ~= 0 and build.characterLevelAutoMode then
		levelNote = "This build derives its character level from passive points spent, so " ..
			"applying this will also raise the level and add life/mana beyond the figures " ..
			"above. Tell the user the measured change is the tree's contribution alone."
	end

	return {
		label = change.label,
		pointCost = cost,
		notes = (notes and #notes > 0) and notes or nil,
		levelNote = levelNote,
		unknownStats = unknownStats,
		unknownStatsNote = unknownStats and
			"These are not stat labels this build reports, so they were not filtered on. " ..
			"Drop the 'stats' filter and read the full list rather than concluding nothing moved."
			or nil,
		changed = changes,
	}
end

AITools.handlers["pob_simulate"] = withBuild(function(build, args)
	local calcFunc = build.calcsTab:GetMiscCalculator()
	-- Baseline through calcFunc rather than the cached calcBase, so both sides of the
	-- comparison come out of the same code path and FullDPS is present in both.
	local baseline = statSnapshot(build, calcFunc({}))
	local result = simulateOne(build, calcFunc, baseline, args, args.stats)
	if result.error then return false, result.error end
	return true, result
end)

AITools.handlers["pob_simulate_batch"] = withBuild(function(build, args)
	local variants = args.variants
	if type(variants) ~= "table" or #variants == 0 then
		return false, "pob_simulate_batch needs a non-empty 'variants' array."
	end
	if #variants > 10 then
		return false, "At most 10 variants per call; you sent " .. #variants .. "."
	end

	-- A batch is several full calculation passes, which can run into seconds. Returning a
	-- coroutine lets AIBridge spend a slice of each frame on it so the UI keeps drawing.
	return coroutine.create(function()
		local calcFunc = build.calcsTab:GetMiscCalculator()
		local baseline = statSnapshot(build, calcFunc({}))
		coroutine.yield()

		local results = {}
		for index, variant in ipairs(variants) do
			variant.label = variant.label or ("variant " .. index)
			table.insert(results, simulateOne(build, calcFunc, baseline, variant, args.stats))
			coroutine.yield()
		end
		return true, { results = results }
	end)
end)

--------------------------------------------------------------------------- pob_propose

AITools.handlers["pob_propose"] = withBuild(function(build, args)
	if type(args.title) ~= "string" or args.title == "" then
		return false, "pob_propose needs a 'title'."
	end
	local spec = build.spec

	-- Resolve now rather than at Apply time: a proposal that turns out to reference a
	-- nonexistent node should fail here, where the model can still correct itself, not later
	-- under the user's cursor.
	local addNodes, removeNodes = {}, {}
	for _, rawId in ipairs(args.add_nodes or {}) do
		local node = spec.nodes[tonumber(rawId)]
		if not node then return false, "Unknown node id: " .. tostring(rawId) end
		table.insert(addNodes, node.id)
	end
	for _, rawId in ipairs(args.remove_nodes or {}) do
		local node = spec.nodes[tonumber(rawId)]
		if not node then return false, "Unknown node id: " .. tostring(rawId) end
		table.insert(removeNodes, node.id)
	end
	if #addNodes == 0 and #removeNodes == 0 then
		return false, "A proposal needs at least one node to add or remove."
	end

	local _, _, cost = expandNodes(spec, addNodes, true)
	local proposal = {
		title = args.title,
		summary = args.summary or "",
		addNodes = addNodes,
		removeNodes = removeNodes,
		pointCost = cost,
	}
	AIBridge:AddProposal(proposal)
	return true, {
		accepted = true,
		pointCost = cost,
		note = "Shown to the user with an Apply button. Do not assume it was applied.",
	}
end)

--- Applies an accepted proposal to the real build. Goes through the same calls the tree UI
--- uses, so the change lands in the undo history and Ctrl+Z works exactly as the user expects.
function AITools.ApplyProposal(build, proposal)
	local spec = build.spec
	for _, id in ipairs(proposal.removeNodes or {}) do
		local node = spec.nodes[id]
		if node and node.alloc then
			spec:DeallocNode(node)
		end
	end
	for _, id in ipairs(proposal.addNodes or {}) do
		local node = spec.nodes[id]
		if node and not node.alloc then
			spec:AllocNode(node)
		end
	end
	spec:AddUndoState()
	build.buildFlag = true
	return true
end

return AITools
