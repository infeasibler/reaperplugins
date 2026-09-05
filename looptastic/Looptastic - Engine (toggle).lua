-- Looptastic: Engine (toggle)
-- Background service that keeps the loop points on the scene under the cursor.
-- Run once to start, run again to stop. All other Looptastic actions work without it.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

local _, _, section_id, cmd_id = reaper.get_action_context()

-- A second run of this script flips the flag; the running instance sees it and exits.
if reaper.GetExtState(L.EXT_SECTION, "engine_running") == "1" then
    reaper.SetExtState(L.EXT_SECTION, "engine_running", "0", false)
    return
end
reaper.SetExtState(L.EXT_SECTION, "engine_running", "1", false)
reaper.SetToggleCommandState(section_id, cmd_id, 1)
reaper.RefreshToolbar2(section_id, cmd_id)

local last_scene_pos = (function()
    local s = L.active_scene()
    return s and s.pos or nil
end)()

local was_recording = L.is_recording()
local recording_snapshot = nil
local recording_scene = nil
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
            reaper.Undo_EndBlock2(0, "Looptastic: Record auto-loop (" .. processed .. " items)", -1)
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
            last_scene_pos = pending.pos
            return
        elseif cursor_moved then
            L.clear_pending()
        else
            return
        end
    end

    local scene = L.active_scene(scenes)
    if scene and (last_scene_pos == nil or math.abs(scene.pos - last_scene_pos) > 1e-9) then
        L.set_loop_to(scene, false)
        last_scene_pos = scene.pos
    end
end

local function loop()
    if reaper.GetExtState(L.EXT_SECTION, "engine_running") ~= "1" then return end

    local now = reaper.time_precise()
    if now >= next_poll then
        next_poll = now + (L.get_config().poll_interval)
        follow()
    end
    reaper.defer(loop)
end

reaper.atexit(function()
    reaper.SetExtState(L.EXT_SECTION, "engine_running", "0", false)
    L.clear_pending()
    was_recording = false
    recording_snapshot = nil
    recording_scene = nil
    reaper.SetToggleCommandState(section_id, cmd_id, 0)
    reaper.RefreshToolbar2(section_id, cmd_id)
end)

loop()
