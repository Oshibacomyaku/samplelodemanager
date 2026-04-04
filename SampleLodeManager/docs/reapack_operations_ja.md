# ReaPack 運用メモ（バージョンアップ・index・配布）

このリポジトリでは **`docs/` は `.gitignore` 対象**のため、設計メモの多くはワークスペースの `docs/` にだけあります。  
**ReaPack の実運用の「正」として Git に載せるメモは本ファイル**です。

---

## 1. スクリプトを更新したあと「新しいバージョン」にする手順

ReaPack は **`index.xml` 内の `<version name="…">`** で版を区別します。ユーザーに「アップデートあり」と見せるには、**版名が上がった `<version>` が index に載る**必要があります。

### 手順（このリポジトリの標準）

1. **`SampleLodeManager/SampleLodeManager.lua` のメタヘッダを更新する**
   - **`@version`** … 例: `0.2.0` → `0.2.1`（出したい版に必ず変更する）
   - **`@changelog`** … その版の変更内容（ReaPack の変更履歴に出る）
   - 必要なら **`@about`** なども追随

2. **変更をコミットして `main` に push する**

3. **`index.xml` は基本は自動更新に任せる**
   - `.github/workflows/deploy.yml` が **`main` への push のたび**に `reapack-index --commit --scan SampleLodeManager/SampleLodeManager.lua` を実行し、**`index.xml` を更新したうえで再度 push** します。
   - 数分以内に GitHub 上で **`github-actions[bot]` の `index: …` コミット**が続くか、**Actions の `deploy` ワークフロー**が成功しているか確認してください。

4. **ユーザー側**
   - ReaPack で **Synchronize packages**（または該当リポジトリの更新）を実行すると、新しい `<version>` が取り込まれます。

### よくある失敗

- **`@version` を上げずに push** … index が「同じ版」のまま書き換わるだけで、ReaPack 上で「新リリース」として分かりにくい。
- **`deploy` が失敗** … `index.xml` が古いまま。Actions のログを確認し、手元で Ruby + `reapack-index` を入れたうえで `index.xml` を再生成・push する。

### 旧バージョンを残したい場合

`index.xml` に **古い `<version>` ブロックが残っている限り**、ReaPack からはその版を選べます。`reapack-index` の挙動に任せるか、意図的に古いブロックを消さない運用にします。

---

## 2. ユーザーに伝えるインポート URL

ReaPack の **Import repositories…** に次を登録します（ブランチは `main` の最新 `index.xml` を指します）。

`https://raw.githubusercontent.com/Oshibacomyaku/samplelodemanager/main/index.xml`

登録だけではインストールは終わらず、パッケージの **Install / Synchronize** が必要です。別途 **ReaImGui** など、ルート `README.md` に書いた依存関係も案内してください。

---

## 3. `index.xml` とリポジトリ内のファイルの関係（なぜズレることがあるか）

- **Git 上のファイル**（`SampleLodeManager/...`）と、**ReaPack が見る `index.xml`** は別物です。
- **`index.xml` は `<source>` の URL 一覧**であり、ReaPack はここに無いファイルはダウンロードしません。
- **`deploy` が走るタイミング**は「`main` に push があったとき」なので、**別の bot が先に index だけ更新し、その後に別コミットで `bin/` などが増える**と、**一瞬 index だけ古い**状態になりえます。
- その場合は **`main` にもう一度 push する**（空コミットでも可）か **`deploy` を再実行**して index を再生成するか、**手で `index.xml` を直して push** します。

メタデータの正は **`SampleLodeManager.lua` の `@provides`** と **`@version`** です。`reapack-index` はこれを読んで index を組み立てます。

---

## 4. SQLite（lsqlite3complete）同梱まわり（要点）

- **必須依存**として SQLite ネイティブモジュールを使う。`db_manager.lua` が `lsqlite3` / `lsqlite3complete` / `sqlite3` を順に `require` します。
- **配置**（`SampleLodeManager.lua` が `reaper.GetAppVersion()` で OS を判定し `package.cpath` の先頭に足す）:
  - `bin/win64/lsqlite3complete.dll`
  - `bin/darwin64/lsqlite3complete.so`（Intel Mac）
  - `bin/darwin-arm64/lsqlite3complete.so`（Apple Silicon）
- **ReaPack** では `@provides` に `[win64]` / `[darwin64]` / `[darwin-arm64]` 行があり、`index.xml` の `<source platform="…">` と対応します。
- **Mac 用 `.so` のビルド**は GitHub Actions の **`Bundle lsqlite3complete (macOS)`**（`.github/workflows/bundle-lsqlite-macos.yml`）を **手動実行**（`workflow_dispatch`）。成功すると `bin/darwin*` と `@provides` がコミットされます。
- **詳細・トラブルシュート**は **`SampleLodeManager/bin/README.md`**。
- **Windows 用 DLL** は Lua 5.4 向けに LuaRocks でビルドしたものを `bin/win64/` に置く想定です。`lua54.dll` にリンクしている場合、環境によっては REAPER から解決できないことがあります（補足手順はワークスペースの `docs/install_windows_sqlite.md` などローカル用ドキュメントを参照）。

---

## 5. 作業ログ（2026-04-05 前後に実施したことの要約）

以下は会話・作業の記録用です。細部は Git 履歴と Actions ログが正です。

1. **`bin/` の OS 別レイアウト**と、`SampleLodeManager.lua` 側の **`package.cpath` 組み立て**（Lua 5.4 / REAPER 7 前提）。
2. **Windows 用 `lsqlite3complete.dll`** を `bin/win64/` に同梱し、`@provides [win64]` を追加。
3. **GitHub Actions** で **Intel / Apple Silicon 向け `.so` をビルドしてコミット**するワークフローを追加。初期失敗は **LuaRocks の出力パス誤り**・**Actions Cache / GitHub 一時障害**・**古い `leafo` アクション**などを順に修正（`buildCache: false`、`v12`/`v6`、`find` で `.so` 探索）。
4. **`index.xml` が Mac 同梱コミットより前の時点で更新されていた**ため、**darwin 用 `<source>` が欠けた状態**が一時的に発生。**コミット ID を揃えたうえで darwin 用行を追加**し push して整合。
5. **ユーザーマニュアル**（ワークスペースの `docs/user_manual_*.md` 等）で SQLite を **必須**表現に更新。
6. **`install_windows_sqlite.md`**（ローカル `docs/`）に同梱時の案内を追記。

---

## 6. リリース前チェック（短縮リスト）

- [ ] `SampleLodeManager.lua` の **`@version` / `@changelog`** を更新したか
- [ ] **`@provides`** に不要なファイルが混ざっていないか（`bin` のバイナリは実ファイルと一致させる）
- [ ] `main` push 後 **`deploy` が成功**し `index.xml` が更新されたか
- [ ] `lua -e "assert(loadfile('SampleLodeManager/SampleLodeManager.lua'))"` で構文確認

---

## 7. 関連パス（Git 管理下）

| 内容 | パス |
|------|------|
| SQLite 同梱・Mac ワークフロー | `SampleLodeManager/bin/README.md` |
| 本運用メモ | `SampleLodeManager/docs/reapack_operations_ja.md` |
| ルート説明・依存の一覧 | `README.md` |
| `main` push 時の index 自動更新 | `.github/workflows/deploy.yml` |
| PR 時の reapack-index 検証 | `.github/workflows/check.yml` |
| Mac `.so` ビルド | `.github/workflows/bundle-lsqlite-macos.yml` |
| ReaPack カタログ | `index.xml`（ルート） |

**ワークスペースの `docs/`** にある `reapack_*` や `user_manual_*` は **ローカル用**（`.gitignore`）です。必要なら `git add -f docs/...` で例外追加する運用も可能です。
