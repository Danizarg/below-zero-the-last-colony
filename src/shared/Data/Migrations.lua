--[[
	Migrations.lua

	Versioned, forward-only profile migrations.

	Each step takes a profile at version N and returns it at version N+1. Steps
	run in order until the profile reaches GameConfig.DataVersion. A profile
	saved by a *newer* build than the running server is never downgraded — it is
	refused, and DataService puts the session in read-only mode rather than
	silently destroying data the running build does not understand.

	Adding a migration:
	  1. Add the field(s) to ProfileTemplate.
	  2. Bump GameConfig.DataVersion.
	  3. Append a step here whose `to` equals the new version.

	Reconciliation against the template happens after migration, so a step only
	needs to handle genuine transformations (renames, type changes, recomputed
	values), not new fields with sensible defaults.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local TableUtil = require(script.Parent.Parent.Util.TableUtil)

local Migrations = {}

Migrations.Target = GameConfig.DataVersion

--[[
	Steps are ordered by `to`. Each has:
	  to       number  the version this step produces
	  describe string  what it does, for the log
	  apply    function(profile) -> profile
]]
Migrations.Steps = {
	--[[ Version 1 is the initial schema, so there is nothing to migrate to it.
	     The first real entry will look like:

	     {
	         to = 2,
	         describe = "split colony.storage into storage + consumables",
	         apply = function(profile)
	             profile.colony.consumables = profile.colony.consumables or {}
	             for id, count in pairs(profile.colony.storage) do
	                 if CONSUMABLE_IDS[id] then
	                     profile.colony.consumables[id] = count
	                     profile.colony.storage[id] = nil
	                 end
	             end
	             return profile
	         end,
	     },
	]]
}

--[[
	Bring a profile up to the running build's schema version.

	@param profile table  decoded profile, mutated in place
	@return {
		ok        boolean
		profile   table
		from      number
		to        number
		applied   { string, ... }  descriptions of steps that ran
		reason    string|nil       set when ok is false
	}
]]
function Migrations.run(profile)
	if type(profile) ~= "table" then
		return { ok = false, reason = "profile is not a table" }
	end

	local from = tonumber(profile.version) or 1
	local applied = {}

	if from > Migrations.Target then
		--[[ Saved by a newer build. Refusing is the only safe option: writing a
		     downgraded profile would delete whatever the newer build added. ]]
		return {
			ok = false,
			profile = profile,
			from = from,
			to = Migrations.Target,
			applied = applied,
			reason = ("profile version %d is newer than this build's %d"):format(from, Migrations.Target),
		}
	end

	local current = from
	local guard = 0

	while current < Migrations.Target do
		guard += 1
		if guard > 64 then
			return {
				ok = false,
				profile = profile,
				from = from,
				to = current,
				applied = applied,
				reason = "migration chain did not terminate",
			}
		end

		local step
		for _, candidate in ipairs(Migrations.Steps) do
			if candidate.to == current + 1 then
				step = candidate
				break
			end
		end

		if not step then
			return {
				ok = false,
				profile = profile,
				from = from,
				to = current,
				applied = applied,
				reason = ("no migration step produces version %d"):format(current + 1),
			}
		end

		local ok, result = pcall(step.apply, profile)
		if not ok then
			return {
				ok = false,
				profile = profile,
				from = from,
				to = current,
				applied = applied,
				reason = ("step to version %d failed: %s"):format(step.to, tostring(result)),
			}
		end

		profile = result or profile
		current = step.to
		profile.version = current
		table.insert(applied, step.describe)
	end

	profile.version = Migrations.Target
	return { ok = true, profile = profile, from = from, to = Migrations.Target, applied = applied }
end

--[[
	Migrate, then fill in any fields the template has that this profile does not.
	This is the single entry point DataService uses on load.
]]
function Migrations.prepare(profile, template)
	local result = Migrations.run(profile)
	if not result.ok then
		return result
	end
	result.profile = TableUtil.reconcile(result.profile, template)
	return result
end

return Migrations
