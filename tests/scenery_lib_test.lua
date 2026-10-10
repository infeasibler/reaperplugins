local scenery = dofile("scenery/scenery_lib.lua")
local passed = 0
local failed = 0

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function make_scene(num, pos, rgnend, linked, label)
    return {
        num = num,
        pos = pos,
        rgnend = rgnend,
        linked = linked or false,
        label = label or ("Scene " .. num),
    }
end

local function with_fake_reaper(fake, callback)
    local previous_reaper = _G.reaper
    setmetatable(fake, {
        __index = function(_, name)
            error("unexpected REAPER API call: " .. name, 2)
        end,
    })
    _G.reaper = fake
    local ok, error_message = xpcall(callback, debug.traceback)
    _G.reaper = previous_reaper
    if not ok then error(error_message, 0) end
end

local function make_state_fake()
    local values = {}
    return {
        values = values,
        GetExtState = function(section, key)
            return values[section .. ":" .. key] or ""
        end,
        SetExtState = function(section, key, value)
            values[section .. ":" .. key] = value
        end,
        GetMasterTrack = function() return nil end,
        CountTrackEnvelopes = function(track) return #(track.envelopes or {}) end,
        GetTrackEnvelope = function(track, index) return track.envelopes[index + 1] end,
        DeleteExtState = function(section, key)
            values[section .. ":" .. key] = nil
        end,
    }
end

local function make_duplicate_fake(skip_occupied_tracks, with_audio_leadout, skip_track_guids)
    local fake = make_state_fake()
    local markers = { { true, 0, 4, "Source", 1, 0 } }
    local track = { items = {} }
    local lead_in = { pos = -1, len = 4 }
    local destination_item_before = { pos = 2, len = 4 }
    local destination_item = { pos = 11, len = 2 }
    track.items = { lead_in, destination_item_before, destination_item }
    local audio_first
    local audio_leadout
    if with_audio_leadout then
        audio_first = { pos = 0, len = 1, fade_in = 0, fade_out = 0, take = { is_midi = false } }
        audio_leadout = { pos = 3, len = 2, fade_in = 0, fade_out = 1, take = { is_midi = false } }
        track.items[#track.items + 1] = audio_first
        track.items[#track.items + 1] = audio_leadout
    end
    fake.values[scenery.EXT_SECTION .. ":default_bars"] = "2"
    fake.values[scenery.EXT_SECTION .. ":skip_track_guids"] = skip_track_guids or ""
    if skip_occupied_tracks then
        fake.values[scenery.EXT_SECTION .. ":skip_occupied_tracks"] = "1"
    end
    fake.SetProjectMarkerByIndex2 = function(_, index, is_region, pos, rgnend, id, name, color)
        markers[index + 1] = { is_region, pos, rgnend, name, id, color }
        return true
    end
    fake.EnumProjectMarkers3 = function(_, index)
        local marker = markers[index + 1]
        if not marker then return 0 end
        return 1, marker[1], marker[2], marker[3], marker[4], marker[5], marker[6]
    end
    fake.TimeMap2_timeToBeats = function(_, time)
        return 0, math.floor(time / 4), 0, time, 0
    end
    fake.TimeMap2_beatsToTime = function(_, _, measure) return measure * 4 end
    fake.ColorToNative = function() return 1 end
    fake.AddProjectMarker2 = function(_, is_region, pos, rgnend, name, id, color)
        markers[#markers + 1] = { is_region, pos, rgnend, name, id, color }
        return #markers
    end
    fake.CountTracks = function() return 1 end
    fake.GetTrack = function() return track end
    fake.GetMasterTrack = function() return nil end
    fake.CountTrackEnvelopes = function(target) return #(target.envelopes or {}) end
    fake.GetTrackEnvelope = function(target, index) return target.envelopes[index + 1] end
    fake.CountEnvelopePointsEx = function(envelope, autoitem_index)
        if autoitem_index == -1 then return #envelope.points end
        return #envelope.items[autoitem_index + 1].points
    end
    fake.GetEnvelopePointEx = function(envelope, autoitem_index, index)
        local point = autoitem_index == -1 and envelope.points[index + 1]
            or envelope.items[autoitem_index + 1].points[index + 1]
        if not point then return false end
        return true, point.time, point.value, point.shape or 0, point.tension or 0, point.selected or false
    end
    fake.InsertEnvelopePointEx = function(envelope, autoitem_index, time, value, shape, tension, selected)
        local points = autoitem_index == -1 and envelope.points or envelope.items[autoitem_index + 1].points
        points[#points + 1] = {
            time = time, value = value, shape = shape, tension = tension, selected = selected,
        }
        return true
    end
    fake.DeleteEnvelopePointEx = function(envelope, autoitem_index, index)
        table.remove(autoitem_index == -1 and envelope.points or envelope.items[autoitem_index + 1].points,
            index + 1)
        return true
    end
    fake.SetEnvelopePointEx = function(envelope, autoitem_index, index, time)
        local points = autoitem_index == -1 and envelope.points or envelope.items[autoitem_index + 1].points
        points[index + 1].time = time
        return true
    end
    fake.Envelope_SortPointsEx = function(envelope, autoitem_index)
        local points = autoitem_index == -1 and envelope.points or envelope.items[autoitem_index + 1].points
        table.sort(points, function(left, right) return left.time < right.time end)
        return true
    end
    fake.CountAutomationItems = function(envelope) return #envelope.items end
    fake.GetSetAutomationItemInfo = function(envelope, index, property, value, set_value)
        local item = envelope.items[index + 1]
        if set_value then item[property] = value end
        return item[property] or 0
    end
    fake.InsertAutomationItem = function(envelope, pool_id, position, length)
        if pool_id < 0 then
            envelope.next_pool_id = (envelope.next_pool_id or 100) + 1
            pool_id = envelope.next_pool_id
        end
        local item = {
            D_POOL_ID = pool_id, D_POSITION = position, D_LENGTH = length, D_STARTOFFS = 0,
            D_PLAYRATE = 1, D_BASELINE = 0, D_AMPLITUDE = 1, D_LOOPSRC = 0,
            D_UISEL = 0, D_MUTE = 0, points = {},
        }
        envelope.items[#envelope.items + 1] = item
        return #envelope.items - 1
    end
    fake.DeleteAutomationItem = function(envelope, index)
        table.remove(envelope.items, index + 1)
        return true
    end
    track.guid = "{track-1}"
    fake.GetTrackGUID = function(target) return target.guid end
    fake.CountTrackMediaItems = function(target) return #target.items end
    fake.GetTrackMediaItem = function(target, index) return target.items[index + 1] end
    fake.GetMediaItemInfo_Value = function(item, key)
        if key == "D_POSITION" then return item.pos end
        if key == "D_LENGTH" then return item.len end
        if key == "D_FADEINLEN" then return item.fade_in or 0 end
        if key == "D_FADEOUTLEN" then return item.fade_out or 0 end
    end
    fake.GetItemStateChunk = function(item)
        return true, string.format("ITEM\nPOSITION %.17g\nLENGTH %.17g\nFADEIN %.17g\nFADEOUT %.17g\nTAKE %d\nMIDI %d\n",
            item.pos, item.len, item.fade_in or 0, item.fade_out or 0,
            item.take and 1 or 0,
            item.take and item.take.is_midi and 1 or 0)
    end
    fake.SetItemStateChunk = function(item, chunk)
        item.pos = tonumber(chunk:match("POSITION ([^\n]+)")) or item.pos
        item.len = tonumber(chunk:match("LENGTH ([^\n]+)")) or item.len
        item.fade_in = tonumber(chunk:match("FADEIN ([^\n]+)")) or 0
        item.fade_out = tonumber(chunk:match("FADEOUT ([^\n]+)")) or 0
        local has_take = chunk:match("TAKE (%d+)")
        local is_midi = chunk:match("MIDI (%d+)")
        if has_take == "1" then item.take = { is_midi = is_midi == "1" } end
        return true
    end
    fake.AddMediaItemToTrack = function(target)
        local item = { pos = 0, len = 0 }
        target.items[#target.items + 1] = item
        return item
    end
    fake.SetMediaItemInfo_Value = function(item, key, value)
        if key == "D_POSITION" then item.pos = value end
        if key == "D_FADEINLEN" then item.fade_in = value end
        if key == "D_FADEOUTLEN" then item.fade_out = value end
    end
    fake.GetActiveTake = function(item) return item.take end
    fake.TakeIsMIDI = function(take) return take.is_midi end
    fake.SplitMediaItem = function(item, split_pos)
        local right = { pos = split_pos, len = item.pos + item.len - split_pos }
        item.len = split_pos - item.pos
        track.items[#track.items + 1] = right
        return right
    end
    fake.DeleteTrackMediaItem = function(target, item_to_delete)
        for index, item in ipairs(target.items) do
            if item == item_to_delete then
                table.remove(target.items, index)
                return
            end
        end
    end
    return fake, track, lead_in, destination_item_before, destination_item, audio_first, audio_leadout
end

local function add_duplicate_automation(fake, track)
    local envelope = {
        points = {
            { time = 0, value = 0.1 }, { time = 2, value = 0.5 },
            { time = 5, value = 0.9 }, { time = 12, value = 0.2 },
        },
        items = {
            { D_POOL_ID = 7, D_POSITION = 1, D_LENGTH = 1, D_STARTOFFS = 0,
                D_PLAYRATE = 1, D_BASELINE = 0, D_AMPLITUDE = 1, D_LOOPSRC = 0,
                D_UISEL = 0, D_MUTE = 0,
                points = { { time = 1, value = 0.2 }, { time = 1.5, value = 0.8 } } },
            { D_POOL_ID = 8, D_POSITION = 5, D_LENGTH = 1, D_STARTOFFS = 0,
                D_PLAYRATE = 1, D_BASELINE = 0, D_AMPLITUDE = 1, D_LOOPSRC = 0,
                D_UISEL = 0, D_MUTE = 0, points = {} },
        },
    }
    local unrelated_envelope = { points = { { time = 5, value = 0.7 } }, items = {} }
    track.envelopes = { envelope, unrelated_envelope }
    return envelope, unrelated_envelope
end

local function make_reorder_fake()
    local fake = make_state_fake()
    fake.restored = 0
    fake.play_state = 0
    local scenes = { make_scene(1, 0, 4), make_scene(2, 4, 8, true),
        make_scene(3, 8, 10), make_scene(4, 10, 15) }
    local markers = {}
    for index, scene in ipairs(scenes) do
        scene.id = index
        scene.name = "Scene " .. index
        scene.enum_idx = index - 1
        markers[#markers + 1] = { true, scene.pos, scene.rgnend, "Scene " .. index, index, index }
    end
    markers[#markers + 1] = { false, 5, 0, "Inside", 1, 0 }
    local envelope = {
        points = { { 0, 0, 0, 0, false }, { 5, 0.5, 0, 0, true }, { 15, 1, 0, 0, false } },
        items = { { D_POOL_ID = 7, D_POSITION = 3, D_LENGTH = 3, D_STARTOFFS = 1,
            D_PLAYRATE = 2, D_BASELINE = 0.2, D_AMPLITUDE = 0.8, D_LOOPSRC = 1,
            D_UISEL = 1, D_MUTE = 0 } },
    }
    local track = { items = { { pos = 0, len = 4 }, { pos = 4, len = 6 },
        { pos = 10, len = 5 }, { pos = 16, len = 1 } }, envelopes = { envelope } }
    local master = { items = {}, envelopes = {} }
    fake.GetPlayState = function() return fake.play_state end
    fake.GetSetProjectInfo = function() return 48000 end
    fake.GetProjectLength = function() return 20 end
    fake.CountTracks = function() return 1 end
    fake.GetTrack = function() return track end
    fake.GetMasterTrack = function() return master end
    fake.CountTrackMediaItems = function(target) return #target.items end
    fake.GetTrackMediaItem = function(target, index) return target.items[index + 1] end
    fake.GetMediaItemInfo_Value = function(item, key)
        if key == "D_POSITION" then return item.pos end
        if key == "D_LENGTH" then return item.len end
        if key == "C_LOCK" then return item.locked and 1 or 0 end
    end
    fake.SetMediaItemInfo_Value = function(item, key, value)
        if key == "D_POSITION" then item.pos = value end
        return true
    end
    fake.SplitMediaItem = function(item, position)
        local right = { pos = position, len = item.pos + item.len - position }
        item.len = position - item.pos
        track.items[#track.items + 1] = right
        return right
    end
    fake.GetTrackStateChunk = function(target) return true, target end
    fake.SetTrackStateChunk = function() fake.restored = (fake.restored or 0) + 1; return true end
    fake.CountTrackEnvelopes = function(target) return #target.envelopes end
    fake.GetTrackEnvelope = function(target, index) return target.envelopes[index + 1] end
    fake.GetTrackEnvelopeByChunkName = function() return nil end
    fake.CountEnvelopePointsEx = function(target) return #target.points end
    fake.GetEnvelopePointEx = function(target, _, index)
        local point = target.points[index + 1]
        if not point then return false end
        return true, table.unpack(point)
    end
    fake.GetEnvelopePointByTimeEx = function(target, _, time)
        local found = -1
        for index, point in ipairs(target.points) do
            if point[1] <= time then found = index - 1 end
        end
        return found
    end
    fake.Envelope_Evaluate = function(target, time)
        assert_equal(target.items[1].D_MUTE, 1)
        return 1, time / 15
    end
    fake.DeleteEnvelopePointEx = function(target, _, index)
        table.remove(target.points, index + 1)
        return true
    end
    fake.InsertEnvelopePointEx = function(target, _, time, value, shape, tension, selected)
        target.points[#target.points + 1] = { time, value, shape, tension, selected }
        return true
    end
    fake.Envelope_SortPointsEx = function(target)
        table.sort(target.points, function(left, right) return left[1] < right[1] end)
        return true
    end
    fake.CountAutomationItems = function(target) return #target.items end
    fake.GetSetAutomationItemInfo = function(target, index, key, value, write)
        local item = target.items[index + 1]
        if write then item[key] = value end
        local result = item[key]
        if write and key == "D_POSITION" then
            table.sort(target.items, function(left, right) return left.D_POSITION < right.D_POSITION end)
        end
        return result
    end
    fake.InsertAutomationItem = function(target, pool, position, length)
        local item = { D_POOL_ID = pool, D_POSITION = position, D_LENGTH = length }
        target.items[#target.items + 1] = item
        table.sort(target.items, function(left, right) return left.D_POSITION < right.D_POSITION end)
        for index, candidate in ipairs(target.items) do if candidate == item then return index - 1 end end
    end
    fake.EnumProjectMarkers3 = function(_, index)
        local marker = markers[index + 1]
        if not marker then return 0 end
        return 1, table.unpack(marker)
    end
    fake.SetProjectMarkerByIndex2 = function(_, index, is_region, position, finish, id, name, color, flags)
        if index == -1 then
            table.sort(markers, function(left, right) return left[2] < right[2] end)
        else
            assert_equal(flags & 2, 2)
            markers[index + 1] = { is_region, position, finish, name, id, color }
        end
        return true
    end
    return fake, scenes, track, envelope, markers, master
end

local tests = {
    {
        name = "launcher drag handles commit on release and Escape cancels without launching",
        run = function()
            local function run_frames(frames, expected_moves)
                local fake, scenes = make_reorder_fake()
                local move_count, launch_count, undo_count = 0, 0, 0
                local pending_frame
                local library = {
                    EXT_SECTION = scenery.EXT_SECTION,
                    get_config = scenery.get_config,
                    scan_scenes = function() return scenes end,
                    active_scene = function() return scenes[1] end,
                    get_next_scene_id = function() return nil end,
                    get_smooth_seek = function() return false end,
                    record_stop_pending = function() return false end,
                    is_recording = function() return false end,
                    engine_running = function() return true end,
                    link_chain = scenery.link_chain,
                    scene_move_plan = scenery.scene_move_plan,
                    switch_scene = function() launch_count = launch_count + 1 end,
                    jump_to = function() launch_count = launch_count + 1 end,
                    move_scene = function(source, before_scene)
                        assert_equal(source.id, 1)
                        assert_equal(before_scene, nil)
                        move_count = move_count + 1
                        return true
                    end,
                }
                local graphics = { w = 260, h = 1000, mouse_wheel = 0 }
                graphics.set = function() end
                graphics.rect = function() end
                graphics.setfont = function() end
                graphics.measurestr = function(text) return #text * 6, 14 end
                graphics.drawstr = function() end
                graphics.init = function() end
                graphics.update = function() end
                graphics.getchar = function() return graphics.character end
                fake.get_action_context = function() return false, "scenery/Scenery - Launcher.lua" end
                fake.EnumProjects = function() return "project" end
                fake.GetProjectStateChangeCount = function() return 1 end
                fake.time_precise = function() return 10 end
                fake.TrackCtl_SetToolTip = false
                fake.JS_Window_AttachTopmostPin = false
                fake.PreventUIRefresh = function() end
                fake.UpdateArrange = function() end
                fake.Undo_BeginBlock2 = function() undo_count = undo_count + 1 end
                fake.Undo_EndBlock2 = function() end
                fake.atexit = function() end
                fake.defer = function(callback) pending_frame = callback end
                local environment = setmetatable({ reaper = fake, gfx = graphics,
                    dofile = function() return library end }, { __index = _G })
                with_fake_reaper(fake, function()
                    for index, input in ipairs(frames) do
                        graphics.mouse_x, graphics.mouse_y, graphics.mouse_cap, graphics.character =
                            input[1], input[2], input[3], input[4]
                        if index == 1 then
                            assert(loadfile("scenery/Scenery - Launcher.lua", "t", environment))()
                        else
                            local callback = pending_frame
                            pending_frame = nil
                            callback()
                        end
                        if index < 3 then assert_equal(move_count, 0) end
                    end
                    assert_equal(move_count, expected_moves)
                    assert_equal(undo_count, expected_moves)
                    assert_equal(launch_count, 0)
                end)
            end
            run_frames({ { 16, 16, 1, 0 }, { 16, 135, 1, 0 }, { 16, 135, 0, -1 } }, 1)
            run_frames({ { 16, 16, 1, 0 }, { 16, 135, 1, 27 }, { 16, 135, 0, -1 } }, 0)
            run_frames({ { 16, 16, 1, 0 }, { 400, 135, 1, 0 }, { 400, 135, 0, -1 } }, 0)
        end,
    },
    {
        name = "reordering moves linked media, markers and automation while preserving pooled splits",
        run = function()
            local fake, scenes, track, envelope, markers = make_reorder_fake()
            with_fake_reaper(fake, function()
                assert_equal(scenery.move_scene(scenes[3], scenes[1], scenes), true)
                assert_equal(track.items[1].pos, 6)
                assert_equal(track.items[2].pos, 0)
                assert_equal(track.items[3].pos, 10)
                assert_equal(track.items[4].pos, 16)
                local moved_point
                for _, point in ipairs(envelope.points) do
                    if point[5] then moved_point = point end
                end
                assert_equal(moved_point[1], 1)
                assert_equal(moved_point[2], 0.5)
                assert_equal(#envelope.items, 2)
                assert_equal(envelope.items[1].D_POSITION, 0)
                assert_equal(envelope.items[1].D_LENGTH, 2)
                assert_equal(envelope.items[1].D_STARTOFFS, 3)
                assert_equal(envelope.items[2].D_POSITION, 9)
                assert_equal(envelope.items[2].D_LENGTH, 1)
                for _, item in ipairs(envelope.items) do
                    assert_equal(item.D_POOL_ID, 7)
                    assert_equal(item.D_MUTE, 0)
                    assert_equal(item.D_AMPLITUDE, 0.8)
                end
                for _, marker in ipairs(markers) do
                    if marker[4] == "Inside" then assert_equal(marker[2], 1) end
                    if marker[4] == "Scene 2" then
                        assert_equal(marker[2], 0)
                        assert_equal(marker[3], 4)
                    end
                end
            end)
        end,
    },
    {
        name = "scene reordering splits crossing media and rolls back failed track edits",
        run = function()
            local fake, scenes, track = make_reorder_fake()
            track.items = { { pos = 2, len = 10 } }
            track.envelopes = {}
            with_fake_reaper(fake, function()
                assert_equal(scenery.move_scene(scenes[2], nil, scenes), true)
                assert_equal(#track.items, 3)
                assert_equal(track.items[1].pos, 2)
                assert_equal(track.items[1].len, 2)
                assert_equal(track.items[2].pos, 9)
                assert_equal(track.items[2].len, 6)
                assert_equal(track.items[3].pos, 4)
                assert_equal(track.items[3].len, 2)
            end)
            fake, scenes, track = make_reorder_fake()
            track.items = { { pos = 2, len = 10 } }
            fake.SplitMediaItem = function() return nil end
            with_fake_reaper(fake, function()
                local ok, message = scenery.move_scene(scenes[2], nil, scenes)
                assert_equal(ok, false)
                assert_equal(assert(message):find("rolled back", 1, true) ~= nil, true)
                assert_equal(fake.restored, 2)
            end)
        end,
    },
    {
        name = "scene reordering rejects playback, locked items and overlapping regions before editing",
        run = function()
            local fake, scenes, track = make_reorder_fake()
            with_fake_reaper(fake, function()
                fake.play_state = 1
                assert_equal(scenery.move_scene(scenes[2], nil, scenes), false)
                fake.play_state = 0
                track.items[2].locked = true
                assert_equal(scenery.move_scene(scenes[2], nil, scenes), false)
                track.items[2].locked = false
                scenes[1].rgnend = 5
                assert_equal(scenery.move_scene(scenes[2], nil, scenes), false)
                assert_equal(track.items[2].pos, 4)
            end)
        end,
    },
    {
        name = "scene move plans preserve linked chains in both directions and ignore self drops",
        run = function()
            local scenes = {
                make_scene(1, 0, 4), make_scene(2, 4, 8, true),
                make_scene(3, 8, 10), make_scene(4, 10, 15),
            }
            local earlier = assert(scenery.scene_move_plan(scenes[3], scenes[1], scenes))
            assert_equal(#earlier.chain, 2)
            assert_equal(earlier.ranges[1].offset, 6)
            assert_equal(earlier.ranges[2].offset, -4)
            local later = assert(scenery.scene_move_plan(scenes[2], nil, scenes))
            assert_equal(later.ranges[1].offset, 5)
            assert_equal(later.ranges[2].offset, -6)
            local into_chain = scenery.scene_move_plan(scenes[1], scenes[3], scenes)
            assert_equal(into_chain, nil)
            assert_equal(scenery.scene_move_plan(scenes[3], scenes[2], scenes), nil)
        end,
    },
    {
        name = "deleting a scene removes its items and shifts later items and markers left",
        run = function()
            local markers = {
                { false, 5, 0, "Earlier marker", 8, 0 },
                { true, 10, 14, "Delete me", 7, 0 },
                { false, 12, 0, "Inside marker", 10, 0 },
                { true, 14, 18, "Later scene", 9, 0 },
                { false, 16, 0, "Later marker", 11, 0 },
            }
            local track = { items = {
                { pos = 8, len = 4 },
                { pos = 11, len = 1 },
                { pos = 8, len = 8 },
                { pos = 14, len = 1 },
            } }
            local fake = {
                GetSetProjectInfo = function() return 48000 end,
                EnumProjectMarkers3 = function(_, index)
                    local marker = markers[index + 1]
                    if not marker then return 0 end
                    return 1, table.unpack(marker)
                end,
                DeleteProjectMarkerByIndex = function(_, index)
                    table.remove(markers, index + 1)
                end,
                SetProjectMarkerByIndex2 = function(_, index, is_region, pos, rgnend, id, name, color)
                    markers[index + 1] = { is_region, pos, rgnend, name, id, color }
                    table.sort(markers, function(left, right) return left[2] < right[2] end)
                end,
                CountTracks = function() return 1 end,
                GetTrack = function() return track end,
                GetMasterTrack = function() return nil end,
                CountTrackEnvelopes = function() return 0 end,
                CountTrackMediaItems = function(target) return #target.items end,
                GetTrackMediaItem = function(target, index) return target.items[index + 1] end,
                GetMediaItemInfo_Value = function(item, key)
                    if key == "D_POSITION" then return item.pos end
                    if key == "D_LENGTH" then return item.len end
                end,
                SetMediaItemInfo_Value = function(item, key, value)
                    if key == "D_POSITION" then item.pos = value end
                end,
                SplitMediaItem = function(item, split_pos)
                    local right = {
                        pos = split_pos,
                        len = item.pos + item.len - split_pos,
                    }
                    item.len = split_pos - item.pos
                    track.items[#track.items + 1] = right
                    return right
                end,
                DeleteTrackMediaItem = function(target, item_to_delete)
                    for index, item in ipairs(target.items) do
                        if item == item_to_delete then
                            table.remove(target.items, index)
                            return
                        end
                    end
                end,
            }
            with_fake_reaper(fake, function()
                scenery.delete_scene_and_shift({ enum_idx = 1, pos = 10, rgnend = 14 })
                assert_equal(#track.items, 4)
                local positions = {}
                for _, item in ipairs(track.items) do positions[#positions + 1] = item.pos end
                table.sort(positions)
                assert_equal(table.concat(positions, ","), "8,8,10,10")
                local marker_by_name = {}
                for _, marker in ipairs(markers) do marker_by_name[marker[4]] = marker end
                assert_equal(#markers, 4)
                assert_equal(marker_by_name["Earlier marker"][2], 5)
                assert_equal(marker_by_name["Inside marker"][2], 12)
                assert_equal(marker_by_name["Later scene"][2], 10)
                assert_equal(marker_by_name["Later scene"][3], 14)
                assert_equal(marker_by_name["Later marker"][2], 12)
            end)
        end,
    },
    {
        name = "sub-sample leading overlap is deleted without splitting and later audio is preserved",
        run = function()
            local markers = {
                { true, 10, 14, "Delete me", 7, 0 },
            }
            local track = { items = { { pos = 9.999999, len = 5 } } }
            local split_positions = {}
            local fake = {
                GetSetProjectInfo = function(_, key)
                    assert_equal(key, "PROJECT_SRATE")
                    return 48000
                end,
                EnumProjectMarkers3 = function(_, index)
                    local marker = markers[index + 1]
                    if not marker then return 0 end
                    return 1, table.unpack(marker)
                end,
                DeleteProjectMarkerByIndex = function(_, index)
                    table.remove(markers, index + 1)
                end,
                CountTracks = function() return 1 end,
                GetTrack = function() return track end,
                GetMasterTrack = function() return nil end,
                CountTrackEnvelopes = function() return 0 end,
                CountTrackMediaItems = function(target) return #target.items end,
                GetTrackMediaItem = function(target, index) return target.items[index + 1] end,
                GetMediaItemInfo_Value = function(item, key)
                    if key == "D_POSITION" then return item.pos end
                    if key == "D_LENGTH" then return item.len end
                end,
                SplitMediaItem = function(item, split_pos)
                    split_positions[#split_positions + 1] = split_pos
                    local right = { pos = split_pos, len = item.pos + item.len - split_pos }
                    item.len = split_pos - item.pos
                    track.items[#track.items + 1] = right
                    return right
                end,
                DeleteTrackMediaItem = function(target, item_to_delete)
                    for index, item in ipairs(target.items) do
                        if item == item_to_delete then
                            table.remove(target.items, index)
                            return
                        end
                    end
                end,
                SetMediaItemInfo_Value = function(item, key, value)
                    if key == "D_POSITION" then item.pos = value end
                end,
                SetProjectMarkerByIndex2 = function(_, index, is_region, pos, rgnend, id, name, color)
                    markers[index + 1] = { is_region, pos, rgnend, name, id, color }
                end,
            }
            with_fake_reaper(fake, function()
                local succeeded = scenery.delete_scene_and_shift({ enum_idx = 0, pos = 10, rgnend = 14 })
                assert_equal(succeeded, true)
                assert_equal(#split_positions, 1)
                assert_equal(split_positions[1], 14)
                assert_equal(#track.items, 1)
                assert_equal(track.items[1].pos, 10)
                assert_equal(math.floor(track.items[1].len * 1000000 + 0.5), 999999)
            end)
        end,
    },
    {
        name = "failed item split reports timing and lock state without passing an invalid handle",
        run = function()
            local markers = {
                { true, 10, 14, "Delete me", 7, 0 },
            }
            local track = { items = { { pos = 8, len = 8, locked = false } } }
            local split_calls = 0
            local delete_item_called = false
            local fake = {
                GetSetProjectInfo = function() return 48000 end,
                EnumProjectMarkers3 = function(_, index)
                    local marker = markers[index + 1]
                    if not marker then return 0 end
                    return 1, table.unpack(marker)
                end,
                DeleteProjectMarkerByIndex = function(_, index)
                    table.remove(markers, index + 1)
                end,
                CountTracks = function() return 1 end,
                GetTrack = function() return track end,
                CountTrackMediaItems = function(target) return #target.items end,
                GetTrackMediaItem = function(target, index) return target.items[index + 1] end,
                GetMediaItemInfo_Value = function(item, key)
                    if key == "D_POSITION" then return item.pos end
                    if key == "D_LENGTH" then return item.len end
                    if key == "C_LOCK" then return item.locked and 1 or 0 end
                end,
                SplitMediaItem = function(item, split_pos)
                    split_calls = split_calls + 1
                    if split_calls == 2 then return nil end
                    local right = { pos = split_pos, len = item.pos + item.len - split_pos }
                    item.len = split_pos - item.pos
                    track.items[#track.items + 1] = right
                    return right
                end,
                DeleteTrackMediaItem = function()
                    delete_item_called = true
                end,
            }
            with_fake_reaper(fake, function()
                local succeeded, failure = scenery.delete_scene_and_shift({
                    enum_idx = 0,
                    pos = 10,
                    rgnend = 14,
                })
                assert_equal(succeeded, false)
                assert_equal(failure,
                    "Track 1, item 1 (8.000000-14.000000 s) could not be split at 10.000000 s (C_LOCK=0).")
                assert_equal(delete_item_called, false)
                assert_equal(#markers, 1)
                assert_equal(#track.items, 2)
            end)
        end,
    },
    {
        name = "recent MIDI input pairs note events across a loop wrap",
        run = function()
            local fake = make_state_fake()
            local history = {
                { 4, string.char(0x90, 60, 90), 0, 1, 63.75, 2 },
                { 5, string.char(0x80, 60, 0), 0, 1, 0.25, 3 },
                { 6, string.char(0x90, 62, 90), 0, 1, 4, 3 },
                { 7, string.char(0x80, 62, 0), 0, 1, 5, 3 },
            }
            fake.MIDI_GetRecentInputEvent = function(index)
                local event = history[#history - index]
                if not event then return 0 end
                return table.unpack(event)
            end
            with_fake_reaper(fake, function()
                local events, newest = scenery.recent_midi_input_events_after(3)
                assert_equal(#events, 4)
                assert_equal(newest, 7)
                local wrapped = scenery.wrapped_midi_input_notes(events, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(#wrapped, 1)
                assert_equal(wrapped[1].device, 1)
                assert_equal(wrapped[1].channel, 0)
                assert_equal(wrapped[1].pitch, 60)
                assert_equal(wrapped[1].velocity, 90)
                assert_equal(wrapped[1].start_position, 63.75)
                assert_equal(wrapped[1].remaining_seconds, 0.25)
            end)
        end,
    },
    {
        name = "wrapped MIDI continuation is added to the most populated scene take",
        run = function()
            local fake = make_state_fake()
            local take1 = {
                is_midi = true,
                notes = {
                    { selected = false, muted = false, start_ppq = 6375, end_ppq = 6400,
                        channel = 0, pitch = 60, velocity = 90 },
                },
            }
            local take2 = {
                is_midi = true,
                notes = {
                    { selected = false, muted = false, start_ppq = 100, end_ppq = 150,
                        channel = 0, pitch = 62, velocity = 90 },
                    { selected = false, muted = false, start_ppq = 300, end_ppq = 350,
                        channel = 0, pitch = 64, velocity = 90 },
                },
            }
            local take3 = {
                is_midi = true,
                notes = {
                    { selected = false, muted = false, start_ppq = 0, end_ppq = 25,
                        channel = 0, pitch = 60, velocity = 90 },
                },
            }
            local item = {
                guid = "{wrap-body}", pos = 0, len = 64,
                takes = { take1, take2, take3 }, active_take = 3,
            }
            take1.item = item
            take2.item = item
            take3.item = item
            local track = { items = { item }, rec_input = 4096 + (1 << 5) }
            fake.CountTracks = function() return 1 end
            fake.GetTrack = function() return track end
            fake.CountTrackMediaItems = function(target) return #target.items end
            fake.GetTrackMediaItem = function(target, index) return target.items[index + 1] end
            fake.GetSetMediaItemInfo_String = function(target, key)
                if key == "GUID" then return true, target.guid end
            end
            fake.GetMediaItemInfo_Value = function(target, key)
                if key == "D_POSITION" then return target.pos end
                if key == "D_LENGTH" then return target.len end
            end
            fake.GetMediaTrackInfo_Value = function(target, key)
                if key == "I_RECINPUT" then return target.rec_input end
            end
            fake.CountTakes = function(target) return #target.takes end
            fake.GetTake = function(target, index) return target.takes[index + 1] end
            fake.GetActiveTake = function(target) return target.takes[target.active_take] end
            fake.TakeIsMIDI = function(target) return target and target.is_midi end
            fake.MIDI_GetProjTimeFromPPQPos = function(target, ppq)
                return target.item.pos + ppq / 100
            end
            fake.MIDI_CountEvts = function(target) return true, #target.notes, 0, 0 end
            fake.MIDI_GetNote = function(target, index)
                local note = target.notes[index + 1]
                if not note then return false end
                return true, note.selected, note.muted, note.start_ppq, note.end_ppq,
                    note.channel, note.pitch, note.velocity
            end
            fake.MIDI_GetPPQPosFromProjTime = function(target, time)
                return (time - target.item.pos) * 100
            end
            fake.MIDI_InsertNote = function(target, selected, muted, start_ppq, end_ppq,
                channel, pitch, velocity)
                target.notes[#target.notes + 1] = {
                    selected = selected,
                    muted = muted,
                    start_ppq = start_ppq,
                    end_ppq = end_ppq,
                    channel = channel,
                    pitch = pitch,
                    velocity = velocity,
                }
                return true
            end
            fake.MIDI_SetNote = function(target, index, _, _, _, end_ppq)
                target.notes[index + 1].end_ppq = end_ppq
                return true
            end
            fake.MIDI_Sort = function(target)
                table.sort(target.notes, function(left, right)
                    return left.start_ppq < right.start_ppq
                end)
            end
            with_fake_reaper(fake, function()
                local repaired = scenery.apply_wrapped_midi_notes_to_new_items({
                    ["{wrap-body}"] = true,
                }, {
                    pos = 0,
                    rgnend = 64,
                }, {
                    { device = 1, channel = 0, pitch = 60, velocity = 90,
                        start_position = 63.75, remaining_seconds = 0.25 },
                })
                assert_equal(repaired, 1)
                assert_equal(#take1.notes, 1)
                assert_equal(#take2.notes, 3)
                assert_equal(take2.notes[1].start_ppq, 0)
                assert_equal(take2.notes[1].end_ppq, 25)
                assert_equal(#take3.notes, 1)
            end)
        end,
    },
    {
        name = "clone copies envelope points and independent automation items by default",
        run = function()
            local fake, track = make_duplicate_fake(false)
            local envelope, unrelated_envelope = add_duplicate_automation(fake, track)
            with_fake_reaper(fake, function()
                assert_equal(scenery.get_config().copy_automation, true)
                scenery.duplicate_scene({ pos = 0, rgnend = 4 })

                local copied_points = {}
                for _, point in ipairs(envelope.points) do
                    copied_points[point.time] = point.value
                end
                assert_equal(copied_points[0], 0.1)
                assert_equal(copied_points[2], 0.5)
                assert_equal(copied_points[4], 0.1)
                assert_equal(copied_points[6], 0.5)
                assert_equal(copied_points[8], 0.1)
                assert_equal(copied_points[10], 0.5)
                assert_equal(copied_points[12], 0.2, "automation after the scene should remain")
                assert_equal(copied_points[5], nil, "destination automation should be overwritten")
                assert_equal(unrelated_envelope.points[1].time, 5,
                    "automation for a different parameter should remain")

                assert_equal(#envelope.items, 3)
                assert_equal(envelope.items[1].D_POSITION, 1)
                assert_equal(envelope.items[2].D_POSITION, 5)
                assert_equal(envelope.items[3].D_POSITION, 9)
                assert(envelope.items[2].D_POOL_ID ~= 7)
                assert(envelope.items[3].D_POOL_ID ~= 7)
                assert(envelope.items[2].D_POOL_ID ~= envelope.items[3].D_POOL_ID)
                assert_equal(#envelope.items[2].points, 2)
                assert_equal(envelope.items[2].points[1].time, 5)
                assert_equal(envelope.items[2].points[2].time, 5.5)
            end)
        end,
    },
    {
        name = "copy keeps automation-item pools linked and can be disabled",
        run = function()
            local fake, track = make_duplicate_fake(false)
            local envelope = add_duplicate_automation(fake, track)
            with_fake_reaper(fake, function()
                scenery.duplicate_scene({ pos = 0, rgnend = 4 }, scenery.copy_items_linked)
                assert_equal(#envelope.items, 3)
                assert_equal(envelope.items[2].D_POOL_ID, 7)
                assert_equal(envelope.items[3].D_POOL_ID, 7)
            end)

            local disabled_fake, disabled_track = make_duplicate_fake(false)
            local disabled_envelope = add_duplicate_automation(disabled_fake, disabled_track)
            disabled_fake.values[scenery.EXT_SECTION .. ":copy_automation"] = "0"
            with_fake_reaper(disabled_fake, function()
                assert_equal(scenery.get_config().copy_automation, false)
                scenery.duplicate_scene({ pos = 0, rgnend = 4 })
                assert_equal(#disabled_envelope.items, 2)
                assert_equal(disabled_envelope.points[3].value, 0.9)
            end)
        end,
    },
    {
        name = "insert-after clone shifts later automation with the timeline",
        run = function()
            local fake, track = make_duplicate_fake(false)
            local envelope = add_duplicate_automation(fake, track)
            fake.values[scenery.EXT_SECTION .. ":insert_after_current"] = "1"
            with_fake_reaper(fake, function()
                scenery.duplicate_scene({ pos = 0, rgnend = 4 })
                local points_by_time = {}
                for _, point in ipairs(envelope.points) do points_by_time[point.time] = point.value end
                assert_equal(points_by_time[4], 0.1)
                assert_equal(points_by_time[6], 0.5)
                assert_equal(points_by_time[13], 0.9)
                assert_equal(points_by_time[20], 0.2)
                assert_equal(envelope.items[2].D_POSITION, 13)
                assert_equal(envelope.items[3].D_POSITION, 5)
                assert_equal(envelope.items[4].D_POSITION, 9)
            end)
        end,
    },
    {
        name = "clone replaces destination items and trims lead-in overlap",
        run = function()
            local fake, track, lead_in, destination_item_before, destination_item = make_duplicate_fake(false)
            with_fake_reaper(fake, function()
                assert_equal(scenery.get_config().skip_occupied_tracks, false)
                scenery.duplicate_scene({ pos = 0, rgnend = 4 })
                assert_equal(lead_in.pos, -1)
                assert_equal(lead_in.len, 4)
                assert_equal(destination_item_before.pos, 2)
                assert_equal(destination_item_before.len, 2)
                assert_equal(destination_item.pos, 11)
                assert_equal(destination_item.len, 1)

                local copies = {}
                for _, item in ipairs(track.items) do
                    if item ~= lead_in and item ~= destination_item_before and item ~= destination_item then
                        if item.pos == 12 then
                            assert_equal(item.len, 1, "destination tail should remain outside the scene")
                        else
                            copies[#copies + 1] = item
                        end
                    end
                end
                assert_equal(#copies, 4)
                assert_equal(copies[1].pos, 4)
                assert_equal(copies[1].len, 3)
                assert_equal(copies[2].pos, 6)
                assert_equal(copies[3].pos, 8)
                assert_equal(copies[4].pos, 10)
            end)
        end,
    },
    {
        name = "insert-after copy does not leave lead-in copies in the source scene",
        run = function()
            local fake, track, lead_in, source_item, destination_item = make_duplicate_fake(false)
            fake.values[scenery.EXT_SECTION .. ":insert_after_current"] = "1"
            with_fake_reaper(fake, function()
                scenery.duplicate_scene({ pos = 0, rgnend = 4 })
                assert_equal(lead_in.pos, -1)
                assert_equal(lead_in.len, 4)
                assert_equal(source_item.pos, 2)
                assert_equal(source_item.len, 2)
                assert_equal(destination_item.pos, 19)

                local copies = 0
                for _, item in ipairs(track.items) do
                    if item ~= lead_in and item ~= source_item and item ~= destination_item then
                        assert(item.pos >= 4, "copied items must start inside the inserted scene")
                        copies = copies + 1
                    end
                end
                assert_equal(copies, 4)
            end)
        end,
    },
    {
        name = "skip occupied tracks leaves destination items and skips their copies",
        run = function()
            local fake, track, lead_in, destination_item_before, destination_item = make_duplicate_fake(true)
            with_fake_reaper(fake, function()
                assert_equal(scenery.get_config().skip_occupied_tracks, true)
                scenery.duplicate_scene({ pos = 0, rgnend = 4 })
                assert_equal(#track.items, 3)
                assert_equal(track.items[1], lead_in)
                assert_equal(track.items[2], destination_item_before)
                assert_equal(track.items[3], destination_item)
                assert_equal(destination_item_before.pos, 2)
                assert_equal(destination_item_before.len, 4)
                assert_equal(destination_item.pos, 11)
                assert_equal(destination_item.len, 2)
            end)
        end,
    },
    {
        name = "explicitly skipped tracks preserve destination items and skip copies",
        run = function()
            local fake, track, lead_in, destination_item_before, destination_item =
                make_duplicate_fake(false, false, "{track-1}")
            with_fake_reaper(fake, function()
                assert_equal(scenery.get_config().skip_occupied_tracks, false)
                scenery.duplicate_scene({ pos = 0, rgnend = 4 })
                assert_equal(#track.items, 3)
                assert_equal(track.items[1], lead_in)
                assert_equal(track.items[2], destination_item_before)
                assert_equal(track.items[3], destination_item)
                assert_equal(destination_item_before.len, 4)
                assert_equal(destination_item.len, 2)
            end)
        end,
    },
    {
        name = "clone preserves and crossfades audio lead-out overlap",
        run = function()
            local fake, track, _, _, _, audio_first, audio_leadout = make_duplicate_fake(false, true)
            with_fake_reaper(fake, function()
                scenery.duplicate_scene({ pos = 0, rgnend = 4 })
                assert_equal(audio_leadout.pos, 3)
                assert_equal(audio_leadout.len, 2)
                assert_equal(audio_leadout.fade_out, 1)

                local first_phrases = {}
                local leadout_copies = {}
                for _, item in ipairs(track.items) do
                    if item ~= audio_first and item ~= audio_leadout and item.take and not item.take.is_midi then
                        if item.pos == 4 or item.pos == 8 then
                            first_phrases[#first_phrases + 1] = item
                        elseif item.pos == 7 or item.pos == 11 then
                            leadout_copies[#leadout_copies + 1] = item
                        end
                    end
                end
                assert_equal(#first_phrases, 2)
                assert_equal(first_phrases[1].fade_in, 1)
                assert_equal(first_phrases[2].fade_in, 1)
                assert_equal(#leadout_copies, 2)
                assert_equal(leadout_copies[1].len, 2)
                assert_equal(leadout_copies[2].len, 2)
                assert_equal(leadout_copies[2].fade_out, 1)
            end)
        end,
    },
    {
        name = "quantized recording stop uses configured lead-out duration",
        run = function()
            local fake = make_state_fake()
            fake.GetPlayState = function() return 4 end
            fake.cursor_position = 4
            fake.GetCursorPosition = function() return fake.cursor_position end
            fake.values[scenery.EXT_SECTION .. ":engine_running"] = "1"
            fake.TimeMap2_timeToBeats = function(_, time)
                return 0, math.floor(time / 4), 0, time, 0
            end
            fake.TimeMap2_beatsToTime = function(_, _, measure) return measure * 4 end
            fake.TimeMap2_timeToQN = function(_, time) return time end
            fake.TimeMap2_QNToTime = function(_, quarter_note) return quarter_note end

            with_fake_reaper(fake, function()
                assert_equal(scenery.get_config().record_lead_out_bars, 0.5)
                local cfg = {
                    record_end_of_bar = true,
                    record_lead_out = false,
                    record_lead_out_bars = 0.5,
                    switch_wait_bars = 4,
                }
                scenery.toggle_record(cfg, "")
                assert_equal(tonumber(fake.values[scenery.EXT_SECTION .. ":pending_record_stop"]), 16.02)

                cfg.record_lead_out = true
                scenery.toggle_record(cfg, "")
                assert_equal(tonumber(fake.values[scenery.EXT_SECTION .. ":pending_record_stop"]), 18.02)

                cfg.record_lead_out_bars = 1
                scenery.toggle_record(cfg, "")
                assert_equal(tonumber(fake.values[scenery.EXT_SECTION .. ":pending_record_stop"]), 20.02)

                fake.cursor_position = 16
                cfg.record_lead_out = false
                scenery.toggle_record(cfg, "")
                assert_equal(tonumber(fake.values[scenery.EXT_SECTION .. ":pending_record_stop"]), 16.02)

                cfg.record_lead_out = true
                scenery.toggle_record(cfg, "")
                assert_equal(tonumber(fake.values[scenery.EXT_SECTION .. ":pending_record_stop"]), 20.02)
            end)
        end,
    },
    {
        name = "scene_name preserves labels and link suffix",
        run = function()
            assert_equal(scenery.scene_name("Verse", false), "Verse")
            assert_equal(scenery.scene_name("Verse", true), "Verse >>")
            assert_equal(scenery.scene_name("", true), " >>")
            assert_equal(scenery.scene_name(nil, false), "")
        end,
    },
    {
        name = "is_linked_to_next requires a true flag",
        run = function()
            assert_equal(scenery.is_linked_to_next({ linked = true }), true)
            assert_equal(scenery.is_linked_to_next({ linked = false }), false)
            assert_equal(scenery.is_linked_to_next({ linked = 1 }), false)
        end,
    },
    {
        name = "link_chain resolves from the head, middle, or tail",
        run = function()
            local first = make_scene(1, 0, 4, true)
            local second = make_scene(2, 4, 8, true)
            local third = make_scene(3, 8, 12, false)
            local scenes = { first, second, third }
            local from_middle = scenery.link_chain(second, scenes)
            local from_tail = scenery.link_chain(third, scenes)

            assert_equal(#from_middle, 3)
            assert_equal(from_middle[1], first)
            assert_equal(from_middle[2], second)
            assert_equal(from_middle[3], third)
            assert_equal(#from_tail, 3)
            assert_equal(from_tail[1], first)
            assert_equal(from_tail[3], third)
        end,
    },
    {
        name = "link_chain stops at unlinked neighbors and list edges",
        run = function()
            local first = make_scene(1, 0, 4, false)
            local second = make_scene(2, 4, 8, true)
            local third = make_scene(3, 8, 12, true)
            local scenes = { first, second, third }
            local chain = scenery.link_chain(second, scenes)

            assert_equal(#chain, 2)
            assert_equal(chain[1], second)
            assert_equal(chain[2], third)
            assert_equal(#scenery.link_chain(first, scenes), 1)
        end,
    },
    {
        name = "chain_bounds spans the complete linked chain",
        run = function()
            local first = make_scene(1, 2, 6, true)
            local second = make_scene(2, 6, 10, true)
            local third = make_scene(3, 10, 14, false)
            local start_time, end_time, chain = scenery.chain_bounds(second, {
                first,
                second,
                third,
            })

            assert_equal(start_time, 2)
            assert_equal(end_time, 14)
            assert_equal(#chain, 3)
        end,
    },
    {
        name = "scene_at uses inclusive starts and exclusive ends",
        run = function()
            local first = make_scene(1, 0, 4)
            local second = make_scene(2, 4, 8)
            local scenes = { first, second }

            assert_equal(scenery.scene_at(0, scenes), first)
            assert_equal(scenery.scene_at(4, scenes), second)
            assert_equal(scenery.scene_at(8, scenes), second)
            assert_equal(scenery.scene_at(-1, scenes), nil)
        end,
    },
    {
        name = "scene_at falls back to the latest prior scene in a gap",
        run = function()
            local first = make_scene(1, 0, 3)
            local second = make_scene(2, 5, 8)
            local scenes = { first, second }

            assert_equal(scenery.scene_at(4, scenes), first)
            assert_equal(scenery.scene_at(9, scenes), second)
        end,
    },
    {
        name = "scan_scenes sorts regions and puts longest equal-start region first",
        run = function()
            local fake = make_state_fake()
            local markers = {
                { true, 20, 24, "Later", 13, 0 },
                { false, 2, 2, "Marker", 14, 0 },
                { true, 0, 4, "Inner", 15, 0 },
                { true, 0, 8, "Outer >>", 16, 0 },
            }
            fake.EnumProjectMarkers3 = function(_, index)
                local marker = markers[index + 1]
                if not marker then return 0 end
                return 1, marker[1], marker[2], marker[3], marker[4], marker[5], marker[6]
            end

            with_fake_reaper(fake, function()
                local scenes = scenery.scan_scenes()
                assert_equal(#scenes, 3)
                assert_equal(scenes[1].id, 16)
                assert_equal(scenes[1].label, "Outer")
                assert_equal(scenes[1].linked, true)
                assert_equal(scenes[1].num, 1)
                assert_equal(scenes[2].id, 15)
                assert_equal(scenes[2].num, 2)
                assert_equal(scenes[3].id, 13)
                assert_equal(scenes[3].num, 3)
            end)
        end,
    },
    {
        name = "active_scene prefers remembered ID while cursor remains in range",
        run = function()
            local fake = make_state_fake()
            fake.play_state = 1
            fake.play_position = 2
            fake.GetPlayState = function() return fake.play_state end
            fake.GetPlayPosition = function() return fake.play_position end
            fake.GetCursorPosition = function() return 0 end
            fake.values[scenery.EXT_SECTION .. ":active_id"] = "22"
            local outer = make_scene(1, 0, 8, false, "Outer")
            outer.id = 21
            local inner = make_scene(2, 0, 4, false, "Inner")
            inner.id = 22

            with_fake_reaper(fake, function()
                assert_equal(scenery.active_scene({ outer, inner }), inner)
            end)
        end,
    },
    {
        name = "active_scene falls back to position after remembered range ends",
        run = function()
            local fake = make_state_fake()
            fake.play_state = 1
            fake.play_position = 5
            fake.GetPlayState = function() return fake.play_state end
            fake.GetPlayPosition = function() return fake.play_position end
            fake.GetCursorPosition = function() return 0 end
            fake.values[scenery.EXT_SECTION .. ":active_id"] = "22"
            fake.values[scenery.EXT_SECTION .. ":active_start"] = "0"
            fake.values[scenery.EXT_SECTION .. ":active_end"] = "4"
            local outer = make_scene(1, 0, 8, false, "Outer")
            outer.id = 21
            local inner = make_scene(2, 0, 4, false, "Inner")
            inner.id = 22

            with_fake_reaper(fake, function()
                assert_equal(scenery.active_scene({ outer, inner }), outer)
            end)
        end,
    },
    {
        name = "record back-fill tiles a mid-scene loop to the scene start",
        run = function()
            local fake = make_state_fake()
            fake.values[scenery.EXT_SECTION .. ":record_backfill"] = "1"
            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "1"
            fake.values[scenery.EXT_SECTION .. ":record_lead_out"] = "1"
            fake.values[scenery.EXT_SECTION .. ":switch_wait_bars"] = "4"
            local fail_split_at = nil
            local track = { items = {} }
            local item = { guid = "{recorded}", pos = 12, len = 20 }
            track.items[1] = item
            fake.CountTracks = function() return 1 end
            fake.GetTrack = function() return track end
            fake.CountTrackMediaItems = function(target) return #target.items end
            fake.GetTrackMediaItem = function(target, index) return target.items[index + 1] end
            fake.GetSetMediaItemInfo_String = function(target, key)
                if key == "GUID" then return true, target.guid end
            end
            fake.GetMediaItemInfo_Value = function(target, key)
                if key == "D_POSITION" then return target.pos end
                if key == "D_LENGTH" then return target.len end
                if key == "D_SNAPOFFSET" then return target.snap_offset or 0 end
            end
            fake.TimeMap2_timeToBeats = function(_, time)
                return 0, math.floor(time / 4), 0, time, 0
            end
            fake.TimeMap2_beatsToTime = function(_, _, measure) return measure * 4 end
            fake.TimeMap2_timeToQN = function(_, time) return time end
            fake.TimeMap2_QNToTime = function(_, quarter_note) return quarter_note end
            fake.GetItemStateChunk = function(target)
                local chunk = string.format("ITEM\nPOSITION %.17g\nLENGTH %.17g\n", target.pos, target.len)
                if target.take and target.take.is_midi then
                    chunk = chunk .. "MIDI 1\n"
                    for _, note in ipairs(target.take.notes or {}) do
                        chunk = chunk .. string.format("NOTE %d %d %.17g %.17g %d %d %d\n",
                            note.selected and 1 or 0, note.muted and 1 or 0,
                            note.start_ppq, note.end_ppq, note.channel, note.pitch, note.velocity)
                    end
                end
                return true, chunk
            end
            fake.AddMediaItemToTrack = function(target)
                local tile = { pos = 0, len = 20, chunk = "" }
                target.items[#target.items + 1] = tile
                return tile
            end
            fake.SplitMediaItem = function(target, split_pos)
                if fail_split_at == split_pos then return nil end
                local right = {
                    pos = split_pos,
                    len = target.pos + target.len - split_pos,
                }
                if target.take then
                    right.take = { is_midi = target.take.is_midi, notes = {} }
                    right.take.item = right
                    local offset = (split_pos - target.pos) * 100
                    local left_notes = {}
                    for _, note in ipairs(target.take.notes or {}) do
                        if note.start_ppq < offset then
                            left_notes[#left_notes + 1] = {
                                selected = note.selected, muted = note.muted,
                                start_ppq = note.start_ppq,
                                end_ppq = math.min(note.end_ppq, offset),
                                channel = note.channel, pitch = note.pitch,
                                velocity = note.velocity,
                            }
                        end
                        if note.end_ppq > offset then
                            right.take.notes[#right.take.notes + 1] = {
                                selected = note.selected, muted = note.muted,
                                start_ppq = math.max(0, note.start_ppq - offset),
                                end_ppq = note.end_ppq - offset,
                                channel = note.channel, pitch = note.pitch,
                                velocity = note.velocity,
                            }
                        end
                    end
                    target.take.notes = left_notes
                end
                target.len = split_pos - target.pos
                track.items[#track.items + 1] = right
                return right
            end
            fake.DeleteTrackMediaItem = function(target, item_to_delete)
                for index, candidate in ipairs(target.items) do
                    if candidate == item_to_delete then
                        table.remove(target.items, index)
                        return
                    end
                end
            end
            fake.SetItemStateChunk = function(target, chunk)
                target.pos = tonumber(chunk:match("POSITION ([^\n]+)")) or target.pos
                target.len = tonumber(chunk:match("LENGTH ([^\n]+)")) or target.len
                if chunk:match("\nMIDI 1\n") then
                    target.take = { is_midi = true, notes = {} }
                    target.take.item = target
                    for note_data in chunk:gmatch("NOTE ([^\n]+)") do
                        local selected, muted, start_ppq, end_ppq, channel, pitch, velocity =
                            note_data:match("^(%d+) (%d+) (%S+) (%S+) (%d+) (%d+) (%d+)$")
                        target.take.notes[#target.take.notes + 1] = {
                            selected = selected == "1",
                            muted = muted == "1",
                            start_ppq = tonumber(start_ppq),
                            end_ppq = tonumber(end_ppq),
                            channel = tonumber(channel),
                            pitch = tonumber(pitch),
                            velocity = tonumber(velocity),
                        }
                    end
                end
                return true
            end
            fake.SetMediaItemInfo_Value = function(target, key, value)
                if key == "D_POSITION" then target.pos = value end
                if key == "D_SNAPOFFSET" then target.snap_offset = value end
            end
            fake.GetActiveTake = function(target) return target.take end
            fake.CountTakes = function() return 0 end
            fake.SetMediaItemLength = function(target, length) target.len = length end
            fake.UpdateItemInProject = function() end
            fake.CountMediaItems = function() return #track.items end
            fake.GetMediaItem = function(_, index) return track.items[index + 1] end
            fake.IsMediaItemSelected = function(target) return target.selected == true end
            fake.SelectAllMediaItems = function(_, selected)
                for _, candidate in ipairs(track.items) do candidate.selected = selected end
            end
            fake.SetMediaItemSelected = function(target, selected) target.selected = selected end
            fake.CountSelectedMediaItems = function()
                local count = 0
                for _, candidate in ipairs(track.items) do
                    if candidate.selected then count = count + 1 end
                end
                return count
            end
            fake.GetSelectedMediaItem = function(_, index)
                local selected = {}
                for _, candidate in ipairs(track.items) do
                    if candidate.selected then selected[#selected + 1] = candidate end
                end
                return selected[index + 1]
            end
            local perform_glue = true
            fake.Main_OnCommand = function(command_id)
                assert_equal(command_id, 40362)
                if not perform_glue then return end
                local start_pos, end_pos = math.huge, -math.huge
                local source_notes = {}
                local has_midi_take = false
                for _, candidate in ipairs(track.items) do
                    if candidate.selected then
                        start_pos = math.min(start_pos, candidate.pos)
                        end_pos = math.max(end_pos, candidate.pos + candidate.len)
                        if candidate.take and candidate.take.is_midi then
                            has_midi_take = true
                            for _, note in ipairs(candidate.take.notes or {}) do
                                local note_start = candidate.pos + note.start_ppq / 100
                                local note_end = candidate.pos + note.end_ppq / 100
                                source_notes[#source_notes + 1] = {
                                    selected = note.selected,
                                    muted = note.muted,
                                    channel = note.channel,
                                    pitch = note.pitch,
                                    velocity = note.velocity,
                                    project_start = note_start,
                                    project_end = note_end,
                                }
                            end
                        end
                    end
                end
                for index = #track.items, 1, -1 do
                    if track.items[index].selected then table.remove(track.items, index) end
                end
                local glued_item = {
                    pos = start_pos,
                    len = end_pos - start_pos,
                    selected = true,
                }
                if has_midi_take then
                    local merged_notes = {}
                    for _, note in ipairs(source_notes) do
                        merged_notes[#merged_notes + 1] = {
                            selected = note.selected,
                            muted = note.muted,
                            start_ppq = (note.project_start - start_pos) * 100,
                            end_ppq = (note.project_end - start_pos) * 100,
                            channel = note.channel,
                            pitch = note.pitch,
                            velocity = note.velocity,
                            project_start = note.project_start,
                            project_end = note.project_end,
                        }
                    end
                    glued_item.take = { is_midi = true, notes = merged_notes }
                    glued_item.take.item = glued_item
                end
                track.items[#track.items + 1] = glued_item
            end

            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[1].snap_offset, 4)
                assert_equal(track.items[2].pos, 0)
                assert_equal(track.items[2].len, 16)
                assert_equal(track.items[2].snap_offset, 0)
                assert_equal(track.items[3].pos, 28)
                assert_equal(track.items[3].snap_offset, 4)
                assert_equal(track.items[4].pos, 44)
                assert_equal(track.items[4].snap_offset, 4)
                track.items = { item }
                fail_split_at = 4
                processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 4,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[2].pos, -4)
                assert_equal(track.items[2].len, 20)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "0"
            fake.values[scenery.EXT_SECTION .. ":record_lead_out"] = "0"
            track.items = { item }
            item.pos = 16
            item.len = 16
            fail_split_at = nil
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[2].pos, 0)
                assert_equal(track.items[2].len, 16)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_backfill"] = "0"
            local item_at_scene_start = { guid = "{phrase-alignment}", pos = 8, len = 24 }
            track.items = { item_at_scene_start }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 8,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 3)
                assert_equal(track.items[1].pos, 16)
                assert_equal(track.items[1].len, 16)
                assert_equal(track.items[2].pos, 32)
                assert_equal(track.items[3].pos, 48)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_auto_loop"] = "1"
            fake.values[scenery.EXT_SECTION .. ":record_end_of_bar"] = "0"
            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "0"
            local wrapped_recording = { guid = "{wrapped-recording}", pos = 60, len = 20 }
            track.items = { wrapped_recording }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[1].pos, 0)
                assert_equal(track.items[1].len, 16)
                assert_equal(track.items[2].pos, 16)
                assert_equal(track.items[3].pos, 32)
                assert_equal(track.items[4].pos, 48)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "1"
            wrapped_recording = { guid = "{wrapped-recording-lead-in}", pos = 60, len = 20 }
            track.items = { wrapped_recording }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[1].pos, -4)
                assert_equal(track.items[1].len, 20)
                assert_equal(track.items[1].pos + 4, 0)
                assert_equal(track.items[2].pos, 12)
                assert_equal(track.items[2].pos + 4, 16)
                assert_equal(track.items[3].pos, 28)
                assert_equal(track.items[3].pos + 4, 32)
                assert_equal(track.items[4].pos, 44)
                assert_equal(track.items[4].pos + 4, 48)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "0"
            local wrapped_body = { guid = "{wrapped-body}", pos = 0, len = 16 }
            local wrapped_tail = { guid = "{wrapped-tail}", pos = 60, len = 4 }
            track.items = { wrapped_body, wrapped_tail }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[1].pos, 0)
                assert_equal(track.items[1].len, 16)
                assert_equal(track.items[2].pos, 16)
                assert_equal(track.items[3].pos, 32)
                assert_equal(track.items[4].pos, 48)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "1"
            wrapped_body = { guid = "{wrapped-body-lead-in}", pos = 0, len = 16 }
            wrapped_tail = { guid = "{wrapped-tail-lead-in}", pos = 60, len = 4 }
            track.items = { wrapped_body, wrapped_tail }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[1].pos, -4)
                assert_equal(track.items[1].len, 20)
                assert_equal(track.items[1].pos + 4, 0)
                assert_equal(track.items[2].pos, 12)
                assert_equal(track.items[2].pos + 4, 16)
                assert_equal(track.items[3].pos, 28)
                assert_equal(track.items[3].pos + 4, 32)
                assert_equal(track.items[4].pos, 44)
                assert_equal(track.items[4].pos + 4, 48)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_end_of_bar"] = "1"
            local long_recording = { guid = "{long-recording}", pos = 0, len = 32 }
            track.items = { long_recording }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 2)
                for index, expected_pos in ipairs({ 0, 32 }) do
                    assert_equal(track.items[index].pos, expected_pos)
                    assert_equal(track.items[index].len, 32)
                end
            end)

            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "1"
            fake.values[scenery.EXT_SECTION .. ":record_lead_out"] = "1"
            local leadout_recording = {
                guid = "{leadout-recording}",
                pos = 8,
                len = 44,
                take = { is_midi = true },
            }
            track.items = { leadout_recording }
            perform_glue = false
            fake.TakeIsMIDI = function(take) return take and take.is_midi end
            fake.MIDI_CountEvts = function(take) return true, #(take.notes or {}), 0, 0 end
            fake.MIDI_GetNote = function(take, index)
                local note = take.notes[index + 1]
                if not note then return false end
                return true, note.selected, note.muted, note.start_ppq, note.end_ppq,
                    note.channel, note.pitch, note.velocity
            end
            fake.MIDI_GetPPQPosFromProjTime = function(take, time)
                return (time - take.item.pos) * 100
            end
            fake.MIDI_GetProjTimeFromPPQPos = function(take, ppq)
                return take.item.pos + ppq / 100
            end
            fake.MIDI_InsertNote = function(take, selected, muted, start_ppq, end_ppq,
                channel, pitch, velocity)
                take.notes[#take.notes + 1] = {
                    selected = selected,
                    muted = muted,
                    start_ppq = start_ppq,
                    end_ppq = end_ppq,
                    channel = channel,
                    pitch = pitch,
                    velocity = velocity,
                }
                return true
            end
            fake.MIDI_SetNote = function(take, index, _, _, _, end_ppq)
                take.notes[index + 1].end_ppq = end_ppq
                return true
            end
            fake.MIDI_DeleteNote = function(take, index)
                table.remove(take.notes, index + 1)
                return true
            end
            fake.MIDI_Sort = function(take)
                table.sort(take.notes, function(left, right)
                    return left.start_ppq < right.start_ppq
                end)
            end
            local extent_updates = 0
            fake.MIDI_SetItemExtents = function(target, start_qn, end_qn)
                extent_updates = extent_updates + 1
                target.len = end_qn - start_qn
            end
            fake.ValidatePtr2 = function() return true end
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 8,
                    rgnend = 80,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 2)
                assert_equal(track.items[1].pos, 8)
                assert_equal(track.items[1].len, 44)
                assert_equal(track.items[2].pos, 40)
                assert_equal(track.items[2].len, 44)
                assert_equal(track.items[2].pos - track.items[1].pos, 32)
            end)

            local full_scene_recording = { guid = "{full-scene-leadout}", pos = 0, len = 32 }
            track.items = { full_scene_recording }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 32,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 1)
                assert_equal(track.items[1].pos, 0)
                assert_equal(track.items[1].len, 32)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "0"
            fake.values[scenery.EXT_SECTION .. ":record_lead_out"] = "0"
            fake.values[scenery.EXT_SECTION .. ":record_end_of_bar"] = "0"
            local body_take = { is_midi = true, notes = {} }
            local midi_body = { guid = "{midi-body}", pos = 0, len = 16, take = body_take }
            body_take.item = midi_body
            local tail_take = {
                is_midi = true,
                notes = {
                    { selected = false, muted = false, start_ppq = 200, end_ppq = 400,
                        channel = 0, pitch = 60, velocity = 100 },
                    { selected = false, muted = false, start_ppq = 100, end_ppq = 300,
                        channel = 0, pitch = 62, velocity = 100 },
                },
            }
            local midi_tail = { guid = "{midi-tail}", pos = 60, len = 4, take = tail_take }
            tail_take.item = midi_tail
            track.items = { midi_body, midi_tail }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(#midi_body.take.notes, 1)
                assert_equal(midi_body.take.notes[1].start_ppq, 0)
                assert_equal(midi_body.take.notes[1].end_ppq, 200)
                assert_equal(midi_body.take.notes[1].pitch, 60)
                for index = 2, 4 do
                    assert_equal(#track.items[index].take.notes, 1)
                    assert_equal(track.items[index].take.notes[1].start_ppq, 0)
                    assert_equal(track.items[index].take.notes[1].end_ppq, 200)
                end
            end)

            fake.values[scenery.EXT_SECTION .. ":record_backfill"] = "1"
            local crossing_take = {
                is_midi = true,
                notes = {
                    { selected = false, muted = false, start_ppq = 300, end_ppq = 500,
                        channel = 0, pitch = 64, velocity = 100 },
                    { selected = false, muted = false, start_ppq = 600, end_ppq = 700,
                        channel = 0, pitch = 67, velocity = 100 },
                },
            }
            local crossing_item = {
                guid = "{phrase-boundary-note}", pos = 12, len = 20, take = crossing_take,
            }
            local empty_wrap_take = { is_midi = true, notes = {} }
            local empty_wrap_item = {
                guid = "{empty-wrap-fragment}", pos = 0, len = 0.044, take = empty_wrap_take,
            }
            crossing_take.item = crossing_item
            empty_wrap_take.item = empty_wrap_item
            track.items = { empty_wrap_item, crossing_item }
            local updates_before_crossing = extent_updates
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 32,
                })
                assert_equal(processed, 1)
                assert_equal(extent_updates, updates_before_crossing)
                assert_equal(#track.items, 2)
                assert_equal(empty_wrap_item.len, 0.044)
                assert_equal(track.items[1].pos, 16)
                assert_equal(#track.items[1].take.notes, 2)
                assert_equal(track.items[1].take.notes[1].start_ppq, 0)
                assert_equal(track.items[1].take.notes[1].end_ppq, 100)
                assert_equal(track.items[1].take.notes[2].start_ppq, 200)
                assert_equal(track.items[2].pos, 0)
                assert_equal(#track.items[2].take.notes, 2)
                assert_equal(track.items[2].take.notes[1].start_ppq, 0)
                assert_equal(track.items[2].take.notes[1].end_ppq, 100)
                assert_equal(track.items[2].take.notes[2].start_ppq, 200)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_backfill"] = "1"
            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "1"
            fake.values[scenery.EXT_SECTION .. ":record_lead_out"] = "1"
            local phrase_tail_take = {
                is_midi = true,
                notes = {
                    { selected = false, muted = false, start_ppq = 1900, end_ppq = 2100,
                        channel = 0, pitch = 65, velocity = 100 },
                },
            }
            local phrase_tail_item = {
                guid = "{phrase-tail-note}", pos = 12, len = 20, take = phrase_tail_take,
            }
            phrase_tail_take.item = phrase_tail_item
            track.items = { phrase_tail_item }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[2].pos, 0)
                assert_equal(track.items[2].len, 17)
                assert_equal(#track.items[2].take.notes, 1)
                assert_equal(track.items[2].take.notes[1].end_ppq, 1700)
                assert_equal(track.items[3].pos, 28)
                assert_equal(track.items[3].len, 21)
                assert_equal(track.items[3].take.notes[1].end_ppq, 2100)
                assert_equal(track.items[4].pos, 44)
                assert_equal(track.items[4].len, 21)
                assert_equal(track.items[4].take.notes[1].end_ppq, 2100)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_end_of_bar"] = "0"
            local crossing_phrase_take = {
                is_midi = true,
                notes = {
                    { selected = false, muted = false, start_ppq = 1150, end_ppq = 2850,
                        channel = 0, pitch = 65, velocity = 100 },
                },
            }
            local crossing_phrase_item = {
                guid = "{backfill-note-crosses-both-boundaries}",
                pos = 20,
                len = 30,
                take = crossing_phrase_take,
            }
            crossing_phrase_take.item = crossing_phrase_item
            track.items = { crossing_phrase_item }
            perform_glue = true
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 1)
                assert_equal(track.items[1].pos, 0)
                local crossing_note_found = false
                for _, note in ipairs(track.items[1].take.notes) do
                    local note_start = track.items[1].pos + note.start_ppq / 100
                    local note_end = track.items[1].pos + note.end_ppq / 100
                    if math.abs(note_start) < 1e-9
                        and math.abs(note_end - 64.5) < 1e-9 then
                        crossing_note_found = true
                    end
                end
                assert_equal(crossing_note_found, true)
            end)

            fake.values[scenery.EXT_SECTION .. ":record_backfill"] = "0"
            fake.values[scenery.EXT_SECTION .. ":record_lead_in"] = "0"
            fake.values[scenery.EXT_SECTION .. ":record_lead_out"] = "0"
            local two_bar_audio = { guid = "{two-bar-audio}", pos = 0, len = 8 }
            track.items = { two_bar_audio }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 32,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                for index, expected_pos in ipairs({ 0, 8, 16, 24 }) do
                    assert_equal(track.items[index].pos, expected_pos)
                    assert_equal(track.items[index].len, 8)
                end
            end)

            two_bar_audio = { guid = "{quantized-start-two-bar-audio}", pos = 4, len = 20 }
            track.items = { two_bar_audio }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 48,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                for index, expected_pos in ipairs({ 16, 24, 32, 40 }) do
                    assert_equal(track.items[index].pos, expected_pos)
                    assert_equal(track.items[index].len, 8)
                end
            end)

            fake.values[scenery.EXT_SECTION .. ":record_lead_out"] = "1"
            two_bar_audio = { guid = "{two-bar-audio-lead-out}", pos = 0, len = 10 }
            track.items = { two_bar_audio }
            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 32,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                for index, expected_pos in ipairs({ 0, 8, 16, 24 }) do
                    assert_equal(track.items[index].pos, expected_pos)
                    assert_equal(track.items[index].len, 10)
                end
            end)
        end,
    },
    {
        name = "full-scene recording activates the take before the final take",
        run = function()
            local fake = make_state_fake()
            local track = {}
            local takes = {
                { is_midi = true, notes = 0 },
                { is_midi = true, notes = 2 },
                { is_midi = true, notes = 0 },
            }
            local item = {
                guid = "{new-item}",
                pos = 0,
                len = 4,
                takes = takes,
                active_take = takes[3],
                loop_source = 1,
            }
            fake.CountTracks = function() return 1 end
            fake.GetTrack = function() return track end
            fake.CountTrackMediaItems = function() return 1 end
            fake.GetTrackMediaItem = function() return item end
            fake.CountMediaItems = function() return 1 end
            fake.GetMediaItem = function() return item end
            fake.IsMediaItemSelected = function(target) return target.selected == true end
            fake.SelectAllMediaItems = function(_, selected)
                item.selected = selected
            end
            fake.SetMediaItemSelected = function(target, selected)
                target.selected = selected
            end
            fake.ValidatePtr2 = function() return true end
            fake.GetSetMediaItemInfo_String = function(_, key)
                if key == "GUID" then return true, item.guid end
            end
            fake.GetMediaItemInfo_Value = function(_, key)
                if key == "D_POSITION" then return item.pos end
                if key == "D_LENGTH" then return item.len end
            end
            fake.CountTakes = function(target) return #target.takes end
            fake.GetTake = function(target, index) return target.takes[index + 1] end
            fake.TakeIsMIDI = function(take) return take.is_midi end
            fake.MIDI_CountEvts = function(take)
                return true, take.notes or 0, take.cc or 0, take.text or 0
            end
            fake.MIDI_GetNote = function() return false end
            fake.SetActiveTake = function(take) item.active_take = take end
            fake.DeleteTake = function(take)
                for index, candidate in ipairs(item.takes) do
                    if candidate == take then
                        table.remove(item.takes, index)
                        return
                    end
                end
            end
            fake.Main_OnCommand = function(command_id)
                assert_equal(command_id, 40129)
                fake.DeleteTake(item.active_take)
            end
            fake.GetActiveTake = function(target) return target.active_take end
            fake.TimeMap2_timeToBeats = function(_, time)
                return 0, math.floor(time / 4), 0, time, 0
            end
            fake.TimeMap2_beatsToTime = function(_, _, measure) return measure * 4 end
            fake.TimeMap2_timeToQN = function(_, time) return time end
            fake.TimeMap2_QNToTime = function(_, quarter_note) return quarter_note end
            local loop_source_updates = 0
            local extent_updates = 0
            fake.SetMediaItemInfo_Value = function(target, key, value)
                if key == "B_LOOPSRC" then
                    target.loop_source = value
                    loop_source_updates = loop_source_updates + 1
                end
            end
            fake.MIDI_SetItemExtents = function()
                assert_equal(item.loop_source, 0, "MIDI loop source should be disabled before extending")
                extent_updates = extent_updates + 1
            end
            fake.UpdateItemInProject = function() end
            fake.SetMediaItemLength = function(target, length) target.len = length end
            fake.SplitMediaItem = function() return nil end

            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 4,
                })
                assert_equal(processed, 1)
                assert_equal(item.active_take, takes[2])
                assert_equal(#item.takes, 2)
                assert_equal(item.len, 4)
                assert_equal(item.loop_source, 1)
                assert_equal(loop_source_updates, 0)
                assert_equal(extent_updates, 0)

                local nonempty_final_takes = {
                    { is_midi = true, notes = 0 },
                    { is_midi = true, notes = 2 },
                    { is_midi = true, notes = 1 },
                }
                item.takes = nonempty_final_takes
                item.active_take = nonempty_final_takes[3]
                processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 4,
                })
                assert_equal(processed, 1)
                assert_equal(item.active_take, nonempty_final_takes[2])
                assert_equal(#item.takes, 3)

                item.len = 8
                item.active_take = nonempty_final_takes[3]
                processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 4,
                })
                assert_equal(processed, 1)
                assert_equal(item.active_take, nonempty_final_takes[2])
                assert_equal(extent_updates, 0)

                local two_takes = {
                    { is_midi = true, notes = 2 },
                    { is_midi = true, notes = 0 },
                }
                item.len = 4
                item.takes = two_takes
                item.active_take = two_takes[2]
                processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 4,
                })
                assert_equal(processed, 1)
                assert_equal(item.active_take, two_takes[1])
                assert_equal(#item.takes, 1)

                local audio_takes = {
                    { is_midi = false },
                    { is_midi = false },
                }
                item.takes = audio_takes
                item.active_take = audio_takes[2]
                processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 4,
                })
                assert_equal(processed, 1)
                assert_equal(item.active_take, audio_takes[1])
                assert_equal(#item.takes, 2)

                fake.values[scenery.EXT_SECTION .. ":record_lead_out"] = "1"
                item.len = 6
                item.active_take = audio_takes[2]
                processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 4,
                })
                assert_equal(processed, 1)
                assert_equal(item.active_take, audio_takes[1])
                assert_equal(item.len, 6)
            end)
        end,
    },
}

for _, test_case in ipairs(tests) do
    local ok, error_message = xpcall(test_case.run, debug.traceback)
    if ok then
        passed = passed + 1
        print("PASS " .. test_case.name)
    else
        failed = failed + 1
        io.stderr:write("FAIL " .. test_case.name .. "\n" .. error_message .. "\n")
    end
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end