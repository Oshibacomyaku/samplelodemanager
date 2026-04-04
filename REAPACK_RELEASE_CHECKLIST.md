# ReaPack Release Checklist

Use this checklist before each release.

## 1) Versioning

- [ ] Update `@version` in `SampleLodeManager.lua`
- [ ] Update `@changelog` in `SampleLodeManager.lua`

## 2) Distribution Scope

- [ ] `@provides` only includes runtime files
- [ ] `docs/` is not included in `@provides`
- [ ] `licenses/*.txt` is included in `@provides`

## 3) Dependency Notes

- [ ] README still lists required external dependencies:
  - ReaPack
  - ReaImGui
  - SWS
  - js_ReaScriptAPI

## 4) ReaPack Index

- [ ] Regenerate `index.xml`:
  - `reapack-index --rebuild -o index.xml .`
- [ ] Confirm `index.xml` is in repository root

## 5) Final Validation

- [ ] Syntax check:
  - `lua -e "assert(loadfile('SampleLodeManager.lua'))"`
- [ ] Commit and push changes
- [ ] Verify ReaPack import URL:
  - `https://raw.githubusercontent.com/<YOUR_USER>/<YOUR_REPO>/main/index.xml`
