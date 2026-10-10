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
    cfg.record_backfill and "1" or "0",
    cfg.record_lead_in and "1" or "0",
    cfg.record_lead_out and "1" or "0",
    cfg.record_lead_out_bars,
    cfg.record_end_of_bar and "1" or "0",
    cfg.wait_for_scene_end and "1" or "0",
    cfg.switch_wait_bars,
    cfg.skip_occupied_tracks and "1" or "0",
    cfg.auto_repeat and "1" or "0",
    cfg.insert_after_current and "1" or "0",
    cfg.copy_automation and "1" or "0",
}, "|")

local ok, input = reaper.GetUserInputs(
    "Scenery - Settings", 15,
    "Default scene length (bars):,Region colour (RGB):,Engine auto-follow (1/0):,Record auto-loop (1/0):," ..
    "Back-fill auto-loops (1/0):,Record lead-in (1/0):,Record lead-out (1/0):,Lead-out duration (bars):,Record to end of phrase (1/0):,Wait for scene end when launching (1/0):,Phrase length (bars; ignored " ..
    "if waiting for scene end):,Skip occupied tracks when copying (1/0):," ..
    "Auto repeat on scene start (1/0):,Insert copies after current scene (1/0):," ..
    "Copy automation during Clone/Copy (1/0):,separator=|,extrawidth=60",
    defaults)
if not ok then return end

local fields = {}
for field in (input .. "|"):gmatch("(.-)|") do fields[#fields + 1] = field end
local bars, colour = fields[1], fields[2]
local r, g, b
if colour then r, g, b = colour:match("^(%d+),(%d+),(%d+)$") end
if #fields ~= 15 or not bars or not r then
    reaper.MB("Could not parse the settings. Colour must be three numbers, e.g. 48,128,192.", "Scenery", 0)
    return
end

local bar_count = math.floor(tonumber(bars) or 0)
if bar_count < 1 then
    reaper.MB("Default scene length must be a positive whole number.", "Scenery", 0)
    return
end

local switch_wait_bar_count = math.max(0, math.floor(tonumber(fields[11]) or 0))
local lead_out_bar_count = tonumber(fields[8])
if not lead_out_bar_count or lead_out_bar_count < 0 then
    reaper.MB("Lead-out duration must be a non-negative number of bars.", "Scenery", 0)
    return
end

local function clamp_channel(v)
    return math.max(0, math.min(255, math.floor(tonumber(v) or 0)))
end

L.set_config("default_bars", bar_count)
L.set_config("region_color", string.format("%d,%d,%d", clamp_channel(r), clamp_channel(g), clamp_channel(b)))
L.set_config("follow_enabled", fields[3]:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_auto_loop", fields[4]:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_backfill", fields[5]:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_lead_in", fields[6]:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_lead_out", fields[7]:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_lead_out_bars", tonumber(fields[8]))
L.set_config("record_end_of_bar", fields[9]:match("^%s*1%s*$") and "1" or "0")
L.set_config("wait_for_scene_end", fields[10]:match("^%s*1%s*$") and "1" or "0")
L.set_config("switch_wait_bars", switch_wait_bar_count)
L.set_config("skip_occupied_tracks", fields[12]:match("^%s*1%s*$") and "1" or "0")
L.set_config("auto_repeat", fields[13]:match("^%s*1%s*$") and "1" or "0")
L.set_config("insert_after_current", fields[14]:match("^%s*1%s*$") and "1" or "0")
L.set_config("copy_automation", fields[15]:match("^%s*1%s*$") and "1" or "0")
