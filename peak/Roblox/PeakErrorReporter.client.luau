--!strict
-- Peak error reporter (client). Put this LocalScript in StarterPlayer > StarterPlayerScripts.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptContext = game:GetService("ScriptContext")

local remote = ReplicatedStorage:WaitForChild("PeakClientError") :: RemoteEvent
local REPORTS_PER_MINUTE = 5
local MAX_MESSAGE = 500
local windowStart = os.clock()
local sent = 0

local function truncate(text: string, maxBytes: number): string
	text = string.sub(text, 1, maxBytes)
	while #text > 0 and utf8.len(text) == nil do
		text = string.sub(text, 1, #text - 1)
	end
	return text
end

ScriptContext.Error:Connect(function(message: string)
	local now = os.clock()
	if now - windowStart >= 60 then
		windowStart = now
		sent = 0
	end
	if sent >= REPORTS_PER_MINUTE then
		return
	end
	sent += 1
	remote:FireServer(truncate(message, MAX_MESSAGE))
end)
