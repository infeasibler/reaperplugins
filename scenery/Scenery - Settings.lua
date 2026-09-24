-- @noindex
-- Scenery: Settings
-- Edits the persistent Scenery preferences (shared by all Scenery actions).

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local cfg = L.get_config()
local defaults = table.concat({
    cfg.default_bars,
    string.format("%d,%d,%d", cfg.color_r, cfg.color_g, cfg.color_b),
    cfg.follow_enabled and "1" or "0",
    cfg.record_auto_loop and "1" or "0",
    cfg.record_lead_in and "1" or "0",
    cfg.record_lead_out and "1" or "0",
    cfg.record_end_of_bar and "1" or "0",
    cfg.wait_for_scene_end and "1" or "0",
    cfg.switch_wait_bars,
    cfg.skip_occupied_tracks and "1" or "0",
    cfg.auto_repeat and "1" or "0",
    cfg.insert_after_current and "1" or "0",
}, ",")

local ok, input = reaper.GetUserInputs(
    "Scenery - Settings", 12,
    "Default scene length (bars):,Region colour (r,g,b):,Engine auto-follow (1/0):,Record auto-loop (1/0):," ..
    "Record lead-in (1/0):,Record lead-out (1/0):,Record to end of bar (1/0):,Wait for scene end when launching (1/0):,Phrase length (bars; ignored " ..
    "if waiting for scene end):,Skip occupied tracks when copying (1/0):," ..
    "Auto repeat on scene start (1/0):,Insert copies after current scene (1/0):,extrawidth=60",
    defaults)
if not ok then return end

local bars, r, g, b, follow, record_auto_loop, record_lead_in, record_lead_out, record_end_of_bar, wait_for_scene_end, switch_wait_bars,
skip_occupied_tracks, auto_repeat, insert_after_current =
    input:match("^([^,]*),(%d+),(%d+),(%d+),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$")
if not bars then
    reaper.MB("Could not parse the settings. Colour must be three numbers, e.g. 48,128,192.", "Scenery", 0)
    return
end

local bar_count = math.floor(tonumber(bars) or 0)
if bar_count < 1 then
    reaper.MB("Default scene length must be a positive whole number.", "Scenery", 0)
    return
end

local switch_wait_bar_count = math.max(0, math.floor(tonumber(switch_wait_bars) or 0))

local function clamp_channel(v)
    return math.max(0, math.min(255, math.floor(tonumber(v) or 0)))
end

L.set_config("default_bars", bar_count)
L.set_config("region_color", string.format("%d,%d,%d", clamp_channel(r), clamp_channel(g), clamp_channel(b)))
L.set_config("follow_enabled", follow:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_auto_loop", record_auto_loop:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_lead_in", record_lead_in:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_lead_out", record_lead_out:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_end_of_bar", record_end_of_bar:match("^%s*1%s*$") and "1" or "0")
L.set_config("wait_for_scene_end", wait_for_scene_end:match("^%s*1%s*$") and "1" or "0")
L.set_config("switch_wait_bars", switch_wait_bar_count)
L.set_config("skip_occupied_tracks", skip_occupied_tracks:match("^%s*1%s*$") and "1" or "0")
L.set_config("auto_repeat", auto_repeat:match("^%s*1%s*$") and "1" or "0")
L.set_config("insert_after_current", insert_after_current:match("^%s*1%s*$") and "1" or "0")
