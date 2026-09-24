-- @noindex
-- Scenery: Toggle record lead-out
-- Preserves post-phrase material in auto-looped recordings.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local cfg = L.get_config()
L.set_config("record_lead_out", cfg.record_lead_out and "0" or "1")