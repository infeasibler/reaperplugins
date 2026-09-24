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

local tests = {
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