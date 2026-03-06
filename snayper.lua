--[[
  ══════════════════════════════════════════════════════════════
  SNIPER SCRIPT  —  Universal Sniper (Mobile FPS)
  ══════════════════════════════════════════════════════════════
  Analyzed files:
    • Full_Master_Logic.lua   — Full decompiled game source
    • Extracted_mygamesniper/ — 100+ LocalScripts & Modules
    • Universal_Tree_Dump.txt — Full workspace/RS tree dump
    • Live_Remote_Logs.txt    — Captured FireServer remotes

  Remotes confirmed:
    ReplicatedStorage.Remote.GameService.Respawn  (no args)
    ReplicatedStorage.Remote.GameService.Leave    (no args)

  Settings path:
    require(RS.Common.SettingService.Settings)
      → AutoShoot, AutoAim, AutoAimStrength, FastShoot,
        AutoSprint, CameraMode, CameraFOV, Sensitivity,
        Sensitivity_H, Sensitivity_V, Sensitivity_Aiming,
        InvertX, InvertY, HipfireAim, HipfireAimStrength
      (Changed listener auto-syncs each .Value to server)

  Entities: Workspace.World.{roomID}.Entities.{name}.{uuid}
  Characters: Workspace.{PlayerName}  (standard R15 rig)
  Highlight: Workspace.Highlight.EnemyXRay / .Enemy
  ══════════════════════════════════════════════════════════════
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
local Workspace        = game:GetService("Workspace")
local player           = Players.LocalPlayer

-- Force landscape on mobile
pcall(function() StarterGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeRight end)
pcall(function() player.PlayerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeRight end)

-- GUI mount target
local guiTarget = (type(gethui) == "function" and gethui())
    or (pcall(function() return CoreGui end) and CoreGui)
    or player:WaitForChild("PlayerGui")

-- Anti-overlap
if guiTarget:FindFirstChild("SS_Load") then guiTarget.SS_Load:Destroy() end
if guiTarget:FindFirstChild("SS_Main") then guiTarget.SS_Main:Destroy() end

-- ─────────────────────────────────────────────────────────────
--  GAME SETTINGS ACCESS  (RS.Common.SettingService.Settings)
--  Changing .Value auto-syncs to server via Changed listener.
-- ─────────────────────────────────────────────────────────────
local Settings = nil
do
    local ok, result = pcall(require, RS:WaitForChild("Common", 3)
        and RS.Common:WaitForChild("SettingService", 3)
        and RS.Common.SettingService:WaitForChild("Settings", 3))
    if ok and type(result) == "table" then
        Settings = result
    else
        -- fallback: try Remote.SettingService wrapper
        local ok2, svc = pcall(require, RS:FindFirstChild("Remote")
            and RS.Remote:FindFirstChild("SettingService"))
        if ok2 and svc and svc.Settings then
            Settings = svc.Settings
        end
    end
end

-- Safe helper: set a game setting's Value and let Changed auto-sync
local function SetSetting(key, val)
    if not Settings then return end
    local s = Settings[key]
    if s then
        pcall(function() s.Value = val end)
    end
end

local function GetSetting(key, default)
    if not Settings then return default end
    local s = Settings[key]
    if s then return s.Value end
    return default
end

-- ─────────────────────────────────────────────────────────────
--  REMOTES
-- ─────────────────────────────────────────────────────────────
local GameServiceRemote = RS:FindFirstChild("Remote") and RS.Remote:FindFirstChild("GameService")
local RespawnRemote = GameServiceRemote and GameServiceRemote:FindFirstChild("Respawn")
local LeaveRemote   = GameServiceRemote and GameServiceRemote:FindFirstChild("Leave")

-- ─────────────────────────────────────────────────────────────
--  SCRIPT CONFIG  (local state)
-- ─────────────────────────────────────────────────────────────
local Config = {
    -- Gyro
    Gyro           = false,
    GyroSensH      = 2.0,   -- horizontal gyro multiplier
    GyroSensV      = 2.0,   -- vertical gyro multiplier
    -- Aim
    AutoAim        = GetSetting("AutoAim", true),
    AutoShoot      = GetSetting("AutoShoot", true),
    AimStrength    = GetSetting("AutoAimStrength", 5),
    FastShoot      = GetSetting("FastShoot", false),
    HipfireAim     = GetSetting("HipfireAim", true),
    -- Misc
    AutoRespawn    = false,
    AutoSprint     = GetSetting("AutoSprint", true),
    -- ESP
    ESP            = false,
}

-- ─────────────────────────────────────────────────────────────
--  LOADING SCREEN
-- ─────────────────────────────────────────────────────────────
local loadGui = Instance.new("ScreenGui")
loadGui.Name           = "SS_Load"
loadGui.IgnoreGuiInset = true
loadGui.ResetOnSpawn   = false
loadGui.Parent         = guiTarget

local bg = Instance.new("Frame", loadGui)
bg.Size             = UDim2.new(1, 0, 1, 0)
bg.BackgroundColor3 = Color3.fromRGB(4, 5, 9)
bg.BorderSizePixel  = 0

local vig = Instance.new("UIGradient", bg)
vig.Color = ColorSequence.new{
    ColorSequenceKeypoint.new(0,   Color3.fromRGB(0, 0, 0)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(6, 8, 14)),
    ColorSequenceKeypoint.new(1,   Color3.fromRGB(0, 0, 0)),
}
vig.Rotation = 45
vig.Transparency = NumberSequence.new{
    NumberSequenceKeypoint.new(0,   0.6),
    NumberSequenceKeypoint.new(0.5, 0),
    NumberSequenceKeypoint.new(1,   0.6),
}

local titleLbl = Instance.new("TextLabel", bg)
titleLbl.Size               = UDim2.new(1, 0, 0, 50)
titleLbl.Position           = UDim2.new(0, 0, 0.22, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text               = "SNIPER SCRIPT"
titleLbl.TextColor3         = Color3.fromRGB(0, 200, 150)
titleLbl.Font               = Enum.Font.GothamBlack
titleLbl.TextSize            = 38

local subLbl = Instance.new("TextLabel", bg)
subLbl.Size               = UDim2.new(1, 0, 0, 24)
subLbl.Position           = UDim2.new(0, 0, 0.36, 0)
subLbl.BackgroundTransparency = 1
subLbl.Text               = "Mobile FPS  ·  Gyro + Aim + ESP + Misc"
subLbl.TextColor3         = Color3.fromRGB(60, 130, 100)
subLbl.Font               = Enum.Font.GothamBold
subLbl.TextSize           = 14

-- Route dots
local ROUTE_LABELS = {"⚙️ Init", "◆ Settings", "◆ Gyro", "◆ ESP", "🎯 Ready"}
local routeY = 0.50
local routeDots = {}
for i, label in ipairs(ROUTE_LABELS) do
    local xpct = (i - 1) / (#ROUTE_LABELS - 1) * 0.7 + 0.15
    if i > 1 then
        local prevX = (i - 2) / (#ROUTE_LABELS - 1) * 0.7 + 0.15
        local lf = Instance.new("Frame", bg)
        lf.Size             = UDim2.new(xpct - prevX, -4, 0, 2)
        lf.Position         = UDim2.new(prevX, 6, routeY, 4)
        lf.BackgroundColor3 = Color3.fromRGB(20, 40, 30)
        lf.BorderSizePixel  = 0
        routeDots[i] = routeDots[i] or {}
        routeDots[i].line = lf
    end
    local dot = Instance.new("Frame", bg)
    dot.Size             = UDim2.new(0, 10, 0, 10)
    dot.Position         = UDim2.new(xpct, -5, routeY, 0)
    dot.BackgroundColor3 = Color3.fromRGB(20, 40, 30)
    dot.BorderSizePixel  = 0
    Instance.new("UICorner", dot).CornerRadius = UDim.new(0, 5)
    local lbl2 = Instance.new("TextLabel", bg)
    lbl2.Size               = UDim2.new(0, 80, 0, 16)
    lbl2.Position           = UDim2.new(xpct, -40, routeY, 14)
    lbl2.BackgroundTransparency = 1
    lbl2.Text               = label
    lbl2.TextColor3         = Color3.fromRGB(30, 55, 40)
    lbl2.Font               = Enum.Font.Code
    lbl2.TextSize           = 10
    routeDots[i]     = routeDots[i] or {}
    routeDots[i].dot = dot
    routeDots[i].lbl = lbl2
end

-- Progress bar
local barTrack = Instance.new("Frame", bg)
barTrack.Size             = UDim2.new(0.5, 0, 0, 5)
barTrack.Position         = UDim2.new(0.25, 0, 0.68, 0)
barTrack.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
barTrack.BorderSizePixel  = 0
Instance.new("UICorner", barTrack).CornerRadius = UDim.new(0, 3)
local barFill = Instance.new("Frame", barTrack)
barFill.Size             = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = Color3.fromRGB(0, 200, 150)
barFill.BorderSizePixel  = 0
Instance.new("UICorner", barFill).CornerRadius = UDim.new(0, 3)
local barTxt = Instance.new("TextLabel", bg)
barTxt.Size               = UDim2.new(1, 0, 0, 18)
barTxt.Position           = UDim2.new(0, 0, 0.72, 0)
barTxt.BackgroundTransparency = 1
barTxt.TextColor3         = Color3.fromRGB(40, 90, 65)
barTxt.Font               = Enum.Font.Code
barTxt.TextSize           = 12

-- Animated speed lines
local speedLines = {}
math.randomseed(99)
for i = 1, 12 do
    local ln = Instance.new("Frame", bg)
    local yp  = math.random(10, 90) / 100
    local w   = math.random(60, 160) / 1000
    local xp  = math.random(0, 80) / 100
    ln.Size              = UDim2.new(w, 0, 0, 1)
    ln.Position          = UDim2.new(xp, 0, yp, 0)
    ln.BackgroundColor3  = Color3.fromRGB(0, 200, 150)
    ln.BorderSizePixel   = 0
    ln.BackgroundTransparency = 0.6 + math.random() * 0.3
    speedLines[i] = { frame = ln, speed = math.random(40, 120) / 100, x = xp, w = w }
end
local loadAnimConn = RunService.Heartbeat:Connect(function(dt)
    for _, sl in ipairs(speedLines) do
        sl.x = sl.x + sl.speed * dt * 0.15
        if sl.x > 1 then sl.x = -sl.w end
        sl.frame.Position = UDim2.new(sl.x, 0, sl.frame.Position.Y.Scale, 0)
    end
end)

-- Camera cinematic
local cam = Workspace.CurrentCamera
cam.CameraType = Enum.CameraType.Scriptable
local CAM_ROUTE = {
    { CFrame.new(0, 20, 80) * CFrame.Angles(math.rad(-10), 0, 0) },
    { CFrame.new(40, 15, 60) * CFrame.Angles(math.rad(-5), math.rad(-30), 0) },
    { CFrame.new(-30, 25, 70) * CFrame.Angles(math.rad(-15), math.rad(20), 0) },
}

local function SetProg(pct, msg, activeDot)
    TweenService:Create(barFill, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Size = UDim2.new(pct / 100, 0, 1, 0) }):Play()
    barTxt.Text = string.format("  %d%%  —  %s", math.floor(pct), msg)
    local ci = math.max(1, math.min(#CAM_ROUTE, math.round(pct / 100 * #CAM_ROUTE + 0.5)))
    TweenService:Create(cam, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
        { CFrame = CAM_ROUTE[ci][1] }):Play()
    for i, d in ipairs(routeDots) do
        local on  = activeDot and i <= activeDot
        local col = on and Color3.fromRGB(0, 200, 150) or Color3.fromRGB(20, 40, 30)
        local tc  = on and Color3.fromRGB(0, 220, 160) or Color3.fromRGB(30, 55, 40)
        if d.dot  then TweenService:Create(d.dot,  TweenInfo.new(0.25), { BackgroundColor3 = col }):Play() end
        if d.lbl  then d.lbl.TextColor3 = tc end
        if d.line then TweenService:Create(d.line, TweenInfo.new(0.25), { BackgroundColor3 = col }):Play() end
    end
end

-- ─────────────────────────────────────────────────────────────
--  LOADING SEQUENCE
-- ─────────────────────────────────────────────────────────────
SetProg(5,  "Initialising script...", 1) ; task.wait(0.2)
SetProg(25, "Hooking game settings...", 2) ; task.wait(0.25)
SetProg(50, "Setting up Gyro engine...", 3) ; task.wait(0.25)
SetProg(75, "Preparing ESP + Highlights...", 4) ; task.wait(0.25)
SetProg(95, "Finalising hooks...", 5) ; task.wait(0.2)
SetProg(100, "Ready!")
task.wait(0.5)

-- Dismiss loading
if loadAnimConn then loadAnimConn:Disconnect() end
pcall(function()
    TweenService:Create(cam, TweenInfo.new(0), { CFrame = cam.CFrame }):Play()
end)
task.wait()
cam.CameraType    = Enum.CameraType.Custom
cam.CameraSubject = nil
task.wait()
TweenService:Create(bg, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
    { BackgroundTransparency = 1 }):Play()
for _, d in ipairs(loadGui:GetDescendants()) do
    if d:IsA("TextLabel") then pcall(function()
        TweenService:Create(d, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
    end) end
    if d:IsA("Frame") then pcall(function()
        TweenService:Create(d, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
    end) end
end
task.wait(0.6)
if loadGui then loadGui:Destroy() end

-- ═════════════════════════════════════════════════════════════
--  GYRO ENGINE
--  DeviceRotationChanged fires every frame the device moves.
--  deltaRotation is the CFrame change since the previous frame.
--  We accumulate pitch/yaw deltas and apply them to the camera
--  via BindToRenderStep at Camera+1 priority (runs after the
--  game's own CameraController finishes its frame update).
-- ═════════════════════════════════════════════════════════════
local gyroAccumPitch = 0
local gyroAccumYaw   = 0
local gyroPitchClamp = math.rad(85) -- max tilt up/down

-- Accumulate gyro delta each device-rotation event
UserInputService.DeviceRotationChanged:Connect(function(_, deltaRotation)
    if not Config.Gyro then return end
    -- deltaRotation:ToEulerAnglesXYZ()
    --   X → tilt up/down (pitch)  — tilting phone forward = aim up = negative pitch in game
    --   Y → rotate left/right (yaw)
    local dPitch, dYaw, _ = deltaRotation:ToEulerAnglesXYZ()
    gyroAccumPitch = gyroAccumPitch - dPitch * Config.GyroSensV
    gyroAccumYaw   = gyroAccumYaw   - dYaw   * Config.GyroSensH
end)

-- Apply accumulated delta AFTER the game's camera update each frame
RunService:BindToRenderStep("SS_Gyro", Enum.RenderPriority.Camera.Value + 1, function()
    if not Config.Gyro then
        gyroAccumPitch = 0
        gyroAccumYaw   = 0
        return
    end
    if gyroAccumPitch == 0 and gyroAccumYaw == 0 then return end

    local camCF = Workspace.CurrentCamera.CFrame
    local pitch, yaw, _ = camCF:ToEulerAnglesYXZ()

    -- Apply accumulated gyro deltas
    local newPitch = math.clamp(pitch + gyroAccumPitch, -gyroPitchClamp, gyroPitchClamp)
    local newYaw   = yaw + gyroAccumYaw

    Workspace.CurrentCamera.CFrame =
        CFrame.new(camCF.Position) * CFrame.fromEulerAnglesYXZ(newPitch, newYaw, 0)

    -- Reset accumulators (consumed this frame)
    gyroAccumPitch = 0
    gyroAccumYaw   = 0
end)

-- ═════════════════════════════════════════════════════════════
--  ESP ENGINE
--  Creates Highlight instances on enemy characters.
--  Enemies = all players NOT on the local player's team.
--  Characters live at Workspace.{PlayerName} (standard R15).
-- ═════════════════════════════════════════════════════════════
local espHighlights = {}

local function RemoveESP(p)
    if espHighlights[p] then
        pcall(function() espHighlights[p]:Destroy() end)
        espHighlights[p] = nil
    end
end

local function AddESP(p)
    if p == player then return end
    RemoveESP(p)
    local char = p.Character
    if not char then return end
    -- Check if enemy (different team OR no team assigned)
    local isEnemy = true
    pcall(function()
        isEnemy = player.Team == nil or p.Team == nil or player.Team ~= p.Team
    end)
    if not isEnemy then return end

    local hl = Instance.new("Highlight")
    hl.FillColor      = Color3.fromRGB(255, 50, 50)
    hl.OutlineColor   = Color3.fromRGB(255, 200, 0)
    hl.FillTransparency    = 0.55
    hl.OutlineTransparency = 0
    hl.DepthMode      = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Adornee        = char
    hl.Parent         = char
    espHighlights[p]  = hl
end

local function RefreshESP()
    -- Remove all existing
    for p in pairs(espHighlights) do RemoveESP(p) end
    if not Config.ESP then return end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character then
            AddESP(p)
        end
    end
end

-- Track character changes
Players.PlayerAdded:Connect(function(p)
    p.CharacterAdded:Connect(function()
        task.wait(0.5)
        if Config.ESP then AddESP(p) end
    end)
end)
for _, p in ipairs(Players:GetPlayers()) do
    if p ~= player then
        p.CharacterAdded:Connect(function()
            task.wait(0.5)
            if Config.ESP then AddESP(p) end
        end)
    end
end
Players.PlayerRemoving:Connect(function(p) RemoveESP(p) end)

-- ═════════════════════════════════════════════════════════════
--  AUTO RESPAWN ENGINE
--  Polls humanoid health; when dead, fires Respawn remote.
-- ═════════════════════════════════════════════════════════════
local lastRespawnTime = 0
task.spawn(function()
    while task.wait(0.5) do
        if not Config.AutoRespawn then continue end
        local ch = player.Character
        if not ch then continue end
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health <= 0 then
            local now = tick()
            if now - lastRespawnTime > 2 then
                lastRespawnTime = now
                if RespawnRemote then
                    pcall(function() RespawnRemote:FireServer() end)
                end
            end
        end
    end
end)

-- ═════════════════════════════════════════════════════════════
--  MAIN PANEL — Fluent UI  (Extracted from JOSEPEDOV V51)
-- ═════════════════════════════════════════════════════════════

local Theme = {
    Background = Color3.fromRGB(14, 16, 20),
    Sidebar    = Color3.fromRGB(10, 12, 16),
    Accent     = Color3.fromRGB(0, 200, 150),
    AccentDim  = Color3.fromRGB(0, 130, 95),
    Text       = Color3.fromRGB(240, 240, 240),
    SubText    = Color3.fromRGB(150, 150, 150),
    Button     = Color3.fromRGB(28, 32, 38),
    Stroke     = Color3.fromRGB(55, 60, 68),
    Red        = Color3.fromRGB(220, 60, 60),
    Orange     = Color3.fromRGB(255, 160, 0),
    Green      = Color3.fromRGB(0, 220, 110),
}

local ScreenGui = Instance.new("ScreenGui", guiTarget)
ScreenGui.Name           = "SS_Main"
ScreenGui.ResetOnSpawn   = false
ScreenGui.IgnoreGuiInset = true

-- Minimised icon
local ToggleIcon = Instance.new("TextButton", ScreenGui)
ToggleIcon.Size                 = UDim2.new(0, 45, 0, 45)
ToggleIcon.Position             = UDim2.new(0.5, -22, 0.05, 0)
ToggleIcon.BackgroundColor3     = Theme.Background
ToggleIcon.BackgroundTransparency = 0.1
ToggleIcon.Text                 = "🎯"
ToggleIcon.TextSize             = 22
ToggleIcon.Visible              = false
Instance.new("UICorner", ToggleIcon).CornerRadius = UDim.new(1, 0)
local IconStroke = Instance.new("UIStroke", ToggleIcon)
IconStroke.Color = Theme.Accent ; IconStroke.Thickness = 2

-- Main window
local MainFrame = Instance.new("Frame", ScreenGui)
MainFrame.Size                  = UDim2.new(0, 420, 0, 285)
MainFrame.Position              = UDim2.new(0.5, -210, 0.5, -142)
MainFrame.BackgroundColor3      = Theme.Background
MainFrame.BackgroundTransparency = 0.05
MainFrame.Active                = true
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 10)
local MainStroke = Instance.new("UIStroke", MainFrame)
MainStroke.Color = Theme.Stroke ; MainStroke.Transparency = 0.4

-- Top bar
local TopBar = Instance.new("Frame", MainFrame)
TopBar.Size                 = UDim2.new(1, 0, 0, 32)
TopBar.BackgroundTransparency = 1
local TitleLbl = Instance.new("TextLabel", TopBar)
TitleLbl.Size               = UDim2.new(0.65, 0, 1, 0)
TitleLbl.Position           = UDim2.new(0, 14, 0, 0)
TitleLbl.Text               = "🎯  SNIPER SCRIPT"
TitleLbl.Font               = Enum.Font.GothamBold
TitleLbl.TextColor3         = Theme.Accent
TitleLbl.TextSize           = 12
TitleLbl.TextXAlignment     = Enum.TextXAlignment.Left
TitleLbl.BackgroundTransparency = 1
local Sep = Instance.new("Frame", MainFrame)
Sep.Size             = UDim2.new(1, -20, 0, 1)
Sep.Position         = UDim2.new(0, 10, 0, 32)
Sep.BackgroundColor3 = Theme.Stroke
Sep.BorderSizePixel  = 0

local function AddCtrl(text, pos, color, cb)
    local b = Instance.new("TextButton", TopBar)
    b.Size               = UDim2.new(0, 28, 0, 22)
    b.Position           = pos
    b.BackgroundTransparency = 1
    b.Text               = text
    b.TextColor3         = color
    b.Font               = Enum.Font.GothamBold
    b.TextSize           = 12
    b.MouseButton1Click:Connect(cb)
    return b
end
AddCtrl("✕", UDim2.new(1, -32, 0.5, -11), Color3.fromRGB(255, 80, 80), function()
    RunService:UnbindFromRenderStep("SS_Gyro")
    ScreenGui:Destroy()
end)
AddCtrl("—", UDim2.new(1, -62, 0.5, -11), Theme.SubText, function()
    MainFrame.Visible = false ; ToggleIcon.Visible = true
end)
ToggleIcon.MouseButton1Click:Connect(function()
    MainFrame.Visible = true ; ToggleIcon.Visible = false
end)

-- Drag
local function EnableDrag(obj, handle)
    local drag, start, startPos
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            drag = true ; start = i.Position ; startPos = obj.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then drag = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if drag and (i.UserInputType == Enum.UserInputType.MouseMovement
                  or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - start
            obj.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                     startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end
EnableDrag(MainFrame, TopBar)
EnableDrag(ToggleIcon, ToggleIcon)

-- Sidebar
local Sidebar = Instance.new("Frame", MainFrame)
Sidebar.Size                  = UDim2.new(0, 110, 1, -33)
Sidebar.Position              = UDim2.new(0, 0, 0, 33)
Sidebar.BackgroundColor3      = Theme.Sidebar
Sidebar.BackgroundTransparency = 0.3
Sidebar.BorderSizePixel       = 0
Instance.new("UICorner", Sidebar).CornerRadius = UDim.new(0, 10)
local SidebarLayout = Instance.new("UIListLayout", Sidebar)
SidebarLayout.Padding             = UDim.new(0, 5)
SidebarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
local SidebarPadding = Instance.new("UIPadding", Sidebar)
SidebarPadding.PaddingTop = UDim.new(0, 10)

-- Content area
local ContentArea = Instance.new("Frame", MainFrame)
ContentArea.Size                  = UDim2.new(1, -120, 1, -38)
ContentArea.Position              = UDim2.new(0, 115, 0, 38)
ContentArea.BackgroundTransparency = 1

local AllTabs    = {}
local AllTabBtns = {}

local function CreateTab(name, icon)
    local tf = Instance.new("ScrollingFrame", ContentArea)
    tf.Size                  = UDim2.new(1, 0, 1, 0)
    tf.BackgroundTransparency = 1
    tf.ScrollBarThickness    = 2
    tf.ScrollBarImageColor3  = Theme.AccentDim
    tf.Visible               = false
    tf.AutomaticCanvasSize   = Enum.AutomaticSize.Y
    tf.CanvasSize            = UDim2.new(0, 0, 0, 0)
    tf.BorderSizePixel       = 0
    local lay = Instance.new("UIListLayout", tf) ; lay.Padding = UDim.new(0, 7)
    local pad = Instance.new("UIPadding", tf) ; pad.PaddingTop = UDim.new(0, 6)

    local tb = Instance.new("TextButton", Sidebar)
    tb.Size                  = UDim2.new(0.92, 0, 0, 30)
    tb.BackgroundColor3      = Theme.Accent
    tb.BackgroundTransparency = 1
    tb.Text                  = "  " .. icon .. " " .. name
    tb.TextColor3            = Theme.SubText
    tb.Font                  = Enum.Font.GothamMedium
    tb.TextSize              = 11
    tb.TextXAlignment        = Enum.TextXAlignment.Left
    Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 6)
    local ind = Instance.new("Frame", tb)
    ind.Size             = UDim2.new(0, 3, 0.6, 0)
    ind.Position         = UDim2.new(0, 2, 0.2, 0)
    ind.BackgroundColor3 = Theme.Accent
    ind.Visible          = false
    Instance.new("UICorner", ind).CornerRadius = UDim.new(1, 0)

    tb.MouseButton1Click:Connect(function()
        for _, t in pairs(AllTabs)    do t.Frame.Visible = false end
        for _, b in pairs(AllTabBtns) do
            b.Btn.BackgroundTransparency = 1
            b.Btn.TextColor3             = Theme.SubText
            b.Ind.Visible                = false
        end
        tf.Visible               = true
        tb.BackgroundTransparency = 0.80
        tb.TextColor3            = Theme.Text
        ind.Visible              = true
    end)
    table.insert(AllTabs,    { Frame = tf })
    table.insert(AllTabBtns, { Btn = tb, Ind = ind })
    return tf
end

local function Section(parent, text)
    local lbl = Instance.new("TextLabel", parent)
    lbl.Size                  = UDim2.new(0.98, 0, 0, 18)
    lbl.BackgroundTransparency = 1
    lbl.Text                  = text
    lbl.TextColor3            = Theme.AccentDim
    lbl.Font                  = Enum.Font.GothamBold
    lbl.TextSize              = 10
    lbl.TextXAlignment        = Enum.TextXAlignment.Left
end

local function AddButton(parent, text, cb)
    local btn = Instance.new("TextButton", parent)
    btn.Size             = UDim2.new(0.98, 0, 0, 35)
    btn.BackgroundColor3 = Theme.Button
    btn.Text             = text
    btn.Font             = Enum.Font.GothamBold
    btn.TextColor3       = Theme.Text
    btn.TextSize         = 12
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 7)
    Instance.new("UIStroke", btn).Color = Theme.Stroke
    btn.MouseButton1Click:Connect(cb)
    return btn
end

local function FluentToggle(parent, title, desc, callback)
    local state = false
    local btn = Instance.new("TextButton", parent)
    btn.Size             = UDim2.new(0.98, 0, 0, 48)
    btn.BackgroundColor3 = Theme.Button
    btn.Text             = "" ; btn.AutoButtonColor = false
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 7)
    local btnStroke = Instance.new("UIStroke", btn) ; btnStroke.Color = Theme.Stroke

    local tx = Instance.new("TextLabel", btn)
    tx.Size = UDim2.new(0.72, 0, 0.5, 0) ; tx.Position = UDim2.new(0, 10, 0, 5)
    tx.Text = title ; tx.Font = Enum.Font.GothamMedium ; tx.TextColor3 = Theme.Text
    tx.TextSize = 12 ; tx.TextXAlignment = Enum.TextXAlignment.Left ; tx.BackgroundTransparency = 1

    local sub = Instance.new("TextLabel", btn)
    sub.Size = UDim2.new(0.72, 0, 0.5, 0) ; sub.Position = UDim2.new(0, 10, 0.5, 0)
    sub.Text = desc ; sub.Font = Enum.Font.Gotham ; sub.TextColor3 = Theme.SubText
    sub.TextSize = 10 ; sub.TextXAlignment = Enum.TextXAlignment.Left ; sub.BackgroundTransparency = 1

    local pill = Instance.new("Frame", btn)
    pill.Size = UDim2.new(0, 42, 0, 22) ; pill.Position = UDim2.new(1, -52, 0.5, -11)
    pill.BackgroundColor3 = Theme.Button
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)
    local ps = Instance.new("UIStroke", pill) ; ps.Color = Theme.Stroke ; ps.Thickness = 1
    local pillTxt = Instance.new("TextLabel", pill)
    pillTxt.Size = UDim2.new(1, 0, 1, 0) ; pillTxt.Text = "OFF"
    pillTxt.Font = Enum.Font.GothamBold ; pillTxt.TextColor3 = Theme.SubText
    pillTxt.TextSize = 9 ; pillTxt.BackgroundTransparency = 1

    local function setV(on)
        state                 = on
        pill.BackgroundColor3 = on and Theme.Accent or Theme.Button
        ps.Color              = on and Theme.Accent or Theme.Stroke
        pillTxt.Text          = on and "ON"  or "OFF"
        pillTxt.TextColor3    = on and Color3.new(1, 1, 1) or Theme.SubText
        btn.BackgroundColor3  = on and Color3.fromRGB(20, 40, 32) or Theme.Button
        btnStroke.Color       = on and Theme.AccentDim or Theme.Stroke
    end
    setV(false)
    btn.MouseButton1Click:Connect(function()
        local res = callback(not state)
        setV(res ~= nil and res or not state)
    end)
    return setV
end

local function FluentSlider(parent, label, minV, maxV, defaultV, getV, setV)
    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(0.98, 0, 0, 62) ; row.BackgroundColor3 = Theme.Button
    row.BorderSizePixel = 0
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 7)
    local rowStroke = Instance.new("UIStroke", row) ; rowStroke.Color = Theme.Stroke

    local nameLbl = Instance.new("TextLabel", row)
    nameLbl.Size = UDim2.new(0.55, 0, 0, 20) ; nameLbl.Position = UDim2.new(0, 10, 0, 6)
    nameLbl.BackgroundTransparency = 1 ; nameLbl.Text = label
    nameLbl.TextColor3 = Theme.Text ; nameLbl.Font = Enum.Font.GothamMedium
    nameLbl.TextSize = 12 ; nameLbl.TextXAlignment = Enum.TextXAlignment.Left

    local valLbl = Instance.new("TextLabel", row)
    valLbl.Size = UDim2.new(0.40, 0, 0, 20) ; valLbl.Position = UDim2.new(0.58, 0, 0, 6)
    valLbl.BackgroundTransparency = 1 ; valLbl.Font = Enum.Font.GothamBold
    valLbl.TextSize = 12 ; valLbl.TextXAlignment = Enum.TextXAlignment.Right

    local track = Instance.new("Frame", row)
    track.Size = UDim2.new(1, -20, 0, 6) ; track.Position = UDim2.new(0, 10, 0, 36)
    track.BackgroundColor3 = Color3.fromRGB(14, 18, 28) ; track.BorderSizePixel = 0
    Instance.new("UICorner", track).CornerRadius = UDim.new(0, 3)
    local fill = Instance.new("Frame", track)
    fill.BorderSizePixel = 0 ; fill.Size = UDim2.new(0, 0, 1, 0)
    Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 3)
    local knob = Instance.new("Frame", track)
    knob.Size = UDim2.new(0, 14, 0, 14) ; knob.BackgroundColor3 = Color3.new(1, 1, 1)
    knob.BorderSizePixel = 0
    Instance.new("UICorner", knob).CornerRadius = UDim.new(0, 7)

    local minTxt = Instance.new("TextLabel", row)
    minTxt.Size = UDim2.new(0, 30, 0, 10) ; minTxt.Position = UDim2.new(0, 10, 0, 48)
    minTxt.BackgroundTransparency = 1 ; minTxt.Text = tostring(minV)
    minTxt.TextColor3 = Theme.SubText ; minTxt.Font = Enum.Font.Code
    minTxt.TextSize = 8 ; minTxt.TextXAlignment = Enum.TextXAlignment.Left
    local maxTxt = Instance.new("TextLabel", row)
    maxTxt.Size = UDim2.new(0, 40, 0, 10) ; maxTxt.Position = UDim2.new(1, -50, 0, 48)
    maxTxt.BackgroundTransparency = 1 ; maxTxt.Text = tostring(maxV) .. " MAX"
    maxTxt.TextColor3 = Theme.Red ; maxTxt.Font = Enum.Font.Code
    maxTxt.TextSize = 8 ; maxTxt.TextXAlignment = Enum.TextXAlignment.Right

    local function updateFromPct(pct)
        pct = math.clamp(pct, 0, 1)
        local range = maxV - minV
        local step  = range <= 20 and 1 or 10
        local raw   = minV + pct * range
        local val   = math.clamp(math.round(raw / step) * step, minV, maxV)
        setV(val)
        local rp = (val - minV) / range
        fill.Size         = UDim2.new(rp, 0, 1, 0)
        knob.Position     = UDim2.new(rp, -7, 0.5, -7)
        local col         = (val >= maxV) and Theme.Red or Theme.Accent
        valLbl.Text       = tostring(val)
        valLbl.TextColor3 = col
        fill.BackgroundColor3 = col
        knob.BackgroundColor3 = (val >= maxV) and Theme.Red or Color3.new(1, 1, 1)
    end
    updateFromPct((defaultV - minV) / (maxV - minV))

    local dragging = false
    local function applyInput(inp)
        updateFromPct((inp.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X)
    end
    knob.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then dragging = true end
    end)
    track.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then dragging = true ; applyInput(i) end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
                      or i.UserInputType == Enum.UserInputType.Touch) then applyInput(i) end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    return updateFromPct
end

-- ═════════════════════════════════════════════════════════════
--  TABS
-- ═════════════════════════════════════════════════════════════
local TabGyro  = CreateTab("Gyro",  "📱")
local TabAim   = CreateTab("Aim",   "🎯")
local TabESP   = CreateTab("ESP",   "👁️")
local TabMisc  = CreateTab("Misc",  "⚙️")
local TabInfo  = CreateTab("Info",  "ℹ️")

-- ─────────────────────────────────────────────────────────────
--  TAB 1: GYRO
-- ─────────────────────────────────────────────────────────────
Section(TabGyro, "  GYROSCOPE AIM")

local gyroSetV = FluentToggle(TabGyro,
    "📱 Gyro Aim",
    "Move your phone to aim — works after the game's camera update",
    function(v)
        Config.Gyro = v
        if not v then
            gyroAccumPitch = 0
            gyroAccumYaw   = 0
        end
        return v
    end)

Section(TabGyro, "  GYRO SENSITIVITY")

FluentSlider(TabGyro, "Horizontal Sens", 1, 10,
    math.round(Config.GyroSensH * 2),
    function() return math.round(Config.GyroSensH * 2) end,
    function(v)
        Config.GyroSensH = v / 2
    end)

FluentSlider(TabGyro, "Vertical Sens", 1, 10,
    math.round(Config.GyroSensV * 2),
    function() return math.round(Config.GyroSensV * 2) end,
    function(v)
        Config.GyroSensV = v / 2
    end)

-- Gyro status indicator row
local gyroStatusRow = Instance.new("Frame", TabGyro)
gyroStatusRow.Size             = UDim2.new(0.98, 0, 0, 32)
gyroStatusRow.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
gyroStatusRow.BorderSizePixel  = 0
Instance.new("UICorner", gyroStatusRow).CornerRadius = UDim.new(0, 6)
Instance.new("UIStroke", gyroStatusRow).Color = Theme.Stroke
local gyroStatusLbl = Instance.new("TextLabel", gyroStatusRow)
gyroStatusLbl.Size                  = UDim2.new(1, -10, 1, 0)
gyroStatusLbl.Position              = UDim2.new(0, 8, 0, 0)
gyroStatusLbl.BackgroundTransparency = 1
gyroStatusLbl.Font                  = Enum.Font.Code
gyroStatusLbl.TextSize              = 10
gyroStatusLbl.TextXAlignment        = Enum.TextXAlignment.Left
gyroStatusLbl.TextColor3            = Theme.SubText

-- Check if device supports gyro
local gyroSupported = pcall(function()
    return UserInputService.GyroscopeEnabled
end) and UserInputService.GyroscopeEnabled

if gyroSupported then
    gyroStatusLbl.Text       = "  ✅ Gyroscope detected on this device"
    gyroStatusLbl.TextColor3 = Theme.Green
else
    gyroStatusLbl.Text       = "  ⚠️  No gyroscope — desktop or unsupported device"
    gyroStatusLbl.TextColor3 = Theme.Orange
end

Section(TabGyro, "  TIPS")
local gyroTipRow = Instance.new("Frame", TabGyro)
gyroTipRow.Size             = UDim2.new(0.98, 0, 0, 52)
gyroTipRow.BackgroundColor3 = Color3.fromRGB(16, 20, 26)
gyroTipRow.BorderSizePixel  = 0
Instance.new("UICorner", gyroTipRow).CornerRadius = UDim.new(0, 6)
Instance.new("UIStroke", gyroTipRow).Color = Theme.Stroke
local gyroTipLbl = Instance.new("TextLabel", gyroTipRow)
gyroTipLbl.Size                  = UDim2.new(1, -14, 1, 0)
gyroTipLbl.Position              = UDim2.new(0, 7, 0, 0)
gyroTipLbl.BackgroundTransparency = 1
gyroTipLbl.Font                  = Enum.Font.Gotham
gyroTipLbl.TextSize              = 9
gyroTipLbl.TextWrapped           = true
gyroTipLbl.TextXAlignment        = Enum.TextXAlignment.Left
gyroTipLbl.TextColor3            = Theme.SubText
gyroTipLbl.Text = "Use gyro for micro-adjustments while aiming with the joystick for gross movement. Tilt phone forward = aim up. Rotate phone = pan left/right."

-- ─────────────────────────────────────────────────────────────
--  TAB 2: AIM  (toggles game's own AutoAim/AutoShoot settings)
-- ─────────────────────────────────────────────────────────────
Section(TabAim, "  AUTO AIM")

local aimSetV = FluentToggle(TabAim,
    "🎯 Auto Aim",
    "Snaps camera toward nearest visible enemy",
    function(v)
        Config.AutoAim = v
        SetSetting("AutoAim", v)
        return v
    end)
aimSetV(Config.AutoAim)

local shootSetV = FluentToggle(TabAim,
    "🔫 Auto Shoot",
    "Fires automatically when target in reticle",
    function(v)
        Config.AutoShoot = v
        SetSetting("AutoShoot", v)
        return v
    end)
shootSetV(Config.AutoShoot)

local hipfireSetV = FluentToggle(TabAim,
    "🏃 Hipfire Aim",
    "Apply auto-aim even when not ADS",
    function(v)
        Config.HipfireAim = v
        SetSetting("HipfireAim", v)
        return v
    end)
hipfireSetV(Config.HipfireAim)

Section(TabAim, "  STRENGTH")

FluentSlider(TabAim, "Aim Strength", 0, 10,
    Config.AimStrength,
    function() return Config.AimStrength end,
    function(v)
        Config.AimStrength = v
        SetSetting("AutoAimStrength", v)
        SetSetting("HipfireAimStrength", v)
    end)

Section(TabAim, "  ADVANCED")

local fastSetV = FluentToggle(TabAim,
    "⚡ Fast Shoot",
    "Reduces shoot animation delay (game setting)",
    function(v)
        Config.FastShoot = v
        SetSetting("FastShoot", v)
        return v
    end)
fastSetV(Config.FastShoot)

-- ─────────────────────────────────────────────────────────────
--  TAB 3: ESP
-- ─────────────────────────────────────────────────────────────
Section(TabESP, "  PLAYER ESP")

local espSetV = FluentToggle(TabESP,
    "👁️ Enemy Highlight ESP",
    "Red fill + gold outline on all enemies (through walls)",
    function(v)
        Config.ESP = v
        RefreshESP()
        return v
    end)

-- ESP color info row
local espInfoRow = Instance.new("Frame", TabESP)
espInfoRow.Size             = UDim2.new(0.98, 0, 0, 38)
espInfoRow.BackgroundColor3 = Color3.fromRGB(16, 20, 26)
espInfoRow.BorderSizePixel  = 0
Instance.new("UICorner", espInfoRow).CornerRadius = UDim.new(0, 6)
Instance.new("UIStroke", espInfoRow).Color = Theme.Stroke

-- Red fill swatch
local swatchR = Instance.new("Frame", espInfoRow)
swatchR.Size             = UDim2.new(0, 14, 0, 14)
swatchR.Position         = UDim2.new(0, 10, 0.5, -7)
swatchR.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
swatchR.BorderSizePixel  = 0
Instance.new("UICorner", swatchR).CornerRadius = UDim.new(0, 3)
-- Gold outline swatch
local swatchG = Instance.new("Frame", espInfoRow)
swatchG.Size             = UDim2.new(0, 14, 0, 14)
swatchG.Position         = UDim2.new(0, 28, 0.5, -7)
swatchG.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
swatchG.BorderSizePixel  = 0
Instance.new("UICorner", swatchG).CornerRadius = UDim.new(0, 3)

local espColorLbl = Instance.new("TextLabel", espInfoRow)
espColorLbl.Size                  = UDim2.new(1, -52, 1, 0)
espColorLbl.Position              = UDim2.new(0, 48, 0, 0)
espColorLbl.BackgroundTransparency = 1
espColorLbl.Font                  = Enum.Font.Gotham
espColorLbl.TextSize              = 9
espColorLbl.TextXAlignment        = Enum.TextXAlignment.Left
espColorLbl.TextColor3            = Theme.SubText
espColorLbl.Text                  = "Red fill  ·  Gold outline  ·  AlwaysOnTop depth"

AddButton(TabESP, "↺  Refresh ESP (re-scan players)", function()
    RefreshESP()
end)

-- ─────────────────────────────────────────────────────────────
--  TAB 4: MISC
-- ─────────────────────────────────────────────────────────────
Section(TabMisc, "  SURVIVAL")

local respawnSetV = FluentToggle(TabMisc,
    "💀 Auto Respawn",
    "Fires Respawn remote when your health hits 0",
    function(v)
        Config.AutoRespawn = v
        return v
    end)

local sprintSetV = FluentToggle(TabMisc,
    "🏃 Auto Sprint",
    "Always sprint — toggles game AutoSprint setting",
    function(v)
        Config.AutoSprint = v
        SetSetting("AutoSprint", v)
        return v
    end)
sprintSetV(Config.AutoSprint)

Section(TabMisc, "  CAMERA")

local fpSetV = FluentToggle(TabMisc,
    "👁️ First Person Mode",
    "Switch camera to first person (game CameraMode = 1)",
    function(v)
        SetSetting("CameraMode", v and 1 or 2)
        SetSetting("CameraMode_NonKeyboard", v and 1 or 2)
        return v
    end)

FluentSlider(TabMisc, "Field of View (FOV)", -20, 50,
    GetSetting("CameraFOV", 0),
    function() return GetSetting("CameraFOV", 0) end,
    function(v) SetSetting("CameraFOV", v) end)

Section(TabMisc, "  SENSITIVITY (game settings)")

FluentSlider(TabMisc, "Look Sensitivity", 1, 10,
    GetSetting("Sensitivity", 5),
    function() return GetSetting("Sensitivity", 5) end,
    function(v)
        SetSetting("Sensitivity", v)
        SetSetting("Sensitivity_H", v)
        SetSetting("Sensitivity_V", v)
    end)

FluentSlider(TabMisc, "ADS Sensitivity", 1, 10,
    GetSetting("Sensitivity_Aiming", 5),
    function() return GetSetting("Sensitivity_Aiming", 5) end,
    function(v) SetSetting("Sensitivity_Aiming", v) end)

-- ─────────────────────────────────────────────────────────────
--  TAB 5: INFO
-- ─────────────────────────────────────────────────────────────
Section(TabInfo, "  SCRIPT INFO")

local function InfoRow(parent, text, col)
    local r = Instance.new("Frame", parent)
    r.Size             = UDim2.new(0.98, 0, 0, 30)
    r.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
    r.BorderSizePixel  = 0
    Instance.new("UICorner", r).CornerRadius = UDim.new(0, 6)
    local l = Instance.new("TextLabel", r)
    l.Size                  = UDim2.new(1, -10, 1, 0)
    l.Position              = UDim2.new(0, 10, 0, 0)
    l.BackgroundTransparency = 1
    l.Text                  = text
    l.TextColor3            = col or Theme.SubText
    l.Font                  = Enum.Font.Gotham
    l.TextSize              = 11
    l.TextXAlignment        = Enum.TextXAlignment.Left
end

InfoRow(TabInfo, "🎯  SNIPER SCRIPT  —  Universal Mobile FPS", Theme.Accent)
InfoRow(TabInfo, "📱  Gyro: DeviceRotationChanged → Camera+1 priority")
InfoRow(TabInfo, "🎯  Aim: Toggles game-native AutoAim / AutoShoot")
InfoRow(TabInfo, "👁️  ESP: Highlight.DepthMode = AlwaysOnTop")
InfoRow(TabInfo, "💀  Respawn: RS.Remote.GameService.Respawn:FireServer()")
InfoRow(TabInfo, "⚠️  Gyro only works on real mobile devices")

local settingsStatus = Settings and "✅  Settings module loaded" or "❌  Settings module not found"
local settingsColor  = Settings and Theme.Green or Theme.Red
InfoRow(TabInfo, settingsStatus, settingsColor)

-- ─────────────────────────────────────────────────────────────
--  INIT: open first tab, sync toggle states
-- ─────────────────────────────────────────────────────────────
if AllTabs[1] and AllTabBtns[1] then
    AllTabs[1].Frame.Visible              = true
    AllTabBtns[1].Btn.BackgroundTransparency = 0.80
    AllTabBtns[1].Btn.TextColor3          = Theme.Text
    AllTabBtns[1].Ind.Visible             = true
end

-- Sync toggle visuals to current game state on load
aimSetV(Config.AutoAim)
shootSetV(Config.AutoShoot)
hipfireSetV(Config.HipfireAim)
fastSetV(Config.FastShoot)
sprintSetV(Config.AutoSprint)

print("[SniperScript] ✅ Loaded — Gyro / AutoAim / AutoShoot / ESP / Respawn")
print("[SniperScript] Settings module:", Settings and "FOUND" or "NOT FOUND")
print("[SniperScript] Gyro supported:", gyroSupported and "YES" or "NO (desktop / unsupported)")
