# infeasibler ReaScripts

A [ReaPack](https://reapack.com/) repository of REAPER ReaScripts.

## Install via ReaPack

1. In REAPER: **Extensions > ReaPack > Import a repository...**
2. Paste this URL:
   ```
   https://github.com/infeasibler/reaperplugins/raw/main/index.xml
   ```
3. **Extensions > ReaPack > Browse packages...**, find the packages below, right-click **Install**.

## Packages

- **Scenery** (`scenery/`) — scene-based looping toolkit: a launcher panel, scene creation/duplication/navigation actions, a follow-along engine, and bar-quantized recording. See [scenery/README.md](scenery/README.md).

## Other scripts

- **Playtime Bridge** (`playtime_bridge/playtime_bridge.lua`) — standalone script that syncs REAPER's transport with Playtime 2 playback. Not distributed via ReaPack; install manually by copying it into your REAPER Scripts folder and loading it as a ReaScript. See the header comment in the file for configuration and MIDI clock bridge options.

## Packaging

Package metadata follows [reapack-index's Packaging Documentation](https://github.com/cfillion/reapack-index/wiki/Packaging-Documentation). `index.xml` is regenerated automatically by GitHub Actions (`.github/workflows/deploy.yml`) on every push to `main`.
