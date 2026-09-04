-- Path of Building
--
-- Module: AIServer
-- MCP (Model Context Protocol) server exposing the open build to a `claude` child process.
--
-- Runs as a subscript (separate Lua state, host thread) because the main state cannot block.
-- Speaks the Streamable-HTTP flavour of MCP over loopback TCP:
--     initialize -> notifications/initialized -> [GET /mcp] -> tools/list -> tools/call
--
-- Two things drive the shape of this file, both established by the Phase 0 spikes:
--
--  * Plain application/json responses are enough. The client asks for text/event-stream on a
--    GET, but takes a 405 and carries on, so there is no SSE machinery here.
--  * A subscript can call into the main Lua state but CANNOT receive a return value. So a
--    tools/call goes out as a one-way doorbell (PoBAI_ToolCall) and the answer comes back as a
--    file the main state drops in the spool directory.
--
-- Everything is multiplexed through socket.select: the client keeps one connection alive while
-- opening another, and a tools/call can take seconds. Blocking anywhere stalls the whole server.

local spoolDir, toolsJson, serverName, serverVersion = ...

local socket = require("socket")
local dkjson = require("dkjson")

local PORT_FIRST, PORT_LAST = 49090, 49120
local SELECT_TIMEOUT = 0.05
local REQUEST_LIMIT = 4 * 1024 * 1024

local function log(fmt, ...)
	ConPrintf("[AIServer] " .. fmt, ...)
end

-- The main state publishes a response by renaming into place, so seeing the file at all means
-- it is complete; no partial reads to guard against.
local function takeResponse(reqId)
	local path = spoolDir .. "/resp_" .. reqId .. ".json"
	local f = io.open(path, "r")
	if not f then return nil end
	local body = f:read("*a")
	f:close()
	os.remove(path)
	return body
end

local function httpRaw(status, reason, headers, body)
	local out = { string.format("HTTP/1.1 %d %s", status, reason) }
	for _, h in ipairs(headers or {}) do out[#out + 1] = h end
	out[#out + 1] = "Content-Length: " .. #(body or "")
	out[#out + 1] = ""
	out[#out + 1] = body or ""
	return table.concat(out, "\r\n")
end

local function jsonResponse(body)
	return httpRaw(200, "OK", {
		"Content-Type: application/json",
		"Mcp-Session-Id: pob",
	}, body)
end

local function rpcError(id, code, message)
	return jsonResponse(dkjson.encode({
		jsonrpc = "2.0",
		id = id,
		error = { code = code, message = message },
	}))
end

---------------------------------------------------------------------------- listen

local server = socket.tcp4()
local port
for p = PORT_FIRST, PORT_LAST do
	if server:bind("127.0.0.1", p) then port = p break end
end
if not port then
	server:close()
	return nil, "could not bind a port in " .. PORT_FIRST .. "-" .. PORT_LAST
end
server:listen(8)
server:settimeout(0)
log("listening on 127.0.0.1:%d", port)
PoBAI_ServerReady(port)

---------------------------------------------------------------------------- clients

-- client = { sock = socket, buf = string, pending = { rpcId, reqId } }
local clients = {}

local function dropClient(client, why)
	for i, c in ipairs(clients) do
		if c == client then table.remove(clients, i) break end
	end
	client.sock:close()
	client.dead = true
	if why then log("client closed (%s)", why) end
end

local function send(client, text)
	client.sock:settimeout(2)
	local ok, err = client.sock:send(text)
	if ok then
		client.sock:settimeout(0)
	else
		dropClient(client, "send failed: " .. tostring(err))
	end
	return ok
end

-- Pulls one complete HTTP request out of the buffer, or returns nil if more bytes are needed.
local function takeMessage(client)
	local headEnd = client.buf:find("\r\n\r\n", 1, true)
	if not headEnd then return nil end
	local head = client.buf:sub(1, headEnd - 1)
	local method, path = head:match("^(%u+)%s+(%S+)")
	local length = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
	local bodyStart = headEnd + 4
	if #client.buf < bodyStart + length - 1 then return nil end
	local body = client.buf:sub(bodyStart, bodyStart + length - 1)
	client.buf = client.buf:sub(bodyStart + length)
	return method, path, body
end

local function handleRpc(client, msg)
	local id, method = msg.id, msg.method

	-- A notification carries no id and wants no response body.
	if id == nil then
		return httpRaw(202, "Accepted", {}, "")
	end

	if method == "initialize" then
		local params = msg.params or {}
		return jsonResponse(dkjson.encode({
			jsonrpc = "2.0",
			id = id,
			result = {
				-- Echo the client's version: it picks, we follow.
				protocolVersion = params.protocolVersion or "2025-11-25",
				capabilities = { tools = { listChanged = false } },
				serverInfo = { name = serverName, version = serverVersion },
			},
		}))
	end

	if method == "tools/list" then
		-- toolsJson is the pre-encoded array handed to us at launch; splice it in rather than
		-- decoding and re-encoding a structure we never otherwise look at.
		return jsonResponse('{"jsonrpc":"2.0","id":' .. dkjson.encode(id) ..
			',"result":{"tools":' .. toolsJson .. '}}')
	end

	if method == "tools/call" then
		local params = msg.params or {}
		local name = params.name
		if type(name) ~= "string" then
			return rpcError(id, -32602, "tools/call requires a string 'name'")
		end
		local reqId = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
		client.pending = { rpcId = id, reqId = reqId }
		-- One-way doorbell into the main state; the answer arrives as a file.
		PoBAI_ToolCall(reqId, name, dkjson.encode(params.arguments or {}))
		return nil
	end

	if method == "ping" then
		return jsonResponse('{"jsonrpc":"2.0","id":' .. dkjson.encode(id) .. ',"result":{}}')
	end

	return rpcError(id, -32601, "method not found: " .. tostring(method))
end

local function serviceClient(client)
	while not client.pending and not client.dead do
		local method, path, body = takeMessage(client)
		if not method then return end

		if method == "POST" then
			local msg, _, err = dkjson.decode(body)
			if type(msg) ~= "table" then
				send(client, rpcError(nil, -32700, "parse error: " .. tostring(err)))
			elseif msg[1] then
				-- Batched requests: the client has never sent one, so reject loudly rather
				-- than silently answering only the first entry.
				send(client, rpcError(nil, -32600, "batched requests are not supported"))
			else
				local response = handleRpc(client, msg)
				if response then send(client, response) end
			end
		elseif method == "GET" then
			-- The SSE upgrade. Declining it is fine; the client falls back to POST-only.
			send(client, httpRaw(405, "Method Not Allowed", {}, ""))
		elseif method == "DELETE" then
			send(client, httpRaw(200, "OK", {}, ""))
			dropClient(client, "session ended")
			return
		else
			send(client, httpRaw(400, "Bad Request", {}, ""))
		end
	end
end

---------------------------------------------------------------------------- loop

log("entering serve loop")
while true do
	local watch = { server }
	for _, c in ipairs(clients) do watch[#watch + 1] = c.sock end
	local readable = socket.select(watch, nil, SELECT_TIMEOUT)

	for _, sock in ipairs(readable or {}) do
		if sock == server then
			local incoming = server:accept()
			if incoming then
				local peer = incoming:getpeername()
				if peer ~= "127.0.0.1" then
					-- Never serve anything that did not originate on this machine.
					log("refused non-loopback connection from %s", tostring(peer))
					incoming:close()
				else
					incoming:settimeout(0)
					clients[#clients + 1] = { sock = incoming, buf = "" }
				end
			end
		else
			for _, client in ipairs(clients) do
				if client.sock == sock then
					local chunk, err, partial = sock:receive(8192)
					local data = chunk or partial
					if data and #data > 0 then
						client.buf = client.buf .. data
						if #client.buf > REQUEST_LIMIT then
							send(client, httpRaw(413, "Payload Too Large", {}, ""))
							dropClient(client, "request too large")
						else
							serviceClient(client)
						end
					elseif err == "closed" then
						dropClient(client)
					end
					break
				end
			end
		end
	end

	-- Deliver any tool results the main state has finished computing.
	for i = #clients, 1, -1 do
		local client = clients[i]
		if client.pending then
			local resultJson = takeResponse(client.pending.reqId)
			if resultJson then
				send(client, jsonResponse('{"jsonrpc":"2.0","id":' ..
					dkjson.encode(client.pending.rpcId) .. ',"result":' .. resultJson .. '}'))
				client.pending = nil
				if not client.dead then serviceClient(client) end
			end
		end
	end
end
