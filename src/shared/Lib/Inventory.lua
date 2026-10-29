--[[
	Inventory.lua

	Pure inventory arithmetic. No Instances, no remotes, no services — the server
	owns a plain table and asks this module what a change would do.

	Two inventory flavours share the same shape:

	  colony bag       capacity-limited by total units, persisted, survives death
	  expedition bag   capacity-limited by weight, temporary, partially lost on
	                   death per difficulty

	An inventory is `{ [resourceId] = count }` plus a separate `consumables`
	table. Keeping it a flat map rather than a slot array means no slot-shuffling
	bugs; stack limits are enforced as a per-resource cap instead.

	Every mutating function is total: it never errors on bad input, it returns a
	result table saying what happened. The caller decides whether to tell the
	player.
]]

local Enums = require(script.Parent.Parent.Enums)

local Inventory = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Construction
-- ─────────────────────────────────────────────────────────────────────────────

function Inventory.new()
	return { items = {}, consumables = {} }
end

function Inventory.clone(inventory)
	local copy = Inventory.new()
	for id, count in pairs(inventory.items or {}) do
		copy.items[id] = count
	end
	for id, count in pairs(inventory.consumables or {}) do
		copy.consumables[id] = count
	end
	return copy
end

function Inventory.isEmpty(inventory)
	return next(inventory.items or {}) == nil and next(inventory.consumables or {}) == nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Measurement
-- ─────────────────────────────────────────────────────────────────────────────

function Inventory.count(inventory, resourceId)
	return (inventory.items and inventory.items[resourceId]) or 0
end

function Inventory.consumableCount(inventory, consumableId)
	return (inventory.consumables and inventory.consumables[consumableId]) or 0
end

--[[ Total units held, ignoring weight. Used by the colony's storage cap. ]]
function Inventory.totalUnits(inventory)
	local total = 0
	for _, count in pairs(inventory.items or {}) do
		total += count
	end
	for _, count in pairs(inventory.consumables or {}) do
		total += count
	end
	return total
end

--[[
	Total weight, used by the expedition bag.
	@param defs { [resourceId] = { weight = n } }   ResourceConfig.Resources
	@param consumableDefs { [id] = { weight = n } } ResourceConfig.Consumables
]]
function Inventory.totalWeight(inventory, defs, consumableDefs)
	local total = 0
	for id, count in pairs(inventory.items or {}) do
		local def = defs and defs[id]
		total += count * ((def and def.weight) or 1)
	end
	for id, count in pairs(inventory.consumables or {}) do
		local def = consumableDefs and consumableDefs[id]
		total += count * ((def and def.weight) or 1)
	end
	return total
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Adding
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Try to add `amount` of `resourceId`.

	@param limits {
		stackLimit  number|nil  per-resource cap
		capacity    number|nil  total cap, measured in `measure` units
		measure     "units"|"weight"
		defs        resource definition map, required for "weight"
		consumableDefs consumable definition map, optional
	}
	@return {
		added      number  how much actually went in
		overflow   number  how much did not fit
		reason     string|nil  Enums.Reject value when nothing or not all fit
	}
]]
function Inventory.add(inventory, resourceId, amount, limits)
	limits = limits or {}
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 or type(resourceId) ~= "string" then
		return { added = 0, overflow = math.max(0, amount), reason = Enums.Reject.BadRequest }
	end

	inventory.items = inventory.items or {}
	local current = inventory.items[resourceId] or 0
	local allowed = amount

	-- Per-resource stack cap.
	if limits.stackLimit then
		allowed = math.min(allowed, math.max(0, limits.stackLimit - current))
	end

	-- Whole-inventory cap.
	if limits.capacity then
		local used, perUnit
		if limits.measure == "weight" then
			used = Inventory.totalWeight(inventory, limits.defs, limits.consumableDefs)
			local def = limits.defs and limits.defs[resourceId]
			perUnit = (def and def.weight) or 1
		else
			used = Inventory.totalUnits(inventory)
			perUnit = 1
		end
		if perUnit <= 0 then
			perUnit = 1
		end
		local room = math.floor(math.max(0, limits.capacity - used) / perUnit)
		allowed = math.min(allowed, room)
	end

	if allowed <= 0 then
		return { added = 0, overflow = amount, reason = Enums.Reject.InventoryFull }
	end

	inventory.items[resourceId] = current + allowed
	return {
		added = allowed,
		overflow = amount - allowed,
		reason = (allowed < amount) and Enums.Reject.InventoryFull or nil,
	}
end

function Inventory.addConsumable(inventory, consumableId, amount, limits)
	limits = limits or {}
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 or type(consumableId) ~= "string" then
		return { added = 0, overflow = math.max(0, amount), reason = Enums.Reject.BadRequest }
	end

	inventory.consumables = inventory.consumables or {}
	local current = inventory.consumables[consumableId] or 0
	local allowed = amount

	if limits.stackLimit then
		allowed = math.min(allowed, math.max(0, limits.stackLimit - current))
	end
	if limits.capacity then
		local used
		if limits.measure == "weight" then
			used = Inventory.totalWeight(inventory, limits.defs, limits.consumableDefs)
		else
			used = Inventory.totalUnits(inventory)
		end
		local def = limits.consumableDefs and limits.consumableDefs[consumableId]
		local perUnit = (limits.measure == "weight" and def and def.weight) or 1
		if perUnit <= 0 then
			perUnit = 1
		end
		allowed = math.min(allowed, math.floor(math.max(0, limits.capacity - used) / perUnit))
	end

	if allowed <= 0 then
		return { added = 0, overflow = amount, reason = Enums.Reject.InventoryFull }
	end

	inventory.consumables[consumableId] = current + allowed
	return {
		added = allowed,
		overflow = amount - allowed,
		reason = (allowed < amount) and Enums.Reject.InventoryFull or nil,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Removing
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Remove exactly `amount`, or nothing at all. Partial removal is never what a
     caller wants: a half-paid build cost is a duplication bug waiting to
     happen. ]]
function Inventory.remove(inventory, resourceId, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return { removed = 0, reason = Enums.Reject.BadRequest }
	end

	inventory.items = inventory.items or {}
	local current = inventory.items[resourceId] or 0
	if current < amount then
		return { removed = 0, reason = Enums.Reject.NotEnoughResources, short = amount - current }
	end

	local remaining = current - amount
	inventory.items[resourceId] = remaining > 0 and remaining or nil
	return { removed = amount }
end

function Inventory.removeConsumable(inventory, consumableId, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return { removed = 0, reason = Enums.Reject.BadRequest }
	end

	inventory.consumables = inventory.consumables or {}
	local current = inventory.consumables[consumableId] or 0
	if current < amount then
		return { removed = 0, reason = Enums.Reject.NotEnoughResources, short = amount - current }
	end

	local remaining = current - amount
	inventory.consumables[consumableId] = remaining > 0 and remaining or nil
	return { removed = amount }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cost checks and transactions
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Can this inventory pay `cost`?
	@param cost { [resourceId] = amount }
	@return boolean, { [resourceId] = shortfall }
]]
function Inventory.canAfford(inventory, cost)
	local missing = {}
	local ok = true
	for resourceId, amount in pairs(cost or {}) do
		local shortfall = amount - Inventory.count(inventory, resourceId)
		if shortfall > 0 then
			missing[resourceId] = shortfall
			ok = false
		end
	end
	return ok, missing
end

--[[
	Pay `cost` atomically. Either every line item is deducted or none is.

	This is the single chokepoint for spending resources. Every build, upgrade,
	repair and craft goes through it, which is what makes "no partial spend"
	a property of the system rather than a habit.
]]
function Inventory.pay(inventory, cost)
	local ok, missing = Inventory.canAfford(inventory, cost)
	if not ok then
		return { paid = false, reason = Enums.Reject.NotEnoughResources, missing = missing }
	end
	for resourceId, amount in pairs(cost or {}) do
		Inventory.remove(inventory, resourceId, amount)
	end
	return { paid = true }
end

--[[
	Merge `source` into `target`, respecting target limits.
	@return { moved = { [id] = n }, leftover = { [id] = n }, anyOverflow = bool }
]]
function Inventory.merge(target, source, limitsFor)
	local moved = {}
	local leftover = {}
	local anyOverflow = false

	--[[ Deterministic order so a storage-full merge always drops the same items
	     rather than a different subset each time. ]]
	local ids = {}
	for id in pairs(source.items or {}) do
		table.insert(ids, id)
	end
	table.sort(ids)

	for _, id in ipairs(ids) do
		local amount = source.items[id]
		local result = Inventory.add(target, id, amount, limitsFor and limitsFor(id) or nil)
		if result.added > 0 then
			moved[id] = result.added
		end
		if result.overflow > 0 then
			leftover[id] = result.overflow
			anyOverflow = true
		end
	end

	local consumableIds = {}
	for id in pairs(source.consumables or {}) do
		table.insert(consumableIds, id)
	end
	table.sort(consumableIds)

	for _, id in ipairs(consumableIds) do
		local amount = source.consumables[id]
		local result = Inventory.addConsumable(target, id, amount, limitsFor and limitsFor(id) or nil)
		if result.added > 0 then
			moved[id] = (moved[id] or 0) + result.added
		end
		if result.overflow > 0 then
			leftover[id] = (leftover[id] or 0) + result.overflow
			anyOverflow = true
		end
	end

	return { moved = moved, leftover = leftover, anyOverflow = anyOverflow }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Loss on failure
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Apply a death or timeout penalty to an expedition bag.

	@param keptFraction number 0..1 from DifficultyConfig
	@param protectedIds { [resourceId] = true }  never lost (e.g. ancient keys)
	@return { kept = inventory, lost = { [id] = n } }

	Rounding favours the player: a fraction of a unit is kept, not lost. Losing
	your last ancient key to a rounding rule would be the kind of thing that
	makes someone stop playing.
]]
function Inventory.applyLoss(inventory, keptFraction, protectedIds)
	keptFraction = math.clamp(tonumber(keptFraction) or 0, 0, 1)
	protectedIds = protectedIds or {}

	local kept = Inventory.new()
	local lost = {}

	local ids = {}
	for id in pairs(inventory.items or {}) do
		table.insert(ids, id)
	end
	table.sort(ids)

	for _, id in ipairs(ids) do
		local count = inventory.items[id]
		if protectedIds[id] then
			kept.items[id] = count
		else
			local keptCount = math.ceil(count * keptFraction)
			if keptCount > 0 then
				kept.items[id] = keptCount
			end
			local lostCount = count - keptCount
			if lostCount > 0 then
				lost[id] = lostCount
			end
		end
	end

	--[[ Consumables are used up or dropped entirely; carrying half a salve out
	     of a failed run is not a meaningful reward. ]]
	for id, count in pairs(inventory.consumables or {}) do
		lost[id] = (lost[id] or 0) + count
	end

	return { kept = kept, lost = lost }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Presentation helpers
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Stable, sorted array form for sending to the client or for display. ]]
function Inventory.toList(inventory, order)
	local list = {}
	if order then
		for _, id in ipairs(order) do
			local count = Inventory.count(inventory, id)
			if count > 0 then
				table.insert(list, { id = id, count = count })
			end
		end
	else
		local ids = {}
		for id in pairs(inventory.items or {}) do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ipairs(ids) do
			table.insert(list, { id = id, count = inventory.items[id] })
		end
	end
	return list
end

return Inventory
