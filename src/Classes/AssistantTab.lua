-- Path of Building
--
-- Class: Assistant Tab
-- Chat panel for asking the AI assistant about the open build.
--
-- Layout, top to bottom: status line, transcript, pending proposals, input box.
-- The tab owns no assistant logic -- it subscribes to AIBridge events and renders them. That
-- split is what lets the smoke-test harness drive the whole feature with no UI at all.
---@class AssistantTab: ControlHost, Control
local AssistantTabClass = newClass("AssistantTab", "ControlHost", "Control")

local LINE_HEIGHT = 16
local INPUT_HEIGHT = 68
local PROPOSAL_BUTTON_HEIGHT = 18
local PROPOSAL_PADDING = 8
-- Breathing room between the bottom of the transcript and the top of the proposal stack.
local PROPOSAL_GAP = 20

local ROLE_COLOR = {
	user = "^xFFCC55",
	assistant = "^7",
	tool = "^x7799BB",
	status = "^x888888",
	error = "^xFF4444",
}

local QUICK_PROMPTS = {
	{ "Cap my resistances", "How do I cap my elemental resistances? Show me the cheapest options and measure them." },
	{ "More life", "How do I get more maximum life? Search the tree and measure the best options by life per point." },
	{ "Analyse this build", "Analyse this build: what are its biggest weaknesses right now, and what would you fix first?" },
}

function AssistantTabClass:AssistantTab(build)
	self:ControlHost()
	self:Control()
	self.build = build

	-- Raw messages; the wrapped display list is rebuilt from these whenever the width changes.
	self.messages = {}
	self.lastWrapWidth = 0
	self.stickToBottom = true

	-- Proposal rows wrap too, so their heights depend on the panel width and have to be
	-- recomputed alongside the transcript.
	self.proposalLayout = {}
	self.lastProposalWidth = 0

	self.controls.status = new("LabelControl")
		:LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 8, 8, 0, 16 }, function()
			return self:StatusText()
		end)

	self.controls.stop = new("ButtonControl")
		:ButtonControl({ "TOPRIGHT", self, "TOPRIGHT" }, { -8, 6, 70, 20 }, "Stop", function()
			AIBridge:Abort()
			self:AddMessage("status", "Stopped.")
		end)
	self.controls.stop.enabled = function() return AIBridge.busy end

	self.controls.clear = new("ButtonControl")
		:ButtonControl({ "TOPRIGHT", self.controls.stop, "TOPLEFT" }, { -6, 0, 70, 20 }, "Clear", function()
			self:Clear()
		end)
	self.controls.clear.enabled = function() return not AIBridge.busy end

	self.controls.transcript = new("TextListControl")
		:TextListControl({ "TOPLEFT", self, "TOPLEFT" }, { 8, 30, 0, 0 }, { { x = 4, align = "LEFT" } })
	self.controls.transcript.width = function() return self.width - 16 end
	self.controls.transcript.height = function()
		return self.height - 46 - INPUT_HEIGHT - self:ProposalAreaHeight()
	end

	self.controls.input = new("EditControl")
		:EditControl({ "BOTTOMLEFT", self, "BOTTOMLEFT" }, { 8, -8, 0, INPUT_HEIGHT - 26 },
			"", "Ask about this build...", "^%C\t\n", nil, nil, LINE_HEIGHT)
	self.controls.input.width = function() return self.width - 16 end

	self.controls.send = new("ButtonControl")
		:ButtonControl({ "BOTTOMRIGHT", self.controls.input, "TOPRIGHT" }, { 0, -4, 90, 20 }, "Send", function()
			self:SendCurrentInput()
		end)
	self.controls.send.enabled = function()
		return not AIBridge.busy and self.controls.input.buf:match("%S") ~= nil
	end

	for index, entry in ipairs(QUICK_PROMPTS) do
		local anchor = index == 1 and { "BOTTOMLEFT", self.controls.input, "TOPLEFT" }
			or { "BOTTOMLEFT", self.controls["quick" .. (index - 1)], "BOTTOMRIGHT" }
		local offset = index == 1 and { 0, -4, 130, 20 } or { 6, 0, 130, 20 }
		self.controls["quick" .. index] = new("ButtonControl")
			:ButtonControl(anchor, offset, entry[1], function()
				self:Send(entry[2])
			end)
		self.controls["quick" .. index].enabled = function() return not AIBridge.busy end
	end

	AIBridge:Subscribe(function(event) self:OnBridgeEvent(event) end)

	self:AddMessage("status",
		"Ask anything about this build. The assistant reads it through Path of Building and " ..
		"measures changes with the real calculation engine before suggesting them.")
	return self
end

--------------------------------------------------------------------------- transcript

function AssistantTabClass:StatusText()
	if AIBridge.busy then
		return "^x888888Thinking... ^7(" .. AIBridge.model .. ")"
	end
	if AIBridge.status == "failed" then
		return "^xFF4444Assistant unavailable: ^7" .. tostring(AIBridge.statusMessage)
	end
	if AIBridge.status == "ready" then
		return "^x888888Ready ^7(" .. AIBridge.model .. ")"
	end
	if AIBridge.status == "starting" then
		return "^x888888Starting assistant..."
	end
	return "^x888888Assistant idle"
end

function AssistantTabClass:AddMessage(role, text)
	if not text or text == "" then return end
	table.insert(self.messages, { role = role, text = text })
	self.lastWrapWidth = 0  -- force a rebuild
	self.stickToBottom = true
end

--- Greedy word wrap against the real rendered width. TextListControl and LabelControl both
--- draw whatever string they are handed, with no clipping, so anything wider than the panel
--- simply runs off the edge.
---
--- Escapes are stripped up front: the assistant's text carries no colour of its own -- callers
--- prepend it -- and a stray '^' in model output would otherwise be eaten by the renderer,
--- desyncing the measured width from the drawn one.
local function wrapLine(text, maxWidth)
	-- Floor the width so a collapsed panel can't stall the character splitter below.
	maxWidth = math.max(maxWidth or 0, 40)
	local lines = {}

	--- Character-level fallback for a token that cannot fit on a line of its own: a long URL,
	--- an item name, a blob of JSON. Returns the trailing remainder for the caller to continue.
	local function splitOversized(indent, word)
		local current = ""
		for index = 1, #word do
			local char = word:sub(index, index)
			if current ~= "" and DrawStringWidth(LINE_HEIGHT, "VAR", indent .. current .. char) > maxWidth then
				table.insert(lines, indent .. current)
				current = char
			else
				current = current .. char
			end
		end
		return current
	end

	for rawLine in (StripEscapes(text) .. "\n"):gmatch("([^\n]*)\n") do
		-- Leading whitespace is kept and reused as a hanging indent, so bullet lists and
		-- numbered steps in the answer stay aligned once they wrap.
		local indent, body = rawLine:match("^(%s*)(.-)%s*$")
		if body == "" then
			table.insert(lines, "")
		else
			local current = ""
			for word in body:gmatch("%S+") do
				local candidate = current == "" and word or (current .. " " .. word)
				if DrawStringWidth(LINE_HEIGHT, "VAR", indent .. candidate) <= maxWidth then
					current = candidate
				else
					if current ~= "" then
						table.insert(lines, indent .. current)
						current = ""
					end
					if DrawStringWidth(LINE_HEIGHT, "VAR", indent .. word) > maxWidth then
						current = splitOversized(indent, word)
					else
						current = word
					end
				end
			end
			if current ~= "" then table.insert(lines, indent .. current) end
		end
	end
	return lines
end

function AssistantTabClass:RebuildTranscript(width)
	local list = {}
	local maxWidth = width - 24
	for _, message in ipairs(self.messages) do
		local color = ROLE_COLOR[message.role] or "^7"
		-- The speaker prefix is laid out as a hanging indent using the list's per-line x, so
		-- continuation lines align under the text instead of under "You: ". Measuring it is
		-- the only way to get this right: VAR is a proportional font, so padding with spaces
		-- would not line up.
		local prefix = message.role == "user" and "You: " or ""
		local prefixWidth = prefix ~= "" and DrawStringWidth(LINE_HEIGHT, "VAR", prefix) or 0
		for index, line in ipairs(wrapLine(message.text, maxWidth - prefixWidth)) do
			if index == 1 then
				table.insert(list, { height = LINE_HEIGHT, color .. prefix .. line })
			else
				table.insert(list, { height = LINE_HEIGHT, x = 4 + prefixWidth, color .. line })
			end
		end
		table.insert(list, { height = 6, "" })
	end
	self.controls.transcript.list = list
	self.lastWrapWidth = width
end

function AssistantTabClass:ScrollToBottom()
	local scrollBar = self.controls.transcript.controls.scrollBar
	scrollBar:SetOffset(scrollBar.offsetMax or 0)
end

--------------------------------------------------------------------------- proposals

function AssistantTabClass:ProposalAreaHeight()
	local total = 0
	for _, block in ipairs(self.proposalLayout) do
		total = total + block.height
	end
	return total > 0 and (total + PROPOSAL_GAP) or 0
end

--- Proposal rows are rebuilt whenever the set changes: they are ordinary buttons rather than
--- entries in the transcript because the transcript is a plain string list and cannot host
--- anything clickable.
---
--- Title and summary are wrapped and joined with newlines into a single LabelControl --
--- DrawString renders embedded newlines as multiple lines -- which means the row height has to
--- be counted here, the same way PartyTab does for its wrapped notes. Heights therefore depend
--- on the panel width, so Draw re-runs this whenever the width changes.
function AssistantTabClass:RebuildProposalControls()
	for name in pairs(self.controls) do
		if name:match("^proposal") then self.controls[name] = nil end
	end
	self.proposalLayout = {}
	-- Before the first Draw there is no width to wrap against; Draw will call us again.
	if not self.width or self.width <= 0 then return end
	self.lastProposalWidth = self.width

	local textWidth = self.width - 16
	for _, proposal in ipairs(AIBridge.proposals) do
		-- Wrapped separately so each part keeps its own colour: wrapLine strips escapes, so
		-- colour codes cannot be embedded in the text handed to it.
		local lines = {}
		local header = proposal.title .. "  (" .. proposal.pointCost .. " pts)"
		for _, line in ipairs(wrapLine(header, textWidth)) do
			table.insert(lines, "^xFFCC55" .. line)
		end
		if proposal.summary ~= "" then
			for _, line in ipairs(wrapLine(proposal.summary, textWidth)) do
				table.insert(lines, "^7" .. line)
			end
		end
		table.insert(self.proposalLayout, {
			proposal = proposal,
			label = table.concat(lines, "\n"),
			textHeight = #lines * LINE_HEIGHT,
			height = #lines * LINE_HEIGHT + PROPOSAL_BUTTON_HEIGHT + PROPOSAL_PADDING,
		})
	end

	-- The stack grows upward from just above the quick-prompt buttons.
	local bottom = -INPUT_HEIGHT - 30
	for index = #self.proposalLayout, 1, -1 do
		local block = self.proposalLayout[index]
		bottom = bottom - block.height
		block.offsetY = bottom
	end

	-- A BOTTOMLEFT anchor subtracts the control's own height (Control:GetPos), so each y below
	-- is the block-relative top plus that height. The label's height stays LINE_HEIGHT because
	-- LabelControl reuses it as the font size -- the extra wrapped lines are drawn below it,
	-- which is why the buttons are offset by the measured textHeight rather than by one line.
	for index, block in ipairs(self.proposalLayout) do
		local proposal = block.proposal
		self.controls["proposalLabel" .. index] = new("LabelControl")
			:LabelControl({ "BOTTOMLEFT", self, "BOTTOMLEFT" },
				{ 8, block.offsetY + LINE_HEIGHT, 0, LINE_HEIGHT }, block.label)

		local buttonY = block.offsetY + block.textHeight + 2 + PROPOSAL_BUTTON_HEIGHT
		self.controls["proposalApply" .. index] = new("ButtonControl")
			:ButtonControl({ "BOTTOMLEFT", self, "BOTTOMLEFT" },
				{ 8, buttonY, 90, PROPOSAL_BUTTON_HEIGHT }, "Apply", function()
					AITools.ApplyProposal(self.build, proposal)
					self:AddMessage("status", "Applied: " .. proposal.title .. ". Ctrl+Z undoes it.")
					AIBridge:RemoveProposal(proposal)
					self:RebuildProposalControls()
				end)

		self.controls["proposalDismiss" .. index] = new("ButtonControl")
			:ButtonControl({ "BOTTOMLEFT", self, "BOTTOMLEFT" },
				{ 104, buttonY, 90, PROPOSAL_BUTTON_HEIGHT }, "Dismiss", function()
					AIBridge:RemoveProposal(proposal)
					self:RebuildProposalControls()
				end)
	end
end

--------------------------------------------------------------------------- sending

function AssistantTabClass:Send(text)
	if AIBridge.status ~= "ready" then
		AIBridge:Start()
		self.pendingSend = text
		self:AddMessage("status", "Starting the assistant...")
		return
	end
	AIBridge:Send(text)
end

function AssistantTabClass:SendCurrentInput()
	local text = self.controls.input.buf
	if not text:match("%S") then return end
	self.controls.input:SetText("")
	self:Send(text)
end

function AssistantTabClass:Clear()
	self.messages = {}
	AIBridge:ClearProposals()
	self:RebuildProposalControls()
	self.lastWrapWidth = 0
	self:AddMessage("status", "Conversation cleared.")
end

--------------------------------------------------------------------------- events

function AssistantTabClass:OnBridgeEvent(event)
	if event.kind == "user" then
		self:AddMessage("user", event.text)
	elseif event.kind == "text" then
		self:AddMessage("assistant", event.text)
	elseif event.kind == "error" then
		self:AddMessage("error", event.text)
	elseif event.kind == "tool_use" then
		self:AddMessage("tool", self:DescribeToolUse(event))
	elseif event.kind == "propose" then
		self:RebuildProposalControls()
	elseif event.kind == "status" then
		if event.status == "ready" and self.pendingSend then
			local text = self.pendingSend
			self.pendingSend = nil
			AIBridge:Send(text)
		elseif event.status == "failed" then
			self:AddMessage("error", tostring(event.message))
		end
	elseif event.kind == "result" then
		self.modFlag = true
	end
end

--- Tool calls are shown, but compressed to one readable line. Hiding them entirely would make
--- the assistant look like it was making things up; printing the raw JSON would bury the answer.
function AssistantTabClass:DescribeToolUse(event)
	local args = event.args or {}
	if event.name == "pob_search_tree" then
		return "searching the tree for \"" .. tostring(args.query or "") .. "\""
	elseif event.name == "pob_simulate" then
		if args.item then
			return "measuring that item in " .. tostring(args.slot or "its slot")
		end
		return "simulating a change"
	elseif event.name == "pob_simulate_batch" then
		return "simulating " .. tostring(#(args.variants or {})) .. " variations"
	elseif event.name == "pob_get_build" then
		return "reading the build"
	elseif event.name == "pob_get_tree" then
		return "reading the passive tree"
	elseif event.name == "pob_get_items" then
		return "reading equipped items"
	elseif event.name == "pob_get_skills" then
		return "reading the skill setup"
	elseif event.name == "pob_path_to_node" then
		return "checking the path to a node"
	elseif event.name == "pob_propose" then
		return "preparing a proposal"
	end
	return event.name
end

--------------------------------------------------------------------------- frame

function AssistantTabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height

	-- Both the transcript and the proposal rows are wrapped to the panel width, so they have
	-- to be rebuilt before input is processed against their new positions.
	if self.width ~= self.lastProposalWidth then
		self:RebuildProposalControls()
	end

	local transcriptWidth = self.width - 16
	if transcriptWidth ~= self.lastWrapWidth then
		self:RebuildTranscript(transcriptWidth)
		if self.stickToBottom then
			self:ScrollToBottom()
			self.stickToBottom = false
		end
	end

	for id, event in ipairs(inputEvents) do
		if event.type == "KeyDown" then
			-- Enter sends, Shift+Enter keeps writing: the convention every chat box uses.
			if event.key == "RETURN" and not IsKeyDown("SHIFT")
					and self.selControl == self.controls.input then
				self:SendCurrentInput()
				inputEvents[id] = nil
			end
		end
	end

	self:ProcessControlsInput(inputEvents, viewPort)

	main:DrawBackground(viewPort)
	self:DrawControls(viewPort)
end

--------------------------------------------------------------------------- persistence

function AssistantTabClass:Load(xml, fileName)
	for _, node in ipairs(xml) do
		if type(node) == "table" and node.elem == "Message" then
			table.insert(self.messages, { role = node.attrib.role or "assistant", text = node[1] or "" })
		end
	end
	self.lastWrapWidth = 0
end

function AssistantTabClass:Save(xml)
	-- Proposals are deliberately not saved: they reference node ids that only make sense
	-- against the tree as it stood when they were made.
	for _, message in ipairs(self.messages) do
		if message.role == "user" or message.role == "assistant" then
			table.insert(xml, { elem = "Message", attrib = { role = message.role }, message.text })
		end
	end
	self.modFlag = false
end
