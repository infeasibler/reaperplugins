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
-- Ableton-style scene launcher drawn with REAPER's built-in gfx (no extensions needed).
-- Left-click and double-click both switch scenes immediately; smooth seek (if
-- enabled in Settings) gives the switch a quantized feel.
-- right-click opens a per-scene menu.

local script_dir = ({ reaper.get_action_context() })[2]:match("^(.*[\\/])")
local L = dofile(script_dir .. "scenery_lib.lua")

local WINDOW = { title = "Scenery", w = 260, h = 500 }
local ROW = { h = 26, gap = 4 }
local PAD = 8
local DOUBLE_CLICK_SECONDS = 0.35

local COLOR = {
    bg        = { 0.13, 0.14, 0.16 },
    row       = { 0.23, 0.25, 0.29 },
    row_hover = { 0.29, 0.32, 0.38 },
    playing   = { 0.18, 0.55, 0.34 },
    button    = { 0.20, 0.22, 0.26 },
    text      = { 0.90, 0.90, 0.90 },
    dim       = { 0.60, 0.62, 0.66 },
}

local mouse = { x = 0, y = 0, lclick = false, rclick = false, double = false }
local prev_cap = 0
local last_click = { time = 0, y = -1 }
local scroll = 0

-- ------------------------------------------------------------------ paint

local function set_color(c)
    gfx.set(c[1], c[2], c[3], 1)
end

local function hit(x, y, w, h)
    return mouse.x >= x and mouse.x < x + w and mouse.y >= y and mouse.y < y + h
end

local function draw_label(text, x, y, w, h, color)
    local tw, th = gfx.measurestr(text)
    while tw > w - 8 and #text > 1 do
        text = text:sub(1, #text - 2) .. "."
        tw = gfx.measurestr(text)
    end
    set_color(color or COLOR.text)
    gfx.x = x + (w - tw) / 2
    gfx.y = y + (h - th) / 2
    gfx.drawstr(text)
end

local function panel(x, y, w, h, color, hovered)
    set_color(hovered and COLOR.row_hover or color)
    gfx.rect(x, y, w, h, 1)
end

local function button(x, y, w, h, label, color)
    local hovered = hit(x, y, w, h)
    panel(x, y, w, h, color or COLOR.button, hovered)
    draw_label(label, x, y, w, h)
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
    L.queue_scene(scene)
    if not L.engine_running() then L.start_engine(script_dir) end
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
local function row_color(scene, active)
    if active and active.enum_idx == scene.enum_idx then return COLOR.playing end
    return COLOR.row
end

local function draw_scene_list(scenes, top, height)
    if #scenes == 0 then
        draw_label("No scenes yet", PAD, top, gfx.w - PAD * 2, ROW.h, COLOR.dim)
        return
    end

    local active = L.active_scene(scenes)
    local step = ROW.h + ROW.gap
    scroll = math.min(math.max(0, scroll), math.max(0, #scenes * step - height))

    local link_w = 28
    for _, scene in ipairs(scenes) do
        local y = top + (scene.num - 1) * step - scroll
        if y + ROW.h > top and y < top + height then
            local x, w = PAD, gfx.w - PAD * 2 - link_w - ROW.gap
            local hovered = hit(x, y, w, ROW.h)
            panel(x, y, w, ROW.h, row_color(scene, active), hovered and mouse.lclick)
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
    if button(PAD, y, gfx.w - PAD * 2, 20,
            running and "Engine on" or "Engine off - click to start",
            running and COLOR.playing or COLOR.button) then
        L.start_engine(script_dir)
    end
end

local function draw_settings(y, cfg)
    local w = gfx.w - PAD * 2
    local step = 22

    draw_label("Default bars", PAD, y, w - 84, step, COLOR.dim)
    if button(gfx.w - PAD - 78, y, 22, step, "-") and cfg.default_bars > 1 then
        L.set_config("default_bars", cfg.default_bars - 1)
    end
    draw_label(tostring(cfg.default_bars), gfx.w - PAD - 54, y, 30, step)
    if button(gfx.w - PAD - 22, y, 22, step, "+") then
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

    local end_of_bar_label = (cfg.record_end_of_bar and "[x] " or "[ ] ") .. "Record to end of bar"
    if button(PAD, y + (step + ROW.gap) * 5, w, step, end_of_bar_label) then
        L.set_config("record_end_of_bar", cfg.record_end_of_bar and "0" or "1")
    end
end

-- Draws bottom-up and returns the Y the scene list may occupy down to.
local function draw_footer(scenes, cfg)
    local w = gfx.w - PAD * 2
    local top = gfx.h - PAD - (22 * 2 + ROW.gap) - (20 + ROW.gap) - (22 + ROW.gap) * 4 - (24 + ROW.gap) * 3 - (22 + ROW.gap)
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
        scroll = scroll - (gfx.mouse_wheel / 120) * (ROW.h + ROW.gap)
        gfx.mouse_wheel = 0
    end
end

-- -------------------------------------------------------------------- loop

local function save_window()
    local dock, x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
    L.set_config("window", table.concat({ dock, x, y, w, h }, ","))
    gfx.quit()
end

local function restore_window()
    local saved = reaper.GetExtState(L.EXT_SECTION, "window")
    local dock, x, y, w, h = saved:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%d+),(%d+)$")
    if not dock then return WINDOW.w, WINDOW.h, 0, nil, nil end
    return tonumber(w), tonumber(h), tonumber(dock), tonumber(x), tonumber(y)
end

local function frame()
    local cfg = L.get_config()
    local scenes = L.scan_scenes()

    set_color(COLOR.bg)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    local list_bottom = draw_footer(scenes, cfg)
    draw_scene_list(scenes, PAD, math.max(ROW.h, list_bottom - PAD))
end

local function loop()
    read_input()
    frame()
    gfx.update()

    local char = gfx.getchar()
    if char == -1 or char == 27 then return end
    reaper.defer(loop)
end

local w, h, dock, x, y = restore_window()
gfx.init(WINDOW.title, w, h, dock, x, y)
gfx.setfont(1, "Segoe UI", 14)
reaper.atexit(save_window)
if not L.engine_running() then L.start_engine(script_dir) end
loop()
