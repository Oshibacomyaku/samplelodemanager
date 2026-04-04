# Bundled SQLite (lsqlite3complete) — Lua 5.4 / REAPER 7+

Place **one** native module per folder (built against **REAPER’s embedded Lua 5.4**, same OS ABI as the user’s REAPER install):

| Folder | `reaper.GetAppVersion()` hint | Expected file | ReaPack `platform` |
|--------|------------------------------|---------------|--------------------|
| `win64/` | contains `/x64` | `lsqlite3complete.dll` | `win64` |
| `win32/` | version like `7.67` only (no `/x64`) | `lsqlite3complete.dll` | `win32` |
| `darwin64/` | contains `OSX64` | `lsqlite3complete.so` | `darwin64` |
| `darwin-arm64/` | contains `macOS-arm64` | `lsqlite3complete.so` | `darwin-arm64` |
| `linux-x86_64/` | contains `linux` and `x86_64` / `i686` handling | `lsqlite3complete.so` | `linux64` |
| `linux-aarch64/` | contains `linux` and `aarch64` | `lsqlite3complete.so` | `linux-aarch64` |

`SampleLodeManager.lua` prepends the matching `bin/<platform>/` path to `package.cpath` before generic `bin/?.dll` / `bin/?.so`.

## macOS バイナリをリポジトリに足す（GitHub Actions）

Windows 用 DLL は開発マシンで `luarocks install lsqlite3complete` して `bin/win64/` に置けます。  
Intel / Apple Silicon 用 `.so` は GitHub 上で次を実行してください。

1. リポジトリ **Actions** → **Bundle lsqlite3complete (macOS)** → **Run workflow**
2. 成功すると `bin/darwin64/` と `bin/darwin-arm64/` に `lsqlite3complete.so` がコミットされ、`SampleLodeManager.lua` の `@provides` に darwin 行が追記されます。

`macos-15-intel` ランナーが使えない場合はワークフローの `matrix.runner` を調整するか、該当アーキ向けに手元でビルドして同じパスに配置してください。

### ワークフローが失敗したとき（よくある原因）

- **`luarocks install` は通ったが `test -f $HOME/.luarocks/...` で落ちる**  
  GitHub Actions 上の LuaRocks は **`$HOME/.luarocks` ではなく作業ディレクトリの `.luarocks/`** に `.so` を置くことがあります。現在の `bundle-lsqlite-macos.yml` は `find` で探索するよう修正済みです。
- **`leafo/gh-actions-lua@v10` の Node 非推奨**  
  `@v12` / `gh-actions-luarocks@v6` に上げてあります。まだ失敗する場合は該当ジョブのログ全文（`luarocks install` のコンパイルエラー行）を確認してください。

## ReaPack (`reapack-index`): when binaries are committed

Add multiline `@provides` on the main script (each line must reference a **real** file or `reapack-index --check` fails):

```lua
-- @provides
--   [win64 nomain] bin/win64/lsqlite3complete.dll
--   [darwin64 nomain] bin/darwin64/lsqlite3complete.so
--   [darwin-arm64 nomain] bin/darwin-arm64/lsqlite3complete.so
```

Optional Linux:

```lua
--   [linux64 nomain] bin/linux-x86_64/lsqlite3complete.so
--   [linux-aarch64 nomain] bin/linux-aarch64/lsqlite3complete.so
```

See also `docs/reapack_index_xml_example.md` and `docs/install_windows_sqlite.md` (build hints).
