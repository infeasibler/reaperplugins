-- Looptastic: Toggle record (quantized)
-- Starts recording immediately, same as REAPER's native Record command. With
-- "Auto-loop new recordings" enabled and the engine running, stopping is
-- quantized: recording keeps going until just past the end of the current
-- bar so nothing is missed, then the engine issues the real stop and
-- bar-aligns the new items. Equivalent to pressing the launcher's Rec button.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "looptastic_lib.lua")

L.toggle_record(L.get_config(), script_dir)
