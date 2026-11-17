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
local idle_snapshot = nil
local idle_project = nil
local idle_revision = nil
local recording_snapshot = nil
local recording_project = nil
local recording_scene = nil
local recording_destination = nil
local recording_loop = nil
local recording_midi_events = {}
local last_midi_sequence = L.latest_midi_input_sequence()
local last_play_pos = nil
local next_poll = 0

local function refresh_idle_snapshot(force)
    local project = reaper.EnumProjects(-1, "")
    local revision = reaper.GetProjectStateChangeCount(project)
    if force or not idle_snapshot or project ~= idle_project or revision ~= idle_revision then
        idle_snapshot = L.snapshot_item_guids()
        idle_project = project
        idle_revision = revision
    end
end

local function report_unprocessed_recording(snapshot, loop_scene, destination, scenes)
    local snapshot_count = 0
    for _ in pairs(snapshot) do snapshot_count = snapshot_count + 1 end
    local lines = {
        "Scenery: Recording auto-loop processed 0 items.",
        string.format("Snapshot: %d items; loop: %.12f-%.12f; destination: %s",
            snapshot_count, loop_scene.pos, loop_scene.rgnend,
            destination and string.format("%.12f-%.12f", destination.pos, destination.rgnend) or "none"),
    }
    local new_count, shown = 0, 0
    for t = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, t)
        local armed = reaper.GetMediaTrackInfo_Value(track, "I_RECARM") > 0
        for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            local ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
            local known = ok and guid ~= "" and not not snapshot[guid]
            if ok and guid ~= "" and not snapshot[guid] then new_count = new_count + 1 end
            if shown < 20 and (armed or not known) then
                local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                local item_scene = L.scene_at(pos, scenes)
                lines[#lines + 1] = string.format(
                    "Track %d%s: position %.12f, length %.12f, GUID %s, takes %d, scene %s",
                    t + 1, armed and " (armed)" or "", pos, length,
                    (not ok or guid == "") and "unavailable" or (known and "existing" or "new"),
                    reaper.CountTakes(item),
                    item_scene and string.format("%.12f-%.12f", item_scene.pos, item_scene.rgnend) or "none")
                shown = shown + 1
            end
        end
    end
    lines[#lines + 1] = string.format("New item GUIDs: %d (showing at most 20 items).", new_count)
    reaper.ShowConsoleMsg(table.concat(lines, "\n") .. "\n")
end

-- Recording starts immediately; requested stops are deferred to the configured
-- phrase boundary by follow(). Auto-loop alignment is applied in post-processing.
local function service_recording()
    local recording = L.is_recording()
    local cfg = L.get_config()
    local new_events
    new_events, last_midi_sequence = L.recent_midi_input_events_after(last_midi_sequence)

    if recording and not was_recording then
        recording_project = reaper.EnumProjects(-1, "")
        recording_snapshot = recording_project == idle_project and idle_snapshot or nil
        if not recording_snapshot then
            reaper.ShowConsoleMsg("Scenery: Cannot process this recording without a pre-recording item snapshot.\n")
        end
        recording_scene = L.active_scene()
        recording_destination = recording_scene
        recording_midi_events = new_events
        if recording_scene then
            local start, stop = L.chain_bounds(recording_scene)
            recording_loop = { pos = start, rgnend = stop }
        end
    elseif recording then
        recording_destination = L.active_scene() or recording_destination
        for _, event in ipairs(new_events) do
            recording_midi_events[#recording_midi_events + 1] = event
        end
    elseif not recording and was_recording then
        local target_scene = L.active_scene() or recording_scene
        local wrap_scene = recording_loop or recording_scene or target_scene
        for _, event in ipairs(new_events) do
            recording_midi_events[#recording_midi_events + 1] = event
        end
        local wrapped_notes = L.wrapped_midi_input_notes(recording_midi_events, wrap_scene)
        if recording_project and recording_project ~= reaper.EnumProjects(-1, "") then
            reaper.ShowConsoleMsg("Scenery: Recording post-processing skipped because the active project changed.\n")
        elseif recording_snapshot and target_scene
            and (cfg.record_auto_loop or #wrapped_notes > 0) then
            reaper.PreventUIRefresh(1)
            reaper.Undo_BeginBlock2(0)
            local ok, repaired, processed = xpcall(function()
                local repaired = L.apply_wrapped_midi_notes_to_new_items(
                    recording_snapshot, wrap_scene, wrapped_notes)
                local processed = 0
                if cfg.record_auto_loop then
                    local scenes = L.scan_scenes()
                    processed = L.apply_loop_source_to_new_items(
                        recording_snapshot, wrap_scene, scenes,
                        recording_destination or target_scene)
                    if processed == 0 then
                        report_unprocessed_recording(recording_snapshot, wrap_scene,
                            recording_destination or target_scene, scenes)
                    end
                end
                return repaired, processed
            end, debug.traceback)
            local undo_label
            if not ok then
                undo_label = "Scenery: Recording post-processing failed"
            elseif repaired > 0 then
                undo_label = "Scenery: Repair wrapped MIDI (" .. repaired .. " notes)"
                if processed > 0 then
                    undo_label = undo_label .. "; record auto-loop (" .. processed .. " items)"
                end
            else
                undo_label = "Scenery: Record auto-loop (" .. processed .. " items)"
            end
            reaper.Undo_EndBlock2(0, undo_label, -1)
            reaper.PreventUIRefresh(-1)
            if not ok then
                reaper.ShowConsoleMsg("Scenery engine error: " .. tostring(repaired) .. "\n")
            end
            if not ok or processed > 0 or repaired > 0 then reaper.UpdateArrange() end
        end
        recording_snapshot = nil
        recording_project = nil
        recording_scene = nil
        recording_destination = nil
        recording_loop = nil
        recording_midi_events = {}
        refresh_idle_snapshot(true)
    elseif not recording then
        refresh_idle_snapshot(false)
    end
    was_recording = recording
end

local function follow()
    local cfg = L.get_config()

    -- Honour a quantized-stop request before checking for a stopped recording,
    -- so nothing recorded through the end of the phrase is lost.
    local play_pos = L.is_playing() and reaper.GetPlayPosition() or nil
    if play_pos and L.due_record_stop(play_pos, last_play_pos) then
        reaper.Main_OnCommand(1013, 0)
    end

    local waiting = L.get_waiting_scene()
    if waiting and play_pos then
        if play_pos >= waiting.arm_at then
            L.clear_waiting_scene()
            L.set_loop_to({ pos = waiting.start, rgnend = waiting.rgnend })
            reaper.SetEditCurPos(waiting.pos, false, true)
            L.set_active_scene({ id = waiting.id })
            last_play_pos = play_pos
            return
        end
    elseif not play_pos then
        L.clear_waiting_scene()
        L.clear_next_scene()
    end

    last_play_pos = play_pos

    service_recording()

    local next_scene_id = L.get_next_scene_id()
    if next_scene_id and play_pos then
        local active_scene = L.active_scene()
        if active_scene and active_scene.id == next_scene_id then
            L.clear_next_scene()
        end
    end

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
            L.clear_next_scene()
            L.set_active_range(pending.pos, pending.rgnend)
            local entered_scene = L.active_scene(scenes)
            last_scene_id = entered_scene and entered_scene.id or nil
            return
        elseif cursor_moved then
            L.clear_pending()
            L.clear_next_scene()
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
    L.clear_waiting_scene()
    L.clear_next_scene()
    L.clear_record_stop_pending()
    was_recording = false
    idle_snapshot = nil
    recording_snapshot = nil
    recording_project = nil
    recording_scene = nil
    recording_destination = nil
    recording_loop = nil
    recording_midi_events = {}
    reaper.SetToggleCommandState(section_id, cmd_id, 0)
    reaper.RefreshToolbar2(section_id, cmd_id)
end)

loop()
