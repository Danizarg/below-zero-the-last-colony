--[[
	TableUtil.lua
	Small table helpers used across services. Nothing clever on purpose.
]]

local TableUtil = {}

--[[ Recursive copy. Cycles are not handled; config and profile data is acyclic
     and a cycle here would be a bug worth crashing on. ]]
function TableUtil.deepCopy(source)
	if type(source) ~= "table" then
		return source
	end
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = TableUtil.deepCopy(value)
	end
	return copy
end

--[[ Fill in missing keys of `target` from `defaults`, recursively.
     Existing values always win, which is what makes this safe to run over a
     loaded profile after adding new fields to the template. ]]
function TableUtil.reconcile(target, defaults)
	if type(target) ~= "table" then
		return TableUtil.deepCopy(defaults)
	end
	for key, value in pairs(defaults) do
		if target[key] == nil then
			target[key] = TableUtil.deepCopy(value)
		elseif type(value) == "table" and type(target[key]) == "table" then
			TableUtil.reconcile(target[key], value)
		end
	end
	return target
end

function TableUtil.count(source)
	local n = 0
	for _ in pairs(source) do
		n += 1
	end
	return n
end

function TableUtil.keys(source, sorted)
	local keys = {}
	for key in pairs(source) do
		table.insert(keys, key)
	end
	if sorted then
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
	end
	return keys
end

function TableUtil.values(source)
	local values = {}
	for _, value in pairs(source) do
		table.insert(values, value)
	end
	return values
end

function TableUtil.find(array, predicate)
	for index, value in ipairs(array) do
		if predicate(value, index) then
			return value, index
		end
	end
	return nil, nil
end

function TableUtil.filter(array, predicate)
	local out = {}
	for index, value in ipairs(array) do
		if predicate(value, index) then
			table.insert(out, value)
		end
	end
	return out
end

function TableUtil.map(array, transform)
	local out = table.create(#array)
	for index, value in ipairs(array) do
		out[index] = transform(value, index)
	end
	return out
end

function TableUtil.sum(source)
	local total = 0
	for _, value in pairs(source) do
		if type(value) == "number" then
			total += value
		end
	end
	return total
end

--[[ Merge numeric maps: result[k] = a[k] + b[k]. Used for resource bundles. ]]
function TableUtil.addMaps(a, b)
	local out = table.clone(a or {})
	for key, value in pairs(b or {}) do
		out[key] = (out[key] or 0) + value
	end
	return out
end

--[[ Multiply every value in a numeric map, dropping anything that rounds to 0. ]]
function TableUtil.scaleMap(source, factor, roundFn)
	roundFn = roundFn or math.floor
	local out = {}
	for key, value in pairs(source or {}) do
		local scaled = roundFn(value * factor)
		if scaled > 0 then
			out[key] = scaled
		end
	end
	return out
end

function TableUtil.isEmpty(source)
	return next(source) == nil
end

--[[ Shallow equality over a numeric map. Used to skip no-op replication. ]]
function TableUtil.mapsEqual(a, b)
	for key, value in pairs(a) do
		if b[key] ~= value then
			return false
		end
	end
	for key, value in pairs(b) do
		if a[key] ~= value then
			return false
		end
	end
	return true
end

return TableUtil
