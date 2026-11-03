-- @description Scenery - Settings
-- @version 0.1.0
-- @author infeasibler
-- @about
--   Opens the Scenery Settings UI.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
dofile(script_dir .. "Scenery - Settings UI.lua")
