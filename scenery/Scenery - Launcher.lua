-- @description Scenery
-- @version 0.1.0
-- @author infeasibler
-- @provides
--   [main] Scenery - New scene.lua
--   [main] Scenery - New scene (custom bars).lua
--   [main] Scenery - Clone current scene.lua
--   [main] Scenery - Copy current scene.lua
--   [main] Scenery - Delete current scene and close gap.lua
--   [main] Scenery - Go to next scene.lua
--   [main] Scenery - Go to previous scene.lua
--   [main] Scenery - Settings.lua
--   [main] Scenery - Settings UI.lua
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

local WINDOW = { title = "Scenery", w = 260, h = 400 }
local SCALE = { min = 0.75, max = 1.5, step = 0.1, value = 1 }
local ROW = { h = 26, gap = 4 }
local PAD = 8
local SCENE_MIN_W = 200
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
local scene_drag = nil

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
    local hovered = not disabled and not scene_drag and hit(x, y, w, h)
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

local function delete_scene_and_shift(scene)
    local succeeded
    local error_message
    if not L.get_config().confirm_destructive then
        undoable("Scenery: Delete scene and close gap", function()
            succeeded, error_message = L.delete_scene_and_shift(scene)
        end)
    else
        local answer = reaper.MB("Delete " .. scene.name .. " and its items, then shift later items and markers " ..
            "left to close the gap?", "Scenery", 4)
        if answer == 6 then
            undoable("Scenery: Delete scene and close gap", function()
                succeeded, error_message = L.delete_scene_and_shift(scene)
            end)
        end
    end
    if succeeded == false then
        reaper.MB((error_message or "An overlapping item could not be split.") ..
            " The scene was not deleted; check the Undo history for any partial item splits.", "Scenery", 0)
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
    local delete_shift_idx = add("Delete scene and close gap")

    local choice = gfx.showmenu(table.concat(items, "|"))
    if choice == rename_idx then rename_scene(scene)
    elseif choice == resize_idx then resize_scene(scene, scene_count)
    elseif choice == clone_idx then duplicate_scene(scene, nil, "Clone")
    elseif choice == copy_idx then duplicate_scene(scene, L.copy_items_linked, "Copy")
    elseif link_idx and choice == link_idx then toggle_link(scene)
    elseif merge_idx and choice == merge_idx then merge_chain(scene, scenes)
    elseif choice == delete_all_idx then delete_scene(scene, false)
    elseif choice == delete_keep_idx then delete_scene(scene, true)
    elseif choice == delete_shift_idx then delete_scene_and_shift(scene)
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
    local link_w = 28
    local drag_w = 22
    local list_w = logical_width() - PAD * 2
    local columns = math.max(1, math.floor((list_w + ROW.gap) / (SCENE_MIN_W + ROW.gap)))
    local cell_w = (list_w - (columns - 1) * ROW.gap) / columns
    local column_step = cell_w + ROW.gap
    local row_count = math.ceil(#scenes / columns)
    local content_height = row_count * step
    scroll = math.min(math.max(0, scroll), math.max(0, content_height - height))

    local pointer_y = mouse.y / SCALE.value
    local pointer_x = mouse.x / SCALE.value
    local in_list = hit(PAD, top, logical_width() - PAD * 2, height)
    local source
    if scene_drag then
        for _, scene in ipairs(scenes) do
            if scene.id == scene_drag.id then source = scene; break end
        end
        if not source or scene_drag.project ~= reaper.EnumProjects(-1, "")
            or scene_drag.revision ~= reaper.GetProjectStateChangeCount(0) then
            scene_drag = nil
        end
    end
    local drop_index
    if scene_drag then
        if mouse.ldown and in_list then
            local now = reaper.time_precise()
            local elapsed = math.min(0.1, now - scene_drag.last_frame)
            if pointer_y < top + ROW.h then scroll = scroll - elapsed * step * 8 end
            if pointer_y > top + height - ROW.h then scroll = scroll + elapsed * step * 8 end
            scroll = math.min(math.max(0, scroll), math.max(0, content_height - height))
            scene_drag.last_frame = now
        end
        if in_list then
            local column = math.min(columns - 1, math.max(0,
                math.floor((pointer_x - PAD) / column_step)))
            local row = math.max(0, math.floor((pointer_y - top + scroll) / step))
            local cell_x = PAD + column * column_step
            drop_index = math.min(#scenes + 1, math.max(1,
                row * columns + column + (pointer_x >= cell_x + cell_w / 2 and 2 or 1)))
            if scenes[drop_index] then
                drop_index = L.link_chain(scenes[drop_index], scenes)[1].num
            end
            if not L.scene_move_plan(source, scenes[drop_index], scenes) then drop_index = nil end
        end
        if mouse.lrelease then
            scene_drag = nil
            if drop_index then
                local succeeded, message
                undoable("Scenery: Reorder scenes", function()
                    succeeded, message = L.move_scene(source, scenes[drop_index], scenes)
                end)
                if not succeeded then reaper.MB(message, "Scenery", 0) end
            end
            return
        end
    end
    local dragged_ids = {}
    if scene_drag then
        for _, member in ipairs(L.link_chain(source, scenes)) do dragged_ids[member.id] = true end
    end
    for index, scene in ipairs(scenes) do
        local column = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local cell_x = PAD + column * column_step
        local y = top + row * step - scroll
        if y >= top and y + ROW.h <= top + height then
            local x = cell_x + drag_w + ROW.gap
            local w = cell_w - drag_w - link_w - ROW.gap * 2
            local handle_hovered = hit(cell_x, y, drag_w, ROW.h)
            panel(cell_x, y, drag_w, ROW.h, COLOR.button, handle_hovered)
            set_color(dragged_ids[scene.id] and COLOR.next or COLOR.dim)
            for line_index = 0, 2 do
                gfx.rect((cell_x + 5) * SCALE.value, (y + 8 + line_index * 4) * SCALE.value,
                    12 * SCALE.value, math.max(1, SCALE.value), 1)
            end
            if handle_hovered and not scene_drag then
                if type(reaper.TrackCtl_SetToolTip) == "function" then
                    local screen_x, screen_y = gfx.clienttoscreen(mouse.x + 12, mouse.y + 16)
                    reaper.TrackCtl_SetToolTip("Move scene chain", screen_x, screen_y, true)
                end
                if mouse.lclick then
                    scene_drag = { id = scene.id, project = reaper.EnumProjects(-1, ""),
                        revision = reaper.GetProjectStateChangeCount(0), last_frame = reaper.time_precise() }
                end
            end
            local hovered = not scene_drag and hit(x, y, w, ROW.h)
            panel(x, y, w, ROW.h, dragged_ids[scene.id] and COLOR.row_hover
                or row_color(scene, active, next_id), hovered and mouse.lclick)
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
    if drop_index then
        local column, row, line_x
        if drop_index <= #scenes then
            column = (drop_index - 1) % columns
            row = math.floor((drop_index - 1) / columns)
            line_x = PAD + column * column_step - ROW.gap / 2
        else
            local last_column = (#scenes - 1) % columns
            local last_row = math.floor((#scenes - 1) / columns)
            if last_column < columns - 1 then
                column, row = last_column, last_row
                line_x = PAD + column * column_step + cell_w + ROW.gap / 2
            else
                column, row = 0, last_row + 1
                line_x = PAD - ROW.gap / 2
            end
        end
        local line_y = top + row * step - scroll
        if line_y >= top - ROW.h and line_y <= top + height then
            set_color(COLOR.next)
            gfx.rect(line_x * SCALE.value, line_y * SCALE.value,
                2 * SCALE.value, ROW.h * SCALE.value, 1)
        end
    end
end

local function draw_status(y)
    local settings_w = 24
    local status_w = logical_width() - PAD * 2 - settings_w - ROW.gap
    local running = L.engine_running()
    if button(PAD, y, status_w, 20,
            running and "Engine on" or "Engine off - click to start",
            running and COLOR.playing or COLOR.button) then
        L.start_engine(script_dir)
    end
    local x = logical_width() - PAD - settings_w
    panel(x, y - 2, settings_w, 24, COLOR.button, hit(x, y - 2, settings_w, 24))
    local hovered = hit(x, y - 2, settings_w, 24)
    draw_label("⚙", x, y - 2, settings_w, 24, hovered and COLOR.text or COLOR.dim)
    if hovered and mouse.lclick then
        local command_id = reaper.AddRemoveReaScript(true, 0,
            script_dir .. "Scenery - Settings UI.lua", true)
        if command_id and command_id > 0 then
            reaper.Main_OnCommand(command_id, 0)
        else
            reaper.MB("Could not open Scenery Settings UI.", "Scenery", 0)
        end
    end
end

-- Draws bottom-up and returns the Y the scene list may occupy down to.
local function draw_footer(scenes, cfg)
    local w = logical_width() - PAD * 2
    local top = logical_height() - PAD - (20 + ROW.gap) - (22 + ROW.gap) - (24 + ROW.gap) * 3
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
    if button(PAD + (third + ROW.gap) * 2, y, third, 22, rec_label, rec_color) then L.toggle_record(cfg) end
    y = y + 22 + ROW.gap

    draw_status(y)

    return top - ROW.gap
end

-- ------------------------------------------------------------------- input

local function read_input()
    mouse.x, mouse.y = gfx.mouse_x, gfx.mouse_y

    local cap = gfx.mouse_cap
    mouse.lclick = (cap & 1) == 1 and (prev_cap & 1) == 0
    mouse.ldown = (cap & 1) == 1
    mouse.lrelease = (cap & 1) == 0 and (prev_cap & 1) == 1
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

    local scenes = L.scan_scenes()
    local list_bottom = draw_footer(scenes, cfg)
    draw_scene_list(scenes, PAD, math.max(ROW.h, list_bottom - PAD))
end

local function loop()
    local saved_scale = tonumber(reaper.GetExtState(L.EXT_SECTION, "window_scale"))
    local wanted_scale = math.min(SCALE.max, math.max(SCALE.min, saved_scale or SCALE.value))
    if math.abs(wanted_scale - SCALE.value) >= 0.01 then resize_window(wanted_scale) end
    read_input()
    frame()
    gfx.update()

    local char = gfx.getchar()
    if char == -1 then return end
    if char == 27 then
        if scene_drag then
            scene_drag = nil
        else return end
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
