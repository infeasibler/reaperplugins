# Looptastic

Scene-based looping for REAPER. A "scene" is a project region named `Scene 1`, `Scene 2`, … Creating a scene appends it after the last one, sets the loop points to it and enables repeat — so you can build an arrangement one loop at a time without touching the timeline by hand.

## Install

1. In REAPER: **Options > Show REAPER resource path in explorer/finder**, then open the `Scripts` folder.
2. Copy the whole `looptastic` folder into it. `looptastic_lib.lua` must stay alongside the action scripts.
3. **Actions > Show action list > New action > Load ReaScript…**, and load each `Looptastic - *.lua` file (not the `_lib` file).
4. Assign keyboard shortcuts or toolbar buttons to the actions you use.

## Actions

| Action | What it does |
| --- | --- |
| `Looptastic - Launcher` | Scene launcher panel. Left-click or double-click switches to a scene immediately, right-click renames/resizes/duplicates/deletes (with or without its items). Also has new/duplicate, transport and settings. |
| `Looptastic - New scene` | Appends a scene of the default length (8 bars) and loops it. |
| `Looptastic - New scene (custom bars)` | Same, but prompts for the bar count. |
| `Looptastic - Duplicate current scene` | Appends a scene of the same length and copies the current scene's items into it. |
| `Looptastic - Go to next scene` / `previous scene` | Moves the loop to the neighbouring scene. |
| `Looptastic - Toggle record (quantized)` | Starts/stops recording immediately, same as REAPER's native Record command, but also makes sure the engine is running so new items get bar-aligned afterwards. Handy as a bindable equivalent to the launcher's `Rec` button. |
| `Looptastic - Settings` | Default scene length, region colour, auto-follow on/off, and record auto-loop on/off. |
| `Looptastic - Engine (toggle)` | Background service that keeps the loop on the scene under the cursor and bar-aligns new recordings. Run again to stop. The launcher starts it automatically. |

## Behaviour notes

- Scene lengths follow the project tempo and time-signature map, so 8 bars stays 8 bars across meter changes.
- Switching scenes from the launcher moves the loop points and seeks immediately; enable "Smooth seek" in Settings for REAPER to quantize the audible transition to the next bar/measure instead of cutting instantly.
- Creating a scene never moves the play cursor. If the transport is rolling, playback continues and wraps into the new loop when it reaches it — the engine holds off auto-follow until then.
- Scene regions can carry a label after the number (`Scene 3 Chorus`); renumbering keeps the label.
- Scene regions are renumbered by timeline position whenever a scene is created, so deleting a region in the Region Manager tidies itself up on the next action.
- When the engine is running and record auto-loop is enabled, each recording pass snapshots existing item GUIDs. New items recorded inside the active scene are moved to the containing bar, set to loop their source, and extended to the scene end when recording stops.
- With record auto-loop enabled, the launcher's `Rec` button, the `Toggle record (quantized)` action, and REAPER's native Record button/shortcut all behave the same way: recording starts and stops immediately. Afterwards, the recorded item's start is trimmed forward to the next bar boundary (cutting off the pickup before the first full bar) and its end is rounded up to a bar boundary before it is set to loop through the scene.
- Every scene action is a single undo step.

## Current limitations

- Duplicate copies media items only — envelopes, automation and tempo markers are not copied.
- Items that start *before* a scene but overlap into it are not duplicated.
- New scenes are always appended after the last one; there is no insert-between action, and deleting a scene leaves its gap on the timeline.
- Only the last scene can have its length changed.

## Planned

- **Bar-quantized record** — start recording on the next bar line, and delay stopping until the end of the current bar.
