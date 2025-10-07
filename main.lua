-- Optimized Universal UD-safe ESP + aggressive aimbot
-- Features:
--  • Optimized Box + Skeleton ESP (shallow part caching + projection cache)
--  • FOV circle + watermark
--  • Toggle: Insert = FOV, End = ESP
--  • Aggressive aim modes: "smooth", "lock", "camlock"
--  • Auto-detects mouse mover (uses it for "smooth" and "lock" modes)
--  • Silent aim and wallbangall(toggle with homekey)
--  • Inf jump/crappy fly (togglable with k key)

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

-- ===== CONFIG =====
local FOVPixelRadius    = 120        -- pixels
local ESP_UPDATE_RATE   = 2          -- update ESP every N frames (1 = every frame)
local AIM_ENABLED       = true
local AIM_MODE          = "lock"     -- "smooth", "lock", "camlock"
local AIM_STRENGTH      = 0.8        -- 0..1 (higher = more aggressive)
local LOCK_STEPS        = 3          -- number of mover calls per frame in "lock" mode
local CAMLOCK_USE       = false      -- if true, camlock will set Camera.CameraType = Scriptable while aiming
local AIM_KEY           = Enum.UserInputType.MouseButton2
local IGNORE_TEAM       = true

-- Visuals
local BOX_COLOR         = Color3.fromRGB(0, 255, 0)
local SKELETON_COLOR    = Color3.fromRGB(255, 255, 255)
local FOV_COLOR         = Color3.fromRGB(255, 0, 0)
local WATERMARK_COLOR   = Color3.fromRGB(255, 255, 255)

-- Bones (for skeleton)
local BONES = {
	{"Head","UpperTorso"},
	{"UpperTorso","LowerTorso"},
	{"LowerTorso","LeftUpperLeg"},
	{"LowerTorso","RightUpperLeg"},
	{"UpperTorso","LeftUpperArm"},
	{"UpperTorso","RightUpperArm"}
}

-- ===== DRAWING SETUP =====
local fov = Drawing.new("Circle")
fov.Thickness = 2
fov.Filled = false
fov.Radius = FOVPixelRadius
fov.Color = FOV_COLOR
fov.Visible = true

local watermark = Drawing.new("Text")
watermark.Text = "kernelhook.xyz"
watermark.Size = 18
watermark.Color = WATERMARK_COLOR
watermark.Position = Vector2.new(18, 18)
watermark.Outline = true
watermark.Visible = true

-- ===== STATE =====
-- playersData[p] = {
--    box = DrawingSquare,
--    skeleton = { {from=,to=,line=}, ... },
--    partList = {BasePart,...},   -- shallow structural cache
--    projCache = { [part] = {x=,y=,v=}, ... }  -- per-frame projection cache
-- }
local playersData = {}

-- ===== UTILITIES =====
local function IsTeammate(p)
	if not IGNORE_TEAM then return false end
	if LocalPlayer and LocalPlayer.Team and p and p.Team then
		return LocalPlayer.Team == p.Team
	end
	return false
end

local function safeFind(char, names)
	if not char then return nil end
	for i = 1, #names do
		local part = char:FindFirstChild(names[i])
		if part and part:IsA("BasePart") then return part end
	end
	return nil
end

local function findHeadLike(char)
	return safeFind(char, {"Head","head","UpperTorso","Torso"})
end
local function findTorsoLike(char)
	return safeFind(char, {"UpperTorso","LowerTorso","Torso","torso"})
end

-- shallow part list builder (cheap)
local function buildShallowPartList(char)
	local out = {}
	if not char then return out end
	for _, child in ipairs(char:GetChildren()) do
		if child:IsA("BasePart") then
			out[#out+1] = child
		elseif child:IsA("Accessory") then
			local h = child:FindFirstChild("Handle")
			if h and h:IsA("BasePart") then out[#out+1] = h end
		else
			-- include immediate baseparts under models/folders
			if child:IsA("Model") or child:IsA("Folder") then
				for _, cc in ipairs(child:GetChildren()) do
					if cc:IsA("BasePart") then out[#out+1] = cc end
				end
			end
		end
	end
	return out
end

-- ===== MOUSE MOVER DETECTION =====
local function detectMouseMover()
	-- check common global names
	local candidates = {"mousemoverel", "syn_mousemoverel", "mousemove", "move_mouse"}
	for _, name in ipairs(candidates) do
		local f = rawget(_G, name) or _G[name]
		if type(f) == "function" then
			local ok = pcall(function() f(0.001, 0.001) end)
			if ok then return function(dx, dy) pcall(f, dx, dy) end end
		end
	end
	-- try syn table
	if type(syn) == "table" and type(syn.mousemoverel) == "function" then
		return function(dx, dy) pcall(syn.mousemoverel, dx, dy) end
	end
	-- nothing found
	return nil
end

local MOUSE_MOVER = detectMouseMover()
if not MOUSE_MOVER then
	-- try fallback without pcall
	if type(mousemoverel) == "function" then
		MOUSE_MOVER = function(dx,dy) pcall(mousemoverel, dx, dy) end
	end
end

-- ===== PLAYER VISUALS MANAGEMENT =====
local function createPlayerVisuals(p)
	if playersData[p] then return end
	local box = Drawing.new("Square")
	box.Visible = true
	box.Filled = false
	box.Color = BOX_COLOR
	box.Thickness = 1.5

	local skeleton = {}
	for i = 1, #BONES do
		local ln = Drawing.new("Line")
		ln.Visible = true
		ln.Thickness = 1.2
		ln.Color = SKELETON_COLOR
		skeleton[i] = { from = BONES[i][1], to = BONES[i][2], line = ln }
	end

	playersData[p] = {
		box = box,
		skeleton = skeleton,
		partList = {},
		projCache = {}
	}
end

local function removePlayerVisuals(p)
	local data = playersData[p]
	if not data then return end
	pcall(function()
		if data.box then data.box:Remove() end
		for _, s in ipairs(data.skeleton) do if s.line then s.line:Remove() end end
	end)
	playersData[p] = nil
end

local function refreshPartList(p)
	local data = playersData[p]
	if not data then return end
	local char = p.Character
	if not char then
		data.partList = {}
		return
	end
	data.partList = buildShallowPartList(char)
	-- clear proj cache; it'll be recalculated next frame
	data.projCache = {}
end

-- attach listeners for char changes (only once)
local function attachCharacterListeners(p)
	if not p then return end
	p.CharacterAdded:Connect(function(c)
		-- wait a touch
		repeat task.wait() until c and c.Parent
		if not playersData[p] then createPlayerVisuals(p) end
		refreshPartList(p)
		c.ChildAdded:Connect(function() refreshPartList(p) end)
		c.ChildRemoved:Connect(function() refreshPartList(p) end)
	end)
	if p.Character then
		refreshPartList(p)
		p.Character.ChildAdded:Connect(function() refreshPartList(p) end)
		p.Character.ChildRemoved:Connect(function() refreshPartList(p) end)
	end
end

-- initialize existing players
for _, p in ipairs(Players:GetPlayers()) do
	if p ~= LocalPlayer then
		createPlayerVisuals(p)
		attachCharacterListeners(p)
		if p.Character then refreshPartList(p) end
	end
end
Players.PlayerAdded:Connect(function(p)
	if p ~= LocalPlayer then
		createPlayerVisuals(p)
		attachCharacterListeners(p)
	end
end)
Players.PlayerRemoving:Connect(function(p) removePlayerVisuals(p) end)

-- ===== TARGETING UTILITIES =====
local function pixelFOVToRad(pixelRadius)
	local w = Camera.ViewportSize.X
	if not w or w == 0 then return math.rad(45) end
	local camFov = math.rad(Camera.FieldOfView or 70)
	local screenFactor = (pixelRadius / (w / 2))
	local tanHalf = math.tan(camFov / 2)
	return 2 * math.atan(screenFactor * tanHalf)
end

local function selectTarget()
	local radFOV = pixelFOVToRad(FOVPixelRadius)
	local camPos = Camera.CFrame.Position
	local camLook = Camera.CFrame.LookVector
	local bestP, bestAngle = nil, math.huge
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p.Character and p.Character.Parent and not IsTeammate(p) then
			local hum = p.Character:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				local data = playersData[p]
				if data then
					-- prefer head-like
					local head = findHeadLike(p.Character)
					local candidates = {}
					if head then candidates[#candidates+1] = head end
					for i = 1, #data.partList do candidates[#candidates+1] = data.partList[i] end
					for i = 1, #candidates do
						local part = candidates[i]
						if part and part:IsA("BasePart") then
							local dir = (part.Position - camPos)
							if dir.Magnitude > 0 then
								local angle = math.acos(math.clamp(camLook:Dot(dir.Unit), -1, 1))
								if angle <= radFOV and angle < bestAngle then
									bestAngle = angle
									bestP = p
								end
							end
						end
					end
				end
			end
		end
	end
	return bestP
end

-- project parts for a player (cached per-frame)
local function projectPartsForPlayer(p)
	local data = playersData[p]
	if not data then return end
	data.projCache = data.projCache or {}
	-- project each cached part
	for i = 1, #data.partList do
		local part = data.partList[i]
		if part and part:IsA("BasePart") then
			local spos, vis = Camera:WorldToViewportPoint(part.Position)
			data.projCache[part] = { x = spos.X, y = spos.Y, visible = vis }
		end
	end
	-- also cache head/torso direct (so skeleton uses them fast)
	local head = findHeadLike(p.Character)
	local torso = findTorsoLike(p.Character)
	if head then
		local spos, vis = Camera:WorldToViewportPoint(head.Position)
		data.projCache[head] = { x = spos.X, y = spos.Y, visible = vis }
	end
	if torso then
		local spos, vis = Camera:WorldToViewportPoint(torso.Position)
		data.projCache[torso] = { x = spos.X, y = spos.Y, visible = vis }
	end
end

-- move mouse toward screen coordinates (uses detected mover). Returns true if mover used.
local function moveMouseToScreen(screenX, screenY)
	if not MOUSE_MOVER then return false end
	local center = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
	local dx = (screenX - center.X)
	local dy = (screenY - center.Y)
	-- apply aim strength scaling (bigger values = stronger snap)
	local moveX = dx * AIM_STRENGTH
	local moveY = dy * AIM_STRENGTH
	-- clamp
	if moveX > 3000 then moveX = 3000 elseif moveX < -3000 then moveX = -3000 end
	if moveY > 3000 then moveY = 3000 elseif moveY < -3000 then moveY = -3000 end
	-- call mover (multiple steps if lock mode)
	if AIM_MODE == "lock" then
		for i = 1, LOCK_STEPS do
			local ok = pcall(function() MOUSE_MOVER(moveX / LOCK_STEPS, moveY / LOCK_STEPS) end)
			if not ok then return false end
		end
		return true
	elseif AIM_MODE == "smooth" then
		local ok = pcall(function() MOUSE_MOVER(moveX, moveY) end)
		return ok
	end
	return false
end

-- camlock aiming (directly set camera; requires CAMLOCK_USE true)
local function camlockAimAt(part)
	if not part then return end
	local oldType = Camera.CameraType
	if CAMLOCK_USE then
		pcall(function() Camera.CameraType = Enum.CameraType.Scriptable end)
	end
	local camPos = Camera.CFrame.Position
	local dir = (part.Position - camPos)
	if dir.Magnitude == 0 then return end
	local dirUnit = dir.Unit
	local newLook = Camera.CFrame.LookVector:Lerp(dirUnit, AIM_STRENGTH)
	-- set camera
	pcall(function()
		Camera.CFrame = CFrame.lookAt(camPos, camPos + newLook)
	end)
	-- leave restoration to when aim ends (we restore after aim key is released)
end

-- ===== TOGGLES =====
local FOVVisible = true
local ESPVisible = true
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Insert then
		FOVVisible = not FOVVisible
		fov.Visible = FOVVisible
	elseif input.KeyCode == Enum.KeyCode.End then
		ESPVisible = not ESPVisible
		for _, d in pairs(playersData) do
			if d.box then d.box.Visible = ESPVisible end
			for _, s in ipairs(d.skeleton) do s.line.Visible = ESPVisible end
		end
	end
end)

-- adjust watermark if aim disabled
if AIM_ENABLED and not MOUSE_MOVER and AIM_MODE ~= "camlock" then
	watermark.Text = watermark.Text .. " (aim disabled)"
end

-- remember original camera type for restore
local originalCameraType = Camera and Camera.CameraType

-- ===== MAIN LOOP (optimized) =====
local frameCounter = 0
RunService.RenderStepped:Connect(function()
	frameCounter = frameCounter + 1

	-- HUD
	local vp = Camera.ViewportSize
	fov.Position = Vector2.new(vp.X/2, vp.Y/2)
	fov.Radius = FOVPixelRadius
	watermark.Position = Vector2.new(18, 18)

	-- Project parts once per-frame for players that have part lists
	for p, data in pairs(playersData) do
		local char = p.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if char and hum and hum.Health > 0 then
			-- project only if there are parts or head/torso exist
			projectPartsForPlayer(p)
		else
			-- clear proj cache
			data.projCache = {}
		end
	end

	-- Throttled ESP updates
	if (frameCounter % ESP_UPDATE_RATE) == 0 then
		for p, data in pairs(playersData) do
			local box = data.box
			local skel = data.skeleton
			local char = p.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if ESPVisible and char and hum and hum.Health > 0 then
				-- bounding box using projCache
				local any = false
				local minX, minY = math.huge, math.huge
				local maxX, maxY = -math.huge, -math.huge
				for i = 1, #data.partList do
					local part = data.partList[i]
					local pc = data.projCache[part]
					if pc and pc.visible then
						any = true
						if pc.x < minX then minX = pc.x end
						if pc.y < minY then minY = pc.y end
						if pc.x > maxX then maxX = pc.x end
						if pc.y > maxY then maxY = pc.y end
					end
				end
				-- fallback: use head/torso projection if nothing visible
				local head = findHeadLike(char)
				local headPc = head and data.projCache[head]
				if not any and headPc and headPc.visible then
					any = true
					local w = 40
					local h = 60
					minX = headPc.x - w/2
					minY = headPc.y - h/2
					maxX = headPc.x + w/2
					maxY = headPc.y + h/2
				end

				if any then
					local w = maxX - minX
					local h = maxY - minY
					if w < 6 then w = 6 end
					if h < 6 then h = 6 end
					box.Size = Vector2.new(w, h)
					box.Position = Vector2.new(minX, minY)
					box.Visible = true
				else
					box.Visible = false
				end

				-- skeleton: update per bone (only if both endpoints visible)
				for i = 1, #skel do
					local entry = skel[i]
					local p0 = char:FindFirstChild(entry.from)
					local p1 = char:FindFirstChild(entry.to)
					local pc0 = p0 and data.projCache[p0]
					local pc1 = p1 and data.projCache[p1]
					if pc0 and pc1 and pc0.visible and pc1.visible then
						entry.line.From = Vector2.new(pc0.x, pc0.y)
						entry.line.To = Vector2.new(pc1.x, pc1.y)
						entry.line.Visible = true
					else
						entry.line.Visible = false
					end
				end
			else
				-- hide
				if box then box.Visible = false end
				for i = 1, #skel do skel[i].line.Visible = false end
			end
		end
	end

	-- AIM (only when key held)
	if AIM_ENABLED and UserInputService:IsMouseButtonPressed(AIM_KEY) then
		local target = selectTarget()
		if target and target.Character then
			-- pick head or nearest visible part
			local data = playersData[target]
			local aimPart = findHeadLike(target.Character)
			if not aimPart and data and data.partList and data.partList[1] then
				aimPart = data.partList[1]
			end

			if aimPart then
				-- get its screen projection
				local pc = data and data.projCache[aimPart]
				-- if projection missing, compute quickly
				local sx, sy, sv
				if pc then sx, sy, sv = pc.x, pc.y, pc.visible
				else
					local spos, on = Camera:WorldToViewportPoint(aimPart.Position)
					sx, sy, sv = spos.X, spos.Y, on
				end

				if AIM_MODE == "camlock" then
					-- camlock direct camera (requires CAMLOCK_USE true to attempt changing camera type)
					if CAMLOCK_USE then
						camlockAimAt(aimPart)
					else
						-- fall back to best available: try multiple mouse moves to snap
						if sx and sy then moveMouseToScreen(sx, sy) end
					end
				else
					-- smooth or lock via mouse mover
					if MOUSE_MOVER and sx and sy then
						if AIM_MODE == "lock" then
							-- strong snap (multiple small mover calls)
							for i = 1, LOCK_STEPS do
								local ok = pcall(function()
									-- each step uses a fraction of the delta; LOCK_STEPS*step ~= full move
									local center = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
									local dx = (sx - center.X) * (AIM_STRENGTH / LOCK_STEPS)
									local dy = (sy - center.Y) * (AIM_STRENGTH / LOCK_STEPS)
									MOUSE_MOVER(dx, dy)
								end)
								if not ok then break end
							end
						else
							-- smooth: single scaled move
							moveMouseToScreen(sx, sy)
						end
					else
						-- no mouse mover: optional camlock fallback (may be overwritten by game)
						if CAMLOCK_USE then camlockAimAt(aimPart) end
					end
				end
			end
		end
	else
		-- restore camera type if camlock was used previously
		if CAMLOCK_USE and Camera.CameraType ~= originalCameraType then
			pcall(function() Camera.CameraType = originalCameraType end)
		end
	end
end)

--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local uis = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")

--// Variables
local silentAimEnabled = false
local infJumpEnabled = false

--// Function to handle infinite jump logic
local function setupInfiniteJump(hum)
	uis.JumpRequest:Connect(function()
		if infJumpEnabled and hum then
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end)
end

-- Setup initial humanoid listener
setupInfiniteJump(Humanoid)

-- Reconnect infinite jump after death/respawn
LocalPlayer.CharacterAdded:Connect(function(char)
	Character = char
	Humanoid = char:WaitForChild("Humanoid")
	setupInfiniteJump(Humanoid)
end)

--// Silent Aim Toggle (Home)
uis.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Home then
		silentAimEnabled = not silentAimEnabled
		print("Silent Aim: " .. (silentAimEnabled and "ON" or "OFF"))

		if silentAimEnabled then
			task.spawn(function()
				while silentAimEnabled do
					for _, player in pairs(Players:GetPlayers()) do
						if player ~= LocalPlayer and player.Character then
							if LocalPlayer.Team == nil or player.Team ~= LocalPlayer.Team then
								local parts = {"Head", "HumanoidRootPart", "RightUpperLeg", "LeftUpperLeg"}
								for _, partName in ipairs(parts) do
									local part = player.Character:FindFirstChild(partName)
									if part then
										part.CanCollide = false
										part.Transparency = 10
										part.Size = Vector3.new(100, 100, 100)
									end
								end
							end
						end
					end
					task.wait(1)
				end
			end)
		end
	end
end)

--// Infinite Jump Toggle (K)
uis.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.K then
		infJumpEnabled = not infJumpEnabled
		print("Infinite Jump: " .. (infJumpEnabled and "ON" or "OFF"))
	end
end)

