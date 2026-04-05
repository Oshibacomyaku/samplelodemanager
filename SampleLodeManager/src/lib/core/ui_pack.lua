-- @noindex
local M = {}

local manage_sources_ui = nil
do
  local ok, mod = pcall(require, "lib.core.ui_pack_manage_sources")
  if ok then manage_sources_ui = mod end
end

local r = nil
local ctx = nil
local state = nil
local sqlite_store = nil
local cover_art = nil
local scan_controller = nil
local font_small = nil

local ACTIVE_PACK_STRIP_H = 34
local ACTIVE_PACK_CHIP_PAD_Y = 2
local ACTIVE_PACK_SCROLLBAR_SIZE = 10
local PACK_LIST_ROW_MIN_H = 32
local PACK_LIST_THUMB = 28
local pack_ui = nil
local use_native_tabs = false

local DEFAULT_PACK_UI = {
  manage_btn_w = 124,
  manage_btn_h = 22,
  active_strip_gap_x = 6,
  active_chip_gap_x = 4,
  active_clear_gap_x = 6,
  sort_label_gap_x = 8,
  sort_btn_h = 19,
  sort_btn_name_w = 74,
  sort_btn_most_w = 74,
  sort_btn_fewest_w = 74,
  sort_btn_gap_x = 4,
  table_fav_col_w = 30,
  table_fav_btn_w = 28,
  table_fav_btn_h = 22,
  fallback_tab_h = 24,
  fallback_tab_gap_x = 4,
}

local content_width = nil
local safe_push_font = nil
local safe_pop_font = nil
local window_flag_noresize = nil
local window_flag_noscroll_with_mouse = nil
local ui_input_text_with_hint = nil
local draw_rows_virtualized = nil
local filter_pack_ids_has = nil
local filter_pack_ids_toggle = nil
local filter_pack_ids_clear = nil
local filter_pack_ids_remove_at = nil
local pack_display_name_by_id = nil
local reload_pack_lists = nil
local set_runtime_notice = nil
local sanitize_root_path_input = nil
local set_persisted_splice_db_path = nil

local function ensure_fn(fn, fallback)
  if type(fn) == "function" then return fn end
  if type(fallback) == "function" then return fallback end
  return function() end
end

local function draw_favorite_icon_button(id, is_on, w, h)
  w = tonumber(w) or 24
  h = tonumber(h) or 20
  local sx, sy = 0, 0
  if r.ImGui_GetCursorScreenPos then
    local ok_pos, x, y = pcall(r.ImGui_GetCursorScreenPos, ctx)
    if ok_pos and type(x) == "number" and type(y) == "number" then
      sx, sy = x, y
    end
  end
  local clicked = false
  if r.ImGui_InvisibleButton then
    clicked = r.ImGui_InvisibleButton(ctx, id, w, h) == true
  else
    clicked = r.ImGui_Button(ctx, id, w, h) == true
  end
  if not (r.ImGui_GetWindowDrawList and (r.ImGui_DrawList_AddLine or r.ImDrawList_AddLine)) then
    return clicked
  end
  local hovered = false
  if r.ImGui_IsItemHovered then
    local ok_h, hv = pcall(function() return r.ImGui_IsItemHovered(ctx) end)
    hovered = ok_h and hv == true
  end
  local dl = r.ImGui_GetWindowDrawList(ctx)
  if not dl then return clicked end
  local cx = sx + w * 0.5
  local cy = sy + h * 0.5
  local r_outer = math.max(4.0, math.min(w, h) * 0.33)
  local r_inner = r_outer * 0.48
  local col = is_on and 0xFFFFFFFF or 0x7E8088FF
  if hovered then
    col = is_on and 0xFFFFFFFF or 0x9A9CA4FF
  end
  local thick = is_on and 2.6 or 1.2
  local pts = {}
  for k = 0, 9 do
    local ang = (-math.pi * 0.5) + (k * math.pi / 5.0)
    local rr = (k % 2 == 0) and r_outer or r_inner
    pts[#pts + 1] = { x = cx + math.cos(ang) * rr, y = cy + math.sin(ang) * rr }
  end
  for i = 1, #pts do
    local a = pts[i]
    local b = pts[(i % #pts) + 1]
    if r.ImGui_DrawList_AddLine then
      r.ImGui_DrawList_AddLine(dl, a.x, a.y, b.x, b.y, col, thick)
    else
      r.ImDrawList_AddLine(dl, a.x, a.y, b.x, b.y, col, thick)
    end
  end
  return clicked
end

function M.setup(deps)
  deps = type(deps) == "table" and deps or {}
  r = deps.r
  ctx = deps.ctx
  state = deps.state
  sqlite_store = deps.sqlite_store
  cover_art = deps.cover_art
  scan_controller = deps.scan_controller
  font_small = deps.font_small

  ACTIVE_PACK_STRIP_H = tonumber(deps.active_pack_strip_h) or ACTIVE_PACK_STRIP_H
  ACTIVE_PACK_CHIP_PAD_Y = tonumber(deps.active_pack_chip_pad_y) or ACTIVE_PACK_CHIP_PAD_Y
  ACTIVE_PACK_SCROLLBAR_SIZE = tonumber(deps.active_pack_scrollbar_size) or ACTIVE_PACK_SCROLLBAR_SIZE
  PACK_LIST_ROW_MIN_H = tonumber(deps.pack_list_row_min_h) or PACK_LIST_ROW_MIN_H
  PACK_LIST_THUMB = tonumber(deps.pack_list_thumb) or PACK_LIST_THUMB

  content_width = ensure_fn(deps.content_width, function(fallback) return tonumber(fallback) or 0 end)
  safe_push_font = ensure_fn(deps.safe_push_font, function() return false end)
  safe_pop_font = ensure_fn(deps.safe_pop_font)
  window_flag_noresize = ensure_fn(deps.window_flag_noresize, function() return 0 end)
  window_flag_noscroll_with_mouse = ensure_fn(deps.window_flag_noscroll_with_mouse, function() return 0 end)
  ui_input_text_with_hint = ensure_fn(deps.ui_input_text_with_hint, function(id, _, v) return false, tostring(v or ""), id end)
  draw_rows_virtualized = ensure_fn(deps.draw_rows_virtualized, function(total_rows, draw_row_fn)
    for i = 1, tonumber(total_rows) or 0 do draw_row_fn(i) end
  end)
  filter_pack_ids_has = ensure_fn(deps.filter_pack_ids_has, function() return false end)
  filter_pack_ids_toggle = ensure_fn(deps.filter_pack_ids_toggle)
  filter_pack_ids_clear = ensure_fn(deps.filter_pack_ids_clear)
  filter_pack_ids_remove_at = ensure_fn(deps.filter_pack_ids_remove_at)
  pack_display_name_by_id = ensure_fn(deps.pack_display_name_by_id, function(pid) return tostring(pid or "") end)
  reload_pack_lists = ensure_fn(deps.reload_pack_lists)
  set_runtime_notice = ensure_fn(deps.set_runtime_notice)
  sanitize_root_path_input = ensure_fn(deps.sanitize_root_path_input, function(v) return tostring(v or "") end)
  set_persisted_splice_db_path = ensure_fn(deps.set_persisted_splice_db_path)
  pack_ui = {}
  local incoming_pack_ui = type(deps.pack_ui) == "table" and deps.pack_ui or {}
  for k, v in pairs(DEFAULT_PACK_UI) do
    pack_ui[k] = tonumber(incoming_pack_ui[k]) or v
  end
  use_native_tabs = deps.use_native_tabs == true

  if manage_sources_ui and type(manage_sources_ui.setup) == "function" then
    manage_sources_ui.setup({
      r = r,
      ctx = ctx,
      state = state,
      sqlite_store = sqlite_store,
      scan_controller = scan_controller,
      ui_input_text_with_hint = ui_input_text_with_hint,
      window_flag_always_vertical_scrollbar = deps.window_flag_always_vertical_scrollbar,
      sanitize_root_path_input = sanitize_root_path_input,
      reload_pack_lists = reload_pack_lists,
      set_persisted_splice_db_path = set_persisted_splice_db_path,
      set_persisted_splice_relink_roots = ensure_fn(deps.set_persisted_splice_relink_roots),
    })
  end
end

function M.draw(win_w)
  if not (r and ctx and state) then return end

  do
    local cw = content_width(win_w)
    r.ImGui_SetCursorPosX(ctx, math.max(0, cw - 126))
    local pushed_g = safe_push_font(font_small, 11)
    if r.ImGui_Button(ctx, "Manage Sources##pack_gear", pack_ui.manage_btn_w, pack_ui.manage_btn_h) then
      if r.ImGui_OpenPopup then
        r.ImGui_OpenPopup(ctx, "Manage Sources##manage_sources_modal")
      end
    end
    safe_pop_font(pushed_g)
  end
  r.ImGui_Text(ctx, "Active packs:")
  r.ImGui_SameLine(ctx, 0, pack_ui.active_strip_gap_x)
  do
    local strip_h = ACTIVE_PACK_STRIP_H
    state.ui.pack_active_strip_px = strip_h
    local child_flags = window_flag_noresize() | window_flag_noscroll_with_mouse()
    if r.ImGui_WindowFlags_HorizontalScrollbar then
      child_flags = child_flags | r.ImGui_WindowFlags_HorizontalScrollbar()
    end
    local pushed_scrollbar_size = false
    if r.ImGui_PushStyleVar and r.ImGui_StyleVar_ScrollbarSize then
      local ok_sv = pcall(function()
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ScrollbarSize(), ACTIVE_PACK_SCROLLBAR_SIZE)
      end)
      pushed_scrollbar_size = ok_sv == true
    end
    if r.ImGui_BeginChild(ctx, "##pack_active_strip", 0, strip_h, 0, child_flags) then
      local to_rm_pack = nil
      local pushed_chip_pad = false
      if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FramePadding then
        local ok_pad = pcall(function()
          r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 5, ACTIVE_PACK_CHIP_PAD_Y)
        end)
        pushed_chip_pad = ok_pad == true
      end
      if #state.filter_pack_ids == 0 then
        r.ImGui_Text(ctx, "all (click rows to narrow)")
      else
        for i, pid in ipairs(state.filter_pack_ids) do
          if i > 1 then
            r.ImGui_SameLine(ctx, 0, pack_ui.active_chip_gap_x)
          end
          r.ImGui_PushID(ctx, "ap_" .. tostring(i))
          local nm = tostring(pack_display_name_by_id(pid) or ("#" .. tostring(pid)))
          if #nm > 26 then
            nm = nm:sub(1, 26) .. "..."
          end
          if r.ImGui_SmallButton(ctx, "x " .. nm .. "##rmpk") then
            to_rm_pack = i
          end
          r.ImGui_PopID(ctx)
        end
        r.ImGui_SameLine(ctx, 0, pack_ui.active_clear_gap_x)
        if r.ImGui_SmallButton(ctx, "Clear all##pack_filter_clear_all") then
          filter_pack_ids_clear()
          to_rm_pack = nil
        end
      end
      if pushed_chip_pad and r.ImGui_PopStyleVar then
        pcall(function() r.ImGui_PopStyleVar(ctx, 1) end)
      end
      if to_rm_pack then
        filter_pack_ids_remove_at(to_rm_pack)
      end
      r.ImGui_EndChild(ctx)
    end
    if pushed_scrollbar_size and r.ImGui_PopStyleVar then
      pcall(function() r.ImGui_PopStyleVar(ctx, 1) end)
    end
  end

  r.ImGui_PushItemWidth(ctx, -1)
  local changed, new_text = ui_input_text_with_hint("##pack_query", "Search packs or developer...", state.packs_query, 256)
  if changed then state.packs_query = new_text end
  r.ImGui_PopItemWidth(ctx)

  do
    local pushed_checkbox_size = false
    if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FramePadding then
      local ok_pad = pcall(function()
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 5, 1)
      end)
      pushed_checkbox_size = ok_pad == true
    end
    local chg, on = r.ImGui_Checkbox(ctx, "Favorite packs only", state.ui.pack_favorites_only_filter == true)
    if pushed_checkbox_size and r.ImGui_PopStyleVar then
      pcall(function() r.ImGui_PopStyleVar(ctx, 1) end)
    end
    if chg then
      state.ui.pack_favorites_only_filter = on == true
      state.needs_reload_samples = true
    end
  end
  r.ImGui_Spacing(ctx)

  if state.db.available == false then
    r.ImGui_Text(ctx, "SQLite module missing")
    if state.db.error and state.db.error ~= "" then
      r.ImGui_TextWrapped(ctx, tostring(state.db.error))
    end
    r.ImGui_Spacing(ctx)
  end

  if state.manage.notice and state.manage.notice ~= "" then
    r.ImGui_TextWrapped(ctx, tostring(state.manage.notice))
    r.ImGui_Spacing(ctx)
  end

  local q = (state.packs_query or ""):lower()
  local pack_fav_only = state.ui.pack_favorites_only_filter == true
  local sort_mode = state.ui.pack_sort or "name"

  local function pack_row_matches_query(p)
    if q == "" then return true end
    local base_name = tostring(p.display_name or p.name or "")
    local prov = ""
    if p.provider_name and tostring(p.provider_name) ~= "" then
      prov = tostring(p.provider_name):match("^%s*(.-)%s*$") or ""
    end
    if base_name:lower():find(q, 1, true) then return true end
    if prov ~= "" and prov:lower():find(q, 1, true) then return true end
    return false
  end

  r.ImGui_Text(ctx, "Sort")
  r.ImGui_SameLine(ctx, 0, pack_ui.sort_label_gap_x)
  local pushed_sort_rounding = false
  local pushed_sort_text_align = false
  local pushed_sort_padding = false
  if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FrameRounding then
    local ok_round = pcall(function()
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), 8.0)
    end)
    pushed_sort_rounding = ok_round == true
  end
  if r.ImGui_PushStyleVar and r.ImGui_StyleVar_ButtonTextAlign then
    local ok_align = pcall(function()
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ButtonTextAlign(), 0.5, 0.14)
    end)
    pushed_sort_text_align = ok_align == true
  end
  if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FramePadding then
    local ok_pad = pcall(function()
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 8, 1)
    end)
    pushed_sort_padding = ok_pad == true
  end
  local function pack_sort_button(key, label, width)
    local on = (sort_mode == key)
    local w = width or 0
    if r.ImGui_Button(ctx, (on and "* " or "") .. label .. "##pack_sort_" .. key, w, pack_ui.sort_btn_h) then
      if state.ui.pack_sort ~= key then
        state.ui.pack_sort = key
        reload_pack_lists()
      end
    end
  end
  pack_sort_button("name", "Name", pack_ui.sort_btn_name_w)
  r.ImGui_SameLine(ctx, 0, pack_ui.sort_btn_gap_x)
  pack_sort_button("count_desc", "Most", pack_ui.sort_btn_most_w)
  r.ImGui_SameLine(ctx, 0, pack_ui.sort_btn_gap_x)
  pack_sort_button("count_asc", "Fewest", pack_ui.sort_btn_fewest_w)
  local sort_style_pop_n = 0
  if pushed_sort_rounding then sort_style_pop_n = sort_style_pop_n + 1 end
  if pushed_sort_text_align then sort_style_pop_n = sort_style_pop_n + 1 end
  if pushed_sort_padding then sort_style_pop_n = sort_style_pop_n + 1 end
  if sort_style_pop_n > 0 and r.ImGui_PopStyleVar then
    pcall(function() r.ImGui_PopStyleVar(ctx, sort_style_pop_n) end)
  end
  r.ImGui_Spacing(ctx)

  local pack_has_any_cover = cover_art and state.runtime and state.runtime.cover_art
  if pack_has_any_cover and state.ui and state.ui.cover_auto_download == true then
    -- Keep pack thumbnails progressing even before a pack is selected.
    state.runtime.cover_art.ctx_ref = ctx
    cover_art.process_queue(state.runtime.cover_art.queue, 1)
  end

  local function open_pack_bulk_tag_window(p)
    if not (p and tonumber(p.id)) then return end
    state.runtime.pack_bulk_tag_open = true
    state.runtime.pack_bulk_tag_pack_id = tonumber(p.id)
    state.runtime.pack_bulk_tag_pack_name = tostring(p.display_name or p.name or ("pack #" .. tostring(p.id)))
    state.runtime.pack_bulk_tag_input = state.runtime.pack_bulk_tag_input or ""
  end

  local function draw_pack_table_body(packs, table_suffix)
    local filtered = nil
    if state.runtime and type(state.runtime.pack_filtered_cache) ~= "table" then
      state.runtime.pack_filtered_cache = {}
    end
    local cache = state.runtime and state.runtime.pack_filtered_cache and state.runtime.pack_filtered_cache[table_suffix] or nil
    if cache and cache.packs_ref == packs and cache.query == q and cache.pack_fav_only == pack_fav_only then
      filtered = cache.rows
    end
    if type(filtered) ~= "table" then
      filtered = {}
      for _, p in ipairs(packs or {}) do
        local fav_ok = (not pack_fav_only) or (p and p.is_favorite == true)
        if fav_ok and pack_row_matches_query(p) then
          filtered[#filtered + 1] = p
        end
      end
      if state.runtime and type(state.runtime.pack_filtered_cache) == "table" then
        state.runtime.pack_filtered_cache[table_suffix] = {
          packs_ref = packs,
          query = q,
          pack_fav_only = pack_fav_only,
          rows = filtered,
        }
      end
    end

    local n_cols = pack_has_any_cover and 3 or 2
    local tbl_flags = 0
    if r.ImGui_TableFlags_SizingStretchProp then
      tbl_flags = r.ImGui_TableFlags_SizingStretchProp()
    end
    local tbl_opened = false
    if r.ImGui_BeginTable and r.ImGui_BeginTable(ctx, "##pt_" .. tostring(table_suffix), n_cols, tbl_flags) then
      tbl_opened = true
      if r.ImGui_TableSetupColumn then
        if pack_has_any_cover then
          r.ImGui_TableSetupColumn(ctx, "##cov", r.ImGui_TableColumnFlags_WidthFixed(), PACK_LIST_THUMB + 4)
        end
        r.ImGui_TableSetupColumn(ctx, "pack", r.ImGui_TableColumnFlags_WidthStretch())
        r.ImGui_TableSetupColumn(ctx, "fav", r.ImGui_TableColumnFlags_WidthFixed(), pack_ui.table_fav_col_w)
      end
    end
    local function end_pack_table_safe()
      if tbl_opened and r.ImGui_EndTable then
        r.ImGui_EndTable(ctx)
      end
      tbl_opened = false
    end

    local ok_body, body_err = pcall(function()
      local function draw_one_pack(p)
        if not p then return end
        r.ImGui_PushID(ctx, "prow_" .. tostring(p.id) .. "_" .. tostring(table_suffix))
        pcall(function()
          local base_name = p.display_name or p.name or ""
          local prov = ""
          if p.provider_name and tostring(p.provider_name) ~= "" then
            prov = tostring(p.provider_name):match("^%s*(.-)%s*$") or ""
          end
          local line1 = base_name
          if sort_mode == "count_desc" or sort_mode == "count_asc" then
            line1 = string.format("%s (%d)", base_name, tonumber(p.sample_count) or 0)
          end
          local label = line1
          if prov ~= "" then
            label = line1 .. "\n" .. prov
          end
          if tbl_opened then
            local ok_tr = pcall(function()
              r.ImGui_TableNextRow(ctx, 0, PACK_LIST_ROW_MIN_H)
            end)
            if not ok_tr then
              r.ImGui_TableNextRow(ctx)
            end
            if pack_has_any_cover then
              r.ImGui_TableNextColumn(ctx)
              local url = p.cover_url and tostring(p.cover_url) or ""
              if url ~= "" then
                cover_art.draw_cell(ctx, state.runtime.cover_art, p.id, url, PACK_LIST_THUMB, true)
              elseif r.ImGui_Dummy then
                r.ImGui_Dummy(ctx, PACK_LIST_THUMB, PACK_LIST_THUMB)
              end
            end
            r.ImGui_TableNextColumn(ctx)
          end
          local in_filter = filter_pack_ids_has(state.filter_pack_ids, p.id)
          if r.ImGui_Selectable(ctx, label, in_filter) then
            filter_pack_ids_toggle(p.id)
          end
          if r.ImGui_BeginPopupContextItem then
            local pop_id = "##pack_row_ctx_" .. tostring(p.id) .. "_" .. tostring(table_suffix)
            if r.ImGui_BeginPopupContextItem(ctx, pop_id) then
              if r.ImGui_Selectable(ctx, "Tag pack samples...") then
                open_pack_bulk_tag_window(p)
              end
              r.ImGui_EndPopup(ctx)
            end
          end
          if not tbl_opened then
            r.ImGui_SameLine(ctx, 0, pack_ui.active_chip_gap_x)
          else
            r.ImGui_TableNextColumn(ctx)
          end
          local is_pf = p.is_favorite == true
          local fav_changed, fav_next = r.ImGui_Checkbox(ctx, "##pfav_ck_" .. tostring(p.id), is_pf)
          if fav_changed then
            if state.store.available and state.store.conn and sqlite_store and type(sqlite_store.set_pack_favorite) == "function" then
              local want = fav_next == true
              local ok_pcall, ok_db = pcall(function()
                return sqlite_store.set_pack_favorite({ db = state.store.conn }, tonumber(p.id), want)
              end)
              if ok_pcall and ok_db then
                p.is_favorite = want == true
                if state.ui.pack_favorites_only_filter == true and want == false then
                  set_runtime_notice("Pack favorite removed. List updates on next filter change.")
                else
                  reload_pack_lists()
                  if state.ui.pack_favorites_only_filter then
                    state.needs_reload_samples = true
                  end
                end
              else
                set_runtime_notice("Could not update pack favorite.")
              end
            end
          end
        end)
        r.ImGui_PopID(ctx)
      end
      draw_rows_virtualized(#filtered, function(row_idx)
        draw_one_pack(filtered[row_idx])
      end, "pack_row_clipper_" .. tostring(table_suffix))
    end)

    end_pack_table_safe()
    if not ok_body then
      set_runtime_notice("Pack table draw failed: " .. tostring(body_err or "unknown"))
    end
  end

  local tab = state.ui.pack_source_tab
  if tab ~= "splice" and tab ~= "other" then
    tab = "splice"
    state.ui.pack_source_tab = tab
  end

  local tabbar_ok = false
  if use_native_tabs and r.ImGui_BeginTabBar then
    local ok, ret = pcall(r.ImGui_BeginTabBar, ctx, "##pack_source_tabbar", 0)
    if ok and ret ~= false then
      tabbar_ok = true
    end
  end

  if tabbar_ok then
    local ok_tab, err_tab
    if r.ImGui_BeginTabItem(ctx, "Splice##pack_tab_splice") then
      ok_tab, err_tab = pcall(draw_pack_table_body, state.packs.splice, "splice")
      if not ok_tab then
        set_runtime_notice("Pack list UI error: " .. tostring(err_tab))
      end
      if r.ImGui_EndTabItem then
        r.ImGui_EndTabItem(ctx)
      end
    end
    if r.ImGui_BeginTabItem(ctx, "Other##pack_tab_other") then
      ok_tab, err_tab = pcall(draw_pack_table_body, state.packs.other, "other")
      if not ok_tab then
        set_runtime_notice("Pack list UI error: " .. tostring(err_tab))
      end
      if r.ImGui_EndTabItem then
        r.ImGui_EndTabItem(ctx)
      end
    end
    pcall(function()
      if r.ImGui_EndTabBar then
        r.ImGui_EndTabBar(ctx)
      end
    end)
  else
    local function draw_mono_tab_button(label, id, selected, w, h)
      local push_n = 0
      if r.ImGui_PushStyleColor and r.ImGui_Col_Button then
        pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), selected and 0xF0F0F0FF or 0x00000000)
          push_n = push_n + 1
        end)
        pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), selected and 0xF0F0F0FF or 0x45464DFF)
          push_n = push_n + 1
        end)
        pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), selected and 0xF0F0F0FF or 0x45464DFF)
          push_n = push_n + 1
        end)
        pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), selected and 0x2A2A2AFF or 0xF2F2F2FF)
          push_n = push_n + 1
        end)
      end
      local clicked = r.ImGui_Button(ctx, label .. id, w, h) == true
      local rect = nil
      do
        local ok_r1, x1, y1 = pcall(r.ImGui_GetItemRectMin, ctx)
        local ok_r2, x2, y2 = pcall(r.ImGui_GetItemRectMax, ctx)
        if ok_r1 and ok_r2 and type(x1) == "number" and type(y1) == "number" and type(x2) == "number" and type(y2) == "number" then
          rect = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
        end
      end
      if push_n > 0 and r.ImGui_PopStyleColor then
        pcall(function() r.ImGui_PopStyleColor(ctx, push_n) end)
      end
      return clicked, rect
    end
    local sel = state.ui.pack_source_tab
    local wtab = math.max(60, math.floor((content_width(win_w) - 8) / 2))
    local on_s = (sel == "splice")
    local on_o = (sel == "other")
    local clicked_splice, rect1 = draw_mono_tab_button("Splice", "##packtab_splice", on_s, wtab, pack_ui.fallback_tab_h)
    if clicked_splice then
      state.ui.pack_source_tab = "splice"
    end
    r.ImGui_SameLine(ctx, 0, 0)
    local clicked_other, rect2 = draw_mono_tab_button("Other", "##packtab_other", on_o, wtab, pack_ui.fallback_tab_h)
    if clicked_other then
      state.ui.pack_source_tab = "other"
    end
    do
      local line_y = nil
      local x_start = nil
      local x_end = nil
      if rect1 and rect2 then
        line_y = math.floor(math.max(rect1.y2, rect2.y2) - 1) + 0.5
        x_start = rect1.x1
        x_end = x_start + math.max(rect2.x2 - rect1.x1, content_width(win_w))
      end
      if line_y and x_start and x_end then
        local ok_dl, dl = pcall(function()
          if r.ImGui_GetWindowDrawList then return r.ImGui_GetWindowDrawList(ctx) end
          return nil
        end)
        if ok_dl and dl then
          local col = 0x45464DFF
          pcall(function()
            if r.ImGui_DrawList_AddLine then
              r.ImGui_DrawList_AddLine(dl, x_start, line_y, x_end, line_y, col, 1)
            elseif r.ImDrawList_AddLine then
              r.ImDrawList_AddLine(dl, x_start, line_y, x_end, line_y, col, 1)
            end
          end)
        end
      end
    end
    if sel == "splice" then
      draw_pack_table_body(state.packs.splice, "splice")
    else
      draw_pack_table_body(state.packs.other, "other")
    end
  end

  local ok_sep = pcall(function()
    r.ImGui_Separator(ctx)
  end)
  if not ok_sep then
    if state and state.runtime then
      state.runtime.ctx_recreate_requested = true
    end
    return
  end

  if manage_sources_ui and type(manage_sources_ui.draw_modal) == "function" then
    manage_sources_ui.draw_modal()
  end
end

return M
