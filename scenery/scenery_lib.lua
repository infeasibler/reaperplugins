-- @noindex
-- Scenery - shared library
-- Loaded by the Scenery action scripts via dofile(). Not an action itself.

local M = {}

M.EXT_SECTION = "Scenery"
M.SCENE_PREFIX = "Scene"
M.DEFAULT_BARS = 8
M.DEFAULT_COLOR_RGB = { 0x30, 0x80, 0xC0 }

-- ---------------------------------------------------------------- config

local function ext_get(key, fallback)
    local v = reaper.GetExtState(M.EXT_SECTION, key)
    if v == nil or v == "" then return fallback end
    return v
end

function M.get_config()
    local rgb = ext_get("region_color", table.concat(M.DEFAULT_COLOR_RGB, ","))
    local r, g, b = rgb:match("^(%d+),(%d+),(%d+)$")
    if not r then r, g, b = M.DEFAULT_COLOR_RGB[1], M.DEFAULT_COLOR_RGB[2], M.DEFAULT_COLOR_RGB[3] end
    return {
        default_bars        = math.max(1, math.floor(tonumber(ext_get("default_bars", M.DEFAULT_BARS)) or M.DEFAULT_BARS)),
        color_r             = tonumber(r), color_g = tonumber(g), color_b = tonumber(b),
        follow_enabled      = ext_get("follow_enabled", "1") == "1",
        record_auto_loop    = ext_get("record_auto_loop", "1") == "1",
        record_end_of_bar   = ext_get("record_end_of_bar", "1") == "1",
        confirm_destructive = ext_get("confirm_destructive", "1") == "1",
        poll_interval       = tonumber(ext_get("poll_interval", "0.008")) or 0.008,
    }
end

function M.set_config(key, value)
    reaper.SetExtState(M.EXT_SECTION, key, tostring(value), true)
end

function M.region_color(cfg)
    return reaper.ColorToNative(cfg.color_r, cfg.color_g, cfg.color_b) | 0x1000000
end

function M.get_smooth_seek()
    local ok, value = reaper.get_config_var_string("smoothseek")
    return ok and value ~= "0"
end

function M.set_smooth_seek(enabled)
    reaper.set_config_var_string("smoothseek", enabled and "1" or "0", 1)
end

-- ------------------------------------------------------------- bar maths

-- Measure index (0-based) containing the given time, per the project tempo map.
function M.measure_at(time)
    local _, measures = reaper.TimeMap2_timeToBeats(0, time)
    return measures
end

function M.measure_start_time(measure)
    return reaper.TimeMap2_beatsToTime(0, 0.0, measure)
end

-- Start of the bar containing `time`; mode "next" rounds up unless already on a
-- bar (within `tolerance`, so a small overshoot past a boundary snaps back to it
-- instead of rounding all the way up to the next bar).
function M.snap_to_bar(time, mode, tolerance)
    tolerance = tolerance or 1e-9
    local measure = M.measure_at(time)
    local at = M.measure_start_time(measure)
    if mode == "next" and (time - at) > tolerance then
        return M.measure_start_time(measure + 1)
    end
    return at
end

-- End time of a run of `bars` bars starting at `start_time`, honouring tempo/time-sig changes.
function M.bars_to_time(start_time, bars)
    return M.measure_start_time(M.measure_at(start_time) + bars)
end

function M.bars_between(start_time, end_time)
    return M.measure_at(end_time) - M.measure_at(start_time)
end

-- ----------------------------------------------------------- scene model

-- Every region is treated as a scene, whatever it's named - the user can
-- create/rename regions directly in REAPER's timeline/Region Manager and
-- Scenery will pick them up. `num` is the positional (timeline) number,
-- computed fresh each scan rather than stored in the name. A trailing " >>"
-- in the region name marks the scene as linked to its immediate successor
-- (see M.link_chain); it's stripped out of `label` so rename dialogs and the
-- launcher's list never show it.
function M.scan_scenes()
    local scenes = {}
    local i = 0
    while true do
        local retval, isrgn, pos, rgnend, name, markrgnindex, color = reaper.EnumProjectMarkers3(0, i)
        if retval == 0 then break end
        if isrgn then
            local linked = name:match(">>%s*$") ~= nil
            local label = linked and name:gsub("%s*>>%s*$", "") or name
            scenes[#scenes + 1] = {
                enum_idx = i, pos = pos, rgnend = rgnend,
                name = name, label = label, linked = linked, id = markrgnindex, color = color,
            }
        end
        i = i + 1
    end
    -- table.sort's tie-break for equal keys isn't stable/deterministic, so two
    -- regions starting at the same point (a nested scene and the first scene
    -- it contains) could swap order from one scan to the next. Breaking ties
    -- by longest-first keeps the containing (nested) region ordered before
    -- the shorter one it wraps, so scene_at's first-match always resolves to
    -- the nested scene rather than randomly flipping to the inner one.
    table.sort(scenes, function(a, b)
        if a.pos ~= b.pos then return a.pos < b.pos end
        return a.rgnend > b.rgnend
    end)
    for n, s in ipairs(scenes) do s.num = n end
    return scenes
end

-- Builds a region name from a (user-chosen, possibly empty) label plus the
-- link-chain suffix. Unlike scene numbers, labels are never rewritten by
-- Scenery on its own - only explicit renames or link toggles touch them.
function M.scene_name(label, linked)
    local base = label or ""
    return linked and (base .. " >>") or base
end

local function write_scene(s, name)
    reaper.SetProjectMarkerByIndex2(0, s.enum_idx, true, s.pos, s.rgnend, s.id, name, s.color, 0)
end

function M.rename_scene(scene, label)
    write_scene(scene, M.scene_name(label, scene.linked))
end

-- Only the last scene can be resized; earlier ones would overlap their neighbour.
function M.set_scene_length(scene, bars)
    local stop = M.bars_to_time(scene.pos, bars)
    reaper.SetProjectMarkerByIndex2(0, scene.enum_idx, true, scene.pos, stop, scene.id,
        M.scene_name(scene.label, scene.linked), scene.color, 0)
    return stop
end

-- ------------------------------------------------------------ link chains

function M.is_linked_to_next(scene)
    return scene.linked == true
end

function M.set_linked_to_next(scene, linked)
    write_scene(scene, M.scene_name(scene.label, linked))
end

-- The full ordered chain of consecutive linked scenes containing `scene`,
-- regardless of whether it's the head, middle, or tail of that chain.
function M.link_chain(scene, scenes)
    scenes = scenes or M.scan_scenes()
    local head = scene
    while true do
        local prev = scenes[head.num - 1]
        if prev and prev.linked then head = prev else break end
    end
    local chain = { head }
    local current = head
    while current.linked do
        local nxt = scenes[current.num + 1]
        if not nxt then break end
        chain[#chain + 1] = nxt
        current = nxt
    end
    return chain
end

function M.active_link_chain(scenes)
    scenes = scenes or M.scan_scenes()
    local scene = M.active_scene(scenes)
    if not scene then return nil end
    return M.link_chain(scene, scenes)
end

-- The loop range spanning `scene`'s whole link chain (just itself if unlinked).
function M.chain_bounds(scene, scenes)
    local chain = M.link_chain(scene, scenes)
    return chain[1].pos, chain[#chain].rgnend, chain
end

-- Collapses `scene`'s whole link chain into a single scene region spanning
-- head.pos to tail.rgnend. Items are already positioned in absolute project
-- time and untouched by this - only the region markers change. Re-scans and
-- matches by position before each marker edit/delete rather than trusting
-- stale enum_idx values, since deleting a marker shifts every later one's
-- enumeration index.
function M.merge_chain(scene, scenes)
    local chain = M.link_chain(scene, scenes or M.scan_scenes())
    if #chain < 2 then return nil end
    local head_pos, tail_rgnend = chain[1].pos, chain[#chain].rgnend

    local function find(pos)
        for _, s in ipairs(M.scan_scenes()) do
            if math.abs(s.pos - pos) < 1e-6 then return s end
        end
    end

    for i = #chain, 2, -1 do
        local s = find(chain[i].pos)
        if s then reaper.DeleteProjectMarkerByIndex(0, s.enum_idx) end
    end

    local head = find(head_pos)
    if head then
        reaper.SetProjectMarkerByIndex2(0, head.enum_idx, true, head.pos, tail_rgnend, head.id,
            M.scene_name(head.label, false), head.color, 0)
    end
    return head and { pos = head.pos, rgnend = tail_rgnend, name = head.name, num = head.num }
end

-- Removes the region, and its items unless keep_items is true; the timeline gap is left in place.
function M.delete_scene(scene, keep_items)
    if not keep_items then
        for t = reaper.CountTracks(0) - 1, 0, -1 do
            local track = reaper.GetTrack(0, t)
            for k = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
                local item = reaper.GetTrackMediaItem(track, k)
                local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                if pos >= scene.pos - 1e-9 and pos < scene.rgnend - 1e-9 then
                    reaper.DeleteTrackMediaItem(track, item)
                end
            end
        end
    end
    reaper.DeleteProjectMarkerByIndex(0, scene.enum_idx)
end

function M.is_playing()
    return (reaper.GetPlayState() & 1) == 1
end

function M.is_recording()
    return (reaper.GetPlayState() & 4) ~= 0
end

function M.cursor_position()
    if M.is_playing() then return reaper.GetPlayPosition() end
    return reaper.GetCursorPosition()
end

function M.scene_at(time, scenes)
    scenes = scenes or M.scan_scenes()
    local best
    for _, s in ipairs(scenes) do
        if time >= s.pos and time < s.rgnend then return s end
        if time >= s.rgnend and (not best or s.pos > best.pos) then best = s end
    end
    return best
end

-- Prefers the scene that was last explicitly selected (see set_active_range)
-- while the cursor is still inside it, since resolving purely by position is
-- ambiguous whenever regions overlap (e.g. a nested scene sharing its start
-- with the first scene it wraps). Falls back to plain position lookup once
-- the cursor has moved on.
function M.active_scene(scenes)
    scenes = scenes or M.scan_scenes()
    local cursor = M.cursor_position()
    local active_start, active_end = M.get_active_range()
    if active_start and cursor >= active_start - 1e-9 and cursor < active_end then
        for _, s in ipairs(scenes) do
            if math.abs(s.pos - active_start) < 1e-6 and math.abs(s.rgnend - active_end) < 1e-6 then
                return s
            end
        end
    end
    return M.scene_at(cursor, scenes)
end

-- -------------------------------------------------------------- transport

-- Sets loop points + repeat without moving the play cursor, and locks the engine
-- off auto-follow until playback actually reaches this scene.
function M.set_loop_to(scene, lock)
    reaper.GetSet_LoopTimeRange2(0, true, true, scene.pos, scene.rgnend, false)
    reaper.GetSetRepeat(1)
    if lock ~= false then
        reaper.SetExtState(M.EXT_SECTION, "pending_start", tostring(scene.pos), false)
        reaper.SetExtState(M.EXT_SECTION, "pending_end", tostring(scene.rgnend), false)
        reaper.SetExtState(M.EXT_SECTION, "pending_cursor", tostring(reaper.GetCursorPosition()), false)
    else
        M.clear_pending()
        M.set_active_range(scene.pos, scene.rgnend)
    end
end

-- Remembers which scene the loop is meant to be on right now, so the engine's
-- auto-follow can stay put while the cursor is inside it instead of re-picking
-- via scene_at every poll - which is ambiguous whenever regions overlap (e.g.
-- a nested scene sharing its start with the first scene it wraps).
function M.set_active_range(pos, rgnend)
    reaper.SetExtState(M.EXT_SECTION, "active_start", tostring(pos), false)
    reaper.SetExtState(M.EXT_SECTION, "active_end", tostring(rgnend), false)
end

function M.get_active_range()
    local s = tonumber(reaper.GetExtState(M.EXT_SECTION, "active_start"))
    local e = tonumber(reaper.GetExtState(M.EXT_SECTION, "active_end"))
    if not s or not e then return nil end
    return s, e
end

function M.get_pending()
    local s = tonumber(reaper.GetExtState(M.EXT_SECTION, "pending_start"))
    local e = tonumber(reaper.GetExtState(M.EXT_SECTION, "pending_end"))
    if not s or not e then return nil end
    return { pos = s, rgnend = e, cursor = tonumber(reaper.GetExtState(M.EXT_SECTION, "pending_cursor")) or 0 }
end

function M.clear_pending()
    reaper.DeleteExtState(M.EXT_SECTION, "pending_start", false)
    reaper.DeleteExtState(M.EXT_SECTION, "pending_end", false)
    reaper.DeleteExtState(M.EXT_SECTION, "pending_cursor", false)
end

-- ---------------------------------------------------------------- queueing

-- Switches to a scene immediately; smooth seek (if enabled) gives it a quantized
-- feel without the engine having to poll for a future fire time.
function M.queue_scene(scene)
    M.jump_to(scene)
end

function M.engine_running()
    return reaper.GetExtState(M.EXT_SECTION, "engine_running") == "1"
end

-- Registers the engine action if it isn't in the action list yet, then runs it.
function M.start_engine(script_dir)
    local path = script_dir .. "Scenery - Engine (toggle).lua"
    local command = reaper.AddRemoveReaScript(true, 0, path, true)
    if command == 0 then
        reaper.MB("Could not find \"Scenery - Engine (toggle).lua\" next to this script.",
            "Scenery", 0)
        return false
    end
    reaper.Main_OnCommand(command, 0)
    return true
end

-- Shared by the launcher's Rec button and the standalone action. Starting is
-- immediate (native Record command/button can't be intercepted for a
-- quantized start). Stopping, when record-to-end-of-bar is on, is deferred to
-- the engine so nothing recorded in the current bar is lost - see
-- request_quantized_stop/due_record_stop. This is independent of auto-loop,
-- which only controls whether finished recordings get bar-aligned/looped.
function M.toggle_record(cfg, script_dir)
    if M.is_recording() then
        if cfg.record_end_of_bar and M.engine_running() then
            M.request_quantized_stop()
        else
            reaper.Main_OnCommand(1013, 0)
        end
        return
    end
    if (cfg.record_auto_loop or cfg.record_end_of_bar) and not M.engine_running() then
        M.start_engine(script_dir)
    end
    reaper.Main_OnCommand(1013, 0)
end

-- Requests that recording keep running until just past the end of the
-- current bar, instead of cutting off immediately, so nothing is missed;
-- the engine's poll loop watches for this and issues the real stop.
function M.request_quantized_stop()
    local target = M.bars_to_time(M.cursor_position(), 1) + 0.02
    reaper.SetExtState(M.EXT_SECTION, "pending_record_stop", tostring(target), false)
end

function M.record_stop_pending()
    return reaper.GetExtState(M.EXT_SECTION, "pending_record_stop") ~= ""
end

function M.clear_record_stop_pending()
    reaper.DeleteExtState(M.EXT_SECTION, "pending_record_stop", false)
end

-- True once playback has reached (or looped past) the requested stop time -
-- looping past it happens when the bar end coincides with the scene's own
-- loop end, wrapping the play position back to the scene start beforehand.
function M.due_record_stop(play_pos, prev_play_pos)
    local target = tonumber(reaper.GetExtState(M.EXT_SECTION, "pending_record_stop"))
    if not target then return false end
    if not M.is_recording() then
        M.clear_record_stop_pending()
        return false
    end
    if play_pos < target and not (prev_play_pos and play_pos < prev_play_pos) then
        return false
    end
    M.clear_record_stop_pending()
    return true
end

function M.jump_to(scene, scenes)
    local start, stop = M.chain_bounds(scene, scenes)
    M.set_loop_to({ pos = start, rgnend = stop }, false)
    reaper.SetEditCurPos(scene.pos, false, true)
end

function M.beats_until(target)
    local _, _, _, from = reaper.TimeMap2_timeToBeats(0, M.cursor_position())
    local _, _, _, to = reaper.TimeMap2_timeToBeats(0, target)
    return math.max(0, to - from)
end

-- ---------------------------------------------------------------- scenes

-- The new scene's default name is derived purely from how many scene
-- regions currently exist, regardless of what those existing regions are
-- named - so a user free-renaming regions in the Region Manager doesn't
-- disrupt numbering of ones created afterwards via Scenery actions.
-- If that name is already taken (e.g. a region was manually renamed to
-- "Scene 10" ahead of time), " - 1", " - 2", etc. are appended until unique.
local function unique_scene_name(base, scenes)
    local taken = {}
    for _, s in ipairs(scenes) do taken[s.name] = true end
    if not taken[base] then return base end
    local n = 1
    while taken[base .. " - " .. n] do n = n + 1 end
    return base .. " - " .. n
end

function M.create_scene(bars)
    local cfg = M.get_config()
    local scenes = M.scan_scenes()
    local start = (#scenes > 0) and scenes[#scenes].rgnend or M.snap_to_bar(0)
    local stop = M.bars_to_time(start, bars)
    local name = unique_scene_name(M.SCENE_PREFIX .. " " .. (#scenes + 1), scenes)
    reaper.AddProjectMarker2(0, true, start, stop, name, -1, M.region_color(cfg))
    return { pos = start, rgnend = stop, name = name, num = #scenes + 1 }
end

-- Appends a new scene at the configured default bar length, tiling the
-- source content to fill it (or trimming it, if the default is shorter).
function M.duplicate_scene(source)
    local bars = M.get_config().default_bars
    local scene = M.create_scene(bars)
    local unit = source.rgnend - source.pos
    if unit <= 1e-9 then
        M.copy_items(source.pos, source.rgnend, scene.pos, scene.rgnend)
        return scene
    end
    local dest = scene.pos
    while dest < scene.rgnend - 1e-9 do
        local tile_end = math.min(dest + unit, scene.rgnend)
        M.copy_items(source.pos, source.rgnend, dest, tile_end)
        dest = dest + unit
    end
    return scene
end

-- ----------------------------------------------------------------- items

local function item_guid(item)
    local ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    if not ok or guid == "" then return nil end
    return guid
end

function M.snapshot_item_guids()
    local guids = {}
    for t = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, t)
        for k = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, k)
            local guid = item_guid(item)
            if guid then guids[guid] = true end
        end
    end
    return guids
end

-- Recording starts immediately (not bar-aligned), so the new item is physically
-- split/trimmed to one bar (MIDI_SetItemExtents for MIDI takes, since resizing
-- D_LENGTH alone doesn't update a MIDI take's own PPQ-based extents), then that
-- one-bar unit is physically duplicated across the rest of the scene - B_LOOPSRC
-- isn't used since its repeat unit also follows the take's own extents, not D_LENGTH.
local cloned_chunk

function M.apply_loop_source_to_new_items(existing_guids, scene)
    if not existing_guids or not scene then return 0 end

    local targets = {}
    for t = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, t)
        for k = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, k)
            local guid = item_guid(item)
            local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            if guid and not existing_guids[guid]
                and pos >= scene.pos - 1e-9 and pos < scene.rgnend - 1e-9 then
                targets[#targets + 1] = { track = track, item = item, pos = pos }
            end
        end
    end

    local processed = 0
    for _, target in ipairs(targets) do
        local track, item, pos = target.track, target.item, target.pos
        local snapped_pos = math.min(scene.rgnend, math.max(scene.pos, M.snap_to_bar(pos, "next")))
        local recorded_end = pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        -- a small overshoot past a bar (e.g. from the quantized-stop margin, or
        -- just late-stopping) should trim back to that bar, not pad a whole
        -- extra one on top of it
        local snapped_end = math.min(scene.rgnend, M.snap_to_bar(recorded_end, "next", 0.2))
        if snapped_end <= snapped_pos + 1e-9 then
            snapped_end = math.min(scene.rgnend, M.bars_to_time(snapped_pos, 1))
        end
        local scene_length = scene.rgnend - snapped_pos
        if snapped_end > snapped_pos + 1e-9 and scene_length > 0 then
            if pos < snapped_pos - 1e-9 then
                local right = reaper.SplitMediaItem(item, snapped_pos)
                if right then
                    reaper.DeleteTrackMediaItem(track, item)
                    item = right
                end
            end
            if recorded_end > snapped_end + 1e-9 then
                local right = reaper.SplitMediaItem(item, snapped_end)
                if right then reaper.DeleteTrackMediaItem(track, right) end
            end
            -- For MIDI, D_LENGTH/SetMediaItemLength don't touch the take's own
            -- PPQ-based extents (visible in Item Properties), so growing a
            -- short take leaves it reporting its old, un-padded length;
            -- MIDI_SetItemExtents is the API that actually updates that.
            local take = reaper.GetActiveTake(item)
            if take and reaper.TakeIsMIDI(take) then
                local start_qn = reaper.TimeMap2_timeToQN(0, snapped_pos)
                local end_qn = reaper.TimeMap2_timeToQN(0, snapped_end)
                reaper.MIDI_SetItemExtents(item, start_qn, end_qn)
            else
                -- disable loop-source first, else REAPER auto-repeats the take
                -- from its raw recorded end when the item is grown past it -
                -- we want silence there instead, since we tile bars ourselves
                reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
                reaper.SetMediaItemLength(item, snapped_end - snapped_pos, true)
            end
            reaper.UpdateItemInProject(item)

            local unit = snapped_end - snapped_pos
            local dest = snapped_end
            while dest < scene.rgnend - 1e-9 do
                local chunk = cloned_chunk(item)
                if not chunk then break end
                local tile = reaper.AddMediaItemToTrack(track)
                reaper.SetItemStateChunk(tile, chunk, false)
                reaper.SetMediaItemInfo_Value(tile, "D_POSITION", dest)
                if dest + unit > scene.rgnend + 1e-9 then
                    local right = reaper.SplitMediaItem(tile, scene.rgnend)
                    if right then reaper.DeleteTrackMediaItem(track, right) end
                end
                dest = dest + unit
            end

            processed = processed + 1
        else
            -- entirely a pickup with no room left in the scene for even a
            -- partial bar (e.g. engine follow() moved the loop mid-record) -
            -- it's noise, not something to leave in the project untouched
            reaper.DeleteTrackMediaItem(track, item)
        end
    end
    return processed
end

cloned_chunk = function(item)
    local ok, chunk = reaper.GetItemStateChunk(item, "", false)
    if not ok then return nil end
    return (chunk:gsub("\n([ \t]*)(I?GUID) {[^}]*}", function(indent, tag)
        return "\n" .. indent .. tag .. " " .. reaper.genGuid("")
    end))
end

-- Copies every item starting within [src_start, src_end) to the same track,
-- offset to dest_start and clamped so nothing overruns dest_end.
function M.copy_items(src_start, src_end, dest_start, dest_end)
    local offset = dest_start - src_start
    local copied = 0
    for t = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, t)
        local sources = {}
        for k = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, k)
            local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            if pos >= src_start - 1e-9 and pos < src_end - 1e-9 then
                sources[#sources + 1] = item
            end
        end
        for _, item in ipairs(sources) do
            local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION") + offset
            -- an item whose offset position already lands at/past dest_end has nothing
            -- to keep - SplitMediaItem can't split before an item's own start, so it
            -- would otherwise be copied in full and left overhanging unclamped
            if pos < dest_end - 1e-9 then
                local chunk = cloned_chunk(item)
                if chunk then
                    local new_item = reaper.AddMediaItemToTrack(track)
                    reaper.SetItemStateChunk(new_item, chunk, false)
                    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                    reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", pos)
                    if pos + len > dest_end + 1e-9 then
                        -- split rather than shrink D_LENGTH: for MIDI takes the source's own
                        -- PPQ extents don't follow D_LENGTH, so notes past dest_end would still show
                        local right = reaper.SplitMediaItem(new_item, dest_end)
                        if right then reaper.DeleteTrackMediaItem(track, right) end
                    end
                    copied = copied + 1
                end
            end
        end
    end
    return copied
end

-- ------------------------------------------------------------------ misc

function M.msg(text)
    reaper.ShowConsoleMsg("[Scenery] " .. tostring(text) .. "\n")
end

return M
