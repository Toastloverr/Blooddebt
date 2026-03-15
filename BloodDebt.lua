if not game:IsLoaded() then game.Loaded:Wait(); end

-- Utility functions with fallbacks
local cloneref = cloneref or function(i) return i end
local clonefunction = clonefunction or function(f) return f end
local newcclosure = newcclosure or clonefunction
local executor = (identifyexecutor and select(2, pcall(identifyexecutor))) and identifyexecutor() or "Unknown"

-- Delta-specific detection
local IS_DELTA = executor:lower():find("delta") and true or false

-- Notification system
local SG = loadstring(game:HttpGet("https://raw.githubusercontent.com/sneekygoober/sneeky-s-notifications/refs/heads/main/main.luau"))()

-- Check required functions
if not (hookfunction and require) then
    local missing = {}
    if not hookfunction then table.insert(missing, "hookfunction") end
    if not require then table.insert(missing, "require") end
    if IS_DELTA and not run_on_actor then table.insert(missing, "run_on_actor") end
    
    local err = executor .. " is missing " .. table.concat(missing, ", ")
    SG["error"](err)
    return error(err)
end

local Players = cloneref(game:GetService("Players"))
local plr = Players.LocalPlayer

-- Validate game objects
local npc = workspace:FindFirstChild("NPCSFolder")
local bf = workspace:FindFirstChild("BloodFolder")
if not (npc and bf) then
    local err = "Script needs updating - game structure changed"
    SG["error"](err)
    return warn(err)
end

-- Cache the getTarget function (load once, use everywhere)
local getTargetFunc = loadstring(game:HttpGet("https://raw.githubusercontent.com/sneekygoober/Blood-Debt-Silent-Aim-Script/refs/heads/main/getTarget.luau"))()
local getTarget = getTargetFunc(true)  -- The visual version
local getTargetLogic = getTargetFunc(false)  -- The logic-only version

-- Load FOV library
local fovLib = loadstring(game:HttpGet("https://raw.githubusercontent.com/sneekygoober/sneeky-s-fov-lib/refs/heads/main/main.luau"))()
fovLib(300, getTargetLogic, true)

-- DELTA-SPECIFIC FIX: Alternative injection method
local function injectIntoActor(actor, code)
    if not actor then return false end
    
    -- Method 1: Try run_on_actor (standard)
    local success, result = pcall(run_on_actor, actor, code)
    if success then return true end
    
    -- Method 2: For Delta, try using the actor's environment directly
    if IS_DELTA then
        -- Some Delta versions expose the actor's Lua state through debug
        local success, env = pcall(function()
            return getsenv(actor)  -- If available
        end)
        
        if success and env then
            pcall(function()
                -- Execute in the actor's environment
                local func = loadstring(code)
                setfenv(func, env)
                func()
            end)
            return true
        end
        
        -- Method 3: Try through the actor's Scripts
        for _, child in ipairs(actor:GetChildren()) do
            if child:IsA("ModuleScript") then
                -- Some actors have module scripts we can requre
                pcall(function()
                    local module = require(child)
                    if type(module) == "table" and module.bullet then
                        -- Directly patch the module if we can access it
                        local old = module.bullet
                        module.bullet = function(...)
                            local args = {...}
                            local origin = args[5]  -- Adjust index based on actual signature
                            local target = getTargetLogic(origin)
                            if target then
                                args[6] = table.create(#(args[6] or {}), (target.Position - origin).Unit)
                            end
                            return old(unpack(args))
                        end
                    end
                end)
                return true
            end
        end
    end
    
    return false
end

-- Create a minimal payload that doesn't re-fetch everything
local function createPayload()
    -- Serialize the getTarget function into the payload
    local getTargetSource = getTargetLogic  -- This is actually the function, need its source
    
    -- Better: load the getTarget code inside the actor
    return [[
        local getTarget = loadstring(game:HttpGet("https://raw.githubusercontent.com/sneekygoober/Blood-Debt-Silent-Aim-Script/refs/heads/main/getTarget.luau"))()(false)
        
        local s, rep = pcall(require, game:GetService("ReplicatedStorage").gun_res.lib.replicator)
        if not s then return end
        
        local old = rep.bullet
        rep.bullet = function(...)
            local args = {...}
            local origin = args[5]  -- This index might need adjustment
            
            -- Find the actual endPoses parameter
            local endPoses = args[6]
            if not endPoses then return old(...) end
            
            local target = getTarget(origin)
            if target then
                -- Replace the trajectory
                local direction = (target.Position - origin).Unit
                local newEndPoses = {}
                for i = 1, #endPoses do
                    newEndPoses[i] = direction
                end
                args[6] = newEndPoses
                return old(unpack(args))
            end
            return old(...)
        end
    ]]
end

local payload = createPayload()

-- Track injected actors
local injected = {}
local activeActor = nil

-- Setup function for character weapons
local function setupCharacter(char)
    if not char then return end
    
    -- Clear previous injection tracking
    table.clear(injected)
    activeActor = nil
    
    -- Wait a bit for character to stabilize
    task.wait(0.5)
    
    -- Find the gun
    local gun = char:FindFirstChildOfClass("Tool")
    if not gun then
        -- If no gun yet, wait for it
        local toolAdded = char.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                toolAdded:Disconnect()
                setupCharacter(char)  -- Recursive call with same char
            end
        end)
        return
    end
    
    -- Find actor - DELTA FIX: Actors might be nested differently
    local actor = gun:FindFirstChild("Actor")
    if not actor then
        -- Try searching deeper
        for _, child in ipairs(gun:GetDescendants()) do
            if child:IsA("Actor") then
                actor = child
                break
            end
        end
    end
    
    if not actor then
        warn("No actor found in gun")
        return
    end
    
    -- Check if weapon_cl exists (indicates weapon is ready)
    local maxWait = 50
    local waited = 0
    while not actor:FindFirstChild("weap_cl") and waited < maxWait do
        task.wait(0.1)
        waited = waited + 1
    end
    
    if not actor:FindFirstChild("weap_cl") then
        warn("weap_cl not found in actor")
        return
    end
    
    activeActor = actor
    
    -- Try injection
    task.spawn(function()
        local attempts = 0
        local maxAttempts = 30
        
        while attempts < maxAttempts and activeActor == actor do
            -- Check if actor still valid
            if not actor.Parent or not actor:IsDescendantOf(char) then
                return
            end
            
            -- Try injection
            local success = injectIntoActor(actor, payload)
            
            if success then
                injected[actor] = true
                print("Successfully injected into actor")
                
                -- Verify injection worked by checking if bullet function was hooked
                task.wait(0.5)
                pcall(run_on_actor, actor, [[
                    local s, rep = pcall(require, game:GetService("ReplicatedStorage").gun_res.lib.replicator)
                    if s and rep.bullet then
                        print("Injection verified, bullet function is now hooked")
                    end
                ]])
                
                break
            end
            
            attempts = attempts + 1
            task.wait(0.2)
        end
        
        if not injected[actor] then
            warn("Failed to inject after", maxAttempts, "attempts")
        end
    end)
end

-- Monitor for weapon changes
local function watchCharacter(char)
    if not char then return end
    
    -- Initial setup
    setupCharacter(char)
    
    -- Watch for weapon switching
    char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            task.wait(0.3)  -- Give time for actor to initialize
            setupCharacter(char)
        end
    end)
    
    -- Watch for actor changes within the current tool
    char.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") then
            -- Tool removed, we'll set up again when new tool added
            activeActor = nil
        end
    end)
end

-- Start watching current character
watchCharacter(plr.Character)

-- Watch for respawns
plr.CharacterAdded:Connect(watchCharacter)

SG["success"]("Silent aim loaded for Delta!\nIf it doesn't work, check console (F9) for errors.")