-- ============================================================================
-- 双球碰撞游戏 - Main Entry
-- Supports: Standalone / Client / Server modes
-- ============================================================================

local Module = nil

function Start()
    if IsServerMode() then
        print("[Main] Starting in SERVER mode")
        Module = require("network.Server")
    elseif IsNetworkMode() then
        print("[Main] Starting in CLIENT mode")
        Module = require("network.Client")
    else
        print("[Main] Starting in STANDALONE mode")
        Module = require("network.Standalone")
    end
    Module.Start()
end

function Stop()
    if Module and Module.Stop then
        Module.Stop()
    end
end
