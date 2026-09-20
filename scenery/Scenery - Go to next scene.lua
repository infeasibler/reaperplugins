-- @noindex
-- Scenery: Go to next scene
-- Queues the next scene exactly like clicking it in the Launcher.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local scenes = L.scan_scenes()
local current = L.active_scene(scenes)
if not current then return end

local target = scenes[current.num + 1]
if not target then return end

L.switch_scene(target, script_dir, scenes)
