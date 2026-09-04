-- Looptastic: Duplicate current scene
-- Appends a scene of the same bar length, copies the current scene's items into it, and loops it.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

local source = L.active_scene()
if not source then
    reaper.MB("No scene found at the cursor. Create a scene first.", "Looptastic", 0)
    return
end

local bars = L.bars_between(source.pos, source.rgnend)
if bars < 1 then bars = L.get_config().default_bars end

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock2(0)

L.renumber_scenes()
local scene = L.create_scene(bars)
L.copy_items(source.pos, source.rgnend, scene.pos, scene.rgnend)
L.set_loop_to(scene)

reaper.Undo_EndBlock2(0, "Looptastic: Duplicate scene", -1)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
