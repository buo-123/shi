--!strict
-- Fully client side, just for show

--// Services
local Players = game:GetService("Players")
local Rs = game:GetService("ReplicatedStorage")
local SoundSerivce = game:GetService("SoundService")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")

--// Modules
local Debounce = require(Rs.Debounce)
local CONFIG = require(script.Parent.CONFIG)
local Fusion = require(Rs.Fusion)
local CameraShaker = require(Rs.CameraShaker)

--// Variables
local lp = game.Players.LocalPlayer
local tool = script.Parent	-- The Handle has CanQuery set to false
local camera = workspace.CurrentCamera
local barrelAtt = tool.Handle.Barrel	-- Attachment set at the exit posiiton of the launcher
local mouse = lp:GetMouse()
local missileTemplate = Rs.Missile	-- (model), meshpart canQuery is set to false
local explosionVFX = Rs.ExplosionVFX
local reloadThread: thread? = nil
local reloadSFX = SoundSerivce.Reload
local shootSFX = SoundSerivce.Lazer
local explosionSFX = SoundSerivce.Explosion
-- I chose a debounce module, for simplicity, and expandibility. Its very simple, and is very multifunctional.
local anyDebounce = Debounce.new(CONFIG.FireRate)	-- named it anyDebounce, because I decided later, that this should be used for anything (2 things). So 1 is enough.

-- Folder to store created objects
local junk = Instance.new("Folder")
junk.Name = "Junk"
junk.Parent = workspace

-- Init Camera Shake
local camShake = CameraShaker.new(Enum.RenderPriority.Camera.Value, function(shakeCFrame)
	camera.CFrame = camera.CFrame * shakeCFrame
end)
camShake:Start()


-- UI
local PlayerGui = lp.PlayerGui
local missileLauncerGUI = PlayerGui.MissleLauncher
local ammoContainer = missileLauncerGUI.AmmoContainer
local currentAmmoLabel = ammoContainer.CurrentAmmoLabel
local reservedAmmoLabel = ammoContainer.ReservedAmmoLabel

-- I will sync the ammo uis by taking adavantage of Fusion's state value objects.
local scope = Fusion.scoped(Fusion)
local peek = scope.peek
local ammo = scope:Value(CONFIG.Ammo)	-- Config.Ammo is the starting ammo
local reservedAmmo = scope:Value(CONFIG.ReservedAmmo)
local magazineSize = scope:Value(CONFIG.MagazineSize)

-- Whenever ammo is changd the text will change because its being hydrate to a state object Computed that by using its given "use" parameter will run whenever ammo is updated, updating text.
scope:Hydrate(currentAmmoLabel) {
	-- I set the text to a computed, so I can compute the formatted string, rather than set the text to just a number
	Text = scope:Computed(function(use, _)
		return string.format("%i / %i", use(ammo), peek(magazineSize))
	end)
}


-- Syncs reservedAmmo value to the text.
scope:Hydrate(reservedAmmoLabel) {
	-- Doesn't need a computed because I want the text to be just the number, so a computed is unnecessary
	Text = reservedAmmo
}

-- Custom camera preset
local onFireCameraPreset = {
	magnitude = 5, 
	roughness = 4,
	fadeIn = 0.08,
	fadeOut = 0.5,
	posInfluence = Vector3.new(0.14, 0.14, 0.14),
	rotInfluence = Vector3.new(.71, .71, .71),
}

-- Helper function to use custom camera presets.
local function useCameraPreset(preset)
	camShake:ShakeOnce(
		preset.magnitude,
		preset.roughness,
		preset.fadeIn,
		preset.fadeOut,
		preset.posInfluence,
		preset.rotInfluence
	)
end

-- Returns the position of bezier curve path using Quadratic Bezir curve formula:
-- B(t) = P1 + (1 - t)^2 * (P0 - P1) + t^2 * (P2 - P1),  0 <= t <= 1
-- I chose this formula because its easy to implement, uses 1 control point, and produces curves
local function quadBezier(t: number, p0: Vector3, p1: Vector3, p2: Vector3)
	-- Just follow the formula then return position at the given time.
	return p1 + (1 - t)^2 * (p0 - p1) + t^2 * (p2 - p1)
end

-- Function to get a appropiate control point so there is curve variety and noticable curves
local function getControlPoint(p0: Vector3, p2: Vector3): Vector3
	-- I get the bounding box so when I can get a controlled area relative to path of the projectile. 
	-- I extend the bounding box so there is a change for more extreme curves, and so the bounding box size doesn't limit seeing curves
	-- Because if the point a to point b is too short the box will be to small, so then the control point would be selected too close to the a to b line(which is what the bezier formula uses) resulting in a very small curve 
	local minPos = p0:Min(p2) - Vector3.one*25
	local maxPos = p0:Max(p2) + Vector3.one*25
	
	-- I increase the y value when doing math.random so a high y vector will be selected, to avoid sagging curves. 
	-- And curves that go up are more noticable then curves that go down. Considering the enviorment
	local p1 = Vector3.new(math.random(minPos.X, maxPos.X), math.random(minPos.Y + 18, maxPos.Y + 18), math.random(minPos.Z, maxPos.Z))
	
	return p1
end

local function createExplosionEffect(pos: Vector3)
	-- I create a new attachment at the end position, so I can parent the explosion SFX for spatial audio.
	local p2Att = Instance.new("Attachment")
	p2Att.WorldPosition = pos
	p2Att.Parent = workspace.Terrain
	
	local explosion = explosionVFX:Clone() -- is a part that has a bunch of emitters.
	explosion.Position = pos	-- i dont parent the explosion yet, but set its properties first so I only replicate once to the client.
	explosion.Parent = junk

	-- just enable the vfx based on how its structured.
	for _, emitter: ParticleEmitter in explosion:GetDescendants() do
		if not emitter:IsA("ParticleEmitter") then continue end	-- attachments
		local emitCount = emitter:GetAttribute("EmitCount")
		emitter:Emit(emitCount)
	end

	-- i don't use Debris, because its not efficient/outdated(according to a Roblox staff forum post). Arguably I could still make the destroy cleaner, with a debris func/module but this is sufficnet.
	task.delay(3, explosion.Destroy, explosion) -- I dont don't use the ":" opreator, because I need to send the functions address, not call the function.
	explosion = nil	-- gc, but the object still exists in memory, so task.delay still works

	-- Clone the explosion sfx, for overlapping sound effect.
	local sound = explosionSFX:Clone()
	sound:Play()
	sound.Parent = p2Att
	task.delay(3, sound.Destroy, sound) -- same reasoning already said
	sound = nil
	
	task.delay(5, p2Att.Destroy, p2Att)
end

local function onMissileImpact(missile: Model, pos: Vector3)
	-- I get rid of the missile because its no longer needed.
	missile:Destroy()

	-- VFX
	createExplosionEffect(pos)

	-- Now I get the distance frmo the imapct to decided If the clients camera should shake or not. 
	local char = lp.Character	-- since its a local script the player should still be in the game, if not and this still errors it doesn't matter since its a local script.
	if char and char:FindFirstChild("HumanoidRootPart") then	-- FindFirstChild() to check without erroring
		local hrp: Part = char.HumanoidRootPart
		local distance = (hrp.Position - pos).Magnitude

		if distance <= 300 then
			camShake:Shake(CameraShaker.Presets.Explosion)
		end
	end
end

local function _launchMissile(targetPos: Vector3)
	-- For quadaratic beziers you need 3 points, so just 1 control point(p1)
	local p0 = barrelAtt.WorldPosition
	local p2 = targetPos
	local p1 = getControlPoint(p0, p2)	-- i get p1 the control point last because, I need p0 and p2 to get a random point relative to projectile's path


	-- I want the missles to have a set speed that'll affect the missle time, instead of having a set time that'll affect the missle speed making it inconsistnet in varying distances.
	-- Although bezier curves don't have a constant speed. I'd prefer the curve to have a constant base speed relative to the arc/curve(Impacts the speed) no matter the distance. Than highly varying speeds in varying distances.

	-- I get the launchDistance to later use to calcuate the approiate duration according the the missle's speed. 
	local launchDistance = (p2 - p0).Magnitude
	-- I calculate the duration:
	-- CONFIG.FireSpeed is studs/per second
	-- launchDistance is the distance
	-- so duration is set to how many seconds it would take to reach the launchDistance in the speed.
	-- also formula for time is time = distance/speed anyway

	local duration = launchDistance / CONFIG.FireSpeed
	-- Elasped is elasped time missle has been running; a variable to keep track of time.
	local elasped = 0

	-- variable to store the rendering connection, so it can be cleaned up.
	local conn: RBXScriptConnection?

	local missile = missileTemplate:Clone()	-- I create a new missile object and yield to parent it until it begins to be in use. (PivotTo)

	-- I render the missle's path on a PreRender, because its a visual effect and so the missle is at the correct spot at the time of the client's frame(so they see accurate stuff)
	conn = RunService.PreRender:Connect(function(dt: number)	
		-- I keep track of how long the missle has been running.
		elasped += dt

		-- Quad Bezier's time is 0 to 1, so I just get the fraction completed (elasped / duration) which is basically what time is in the bezier formula
		local t = math.clamp(elasped / duration, 0, 1)	-- I clamp it incase the elasped time exceeds 1, because of frame times.

		-- I get the position to set the missle to at this current time.
		local pos1 = quadBezier(t, p0, p1, p2)

		-- But I need to face the missle to where its going to go next, so use the function and put in the supposed time for the next frame, which isn't the guranteed time, but is the expected frame time for 60 fps, which is smooth to render.
		local pos2 = quadBezier(t + 1/60, p0, p1, p2)

		-- Set the missles poisition, by pivoting the model.
		missile:PivotTo(CFrame.new(pos1, pos2)) -- I use pos2 as the lookat cframe

		-- Upon missle contact:
		if t >= 1 then
			onMissileImpact(missile, pos1)
			
			if conn then
				conn:Disconnect()
			end
			
			-- There is no need to set variables to nil because all local variables in this scope will have no references because the connection is canceled. And function is done. Closing the scopes.
			return
		end
	end)
	missile.Parent = junk	-- I parent the missile now so there is only 1 replication rather than replicating extra property changes when I was configuring the missile.

	--camShake:Shake(CameraShaker.Presets.Bump)
	useCameraPreset(onFireCameraPreset)	-- I use my specifc preset, because it better fits than CameraShaker's predefined presets.
	shootSFX:Play()	-- I'm worried about sound overlapping, because I yield for the missle rate
end

-- I don't want to check if there is ammo for each possible missile shot and updating the ammo value each iteration unnesscearily updating the ammo text. And this function is just targeted to do one specfic thing, which is to shoot missiles from the launcher. So I expect the given amount to checked in and accurate in fire().
local function launchMissiles(amount: number, targetPos: Vector3)
	ammo:set(peek(ammo) - amount)	-- Assumes amount is the actual amount of bullets that can actually be shot ^^^
	-- I update the ammo value which is a state value object, and since I used the "use" func in the Computed during the hydration of currAmmoLabel ui the computed function is reran updating the text
	
	-- I create a new thread so the current thread is not yielded to fire missiles and incase I would want to add anything after the missiles have begun firing.
	task.spawn(function()
		for i = 1, amount do
			_launchMissile(targetPos)
			
			task.wait(CONFIG.MissileRate)
		end
	end)
end

-- Reload speed is 1 second.
local function reload(actionName: string?, inputState: Enum.UserInputState?, inputObject: InputObject?): ()
	if actionName then	-- This should if statement is true when func is called from the binded action
		-- Verify key press.
		if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Sink end
	end
	
	if peek(ammo) == peek(magazineSize) then -- Check if already has enough ammo
		return
	end
	
	if reloadThread then	-- Check if already reloading
		return
	end
	
	if peek(reservedAmmo) <= 0 then	-- Check if you have ammo to reload
		print("Insufficient ammo")
		return
	end
	
	reloadSFX:Play()
	-- Wait reload speed time before giving ammo.
	reloadThread = task.delay(CONFIG.ReloadSpeed, function()
		-- To get the amount to reload, find the amount of ammo missing from magazine then find how much of that ammo I in reserve
		local ammoNeeded = peek(magazineSize) - peek(ammo)
		local reloadAmount = math.clamp(ammoNeeded, 0, peek(reservedAmmo))
		ammo:set(peek(ammo) + reloadAmount)
		reservedAmmo:set(peek(reservedAmmo) - reloadAmount)

		print("Reloaded")
		reloadThread = nil
	end)
end

local function fire()
	if reloadThread then	-- Shouldn't fire if currently reloading
		return
	end
	
	if peek(ammo) <= 0 then	-- Check if enough ammo
		-- If not ammo then don't fire, but reload
		reload()
		return
	end

	if anyDebounce:Contains(tool) then	-- Check if the tool is in the debounce. (checks if tool is in a table)
		return
	end
	
	local targetPos = mouse.Hit.Position
	
	-- Check if targetPos was shot out of range
	local char = lp.Character
	if char and char:FindFirstChild("HumanoidRootPart") then
		local distance = ((char.HumanoidRootPart:: Part).Position - targetPos).Magnitude
		if distance > CONFIG.Range then
			print("out of range")
			return
		end
	else
		return
	end
	
	-- After completing all checks now I consider the launcher should be prevented from shooting. Because its confirmed the shot will occur, and this is my wanted use for FireRate.
	anyDebounce:Add(tool)	-- This basically just puts the tool in a table and schedules it to be removed once the set debounce is over.
	
	-- Create a part to show the target.
	local part = Instance.new("Part")
	part.Color = Color3.new(1, 0, 0)
	part.Material = Enum.Material.Neon
	part.Size = Vector3.new(0.5,0.5,0.5)
	part.Position = targetPos
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Parent = junk	-- like said before I set parent last for performance
	task.delay(3, part.Destroy, part)	-- also explained before

	-- I check how much ammo there is and cap that value at the targeted spread, and I because of the if statements there must be at least 1 ammo, so loaded ammo  = missiles fired
	launchMissiles(math.clamp(CONFIG.Spread, 1, peek(ammo)), targetPos) -- since this func fires the missles, it should reduce the ammo

	
end

tool.Activated:Connect(fire)

tool.Equipped:Connect(function()
	-- I use this service to bind an action to a key rather than UserInputService, because this gives me more control, than just using if statements.
	-- Bind r to be the reload button, and you should only be able to reload with the launcher out, so I decided to bind it.
	ContextActionService:BindAction("ReloadLauncher", reload, true, Enum.KeyCode.R)
end)

tool.Unequipped:Connect(function()
	-- Unbind the reload key, because you should only have the launcher out to be able to reload.
	ContextActionService:UnbindAction("ReloadLauncher")
	
	if reloadThread then	-- Check if reloading, if so cancel it. Becaues your not equipping the tool anymore to be reloading it.
		task.cancel(reloadThread)
		reloadThread = nil	-- gc
		reloadSFX:Stop()	-- stop sound/stop reload
	end
end)

-- A way to get more bullets, very simple, but works.
-- I use a debounce, because I don't filter the touch event causing extra fires, and I don't want to over fire this function. Causing unneccessary peformance drawbacks.

local ammoRefiller = workspace:WaitForChild("AmmoRefiller")

ammoRefiller.Touched:Connect(function()
	-- I reuse the same debounce, because there is no need to create a new one, and use extra memory.
	if anyDebounce:Contains(ammoRefiller) then	
		return
	end
	
	reservedAmmo:set(CONFIG.ReservedAmmo)
	
	anyDebounce:Add(1)	-- I overwrite the wait time. But this ammoRefiller is very niche anyways.
end)
