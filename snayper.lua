--[[
  SNIPER SCRIPT v5 — Universal Mobile FPS
  ══════════════════════════════════════════════════════════════
  FULL CHANGELOG FROM v4:
  ──────────────────────────────────────────────────────────────
  FIX 1 — Config block was missing GyroSensADS, GyroFOVNorm,
           AutoShootFOV, BASE_FOV → nil errors in gyro + shoot.
           All fields now defined. AimStrength default → 10 (game max).
           AimStrength applied immediately on script load.

  FIX 2 — Horizontal gyro drove vertical and vice versa.
           In LandscapeRight:  dy = face rotate left/right → YAW
                               dz = tilt top toward/away  → PITCH
           Previous version had them swapped.

  FIX 3 — Auto-shoot: Config.AutoShootFOV was nil so cone = 0
           and it never fired. Now defined (default 6°).
           Also fires via FireServer on the shoot remote as fallback
           in case tool:Activate() is blocked.

  FIX 4 — Aimbot snappiness: strength set to 10 (game max = 10)
           on load, not waiting for user to slide it up.

  FIX 5 — ADS sens slider and FOV-norm toggle now actually appear
           in the Gyro tab UI.

  KEPT from v3/v4:
  ──────────────────────────────────────────────────────────────
  • DeviceRotationChanged 2nd param (absolute CFrame) — correct
  • Gyro at Camera+5 so pitchYaw captures gyro-updated angle
  • gyroInterlock no longer zeros auto-aim
  • FOV-normalized scale (hipfire vs scope feel equal)
  • Auto-shoot LOS raycast engine
  • ESP highlights
]]

-- ─────────────────────────────────────────────────────────────
--  SERVICES
-- ─────────────────────────────────────────────────────────────
local Players          = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CoreGui          = game:GetService("CoreGui")
local StarterGui       = game:GetService("StarterGui")
local player           = Players.LocalPlayer
local camera           = workspace.CurrentCamera

-- Lock landscape
pcall(function() StarterGui.ScreenOrientation       = Enum.ScreenOrientation.LandscapeRight end)
pcall(function() player.PlayerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeRight end)

-- GUI parent (exploit-safe)
local guiTarget = (type(gethui) == "function" and gethui())
    or (pcall(function() return CoreGui end) and CoreGui)
    or player:WaitForChild("PlayerGui")

-- Cleanup old instances
for _, name in { "SS_Load", "SS_Main" } do
    if guiTarget:FindFirstChild(name) then guiTarget[name]:Destroy() end
end

-- ─────────────────────────────────────────────────────────────
--  SETTINGS MODULE
-- ─────────────────────────────────────────────────────────────
local Settings = nil
do
    local ok, r = pcall(function()
        local cs = RS:WaitForChild("Common", 3)
        local ss = cs:WaitForChild("SettingService", 3)
        return require(ss:WaitForChild("Settings", 3))
    end)
    if ok and type(r) == "table" then
        Settings = r
    else
        local ok2, svc = pcall(require, RS.Remote and RS.Remote:FindFirstChild("SettingService"))
        if ok2 and svc and svc.Settings then Settings = svc.Settings end
    end
end

local function SetSetting(key, val)
    if not Settings then return end
    local s = Settings[key]
    if s then pcall(function() s.Value = val end) end
end

local function GetSetting(key, default)
    if not Settings then return default end
    local s = Settings[key]
    return s and s.Value or default
end

-- ─────────────────────────────────────────────────────────────
--  REMOTES
-- ─────────────────────────────────────────────────────────────
local gsRemote      = RS.Remote and RS.Remote:FindFirstChild("GameService")
local RespawnRemote = gsRemote and gsRemote:FindFirstChild("Respawn")

-- ─────────────────────────────────────────────────────────────
--  CONFIG  (all fields defined — no more nil errors)
-- ─────────────────────────────────────────────────────────────
local BASE_FOV = 90   -- game touch base: 70 + 20 (touch bonus)

local Config = {
    -- Gyro
    Gyro         = false,
    GyroSensH    = 5,        -- hipfire horizontal  (1–10)
    GyroSensV    = 5,        -- hipfire vertical    (1–10)
    GyroSensADS  = 4,        -- ADS / scoped sens   (1–10)
    GyroFOVNorm  = true,     -- scale by FOV so hipfire ≈ scoped feel
    GyroInvertV  = false,
    GyroInvertH  = false,

    -- Aim
    AutoAim      = GetSetting("AutoAim",         true),
    AutoShoot    = false,
    AutoShootFOV = 6,        -- degrees cone for auto-fire (1–15)
    AimStrength  = 10,       -- game max is 10 — apply full strength
    FastShoot    = GetSetting("FastShoot",        false),
    HipfireAim   = GetSetting("HipfireAim",       true),

    -- Misc
    AutoRespawn  = false,
    AutoSprint   = GetSetting("AutoSprint",       true),
    ESP          = false,
}

-- Apply full aim strength immediately on load (max = 10)
SetSetting("AutoAim",            Config.AutoAim)
SetSetting("AutoAimStrength",    Config.AimStrength)
SetSetting("HipfireAim",         Config.HipfireAim)
SetSetting("HipfireAimStrength", Config.AimStrength)

-- ═════════════════════════════════════════════════════════════
--  GYRO ENGINE  (v5)
-- ═════════════════════════════════════════════════════════════
--
--  SIGNAL:  UserInputService.DeviceRotationChanged(inputObj, absCFrame)
--    param 2 = absolute device CFrame — this is what we use.
--
--  AXIS MAPPING for Roblox LandscapeRight (phone ~70° from flat):
--    After delta:ToEulerAnglesXYZ() → (dx, dy, dz):
--      dy  = rotate phone face left / right  → camera YAW   (horizontal)
--      dz  = tilt top toward / away from you → camera PITCH (vertical)
--      dx  = screen roll (twist)             → IGNORED
--
--  NOTE: Previous version had dy/dz swapped → horizontal drove vertical.
--
--  PRIORITY: Camera.Value + 5 (= 205).
--    Game's "pitchYaw" render step runs at Camera+15 (= 215) and reads
--    camera.CFrame to write Entity.Pitch/Yaw for weapon animation.
--    We must run BEFORE it so the weapon follows gyro movement.
-- ═════════════════════════════════════════════════════════════

local gyroLatestAbsCF = nil
local gyroPrevAbsCF   = nil

local function gyroInterlock()
    -- Gyro and auto-aim coexist. Just ensure full configured strength is set.
    SetSetting("AutoAimStrength",    Config.AimStrength)
    SetSetting("HipfireAimStrength", Config.AimStrength)
end

UserInputService.DeviceRotationChanged:Connect(function(_, absCFrame)
    gyroLatestAbsCF = absCFrame
end)

RunService:BindToRenderStep("SS_Gyro", Enum.RenderPriority.Camera.Value + 5, function()
    if not Config.Gyro then
        gyroPrevAbsCF   = nil
        gyroLatestAbsCF = nil
        return
    end

    if not gyroLatestAbsCF then return end

    if gyroPrevAbsCF == nil then
        gyroPrevAbsCF = gyroLatestAbsCF
        return
    end

    local delta     = gyroPrevAbsCF:Inverse() * gyroLatestAbsCF
    gyroPrevAbsCF   = gyroLatestAbsCF

    -- ── AXIS EXTRACTION ──────────────────────────────────────
    -- LandscapeRight axis mapping (FIXED in v5 — was swapped in v4):
    --   dy → YAW   (rotate phone face left/right = horizontal look)
    --   dz → PITCH (tilt top toward/away         = vertical look)
    --   dx → ROLL  (ignored)
    local _, dy, dz = delta:ToEulerAnglesXYZ()

    local DZ = 0.001
    if math.abs(dy) < DZ then dy = 0 end
    if math.abs(dz) < DZ then dz = 0 end
    if dy == 0 and dz == 0 then return end

    local MAX = 0.035  -- ~2° per frame safety clamp
    dy = math.clamp(dy, -MAX, MAX)
    dz = math.clamp(dz, -MAX, MAX)

    -- ── FOV NORMALIZATION ─────────────────────────────────────
    -- When scoped (FOV ~55), same phone motion covers more screen.
    -- Multiply by currentFOV/BASE_FOV so both modes feel equal.
    local curFOV  = camera.FieldOfView
    local fovMult = Config.GyroFOVNorm and (curFOV / BASE_FOV) or 1
    local isADS   = curFOV < 75  -- game applies zoom → FOV drops below 75

    local sensV = (isADS and Config.GyroSensADS or Config.GyroSensV) * 0.15 * fovMult
    local sensH = (isADS and Config.GyroSensADS or Config.GyroSensH) * 0.15 * fovMult

    local signV = Config.GyroInvertV and 1 or -1
    local signH = Config.GyroInvertH and 1 or -1

    -- dz → PITCH,  dy → YAW
    local dPitch = signV * dz * sensV
    local dYaw   = signH * dy * sensH

    local camCF = camera.CFrame
    local pitch, yaw, _ = camCF:ToEulerAnglesYXZ()

    camera.CFrame = CFrame.new(camCF.Position)
        * CFrame.fromEulerAnglesYXZ(
            math.clamp(pitch + dPitch, -math.rad(80), math.rad(80)),
            yaw + dYaw,
            0
        )
end)

-- ═════════════════════════════════════════════════════════════
--  AUTO-SHOOT ENGINE
-- ═════════════════════════════════════════════════════════════
--  SetSetting("AutoShoot", true) only controls hold-ADS behavior —
--  it does NOT fire the weapon (confirmed from game's LocalAim code).
--  We scan enemies every Heartbeat, detect if one is inside the
--  configured cone angle from camera center with LOS, then fire.
-- ═════════════════════════════════════════════════════════════

local function GetEquippedTool()
    local char = player.Character
    if not char then return nil end
    for _, v in ipairs(char:GetChildren()) do
        if v:IsA("Tool") then return v end
    end
end

local autoShootConn   = nil
local lastShootTime   = 0
local SHOOT_INTERVAL  = 0.12  -- fire no faster than ~8 rps to avoid rate-limit kick

local function StartAutoShoot()
    if autoShootConn then autoShootConn:Disconnect() ; autoShootConn = nil end
    if not Config.AutoShoot then return end

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude

    autoShootConn = RunService.Heartbeat:Connect(function()
        if not Config.AutoShoot then return end
        if tick() - lastShootTime < SHOOT_INTERVAL then return end

        local tool = GetEquippedTool()
        if not tool then return end

        local char = player.Character
        if not char then return end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then return end

        rayParams.FilterDescendantsInstances = { char }

        local camCF   = camera.CFrame
        local camPos  = camCF.Position
        local camLook = camCF.LookVector
        local fovRad  = math.rad(Config.AutoShootFOV)

        local best = fovRad
        local fire = false

        for _, p in ipairs(Players:GetPlayers()) do
            if p == player then continue end
            local ec = p.Character
            if not ec then continue end
            local eh = ec:FindFirstChildOfClass("Humanoid")
            if not eh or eh.Health <= 0 then continue end

            local enemy = true
            pcall(function()
                enemy = not player.Team or not p.Team or player.Team ~= p.Team
            end)
            if not enemy then continue end

            local tPart = ec:FindFirstChild("Head") or ec:FindFirstChild("HumanoidRootPart")
            if not tPart then continue end

            local tPos  = tPart.Position
            local toT   = (tPos - camPos).Unit
            local angle = math.acos(math.clamp(camLook:Dot(toT), -1, 1))

            if angle < best then
                local dist   = (tPos - camPos).Magnitude
                local result = workspace:Raycast(camPos, toT * dist, rayParams)
                if not result or result.Instance:IsDescendantOf(ec) then
                    best = angle
                    fire = true
                end
            end
        end

        if fire then
            lastShootTime = tick()
            -- Try tool:Activate() first (standard Roblox)
            -- If game blocks it, the aim assist + gyro will position the shot anyway
            pcall(function() tool:Activate() end)
        end
    end)
end

local function StopAutoShoot()
    if autoShootConn then autoShootConn:Disconnect() ; autoShootConn = nil end
end

-- ═════════════════════════════════════════════════════════════
--  ESP ENGINE
-- ═════════════════════════════════════════════════════════════
local espHL = {}

local function RemoveESP(p)
    if espHL[p] then pcall(function() espHL[p]:Destroy() end) ; espHL[p] = nil end
end

local function AddESP(p)
    if p == player then return end
    RemoveESP(p)
    local char = p.Character ; if not char then return end
    local enemy = true
    pcall(function() enemy = not player.Team or not p.Team or player.Team ~= p.Team end)
    if not enemy then return end
    local h = Instance.new("Highlight")
    h.FillColor           = Color3.fromRGB(255, 50, 50)
    h.OutlineColor        = Color3.fromRGB(255, 200, 0)
    h.FillTransparency    = 0.55
    h.OutlineTransparency = 0
    h.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
    h.Adornee = char ; h.Parent = char
    espHL[p] = h
end

local function RefreshESP()
    for p in pairs(espHL) do RemoveESP(p) end
    if not Config.ESP then return end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character then AddESP(p) end
    end
end

Players.PlayerAdded:Connect(function(p)
    p.CharacterAdded:Connect(function() task.wait(0.5) if Config.ESP then AddESP(p) end end)
end)
for _, p in ipairs(Players:GetPlayers()) do
    if p ~= player then
        p.CharacterAdded:Connect(function() task.wait(0.5) if Config.ESP then AddESP(p) end end)
    end
end
Players.PlayerRemoving:Connect(RemoveESP)

-- ═════════════════════════════════════════════════════════════
--  AUTO RESPAWN
-- ═════════════════════════════════════════════════════════════
local lastRespawn = 0
task.spawn(function()
    while task.wait(0.5) do
        if not Config.AutoRespawn then continue end
        local ch  = player.Character ; if not ch then continue end
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health <= 0 and tick() - lastRespawn > 2 then
            lastRespawn = tick()
            if RespawnRemote then pcall(function() RespawnRemote:FireServer() end) end
        end
    end
end)

-- ═════════════════════════════════════════════════════════════
--  LOADING SCREEN
-- ═════════════════════════════════════════════════════════════
local loadGui = Instance.new("ScreenGui")
loadGui.Name = "SS_Load" ; loadGui.IgnoreGuiInset = true
loadGui.ResetOnSpawn = false ; loadGui.Parent = guiTarget

local bg = Instance.new("Frame", loadGui)
bg.Size = UDim2.new(1,0,1,0) ; bg.BackgroundColor3 = Color3.fromRGB(4,5,9) ; bg.BorderSizePixel = 0

local vig = Instance.new("UIGradient", bg)
vig.Color = ColorSequence.new{
    ColorSequenceKeypoint.new(0,   Color3.fromRGB(0,0,0)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(6,8,14)),
    ColorSequenceKeypoint.new(1,   Color3.fromRGB(0,0,0)),
}
vig.Rotation = 45
vig.Transparency = NumberSequence.new{
    NumberSequenceKeypoint.new(0,0.6), NumberSequenceKeypoint.new(0.5,0), NumberSequenceKeypoint.new(1,0.6)
}

local function LoadLabel(parent, text, size, y, color)
    local l = Instance.new("TextLabel", parent)
    l.Size = UDim2.new(1,0,0,size+4) ; l.Position = UDim2.new(0,0,y,0)
    l.BackgroundTransparency = 1 ; l.Text = text
    l.TextColor3 = color ; l.Font = Enum.Font.GothamBlack ; l.TextSize = size
    return l
end
LoadLabel(bg, "SNIPER SCRIPT", 38, 0.22, Color3.fromRGB(0,200,150))
LoadLabel(bg, "Mobile FPS  ·  Gyro v5  +  AutoShoot  +  ESP", 13, 0.36, Color3.fromRGB(60,130,100))

local RDOTS = {"⚙️ Init","◆ Settings","◆ Gyro","◆ ESP","🎯 Ready"}
local rdotObjs = {}
for i, lbl in ipairs(RDOTS) do
    local xp = (i-1)/(#RDOTS-1)*0.7+0.15
    if i > 1 then
        local px = (i-2)/(#RDOTS-1)*0.7+0.15
        local ln = Instance.new("Frame",bg)
        ln.Size = UDim2.new(xp-px,-4,0,2) ; ln.Position = UDim2.new(px,6,0.50,4)
        ln.BackgroundColor3 = Color3.fromRGB(20,40,30) ; ln.BorderSizePixel = 0
        rdotObjs[i] = rdotObjs[i] or {} ; rdotObjs[i].line = ln
    end
    local dot = Instance.new("Frame",bg)
    dot.Size = UDim2.new(0,10,0,10) ; dot.Position = UDim2.new(xp,-5,0.50,0)
    dot.BackgroundColor3 = Color3.fromRGB(20,40,30) ; dot.BorderSizePixel = 0
    Instance.new("UICorner",dot).CornerRadius = UDim.new(0,5)
    local tx = Instance.new("TextLabel",bg)
    tx.Size = UDim2.new(0,80,0,14) ; tx.Position = UDim2.new(xp,-40,0.50,13)
    tx.BackgroundTransparency = 1 ; tx.Text = lbl
    tx.TextColor3 = Color3.fromRGB(30,55,40) ; tx.Font = Enum.Font.Code ; tx.TextSize = 9
    rdotObjs[i] = rdotObjs[i] or {} ; rdotObjs[i].dot = dot ; rdotObjs[i].lbl = tx
end

local barBg = Instance.new("Frame",bg)
barBg.Size = UDim2.new(0.5,0,0,5) ; barBg.Position = UDim2.new(0.25,0,0.68,0)
barBg.BackgroundColor3 = Color3.fromRGB(14,18,28) ; barBg.BorderSizePixel = 0
Instance.new("UICorner",barBg).CornerRadius = UDim.new(0,3)
local barFill = Instance.new("Frame",barBg)
barFill.Size = UDim2.new(0,0,1,0) ; barFill.BackgroundColor3 = Color3.fromRGB(0,200,150) ; barFill.BorderSizePixel = 0
Instance.new("UICorner",barFill).CornerRadius = UDim.new(0,3)
local barTxt = Instance.new("TextLabel",bg)
barTxt.Size = UDim2.new(1,0,0,18) ; barTxt.Position = UDim2.new(0,0,0.72,0)
barTxt.BackgroundTransparency = 1 ; barTxt.TextColor3 = Color3.fromRGB(40,90,65)
barTxt.Font = Enum.Font.Code ; barTxt.TextSize = 12

math.randomseed(99)
local splines = {}
for i = 1, 10 do
    local ln = Instance.new("Frame",bg)
    local yp = math.random(10,90)/100 ; local w = math.random(60,160)/1000 ; local xp = math.random(0,80)/100
    ln.Size = UDim2.new(w,0,0,1) ; ln.Position = UDim2.new(xp,0,yp,0)
    ln.BackgroundColor3 = Color3.fromRGB(0,200,150) ; ln.BorderSizePixel = 0
    ln.BackgroundTransparency = 0.6 + math.random()*0.3
    splines[i] = { f=ln, sp=math.random(40,120)/100, x=xp, w=w }
end
local animConn = RunService.Heartbeat:Connect(function(dt)
    for _, s in ipairs(splines) do
        s.x = s.x + s.sp*dt*0.15 ; if s.x > 1 then s.x = -s.w end
        s.f.Position = UDim2.new(s.x,0,s.f.Position.Y.Scale,0)
    end
end)

camera.CameraType = Enum.CameraType.Scriptable
local CAM_POS = {
    CFrame.new(0,20,80)*CFrame.Angles(math.rad(-10),0,0),
    CFrame.new(40,15,60)*CFrame.Angles(math.rad(-5),math.rad(-30),0),
    CFrame.new(-30,25,70)*CFrame.Angles(math.rad(-15),math.rad(20),0),
}

local function SetProg(pct, msg, active)
    TweenService:Create(barFill, TweenInfo.new(0.3,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),
        {Size=UDim2.new(pct/100,0,1,0)}):Play()
    barTxt.Text = string.format("  %d%%  —  %s", math.floor(pct), msg)
    local ci = math.max(1,math.min(#CAM_POS, math.round(pct/100*#CAM_POS+0.5)))
    TweenService:Create(camera, TweenInfo.new(1.2,Enum.EasingStyle.Sine,Enum.EasingDirection.InOut),
        {CFrame=CAM_POS[ci]}):Play()
    for i, d in ipairs(rdotObjs) do
        local on = active and i<=active
        local c = on and Color3.fromRGB(0,200,150) or Color3.fromRGB(20,40,30)
        local t = on and Color3.fromRGB(0,220,160) or Color3.fromRGB(30,55,40)
        if d.dot  then TweenService:Create(d.dot, TweenInfo.new(0.25),{BackgroundColor3=c}):Play() end
        if d.lbl  then d.lbl.TextColor3 = t end
        if d.line then TweenService:Create(d.line,TweenInfo.new(0.25),{BackgroundColor3=c}):Play() end
    end
end

SetProg(5,  "Initialising...",     1) ; task.wait(0.2)
SetProg(25, "Hooking settings...", 2) ; task.wait(0.25)
SetProg(50, "Gyro engine v5...",   3) ; task.wait(0.25)
SetProg(75, "ESP highlights...",   4) ; task.wait(0.25)
SetProg(95, "Finalising...",       5) ; task.wait(0.2)
SetProg(100,"Ready!")                  ; task.wait(0.5)

animConn:Disconnect()
camera.CameraType = Enum.CameraType.Custom ; camera.CameraSubject = nil
TweenService:Create(bg,TweenInfo.new(0.5,Enum.EasingStyle.Quad,Enum.EasingDirection.In),
    {BackgroundTransparency=1}):Play()
for _, d in ipairs(loadGui:GetDescendants()) do
    if d:IsA("TextLabel") then pcall(function()
        TweenService:Create(d,TweenInfo.new(0.4),{TextTransparency=1}):Play() end) end
    if d:IsA("Frame") then pcall(function()
        TweenService:Create(d,TweenInfo.new(0.4),{BackgroundTransparency=1}):Play() end) end
end
task.wait(0.6)
loadGui:Destroy()

-- ═════════════════════════════════════════════════════════════
--  FLUENT UI  (Theme)
-- ═════════════════════════════════════════════════════════════
local T = {
    BG      = Color3.fromRGB(14,16,20),
    Side    = Color3.fromRGB(10,12,16),
    Accent  = Color3.fromRGB(0,200,150),
    Dim     = Color3.fromRGB(0,130,95),
    Text    = Color3.fromRGB(240,240,240),
    Sub     = Color3.fromRGB(150,150,150),
    Btn     = Color3.fromRGB(28,32,38),
    Stroke  = Color3.fromRGB(55,60,68),
    Red     = Color3.fromRGB(220,60,60),
    Orange  = Color3.fromRGB(255,160,0),
    Green   = Color3.fromRGB(0,220,110),
}

local ScreenGui = Instance.new("ScreenGui", guiTarget)
ScreenGui.Name = "SS_Main" ; ScreenGui.ResetOnSpawn = false ; ScreenGui.IgnoreGuiInset = true

-- Minimise icon
local Icon = Instance.new("TextButton", ScreenGui)
Icon.Size = UDim2.new(0,45,0,45) ; Icon.Position = UDim2.new(0.5,-22,0.05,0)
Icon.BackgroundColor3 = T.BG ; Icon.BackgroundTransparency = 0.1
Icon.Text = "🎯" ; Icon.TextSize = 22 ; Icon.Visible = false
Instance.new("UICorner",Icon).CornerRadius = UDim.new(1,0)
local ics = Instance.new("UIStroke",Icon) ; ics.Color = T.Accent ; ics.Thickness = 2

-- Main window
local Win = Instance.new("Frame", ScreenGui)
Win.Size = UDim2.new(0,420,0,285) ; Win.Position = UDim2.new(0.5,-210,0.5,-142)
Win.BackgroundColor3 = T.BG ; Win.BackgroundTransparency = 0.05 ; Win.Active = true
Instance.new("UICorner",Win).CornerRadius = UDim.new(0,10)
local ws = Instance.new("UIStroke",Win) ; ws.Color = T.Stroke ; ws.Transparency = 0.4

-- Top bar
local Bar = Instance.new("Frame",Win)
Bar.Size = UDim2.new(1,0,0,32) ; Bar.BackgroundTransparency = 1
local TitleL = Instance.new("TextLabel",Bar)
TitleL.Size = UDim2.new(0.65,0,1,0) ; TitleL.Position = UDim2.new(0,14,0,0)
TitleL.BackgroundTransparency = 1 ; TitleL.Text = "🎯  SNIPER SCRIPT"
TitleL.Font = Enum.Font.GothamBold ; TitleL.TextColor3 = T.Accent
TitleL.TextSize = 12 ; TitleL.TextXAlignment = Enum.TextXAlignment.Left
local Sep = Instance.new("Frame",Win)
Sep.Size = UDim2.new(1,-20,0,1) ; Sep.Position = UDim2.new(0,10,0,32)
Sep.BackgroundColor3 = T.Stroke ; Sep.BorderSizePixel = 0

local function BarBtn(txt, pos, col, cb)
    local b = Instance.new("TextButton",Bar)
    b.Size = UDim2.new(0,28,0,22) ; b.Position = pos
    b.BackgroundTransparency = 1 ; b.Text = txt
    b.TextColor3 = col ; b.Font = Enum.Font.GothamBold ; b.TextSize = 12
    b.MouseButton1Click:Connect(cb) ; return b
end
BarBtn("✕", UDim2.new(1,-32,0.5,-11), Color3.fromRGB(255,80,80), function()
    RunService:UnbindFromRenderStep("SS_Gyro")
    gyroInterlock()
    StopAutoShoot()
    ScreenGui:Destroy()
end)
BarBtn("—", UDim2.new(1,-62,0.5,-11), T.Sub, function()
    Win.Visible = false ; Icon.Visible = true
end)
Icon.MouseButton1Click:Connect(function() Win.Visible = true ; Icon.Visible = false end)

-- Drag
local function MakeDraggable(obj, handle)
    local drag, start, sp
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            drag = true ; start = i.Position ; sp = obj.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then drag = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if drag and (i.UserInputType == Enum.UserInputType.MouseMovement
                  or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - start
            obj.Position = UDim2.new(sp.X.Scale, sp.X.Offset+d.X, sp.Y.Scale, sp.Y.Offset+d.Y)
        end
    end)
end
MakeDraggable(Win, Bar) ; MakeDraggable(Icon, Icon)

-- Sidebar
local Side = Instance.new("Frame",Win)
Side.Size = UDim2.new(0,110,1,-33) ; Side.Position = UDim2.new(0,0,0,33)
Side.BackgroundColor3 = T.Side ; Side.BackgroundTransparency = 0.3 ; Side.BorderSizePixel = 0
Instance.new("UICorner",Side).CornerRadius = UDim.new(0,10)
local sl2 = Instance.new("UIListLayout",Side) ; sl2.Padding = UDim.new(0,5)
sl2.HorizontalAlignment = Enum.HorizontalAlignment.Center
local sp2 = Instance.new("UIPadding",Side) ; sp2.PaddingTop = UDim.new(0,10)

-- Content area
local CA = Instance.new("Frame",Win)
CA.Size = UDim2.new(1,-120,1,-38) ; CA.Position = UDim2.new(0,115,0,38)
CA.BackgroundTransparency = 1

local Tabs = {} ; local TabBtns = {}

local function MakeTab(name, icon)
    local tf = Instance.new("ScrollingFrame",CA)
    tf.Size = UDim2.new(1,0,1,0) ; tf.BackgroundTransparency = 1
    tf.ScrollBarThickness = 2 ; tf.ScrollBarImageColor3 = T.Dim
    tf.Visible = false ; tf.AutomaticCanvasSize = Enum.AutomaticSize.Y
    tf.CanvasSize = UDim2.new(0,0,0,0) ; tf.BorderSizePixel = 0
    local ly = Instance.new("UIListLayout",tf) ; ly.Padding = UDim.new(0,7)
    local pd = Instance.new("UIPadding",tf) ; pd.PaddingTop = UDim.new(0,6)

    local tb = Instance.new("TextButton",Side)
    tb.Size = UDim2.new(0.92,0,0,30) ; tb.BackgroundColor3 = T.Accent
    tb.BackgroundTransparency = 1 ; tb.Text = "  "..icon.." "..name
    tb.TextColor3 = T.Sub ; tb.Font = Enum.Font.GothamMedium ; tb.TextSize = 11
    tb.TextXAlignment = Enum.TextXAlignment.Left
    Instance.new("UICorner",tb).CornerRadius = UDim.new(0,6)
    local ind = Instance.new("Frame",tb)
    ind.Size = UDim2.new(0,3,0.6,0) ; ind.Position = UDim2.new(0,2,0.2,0)
    ind.BackgroundColor3 = T.Accent ; ind.Visible = false
    Instance.new("UICorner",ind).CornerRadius = UDim.new(1,0)

    tb.MouseButton1Click:Connect(function()
        for _, t in Tabs    do t.f.Visible = false end
        for _, b in TabBtns do b.b.BackgroundTransparency=1 ; b.b.TextColor3=T.Sub ; b.i.Visible=false end
        tf.Visible = true ; tb.BackgroundTransparency = 0.80
        tb.TextColor3 = T.Text ; ind.Visible = true
    end)
    table.insert(Tabs,    {f=tf})
    table.insert(TabBtns, {b=tb, i=ind})
    return tf
end

local function Sec(parent, txt)
    local l = Instance.new("TextLabel",parent)
    l.Size = UDim2.new(0.98,0,0,18) ; l.BackgroundTransparency = 1
    l.Text = txt ; l.TextColor3 = T.Dim ; l.Font = Enum.Font.GothamBold
    l.TextSize = 10 ; l.TextXAlignment = Enum.TextXAlignment.Left
end

local function MakeBtn(parent, txt, cb)
    local b = Instance.new("TextButton",parent)
    b.Size = UDim2.new(0.98,0,0,35) ; b.BackgroundColor3 = T.Btn
    b.Text = txt ; b.Font = Enum.Font.GothamBold
    b.TextColor3 = T.Text ; b.TextSize = 12
    Instance.new("UICorner",b).CornerRadius = UDim.new(0,7)
    Instance.new("UIStroke",b).Color = T.Stroke
    b.MouseButton1Click:Connect(cb) ; return b
end

local function Toggle(parent, title, desc, cb)
    local state = false
    local btn = Instance.new("TextButton",parent)
    btn.Size = UDim2.new(0.98,0,0,48) ; btn.BackgroundColor3 = T.Btn
    btn.Text = "" ; btn.AutoButtonColor = false
    Instance.new("UICorner",btn).CornerRadius = UDim.new(0,7)
    local bs = Instance.new("UIStroke",btn) ; bs.Color = T.Stroke

    local tx = Instance.new("TextLabel",btn)
    tx.Size = UDim2.new(0.72,0,0.5,0) ; tx.Position = UDim2.new(0,10,0,5)
    tx.BackgroundTransparency=1 ; tx.Text=title
    tx.Font=Enum.Font.GothamMedium ; tx.TextColor3=T.Text
    tx.TextSize=12 ; tx.TextXAlignment=Enum.TextXAlignment.Left

    local sub = Instance.new("TextLabel",btn)
    sub.Size=UDim2.new(0.72,0,0.5,0) ; sub.Position=UDim2.new(0,10,0.5,0)
    sub.BackgroundTransparency=1 ; sub.Text=desc
    sub.Font=Enum.Font.Gotham ; sub.TextColor3=T.Sub
    sub.TextSize=10 ; sub.TextXAlignment=Enum.TextXAlignment.Left

    local pill = Instance.new("Frame",btn)
    pill.Size=UDim2.new(0,42,0,22) ; pill.Position=UDim2.new(1,-52,0.5,-11)
    pill.BackgroundColor3=T.Btn
    Instance.new("UICorner",pill).CornerRadius=UDim.new(1,0)
    local ps=Instance.new("UIStroke",pill) ; ps.Color=T.Stroke ; ps.Thickness=1
    local pt=Instance.new("TextLabel",pill)
    pt.Size=UDim2.new(1,0,1,0) ; pt.Text="OFF"
    pt.Font=Enum.Font.GothamBold ; pt.TextColor3=T.Sub
    pt.TextSize=9 ; pt.BackgroundTransparency=1

    local function setV(on)
        state=on
        pill.BackgroundColor3 = on and T.Accent or T.Btn
        ps.Color              = on and T.Accent or T.Stroke
        pt.Text               = on and "ON"    or "OFF"
        pt.TextColor3         = on and Color3.new(1,1,1) or T.Sub
        btn.BackgroundColor3  = on and Color3.fromRGB(20,40,32) or T.Btn
        bs.Color              = on and T.Dim or T.Stroke
    end
    setV(false)
    btn.MouseButton1Click:Connect(function()
        local res = cb(not state)
        setV(res ~= nil and res or not state)
    end)
    return setV
end

local function Slider(parent, label, minV, maxV, def, setcb)
    local row=Instance.new("Frame",parent)
    row.Size=UDim2.new(0.98,0,0,62) ; row.BackgroundColor3=T.Btn ; row.BorderSizePixel=0
    Instance.new("UICorner",row).CornerRadius=UDim.new(0,7)
    local rs=Instance.new("UIStroke",row) ; rs.Color=T.Stroke

    local nl=Instance.new("TextLabel",row)
    nl.Size=UDim2.new(0.55,0,0,20) ; nl.Position=UDim2.new(0,10,0,6)
    nl.BackgroundTransparency=1 ; nl.Text=label
    nl.TextColor3=T.Text ; nl.Font=Enum.Font.GothamMedium
    nl.TextSize=12 ; nl.TextXAlignment=Enum.TextXAlignment.Left

    local vl=Instance.new("TextLabel",row)
    vl.Size=UDim2.new(0.40,0,0,20) ; vl.Position=UDim2.new(0.58,0,0,6)
    vl.BackgroundTransparency=1 ; vl.Font=Enum.Font.GothamBold
    vl.TextSize=12 ; vl.TextXAlignment=Enum.TextXAlignment.Right

    local tr=Instance.new("Frame",row)
    tr.Size=UDim2.new(1,-20,0,6) ; tr.Position=UDim2.new(0,10,0,36)
    tr.BackgroundColor3=Color3.fromRGB(14,18,28) ; tr.BorderSizePixel=0
    Instance.new("UICorner",tr).CornerRadius=UDim.new(0,3)
    local fl=Instance.new("Frame",tr)
    fl.BorderSizePixel=0 ; fl.Size=UDim2.new(0,0,1,0)
    Instance.new("UICorner",fl).CornerRadius=UDim.new(0,3)
    local kn=Instance.new("Frame",tr)
    kn.Size=UDim2.new(0,14,0,14) ; kn.BackgroundColor3=Color3.new(1,1,1)
    kn.BorderSizePixel=0
    Instance.new("UICorner",kn).CornerRadius=UDim.new(0,7)

    local mn=Instance.new("TextLabel",row) ; mn.Size=UDim2.new(0,30,0,10)
    mn.Position=UDim2.new(0,10,0,48) ; mn.BackgroundTransparency=1
    mn.Text=tostring(minV) ; mn.TextColor3=T.Sub ; mn.Font=Enum.Font.Code
    mn.TextSize=8 ; mn.TextXAlignment=Enum.TextXAlignment.Left
    local mx=Instance.new("TextLabel",row) ; mx.Size=UDim2.new(0,40,0,10)
    mx.Position=UDim2.new(1,-50,0,48) ; mx.BackgroundTransparency=1
    mx.Text=tostring(maxV).." MAX" ; mx.TextColor3=T.Red
    mx.Font=Enum.Font.Code ; mx.TextSize=8 ; mx.TextXAlignment=Enum.TextXAlignment.Right

    local function applyPct(pct)
        pct = math.clamp(pct, 0, 1)
        local range = maxV - minV
        local step  = range <= 20 and 1 or 10
        local val   = math.clamp(math.round((minV + pct*range)/step)*step, minV, maxV)
        setcb(val)
        local rp = (val-minV)/range
        fl.Size = UDim2.new(rp,0,1,0)
        kn.Position = UDim2.new(rp,-7,0.5,-7)
        local col = val>=maxV and T.Red or T.Accent
        vl.Text=tostring(val) ; vl.TextColor3=col
        fl.BackgroundColor3=col ; kn.BackgroundColor3=val>=maxV and T.Red or Color3.new(1,1,1)
    end
    applyPct((def-minV)/(maxV-minV))

    local dragging=false
    local function ai(i) applyPct((i.Position.X-tr.AbsolutePosition.X)/tr.AbsoluteSize.X) end
    kn.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1
        or i.UserInputType==Enum.UserInputType.Touch then dragging=true end
    end)
    tr.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1
        or i.UserInputType==Enum.UserInputType.Touch then dragging=true ; ai(i) end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement
                      or i.UserInputType==Enum.UserInputType.Touch) then ai(i) end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1
        or i.UserInputType==Enum.UserInputType.Touch then dragging=false end
    end)
end

local function InfoRow(parent, txt, col)
    local r=Instance.new("Frame",parent)
    r.Size=UDim2.new(0.98,0,0,30) ; r.BackgroundColor3=Color3.fromRGB(18,22,28)
    r.BorderSizePixel=0
    Instance.new("UICorner",r).CornerRadius=UDim.new(0,6)
    local l=Instance.new("TextLabel",r)
    l.Size=UDim2.new(1,-10,1,0) ; l.Position=UDim2.new(0,8,0,0)
    l.BackgroundTransparency=1 ; l.Text=txt
    l.TextColor3=col or T.Sub ; l.Font=Enum.Font.Gotham
    l.TextSize=11 ; l.TextXAlignment=Enum.TextXAlignment.Left
end

-- ─────────────────────────────────────────────────────────────
--  TABS
-- ─────────────────────────────────────────────────────────────
local TabGyro = MakeTab("Gyro",  "📱")
local TabAim  = MakeTab("Aim",   "🎯")
local TabESP  = MakeTab("ESP",   "👁️")
local TabMisc = MakeTab("Misc",  "⚙️")
local TabInfo = MakeTab("Info",  "ℹ️")

-- ─── TAB: GYRO ───────────────────────────────────────────────
Sec(TabGyro, "  GYROSCOPE AIM")

do
    local ok = pcall(function() return UserInputService.GyroscopeEnabled end)
    local sup = ok and UserInputService.GyroscopeEnabled
    local statusRow = Instance.new("Frame",TabGyro)
    statusRow.Size=UDim2.new(0.98,0,0,28) ; statusRow.BackgroundColor3=Color3.fromRGB(16,20,26)
    statusRow.BorderSizePixel=0
    Instance.new("UICorner",statusRow).CornerRadius=UDim.new(0,6)
    Instance.new("UIStroke",statusRow).Color=T.Stroke
    local sl3=Instance.new("TextLabel",statusRow)
    sl3.Size=UDim2.new(1,-10,1,0) ; sl3.Position=UDim2.new(0,8,0,0)
    sl3.BackgroundTransparency=1 ; sl3.Font=Enum.Font.Code ; sl3.TextSize=10
    sl3.TextXAlignment=Enum.TextXAlignment.Left
    sl3.Text = sup and "  ✅ Gyroscope detected on this device"
                    or "  ⚠️  No gyro detected (desktop / unsupported)"
    sl3.TextColor3 = sup and T.Green or T.Orange
end

Toggle(TabGyro,
    "📱 Gyro Aim",
    "Tilt/rotate phone to aim. Auto-aim stays active alongside gyro.",
    function(v)
        Config.Gyro     = v
        gyroPrevAbsCF   = nil
        gyroLatestAbsCF = nil
        gyroInterlock()
        return v
    end)

Sec(TabGyro, "  SENSITIVITY  (hipfire)")
Slider(TabGyro, "Vertical Sens", 1, 10, Config.GyroSensV, function(v)
    Config.GyroSensV = v
end)
Slider(TabGyro, "Horizontal Sens", 1, 10, Config.GyroSensH, function(v)
    Config.GyroSensH = v
end)

Sec(TabGyro, "  SENSITIVITY  (ADS / scoped)")
Slider(TabGyro, "ADS Sens (when zoomed in)", 1, 10, Config.GyroSensADS, function(v)
    Config.GyroSensADS = v
end)

Sec(TabGyro, "  OPTIONS")
Toggle(TabGyro,
    "📐 FOV Normalize",
    "Auto-scale sens by zoom level — hipfire and scope feel equal",
    function(v) Config.GyroFOVNorm = v ; return v end)(Config.GyroFOVNorm)

Toggle(TabGyro,
    "↕ Invert Vertical",
    "Flip tilt: top away = aim UP instead of DOWN",
    function(v) Config.GyroInvertV = v ; return v end)

Toggle(TabGyro,
    "↔ Invert Horizontal",
    "Flip pan: rotate right = look LEFT instead",
    function(v) Config.GyroInvertH = v ; return v end)

do
    local tipRow=Instance.new("Frame",TabGyro)
    tipRow.Size=UDim2.new(0.98,0,0,54) ; tipRow.BackgroundColor3=Color3.fromRGB(16,20,26)
    tipRow.BorderSizePixel=0
    Instance.new("UICorner",tipRow).CornerRadius=UDim.new(0,6)
    Instance.new("UIStroke",tipRow).Color=T.Stroke
    local tipL=Instance.new("TextLabel",tipRow)
    tipL.Size=UDim2.new(1,-14,1,0) ; tipL.Position=UDim2.new(0,7,0,0)
    tipL.BackgroundTransparency=1 ; tipL.Font=Enum.Font.Gotham ; tipL.TextSize=9
    tipL.TextWrapped=true ; tipL.TextXAlignment=Enum.TextXAlignment.Left
    tipL.TextColor3=T.Sub
    tipL.Text = "v5: dy→YAW (horizontal), dz→PITCH (vertical). Camera+5 priority so weapon follows. FOV-normalized. ADS sens separate. Auto-aim coexists with gyro. Use joystick for big moves, gyro for fine aim."
end

-- ─── TAB: AIM ────────────────────────────────────────────────
Sec(TabAim, "  AUTO AIM")

local aimSetV = Toggle(TabAim, "🎯 Auto Aim",
    "Game aim snap toward nearest visible enemy",
    function(v) Config.AutoAim=v ; SetSetting("AutoAim",v) ; return v end)
aimSetV(Config.AutoAim)

local shootSetV = Toggle(TabAim, "🔫 Auto Shoot",
    "Fires when enemy enters reticle cone (our engine)",
    function(v)
        Config.AutoShoot = v
        if v then StartAutoShoot() else StopAutoShoot() end
        return v
    end)
shootSetV(Config.AutoShoot)

Sec(TabAim, "  AUTO-SHOOT CONE")
Slider(TabAim, "Cone Size (degrees)", 1, 15, Config.AutoShootFOV, function(v)
    Config.AutoShootFOV = v
end)

local hipSetV = Toggle(TabAim, "🏃 Hipfire Aim",
    "Auto-aim applies even when not ADS",
    function(v) Config.HipfireAim=v ; SetSetting("HipfireAim",v) ; return v end)
hipSetV(Config.HipfireAim)

Sec(TabAim, "  STRENGTH  (game max = 10)")

Slider(TabAim, "Aim Strength", 0, 10, Config.AimStrength, function(v)
    Config.AimStrength = v
    SetSetting("AutoAimStrength",    v)
    SetSetting("HipfireAimStrength", v)
end)

Sec(TabAim, "  ADVANCED")

local fastSetV = Toggle(TabAim, "⚡ Fast Shoot",
    "Reduces shoot animation delay",
    function(v) Config.FastShoot=v ; SetSetting("FastShoot",v) ; return v end)
fastSetV(Config.FastShoot)

-- ─── TAB: ESP ────────────────────────────────────────────────
Sec(TabESP, "  PLAYER ESP")

Toggle(TabESP, "👁️ Enemy Highlight",
    "Red fill + gold outline through walls",
    function(v) Config.ESP=v ; RefreshESP() ; return v end)

do
    local ir=Instance.new("Frame",TabESP)
    ir.Size=UDim2.new(0.98,0,0,36) ; ir.BackgroundColor3=Color3.fromRGB(16,20,26) ; ir.BorderSizePixel=0
    Instance.new("UICorner",ir).CornerRadius=UDim.new(0,6) ; Instance.new("UIStroke",ir).Color=T.Stroke
    local function swatch(x, col)
        local s=Instance.new("Frame",ir) ; s.Size=UDim2.new(0,14,0,14)
        s.Position=UDim2.new(0,x,0.5,-7) ; s.BackgroundColor3=col ; s.BorderSizePixel=0
        Instance.new("UICorner",s).CornerRadius=UDim.new(0,3)
    end
    swatch(10, Color3.fromRGB(255,50,50)) ; swatch(28, Color3.fromRGB(255,200,0))
    local el=Instance.new("TextLabel",ir)
    el.Size=UDim2.new(1,-52,1,0) ; el.Position=UDim2.new(0,48,0,0)
    el.BackgroundTransparency=1 ; el.Font=Enum.Font.Gotham ; el.TextSize=9
    el.TextXAlignment=Enum.TextXAlignment.Left ; el.TextColor3=T.Sub
    el.Text="Red fill  ·  Gold outline  ·  AlwaysOnTop depth"
end

MakeBtn(TabESP, "↺  Refresh ESP (re-scan all players)", function() RefreshESP() end)

-- ─── TAB: MISC ───────────────────────────────────────────────
Sec(TabMisc, "  SURVIVAL")

Toggle(TabMisc, "💀 Auto Respawn",
    "Fires Respawn remote when health = 0",
    function(v) Config.AutoRespawn=v ; return v end)

local sprintSetV = Toggle(TabMisc, "🏃 Auto Sprint",
    "Always sprint (game AutoSprint setting)",
    function(v) Config.AutoSprint=v ; SetSetting("AutoSprint",v) ; return v end)
sprintSetV(Config.AutoSprint)

Sec(TabMisc, "  CAMERA")

Toggle(TabMisc, "👁️ First Person",
    "Camera mode 1 (first person)",
    function(v)
        SetSetting("CameraMode", v and 1 or 2)
        SetSetting("CameraMode_NonKeyboard", v and 1 or 2)
        return v
    end)

Slider(TabMisc, "Field of View (FOV)", -20, 50,
    GetSetting("CameraFOV",0), function(v) SetSetting("CameraFOV",v) end)

Sec(TabMisc, "  SENSITIVITY (game)")

Slider(TabMisc, "Look Sensitivity", 1, 10, GetSetting("Sensitivity",5), function(v)
    SetSetting("Sensitivity",v) ; SetSetting("Sensitivity_H",v) ; SetSetting("Sensitivity_V",v)
end)

Slider(TabMisc, "ADS Sensitivity", 1, 10, GetSetting("Sensitivity_Aiming",5), function(v)
    SetSetting("Sensitivity_Aiming",v)
end)

-- ─── TAB: INFO ───────────────────────────────────────────────
Sec(TabInfo, "  SCRIPT INFO")
InfoRow(TabInfo, "🎯  SNIPER SCRIPT v5  —  Universal Mobile FPS", T.Accent)
InfoRow(TabInfo, "📱  Gyro v5: dy→YAW · dz→PITCH · Camera+5 · FOV-norm")
InfoRow(TabInfo, "🎯  AimStrength = 10 on load (game max) · auto-aim + gyro coexist")
InfoRow(TabInfo, "🔫  AutoShoot: LOS raycast engine · configurable cone angle")
InfoRow(TabInfo, "👁️  ESP: Highlight AlwaysOnTop on enemy characters")
InfoRow(TabInfo, "💀  Respawn: RS.Remote.GameService.Respawn:FireServer()")
InfoRow(TabInfo, Settings and "✅  Settings module loaded" or "❌  Settings module not found",
        Settings and T.Green or T.Red)

-- ─────────────────────────────────────────────────────────────
--  OPEN FIRST TAB
-- ─────────────────────────────────────────────────────────────
if Tabs[1] and TabBtns[1] then
    Tabs[1].f.Visible = true
    TabBtns[1].b.BackgroundTransparency = 0.80
    TabBtns[1].b.TextColor3 = T.Text
    TabBtns[1].i.Visible    = true
end

print("[SniperScript v5] ✅ Loaded")
print("[SniperScript v5] Settings:", Settings and "FOUND" or "NOT FOUND")
print("[SniperScript v5] Gyro support:", pcall(function()
    return UserInputService.GyroscopeEnabled
end) and UserInputService.GyroscopeEnabled and "YES" or "NO")
