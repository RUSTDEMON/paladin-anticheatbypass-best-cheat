-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

-- ===== Settings =====
local ESPEnabled = true
local SkeletonColor = Color3.fromRGB(255,255,255)

-- Triggerbot
local TriggerEnabled = true
local TriggerReactionInterval = 0.01   -- 10ms
local TriggerCooldown = 0.01
local MaxRayDistance = 99999           -- unlimited range

-- Legit smooth aim assist
local AimEnabled = true
local AimFOV = 150                     -- pixels around crosshair to detect targets
local AimSpeed = 0.08                  -- lower = smoother/slower
local MaxAngle = 3                     -- max rotation per frame in degrees

-- ===== Watermark =====
local watermark = Drawing.new("Text")
watermark.Text = "kernelhook.xyz | TRIGGER: ON | AIM: ON"
watermark.Size = 20
watermark.Color = Color3.fromRGB(255,255,255)
watermark.Position = Vector2.new(10, 10)
watermark.Center = false
watermark.Visible = true
watermark.Outline = true

-- ===== ESP Storage =====
local ESPPlayers = {}

-- ===== Helpers =====
local function IsTeammate(player)
    return LocalPlayer.Team and player.Team and LocalPlayer.Team == player.Team
end

local function attemptFire()
    local char = LocalPlayer.Character
    if char then
        local tool = char:FindFirstChildOfClass("Tool")
        if tool and tool.Activate then
            pcall(tool.Activate, tool)
            return true
        end
    end
    if typeof(mouse1click) == "function" then pcall(mouse1click); return true end
    if typeof(mouse1press) == "function" and typeof(mouse1release) == "function" then
        pcall(mouse1press); task.wait(0.001); pcall(mouse1release)
        return true
    end
    local ok, vu = pcall(function() return game:GetService("VirtualUser") end)
    if ok and vu then
        pcall(function() vu:CaptureController(); vu:Button1Down(); task.wait(0.001); vu:Button1Up() end)
        return true
    end
    return false
end

local function createESP(player)
    local esp = {skeleton = {}}
    local bones = {
        {"Head","UpperTorso"},{"UpperTorso","LowerTorso"},{"LowerTorso","LeftUpperLeg"},
        {"LowerTorso","RightUpperLeg"},{"UpperTorso","LeftUpperArm"},{"UpperTorso","RightUpperArm"}
    }
    for _, bone in pairs(bones) do
        local line = Drawing.new("Line")
        line.Color = SkeletonColor
        line.Thickness = 1.5
        line.Visible = ESPEnabled
        table.insert(esp.skeleton, {from=bone[1], to=bone[2], line=line})
    end
    ESPPlayers[player] = esp
end

local function removeESP(player)
    local esp = ESPPlayers[player]
    if esp then
        for _, b in pairs(esp.skeleton) do if b.line then pcall(function() b.line:Remove() end) end end
        ESPPlayers[player] = nil
    end
end

-- Raycast params
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Blacklist
rayParams.IgnoreWater = true

local function instanceToPlayer(instance)
    if not instance then return nil end
    local model = instance:FindFirstAncestorOfClass("Model")
    if not model then return nil end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    return Players:GetPlayerFromCharacter(model)
end

-- Keybinds
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.Insert then
        TriggerEnabled = not TriggerEnabled
        watermark.Text = ("kernelhook.xyz | TRIGGER: %s | AIM: %s"):format(
            TriggerEnabled and "ON" or "OFF", AimEnabled and "ON" or "OFF")
    elseif input.KeyCode == Enum.KeyCode.End then
        ESPEnabled = not ESPEnabled
        for _, esp in pairs(ESPPlayers) do
            for _, b in pairs(esp.skeleton) do b.line.Visible = ESPEnabled end
        end
    elseif input.KeyCode == Enum.KeyCode.RightShift then
        AimEnabled = not AimEnabled
        watermark.Text = ("kernelhook.xyz | TRIGGER: %s | AIM: %s"):format(
            TriggerEnabled and "ON" or "OFF", AimEnabled and "ON" or "OFF")
    end
end)

-- Track players
Players.PlayerAdded:Connect(function(player) if player ~= LocalPlayer then createESP(player) end end)
Players.PlayerRemoving:Connect(removeESP)
for _, player in pairs(Players:GetPlayers()) do if player ~= LocalPlayer then createESP(player) end end

-- ===== Main loop =====
local lastTriggerTime = 0
local accumulator = 0

RunService.Heartbeat:Connect(function(dt)
    watermark.Position = Vector2.new(10,10)

    -- ESP update
    for player, esp in pairs(ESPPlayers) do
        local char = player.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if ESPEnabled and char and hum and hum.Health > 0 then
            for _, b in pairs(esp.skeleton) do
                local part0 = char:FindFirstChild(b.from)
                local part1 = char:FindFirstChild(b.to)
                if part0 and part1 then
                    local pos0, vis0 = Camera:WorldToViewportPoint(part0.Position)
                    local pos1, vis1 = Camera:WorldToViewportPoint(part1.Position)
                    if vis0 and vis1 then
                        b.line.From = Vector2.new(pos0.X, pos0.Y)
                        b.line.To = Vector2.new(pos1.X, pos1.Y)
                        b.line.Visible = true
                    else
                        b.line.Visible = false
                    end
                else
                    b.line.Visible = false
                end
            end
        else
            for _, b in pairs(esp.skeleton) do b.line.Visible = false end
        end
    end

    -- Triggerbot (~10ms)
    accumulator = accumulator + dt
    if TriggerEnabled and accumulator >= TriggerReactionInterval then
        accumulator = accumulator - TriggerReactionInterval
        local now = tick()
        if now - lastTriggerTime >= TriggerCooldown then
            local ignoreList = {}
            if LocalPlayer.Character then table.insert(ignoreList, LocalPlayer.Character) end
            rayParams.FilterDescendantsInstances = ignoreList

            local sx, sy = Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2
            local ray = Camera:ScreenPointToRay(sx, sy)
            local origin = ray.Origin
            local direction = ray.Direction.Unit * MaxRayDistance
            local result = workspace:Raycast(origin, direction, rayParams)
            if result and result.Instance then
                local hitPlayer = instanceToPlayer(result.Instance)
                if hitPlayer and hitPlayer ~= LocalPlayer and not IsTeammate(hitPlayer) then
                    lastTriggerTime = now
                    attemptFire()
                end
            end
        end
    end

    -- Smooth legit aim assist
    if AimEnabled then
        local closestPlayer = nil
        local shortestDist = AimFOV
        for _, player in pairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("Head") then
                local hum = player.Character:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    local headPos, onScreen = Camera:WorldToViewportPoint(player.Character.Head.Position)
                    if onScreen then
                        local dist = (Vector2.new(headPos.X, headPos.Y) - Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)).Magnitude
                        if dist < shortestDist then
                            shortestDist = dist
                            closestPlayer = player
                        end
                    end
                end
            end
        end

        if closestPlayer then
            local headPos = closestPlayer.Character.Head.Position
            local camPos = Camera.CFrame.Position
            local dir = (headPos - camPos).Unit
            local newLook = Camera.CFrame.LookVector:Lerp(dir, AimSpeed)
            local angleBetween = math.acos(math.clamp(Camera.CFrame.LookVector:Dot(newLook), -1,1))
            if angleBetween > math.rad(MaxAngle) then
                newLook = Camera.CFrame.LookVector:Lerp(newLook, math.rad(MaxAngle)/angleBetween)
            end
            Camera.CFrame = CFrame.lookAt(camPos, camPos + newLook)
        end
    end
end)
-- Watermark toggle
local WatermarkEnabled = true  -- starts ON

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end

    if input.KeyCode == Enum.KeyCode.Home then
        WatermarkEnabled = not WatermarkEnabled
        watermark.Visible = WatermarkEnabled
    end
end)
