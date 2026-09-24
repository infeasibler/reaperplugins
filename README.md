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

## Tests

Run the Scenery library tests with Lua 5.4:

```powershell
lua tests/scenery_lib_test.lua
```

If Lua is not installed, Node.js and npm can run the suite through Fengari without adding project dependencies:

```powershell
npx --yes --package=fengari-node-cli fengari tests/scenery_lib_test.lua
```

These tests cover Scenery logic using a small fake REAPER API; host behavior still needs verification in REAPER.

## Packaging

`index.xml` is maintained as a static text file. When releasing a new version, update the package version, changelog, and source URLs in the index alongside the script metadata.
