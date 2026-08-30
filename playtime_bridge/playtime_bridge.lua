-- Playtime Bridge v1.0
-- Automatically starts/stops REAPER transport in sync with Playtime 2 playback.
--
-- INSTALLATION:
--   1. Copy this file to your REAPER Scripts folder
--      (REAPER > Options > Show REAPER resource path > Scripts)
--   2. In REAPER: Actions > Show action list > New action > Load ReaScript
--      Load this file, then assign it to a toolbar button or run it once.
--   3. The script runs as a persistent background service via defer().
--      To stop it, run it again (it will toggle off) OR close REAPER.
--
-- MIDI CLOCK BRIDGE (preferred for VST drum machines):
--   For drum machine VSTs that need MIDI clock, this script starts REAPER's
--   transport when Playtime plays. REAPER will then send MIDI clock to all
--   configured MIDI outputs while playing.
--
--   Optional hardware MIDI clock routing (zero-latency alternative):
--     1. Install loopMIDI (https://www.tobias-erichsen.de/software/loopmidi.html)
--     2. Create a virtual port named "PlaytimeBridge"
--     3. Set CONFIG.use_midi_bridge = true and run the script
--     4. In your drum machine VST, select "PlaytimeBridge" as the MIDI input
--        for clock sync instead of (or in addition to) REAPER's transport.
--
-- ========================== CONFIGURATION ==========================

local CONFIG = {
    -- Detection method for Playtime's playing state:
    --   "auto"    - tries all methods in order (recommended)
    --   "peak"    - audio peak on the Helgobox track (works always, slight latency)
    --   "extstate"- reads Helgobox ExtState (fast, only works if Helgobox writes it)
    --   "command" - checks a named toggle command (fast, only works if registered)
    detection_method = "auto",

    -- Name or partial name of the track that has Helgobox loaded.
    -- Leave empty ("") to auto-scan all tracks.
    helgobox_track_name = "",

    -- Audio peak threshold: above this level = Playtime is playing.
    -- Raise if false positives occur (e.g. reverb tails), lower if clips aren't detected.
    peak_threshold = 0.005,

    -- Seconds of silence before REAPER transport is stopped (only used for peak detection).
    -- Increase if REAPER stops too early during gaps in clips.
    silence_timeout = 1.5,

    -- How often the bridge checks state (seconds). Lower = more responsive, more CPU.
    poll_interval = 0.08,

    -- If true, also sends MIDI Start/Stop to a virtual MIDI port for zero-latency clock.
    -- Requires loopMIDI or similar virtual MIDI driver installed.
    use_midi_bridge = false,
    midi_bridge_port_name = "PlaytimeBridge",

    -- Set true to print diagnostic info to REAPER console (useful for troubleshooting).
    debug = false,
}

-- =========================== INTERNALS ===========================

local SCRIPT_NAME = "Playtime Bridge"
local EXT_SECTION = "PlaytimeBridge"

-- Capture action context so SetToggleCommandState targets the right toolbar
local _, _, sectionID, cmdID = reaper.get_action_context()

-- Lua-level flag; only this instance reads/writes it
local running = false

-- Cached state
local helgobox_track    = nil
local helgobox_fx_idx   = -1
local silence_start     = nil
local was_playing       = false
local transport_started_by_us = false

-- MIDI output handle for bridge port
local midi_out = nil

local function dbg(msg)
    if CONFIG.debug then
        reaper.ShowConsoleMsg("[PlaytimeBridge] " .. tostring(msg) .. "\n")
    end
end

-- ----------------------------------------------------------------
-- Track / FX discovery
-- ----------------------------------------------------------------

local function find_helgobox_fx()
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local _, tname = reaper.GetTrackName(track)

        -- Honour explicit track name filter if set
        if CONFIG.helgobox_track_name ~= "" then
            if not tname:lower():find(CONFIG.helgobox_track_name:lower(), 1, true) then
                goto continue
            end
        end

        for j = 0, reaper.TrackFX_GetCount(track) - 1 do
            local _, fname = reaper.TrackFX_GetFXName(track, j)
            local fl = fname:lower()
            if fl:find("helgobox", 1, true) or fl:find("playtime", 1, true) then
                dbg("Found Helgobox: track=" .. tname .. ", fx=" .. fname)
                return track, j
            end
        end

        ::continue::
    end
    return nil, -1
end

-- ----------------------------------------------------------------
-- State detection methods
-- ----------------------------------------------------------------

-- Method 1: Helgobox ExtState (if the plugin writes "is playing" here)
local function detect_via_extstate()
    -- Helgobox may write state under different keys; try the most likely ones.
    local candidates = {
        { "Helgobox",        "PlaytimeMatrixIsPlaying" },
        { "Helgobox",        "playtime_matrix_playing" },
        { "helgobox",        "matrix_is_playing" },
        { "PlaytimeEngine",  "is_playing" },
    }
    for _, kv in ipairs(candidates) do
        local val = reaper.GetExtState(kv[1], kv[2])
        if val ~= "" then
            dbg("extstate hit: [" .. kv[1] .. "] " .. kv[2] .. " = " .. val)
            return val == "1" or val:lower() == "true"
        end
    end
    return nil  -- nil = "don't know"
end

-- Method 2: Named toggle command registered by Helgobox
local function detect_via_command()
    local names = {
        "_HELGOBOX_PLAYTIME_IS_PLAYING",
        "_HELGOBOX_PLAYTIME_MATRIX_PLAYING",
        "_HB_PLAYTIME_TRANSPORT_PLAY",
        "_PLAYTIME_MATRIX_TRANSPORT",
    }
    for _, n in ipairs(names) do
        local id = reaper.NamedCommandLookup(n)
        if id and id ~= 0 then
            local state = reaper.GetToggleCommandState(id)
            if state >= 0 then
                dbg("command hit: " .. n .. " = " .. state)
                return state == 1
            end
        end
    end
    return nil
end

-- Method 3: Audio peak detection — checks all tracks except the silent Helgobox host
local function detect_via_peak()
    local total = reaper.CountTracks(0)
    for i = 0, total - 1 do
        local track = reaper.GetTrack(0, i)
        if track ~= helgobox_track then
            local peak = math.max(
                reaper.Track_GetPeakInfo(track, 0),
                reaper.Track_GetPeakInfo(track, 1)
            )
            if peak > CONFIG.peak_threshold then
                dbg("track " .. i .. " peak = " .. string.format("%.5f", peak))
                return true
            end
        end
    end
    dbg("all tracks silent")
    return false
end

local function is_playtime_playing()
    local method = CONFIG.detection_method

    if method == "extstate" then
        return detect_via_extstate() or false
    end

    if method == "command" then
        return detect_via_command() or false
    end

    if method == "peak" then
        return detect_via_peak()
    end

    -- "auto": try fast methods first, fall back to peak
    local r = detect_via_extstate()
    if r ~= nil then return r end

    r = detect_via_command()
    if r ~= nil then return r end

    return detect_via_peak()
end

-- ----------------------------------------------------------------
-- MIDI bridge helpers (optional)
-- ----------------------------------------------------------------

local function open_midi_out()
    if not CONFIG.use_midi_bridge then return end
    local n = reaper.GetNumMIDIOutputs()
    for i = 0, n - 1 do
        local _, name = reaper.GetMIDIOutputName(i, "")
        if name:lower():find(CONFIG.midi_bridge_port_name:lower(), 1, true) then
            midi_out = reaper.CreateMIDIOutput(i, false, nil)
            dbg("MIDI bridge opened: " .. name)
            return
        end
    end
    reaper.ShowMessageBox(
        "Could not find MIDI port '" .. CONFIG.midi_bridge_port_name .. "'.\n" ..
        "Install loopMIDI and create a port with that name, or set\n" ..
        "CONFIG.use_midi_bridge = false in the script.",
        SCRIPT_NAME, 0)
end

local function send_midi_start()
    if midi_out then
        reaper.MIDIOutput_SendMsg(midi_out, string.char(0xFA), -1) -- MIDI Start
        dbg("sent MIDI Start")
    end
end

local function send_midi_stop()
    if midi_out then
        reaper.MIDIOutput_SendMsg(midi_out, string.char(0xFC), -1) -- MIDI Stop
        reaper.MIDIOutput_SendMsg(midi_out, string.char(0xB0, 0x7B, 0x00), -1) -- All Notes Off
        dbg("sent MIDI Stop")
    end
end

-- ----------------------------------------------------------------
-- Transport control
-- ----------------------------------------------------------------

local TRANSPORT_PLAY = 1007   -- REAPER: Transport Play
local TRANSPORT_STOP = 1016   -- REAPER: Transport Stop

local function start_reaper_transport()
    if (reaper.GetPlayState() & 1) == 0 then
        -- Seek to bar 1 so REAPER sends MIDI Start (0xFA) instead of SPP+Continue.
        -- Without this, drum-machine VSTs that need MIDI clock will be phase-shifted
        -- if the playhead is not at position 0.
        reaper.SetEditCurPos(0, false, false)
        reaper.Main_OnCommand(TRANSPORT_PLAY, 0)
        transport_started_by_us = true
        send_midi_start()
        dbg("REAPER transport started by bridge (seeked to bar 1)")
    end
end

local function stop_reaper_transport()
    if (reaper.GetPlayState() & 1) ~= 0 and transport_started_by_us then
        reaper.Main_OnCommand(TRANSPORT_STOP, 0)
        transport_started_by_us = false
        send_midi_stop()
        dbg("REAPER transport stopped by bridge")
    end
end

-- ----------------------------------------------------------------
-- Main polling loop
-- ----------------------------------------------------------------

local last_check_time = 0

local function update()
    if not running then return end  -- stop deferring when flagged off

    local now = reaper.time_precise()
    if now - last_check_time < CONFIG.poll_interval then
        reaper.defer(update)
        return
    end
    last_check_time = now

    -- Re-locate Helgobox if not yet found (project may have changed)
    if not helgobox_track then
        helgobox_track, helgobox_fx_idx = find_helgobox_fx()
        if not helgobox_track then
            dbg("Helgobox not found on any track. Retrying next cycle.")
        end
    end

    local playing = is_playtime_playing()

    if playing and not was_playing then
        -- Playtime just started → start REAPER transport
        start_reaper_transport()
    elseif not playing and was_playing then
        -- Playtime just stopped → begin silence countdown (handles reverb tails)
        if not silence_start then
            silence_start = now
            dbg("silence timer started")
        end
    end

    -- After silence_timeout seconds of confirmed silence, stop REAPER transport
    if silence_start and not playing then
        if now - silence_start >= CONFIG.silence_timeout then
            stop_reaper_transport()
            silence_start = nil
        end
    elseif playing then
        -- Reset silence timer if playback resumed
        silence_start = nil
    end

    -- If the user manually stopped REAPER transport, reset our ownership flag
    if (reaper.GetPlayState() & 1) == 0 then
        transport_started_by_us = false
    end

    was_playing = playing
    reaper.defer(update)
end

-- ----------------------------------------------------------------
-- Toggle on/off when the action is run
-- ----------------------------------------------------------------

local function stop_bridge()
    running = false
    reaper.SetToggleCommandState(sectionID, cmdID, 0)
    reaper.RefreshToolbar2(sectionID, cmdID)
    if midi_out then reaper.DestroyMIDIOutput(midi_out) end
    reaper.ShowConsoleMsg("[" .. SCRIPT_NAME .. "] stopped.\n")
end

local function start_bridge()
    running = true
    helgobox_track          = nil
    helgobox_fx_idx         = -1
    was_playing             = false
    silence_start           = nil
    transport_started_by_us = false
    last_check_time         = 0

    reaper.SetToggleCommandState(sectionID, cmdID, 1)
    reaper.RefreshToolbar2(sectionID, cmdID)
    reaper.ShowConsoleMsg("[" .. SCRIPT_NAME .. "] started. Detection: " .. CONFIG.detection_method .. "\n")
    reaper.atexit(stop_bridge)
    open_midi_out()
    reaper.defer(update)
end

-- "Yes" on the terminate dialog kills the running instance and does NOT run a new one.
-- So a fresh invocation here always means "start".
start_bridge()
