-- @noindex
-- Scenery: Copy current scene
-- Appends a scene with item copies that share the source items' pooled IGUIDs.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local source = L.active_scene()
if not source then
    reaper.MB("No scene found at the cursor. Create a scene first.", "Scenery", 0)
    return
end

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock2(0)

local scene = L.duplicate_scene(source, L.copy_items_linked)
L.set_loop_to(scene)

reaper.Undo_EndBlock2(0, "Scenery: Copy scene", -1)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()