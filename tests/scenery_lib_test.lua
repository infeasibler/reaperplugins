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
        DeleteExtState = function(section, key)
            values[section .. ":" .. key] = nil
        end,
    }
end

local function make_duplicate_fake(skip_occupied_tracks, with_audio_leadout)
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
    if skip_occupied_tracks then
        fake.values[scenery.EXT_SECTION .. ":skip_occupied_tracks"] = "1"
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

local tests = {
    {
        name = "clone replaces destination items and copies lead-in overlap by default",
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
                assert_equal(copies[1].pos, 3)
                assert_equal(copies[2].pos, 6)
                assert_equal(copies[3].pos, 7)
                assert_equal(copies[4].pos, 10)
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
        name = "quantized recording stop adds a bar only for lead-out",
        run = function()
            local fake = make_state_fake()
            fake.GetPlayState = function() return 4 end
            fake.GetCursorPosition = function() return 4 end
            fake.values[scenery.EXT_SECTION .. ":engine_running"] = "1"
            fake.TimeMap2_timeToBeats = function(_, time)
                return 0, math.floor(time / 4), 0, time, 0
            end
            fake.TimeMap2_beatsToTime = function(_, _, measure) return measure * 4 end

            with_fake_reaper(fake, function()
                local cfg = {
                    record_end_of_bar = true,
                    record_lead_out = false,
                    switch_wait_bars = 4,
                }
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
            end
            fake.TimeMap2_timeToBeats = function(_, time)
                return 0, math.floor(time / 4), 0, time, 0
            end
            fake.TimeMap2_beatsToTime = function(_, _, measure) return measure * 4 end
            fake.TimeMap2_timeToQN = function(_, time) return time end
            fake.TimeMap2_QNToTime = function(_, quarter_note) return quarter_note end
            fake.GetItemStateChunk = function(target)
                return true, string.format("ITEM\nPOSITION %.17g\nLENGTH %.17g\n", target.pos, target.len)
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
                return true
            end
            fake.SetMediaItemInfo_Value = function(target, key, value)
                if key == "D_POSITION" then target.pos = value end
            end
            fake.GetActiveTake = function() return nil end
            fake.SetMediaItemLength = function(target, length) target.len = length end
            fake.UpdateItemInProject = function() end

            with_fake_reaper(fake, function()
                local processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 0,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[2].pos, 0)
                assert_equal(track.items[2].len, 16)
                assert_equal(track.items[3].pos, 28)
                assert_equal(track.items[4].pos, 44)

                track.items = { item }
                fail_split_at = 4
                processed = scenery.apply_loop_source_to_new_items({}, {
                    pos = 4,
                    rgnend = 64,
                })
                assert_equal(processed, 1)
                assert_equal(#track.items, 4)
                assert_equal(track.items[2].pos, 0)
                assert_equal(track.items[2].len, 16)
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
            fake.GetActiveTake = function(target) return target.take end
            fake.TakeIsMIDI = function(take) return take and take.is_midi end
            fake.MIDI_CountEvts = function() return true, 0, 0, 0 end
            fake.MIDI_SetItemExtents = function(target, start_qn, end_qn)
                target.len = end_qn - start_qn
            end
            fake.CountMediaItems = function() return #track.items end
            fake.GetMediaItem = function(_, index) return track.items[index + 1] end
            fake.IsMediaItemSelected = function(target) return target.selected == true end
            fake.SelectAllMediaItems = function(_, selected)
                for _, candidate in ipairs(track.items) do candidate.selected = selected end
            end
            fake.SetMediaItemSelected = function(target, selected) target.selected = selected end
            fake.Main_OnCommand = function(command_id) assert_equal(command_id, 40362) end
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
        end,
    },
    {
        name = "full-scene MIDI recording activates the take before the final take",
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
                assert_equal(extent_updates, 1)

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