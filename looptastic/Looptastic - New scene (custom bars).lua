-- Looptastic: New scene (custom bars)
-- Prompts for a bar count, then appends and loops a new scene region.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

local cfg = L.get_config()
local ok, input = reaper.GetUserInputs("Looptastic - New scene", 1, "Length in bars:", tostring(cfg.default_bars))
if not ok then return end

local bars = math.floor(tonumber(input) or 0)
if bars < 1 then
    reaper.MB("Bar count must be a positive whole number.", "Looptastic", 0)
    return
end

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock2(0)

L.renumber_scenes()
local scene = L.create_scene(bars)
L.set_loop_to(scene)

reaper.Undo_EndBlock2(0, "Looptastic: New scene (" .. bars .. " bars)", -1)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
