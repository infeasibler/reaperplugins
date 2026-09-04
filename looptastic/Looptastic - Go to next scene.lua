-- Looptastic: Go to next scene
-- Loops the next scene. Moves the edit cursor only when the transport is stopped.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

local scenes = L.scan_scenes()
local current = L.active_scene(scenes)
if not current then return end

local target = scenes[current.num + 1]
if not target then return end

if L.is_playing() then
    L.set_loop_to(target)
else
    reaper.SetEditCurPos(target.pos, true, false)
    L.set_loop_to(target, false)
end
