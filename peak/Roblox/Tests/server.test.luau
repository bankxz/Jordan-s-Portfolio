-- Appended after stubs.luau and PeakErrorReporter.server.luau by run.sh.
local function lastBatch() return captured.encoded[#captured.encoded] end

-- Identical errors are grouped; player names, display names and IDs never leave the game.
for _ = 1, 3 do
	raise("ServerScriptService.Pets:42: no pet for Alice (Players.Alice.Backpack) id 123456, 'Ally Cat'")
end
raise("DataStore request dropped")
captured.closeHandler()
check(#captured.requests == 1, "one request on close")
local request = captured.requests[1]
check(request.Url == "https://YOUR-PEAK-SERVER/v1/ingest/errors" and request.Method == "POST", "posts to the endpoint")
check(request.Headers.Authorization == "Bearer SECRET", "key from the secret, as a bearer header")
check(request.Headers["Content-Type"] == "application/json", "JSON content type")
local batch = lastBatch()
check(batch.placeVersion == 128 and #batch.errors == 2, "two groups with the place version")
local counts, scrubbed = {}, true
for _, entry in batch.errors do
	counts[entry.count] = entry
	for _, secretWord in { "Alice", "Ally", "123456" } do
		if string.find(entry.message, secretWord, 1, true) then scrubbed = false end
	end
end
check(counts[3] ~= nil and counts[1] ~= nil, "counts 3 and 1")
check(scrubbed, "no player names or IDs")
check(string.find(counts[3].message, "Players.<player>.Backpack", 1, true) ~= nil, "replaced with <player>")

-- Nothing pending: nothing sent.
captured.closeHandler()
check(#captured.requests == 1, "empty flush sends nothing")

-- Client errors: wrong types ignored, 5 a minute per player.
local remoteHandler = captured.remoteHandlers[1]
local player = players[1]
remoteHandler(player, 42)
remoteHandler(player, "")
remoteHandler(player, { "table" })
for i = 1, 7 do remoteHandler(player, "client error " .. string.rep("x", i)) end
captured.loop()
batch = lastBatch()
check(#captured.requests == 2 and #batch.errors == 5, "5 client errors per player per minute")
check(batch.errors[1].source == "client", "marked as client")
remoteHandler(players[2], "other player")
captured.closeHandler()
check(#captured.requests == 3, "each player has their own budget")
for _, handler in captured.removingHandlers do handler(player) end

-- Long messages are cut to 500 bytes without breaking UTF-8.
raise(string.rep("é", 400))
captured.closeHandler()
local long = lastBatch().errors[1].message
check(#long <= 500 and utf8.len(long) ~= nil, "cut to 500 bytes, still valid UTF-8")

-- At most 100 distinct messages wait for the next flush.
for i = 1, 150 do raise("distinct error " .. tostring(i) .. string.rep("z", i)) end
captured.closeHandler()
check(#lastBatch().errors == 100, "capped at 100 pending")

-- Missing secret: warn, drop the batch, don't throw.
captured.secretFound = false
raise("after secret removed")
local before = #captured.requests
captured.closeHandler()
check(#captured.requests == before and captured.warnings >= 1, "missing secret warns and drops")
captured.secretFound = true
captured.closeHandler()
check(#captured.requests == before, "dropped batch isn't resent")
print("server reporter: all checks passed")
