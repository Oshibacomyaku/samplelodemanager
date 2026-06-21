# Manage Sources「SQLite backend unavailable」調査メモ

報告環境（v0.2.0 ユーザー）:

| 項目 | 値 |
|------|-----|
| OS | Windows 11 x64 |
| REAPER | v7.67 |
| SWS | 2.14.0.7 |
| パッケージ | Sample Lode Manager **v0.2.0** |

症状: **Manage Sources** を開くと `SQLite backend unavailable.` のみ表示され、Splice インポートやルート追加が使えない。

---

## 1. 症状の意味（コード上）

Manage Sources は `state.store.available` と `state.store.conn` を見ています。

```102:104:SampleLodeManager/src/lib/core/ui_pack_manage_sources.lua
    if not state.store.available or not state.store.conn then
      r.ImGui_Text(ctx, "SQLite backend unavailable.")
      r.ImGui_Text(ctx, tostring(state.store.error or ""))
```

`state.store` が開けない典型原因は **2 段階**:

1. **`db_manager.init()` 失敗** — Lua から `require("lsqlite3complete")` 等ができない  
   → `state.db.available == false`
2. **モジュールは読めたが `sqlite_store.open()` 失敗** — DB パス・権限・破損  
   → `state.db.available == true` だが `state.store.available == false`

画像2のダイアログは **(1) のモジュール未検出** が主因です（`SQLite module missing`）。

---

## 2. 想定される根本原因（優先度順）

### A. ReaPack で `bin/win64/lsqlite3complete.dll` が入っていない（v0.2.0 系）

- **v0.2.7 以降**で `@provides [win64 nomain] bin/win64/lsqlite3complete.dll` が明示化。
- **v0.2.0** インストール時点では DLL が配布物に含まれていない／ReaPack が落としていない可能性が高い。
- 画像3で DLL が存在する場合でも、**手動コピー**や**部分アップデート**の可能性あり。

**確認**:  
`{REAPER ResourcePath}\Scripts\...\SampleLodeManager\bin\win64\lsqlite3complete.dll` が存在するか。

### B. `GetAppVersion()` が `/x64` なし → 誤って `bin/win32/` を参照（v0.2.0 エントリ）

旧エントリは `7.67` のように **アーキテクチャ suffix なし**のとき `bin/win32/` を選ぶ実装だった。

- 実際の REAPER は x64
- DLL は `bin/win64/` にある（手動配置含む）
- → `require("lsqlite3complete")` が **win32 パスだけ**を見て失敗

**修正済み（本リポジトリ HEAD）**: Windows では `GetOS()` フォールバック + **win64/win32 両方**を `package.cpath` に prepend。

### C. DLL はあるがロード失敗

- Lua 5.4 / REAPER 7 向けにビルドされていない DLL
- MSVC ランタイム不足
- ウイルス対策ソフトが DLL 読み込みをブロック

この場合 `require` エラーは `module 'lsqlite3complete' not found` ではなく **DLL load error** 系になることもある。

### D. `script_path` の誤り

エントリ Lua の `get_script_path()` が空 → `package.cpath` に `bin/win64/` が載らない。  
ReaPack 配置では通常問題にならないが、シンボリックリンク経由実行などでは要確認。

---

## 3. ユーザー側クイックチェック

1. ReaPack で **最新版（0.2.7+）に更新**し、`bin/win64/lsqlite3complete.dll` があるか確認
2. REAPER 再起動
3. まだダメなら **ReaPack → パッケージ再インストール**（上書き）
4. Manage Sources を再度開き、2 行目のエラー全文を控える

---

## 4. 開発者向けデバッグ手順

### 4.1 一時診断 ReaScript（REAPER アクションに登録して実行）

```lua
-- @noindex
local r = reaper
local function line(s) r.ShowConsoleMsg(tostring(s) .. "\n") end

line("GetAppVersion: " .. tostring(r.GetAppVersion and r.GetAppVersion() or "?"))
line("GetOS: " .. tostring(r.GetOS and r.GetOS() or "?"))
line("package.cpath:")
for p in string.gmatch(package.cpath or "", "[^;]+") do
  if p:find("SampleLodeManager") or p:find("lsqlite") or p:find("win64") then
    line("  " .. p)
  end
end

for _, name in ipairs({ "lsqlite3", "lsqlite3complete", "sqlite3" }) do
  local ok, err = pcall(require, name)
  line(string.format("require(%q): %s %s", name, ok and "OK" or "FAIL", ok and "" or tostring(err)))
end

local ok, dbm = pcall(require, "lib.db.db_manager")
if ok and dbm.init then
  dbm.init()
  local st = dbm.get_status()
  line("db_manager: " .. tostring(st.available) .. " module=" .. tostring(st.module_name))
  if st.error then line(st.error) end
end
```

※ エントリと同じ `package.path` / `package.cpath` 設定を先に行うか、Sample Lode Manager 起動直後にコンソールログを見る。

### 4.2 関連ソース

| ファイル | 役割 |
|----------|------|
| `oshibacomyaku_Sample Lode Manager.lua` | `package.cpath` に `bin/<platform>/` を prepend |
| `src/lib/db/db_manager.lua` | `require` 候補とエラー集約 |
| `src/lib/core/app.lua` | `init_state` で DB オープン |
| `bin/README.md` | プラットフォーム別 DLL 配置 |

---

## 5. データファイル配置（2026-06 以降）

リソースフォルダ直下の散らかりを減らすため、次のレイアウトに変更済み:

```
{REAPER ResourcePath}/
  SampleLodeManager/
    SampleLodeManager.sqlite      ← メイン DB（旧: 直下にあったファイルは初回起動時に移行）
    SampleLodeManager.sqlite-wal
    work/                         ← Python 用 TSV（処理後削除）
      phase_a_in.tsv  …（一時的）
      wave_tmp/                   ← 波形プレビュー用コピー
```

**ユーザーが手動削除してよいもの**

- 直下の `SampleLodeManager_phase_*.tsv` / `ReaSampleManager_*`（レガシー）
- `SampleLodeManager/work/` 内（実行中以外）

**消さない**

- `SampleLodeManager/SampleLodeManager.sqlite`（または移行前の直下 DB）

---

## 6. 次チャット用プロンプト（コピペ用）

```
Sample Lode Manager v0.2.0 ユーザーが Manage Sources で「SQLite backend unavailable」になる不具合を調査・修正してください。

環境: Win11 x64, REAPER 7.67, SWS 2.14.0.7
症状: Manage Sources が SQLite 無効。起動時に「SQLite module missing」ダイアログ（lsqlite3/lsqlite3complete/sqlite3 すべて not found）。
参考: bin/win64/lsqlite3complete.dll は Everything 検索では存在する場合あり。

まず docs/DEBUG_ManageSources_SQLite_ja.md と以下を読んでください:
- oshibacomyaku_Sample Lode Manager.lua（package.cpath / GetAppVersion 判定）
- src/lib/db/db_manager.lua
- bin/README.md

仮説:
1) v0.2.0 時点で ReaPack が DLL を同梱していない
2) GetAppVersion が /x64 なし → bin/win32 を参照して DLL 未検出
3) DLL ロード失敗（ランタイム・ビルド不一致）

やること:
- 再現条件の切り分け（script_path, cpath, DLL 実在）
- 必要ならエントリのプラットフォーム判定・エラーメッセージ・起動時診断の改善
- ReaPack @provides / バージョン要件の明記
- 修正後 docs 更新
```

---

## 7. 修正履歴（本リポジトリ）

| 変更 | 内容 |
|------|------|
| エントリ Lua | Windows で win64/win32 両方 cpath、GetOS フォールバック |
| `db_manager.lua` | 3 モジュール分のエラーを `\n` 連結で表示 |
| `resource_paths.lua` | DB / work サブフォルダ化、TSV 処理後削除 |
| 本ドキュメント | 調査手順・次チャット用プロンプト |
| **2026-06-22**: エントリ Lua | 起動直後に SQLite モジュールを試し、全失敗時のみ「ReaPack で 0.2.7+ に更新」MB を表示（成功時は無音） |

---

## 8. 2026-06-22 調査結論

### 結論

v0.2.0 ユーザーで「SQLite backend unavailable」が出る主因は

> **v0.2.0 当時の ReaPack パッケージに `lsqlite3complete.dll` が同梱されていなかった**

ことだと特定。git 履歴上、Windows 用 DLL は **2026-04-05 (commit `24f190f`)** で追加され、`@provides [win64 nomain] bin/win64/lsqlite3complete.dll` の明示は **v0.2.7 (commit `ac24b94`)** で入った。つまり **v0.2.0 を ReaPack でインストールしたユーザーには DLL が配布されていない**。

リポジトリ HEAD（v0.2.8 系）の状態:

| 項目 | 状態 |
|------|------|
| `SampleLodeManager/bin/win64/lsqlite3complete.dll` | コミット済み（追跡されている） |
| エントリ Lua の `@provides` で DLL を宣言 | 済 |
| Windows で win64/win32 両 `package.cpath` を prepend | 済 |
| 3 モジュールの require エラーをまとめて表示 | 済 |
| **起動時 SQLite 検出 + MB 案内** | 本コミットで追加 |

### v0.2.0 ユーザー向け確定手順

1. **REAPER → Extensions → ReaPack → Browse packages...**
2. `Sample Lode Manager` を検索 → 右クリック → **Install version → Latest** で 0.2.8 を選択
3. ReaPack を **Apply**
4. REAPER を **再起動**
5. Sample Lode Manager 起動 → 起動時の「SQLite module missing」MB が **出ない**ことと Manage Sources が動作することを確認

更新後も MB が出る場合は、MB 本文の `expected dll` のパスに DLL が実在するかを確認し、無ければ ReaPack の「Reinstall」を実行する。

### 起動時診断（本コミットで追加）

エントリ Lua（`oshibacomyaku_Sample Lode Manager.lua`）が `lsqlite3 / lsqlite3complete / sqlite3` の **すべての require に失敗**した場合のみ、起動直後に MB を 1 回表示する。成功している環境では何も表示しない（既存ユーザーへの影響なし）。

MB 本文には:

- 推奨行動（ReaPack で v0.2.7+ に更新）
- 期待される DLL のフルパス（`{script_path}bin/win64/lsqlite3complete.dll`）
- 試した 3 モジュール名

を含む。MB を閉じればアプリは継続起動し、Manage Sources では従来通り `SQLite backend unavailable.` + エラー詳細を表示する。

---

## 9. 付随して見つかった派生問題（本不具合とは別）

調査中に下記を確認。**今回の修正範囲外**だが、次のリリース前に判断が必要。

- `oshibacomyaku_Sample Lode Manager.lua` の `@provides [nomain] src/lib/core/resource_paths.lua` が宣言されているが、ファイルが git 未追跡で main にも本ブランチ HEAD にもコミットされていない。
- `src/lib/core/app.lua` が `lib.core.ext_state` / `lib.core.key_bpm_utils` / `lib.core.ui_imgui_utils` を `pcall(require, ...)` で参照しているが、対応ファイルが未追跡。
- すべて `pcall` ラップなので起動はクラッシュしないが、機能（リソースパス整理・ext_state・BPM 補助等）は配布版で欠落する。
- 加えて `@provides` に存在しないパスがあると、`reapack-index --check`（`.github/workflows/check.yml`）が落ちるはず。CI が通っているのは未コミットファイルが index に渡っていないため。

**判断オプション**（次リリースで対応）:

- **(a) 揃える**: `resource_paths.lua` / `ext_state.lua` / `key_bpm_utils.lua` / `ui_imgui_utils.lua` を `git add` し、必要なら `@provides` を追加 → 次バージョンとして配布。
- **(b) 取り下げる**: 当該機能を一旦リリースから外す。`@provides` の `resource_paths.lua` 行を削除し、`app.lua` の `pcall(require, ...)` も該当ブロックごと削除して整合。

---

関連: [PROJECT_OVERVIEW_ja.md](./PROJECT_OVERVIEW_ja.md), [bin/README.md](../bin/README.md)
