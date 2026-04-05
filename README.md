# Sample Lode Manager

Sample browser and manager for REAPER.

## Requirements (not bundled)

- ReaPack
- ReaImGui
- SWS Extension
- js_ReaScriptAPI

These dependencies are not bundled in this repository.
Install them via ReaPack before running `SampleLodeManager/oshibacomyaku_Sample Lode Manager.lua`.

## Bundled with the ReaPack package (this repo)

The ReaPack distribution also ships SQLite native bindings (`lsqlite3complete`) for:

- Windows x64 — `SampleLodeManager/bin/win64/lsqlite3complete.dll`
- macOS Intel — `SampleLodeManager/bin/darwin64/lsqlite3complete.so`
- macOS Apple Silicon — `SampleLodeManager/bin/darwin-arm64/lsqlite3complete.so`

Other REAPER builds (for example Win32 or Linux) do not currently ship a bundled binary here; you still need a compatible `lsqlite3` / `lsqlite3complete` / `sqlite3` module loadable from Lua if you use those platforms.

The entry script prepends `SampleLodeManager/bin/<platform>/` to Lua’s `package.cpath` and then `require`s the native module. It does not load “LuaRocks into REAPER” as a whole — it only adds optional user paths so a manually built DLL/SO can be found if you installed one yourself.

## Entry Script

- `SampleLodeManager/oshibacomyaku_Sample Lode Manager.lua` (ReaTeam-style name: `author_Action name here.lua`; `@author` is used by ReaPack metadata; appears in Actions as Script: oshibacomyaku_Sample Lode Manager.lua)

## ReaPack Distribution

This repository is intended to be published through ReaPack.

The distribution package includes:

- `SampleLodeManager/oshibacomyaku_Sample Lode Manager.lua`
- `SampleLodeManager/src/**/*.lua`
- `SampleLodeManager/src/python/**/*.py`
- `SampleLodeManager/licenses/*.txt`
- `SampleLodeManager/bin/**` (platform-specific `lsqlite3complete` binaries declared in `@provides`)

## Third-Party License Notes

The prebuilt `lsqlite3complete` binaries in `SampleLodeManager/bin/` are Lua bindings that typically link against or embed SQLite. In this repository we ship full license texts next to the script (ReaPack installs them with the package):

- `SampleLodeManager/licenses/lsqlite3complete_LICENSE.txt` — MIT (applies to the lsqlite3complete binding code as packaged on LuaRocks; redistribution generally requires keeping that notice with the software).
- `SampleLodeManager/licenses/sqlite_PUBLIC_DOMAIN.txt` — short statement aligned with SQLite’s public-domain dedication (see also [sqlite.org/copyright](https://www.sqlite.org/copyright.html)).

If you rebuild the native module from other sources, replace or amend these files so they match your actual upstream, and keep distributing the corresponding notices with the binaries.

This section is not legal advice; when in doubt, confirm with your own counsel or upstream terms.

## Repository Policy

- Local design/dev notes under repository-root `docs/` are excluded from Git by default via `.gitignore` (`/docs/` only).
- Keep runtime/distribution files under `SampleLodeManager/`.
- Short Japanese notes on Git commit / pull / push: `SampleLodeManager/docs/git_basics_ja.md`.
