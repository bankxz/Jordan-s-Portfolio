--!strict
-- Peak error reporter (server). Put this Script in ServerScriptService.
-- Setup: Game Settings > Security > Allow HTTP Requests: on.
--        Creator Dashboard > your game > Secrets: name "peak_ingest", value = the key from the Peak app,
--        domain = your Peak server's domain.
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptContext = game:GetService("ScriptContext")

local ENDPOINT = "https://YOUR-PEAK-SERVER/v1/ingest/errors"
local FLUSH_SECONDS = 60
local MAX_PENDING = 100
local MAX_MESSAGE = 500
local CLIENT_REPORTS_PER_MINUTE = 5

type Entry = { message: string, source: string, count: number }
local pending: { [string]: Entry } = {}
local pendingCount = 0

-- Cuts to a byte limit without splitting a character: the batch is sent as JSON, which needs valid UTF-8.
local function truncate(text: string, maxBytes: number): string
	text = string.sub(text, 1, maxBytes)
	while #text > 0 and utf8.len(text) == nil do
		text = string.sub(text, 1, #text - 1)
	end
	return text
end

local function replacePlain(text: string, find: string, replacement: string): string
	local parts = {}
	local start = 1
	while true do
		local first, last = string.find(text, find, start, true)
		if first == nil or last == nil then
			break
		end
		table.insert(parts, string.sub(text, start, first - 1))
		table.insert(parts, replacement)
		start = last + 1
	end
	table.insert(parts, string.sub(text, start))
	return table.concat(parts)
end

-- Player names and IDs never leave the game (Peak also strips them, this is the first line).
local function scrub(message: string): string
	for _, player in Players:GetPlayers() do
		for _, value in { player.Name, player.DisplayName, tostring(player.UserId) } do
			if #value >= 3 then
				message = replacePlain(message, value, "<player>")
			end
		end
	end
	return message
end

local function add(message: string, source: string)
	message = truncate(message, MAX_MESSAGE)
	local key = source .. "\0" .. message
	local entry = pending[key]
	if entry then
		entry.count += 1
	elseif pendingCount < MAX_PENDING then
		pending[key] = { message = truncate(scrub(message), MAX_MESSAGE), source = source, count = 1 }
		pendingCount += 1
	end
end

ScriptContext.Error:Connect(function(message: string)
	add(message, "server")
end)

-- Client errors: the client is untrusted, so check type and size and limit each player.
local remote = Instance.new("RemoteEvent")
remote.Name = "PeakClientError"
remote.Parent = ReplicatedStorage

local budgets: { [Player]: { windowStart: number, count: number } } = {}
remote.OnServerEvent:Connect(function(player: Player, message: unknown)
	if typeof(message) ~= "string" or #message == 0 then
		return
	end
	local now = os.clock()
	local budget = budgets[player]
	if budget == nil or now - budget.windowStart >= 60 then
		budget = { windowStart = now, count = 0 }
		budgets[player] = budget
	end
	if budget.count >= CLIENT_REPORTS_PER_MINUTE then
		return
	end
	budget.count += 1
	add(message, "client")
end)
Players.PlayerRemoving:Connect(function(player: Player)
	budgets[player] = nil
end)

local function flush()
	if pendingCount == 0 then
		return
	end
	local batch = {}
	for _, entry in pending do
		table.insert(batch, entry)
	end
	pending = {}
	pendingCount = 0

	local found, secret = pcall(function()
		return HttpService:GetSecret("peak_ingest")
	end)
	if not found then
		warn("[Peak] Add the secret 'peak_ingest' to report errors.")
		return
	end
	local sent, result = pcall(function()
		return HttpService:RequestAsync({
			Url = ENDPOINT,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["Authorization"] = secret:AddPrefix("Bearer "),
			},
			Body = HttpService:JSONEncode({ placeVersion = game.PlaceVersion, errors = batch }),
		})
	end)
	-- Reports are best effort: a failed batch is dropped rather than retried, so an outage can't pile up.
	if not sent or not result.Success then
		warn("[Peak] Error report not sent.")
	end
end

task.spawn(function()
	while true do
		task.wait(FLUSH_SECONDS)
		flush()
	end
end)
game:BindToClose(flush)
