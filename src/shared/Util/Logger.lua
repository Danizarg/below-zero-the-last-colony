--[[
	Logger.lua
	Tagged logging with a debug gate, so development chatter can be switched off
	in one place without hunting down print calls.

	Logger.new("ExpeditionService") returns a logger whose output is prefixed
	[BZ/ExpeditionService]. info() is gated behind GameConfig.Debug; warn() and
	error-level output always show, because a silenced warning is worse than a
	noisy one.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)

local Logger = {}
Logger.__index = Logger

local PREFIX = "BZ"

--[[ Per-tag throttle, so a per-frame code path cannot flood the output. ]]
local lastEmitted = {}

function Logger.new(tag)
	return setmetatable({ _tag = tag or "?" }, Logger)
end

function Logger:_format(level, message, ...)
	local body = message
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, message, ...)
		body = ok and formatted or (message .. " <malformed log args>")
	end
	return ("[%s/%s]%s %s"):format(PREFIX, self._tag, level ~= "" and (" " .. level) or "", body)
end

function Logger:info(message, ...)
	if GameConfig.Debug then
		print(self:_format("", message, ...))
	end
end

function Logger:debug(message, ...)
	if GameConfig.Debug then
		print(self:_format("debug", message, ...))
	end
end

--[[ Always emitted. Use for anything an operator would want to know about. ]]
function Logger:warn(message, ...)
	warn(self:_format("WARN", message, ...))
end

--[[ Reports a problem without stopping the caller. Use where continuing in a
     degraded state is better than dropping a player's session. ]]
function Logger:fault(message, ...)
	warn(self:_format("FAULT", message, ...))
end

--[[ Rate-limited info, for hot paths. `key` identifies the message, `every` is
     the minimum seconds between emissions. ]]
function Logger:throttled(key, every, message, ...)
	if not GameConfig.Debug then
		return
	end
	local fullKey = self._tag .. "/" .. key
	local now = os.clock()
	local last = lastEmitted[fullKey]
	if last and (now - last) < every then
		return
	end
	lastEmitted[fullKey] = now
	print(self:_format("", message, ...))
end

--[[ Wrap a call so a failure is logged with context instead of vanishing into a
     coroutine. Returns ok, result... ]]
function Logger:guard(what, fn, ...)
	local results = table.pack(pcall(fn, ...))
	if not results[1] then
		self:fault("%s failed: %s", what, tostring(results[2]))
		return false
	end
	return true, table.unpack(results, 2, results.n)
end

return Logger
