# Sample Lode Manager

Sample browser and manager for REAPER.

## Requirements (not bundled)

- ReaPack
- ReaImGui
- SWS Extension
- js_ReaScriptAPI

These dependencies are not bundled in this repository.
Install them via ReaPack before running `SampleLodeManager.lua`.

## Entry Script

- `SampleLodeManager.lua`

## ReaPack Distribution

This repository is intended to be published through ReaPack.

The distribution package includes:

- `SampleLodeManager.lua`
- `src/**/*.lua`
- `src/python/**/*.py`
- `licenses/*.txt`

## Third-Party License Notes

Bundled third-party notices are in:

- `licenses/lsqlite3complete_LICENSE.txt` (MIT)
- `licenses/sqlite_PUBLIC_DOMAIN.txt` (SQLite public domain statement)

## Repository Policy

- Local design/dev notes under `docs/` are excluded from Git by default via `.gitignore`.
- Keep runtime/distribution files in repository root, `src/`, and `licenses/`.
