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

local next_poll = 0
local last_play_pos = -1

-- A queued scene takes over at the bar line the launcher recorded, or on loop wrap.
local function service_queue()
    local q = L.get_queue()
    if not q then
        last_play_pos = -1
        return false
    end
    if not L.is_playing() then
        L.fire_queue(q)
        return true
    end
    -- GetPlayPosition2 tracks the engine's next-block position rather than the
    -- latency-delayed audible position, so the fire lands on the bar instead of after it.
    local pos = reaper.GetPlayPosition2()
    local wrapped = last_play_pos >= 0 and pos < last_play_pos - 1e-6
    last_play_pos = pos
    if pos >= q.fire - 1e-6 or wrapped then
        L.fire_queue(q)
        last_scene_pos = q.pos
    end
    return true
end

local function follow()
    local cfg = L.get_config()
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
        if not service_queue() then follow() end
    end
    reaper.defer(loop)
end

reaper.atexit(function()
    reaper.SetExtState(L.EXT_SECTION, "engine_running", "0", false)
    L.clear_pending()
    L.clear_queue()
    reaper.SetToggleCommandState(section_id, cmd_id, 0)
    reaper.RefreshToolbar2(section_id, cmd_id)
end)

loop()
