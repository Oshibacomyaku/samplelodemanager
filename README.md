# Sample Lode Manager

Sample browser and manager for REAPER.

## Requirements (not bundled)

- ReaPack
- ReaImGui
- SWS Extension
- js_ReaScriptAPI

These dependencies are not bundled in this repository.
Install them via ReaPack before running `SampleLodeManager/SampleLodeManager.lua`.

## Entry Script

- `SampleLodeManager/SampleLodeManager.lua`

## ReaPack Distribution

This repository is intended to be published through ReaPack.

Japanese notes for versioning, `index.xml`, and distribution workflow: `SampleLodeManager/docs/reapack_operations_ja.md`.

The distribution package includes:

- `SampleLodeManager/SampleLodeManager.lua`
- `SampleLodeManager/src/**/*.lua`
- `SampleLodeManager/src/python/**/*.py`
- `SampleLodeManager/licenses/*.txt`

## Third-Party License Notes

Bundled third-party notices are in:

- `SampleLodeManager/licenses/lsqlite3complete_LICENSE.txt` (MIT)
- `SampleLodeManager/licenses/sqlite_PUBLIC_DOMAIN.txt` (SQLite public domain statement)

## Repository Policy

- Local design/dev notes under repository-root `docs/` are excluded from Git by default via `.gitignore` (`/docs/` only). Tracked docs such as `SampleLodeManager/docs/` are versioned normally.
- Keep runtime/distribution files under `SampleLodeManager/`.
