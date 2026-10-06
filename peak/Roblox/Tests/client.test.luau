-- Appended after stubs.luau and PeakErrorReporter.client.luau by run.sh.
raise(string.rep("é", 400))
local long = captured.fired[1]
check(#long <= 500 and utf8.len(long) ~= nil, "cut to 500 bytes, still valid UTF-8")
for i = 1, 8 do raise("client boom " .. i) end
check(#captured.fired == 5, "client sends at most 5 a minute")
print("client reporter: all checks passed")
