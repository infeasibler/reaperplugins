-- @noindex
-- Scenery: Toggle auto repeat
-- Toggles whether starting/switching to a scene turns transport repeat on.
-- When off, set_loop_to still sets the loop range but leaves repeat as-is.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local cfg = L.get_config()
L.set_config("auto_repeat", cfg.auto_repeat and "0" or "1")
