-- Looptastic: Duplicate current scene
-- Appends a scene of the same bar length, copies the current scene's items into it, and loops it.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

local source = L.active_scene()
if not source then
    reaper.MB("No scene found at the cursor. Create a scene first.", "Looptastic", 0)
    return
end

local source_bars = L.bars_between(source.pos, source.rgnend)
if source_bars < 1 then source_bars = L.get_config().default_bars end
local bars = math.max(source_bars, L.get_config().default_bars)

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock2(0)

L.renumber_scenes()
local scene = L.create_scene(bars)
-- tile the source content to fill the (possibly longer) new scene
local unit = source.rgnend - source.pos
local dest = scene.pos
while dest < scene.rgnend - 1e-9 do
    L.copy_items(source.pos, source.rgnend, dest, scene.rgnend)
    dest = dest + unit
end
L.set_loop_to(scene)

reaper.Undo_EndBlock2(0, "Looptastic: Duplicate scene", -1)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
