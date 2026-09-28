-- @description Scenery
-- @version 0.1.0
-- @author infeasibler
-- @provides
--   [main] Scenery - New scene.lua
--   [main] Scenery - New scene (custom bars).lua
--   [main] Scenery - Clone current scene.lua
--   [main] Scenery - Copy current scene.lua
--   [main] Scenery - Go to next scene.lua
--   [main] Scenery - Go to previous scene.lua
--   [main] Scenery - Settings.lua
--   [main] Scenery - Toggle link with next scene.lua
--   [main] Scenery - Toggle record (quantized).lua
--   [main] Scenery - Toggle auto repeat.lua
--   [main] Scenery - Toggle insert after current scene.lua
--   [main] Scenery - Toggle record lead-in.lua
--   [main] Scenery - Toggle record lead-out.lua
--   [main] Scenery - Engine (toggle).lua
--   scenery_lib.lua
-- @about
--   Scene-based looping for REAPER. A "scene" is any project region - name it
--   whatever you like (create/rename regions directly on the timeline or in
--   the Region Manager). Creating a scene appends a new region after the
--   last one, sets the loop points to it and enables repeat, so you can
--   build an arrangement one loop at a time without touching the timeline
--   by hand.
--
--   This package installs the whole Scenery toolkit: the Launcher panel,
--   the standalone action scripts (New scene, Clone, Copy, Go to next/
--   previous scene, Settings, Toggle link, Toggle record, Engine) and the
--   shared library they all depend on.

-- Scenery: Launcher
-- Scene launcher drawn with REAPER's built-in gfx; JS_ReaScriptAPI adds an optional title-bar pin.
-- Left-click and double-click both switch scenes immediately; smooth seek (if
-- enabled in Settings) gives the switch a quantized feel.
-- right-click opens a per-scene menu.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local WINDOW = { title = "Scenery", w = 260, h = 604 }
local SCALE = { min = 0.75, max = 1.5, step = 0.1, value = 1 }
local ROW = { h = 26, gap = 4 }
local PAD = 8
local DOUBLE_CLICK_SECONDS = 0.35

local COLOR = {
    bg        = { 0.13, 0.14, 0.16 },
    row       = { 0.23, 0.25, 0.29 },
    row_hover = { 0.29, 0.32, 0.38 },
    playing   = { 0.18, 0.55, 0.34 },
    next      = { 0.82, 0.65, 0.16 },
    button    = { 0.20, 0.22, 0.26 },
    text      = { 0.90, 0.90, 0.90 },
    dim       = { 0.60, 0.62, 0.66 },
}

local mouse = { x = 0, y = 0, lclick = false, rclick = false, double = false }
local prev_cap = 0
local last_click = { time = 0, y = -1 }
local scroll = 0
local track_skip_open = false
local track_skip_scroll = 0

local function logical_width()
    return gfx.w / SCALE.value
end

local function logical_height()
    return gfx.h / SCALE.value
end

local function set_font()
    gfx.setfont(1, "Segoe UI", math.floor(14 * SCALE.value + 0.5))
end

local function attach_topmost_pin()
    if not reaper.JS_Window_AttachTopmostPin or not reaper.JS_Window_Find then return end
    local window = reaper.JS_Window_Find(WINDOW.title, true)
    if window then reaper.JS_Window_AttachTopmostPin(window) end
end

-- ------------------------------------------------------------------ paint

local function set_color(c)
    gfx.set(c[1], c[2], c[3], 1)
end

local function hit(x, y, w, h)
    local mouse_x, mouse_y = mouse.x / SCALE.value, mouse.y / SCALE.value
    return mouse_x >= x and mouse_x < x + w and mouse_y >= y and mouse_y < y + h
end

local function draw_label(text, x, y, w, h, color)
    local tw, th = gfx.measurestr(text)
    tw, th = tw / SCALE.value, th / SCALE.value
    while tw > w - 8 and #text > 1 do
        text = text:sub(1, #text - 2) .. "."
        tw = gfx.measurestr(text) / SCALE.value
    end
    set_color(color or COLOR.text)
    gfx.x = (x + (w - tw) / 2) * SCALE.value
    gfx.y = (y + (h - th) / 2) * SCALE.value
    gfx.drawstr(text)
end

local function panel(x, y, w, h, color, hovered)
    set_color(hovered and COLOR.row_hover or color)
    gfx.rect(x * SCALE.value, y * SCALE.value, w * SCALE.value, h * SCALE.value, 1)
end

local function resize_window(scale)
    local dock, x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
    local base_w, base_h = w / SCALE.value, h / SCALE.value
    SCALE.value = scale
    L.set_config("window_scale", string.format("%.2f", SCALE.value))
    gfx.quit()
    gfx.init(WINDOW.title, math.floor(base_w * SCALE.value + 0.5),
        math.floor(base_h * SCALE.value + 0.5), dock, x, y)
    attach_topmost_pin()
    set_font()
end

local function button(x, y, w, h, label, color, disabled)
    local hovered = not disabled and hit(x, y, w, h)
    panel(x, y, w, h, color or COLOR.button, hovered)
    draw_label(label, x, y, w, h, disabled and COLOR.dim or nil)
    return hovered and mouse.lclick
end

-- ----------------------------------------------------------------- actions

local function undoable(description, fn)
    reaper.PreventUIRefresh(1)
    reaper.Undo_BeginBlock2(0)
    fn()
    reaper.Undo_EndBlock2(0, description, -1)
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
end

local function new_scene(bars)
    undoable("Scenery: New scene", function()
        L.set_loop_to(L.create_scene(bars))
    end)
end

local function duplicate_scene(source, copy_fn, description)
    undoable("Scenery: " .. description .. " scene", function()
        L.set_loop_to(L.duplicate_scene(source, copy_fn))
    end)
end

local function switch_scene(scene)
    L.switch_scene(scene, script_dir)
end

local function record_button_state()
    if L.record_stop_pending() then
        return "Stopping...", COLOR.playing
    end
    if L.is_recording() then
        return "Recording", COLOR.playing
    end
    return "Rec", COLOR.button
end

local function rename_scene(scene)
    local ok, label = reaper.GetUserInputs("Rename scene", 1, "Label:,extrawidth=120", scene.label or "")
    if ok then undoable("Scenery: Rename scene", function() L.rename_scene(scene, label) end) end
end

local function resize_scene(scene, scene_count)
    if scene.num ~= scene_count then
        reaper.MB("Only the last scene can be resized; resizing an earlier one would overlap " ..
            "its neighbour.", "Scenery", 0)
        return
    end
    local bars = L.bars_between(scene.pos, scene.rgnend)
    local ok, input = reaper.GetUserInputs("Set scene length", 1, "Length in bars:", tostring(bars))
    local wanted = ok and math.floor(tonumber(input) or 0) or 0
    if wanted >= 1 then
        undoable("Scenery: Set scene length", function() L.set_scene_length(scene, wanted) end)
    end
end

local function delete_scene(scene, keep_items, skip_confirm)
    if skip_confirm or not L.get_config().confirm_destructive then
        undoable("Scenery: Delete scene", function() L.delete_scene(scene, keep_items) end)
        return
    end
    local prompt = keep_items
        and ("Delete " .. scene.name .. " but keep its items?")
        or ("Delete " .. scene.name .. " and every item inside it?")
    local answer = reaper.MB(prompt .. "\nThe gap it leaves on the timeline is kept.", "Scenery", 4)
    if answer == 6 then
        undoable("Scenery: Delete scene", function() L.delete_scene(scene, keep_items) end)
    end
end

local function toggle_link(scene)
    undoable("Scenery: Toggle link with next scene", function()
        L.set_linked_to_next(scene, not scene.linked)
    end)
end

local function merge_chain(scene, scenes, skip_confirm)
    local chain = L.link_chain(scene, scenes)
    if #chain < 2 then return end
    local do_merge = function() undoable("Scenery: Merge linked scenes", function() L.merge_chain(scene, scenes) end) end
    if skip_confirm or not L.get_config().confirm_destructive then
        do_merge()
        return
    end
    local answer = reaper.MB("Merge " .. #chain .. " linked scenes (" .. chain[1].name .. " through " ..
        chain[#chain].name .. ") into one scene?\nItems stay where they are; only the scene " ..
        "boundaries are removed.", "Scenery", 4)
    if answer == 6 then do_merge() end
end

local function scene_menu(scene, scenes)
    gfx.x, gfx.y = mouse.x, mouse.y
    local scene_count = #scenes
    local has_next = scene.num < scene_count
    local in_chain = #L.link_chain(scene, scenes) >= 2

    -- gfx.showmenu's returned choice only counts selectable items, not the
    -- blank "||" separators, so indices must be tracked alongside them here
    -- rather than assumed from the items array's own length
    local items, idx = {}, 0
    local function add(label)
        items[#items + 1] = label
        idx = idx + 1
        return idx
    end
    local function add_sep() items[#items + 1] = "" end

    local rename_idx = add("Rename...")
    local resize_idx = add("Set length...")
    local clone_idx = add("Clone")
    local copy_idx = add("Copy")
    add_sep()
    local link_idx = has_next and add(scene.linked and "Unlink from next" or "Link with next") or nil
    local merge_idx = in_chain and add("Merge linked scenes") or nil
    add_sep()
    local delete_all_idx = add("Delete scene and its items")
    local delete_keep_idx = add("Delete scene, keep items")

    local choice = gfx.showmenu(table.concat(items, "|"))
    if choice == rename_idx then rename_scene(scene)
    elseif choice == resize_idx then resize_scene(scene, scene_count)
    elseif choice == clone_idx then duplicate_scene(scene, nil, "Clone")
    elseif choice == copy_idx then duplicate_scene(scene, L.copy_items_linked, "Copy")
    elseif link_idx and choice == link_idx then toggle_link(scene)
    elseif merge_idx and choice == merge_idx then merge_chain(scene, scenes)
    elseif choice == delete_all_idx then delete_scene(scene, false)
    elseif choice == delete_keep_idx then delete_scene(scene, true)
    end
end

-- ------------------------------------------------------------------ frame

-- Compares scene identity (not just position) so overlapping/nested regions
-- that share a start time don't all light up as active together.
local function row_color(scene, active, next_id)
    if active and active.enum_idx == scene.enum_idx then return COLOR.playing end
    if next_id and scene.id == next_id then return COLOR.next end
    return COLOR.row
end

local function draw_scene_list(scenes, top, height)
    if #scenes == 0 then
        draw_label("No scenes yet", PAD, top, logical_width() - PAD * 2, ROW.h, COLOR.dim)
        return
    end

    local active = L.active_scene(scenes)
    local next_id = L.get_next_scene_id()
    local step = ROW.h + ROW.gap
    scroll = math.min(math.max(0, scroll), math.max(0, #scenes * step - height))

    local link_w = 28
    for _, scene in ipairs(scenes) do
        local y = top + (scene.num - 1) * step - scroll
        if y + ROW.h > top and y < top + height then
            local x, w = PAD, logical_width() - PAD * 2 - link_w - ROW.gap
            local hovered = hit(x, y, w, ROW.h)
            panel(x, y, w, ROW.h, row_color(scene, active, next_id), hovered and mouse.lclick)
            draw_label(scene.name, x, y, w, ROW.h)

            if hovered and mouse.lclick then
                if mouse.double then L.jump_to(scene, scenes) else switch_scene(scene) end
            elseif hovered and mouse.rclick then
                scene_menu(scene, scenes)
            end

            -- links this scene to its successor so they loop together as one unit
            if scene.num < #scenes then
                local link_x = x + w + ROW.gap
                local label = scene.linked and ">>" or "- -"
                if button(link_x, y, link_w, ROW.h, label, scene.linked and COLOR.playing or COLOR.button) then
                    toggle_link(scene)
                end
            end
        end
    end
end

local function draw_status(y)
    local running = L.engine_running()
    if button(PAD, y, logical_width() - PAD * 2, 20,
            running and "Engine on" or "Engine off - click to start",
            running and COLOR.playing or COLOR.button) then
        L.start_engine(script_dir)
    end
end

local function draw_settings(y, cfg)
    local w = logical_width() - PAD * 2
    local step = 22

    draw_label("Default bars", PAD, y, w - 84, step, COLOR.dim)
    if button(logical_width() - PAD - 78, y, 22, step, "-") and cfg.default_bars > 1 then
        L.set_config("default_bars", cfg.default_bars - 1)
    end
    draw_label(tostring(cfg.default_bars), logical_width() - PAD - 54, y, 30, step)
    if button(logical_width() - PAD - 22, y, 22, step, "+") then
        L.set_config("default_bars", cfg.default_bars + 1)
    end

    local label = (cfg.follow_enabled and "[x] " or "[ ] ") .. "Loop follows cursor"
    if button(PAD, y + step + ROW.gap, w, step, label) then
        L.set_config("follow_enabled", cfg.follow_enabled and "0" or "1")
    end

    local confirm_label = (cfg.confirm_destructive and "[x] " or "[ ] ") .. "Confirm destructive actions"
    if button(PAD, y + (step + ROW.gap) * 2, w, step, confirm_label) then
        L.set_config("confirm_destructive", cfg.confirm_destructive and "0" or "1")
    end

    local smooth_seek = L.get_smooth_seek()
    local smooth_label = (smooth_seek and "[x] " or "[ ] ") .. "Smooth seek (check for smooth transitions)"
    if button(PAD, y + (step + ROW.gap) * 3, w, step, smooth_label) then
        L.set_smooth_seek(not smooth_seek)
    end

    local auto_loop_label = (cfg.record_auto_loop and "[x] " or "[ ] ") .. "Auto-loop new recordings"
    if button(PAD, y + (step + ROW.gap) * 4, w, step, auto_loop_label) then
        L.set_config("record_auto_loop", cfg.record_auto_loop and "0" or "1")
    end

    local backfill_label = (cfg.record_backfill and "[x] " or "[ ] ") .. "Back-fill auto-loops"
    if button(PAD, y + (step + ROW.gap) * 5, w, step, backfill_label) then
        L.set_config("record_backfill", cfg.record_backfill and "0" or "1")
    end

    local end_of_bar_label = (cfg.record_end_of_bar and "[x] " or "[ ] ") .. "Record to end of phrase"
    if button(PAD, y + (step + ROW.gap) * 6, w, step, end_of_bar_label) then
        L.set_config("record_end_of_bar", cfg.record_end_of_bar and "0" or "1")
    end

    local lead_in_label = (cfg.record_lead_in and "[x] " or "[ ] ") .. "Record lead-in"
    if button(PAD, y + (step + ROW.gap) * 7, w, step, lead_in_label) then
        L.set_config("record_lead_in", cfg.record_lead_in and "0" or "1")
    end

    local lead_out_y = y + (step + ROW.gap) * 8
    local lead_out_label = (cfg.record_lead_out and "[x] " or "[ ] ") .. "Record lead-out"
    if button(PAD, lead_out_y, w - 72, step, lead_out_label) then
        L.set_config("record_lead_out", cfg.record_lead_out and "0" or "1")
    end
    if button(logical_width() - PAD - 68, lead_out_y, 68, step,
        string.format("%g bars", cfg.record_lead_out_bars)) then
        local ok, input = reaper.GetUserInputs("Lead-out duration", 1,
            "Duration in bars:", tostring(cfg.record_lead_out_bars))
        if ok then
            local duration = tonumber(input)
            if duration and duration >= 0 then
                L.set_config("record_lead_out_bars", duration)
            else
                reaper.MB("Lead-out duration must be a non-negative number of bars.", "Scenery", 0)
            end
        end
    end

    local wait_label = (cfg.wait_for_scene_end and "[x] " or "[ ] ") .. "Wait for scene end when launching"
    if button(PAD, y + (step + ROW.gap) * 9, w, step, wait_label) then
        L.set_config("wait_for_scene_end", cfg.wait_for_scene_end and "0" or "1")
    end

    -- only meaningful when not already waiting for the scene to end, so greyed out then
    local wait_bars_disabled = cfg.wait_for_scene_end
    local wait_bars_y = y + (step + ROW.gap) * 10
    draw_label("Phrase length", PAD, wait_bars_y, w - 84, step, COLOR.dim)
    if button(logical_width() - PAD - 78, wait_bars_y, 22, step, "-", nil, wait_bars_disabled)
        and cfg.switch_wait_bars > 0 then
        L.set_config("switch_wait_bars", cfg.switch_wait_bars - 1)
    end
    if button(logical_width() - PAD - 54, wait_bars_y, 30, step, tostring(math.max(1, cfg.switch_wait_bars)), nil,
        wait_bars_disabled) then
        local ok, input = reaper.GetUserInputs("Phrase length", 1, "Length in bars:",
            tostring(cfg.switch_wait_bars))
        if ok then
            L.set_config("switch_wait_bars", math.max(0, math.floor(tonumber(input) or cfg.switch_wait_bars)))
        end
    end
    if button(logical_width() - PAD - 22, wait_bars_y, 22, step, "+", nil, wait_bars_disabled) then
        L.set_config("switch_wait_bars", cfg.switch_wait_bars + 1)
    end

    local auto_repeat_label = (cfg.auto_repeat and "[x] " or "[ ] ") .. "Auto repeat on scene start"
    if button(PAD, y + (step + ROW.gap) * 11, w, step, auto_repeat_label) then
        L.set_config("auto_repeat", cfg.auto_repeat and "0" or "1")
    end

    local insert_label = (cfg.insert_after_current and "[x] " or "[ ] ") .. "Insert copies after current scene"
    if button(PAD, y + (step + ROW.gap) * 12, w, step, insert_label) then
        L.set_config("insert_after_current", cfg.insert_after_current and "0" or "1")
    end

    local skip_occupied_y = y + (step + ROW.gap) * 13
    local skip_occupied_label = (cfg.skip_occupied_tracks and "[x] " or "[ ] ") .. "Skip occupied tracks"
    if button(PAD, skip_occupied_y, w - 78, step, skip_occupied_label) then
        L.set_config("skip_occupied_tracks", cfg.skip_occupied_tracks and "0" or "1")
    end
    if button(logical_width() - PAD - 70, skip_occupied_y, 70, step, "Tracks...") then
        track_skip_open = true
        track_skip_scroll = 0
    end

    local scale_y = y + (step + ROW.gap) * 14
    draw_label("Launcher scale", PAD, scale_y, w - 84, step, COLOR.dim)
    if button(logical_width() - PAD - 78, scale_y, 22, step, "-", nil,
        SCALE.value <= SCALE.min) then
        resize_window(math.max(SCALE.min, SCALE.value - SCALE.step))
    end
    draw_label(tostring(math.floor(SCALE.value * 100 + 0.5)) .. "%",
        logical_width() - PAD - 54, scale_y, 30, step)
    if button(logical_width() - PAD - 22, scale_y, 22, step, "+", nil,
        SCALE.value >= SCALE.max) then
        resize_window(math.min(SCALE.max, SCALE.value + SCALE.step))
    end
end

local function skip_track_entries()
    local entries = {}
    for track_index = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, track_index)
        local _, name = reaper.GetTrackName(track, "")
        entries[#entries + 1] = {
            guid = reaper.GetTrackGUID(track),
            number = track_index + 1,
            name = name ~= "" and name or "Track " .. (track_index + 1),
        }
    end
    return entries
end

local function selected_track_guids(serialized)
    local selected = {}
    for guid in serialized:gmatch("[^|]+") do selected[guid] = true end
    return selected
end

local function save_selected_track_guids(entries, selected)
    local guids = {}
    for _, entry in ipairs(entries) do
        if selected[entry.guid] then guids[#guids + 1] = entry.guid end
    end
    L.set_config("skip_track_guids", table.concat(guids, "|"))
end

local function draw_track_skip_selector(cfg)
    local width, height = logical_width(), logical_height()
    local entries = skip_track_entries()
    local selected = selected_track_guids(cfg.skip_track_guids)
    local selected_count = 0
    for _, entry in ipairs(entries) do
        if selected[entry.guid] then selected_count = selected_count + 1 end
    end

    draw_label("Skip these tracks when copying", PAD, PAD, width - PAD * 2, 24)
    local controls_y = PAD + 28
    local control_gap = ROW.gap
    local control_width = (width - PAD * 2 - control_gap * 2) / 3
    if button(PAD, controls_y, control_width, ROW.h, "All") then
        for _, entry in ipairs(entries) do selected[entry.guid] = true end
        save_selected_track_guids(entries, selected)
    end
    if button(PAD + control_width + control_gap, controls_y, control_width, ROW.h, "None") then
        selected = {}
        save_selected_track_guids(entries, selected)
    end
    if button(PAD + (control_width + control_gap) * 2, controls_y,
        control_width, ROW.h, "Done") then
        track_skip_open = false
    end

    draw_label(selected_count .. " selected", PAD, controls_y + ROW.h + ROW.gap,
        width - PAD * 2, 20, COLOR.dim)

    local list_top = controls_y + ROW.h + ROW.gap + 24
    local list_height = math.max(ROW.h, height - list_top - PAD)
    local row_step = ROW.h + ROW.gap
    track_skip_scroll = math.min(math.max(0, track_skip_scroll),
        math.max(0, #entries * row_step - list_height))
    for _, entry in ipairs(entries) do
        local row_y = list_top + (entry.number - 1) * row_step - track_skip_scroll
        if row_y + ROW.h > list_top and row_y < list_top + list_height then
            local label = (selected[entry.guid] and "[x] " or "[ ] ") ..
                entry.number .. ". " .. entry.name
            if button(PAD, row_y, width - PAD * 2, ROW.h, label) then
                selected[entry.guid] = not selected[entry.guid]
                save_selected_track_guids(entries, selected)
            end
        end
    end
end

-- Draws bottom-up and returns the Y the scene list may occupy down to.
local function draw_footer(scenes, cfg)
    local w = logical_width() - PAD * 2
    local top = logical_height() - PAD - (22 * 2 + ROW.gap) - (20 + ROW.gap) -
        (22 + ROW.gap) * 12 - (24 + ROW.gap) * 3 - (22 + ROW.gap) - (22 + ROW.gap)
    local y = top

    if button(PAD, y, w, 24, "+ New scene") then new_scene(cfg.default_bars) end
    y = y + 24 + ROW.gap

    if button(PAD, y, w, 24, "Clone current") then
        local source = L.active_scene(scenes)
        if source then duplicate_scene(source, nil, "Clone") end
    end
    y = y + 24 + ROW.gap

    if button(PAD, y, w, 24, "Copy current") then
        local source = L.active_scene(scenes)
        if source then duplicate_scene(source, L.copy_items_linked, "Copy") end
    end
    y = y + 24 + ROW.gap

    local third = (w - ROW.gap * 2) / 3
    if button(PAD, y, third, 22, "Play") then reaper.Main_OnCommand(1007, 0) end
    if button(PAD + third + ROW.gap, y, third, 22, "Stop") then reaper.Main_OnCommand(1016, 0) end
    local rec_label, rec_color = record_button_state()
    if button(PAD + (third + ROW.gap) * 2, y, third, 22, rec_label, rec_color) then L.toggle_record(cfg, script_dir) end
    y = y + 22 + ROW.gap

    draw_status(y)
    draw_settings(y + 20 + ROW.gap, cfg)

    return top - ROW.gap
end

-- ------------------------------------------------------------------- input

local function read_input()
    mouse.x, mouse.y = gfx.mouse_x, gfx.mouse_y

    local cap = gfx.mouse_cap
    mouse.lclick = (cap & 1) == 1 and (prev_cap & 1) == 0
    mouse.rclick = (cap & 2) == 2 and (prev_cap & 2) == 0
    prev_cap = cap

    mouse.double = false
    if mouse.lclick then
        local now = reaper.time_precise()
        mouse.double = (now - last_click.time) < DOUBLE_CLICK_SECONDS
            and math.abs(mouse.y - last_click.y) < ROW.h
        last_click.time, last_click.y = now, mouse.y
    end

    if gfx.mouse_wheel ~= 0 then
        if track_skip_open then
            track_skip_scroll = track_skip_scroll - (gfx.mouse_wheel / 120) * (ROW.h + ROW.gap)
        else
            scroll = scroll - (gfx.mouse_wheel / 120) * (ROW.h + ROW.gap)
        end
        gfx.mouse_wheel = 0
    end
end

-- -------------------------------------------------------------------- loop

local function save_window()
    local dock, x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
    L.set_config("window", table.concat({ dock, x, y,
        math.floor(w / SCALE.value + 0.5), math.floor(h / SCALE.value + 0.5) }, ","))
    gfx.quit()
end

local function restore_window()
    local saved_scale = tonumber(reaper.GetExtState(L.EXT_SECTION, "window_scale"))
    SCALE.value = math.min(SCALE.max, math.max(SCALE.min, saved_scale or 1))
    local saved = reaper.GetExtState(L.EXT_SECTION, "window")
    local dock, x, y, w, h = saved:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%d+),(%d+)$")
    if not dock then return WINDOW.w * SCALE.value, WINDOW.h * SCALE.value, 0, nil, nil end
    return tonumber(w) * SCALE.value, math.max(WINDOW.h, tonumber(h)) * SCALE.value,
        tonumber(dock), tonumber(x), tonumber(y)
end

local function frame()
    local cfg = L.get_config()
    set_color(COLOR.bg)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    if track_skip_open then
        draw_track_skip_selector(cfg)
        return
    end

    local scenes = L.scan_scenes()
    local list_bottom = draw_footer(scenes, cfg)
    draw_scene_list(scenes, PAD, math.max(ROW.h, list_bottom - PAD))
end

local function loop()
    read_input()
    frame()
    gfx.update()

    local char = gfx.getchar()
    if char == -1 then return end
    if char == 27 then
        if track_skip_open then track_skip_open = false else return end
    end
    reaper.defer(loop)
end

local w, h, dock, x, y = restore_window()
gfx.init(WINDOW.title, w, h, dock, x, y)
attach_topmost_pin()
set_font()
reaper.atexit(save_window)
if not L.engine_running() then L.start_engine(script_dir) end
loop()
