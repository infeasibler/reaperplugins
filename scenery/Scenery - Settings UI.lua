-- @description Scenery - Settings UI
-- @version 0.1.0
-- @author infeasibler
-- @about
--   Configure Scenery preferences in a compact, scrollable window.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local WINDOW = { title = "Scenery Settings", w = 440, h = 610 }
local PAD = 10
local ROW_H = 26
local ROW_GAP = 4
local COLOR = {
    bg = { 0.13, 0.14, 0.16 },
    row = { 0.23, 0.25, 0.29 },
    hover = { 0.29, 0.32, 0.38 },
    button = { 0.20, 0.22, 0.26 },
    text = { 0.90, 0.90, 0.90 },
    dim = { 0.60, 0.62, 0.66 },
}

local previous_cap = 0
local mouse_clicked = false
local scroll = 0
local track_scroll = 0
local track_selector_open = false

local function set_color(color)
    gfx.set(color[1], color[2], color[3], 1)
end

local function hit(x, y, w, h)
    return gfx.mouse_x >= x and gfx.mouse_x < x + w and gfx.mouse_y >= y and gfx.mouse_y < y + h
end

local function draw_label(text, x, y, w, h, color)
    set_color(color or COLOR.text)
    gfx.x = x + 8
    gfx.y = y + (h - gfx.texth) / 2
    gfx.drawstr(text)
end

local function draw_button(x, y, w, h, text, disabled)
    local hovered = not disabled and hit(x, y, w, h)
    set_color(hovered and COLOR.hover or COLOR.button)
    gfx.rect(x, y, w, h, 1)
    local text_w, text_h = gfx.measurestr(text)
    set_color(disabled and COLOR.dim or COLOR.text)
    gfx.x = x + (w - text_w) / 2
    gfx.y = y + (h - text_h) / 2
    gfx.drawstr(text)
    return hovered and mouse_clicked
end

local function row_y(index)
    return 40 + (index - 1) * (ROW_H + ROW_GAP) - scroll
end

local function save_toggle(key, value)
    L.set_config(key, value and "0" or "1")
end

local function draw_toggle(index, label, key, value)
    local y = row_y(index)
    if y + ROW_H >= 40 and y <= gfx.h - PAD then
        if draw_button(PAD, y, gfx.w - PAD * 2, ROW_H, (value and "[x] " or "[ ] ") .. label) then
            if key == "smooth_seek" then
                L.set_smooth_seek(not value)
            else
                save_toggle(key, value)
            end
        end
    end
end

local function draw_number(index, label, value, decrement, increment, display, disabled)
    local y = row_y(index)
    if y + ROW_H < 40 or y > gfx.h - PAD then return end
    local right = gfx.w - PAD
    local button_w = 30
    draw_label(label, PAD, y, right - PAD - 112, ROW_H, COLOR.dim)
    if draw_button(right - 104, y, button_w, ROW_H, "-", disabled) then decrement() end
    if draw_button(right - 70, y, 44, ROW_H, display, disabled) then increment(true) end
    if draw_button(right - 22, y, button_w, ROW_H, "+", disabled) then increment(false) end
end

local function input_number(title, label, current, minimum, integer)
    local ok, input = reaper.GetUserInputs(title, 1, label, tostring(current))
    if not ok then return nil end
    local value = tonumber(input)
    if not value or value < minimum or (integer and value ~= math.floor(value)) then
        reaper.MB(title .. " must be " .. (minimum == 0 and "a non-negative" or "a positive") ..
            (integer and " whole number." or " number."), "Scenery", 0)
        return nil
    end
    if integer then value = math.floor(value) end
    return value
end

local function edit_color(cfg)
    local defaults = string.format("%d,%d,%d", cfg.color_r, cfg.color_g, cfg.color_b)
    local ok, input = reaper.GetUserInputs("Region colour", 1, "RGB (0-255, comma-separated):", defaults)
    if not ok then return end
    local r, g, b = input:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
    if not r then
        reaper.MB("Colour must be three numbers, e.g. 48,128,192.", "Scenery", 0)
        return
    end
    local function channel(value)
        return math.max(0, math.min(255, math.floor(tonumber(value))))
    end
    L.set_config("region_color", string.format("%d,%d,%d", channel(r), channel(g), channel(b)))
end

local function track_entries()
    local entries = {}
    for index = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, index)
        local _, name = reaper.GetTrackName(track, "")
        entries[#entries + 1] = {
            guid = reaper.GetTrackGUID(track),
            number = index + 1,
            name = name ~= "" and name or "Track " .. (index + 1),
        }
    end
    return entries
end

local function save_track_selection(entries, selected)
    local guids = {}
    for _, entry in ipairs(entries) do
        if selected[entry.guid] then guids[#guids + 1] = entry.guid end
    end
    L.set_config("skip_track_guids", table.concat(guids, "|"))
end

local function draw_track_selector(cfg)
    local entries = track_entries()
    local selected = {}
    for guid in cfg.skip_track_guids:gmatch("[^|]+") do selected[guid] = true end
    local selected_count = 0
    for _, entry in ipairs(entries) do
        if selected[entry.guid] then selected_count = selected_count + 1 end
    end

    draw_label("Tracks to preserve during Clone/Copy", PAD, 8, gfx.w - PAD * 2, 24)
    local controls_y = 40
    local gap = ROW_GAP
    local control_w = (gfx.w - PAD * 2 - gap * 2) / 3
    if draw_button(PAD, controls_y, control_w, ROW_H, "All") then
        for _, entry in ipairs(entries) do selected[entry.guid] = true end
        save_track_selection(entries, selected)
    end
    if draw_button(PAD + control_w + gap, controls_y, control_w, ROW_H, "None") then
        selected = {}
        save_track_selection(entries, selected)
    end
    if draw_button(PAD + (control_w + gap) * 2, controls_y, control_w, ROW_H, "Done") then
        track_selector_open = false
    end

    draw_label(selected_count .. " selected", PAD, controls_y + ROW_H + ROW_GAP,
        gfx.w - PAD * 2, 22, COLOR.dim)
    local list_top = controls_y + ROW_H + ROW_GAP + 24
    local row_step = ROW_H + ROW_GAP
    local list_height = math.max(ROW_H, gfx.h - list_top - PAD)
    track_scroll = math.min(math.max(0, track_scroll), math.max(0, #entries * row_step - list_height))
    for _, entry in ipairs(entries) do
        local y = list_top + (entry.number - 1) * row_step - track_scroll
        if y + ROW_H >= list_top and y <= gfx.h - PAD then
            if draw_button(PAD, y, gfx.w - PAD * 2, ROW_H,
                (selected[entry.guid] and "[x] " or "[ ] ") .. entry.number .. ". " .. entry.name) then
                selected[entry.guid] = not selected[entry.guid]
                save_track_selection(entries, selected)
            end
        end
    end
end

local function draw_settings(cfg)
    draw_label("Scenery Settings", PAD, 8, gfx.w - PAD * 2, 24)
    local content_height = 18 * (ROW_H + ROW_GAP)
    local visible_height = gfx.h - 40 - PAD
    scroll = math.min(math.max(0, scroll), math.max(0, content_height - visible_height))

    draw_number(1, "Default scene length (bars)", cfg.default_bars,
        function()
            if cfg.default_bars > 1 then L.set_config("default_bars", cfg.default_bars - 1) end
        end,
        function(edit)
            if edit then
                local value = input_number("Default scene length", "Length in bars:", cfg.default_bars, 1, true)
                if value then L.set_config("default_bars", value) end
            else
                L.set_config("default_bars", cfg.default_bars + 1)
            end
        end, tostring(cfg.default_bars))

    local y = row_y(2)
    if y + ROW_H >= 40 and y <= gfx.h - PAD
        and draw_button(PAD, y, gfx.w - PAD * 2, ROW_H, "Region colour  " ..
            string.format("%d, %d, %d", cfg.color_r, cfg.color_g, cfg.color_b)) then
        edit_color(cfg)
    end

    draw_toggle(3, "Loop follows cursor", "follow_enabled", cfg.follow_enabled)
    draw_toggle(4, "Confirm destructive actions", "confirm_destructive", cfg.confirm_destructive)
    draw_toggle(5, "Smooth seek", "smooth_seek", L.get_smooth_seek())
    draw_toggle(6, "Auto-loop new recordings", "record_auto_loop", cfg.record_auto_loop)
    draw_toggle(7, "Back-fill auto-loops", "record_backfill", cfg.record_backfill)
    draw_toggle(8, "Record to end of phrase", "record_end_of_bar", cfg.record_end_of_bar)
    draw_toggle(9, "Record lead-in", "record_lead_in", cfg.record_lead_in)
    draw_toggle(10, "Record lead-out", "record_lead_out", cfg.record_lead_out)

    draw_number(11, "Lead-out duration (bars)", cfg.record_lead_out_bars,
        function()
            L.set_config("record_lead_out_bars", math.max(0, cfg.record_lead_out_bars - 0.1))
        end,
        function(edit)
            if edit then
                local value = input_number("Lead-out duration", "Duration in bars:", cfg.record_lead_out_bars, 0, false)
                if value then L.set_config("record_lead_out_bars", value) end
            else
                L.set_config("record_lead_out_bars", cfg.record_lead_out_bars + 0.1)
            end
        end, string.format("%g", cfg.record_lead_out_bars))

    draw_toggle(12, "Wait for scene end when launching", "wait_for_scene_end", cfg.wait_for_scene_end)
    draw_number(13, "Phrase length (bars)", cfg.switch_wait_bars,
        function()
            L.set_config("switch_wait_bars", math.max(0, cfg.switch_wait_bars - 1))
        end,
        function(edit)
            if edit then
                local value = input_number("Phrase length", "Length in bars:", cfg.switch_wait_bars, 0, true)
                if value then L.set_config("switch_wait_bars", value) end
            else
                L.set_config("switch_wait_bars", cfg.switch_wait_bars + 1)
            end
        end, tostring(cfg.switch_wait_bars), cfg.wait_for_scene_end)

    local skip_y = row_y(14)
    if skip_y + ROW_H >= 40 and skip_y <= gfx.h - PAD then
        local half = (gfx.w - PAD * 2 - ROW_GAP) / 2
        if draw_button(PAD, skip_y, half, ROW_H,
            (cfg.skip_occupied_tracks and "[x] " or "[ ] ") .. "Skip occupied tracks") then
            save_toggle("skip_occupied_tracks", cfg.skip_occupied_tracks)
        end
        if draw_button(PAD + half + ROW_GAP, skip_y, half, ROW_H, "Choose tracks...") then
            track_selector_open = true
            track_scroll = 0
        end
    end

    draw_toggle(15, "Auto repeat on scene start", "auto_repeat", cfg.auto_repeat)
    draw_toggle(16, "Insert copies after current scene", "insert_after_current", cfg.insert_after_current)
    draw_toggle(17, "Copy automation during Clone/Copy", "copy_automation", cfg.copy_automation)
    local scale = tonumber(reaper.GetExtState(L.EXT_SECTION, "window_scale")) or 1
    draw_number(18, "Launcher scale", scale,
        function()
            L.set_config("window_scale", string.format("%.2f", math.max(0.75, scale - 0.1)))
        end,
        function()
            L.set_config("window_scale", string.format("%.2f", math.min(1.5, scale + 0.1)))
        end, string.format("%d%%", math.floor(scale * 100 + 0.5)))
end

local function read_input()
    local cap = gfx.mouse_cap
    mouse_clicked = (cap & 1) ~= 0 and (previous_cap & 1) == 0
    previous_cap = cap
    if gfx.mouse_wheel ~= 0 then
        local amount = (gfx.mouse_wheel / 120) * (ROW_H + ROW_GAP)
        if track_selector_open then
            track_scroll = track_scroll - amount
        else
            scroll = scroll - amount
        end
        gfx.mouse_wheel = 0
    end
end

local function loop()
    read_input()
    set_color(COLOR.bg)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    local cfg = L.get_config()
    if track_selector_open then draw_track_selector(cfg) else draw_settings(cfg) end
    gfx.update()

    local char = gfx.getchar()
    if char == -1 then return end
    if char == 27 then
        if track_selector_open then track_selector_open = false else return end
    end
    reaper.defer(loop)
end

gfx.init(WINDOW.title, WINDOW.w, WINDOW.h)
gfx.setfont(1, "Segoe UI", 14)
reaper.atexit(gfx.quit)
loop()
