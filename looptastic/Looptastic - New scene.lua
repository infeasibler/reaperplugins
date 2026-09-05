-- Looptastic: New scene (default length)
-- Appends a new scene region after the last one and loops it. Play cursor is not moved.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

local bars = L.get_config().default_bars

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock2(0)

local scene = L.create_scene(bars)
L.set_loop_to(scene)

reaper.Undo_EndBlock2(0, "Looptastic: New scene (" .. bars .. " bars)", -1)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
