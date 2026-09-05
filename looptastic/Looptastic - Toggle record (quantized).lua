-- Looptastic: Toggle record (quantized)
-- Starts/stops recording immediately, same as REAPER's native Record command.
-- With "Auto-loop new recordings" enabled in the launcher, this also makes sure
-- the engine is running so new items get bar-aligned and looped through the
-- scene afterwards. Equivalent to pressing the launcher's Rec button or the
-- native Record button/shortcut - all three now behave the same way.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

L.toggle_record(L.get_config(), script_dir)
