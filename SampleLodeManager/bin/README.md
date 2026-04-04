# Bundled SQLite (lsqlite3complete) — Lua 5.4 / REAPER 7+

ReaPack の **バージョン上げ・`index.xml`・インポート URL** などの全体運用は、**`SampleLodeManager/docs/reapack_operations_ja.md`** にまとめてあります。

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

- **ログに `leafo/gh-actions-lua@v10` / `v5` と出ている**  
  **古い `bundle-lsqlite-macos.yml` で動いています。** `main` を pull したうえで、もう一度 **Run workflow** してください（現在は **v12 / v6**、`gh-actions-lua` は **Node 24** ランタイム）。
- **`Failed to save` / `Our services aren't available` / `Cache service responded with 400`**  
  GitHub 側の **キャッシュ API の一時障害**です。時間をおいて再実行するか、ワークフローで **`buildCache: false`**（Lua を毎回コンパイル、キャッシュに頼らない）にしてあります。
- **`luarocks install` は通ったが `.so` が見つからない**  
  LuaRocks が **`$HOME/.luarocks` ではなく `.luarocks/`** に入れることがあります。`find` で探索するようになっています。

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
