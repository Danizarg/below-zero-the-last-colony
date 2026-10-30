--[[
	AtmosphereController.lua
	Lighting, fog and camera feel, driven by zone and phase.

	Everything here is client-side and purely presentational, which is the right
	place for it: the server has no business tweening Lighting properties, and
	each player's atmosphere can respond to where they are without any
	replication cost.

	What it does:
	  * Fades Lighting and Atmosphere between the colony's warm lantern light and
	    each biome's cave palette.
	  * Tightens fog and drops ambient light as the clock runs to night, which is
	    the main way "visibility decreases" is delivered.
	  * Adds a vignette that pulses red on damage and blue-white during a shift.
	  * Shakes the camera on a maze shift and on heavy hits, if the player has
	    not turned shake off.
	  * Gives nearby campfires a particle flame, capped by distance so a cavern
	    of nine colonies does not run nine particle systems.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local RoomConfig = require(Shared.Config.RoomConfig)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.Parent.UI.UIKit)

local AtmosphereController = {}
AtmosphereController.__index = AtmosphereController

--[[ Dark, but readable. The first look at this in Studio was a black frame
     with two lantern pools in it: ambient at ten percent, fog closing in from
     sixty studs, and every surface outside a light's range rendering as
     void. Underground should feel enclosed, not unlit. Ambient now carries
     the cavern shapes, the fog starts past the plot so the space reads as a
     space, and the lights (ColonyBuilder) reach each other. Lighting
     technology is Future (default.project.json), which is what makes point
     lights fall off and glint on Slate and Wood instead of flat-painting it. ]]
local COLONY_LOOK = {
	Ambient = Color3.fromRGB(58, 54, 62),
	OutdoorAmbient = Color3.fromRGB(64, 60, 70),
	Brightness = 1.2,
	FogColor = Color3.fromRGB(24, 21, 26),
	FogStart = 140,
	FogEnd = 700,
	ExposureCompensation = 0.35,
}

local PHASE_LOOK = {
	prep = { brightnessScale = 1, fogScale = 1.25, ambientScale = 1.15 },
	day = { brightnessScale = 1, fogScale = 1, ambientScale = 1 },
	dusk = { brightnessScale = 0.72, fogScale = 0.75, ambientScale = 0.75 },
	night = { brightnessScale = 0.42, fogScale = 0.5, ambientScale = 0.45 },
	ended = { brightnessScale = 0.6, fogScale = 0.8, ambientScale = 0.7 },
}

local FIRE_RADIUS = 140
local FIRE_SCAN_INTERVAL = 2

function AtmosphereController.new(store, shell)
	local self = setmetatable({}, AtmosphereController)
	self.store = store
	self.shell = shell
	self.player = Players.LocalPlayer
	self._shake = Vector3.zero
	self._shakeDecay = 0
	self._firesLit = {}
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lighting
-- ─────────────────────────────────────────────────────────────────────────────

function AtmosphereController:_ensureAtmosphere()
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	--[[ Haze and density carry most of the "underground" read. Glare and
	     decay are kept low because a cave has no sun to bloom. ]]
	atmosphere.Glare = 0
	atmosphere.Decay = Color3.fromRGB(56, 50, 46)
	self.atmosphere = atmosphere
	return atmosphere
end

function AtmosphereController:_tweenLighting(goal, duration)
	local info = TweenInfo.new(duration or 2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	TweenService:Create(Lighting, info, goal):Play()
end

function AtmosphereController:applyColonyLook()
	self:_tweenLighting({
		Ambient = COLONY_LOOK.Ambient,
		OutdoorAmbient = COLONY_LOOK.OutdoorAmbient,
		Brightness = COLONY_LOOK.Brightness,
		FogColor = COLONY_LOOK.FogColor,
		FogStart = COLONY_LOOK.FogStart,
		FogEnd = COLONY_LOOK.FogEnd,
		ExposureCompensation = COLONY_LOOK.ExposureCompensation,
	}, 2)

	local atmosphere = self:_ensureAtmosphere()
	TweenService:Create(atmosphere, TweenInfo.new(2), {
		Density = 0.28,
		Haze = 1.4,
		Color = Color3.fromRGB(96, 84, 70),
	}):Play()
end

--[[
	Cave look for a biome at a phase. The biome supplies the palette; the phase
	scales brightness, ambient and fog distance. Night is roughly half as bright
	with half the draw distance, which is what makes being caught out there
	frightening rather than merely inconvenient.
]]
function AtmosphereController:applyCaveLook(biomeId, phase)
	local biome = RoomConfig.biome(biomeId)
	local look = PHASE_LOOK[phase] or PHASE_LOOK.day

	self:_tweenLighting({
		Ambient = Color3.new(
			biome.ambientLight.R * look.ambientScale,
			biome.ambientLight.G * look.ambientScale,
			biome.ambientLight.B * look.ambientScale
		),
		OutdoorAmbient = Color3.new(
			biome.ambientLight.R * look.ambientScale * 0.8,
			biome.ambientLight.G * look.ambientScale * 0.8,
			biome.ambientLight.B * look.ambientScale * 0.8
		),
		Brightness = 0.45 * look.brightnessScale,
		FogColor = biome.fogColor,
		FogStart = 18,
		FogEnd = biome.fogEnd * look.fogScale,
		ExposureCompensation = 0.2,
	}, 3)

	local atmosphere = self:_ensureAtmosphere()
	TweenService:Create(atmosphere, TweenInfo.new(3), {
		Density = 0.42 + (1 - look.fogScale) * 0.2,
		Haze = 1.6,
		Color = biome.fogColor,
	}):Play()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Vignette
-- ─────────────────────────────────────────────────────────────────────────────

function AtmosphereController:_buildVignette()
	--[[ Four edge gradients rather than one full-screen frame, so the centre of
	     the screen is never tinted and the player can still see. ]]
	local host = UIKit.frame({
		name = "Vignette",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		zIndex = Theme.ZIndex.HUD - 1,
		parent = self.shell.hudHost,
	})

	local edges = {}
	local specs = {
		{ size = UDim2.new(1, 0, 0, 130), position = UDim2.new(), rotation = 90 },
		{ size = UDim2.new(1, 0, 0, 130), position = UDim2.new(0, 0, 1, -130), rotation = 270 },
		{ size = UDim2.new(0, 160, 1, 0), position = UDim2.new(), rotation = 0 },
		{ size = UDim2.new(0, 160, 1, 0), position = UDim2.new(1, -160, 0, 0), rotation = 180 },
	}

	for index, spec in ipairs(specs) do
		local edge = UIKit.frame({
			name = "Edge" .. index,
			size = spec.size,
			position = spec.position,
			color = Theme.Color.Void,
			transparency = 1,
			parent = host,
		})
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = spec.rotation
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = edge
		table.insert(edges, edge)
	end

	self._vignetteEdges = edges
	self._vignetteHost = host
end

--[[ Flash the screen edges a colour. Used for damage, the Stalker's attention
     and the maze shift. ]]
function AtmosphereController:flash(color, strength, duration)
	if not self._vignetteEdges then
		return
	end
	for _, edge in ipairs(self._vignetteEdges) do
		edge.BackgroundColor3 = color
		edge.BackgroundTransparency = 1 - math.clamp(strength, 0, 1)
		UIKit.tween(edge, { BackgroundTransparency = 1 }, duration or 0.8)
	end
end

--[[ A steady edge darkening that tracks health, so low health is visible
     without looking at the bar. ]]
function AtmosphereController:setHealthVignette(fraction)
	if not self._vignetteEdges then
		return
	end
	local strength = fraction < 0.45 and (0.45 - fraction) * 1.1 or 0
	for _, edge in ipairs(self._vignetteEdges) do
		edge.BackgroundColor3 = Theme.Color.Health
		edge.BackgroundTransparency = 1 - math.clamp(strength, 0, 0.5)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Camera shake
-- ─────────────────────────────────────────────────────────────────────────────

function AtmosphereController:shake(magnitude, decay)
	if self.store.state.settings and self.store.state.settings.screenShake == false then
		return
	end
	self._shake = Vector3.new(
		(math.random() - 0.5) * magnitude,
		(math.random() - 0.5) * magnitude,
		(math.random() - 0.5) * magnitude * 0.4
	)
	self._shakeDecay = decay or 3
end

function AtmosphereController:_applyShake(deltaTime)
	if self._shake.Magnitude < 0.001 then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	--[[ Offsetting CFrame directly fights the camera scripts, so this nudges
	     the camera each frame and lets the decay return it to centre. ]]
	camera.CFrame = camera.CFrame
		* CFrame.new(self._shake.X, self._shake.Y, 0)
		* CFrame.Angles(0, 0, math.rad(self._shake.Z))

	self._shake = self._shake:Lerp(Vector3.zero, math.clamp(deltaTime * self._shakeDecay, 0, 1))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Campfire flames
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Give nearby campfires a particle flame.

	The server marks the flame part with an IsCampfire attribute and nothing
	else; particles are added here, only within FIRE_RADIUS, and removed when
	the player walks away. A cavern of nine colonies would otherwise run nine
	emitters the player cannot even see.
]]
function AtmosphereController:_updateFires()
	local character = self.player.Character
	local root = character and character.PrimaryPart
	if not root then
		return
	end

	local colony = workspace:FindFirstChild("Colony")
	if not colony then
		return
	end

	for _, descendant in ipairs(colony:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant:GetAttribute("IsCampfire") then
			local distance = (descendant.Position - root.Position).Magnitude
			local emitter = descendant:FindFirstChildOfClass("ParticleEmitter")

			if distance <= FIRE_RADIUS and not emitter then
				emitter = Instance.new("ParticleEmitter")
				emitter.Name = "Flame"
				emitter.Rate = 26
				emitter.Lifetime = NumberRange.new(0.5, 1.1)
				emitter.Speed = NumberRange.new(5, 9)
				emitter.SpreadAngle = Vector2.new(14, 14)
				emitter.Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 2.6),
					NumberSequenceKeypoint.new(1, 0),
				})
				emitter.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.2),
					NumberSequenceKeypoint.new(1, 1),
				})
				emitter.Color = ColorSequence.new(Color3.fromRGB(255, 196, 96), Color3.fromRGB(226, 96, 40))
				emitter.LightEmission = 0.8
				emitter.Acceleration = Vector3.new(0, 14, 0)
				emitter.Parent = descendant
			elseif distance > FIRE_RADIUS * 1.2 and emitter then
				emitter:Destroy()
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function AtmosphereController:start()
	self:_buildVignette()
	self:applyColonyLook()

	local lastHealth = self.store.state.stats.health

	self.store.changed:Connect(function(area)
		if area == "zone" then
			if self.store.inExpedition() then
				--[[ biomeId comes from the ZoneChanged push; RoomConfig.biome
				     falls back to the shallowest biome if it is missing, so the
				     lighting is never left at colony values underground. ]]
				self:applyCaveLook(self.store.state.biomeId, self.store.phase() or "day")
			else
				self:applyColonyLook()
			end
		elseif area == "stats" then
			local health = self.store.state.stats.health
			local maxHealth = math.max(1, self.store.state.stats.maxHealth)
			if health < lastHealth then
				--[[ Hit feedback: a red edge flash scaled to the damage, plus a
				     shake for anything substantial. ]]
				local lost = (lastHealth - health) / maxHealth
				self:flash(Theme.Color.Health, math.clamp(lost * 2, 0.15, 0.6), 0.6)
				if lost > 0.12 then
					self:shake(math.clamp(lost * 2.5, 0.1, 0.7), 4)
				end
			end
			lastHealth = health
			self:setHealthVignette(health / maxHealth)
		end
	end)

	self.store.phaseChanged:Connect(function(payload)
		if self.store.inExpedition() then
			self:applyCaveLook(self.store.state.biomeId, payload.phase)
		end
	end)

	self.store.shiftWarned:Connect(function()
		self:shake(0.35, 2)
	end)

	self.store.shiftApplied:Connect(function()
		--[[ The shift is the loudest moment in the game: a hard shake and a cold
		     flash, so it registers physically and not just as text. ]]
		self:shake(1.6, 1.4)
		self:flash(Color3.fromRGB(170, 190, 255), 0.55, 1.6)
	end)

	RunService.RenderStepped:Connect(function(deltaTime)
		self:_applyShake(deltaTime)
	end)

	task.spawn(function()
		while true do
			task.wait(FIRE_SCAN_INTERVAL)
			local ok, err = pcall(function()
				if not self.store.inExpedition() then
					self:_updateFires()
				end
			end)
			if not ok then
				warn("[BZ/Atmosphere] fire update failed: " .. tostring(err))
			end
		end
	end)

	return self
end

return AtmosphereController
