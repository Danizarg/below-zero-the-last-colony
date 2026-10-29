--[[
	Signal.lua
	Minimal synchronous event object, used for server-internal service-to-service
	communication so services never have to know about each other's internals.

	Deliberately small: connect, once, fire, disconnect, destroy. No deferred
	dispatch, no yielding handlers — a handler that yields would block the firing
	system, so handlers are expected to be cheap and non-blocking. Spawn a task
	yourself if you need to wait on something.
]]

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection.new(signal, handler)
	return setmetatable({ _signal = signal, _handler = handler, connected = true }, Connection)
end

function Connection:Disconnect()
	if not self.connected then
		return
	end
	self.connected = false
	local handlers = self._signal._handlers
	local index = table.find(handlers, self)
	if index then
		table.remove(handlers, index)
	end
	self._handler = nil
	self._signal = nil
end

Connection.disconnect = Connection.Disconnect

function Signal.new(name)
	return setmetatable({ _handlers = {}, _name = name or "anonymous" }, Signal)
end

function Signal:Connect(handler)
	assert(type(handler) == "function", "Signal:Connect expects a function")
	local connection = Connection.new(self, handler)
	table.insert(self._handlers, connection)
	return connection
end

function Signal:Once(handler)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

--[[ Handlers are called on a snapshot, so a handler may safely disconnect
     itself or others without disturbing this dispatch. Errors are caught and
     reported so one bad listener cannot break the rest. ]]
function Signal:Fire(...)
	local snapshot = table.clone(self._handlers)
	for _, connection in ipairs(snapshot) do
		if connection.connected and connection._handler then
			local ok, err = pcall(connection._handler, ...)
			if not ok then
				warn(("[Signal:%s] handler error: %s"):format(self._name, tostring(err)))
			end
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Destroy()
	for index = #self._handlers, 1, -1 do
		self._handlers[index]:Disconnect()
	end
	self._handlers = {}
end

Signal.connect = Signal.Connect
Signal.once = Signal.Once
Signal.fire = Signal.Fire
Signal.destroy = Signal.Destroy

return Signal
