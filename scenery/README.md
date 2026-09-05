# Scenery

Scene-based looping for REAPER. A "scene" is any project region — name it whatever you like (create/rename regions directly on the timeline or in the Region Manager). Creating a scene via Scenery appends a new region after the last one, named `Scene N` where `N` is simply the current region count + 1; it sets the loop points to it and enables repeat, so you can build an arrangement one loop at a time without touching the timeline by hand.

## Install

1. In REAPER: **Options > Show REAPER resource path in explorer/finder**, then open the `Scripts` folder.
2. Copy the whole `scenery` folder into it. `scenery_lib.lua` must stay alongside the action scripts.
3. **Actions > Show action list > New action > Load ReaScript…**, and load each `Scenery - *.lua` file (not the `_lib` file).
4. Assign keyboard shortcuts or toolbar buttons to the actions you use.

## Actions

| Action | What it does |
| --- | --- |
| `Scenery - Launcher` | Scene launcher panel. Left-click or double-click switches to a scene immediately. Right-click renames/resizes, links or merges scenes, clones/copies, and deletes scenes (with or without their items). Also has new/clone/copy, transport and launcher settings. |
| `Scenery - New scene` | Appends a scene of the default length (8 bars) and loops it. |
| `Scenery - New scene (custom bars)` | Same, but prompts for the bar count. |
| `Scenery - Clone current scene` | Appends a scene of the configured length with fully independent item copies. |
| `Scenery - Copy current scene` | Appends a scene of the configured length with linked item copies. Editing pooled MIDI/audio content in either scene affects the other. |
| `Scenery - Go to next scene` / `Scenery - Go to previous scene` | Moves the loop to the neighbouring scene. |
| `Scenery - Toggle link with next scene` | Links or unlinks the active scene with its immediate successor, so the engine can loop the linked scenes as one range. |
| `Scenery - Toggle record (quantized)` | Starts/stops recording immediately, same as REAPER's native Record command, but also makes sure the engine is running so new items get bar-aligned afterwards. Handy as a bindable equivalent to the launcher's `Rec` button. |
| `Scenery - Settings` | Default scene length, region colour, auto-follow on/off, record auto-loop on/off, and record-to-end-of-bar on/off. The launcher settings also include destructive-action confirmation and REAPER's Smooth seek preference. |
| `Scenery - Engine (toggle)` | Background service that keeps the loop on the scene, or its linked chain, under the cursor and handles recording post-processing. Run again to stop. The launcher and standalone recording action start it automatically when needed. |

## Behaviour notes

- Scene lengths follow the project tempo and time-signature map, so 8 bars stays 8 bars across meter changes.
- Switching scenes from the launcher moves the loop points and seeks immediately; enable "Smooth seek" in the launcher's Settings for REAPER to quantize the audible transition to the next bar/measure instead of cutting instantly.
- Creating a scene never moves the play cursor. If the transport is rolling, playback continues and wraps into the new loop when it reaches it — the engine holds off auto-follow until then.
- Scene regions can be renamed to anything via the launcher's Rename... or directly in the Region Manager; Scenery never rewrites an existing scene's name. Its position number (used for next/previous navigation) is always computed from timeline order, not stored in the name.
- New/Clone/Copy name the region they create `Scene N`, where `N` is the region count at the time of creation — so numbering stays sensible even if earlier regions have been freely renamed.
- Linking a scene to its immediate successor makes the engine loop the whole consecutive chain as one range. The launcher's Merge linked scenes command collapses that chain into one region without moving its items.
- When the engine is running and record auto-loop is enabled, each recording pass snapshots existing item GUIDs. New items recorded inside the active scene are moved to the containing bar, set to loop their source, and extended to the scene end when recording stops.
- With record auto-loop enabled and the engine running, the launcher's `Rec` button, the `Toggle record (quantized)` action, and REAPER's native Record button/shortcut all start and stop recording immediately. Afterwards, the recorded item's start is trimmed forward to the next bar boundary (cutting off the pickup before the first full bar) and its end is rounded up to a bar boundary before it is set to loop through the scene. The launcher and standalone action start the engine automatically; native Record requires the engine to already be running for this processing.
- "Record to end of bar" (on by default) is independent of auto-loop: when stopping a recording, it delays the actual stop until just past the end of the current bar so nothing is lost, even if auto-loop is off. The launcher and standalone recording action start the engine automatically when this setting requires it, since the engine polls for the deferred stop point.
- Every scene action is a single undo step.

## Current limitations

- Clone and Copy duplicate media items only — envelopes, automation and tempo markers are not copied.
- Copy preserves each source item's `IGUID` and MIDI `POOLEDEVTS` pooled/comping identities while giving the new item its own `GUID`; Clone gives all three identities fresh values, so its content is independent.
- Items that start *before* a scene but overlap into it are not duplicated.
- New scenes are always appended after the last one; there is no insert-between action, and deleting a scene leaves its gap on the timeline.
- Only the last scene can have its length changed.

## Planned

- **Bar-quantized record start** — optionally start recording on the next bar line. Stopping at the end of the current bar is already supported by "Record to end of bar".
