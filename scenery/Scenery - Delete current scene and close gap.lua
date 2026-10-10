-- @noindex
-- Scenery: Delete current scene and close gap
-- Deletes the scene under the edit cursor and shifts later items and markers left.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local scene = L.active_scene()
if not scene then
    reaper.MB("No scene found at the edit cursor.", "Scenery", 0)
    return
end

if L.get_config().confirm_destructive then
    local answer = reaper.MB("Delete " .. scene.name .. " and its items, then shift later items and markers " ..
        "left to close the gap?", "Scenery", 4)
    if answer ~= 6 then return end
end

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock2(0)
local succeeded, error_message = L.delete_scene_and_shift(scene)
reaper.Undo_EndBlock2(0, "Scenery: Delete scene and close gap", -1)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
if not succeeded then
    reaper.MB((error_message or "An overlapping item could not be split.") ..
        " The scene was not deleted; check the Undo history for any partial item splits.", "Scenery", 0)
end
