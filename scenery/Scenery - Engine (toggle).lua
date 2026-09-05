-- @noindex
-- Scenery: Engine (toggle)
-- Background service that keeps the loop points on the scene under the cursor.
-- Run once to start, run again to stop. All other Scenery actions work without it.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local _, _, section_id, cmd_id = reaper.get_action_context()

-- A second run of this script flips the flag; the running instance sees it and exits.
if reaper.GetExtState(L.EXT_SECTION, "engine_running") == "1" then
    reaper.SetExtState(L.EXT_SECTION, "engine_running", "0", false)
    return
end
reaper.SetExtState(L.EXT_SECTION, "engine_running", "1", false)
reaper.SetToggleCommandState(section_id, cmd_id, 1)
reaper.RefreshToolbar2(section_id, cmd_id)

local last_scene_id = (function()
    local s = L.active_scene()
    return s and s.id or nil
end)()

local was_recording = L.is_recording()
local recording_snapshot = nil
local recording_scene = nil
local last_play_pos = nil
local next_poll = 0

-- Recording starts and stops immediately (native Record button, launcher Rec
-- button, and the standalone action all behave the same); bar-alignment is
-- applied purely in post-processing by apply_loop_source_to_new_items.
local function service_recording()
    local recording = L.is_recording()
    local cfg = L.get_config()
    if not cfg.record_auto_loop then
        recording_snapshot = nil
        recording_scene = nil
        was_recording = recording
        return
    end

    if recording and not was_recording then
        recording_snapshot = L.snapshot_item_guids()
        recording_scene = L.active_scene()
    elseif not recording and was_recording then
        if recording_snapshot and recording_scene then
            reaper.PreventUIRefresh(1)
            reaper.Undo_BeginBlock2(0)
            local processed = L.apply_loop_source_to_new_items(recording_snapshot, recording_scene)
            reaper.Undo_EndBlock2(0, "Scenery: Record auto-loop (" .. processed .. " items)", -1)
            reaper.PreventUIRefresh(-1)
            if processed > 0 then reaper.UpdateArrange() end
        end
        recording_snapshot = nil
        recording_scene = nil
    end
    was_recording = recording
end

local function follow()
    local cfg = L.get_config()

    -- honour a quantized-stop request before checking for a stopped recording,
    -- so nothing recorded through the end of the bar is lost
    local play_pos = L.is_playing() and reaper.GetPlayPosition() or nil
    if play_pos and L.due_record_stop(play_pos, last_play_pos) then
        reaper.Main_OnCommand(1013, 0)
    end
    last_play_pos = play_pos

    service_recording()

    if not cfg.follow_enabled then return end

    local scenes = L.scan_scenes()
    if #scenes == 0 then return end

    local pending = L.get_pending()
    if pending then
        local playing = L.is_playing()
        local play_pos = playing and reaper.GetPlayPosition() or nil
        local entered = playing and play_pos >= pending.pos and play_pos < pending.rgnend
        local cursor_moved = (not playing) and math.abs(reaper.GetCursorPosition() - pending.cursor) > 1e-6
        if entered then
            L.clear_pending()
            L.set_active_range(pending.pos, pending.rgnend)
            local entered_scene = L.active_scene(scenes)
            last_scene_id = entered_scene and entered_scene.id or nil
            return
        elseif cursor_moved then
            L.clear_pending()
        else
            return
        end
    end

    local scene = L.active_scene(scenes)
    if scene and (last_scene_id == nil or scene.id ~= last_scene_id) then
        -- linked scenes loop as one unit spanning the whole chain, re-scoped
        -- to just the current scene once it's no longer linked to anything
        local start, stop = L.chain_bounds(scene, scenes)
        L.set_loop_to({ pos = start, rgnend = stop }, false)
        L.set_active_scene(scene)
        last_scene_id = scene.id
    end
end

local function loop()
    if reaper.GetExtState(L.EXT_SECTION, "engine_running") ~= "1" then return end

    local now = reaper.time_precise()
    if now >= next_poll then
        next_poll = now + (L.get_config().poll_interval)
        -- an uncaught error here would otherwise kill the whole defer chain silently
        local ok, err = pcall(follow)
        if not ok then reaper.ShowConsoleMsg("Scenery engine error: " .. tostring(err) .. "\n") end
    end
    reaper.defer(loop)
end

reaper.atexit(function()
    reaper.SetExtState(L.EXT_SECTION, "engine_running", "0", false)
    L.clear_pending()
    L.clear_record_stop_pending()
    was_recording = false
    recording_snapshot = nil
    recording_scene = nil
    reaper.SetToggleCommandState(section_id, cmd_id, 0)
    reaper.RefreshToolbar2(section_id, cmd_id)
end)

loop()
