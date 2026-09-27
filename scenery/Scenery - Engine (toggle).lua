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
local recording_loop = nil
local recording_midi_events = {}
local last_midi_sequence = L.latest_midi_input_sequence()
local last_play_pos = nil
local next_poll = 0

-- Recording starts immediately; requested stops are deferred to the configured
-- phrase boundary by follow(). Auto-loop alignment is applied in post-processing.
local function service_recording()
    local recording = L.is_recording()
    local cfg = L.get_config()
    local new_events
    new_events, last_midi_sequence = L.recent_midi_input_events_after(last_midi_sequence)

    if recording and not was_recording then
        recording_snapshot = L.snapshot_item_guids()
        recording_scene = L.active_scene()
        recording_midi_events = new_events
        if recording_scene then
            local start, stop = L.chain_bounds(recording_scene)
            recording_loop = { pos = start, rgnend = stop }
        end
    elseif recording then
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
        if recording_snapshot and target_scene
            and (cfg.record_auto_loop or #wrapped_notes > 0) then
            reaper.PreventUIRefresh(1)
            reaper.Undo_BeginBlock2(0)
            local repaired = L.apply_wrapped_midi_notes_to_new_items(
                recording_snapshot, wrap_scene, wrapped_notes)
            local processed = 0
            if cfg.record_auto_loop then
                processed = L.apply_loop_source_to_new_items(recording_snapshot, target_scene)
            end
            local undo_label
            if repaired > 0 then
                undo_label = "Scenery: Repair wrapped MIDI (" .. repaired .. " notes)"
                if processed > 0 then
                    undo_label = undo_label .. "; record auto-loop (" .. processed .. " items)"
                end
            else
                undo_label = "Scenery: Record auto-loop (" .. processed .. " items)"
            end
            reaper.Undo_EndBlock2(0, undo_label, -1)
            reaper.PreventUIRefresh(-1)
            if processed > 0 or repaired > 0 then reaper.UpdateArrange() end
        end
        recording_snapshot = nil
        recording_scene = nil
        recording_loop = nil
        recording_midi_events = {}
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
    recording_snapshot = nil
    recording_scene = nil
    recording_loop = nil
    recording_midi_events = {}
    reaper.SetToggleCommandState(section_id, cmd_id, 0)
    reaper.RefreshToolbar2(section_id, cmd_id)
end)

loop()
