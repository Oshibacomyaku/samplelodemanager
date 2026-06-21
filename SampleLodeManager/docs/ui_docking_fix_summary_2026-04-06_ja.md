# UI ドッキング／ImGui スタック不具合の修正まとめ（2026-04-06）

## 1. 目的

`Sample Lode Manager`（ReaImGui）で、ドッキングやウィンドウ状態の変化に伴い発生していた次のような症状を解消する。

- `ImGui_End: Calling End() too many times!`
- `ImGui_EndChild: Assertion failed`（非表示 child に対する `EndChild` など）
- それに続く `ImGui_PopStyleVar` / `PopStyleColor` の `expected a valid ImGui_Context*`

調査過程のメモは、リポジトリ直下の `docs/ui_docking_error_summary_2026-04-06_ja.md`（※このリポジトリでは `/docs/` が `.gitignore` 対象のため Git には含まれない場合があります）にあります。本ファイルは **GitHub に含められる場所**（`SampleLodeManager/docs/`）に置いています。

---

## 2. 症状の本質

ImGui は **Begin／End、Push／Pop、BeginChild／EndChild** などがスタックとして対応している必要があります。1 フレームでも **余分な `End` / `EndChild`** が走ると、メインウィンドウの `End` まで連鎖的に壊れ、`ctx` 無効化やスタイル Pop の失敗につながります。

特に **「`BeginChild` の戻り値が `false`（非表示）なのに `EndChild` を呼ぶ」** と、環境によっては assertion やスタック不整合が起きることが分かりました。

---

## 3. 確定した主因（今回の決定打）

**`ui_pack.lua` の Active packs 横スクロール用子ウィンドウ（`##pack_active_strip`）**

- `begin_child_safe` は `BeginChild` が成功すると `begun=true` だが、**`visible` は `false` になり得る**。
- クリーンアップが `end_child_safe(child_begun)` のみだったため、**非表示のときも `EndChild` が実行され、親の `##pack_section` を 1 段多く閉じてしまう** 可能性があった。
- その結果、外側の `pack_section` の `EndChild` が **メインウィンドウ側まで pop してしまい**、後続の `search` / `samples_list` / `detail` で `BeginChild` が一斉に非表示扱いになり、最終的に **`Main ImGui_End` が「End が多すぎる」** と報告する流れになっていた（ログ上でも `pack EndChild` 直後にウィンドウサイズが不自然に変化するパターンが観測された）。

**修正（維持している変更）**

- `end_child_safe(child_begun and active_strip_visible)` に変更し、**非表示のときは `EndChild` しない**。

---

## 4. その他に行った対策（要点）

以下は、同種の「非表示 child と `EndChild`」や、メインウィンドウ契約の整理として `app.lua` および各 UI モジュールで実施したものです（計測用コードは後述のとおり削除済み）。

| 領域 | 内容の要約 |
|------|------------|
| メインウィンドウ | `Begin` がウィンドウを持たない／非表示のときの `End` を条件付きにし、`safe_end_window` で集約 |
| `search` / `detail` / `samples_list` 等 | `BeginChild` が非表示のときは **`EndChild` をスキップ**（以前の assertion 対策） |
| `ui_pack_manage_sources` | モーダル内の Tab／子領域など、`ImGui` 呼び出しの `pcall` 化や、設定パス一覧の `EndChild` を可視時のみに |
| `ui_pack.lua` | テーブル描画の `pcall`、子ウィンドウの safe ヘルパー利用の整理 など |

---

## 5. デバッグ用計測について

調査中は `debug-380ad7.log`（NDJSON）への書き込みや `H1`〜`H34` などのログ呼び出しを多数挿入していましたが、**問題解消の確認後、計測コードはすべて削除済み**です。

運用上、REAPER が古いスクリプトを動かしているとログファイルが再生成されることがあるため、**コミット対象に含めない**こと。

---

## 6. 変更の主なファイル

- `SampleLodeManager/src/lib/core/app.lua` — メインループ、各セクションの `BeginChild`/`EndChild` 条件、エラー時の整理
- `SampleLodeManager/src/lib/core/ui_pack.lua` — **Active strip の `EndChild` 条件（本件の核）**、周辺の安全化
- `SampleLodeManager/src/lib/core/ui_pack_manage_sources.lua` — モーダル内の ImGui 呼び出し保護・子ウィンドウ対称性
- `SampleLodeManager/src/lib/core/ui_samples_list.lua` — リスト子ウィンドウの `EndChild` 条件
- その他 `ui_search.lua` / `ui_samples_galaxy.lua` など（同系のガード・対称性）

---

## 7. GitHub にプッシュしてよいか

**コード変更（上記 Lua ファイル）はプッシュして問題ありません。** 不具合修正として意味のある差分です。

次だけ守ると安全です。

1. **`debug-380ad7.log` をコミットに含めない**  
   サイズが巨大になりやすく、個人パスや実行環境に依存する情報も混ざり得ます。リポジトリ直下の `.gitignore` に `debug-380ad7.log`（または `debug-*.log`）を追加済みの場合は、そのまま無視されます。
2. **`git status` で意図したファイルだけがステージされているか確認**してから `git commit`。
3. 既存ブランチ方針（例: `fix/ui-restart-...`）に合わせて PR を出すとレビューしやすいです。

---

## 8. 再発時の見方

同種のエラーが出たら、まず **「直前に `BeginChild` が `false` だったのに `EndChild` していないか」** を疑う。特に **ネストした `BeginChild`（strip → section → main）** の境界で、内側の `visible` と `EndChild` の対応を確認する。

---

## 9. 追記（リファクタ／軽量化・2026-05）

- **`lib.core.ui_imgui_utils`**：`BeginChild`／`EndChild` を `begun and visible` で対称にまとめる `begin_child_safe` / `end_child_safe` / `with_child`。`app.lua` のパック／検索セクション、`ui_samples_list`／`ui_samples_galaxy`／`ui_search`（タグサジェスト）、既存の `ui_pack`／`ui_pack_manage_sources` で利用。
- **`lib.core.ext_state`** / **`lib.core.key_bpm_utils`**：`app.lua` から ExtState 周りとキー／BPM 文字列ユーティリティを小さく分離。
- **パフォーマンス**
  - **ギャラクシー**: `prewarm_galaxy_points_cache_step` は **ギャラクシータブ以外**のときだけ走る（ギャラクシー表示中は `ui_samples_galaxy` 側の `get_cached_galaxy_points` と二重にディスク／CPU を食わないため）。
  - **パックフィルタ**: `filter_pack_ids` のメンバーシップを **`state.runtime.filter_pack_id_set` キャッシュ**（変更時に無効化）。
  - **パック一覧**: `reload_pack_lists` は **`pack_lists_reload_requested` により 1 フレーム 1 回まで**フラッシュ（同一フレーム内の複数要求を `get_packs`×2 に圧縮）。表示名解決用に **`pack_display_name_by_id` マップ**を再読込成功時に再構築。
  - **サンプル一覧ソート**: フィルタ署名 `_build_sample_filter_signature` に **`sample_sort`（列・昇順）**を含め、ソート変更とデバウンス／再読込の整合を取る。
  - **タグサジェスト**: 入力の **デバウンス（約 0.14s）** と TTL 緩和で SQLite 呼び出しを抑制。
  - **Popular tags**: キャッシュ TTL を **0.35s** に延長。
  - **heartbeat**: `SetExtState`（heartbeat）を **約 0.75s にスロットル**。
  - **ギャラクシー絞り込み（2026-05）**: フィルタ変更後の `get_samples` を **初回ロード以外は約 0.16s デバウンス**；再読込後は **数フレームだけ galaxy 点キャッシュ構築のステップ budget を 25% に**；`file_exists` は **`path` 単位のメモリキャッシュ**（`state.rows` 差し替えでクリア）；選択維持は **`sample_id → 行インデックス` マップ**で解決。
- **計測オーバーレイ**: REAPER の ExtState（セクション `SampleLodeManager`、キー **`ui_perf_overlay`**）に `true` / `1` を書くと `state.runtime.perf_enabled` が有効化され、メインループ先頭で **2 秒ごと**に再読込。無効は `false` / `0` またはキー削除。デフォルトはオフ。表示例は次のとおり。
  - **`scan`**: 非同期ライブラリスキャン `tick_async_rescan` の平均 ms。
  - **`rld`**: `reload_samples_if_needed`（主に `get_samples` 全件）の平均 ms。
  - **`pre`**: `prewarm_galaxy_points_cache_step`（ギャラクシー非表示時の点キャッシュ先取り）の平均 ms。
  - **`gfr`**: `tick_galaxy_full_refresh`（Update Galaxy パイプラインの repair / rebuild が走るフレームで大きくなる）の平均 ms。
  - **`pack` / `search` / `detail`**: 各パネル ImGui 描画の平均 ms。

---

## 10. 追記（全体パフォーマンス計画・ドラフト 2026-05）

### `get_samples` の規模（将来フェーズ）

- **現状**: `reload_samples_if_needed` は最大 **10 万行**の `get_samples` で一覧・ギャラクシー双方の `state.rows` を満たす。SQL と Lua テーブル構築がメインのスパイク源。
- **案 A（リスト）**: 表示行数＋余白に合わせた `LIMIT` と、スクロール下端での **追加ページ取得**（`OFFSET` またはキーセット方式）。ソート・選択・ギャラクシーとの整合が設計の中心。
- **案 B（ギャラクシー）**: 座標描画に必要な列だけを返す **軽量クエリ**（例: oneshot の `embed_x`/`embed_y`/`path`/`type` のみ）に分離し、詳細リストは案 A に寄せる。
- **案 C**: バックグラウンド完了は ReaScript の制約上むずかしく、まずは **デバウンス＋計測**でボトルネックを固定してから A/B のどちらを優先するか決めるのが安全。

### Update Galaxy（repair / rebuild）の分割 API

- **現状**: `sqlite_store.reanalyze_missing_audio_features` / `rebuild_galaxy_embedding_with_profiles` は **Python バッチを一括**呼び出す同期処理。フレーム分割用の `step_*` API はない。
- **短期**: 進捗ウィンドウと **フリーズ注意の文言**（§9 のオーバーレイ **`gfr`** でも傾向を確認可能）。
- **長期**: DB 層に **N 件ずつ処理するジョブ＋`step`** を追加するか、外部ツールでオフライン処理するかの検討領域。
