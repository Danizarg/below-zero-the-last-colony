--[[
	AudioController.lua
	Creates the mixer, plays cues, and crossfades ambience with the clock.

	No asset IDs are invented anywhere in this project. Every cue in AudioConfig
	has `assetId = ""`, so this controller builds the whole graph — groups,
	Sound instances, volume envelopes, phase beds, random one-shots — and simply
	does not play a cue whose asset is empty. It reports the count once, so it is
	obvious that audio is wired but silent rather than broken.

	To ship audio: paste real asset IDs into AudioConfig.Cues. Nothing in this
	file changes.
]]

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local AudioConfig = require(Shared.Config.AudioConfig)

local AudioController = {}
AudioController.__index = AudioController

local CROSSFADE_SECONDS = 2.5

function AudioController.new(store)
	local self = setmetatable({}, AudioController)
	self.store = store
	self._groups = {}
	self._sounds = {}
	self._lastPlayed = {}
	self._currentBed = nil
	self._randomLoops = {}
	self._silentCueCount = 0
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Graph construction
-- ─────────────────────────────────────────────────────────────────────────────

function AudioController:_buildGroups()
	local container = Instance.new("Folder")
	container.Name = "BelowZeroAudio"
	container.Parent = SoundService

	--[[ Groups are created parentless-first so a child group can find its
	     parent regardless of table iteration order. ]]
	for name in pairs(AudioConfig.Groups) do
		local group = Instance.new("SoundGroup")
		group.Name = name
		group.Parent = container
		self._groups[name] = group
	end

	for name, spec in pairs(AudioConfig.Groups) do
		local group = self._groups[name]
		group.Volume = spec.volume or 1
		if spec.parent and self._groups[spec.parent] then
			--[[ SoundGroups nest by parenting, which is how a master volume
			     scales everything beneath it. ]]
			group.Parent = self._groups[spec.parent]
		end
	end

	self.container = container
end

function AudioController:_buildSounds()
	for name, cue in pairs(AudioConfig.Cues) do
		local sound = Instance.new("Sound")
		sound.Name = name
		sound.SoundId = cue.assetId or ""
		sound.Looped = cue.loop == true
		sound.Volume = cue.volume or 0.5
		sound.SoundGroup = self._groups[cue.group or "SFX"]
		sound.RollOffMode = Enum.RollOffMode.InverseTapered

		if cue.rolloff then
			sound.RollOffMinDistance = cue.rolloff[1]
			sound.RollOffMaxDistance = cue.rolloff[2]
		end

		--[[ Non-positional cues live on SoundService so they play at a constant
		     level; positional ones are cloned onto a part at play time. ]]
		sound.Parent = self.container

		if sound.SoundId == "" then
			self._silentCueCount += 1
		end

		self._sounds[name] = sound
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Playback
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Play a cue.

	@param name     string key in AudioConfig.Cues
	@param position Vector3|nil  when given, plays positionally from a temporary
	                             part so distance and occlusion apply
]]
function AudioController:play(name, position)
	local cue = AudioConfig.get(name)
	local template = self._sounds[name]
	if not cue or not template then
		return
	end

	--[[ A cue with no asset is a no-op, not an error. The graph is complete and
	     the hook is live; only the file is missing. ]]
	if template.SoundId == "" then
		return
	end

	if cue.cooldown then
		local last = self._lastPlayed[name] or 0
		if os.clock() - last < cue.cooldown then
			return
		end
		self._lastPlayed[name] = os.clock()
	end

	if cue.loop then
		if not template.IsPlaying then
			template:Play()
		end
		return
	end

	local sound = template:Clone()
	if cue.pitch then
		sound.PlaybackSpeed = cue.pitch[1] + math.random() * (cue.pitch[2] - cue.pitch[1])
	end

	if position then
		local anchor = Instance.new("Part")
		anchor.Name = "SoundAnchor"
		anchor.Size = Vector3.one
		anchor.Transparency = 1
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.Position = position
		anchor.Parent = workspace
		sound.Parent = anchor

		sound.Ended:Once(function()
			anchor:Destroy()
		end)
		task.delay(12, function()
			if anchor.Parent then
				anchor:Destroy()
			end
		end)
	else
		sound.Parent = self.container
		sound.Ended:Once(function()
			sound:Destroy()
		end)
		task.delay(12, function()
			if sound.Parent then
				sound:Destroy()
			end
		end)
	end

	sound:Play()
end

function AudioController:stop(name)
	local sound = self._sounds[name]
	if sound and sound.IsPlaying then
		sound:Stop()
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Ambience beds
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Crossfade to the ambience bed for a phase.

	The envelope is driven here rather than in config so a future dynamic mixer
	can replace just this function. `intensity` is applied as a volume
	multiplier, which is what makes night audibly heavier than day.
]]
function AudioController:setBed(phaseOrZone)
	local bed = AudioConfig.PhaseBeds[phaseOrZone]
	if not bed then
		return
	end

	if self._currentBed == bed.ambience then
		--[[ Same bed, different intensity: just retarget the volume. ]]
		local sound = self._sounds[bed.ambience]
		local cue = AudioConfig.get(bed.ambience)
		if sound and cue then
			self:_fade(sound, (cue.volume or 0.5) * (0.5 + bed.intensity * 0.5))
		end
		return
	end

	-- Fade out the old bed.
	if self._currentBed then
		local previous = self._sounds[self._currentBed]
		if previous then
			self:_fade(previous, 0, function()
				previous:Stop()
			end)
		end
	end

	self._currentBed = bed.ambience
	local sound = self._sounds[bed.ambience]
	local cue = AudioConfig.get(bed.ambience)
	if sound and cue and sound.SoundId ~= "" then
		sound.Volume = 0
		sound:Play()
		self:_fade(sound, (cue.volume or 0.5) * (0.5 + bed.intensity * 0.5))
	end

	if bed.sting then
		self:play(bed.sting)
	end

	self:_startRandomAmbience(phaseOrZone)
end

function AudioController:_fade(sound, target, onDone)
	local start = sound.Volume
	local elapsed = 0
	task.spawn(function()
		while elapsed < CROSSFADE_SECONDS do
			local delta = task.wait()
			elapsed += delta
			local alpha = math.clamp(elapsed / CROSSFADE_SECONDS, 0, 1)
			sound.Volume = start + (target - start) * alpha
		end
		sound.Volume = target
		if onDone then
			onDone()
		end
	end)
end

--[[ Random one-shots that make the caves feel occupied without a bespoke
     ambience track per room. One loop per phase, cancelled on phase change. ]]
function AudioController:_startRandomAmbience(phase)
	for _, cancel in ipairs(self._randomLoops) do
		cancel.cancelled = true
	end
	self._randomLoops = {}

	local entries = AudioConfig.RandomAmbience[phase]
	if not entries then
		return
	end

	for _, entry in ipairs(entries) do
		local token = { cancelled = false }
		table.insert(self._randomLoops, token)
		task.spawn(function()
			while not token.cancelled do
				local wait = entry.every[1] + math.random() * (entry.every[2] - entry.every[1])
				task.wait(wait)
				if token.cancelled then
					return
				end
				self:play(entry.cue)
			end
		end)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Settings
-- ─────────────────────────────────────────────────────────────────────────────

function AudioController:applySettings()
	local settings = self.store.state.settings or {}
	if self._groups.Music then
		self._groups.Music.Volume = (AudioConfig.Groups.Music.volume or 0.4)
			* (settings.musicVolume or 0.5)
			* 2
	end
	if self._groups.SFX then
		self._groups.SFX.Volume = (AudioConfig.Groups.SFX.volume or 0.8) * (settings.sfxVolume or 0.8)
	end
	if self._groups.Ambience then
		self._groups.Ambience.Volume = (AudioConfig.Groups.Ambience.volume or 0.55)
			* (settings.ambienceVolume or 0.6)
			* 1.6
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function AudioController:start()
	self:_buildGroups()
	self:_buildSounds()
	self:applySettings()

	if self._silentCueCount > 0 then
		--[[ Said once, plainly: the audio system is complete and wired, and
		     every cue is silent because the project ships with no sound assets.
		     Pretending otherwise would be the worse outcome. ]]
		print(
			("[BZ/Audio] %d of %d cues have no asset ID and will stay silent. "):format(
				self._silentCueCount,
				self._silentCueCount
			) .. "Paste real IDs into src/shared/Config/AudioConfig.lua to enable sound."
		)
	end

	self.store.soundRequested:Connect(function(payload)
		self:play(payload.cue, payload.position)
	end)

	self.store.changed:Connect(function(area)
		if area == "settings" or area == "meta" then
			self:applySettings()
		elseif area == "zone" then
			self:setBed(self.store.inExpedition() and (self.store.phase() or "day") or "prep")
		end
	end)

	self.store.phaseChanged:Connect(function(payload)
		self:setBed(payload.phase)
	end)

	--[[ Footsteps are driven locally rather than from the server: they are
	     purely cosmetic, and a remote per step would be absurd. ]]
	task.spawn(function()
		local player = Players.LocalPlayer
		while true do
			task.wait(0.28)
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if
				humanoid
				and humanoid.MoveDirection.Magnitude > 0.1
				and humanoid.FloorMaterial ~= Enum.Material.Air
			then
				self:play("footstep_stone")
			end
		end
	end)

	self:setBed("prep")
	return self
end

return AudioController
