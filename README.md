# Sample Lode Manager

Sample browser and manager for REAPER.

## Requirements (not bundled)

- ReaPack
- ReaImGui
- SWS Extension
- js_ReaScriptAPI

These dependencies are not bundled in this repository.
Install them via ReaPack before running `SampleLodeManager/SampleLodeManager.lua`.

## Bundled with the ReaPack package (this repo)

The ReaPack distribution also ships **SQLite native bindings** (`lsqlite3complete`) for:

- **Windows x64** — `SampleLodeManager/bin/win64/lsqlite3complete.dll`
- **macOS Intel** — `SampleLodeManager/bin/darwin64/lsqlite3complete.so`
- **macOS Apple Silicon** — `SampleLodeManager/bin/darwin-arm64/lsqlite3complete.so`

Other REAPER builds (for example **Win32** or **Linux**) do not currently ship a bundled binary here; you still need a compatible `lsqlite3` / `lsqlite3complete` / `sqlite3` module loadable from Lua if you use those platforms.

## Entry Script

- `SampleLodeManager/SampleLodeManager.lua`

## ReaPack Distribution

This repository is intended to be published through ReaPack.

The distribution package includes:

- `SampleLodeManager/SampleLodeManager.lua`
- `SampleLodeManager/src/**/*.lua`
- `SampleLodeManager/src/python/**/*.py`
- `SampleLodeManager/licenses/*.txt`
- `SampleLodeManager/bin/**` (platform-specific `lsqlite3complete` binaries declared in `@provides`)

## Third-Party License Notes

Bundled third-party notices are in:

- `SampleLodeManager/licenses/lsqlite3complete_LICENSE.txt` (MIT)
- `SampleLodeManager/licenses/sqlite_PUBLIC_DOMAIN.txt` (SQLite public domain statement)

## Repository Policy

- Local design/dev notes under repository-root `docs/` are excluded from Git by default via `.gitignore` (`/docs/` only).
- Keep runtime/distribution files under `SampleLodeManager/`.
