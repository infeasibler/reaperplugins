# Plan: Scenery - REAPER scene looper

A set of Lua ReaScripts (the right form factor here - regions, loop points and item copying are all ReaScript-native; JSFX/C++ would be overkill) in `Scenery`, following the style of the existing `playtime_bridge.lua`. A shared library module holds the scene logic, a handful of thin action scripts are bound to keys/toolbar, and one background "engine" defer script keeps loop points following the active scene.

## Phase 1 - Scene core (build now)

1. `scenery_lib.lua` - bar math. `bars_to_time(start, bars)` walks the tempo map with `TimeMap2_timeToBeats` + `TimeMap_GetMeasureInfo` + `TimeMap_QNToTime` so time-signature and tempo changes are honored. Plus `snap_to_bar()`.
2. `scenery_lib.lua` - scene model *(depends on 1)*. `scan_scenes()` enumerates regions via `EnumProjectMarkers3`, keeps those matching `^Scene (%d+)$`, sorts by position. `renumber_scenes()` rewrites names by timeline order after deletions.
3. `scenery_lib.lua` - `active_scene()` *(parallel with 2)*: uses `GetPlayPosition()` while rolling, `GetCursorPosition()` when stopped, returns the containing scene.
4. `scenery_lib.lua` - `create_scene(bars)` *(depends on 1-2)*: start = end of the last scene (or bar-snapped project start if none), `AddProjectMarker2` with `isrgn=true`, then `set_loop_to()` which calls `GetSet_LoopTimeRange2` + `GetSetRepeat(1)` and records a *pending-scene lock* in ExtState. The play cursor is never moved.
5. `scenery_lib.lua` - `copy_items(src_start, src_end, dest_start)` *(depends on 2)*: for each track, items starting inside the range are duplicated via `GetItemStateChunk` -> fresh `genGuid()` for `GUID`/`IGUID` -> `AddMediaItemToTrack` + `SetItemStateChunk`, repositioned by the offset and length-clamped to the destination scene end. Envelopes and tempo markers deliberately excluded in v1.
6. Action scripts *(depend on 4-5, all parallel with each other)*: New scene, New scene (custom bars, via `GetUserInputs`), Duplicate current scene (later split into Copy/Clone, see Phase 5), Go to next/previous scene, Settings (default bar count + region colour, stored in persistent ExtState).
7. `Scenery - Engine (toggle).lua` *(depends on 3-4)*: ~30ms defer loop, toggle/`SetToggleCommandState`/`atexit` pattern lifted from `playtime_bridge.lua`. While a pending-scene lock exists it stays hands-off and only watches for the play cursor to enter that scene, then clears the lock - this is what makes "keep playing, wrap naturally into the new scene" work. With no lock, it re-points the loop whenever the cursor's scene changes. All actions work with the engine off, just without auto-follow.
8. Undo & README *(depends on 6)*: wrap every mutating action in `Undo_BeginBlock2`/`Undo_EndBlock2` with `PreventUIRefresh`, plus README install steps.

## Phase 2 - Record auto-loop (implemented)

The engine snapshots item GUIDs when recording starts (`GetPlayState()` bit 4), diffs on stop to find new items, trims their start forward to the next bar boundary (cutting off the pickup before the first full bar, adjusting the take's start offset so no audio content is lost) and rounds the end up to a bar boundary, sets `B_LOOPSRC=1` and extends `D_LENGTH` to repeat the source through the current scene - the same result as dragging an item's right edge across bars, still referencing the original source. Only new items inside the recording scene are processed; the engine must be running during the recording pass. The launcher exposes a persistent option to enable or disable this behavior. Recording starts and stops immediately - there is no quantized start/stop delay; bar-alignment is applied entirely in this post-processing step, so the launcher's `Rec` button, the standalone `Scenery - Toggle record (quantized).lua` action, and REAPER's native Record command/button all behave identically. `M.toggle_record()` in the shared library backs the `Rec` button and the standalone action; it only adds auto-starting the engine on top of a plain record toggle.

## Phase 3 - Bar-quantized record (superseded by Phase 2's post-processing)

Originally spec'd as a `CSurf_OnRecord()`-driven quantized-start/stop action; superseded by Phase 2's simpler approach of letting recording start/stop immediately and bar-aligning the resulting item afterwards in `apply_loop_source_to_new_items`, which works uniformly regardless of what started/stopped the recording (native command included).

## Phase 4 - Link consecutive scenes (implemented)

Lets two or more *consecutive* scenes loop together as a single unit instead of individually.

1. `scenery_lib.lua` - `is_linked_to_next(scene)` / `set_linked_to_next(scene, linked)` *(depends on Phase 1 item 2)*: link state is stored as a name-convention suffix on the region itself (e.g. `Scene 2 >>`), kept in sync by `scan_scenes()` so it survives project save/reload and is visible in REAPER's Region Manager without any ExtState lookup. `renumber_scenes()` preserves the suffix when rewriting numbers.
2. `scenery_lib.lua` - `link_chain(scene)` *(depends on 1)*: walks forward while `is_linked_to_next()` is true and returns the ordered list of scenes in the chain (supports 2+ scenes, not just pairs).
3. `scenery_lib.lua` - `active_link_chain()` *(depends on 2-3 of Phase 1)*: returns the chain containing the currently active scene, or a single-scene chain if it isn't linked to anything.
4. Engine loop *(depends on 3)*: when following the cursor's scene, resolve the active scene's full chain and set the loop range to span from the first scene's start to the last scene's end via `GetSet_LoopTimeRange2`, so playback loops over every linked scene in sequence before repeating. Unlinking mid-playback re-scopes the loop to just the current scene on the next detected scene change.
5. `Scenery - Toggle link with next scene.lua` *(depends on 1)*: new action script, toggles the link between the active scene and its immediate successor; no-ops (with a status message) if there's no next scene.
6. Launcher UI *(depends on 5)*: show each scene's link state next to its entry (e.g. a chain icon or the `>>` suffix) and let the same toggle be triggered by clicking it, so linking doesn't require memorizing a separate action/keybind.

## Phase 5 - Copy vs. Clone (implemented)

Splits today's "Duplicate" into two distinct actions. Today's Duplicate already gave every item a fresh `GUID`/`IGUID` (see Phase 1 item 5), which is exactly what "Clone" keeps doing; "Copy" is the new, cheaper option.

1. Renamed `Scenery - Duplicate current scene.lua` to `Scenery - Clone current scene.lua` (label "Clone"); it generates fresh `GUID`, `IGUID`, and MIDI `POOLEDEVTS` values per item so the clone is fully independent of the source.
2. Added `scenery_lib.lua` - `copy_items_linked(src_start, src_end, dest_start, dest_end)`: same traversal and repositioning as `copy_items`, but reuses the source item's existing `IGUID` and MIDI `POOLEDEVTS` values instead of generating new ones. REAPER treats items that share these identities as pooled/comped takes, so editing the MIDI/audio content in one item updates every other item sharing them - giving a true "linked copy". `GUID` (the item's own identity) still gets a fresh value so the two remain separate, independently movable/deletable items.
3. Added `Scenery - Copy current scene.lua`: same region/loop bookkeeping as Clone, but calls `copy_items_linked`. It is available next to Clone in the launcher and package actions.
4. Updated the launcher, ReaPack metadata, and README to document the distinction ("Copy = linked, editing one edits both; Clone = fully independent") since pooled comping is a REAPER concept most users won't already know.

## Relevant files

- `scenery/scenery_lib.lua` - new; all scene/bar/item logic
- `scenery/Scenery - Engine (toggle).lua` - new; reuses the toggle + `get_action_context` + `atexit` pattern from `playtime_bridge.lua`
- `scenery/Scenery - New scene.lua`, `... (custom bars).lua`, `... Clone current scene.lua`, `... Copy current scene.lua`, `... Go to next/previous scene.lua`, `... Settings.lua` - thin action wrappers
- `scenery/Scenery - Toggle record (quantized).lua` - new (Phase 2); thin wrapper around `M.toggle_record()`, bindable in place of REAPER's native Record command
- `scenery/Scenery - Toggle link with next scene.lua` - new (Phase 4); toggles the `>>` link suffix between the active scene and its successor
- `scenery/Scenery - Clone current scene.lua` - renamed from `... Duplicate current scene.lua` (Phase 5); fully independent duplicate, fresh `GUID`/`IGUID`
- `scenery/Scenery - Copy current scene.lua` - new (Phase 5); linked duplicate via shared `IGUID` (pooled comping)
- `scenery/README.md` - new; install + action list
- `playtime_bridge.lua` - reference only for CONFIG block, defer service, toggle state and debug logging conventions

## Verification

1. Empty 120bpm 4/4 project -> New scene creates region "Scene 1" at 0-16s, loop points match, repeat enabled.
2. New scene again -> "Scene 2" appended at 16s; loop moves to it.
3. Add a 3/4 marker mid-project -> an 8-bar scene spans 8 ruler bars, not a fixed second count.
4. Put items in Scene 1 -> Clone produces a scene with identical items at the same relative offsets on the same tracks; originals untouched.
5. While playing inside Scene 1, run New scene -> cursor does not jump; playback wraps only once it reaches the new scene.
6. Engine on, transport stopped, click inside Scene 1 -> loop follows.
7. Ctrl+Z after each action reverts in a single step.
8. Manually delete "Scene 2" -> remaining regions renumber on the next action.
9. Toggle engine off -> toolbar unhighlights, no lingering defer loop.
10. Link Scene 1 to Scene 2, engine on, play from Scene 1 -> loop range spans both scenes and playback cycles through 1 then 2 then back to 1, never stopping at the Scene 1/2 boundary.
11. Link Scene 2 to Scene 3 as well (chain of 3) -> loop range spans Scenes 1-3; unlinking Scene 2 from Scene 3 mid-playback re-scopes the loop to Scenes 1-2 only on the next boundary crossing.
12. Clone Scene 1 -> edit a MIDI note in the clone's item -> source item in Scene 1 is unaffected.
13. Copy Scene 1 -> edit a MIDI note in the copy's item -> the same edit appears in the corresponding source item in Scene 1 (and vice versa), confirming the shared `IGUID` pooling.

## Decisions

- Included: region-backed scenes, tempo-map-aware bar lengths, append-after-last placement, item-only duplication, cursor-based active scene, auto-follow engine, scene-scoped record auto-loop, linked-scene chains, Copy (pooled/linked) vs. Clone (independent) duplication.
- Excluded from v1: automation/envelope and tempo-marker duplication, inserting scenes between existing ones, scene deletion/reordering actions, ReaImGui UI, ReaPack packaging.
