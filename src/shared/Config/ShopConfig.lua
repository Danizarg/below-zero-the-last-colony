--[[
	ShopConfig.lua

	Cosmetics and one optional convenience product. Hard rules encoded here:

	  * No gambling. There are no crates, rolls, odds or randomised rewards.
	  * No pay-to-win. Every product's `gameplayEffect` is nil except the rescue,
	    which is capped and excluded from ranked. MonetizationService refuses to
	    fulfil any product declaring a gameplay effect other than "rescue".
	  * Nothing is purchasable until GameConfig.Monetization.Enabled is true AND
	    the product has a real non-zero id. Both are false/zero here on purpose.

	`productId` / `assetId` are 0 because the Developer Products and passes do not
	exist yet. Fill them in from the Creator Dashboard after the flow is verified.
]]

local Enums = require(script.Parent.Parent.Enums)

local ShopConfig = {}

ShopConfig.Category = {
	Skins = "skins",
	Lanterns = "lanterns",
	Decor = "decor",
	BuildingThemes = "building_themes",
	Emotes = "emotes",
	Utility = "utility",
	Pass = "pass",
}

ShopConfig.CategoryOrder = {
	ShopConfig.Category.Skins,
	ShopConfig.Category.Lanterns,
	ShopConfig.Category.Decor,
	ShopConfig.Category.BuildingThemes,
	ShopConfig.Category.Emotes,
	ShopConfig.Category.Utility,
	ShopConfig.Category.Pass,
}

ShopConfig.CategoryMeta = {
	[ShopConfig.Category.Skins] = { name = "Character Skins", icon = "☻" },
	[ShopConfig.Category.Lanterns] = { name = "Lanterns", icon = "✧" },
	[ShopConfig.Category.Decor] = { name = "Colony Decor", icon = "❖" },
	[ShopConfig.Category.BuildingThemes] = { name = "Building Themes", icon = "⌂" },
	[ShopConfig.Category.Emotes] = { name = "Emotes", icon = "♪" },
	[ShopConfig.Category.Utility] = { name = "Expedition", icon = "⛨" },
	[ShopConfig.Category.Pass] = { name = "Passes", icon = "★" },
}

--[[
	productType  "developer_product" (consumable) | "game_pass" (permanent)
	productId    DeveloperProductId or GamePassId. 0 = not created yet.
	grants       { cosmetics = {...}, slots = n, consumable = {...} }
	gameplayEffect  nil for all cosmetics. Only "rescue" is permitted, and only
	                for the single capped rescue product.
]]
ShopConfig.Products = {
	-- ── Cosmetic: character skins ───────────────────────────────────────────
	skin_deep_delver = {
		id = "skin_deep_delver",
		category = ShopConfig.Category.Skins,
		name = "Deep Delver",
		description = "Patched leathers and a soot-blackened mask.",
		productType = "game_pass",
		productId = 0,
		priceHint = 99,
		grants = { cosmetics = { "skin_deep_delver" } },
		gameplayEffect = nil,
		preview = { primary = Color3.fromRGB(74, 62, 52), accent = Color3.fromRGB(188, 142, 86) },
	},
	skin_vault_warden = {
		id = "skin_vault_warden",
		category = ShopConfig.Category.Skins,
		name = "Vault Warden",
		description = "Plating cut from something older than the colony.",
		productType = "game_pass",
		productId = 0,
		priceHint = 149,
		grants = { cosmetics = { "skin_vault_warden" } },
		gameplayEffect = nil,
		preview = { primary = Color3.fromRGB(92, 86, 108), accent = Color3.fromRGB(176, 196, 255) },
	},

	-- ── Cosmetic: lanterns ──────────────────────────────────────────────────
	lantern_emberglass = {
		id = "lantern_emberglass",
		category = ShopConfig.Category.Lanterns,
		name = "Emberglass Lantern",
		description = "Warm, slow flicker. Purely a look.",
		productType = "game_pass",
		productId = 0,
		priceHint = 49,
		grants = { cosmetics = { "lantern_emberglass" } },
		gameplayEffect = nil,
		--[[ Cosmetic lanterns must not change light radius or brightness; only
		     colour and flicker shape. Enforced in CosmeticService. ]]
		preview = { light = Color3.fromRGB(255, 180, 110) },
	},
	lantern_coldfire = {
		id = "lantern_coldfire",
		category = ShopConfig.Category.Lanterns,
		name = "Coldfire Lantern",
		description = "Blue-white and silent.",
		productType = "game_pass",
		productId = 0,
		priceHint = 49,
		grants = { cosmetics = { "lantern_coldfire" } },
		gameplayEffect = nil,
		preview = { light = Color3.fromRGB(176, 216, 255) },
	},

	-- ── Cosmetic: colony decor + themes ─────────────────────────────────────
	decor_bundle_hollow = {
		id = "decor_bundle_hollow",
		category = ShopConfig.Category.Decor,
		name = "Hollow Garden Bundle",
		description = "Six placeable decorations: glow pools, fungus arches, stone lanterns.",
		productType = "developer_product",
		productId = 0,
		priceHint = 129,
		grants = {
			cosmetics = {
				"decor_glow_pool",
				"decor_fungus_arch",
				"decor_stone_lantern",
				"decor_bone_totem",
				"decor_crystal_shard",
				"decor_banner",
			},
		},
		gameplayEffect = nil,
	},
	theme_old_stone = {
		id = "theme_old_stone",
		category = ShopConfig.Category.BuildingThemes,
		name = "Old Stone Theme",
		description = "Re-skins every building in carved grey stone.",
		productType = "game_pass",
		productId = 0,
		priceHint = 199,
		grants = { cosmetics = { "theme_old_stone" } },
		gameplayEffect = nil,
	},

	-- ── Cosmetic: emotes ────────────────────────────────────────────────────
	emote_pack_signals = {
		id = "emote_pack_signals",
		category = ShopConfig.Category.Emotes,
		name = "Signal Emotes",
		description = "Four emotes: point, regroup, hold, all-clear.",
		productType = "developer_product",
		productId = 0,
		priceHint = 79,
		grants = { cosmetics = { "emote_point", "emote_regroup", "emote_hold", "emote_allclear" } },
		gameplayEffect = nil,
	},

	-- ── Cosmetic slots ──────────────────────────────────────────────────────
	loadout_slots_2 = {
		id = "loadout_slots_2",
		category = ShopConfig.Category.Skins,
		name = "Two Extra Loadout Slots",
		description = "Saves two more cosmetic loadouts. Does not affect what you can carry.",
		productType = "game_pass",
		productId = 0,
		priceHint = 99,
		grants = { slots = 2 },
		gameplayEffect = nil,
	},

	-- ── Optional convenience ────────────────────────────────────────────────
	emergency_rescue = {
		id = "emergency_rescue",
		category = ShopConfig.Category.Utility,
		name = "Emergency Rescue",
		description = "Pulls you out of a failed expedition with your bag intact. "
			.. "A free rescue is always available first; this is for when it is spent.",
		productType = "developer_product",
		productId = 0,
		priceHint = 29,
		grants = { consumable = { id = "rescue", count = 1 } },
		--[[ The only permitted gameplay effect in the shop, and it is bounded:
		     capped per expedition, never required to keep playing, and disabled
		     in ranked modes. ]]
		gameplayEffect = "rescue",
		maxPerExpedition = 2,
		bannedInRanked = true,
	},

	-- ── Pass ────────────────────────────────────────────────────────────────
	explorers_pass = {
		id = "explorers_pass",
		category = ShopConfig.Category.Pass,
		name = "Explorer's Cosmetic Pass",
		description = "A season of cosmetic unlocks earned by playing. "
			.. "No gameplay bonuses, no shortcuts, no randomised rewards.",
		productType = "game_pass",
		productId = 0,
		priceHint = 399,
		grants = { cosmetics = { "pass_explorer_track" } },
		gameplayEffect = nil,
	},
}

ShopConfig.Order = {
	"skin_deep_delver",
	"skin_vault_warden",
	"lantern_emberglass",
	"lantern_coldfire",
	"decor_bundle_hollow",
	"theme_old_stone",
	"emote_pack_signals",
	"loadout_slots_2",
	"emergency_rescue",
	"explorers_pass",
}

--[[ Effects a product is allowed to declare. Anything else is a config bug and
     MonetizationService will refuse to fulfil it. ]]
ShopConfig.AllowedGameplayEffects = { rescue = true }

function ShopConfig.get(id)
	return ShopConfig.Products[id]
end

--[[ A product is live only when it has a real id and monetization is on. ]]
function ShopConfig.isPurchasable(id, monetizationEnabled)
	local product = ShopConfig.Products[id]
	if not product then
		return false, Enums.Reject.BadRequest
	end
	if not monetizationEnabled then
		return false, "monetization_disabled"
	end
	if (tonumber(product.productId) or 0) <= 0 then
		return false, "product_not_configured"
	end
	if product.gameplayEffect and not ShopConfig.AllowedGameplayEffects[product.gameplayEffect] then
		return false, "disallowed_effect"
	end
	return true
end

return ShopConfig
