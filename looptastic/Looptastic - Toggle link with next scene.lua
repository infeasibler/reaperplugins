-- Looptastic: Toggle link with next scene
-- Links (or unlinks) the active scene with its immediate successor so the
-- engine loops them together as one unit. No-op if there's no next scene.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

local scenes = L.scan_scenes()
local scene = L.active_scene(scenes)
if not scene then
    reaper.MB("No active scene.", "Looptastic", 0)
    return
end
if not scenes[scene.num + 1] then
    reaper.MB("No next scene to link with.", "Looptastic", 0)
    return
end

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock2(0)
L.set_linked_to_next(scene, not scene.linked)
reaper.Undo_EndBlock2(0, "Looptastic: Toggle link with next scene", -1)
reaper.PreventUIRefresh(-1)
