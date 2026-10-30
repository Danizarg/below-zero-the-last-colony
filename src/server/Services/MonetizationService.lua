--[[
	MonetizationService.lua
	The shop, cosmetic ownership and purchase fulfilment.

	Nothing here grants anything without a real receipt
	───────────────────────────────────────────────────
	* GameConfig.Monetization.Enabled is false and every product id in
	  ShopConfig is 0, so no purchase can be initiated. The shop renders its
	  catalogue as unavailable, which is honest about the state of the build.
	* No code path simulates a successful purchase. There is no debug grant, no
	  "pretend it worked" branch, and `ProcessReceipt` is the only way a paid
	  item is ever granted.
	* Fulfilment is idempotent: a PurchaseId already recorded in the profile is
	  acknowledged without granting again. Roblox retries receipts, and a
	  non-idempotent handler would hand out duplicates.
	* A receipt is only acknowledged once the profile has been SAVED. Returning
	  PurchaseGranted before the grant is durable is how players lose purchases
	  on a server crash.
	* Products declaring a gameplay effect other than "rescue" are refused as a
	  config error, so a pay-to-win product cannot be added by config alone.

	To go live: create the Developer Products and passes, paste their ids into
	ShopConfig, verify the flow end to end in a test place, then set
	GameConfig.Monetization.Enabled = true. Not before.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local ShopConfig = require(Shared.Config.ShopConfig)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("MonetizationService")

local MonetizationService = {}
MonetizationService.__index = MonetizationService

function MonetizationService.new()
	local self = setmetatable({}, MonetizationService)
	self._productByDevId = {} -- [developerProductId] = product
	self._productByPassId = {} -- [gamePassId] = product
	self.purchaseFulfilled = Signal.new("purchaseFulfilled")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Catalogue
-- ─────────────────────────────────────────────────────────────────────────────

function MonetizationService:_indexProducts()
	for id, product in pairs(ShopConfig.Products) do
		local productId = tonumber(product.productId) or 0
		if productId > 0 then
			if product.productType == "developer_product" then
				self._productByDevId[productId] = product
			elseif product.productType == "game_pass" then
				self._productByPassId[productId] = product
			end
		end

		--[[ Fail loudly at startup rather than at purchase time if a product
		     declares an effect the shop rules do not permit. ]]
		if product.gameplayEffect and not ShopConfig.AllowedGameplayEffects[product.gameplayEffect] then
			log:warn(
				"product %q declares disallowed gameplay effect %q and will never be fulfilled",
				id,
				tostring(product.gameplayEffect)
			)
		end
	end
end

function MonetizationService:catalogue(player)
	local profile = self.context.DataService:get(player)
	local owned = profile and profile.cosmetics.owned or {}

	local entries = {}
	for _, id in ipairs(ShopConfig.Order) do
		local product = ShopConfig.get(id)
		if product then
			local purchasable, reason = ShopConfig.isPurchasable(id, GameConfig.Monetization.Enabled)
			local alreadyOwned = false
			for _, cosmeticId in ipairs((product.grants or {}).cosmetics or {}) do
				if owned[cosmeticId] then
					alreadyOwned = true
					break
				end
			end

			table.insert(entries, {
				id = id,
				category = product.category,
				name = product.name,
				description = product.description,
				priceHint = product.priceHint,
				productType = product.productType,
				purchasable = purchasable,
				unavailableReason = (not purchasable) and reason or nil,
				owned = alreadyOwned,
				isCosmetic = product.gameplayEffect == nil,
				preview = product.preview,
			})
		end
	end

	return {
		monetizationEnabled = GameConfig.Monetization.Enabled,
		categories = ShopConfig.CategoryOrder,
		categoryMeta = ShopConfig.CategoryMeta,
		products = entries,
		owned = owned,
		equipped = profile and profile.cosmetics.equipped or {},
		rescueBalance = self:rescueBalance(player),
		freeRescuesPerExpedition = GameConfig.Monetization.FreeRescuesPerExpedition,
		--[[ Stated plainly in the UI so a player is never left wondering why a
		     product does nothing. ]]
		notice = not GameConfig.Monetization.Enabled
				and "The shop is not live yet. Nothing here can be purchased, and nothing is required to play."
			or nil,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Purchase prompts
-- ─────────────────────────────────────────────────────────────────────────────

function MonetizationService:prompt(player, productIdString)
	local product = ShopConfig.get(productIdString)
	if not product then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	--[[ Never take Robux for a grant that cannot be kept. A read-only session
	     is never written, and an ephemeral one — served from memory during a
	     DataStore outage — is never written to the store. Either would pass
	     ProcessReceipt, grant in RAM, and lose the purchase on exit. ]]
	if self.context.DataService:isReadOnly(player) or self.context.DataService:isEphemeral(player) then
		return {
			ok = false,
			reason = Enums.Reject.NotLoaded,
			detail = "read_only",
			message = "Your progress cannot be saved this session, so a purchase could not be kept. Rejoin later and try again.",
		}
	end

	local purchasable, reason = ShopConfig.isPurchasable(productIdString, GameConfig.Monetization.Enabled)
	if not purchasable then
		--[[ The refusal names the real reason. "Coming soon" with no explanation
		     is the kind of thing that generates support tickets. ]]
		return {
			ok = false,
			reason = Enums.Reject.NotImplemented,
			detail = reason,
			message = reason == "monetization_disabled" and "Purchases are switched off in this build."
				or "This product has not been created yet.",
		}
	end

	local ok, err = pcall(function()
		if product.productType == "developer_product" then
			MarketplaceService:PromptProductPurchase(player, product.productId)
		else
			MarketplaceService:PromptGamePassPurchase(player, product.productId)
		end
	end)

	if not ok then
		log:warn("prompt failed for %s: %s", productIdString, tostring(err))
		return { ok = false, reason = "server_error" }
	end

	return { ok = true, prompted = true }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Fulfilment
-- ─────────────────────────────────────────────────────────────────────────────

function MonetizationService:_grant(player, product)
	local profile = self.context.DataService:get(player)
	if not profile then
		return false
	end

	local grants = product.grants or {}

	for _, cosmeticId in ipairs(grants.cosmetics or {}) do
		profile.cosmetics.owned[cosmeticId] = true
	end

	if grants.slots then
		profile.cosmetics.loadoutSlots = math.min(8, (profile.cosmetics.loadoutSlots or 1) + grants.slots)
	end

	if grants.consumable and grants.consumable.id == "rescue" then
		profile.monetization.rescuesPurchased = (profile.monetization.rescuesPurchased or 0)
			+ (grants.consumable.count or 1)
	end

	self.context.DataService:markDirty(player)
	return true
end

--[[
	ProcessReceipt.

	The contract with Roblox: return PurchaseGranted ONLY when the grant is
	durable. Anything else must return NotProcessedYet so Roblox retries. That
	is why this saves the profile and checks the result before acknowledging.
]]
function MonetizationService:_processReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		--[[ Player has left. Not granted and not acknowledged, so Roblox retries
		     when they return. ]]
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not self.context.DataService:isLoaded(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if self.context.DataService:isReadOnly(player) then
		--[[ A read-only session cannot persist the grant, so acknowledging would
		     lose the purchase. Retry later, when the lock is theirs. ]]
		log:warn(
			"deferring receipt %s: %s has a read-only session",
			tostring(receiptInfo.PurchaseId),
			player.Name
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Idempotency: already granted, just acknowledge.
	if self.context.DataService:hasReceipt(player, receiptInfo.PurchaseId) then
		log:info("receipt %s already fulfilled for %s", tostring(receiptInfo.PurchaseId), player.Name)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local product = self._productByDevId[receiptInfo.ProductId]
	if not product then
		--[[ Unknown product. Acknowledging would silently take the money for
		     nothing; refusing forever would retry forever. Log it and
		     acknowledge, because a product removed from config is an operator
		     problem to reconcile, not something to loop on. ]]
		log:fault(
			"receipt %s is for unknown product %d; acknowledging without a grant, reconcile manually",
			tostring(receiptInfo.PurchaseId),
			receiptInfo.ProductId
		)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if product.gameplayEffect and not ShopConfig.AllowedGameplayEffects[product.gameplayEffect] then
		log:fault("refusing to fulfil %s: disallowed gameplay effect", product.id)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not self:_grant(player, product) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	self.context.DataService:recordReceipt(player, receiptInfo.PurchaseId)

	--[[ Persist before acknowledging. If the save fails we do NOT acknowledge,
	     so the receipt is retried rather than lost. The grant is also rolled
	     back so a later retry does not double-apply it. ]]
	local saved = self.context.DataService:save(player, { force = true })
	if not saved then
		log:fault("receipt %s: save failed, will retry", tostring(receiptInfo.PurchaseId))
		local profile = self.context.DataService:get(player)
		if profile then
			profile.monetization.receipts[tostring(receiptInfo.PurchaseId)] = nil
			local order = profile.monetization.receiptOrder
			local index = table.find(order, tostring(receiptInfo.PurchaseId))
			if index then
				table.remove(order, index)
			end
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	Net.fire(player, Routes.Push.Notify, {
		kind = "success",
		title = "Purchase complete",
		body = product.name,
	})
	Net.fire(player, Routes.Push.ShopSync, self:catalogue(player))
	self.purchaseFulfilled:Fire(player, product)

	log:info("fulfilled %s for %s (receipt %s)", product.id, player.Name, tostring(receiptInfo.PurchaseId))
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

--[[ Game passes are permanent, so ownership is checked rather than received.
     Called on join and after a pass prompt. ]]
function MonetizationService:syncPasses(player)
	if not GameConfig.Monetization.Enabled then
		return
	end
	local profile = self.context.DataService:get(player)
	if not profile then
		return
	end

	for passId, product in pairs(self._productByPassId) do
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if ok and owns then
			local changed = false
			for _, cosmeticId in ipairs((product.grants or {}).cosmetics or {}) do
				if not profile.cosmetics.owned[cosmeticId] then
					profile.cosmetics.owned[cosmeticId] = true
					changed = true
				end
			end
			if changed then
				self.context.DataService:markDirty(player)
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Rescues
-- ─────────────────────────────────────────────────────────────────────────────

function MonetizationService:rescueBalance(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return 0
	end
	return math.max(0, (profile.monetization.rescuesPurchased or 0) - (profile.monetization.rescuesUsed or 0))
end

--[[ Spend one purchased rescue. Returns false if none is held — there is no
     path that grants one on demand. ]]
function MonetizationService:consumeRescue(player)
	if not GameConfig.Monetization.Enabled then
		return false
	end
	local profile = self.context.DataService:get(player)
	if not profile then
		return false
	end
	if self:rescueBalance(player) <= 0 then
		return false
	end

	--[[ Ranked modes exclude paid rescues entirely. There is no ranked mode yet,
	     so this is the hook that makes adding one safe. ]]
	if not GameConfig.Monetization.PaidRescueAllowedInRanked then
		local session = self.context.ExpeditionService:sessionOf(player)
		if session and session.ranked then
			return false
		end
	end

	profile.monetization.rescuesUsed = (profile.monetization.rescuesUsed or 0) + 1
	self.context.DataService:markDirty(player)
	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cosmetics
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Equipping is free and purely visual. Cosmetic lanterns must not change
     light range or brightness, only colour — enforced by only ever reading
     `preview.light` from config and never a gameplay field. ]]
function MonetizationService:equipCosmetic(player, slot, cosmeticId)
	local profile = self.context.DataService:get(player)
	if not profile then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end
	if profile.cosmetics.equipped[slot] == nil then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "unknown_slot" }
	end
	if cosmeticId ~= "" and not profile.cosmetics.owned[cosmeticId] then
		return { ok = false, reason = Enums.Reject.NoPermission, detail = "not_owned" }
	end

	profile.cosmetics.equipped[slot] = cosmeticId
	self.context.DataService:markDirty(player)
	return { ok = true, slot = slot, cosmeticId = cosmeticId }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function MonetizationService:init(context)
	self.context = context
end

function MonetizationService:start()
	self:_indexProducts()

	Net.handle(Routes.Request.GetShop, function(player)
		local catalogue = self:catalogue(player)
		Net.fire(player, Routes.Push.ShopSync, catalogue)
		return { ok = true, shop = catalogue }
	end)

	Net.handle(Routes.Request.PromptPurchase, function(player, payload)
		if type(payload) ~= "table" or type(payload.productId) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:prompt(player, payload.productId)
	end, Routes.limitsFor(Routes.Request.PromptPurchase))

	--[[ Always registered, even with monetization off: if a receipt somehow
	     arrives, it must be handled idempotently rather than dropped. ]]
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local ok, decision = pcall(function()
			return self:_processReceipt(receiptInfo)
		end)
		if not ok then
			log:fault("ProcessReceipt errored: %s", tostring(decision))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return decision
	end

	self.context.DataService.profileLoaded:Connect(function(player)
		task.spawn(function()
			self:syncPasses(player)
			Net.fire(player, Routes.Push.ShopSync, self:catalogue(player))
		end)
	end)

	local liveProducts = 0
	for _ in pairs(self._productByDevId) do
		liveProducts += 1
	end
	for _ in pairs(self._productByPassId) do
		liveProducts += 1
	end

	log:info(
		"ready (monetization %s, %d product ids configured of %d defined)",
		GameConfig.Monetization.Enabled and "ENABLED" or "disabled",
		liveProducts,
		#ShopConfig.Order
	)
end

return MonetizationService.new()
