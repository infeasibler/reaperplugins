# Scenery

Scene-based looping for REAPER. A "scene" is any project region — name it whatever you like (create/rename regions directly on the timeline or in the Region Manager). Creating a scene via Scenery appends a new region after the last one, named `Scene N` where `N` is simply the current region count + 1; it sets the loop points to it and applies the auto-repeat setting (enabled by default), so you can build an arrangement one loop at a time without touching the timeline by hand.

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
| `Scenery - Clone current scene` | Creates a scene of the configured length with fully independent item copies, appending it or inserting it after the current scene according to the setting. |
| `Scenery - Copy current scene` | Creates a scene of the configured length with linked item copies, appending it or inserting it after the current scene according to the setting. Editing pooled MIDI/audio content in either scene affects the other. |
| `Scenery - Go to next scene` / `Scenery - Go to previous scene` | Moves the loop to the neighbouring scene. |
| `Scenery - Toggle link with next scene` | Links or unlinks the active scene with its immediate successor, so the engine can loop the linked scenes as one range. |
| `Scenery - Toggle auto repeat` | Enables or disables forcing REAPER's transport repeat on when a scene starts or switches. |
| `Scenery - Toggle record lead-in` / `Scenery - Toggle record lead-out` | Preserve material before or after the phrase-aligned loop source when auto-looping new recordings. |
| `Scenery - Toggle insert after current scene` | Enables or disables inserting Clone/Copy results immediately after the source scene instead of appending them at the end. |
| `Scenery - Settings` | Default scene length, region colour, auto-follow on/off, record auto-loop on/off, lead-in/out on/off, record-to-end-of-phrase on/off, auto-repeat on/off, insert-after-current on/off, waiting for the current scene to end when launching, phrase wait length, and an exposed Clone/Copy option to skip occupied destination tracks (not currently implemented; see [issue #1](https://github.com/infeasibler/reaperplugins/issues/1)). The launcher settings also include destructive-action confirmation and REAPER's Smooth seek preference. |
| `Scenery - Toggle record (quantized)` | Starts/stops recording immediately, same as REAPER's native Record command, but also makes sure the engine is running so new items get bar-aligned afterwards. Handy as a bindable equivalent to the launcher's `Rec` button. |
| `Scenery - Engine (toggle)` | Background service that keeps the loop on the scene, or its linked chain, under the cursor and handles recording post-processing. Run again to stop. The launcher and standalone recording action start it automatically when needed. |

## Behaviour notes

- Scene lengths follow the project tempo and time-signature map, so 8 bars stays 8 bars across meter changes.
- Auto-repeat is enabled by default: starting or switching to a scene forces REAPER's transport repeat on. Disable it in Settings, the Launcher, or with `Scenery - Toggle auto repeat` when scene changes should not force looping.
- Switching scenes from the launcher moves the loop points and seeks immediately by default; enable "Wait for scene end when launching" to defer single-click launches until the current linked scene chain ends. Double-clicking always switches immediately. When scene-end waiting is off, "Phrase length" is measured in bars and uses human 1-based counting: 0 and 1 switch immediately, while values 2 and above wait for the end of the current phrase of that length. For example, 4-bar phrases are bars 1-4, 5-8, 9-12, and so on. "Smooth seek" in the launcher's Settings can additionally quantize the audible transition to the next bar/measure.
- When "Loop follows cursor" is off, moving the edit cursor into another scene does not change the active scene; launching a scene from the Launcher still changes it explicitly.
- Creating a scene never moves the play cursor. If the transport is rolling, playback continues and wraps into the new loop when it reaches it — the engine holds off auto-follow until then.
- Scene regions can be renamed to anything via the launcher's Rename... or directly in the Region Manager; Scenery never rewrites an existing scene's name. Its position number (used for next/previous navigation) is always computed from timeline order, not stored in the name.
- New/Clone/Copy name the region they create `Scene N`, where `N` is the region count at the time of creation — so numbering stays sensible even if earlier regions have been freely renamed.
- When "Insert copies after current scene" is enabled, Clone and Copy make room immediately after the source scene by shifting later project markers, regions, and media items to the right. The setting is shared by the Launcher and standalone Clone/Copy actions.
- New scenes are always appended after the last one; Clone/Copy can optionally insert after the current scene, and deleting a scene leaves its gap on the timeline.
- Linking a scene to its immediate successor makes the engine loop the whole consecutive chain as one range. The launcher's Merge linked scenes command collapses that chain into one region without moving its items.
- When the engine is running and record auto-loop is enabled, each recording pass snapshots existing item GUIDs. New items recorded inside the active scene are moved to the containing bar, then linked pooled copies are created through the scene so editing one repeated bar changes them all.
- Record lead-in and lead-out are off by default and only affect recordings when auto-loop is enabled. They preserve recorded material before or after the phrase-length loop unit; each repeated item is positioned so its phrase anchor remains aligned. Overlapping MIDI items play together, while audio overlap follows REAPER's configured Item mix behavior (mix, replace, or crossfade).
- With record auto-loop enabled and the engine running, the launcher's `Rec` button, the `Toggle record (quantized)` action, and REAPER's native Record button/shortcut all start and stop recording immediately. With lead-in/out disabled, the recorded item is bar-aligned and linked pooled copies fill the rest of the scene. When either lead option is enabled, a pre-scene pickup anchors at the scene start; otherwise the source anchors at the next configured phrase boundary and repeats at that phrase length. The launcher and standalone action start the engine automatically; native Record requires the engine to already be running for this processing.
- "Record to end of phrase" (on by default) is independent of auto-loop: when stopping a recording, it delays the actual stop until just past the next project-aligned phrase boundary, using the configured phrase length (treated as at least one bar), so nothing is lost even if auto-loop is off. The launcher and standalone recording action start the engine automatically when this setting requires it, since the engine polls for the deferred stop point.
- Every scene action is a single undo step.

## Current limitations

- Clone and Copy duplicate media items only — envelopes, automation and tempo markers are not copied.
- Copy preserves each source item's `IGUID` and MIDI `POOLEDEVTS` pooled/comping identities while giving the new item its own `GUID`; Clone gives all three identities fresh values, so its content is independent.
- Items that start *before* a scene but overlap into it are not duplicated.
- New scenes are always appended after the last one; there is no insert-between action, and deleting a scene leaves its gap on the timeline.
- Only the last scene can have its length changed.
- Settings currently exposes "Skip occupied tracks when copying," but Clone and Copy do not yet honor it; see [issue #1](https://github.com/infeasibler/reaperplugins/issues/1).

## Planned

- **Bar-quantized record start** — optionally start recording on the next bar line. Stopping at the configured phrase boundary is already supported by "Record to end of phrase".
