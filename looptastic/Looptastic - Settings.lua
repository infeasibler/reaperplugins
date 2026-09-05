-- Looptastic: Settings
-- Edits the persistent Looptastic preferences (shared by all Looptastic actions).

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

local cfg = L.get_config()
local defaults = table.concat({
    cfg.default_bars,
    string.format("%d,%d,%d", cfg.color_r, cfg.color_g, cfg.color_b),
    cfg.follow_enabled and "1" or "0",
    cfg.record_auto_loop and "1" or "0",
    cfg.record_end_of_bar and "1" or "0",
}, ",")

local ok, input = reaper.GetUserInputs(
    "Looptastic - Settings", 5,
    "Default scene length (bars):,Region colour (r,g,b):,Engine auto-follow (1/0):,Record auto-loop (1/0):," ..
    "Record to end of bar (1/0):,extrawidth=60",
    defaults)
if not ok then return end

local bars, r, g, b, follow, record_auto_loop, record_end_of_bar =
    input:match("^([^,]*),(%d+),(%d+),(%d+),([^,]*),([^,]*),([^,]*)$")
if not bars then
    reaper.MB("Could not parse the settings. Colour must be three numbers, e.g. 48,128,192.", "Looptastic", 0)
    return
end

local bar_count = math.floor(tonumber(bars) or 0)
if bar_count < 1 then
    reaper.MB("Default scene length must be a positive whole number.", "Looptastic", 0)
    return
end

local function clamp_channel(v)
    return math.max(0, math.min(255, math.floor(tonumber(v) or 0)))
end

L.set_config("default_bars", bar_count)
L.set_config("region_color", string.format("%d,%d,%d", clamp_channel(r), clamp_channel(g), clamp_channel(b)))
L.set_config("follow_enabled", follow:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_auto_loop", record_auto_loop:match("^%s*1%s*$") and "1" or "0")
L.set_config("record_end_of_bar", record_end_of_bar:match("^%s*1%s*$") and "1" or "0")
