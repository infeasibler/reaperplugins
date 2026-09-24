-- @noindex
-- Scenery: Toggle record lead-in
-- Preserves pre-phrase material in auto-looped recordings.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local cfg = L.get_config()
L.set_config("record_lead_in", cfg.record_lead_in and "0" or "1")