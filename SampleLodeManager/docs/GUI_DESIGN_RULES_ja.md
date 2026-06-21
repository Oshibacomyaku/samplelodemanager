# ReaImGui GUI デザインルール（oshibacomyaku 系）

他の ReaScript を作るときに **Sample Lode Manager と同じトーン**で揃えるためのルールです。  
数値の正本（ソース・オブ・トゥルース）は [`src/lib/core/ui_theme.lua`](../src/lib/core/ui_theme.lua) です。新規スクリプトではこのファイルを `require` して定数を流用してください。

---

## 1. 基本方針

| 項目 | 方針 |
|------|------|
| テーマ | ダーク UI。角は基本シャープ（rounding 0）。検索入力だけ pill 型 |
| 情報密度 | コンパクト。折り畳みは **20 px**（サマリなし）／**30 px**（チップ＋横スクロール） |
| 階層 | 背景 → 枠線 → 本文 → 選択／アクセント（白） |
| フォント | Windows 前提で Segoe UI 系。本文 14px、補助 11px |
| 色形式 | ReaImGui の `0xRRGGBBAA`（例: `0xF2F2F2FF`） |

---

## 2. カラーパレット

### 2.1 背景・サーフェス

| 用途 | 定数名 | 値 | 使い分け |
|------|--------|-----|----------|
| ウィンドウ背景 | `color_window_bg` | `#121214` | メインウィンドウ全体 |
| 子領域背景 | `color_child_bg` | `#121214` | `BeginChild` 内（パネル、リスト） |
| ポップアップ背景 | `color_popup_bg` | `#121214` | コンテキストメニュー、モーダル |
| 入力欄背景 | `color_frame_bg` | `#121214` | `InputText`、コンボ |
| 入力欄ホバー | `color_frame_bg_hovered` | `#242424` | マウスオーバー時 |
| 入力欄アクティブ | `color_frame_bg_active` | `#121214` | フォーカス時（強調しすぎない） |
| テーブル行 | `color_table_row_bg` | `#121214` | 一覧テーブル（交互色なし） |

### 2.2 テキスト

| 用途 | 定数名 | 値 | 使い分け |
|------|--------|-----|----------|
| 本文 | `color_text` | `#F2F2F2` | ラベル、一覧、見出し |
| 無効・補助 | `color_text_disabled` | `#45464D` | 折り畳み時の「— all」「— none」など |
| タグチップ | `color_tag_chip_text` | `#C8C9CD` | 人気タグ、詳細パネルのタグ |
| テキストのみボタン hover | `TEXT_ONLY_BTN_HOVER_TEXT_COL` | `#E8F4FF` | 折り畳み `>` / `v` トグル |

### 2.3 枠線・区切り

| 用途 | 定数名 | 値 | 太さ |
|------|--------|-----|------|
| 汎用ボーダー | `color_border` | `#45464D` | `frame_border_size = 1` px |
| セパレータ | `color_separator` | `#45464D` | ImGui 標準 1 px |
| テーブル罫線 | `color_table_border_*` | `#45464D` | 1 px |

ウィンドウ／子ウィンドウの `WindowBorderSize` / `ChildBorderSize` は **0**（外枠は REAPER 側に任せ、内側は Separator で区切る）。

### 2.4 ボタン・選択状態

| 状態 | Button 背景 | Text | 用途 |
|------|-------------|------|------|
| 通常（非選択） | 透明 `0x00000000` | `#F2F2F2` | List / Galaxy 切替、ソート |
| ホバー | `#2E2E2E` | `#F2F2F2` | 非選択タブに枠相当 |
| **選択中** | `#FFFFFF`（`#EDEDED` も可） | `#2A2A2A` | アクティブタブ、トグル ON |
| プライマリ（稀） | `#183357` 系 | 白 | 強調アクション（本プロジェクトでは控えめ） |

**アクティブタグ（検索中）**

| 種類 | Button 背景 | Text |
|------|-------------|------|
| 含むタグ | `#F0F0F0` | `#1A1A1A` |
| 除外タグ | `#2D2E33` | `#F2F2F2` |

**人気タグチップ（未選択）**: デフォルト Button 色 + `color_tag_chip_text`。

### 2.5 ギャラクシー点の色（参考）

ドラム系ファミリーごとに固定色（kick `#C23B3B`、snare `#2F7EC4` など）。詳細は `app.lua` の `galaxy_family_color` を参照。

---

## 3. タイポグラフィ

| レベル | フォント | サイズ | 用途 |
|--------|----------|--------|------|
| メイン | `Segoe UI Bold` | **14 px** | ウィンドウ全体、パック名、サンプル一覧 |
| 小 | `Segoe UI Semibold` | **11 px** | 検索パネル、Manage 画面、チップ |
| 一覧ヘッダ | メイン 14 px | 行高 22 px | BPM / Key 列ヘッダ |

```lua
font_main = r.ImGui_CreateFont("Segoe UI Bold", 14)
font_small = r.ImGui_CreateFont("Segoe UI Semibold", 11)
r.ImGui_Attach(ctx, font_main)
r.ImGui_Attach(ctx, font_small)
```

検索・Manage 系 UI 描画前に `ImGui_PushFont(ctx, font_small, 11)` を推奨。

---

## 4. スペーシング・形状

| 定数 | 値 | 用途 |
|------|-----|------|
| `item_spacing_x` / `y` | 8 / 7 | ウィジェット間 |
| `frame_padding_x` / `y` | 8 / 3 | ボタン・入力の内側余白 |
| `cell_padding_x` / `y` | 8 / 4 | テーブルセル |
| `scrollbar_size` | 10 | 縦スクロール（タグ strip は 8 も使用） |
| `STYLE_*_ROUNDING` | **0** | ウィンドウ、子、タブ、フレーム（全局） |
| 検索 `InputText` のみ | **12 px** rounding | `ui_input_text_with_hint` 内で id/hint に `search` / `filter` を含む場合 |
| `tag_chip_rounding` | **3 px** | タグチップ |

---

## 5. ボタン・コントロールサイズ

### 5.1 高さの段階

| 種別 | 高さ (px) | 幅 | 例 |
|------|-----------|-----|-----|
| **標準アクション** | **24** | `-1`（全幅）または固定 | Rescan All, Import sounds.db |
| **副アクション** | **22** | 同上 | Paste path, Cancel scan, Manage |
| **フィルタ／ソート** | **19–20** | 内容に応じ min–max | Key / BPM / Type トグル |
| **SmallButton** | ImGui 既定（≈18） | ラベル依存 | 折り畳みチップ、列ヘッダソート |
| **タグチップ** | **18**（人気）/ **20**（アクティブ） | テキスト + パディング | Popular tags |
| **折り畳みトグル** | **16×16** | 固定 | `>` / `v` |
| **お気に入り** | **26×30** | 固定 | サンプル一覧 ★ |
| **ギャラクシー** | **26** | 可変 | Update Galaxy |

### 5.2 パネル・行

| 要素 | サイズ |
|------|--------|
| 折り畳みパネル（サマリなし） | **20 px** | `COLLAPSED_PANEL_ROW_H` |
| 折り畳みパネル（チップあり） | **30 px** | 20 px 本文 + 10 px 横スクロールバー |
| パック一覧行 | min **32 px**、サムネ **28 px** |
| サンプル一覧行 | min **26 px**、サムネ **34 px** |
| アクティブパック strip | **34 px** |
| 詳細パネル最小高 | **244 px** |
| パネル分割つまみ | **8 px** |

### 5.3 同一行レイアウト

- 折り畳み行: `[トグル 6px タイトル 6px サマリ…]`
- フィルタチップ: `SameLine` 間隔 **4 px**
- 「Clear all」前: **6–8 px**

---

## 6. コンポーネント別ルール

### 6.1 折り畳みパネル

```
> Packs — all
> Search & filters — none
v Packs                    （展開時は見出し行のみ、その下に Child）
```

- 折り畳み時: **1 行**にトグル + タイトル + 状態サマリ
- サマリなし時: 薄色テキスト `— all` / `— none`（高さ **20 px**）
- フィルタ／パック選択あり: タイトルは固定、**サマリ部分だけ**横スクロール Child（高さ **20 + 10 = 30 px**。10 px は横スクロールバー用）

### 6.2 検索入力

- ヒント: `"Search filename/tags..."`
- pill 型（rounding 12）
- タグ候補選択後は入力文字列をクリア（ウィジェット ID リセット）

### 6.3 タブ型切替（List / Galaxy）

- 非選択: 透明背景 + 白文字 + ホバーで `#45464D` 枠
- 選択: 白背景 + 濃い文字 `#2A2A2A`

### 6.4 テーブル

- ヘッダ背景 = ウィンドウ背景（差別化少なめ）
- 行 hover: ImGui 標準 Header 色（`#1A1A1A` → `#2A2A2A`）
- 罫線: `#45464D` 1 px

### 6.5 テキストのみボタン

背景・枠を透明にしたボタン（`draw_text_only_button`）。  
折り畳みトグル、パネル見出しに使用。hover 時のみ文字色を `#E8F4FF` に。

---

## 7. 新規 ReaScript への適用手順

1. `ui_theme.lua` をコピーまたは `require` する
2. ウィンドウ開始時に `MODERN_UI` の色・StyleVar を一括 `Push`（`app.lua` の `push_modern_ui_style` 相当）
3. フォント 2 段（14 / 11）を `Attach`
4. ボタン高さは **24 → 22 → 20 → Small** の順で検討
5. 角丸は **基本 0**。検索ボックスだけ例外
6. 選択状態は **白背景 + 暗文字** で統一

### 最小コード例

```lua
local ui_theme = require("lib.core.ui_theme")
local C = ui_theme.default_constants()
local MU = C.MODERN_UI

-- Begin の直前
r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), MU.color_window_bg)
r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), MU.color_text)
r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), MU.item_spacing_x, MU.item_spacing_y)
r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), MU.frame_border_size)
-- … 他 Col_* も ui_theme に合わせる

r.ImGui_PushFont(ctx, font_main, 14)
-- 描画
r.ImGui_PopFont(ctx)
-- PopStyleVar / PopStyleColor（Push した数だけ）
```

---

## 8. やってはいけないこと

- 折り畳みパネルで **見出し行 + 別 Child 行** の 2 段構成（縦スペースの無駄）
- 角丸を全体にばら撒く（検索入力以外）
- 選択状態を青系ボタン色だけで表現（本テーマは白フィルが主）
- `BeginChild` に対して `visible == false` のとき `EndChild` する（クラッシュ原因）
- ライトテーマ色を混在させる（コントラスト設計が崩れる）

---

## 9. 関連ファイル

| ファイル | 内容 |
|----------|------|
| [`ui_theme.lua`](../src/lib/core/ui_theme.lua) | 色・サイズ定数の正本 |
| [`app.lua`](../src/lib/core/app.lua) | スタイル Push、折り畳み行、テキストボタン |
| [`ui_search.lua`](../src/lib/core/ui_search.lua) | 検索 UI、タグチップ |
| [`ui_imgui_utils.lua`](../src/lib/core/ui_imgui_utils.lua) | Child の安全な Begin/End |
| [`PROJECT_OVERVIEW_ja.md`](./PROJECT_OVERVIEW_ja.md) | プロダクト全体像 |

---

*最終更新: 2026-06 — Sample Lode Manager の UI 実装に基づく*
