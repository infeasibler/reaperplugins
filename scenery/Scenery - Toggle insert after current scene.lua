-- @noindex
-- Scenery: Toggle insert after current scene
-- Toggles whether Clone and Copy insert immediately after the source scene.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local cfg = L.get_config()
L.set_config("insert_after_current", cfg.insert_after_current and "0" or "1")