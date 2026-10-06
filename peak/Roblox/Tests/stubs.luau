-- Minimal stand-ins for the Roblox services the reporter uses, recording what it does.
captured = { errorHandlers = {}, remoteHandlers = {}, removingHandlers = {}, requests = {}, encoded = {},
	fired = {}, warnings = 0, secretFound = true, closeHandler = nil, loop = nil }

local function signal(list)
	return { Connect = function(_, fn) table.insert(list, fn) end }
end

local remote = { OnServerEvent = signal(captured.remoteHandlers),
	FireServer = function(_, message) table.insert(captured.fired, message) end }
players = { { Name = "Alice", DisplayName = "Ally Cat", UserId = 123456 }, { Name = "Bo", DisplayName = "Bo", UserId = 7 } }

local services = {
	HttpService = {
		GetSecret = function(_, name)
			assert(name == "peak_ingest", "secret name")
			if not captured.secretFound then error("secret not found") end
			return { AddPrefix = function(_, prefix) return prefix .. "SECRET" end }
		end,
		RequestAsync = function(_, request)
			table.insert(captured.requests, request)
			return { Success = true, StatusCode = 202 }
		end,
		JSONEncode = function(_, value)
			table.insert(captured.encoded, value)
			return "json"
		end,
	},
	Players = { GetPlayers = function() return players end, PlayerRemoving = signal(captured.removingHandlers) },
	ReplicatedStorage = { WaitForChild = function(_, name) assert(name == "PeakClientError"); return remote end },
	ScriptContext = { Error = signal(captured.errorHandlers) },
}

game = {
	PlaceVersion = 128,
	GetService = function(_, name) return assert(services[name], name) end,
	BindToClose = function(_, fn) captured.closeHandler = fn end,
}
Instance = { new = function(className) assert(className == "RemoteEvent"); return remote end }
-- The reporter's loop runs as a coroutine: each `captured.loop()` is one wait-then-flush.
task = {
	spawn = function(fn)
		captured.loop = coroutine.wrap(fn)
		captured.loop()
	end,
	wait = function() coroutine.yield() end,
}
warn = function() captured.warnings += 1 end

function raise(message)
	for _, handler in captured.errorHandlers do handler(message, "", nil) end
end

function check(condition, label)
	if not condition then error("FAILED: " .. label, 2) end
	print("ok - " .. label)
end
