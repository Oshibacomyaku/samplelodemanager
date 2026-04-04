local M = {}

local r = nil
local ctx = nil
local state = nil
local sqlite_store = nil
local cover_art = nil

local SAMPLE_SECTION_MIN_H = 40
local SAMPLE_LIST_ROW_MIN_H = 22
local SAMPLE_LIST_THUMB = 36
local font_main = nil
local list_ui = nil

local DEFAULT_LIST_UI = {
  font_px = 14,
  header_h = 22,
  header_inline_gap_x = 4,
  col_cover_w = 34,
  col_bpm_w = 50,
  col_key_w = 44,
  col_sel_w = 34,
  col_fav_w = 36,
  fav_btn_w = 30,
  fav_btn_h = 26,
}

local window_flag_noresize = nil
local window_flag_noscrollbar = nil
local window_flag_noscroll_with_mouse = nil
local safe_push_font = nil
local safe_pop_font = nil
local draw_text_only_button = nil
local draw_rows_virtualized = nil
local imgui_mod_down = nil
local bulk_clear_all_selection = nil
local bulk_set_row_selected = nil
local bulk_toggle_sample_id = nil
local bulk_selected_count = nil
local bulk_selected_ids_list = nil
local set_selected_row = nil
local stop_preview = nil
local set_runtime_notice = nil
local play_selected_sample_preview = nil
local begin_drag_for_row = nil
local open_sample_edit_popup_for_row = nil
local open_sample_edit_popup_for_ids = nil

local function ensure_fn(fn, fallback)
  if type(fn) == "function" then return fn end
  if type(fallback) == "function" then return fallback end
  return function() end
end

local function draw_selected_overlay_for_last_item()
  if not (r.ImGui_GetItemRectMin and r.ImGui_GetItemRectMax and r.ImGui_GetWindowDrawList) then return end
  local ok1, x1, y1 = pcall(r.ImGui_GetItemRectMin, ctx)
  local ok2, x2, y2 = pcall(r.ImGui_GetItemRectMax, ctx)
  if not (ok1 and ok2 and type(x1) == "number" and type(y1) == "number" and type(x2) == "number" and type(y2) == "number") then
    return
  end
  if x2 <= x1 or y2 <= y1 then return end
  local dl = r.ImGui_GetWindowDrawList(ctx)
  if not dl then return end
  local fill_col = 0xFFFFFF18
  if r.ImGui_DrawList_AddRectFilled then
    r.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, fill_col, 0)
  elseif r.ImDrawList_AddRectFilled then
    r.ImDrawList_AddRectFilled(dl, x1, y1, x2, y2, fill_col, 0)
  end
end

function M.setup(deps)
  deps = type(deps) == "table" and deps or {}
  r = deps.r
  ctx = deps.ctx
  state = deps.state
  sqlite_store = deps.sqlite_store
  cover_art = deps.cover_art
  font_main = deps.font_main

  SAMPLE_SECTION_MIN_H = tonumber(deps.sample_section_min_h) or SAMPLE_SECTION_MIN_H
  SAMPLE_LIST_ROW_MIN_H = tonumber(deps.sample_list_row_min_h) or SAMPLE_LIST_ROW_MIN_H
  SAMPLE_LIST_THUMB = tonumber(deps.sample_list_thumb) or SAMPLE_LIST_THUMB

  window_flag_noresize = ensure_fn(deps.window_flag_noresize, function() return 0 end)
  window_flag_noscrollbar = ensure_fn(deps.window_flag_noscrollbar, function() return 0 end)
  window_flag_noscroll_with_mouse = ensure_fn(deps.window_flag_noscroll_with_mouse, function() return 0 end)
  safe_push_font = ensure_fn(deps.safe_push_font, function() return false end)
  safe_pop_font = ensure_fn(deps.safe_pop_font)
  draw_text_only_button = ensure_fn(deps.draw_text_only_button, function() return false end)
  draw_rows_virtualized = ensure_fn(deps.draw_rows_virtualized, function(total_rows, draw_row_fn)
    for i = 1, tonumber(total_rows) or 0 do
      draw_row_fn(i)
    end
  end)
  imgui_mod_down = ensure_fn(deps.imgui_mod_down, function() return false end)
  bulk_clear_all_selection = ensure_fn(deps.bulk_clear_all_selection)
  bulk_set_row_selected = ensure_fn(deps.bulk_set_row_selected)
  bulk_toggle_sample_id = ensure_fn(deps.bulk_toggle_sample_id)
  bulk_selected_count = ensure_fn(deps.bulk_selected_count, function() return 0 end)
  bulk_selected_ids_list = ensure_fn(deps.bulk_selected_ids_list, function() return {} end)
  set_selected_row = ensure_fn(deps.set_selected_row)
  stop_preview = ensure_fn(deps.stop_preview)
  set_runtime_notice = ensure_fn(deps.set_runtime_notice)
  play_selected_sample_preview = ensure_fn(deps.play_selected_sample_preview)
  begin_drag_for_row = ensure_fn(deps.begin_drag_for_row)
  open_sample_edit_popup_for_row = ensure_fn(deps.open_sample_edit_popup_for_row)
  open_sample_edit_popup_for_ids = ensure_fn(deps.open_sample_edit_popup_for_ids)
  list_ui = {}
  local incoming_list_ui = type(deps.list_ui) == "table" and deps.list_ui or {}
  for k, v in pairs(DEFAULT_LIST_UI) do
    list_ui[k] = tonumber(incoming_list_ui[k]) or v
  end
  -- Keep cover column width aligned to actual thumbnail width by default.
  if incoming_list_ui.col_cover_w == nil then
    list_ui.col_cover_w = SAMPLE_LIST_THUMB
  end
end

function M.draw(_win_w, list_h)
  if not (r and ctx and state) then return end
  list_h = math.max(SAMPLE_SECTION_MIN_H, math.floor(tonumber(list_h) or 120))
  local pushed_font = safe_push_font(font_main, list_ui.font_px)

  local function key_root_dual_label(root_raw)
    local root = tostring(root_raw or ""):upper():gsub("^%s+", ""):gsub("%s+$", "")
    local flat_to_sharp = { DB = "C#", EB = "D#", GB = "F#", AB = "G#", BB = "A#" }
    local sharp_to_flat = { ["C#"] = "Db", ["D#"] = "Eb", ["F#"] = "Gb", ["G#"] = "Ab", ["A#"] = "Bb" }
    if flat_to_sharp[root] then root = flat_to_sharp[root] end
    local key_roots = { C = true, ["C#"] = true, D = true, ["D#"] = true, E = true, F = true, ["F#"] = true, G = true, ["G#"] = true, A = true, ["A#"] = true, B = true }
    if not key_roots[root] then return tostring(root_raw or "") end
    local flat = sharp_to_flat[root]
    if flat then return root .. "/" .. flat end
    return root
  end

  local function key_label_compact(key_text)
    local txt = tostring(key_text or "")
    if txt == "" then return "--" end
    local root_raw = txt:match("^([A-Ga-g][#bB]?)")
    if not root_raw then
      txt = txt:gsub("%f[%a][Mm][Aa][Jj][Oo][Rr]%f[%A]", "maj")
      txt = txt:gsub("%f[%a][Mm][Ii][Nn][Oo][Rr]%f[%A]", "min")
      return txt
    end
    local root_dual = key_root_dual_label(root_raw)
    local suffix = txt
    if root_raw then
      suffix = txt:sub(#tostring(root_raw) + 1):gsub("^%s+", "")
    else
      suffix = ""
    end
    local low = suffix:lower()
    if low:find("minor", 1, true) or low:find(" min", 1, true) then
      return root_dual .. "m"
    elseif low:find("major", 1, true) or low:find(" maj", 1, true) then
      return root_dual .. "M"
    elseif suffix ~= "" then
      return root_dual .. " " .. suffix
    end
    return root_dual
  end

  local function key_label_full_dual(key_text)
    local txt = tostring(key_text or "")
    if txt == "" then return "--" end
    local root_raw = txt:match("^([A-Ga-g][#bB]?)")
    if not root_raw then return txt end
    local root_dual = key_root_dual_label(root_raw)
    local suffix = txt:sub(#tostring(root_raw) + 1):gsub("^%s+", "")
    suffix = suffix:gsub("%f[%a][Mm][Aa][Jj][Oo][Rr]%f[%A]", "maj")
    suffix = suffix:gsub("%f[%a][Mm][Ii][Nn][Oo][Rr]%f[%A]", "min")
    if suffix ~= "" then
      return root_dual .. " " .. suffix
    end
    return root_dual
  end

  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 0, 6)
  local flags = window_flag_noresize() | window_flag_noscrollbar() | window_flag_noscroll_with_mouse()
  if r.ImGui_BeginChild(ctx, "##sample_list", 0, list_h, 1, flags) then
    if cover_art and state.runtime.cover_art and state.ui.cover_auto_download == true then
      state.runtime.cover_art.ctx_ref = ctx
      cover_art.process_queue(state.runtime.cover_art.queue, 1)
    end

    local table_flags = r.ImGui_TableFlags_ScrollY()
      | r.ImGui_TableFlags_RowBg()
    if r.ImGui_TableFlags_BordersInnerV then
      table_flags = table_flags | r.ImGui_TableFlags_BordersInnerV()
    elseif r.ImGui_TableFlags_BordersV then
      table_flags = table_flags | r.ImGui_TableFlags_BordersV()
    end

    if r.ImGui_BeginTable(ctx, "samples_table", 5, table_flags) then
      r.ImGui_TableSetupColumn(ctx, "##cov", r.ImGui_TableColumnFlags_WidthFixed(), list_ui.col_cover_w)
      r.ImGui_TableSetupColumn(ctx, "Filename")
      r.ImGui_TableSetupColumn(ctx, "BPM", r.ImGui_TableColumnFlags_WidthFixed(), list_ui.col_bpm_w)
      r.ImGui_TableSetupColumn(ctx, "Key", r.ImGui_TableColumnFlags_WidthFixed(), list_ui.col_key_w)
      r.ImGui_TableSetupColumn(ctx, "Fav", r.ImGui_TableColumnFlags_WidthFixed(), list_ui.col_fav_w)

      local ss = state.ui.sample_sort or { column = "filename", asc = true }
      local function sample_sort_header_click(column_key, label, btn_w, btn_h)
        local active = (ss.column == column_key)
        local ind = ""
        if active then
          if column_key == "random" then
            ind = " *"
          else
            ind = ss.asc and " ^" or " v"
          end
        end
        if draw_text_only_button(label .. ind .. "##sample_hdr_sort_" .. column_key, btn_w or -1, btn_h or 22) then
          if column_key == "random" then
            ss.column = "random"
            ss.asc = true
          elseif ss.column == column_key then
            ss.asc = not ss.asc
          else
            ss.column = column_key
            ss.asc = true
          end
          state.needs_reload_samples = true
        end
      end

      local hdr_flags = (r.ImGui_TableRowFlags_Headers and r.ImGui_TableRowFlags_Headers()) or 0
      r.ImGui_TableNextRow(ctx, hdr_flags)
      r.ImGui_TableSetColumnIndex(ctx, 0)
      r.ImGui_Text(ctx, "")
      r.ImGui_TableSetColumnIndex(ctx, 1)
      sample_sort_header_click("filename", "Filename", -74, list_ui.header_h)
      r.ImGui_SameLine(ctx, 0, list_ui.header_inline_gap_x)
      sample_sort_header_click("random", "Rnd", 70, list_ui.header_h)
      r.ImGui_TableSetColumnIndex(ctx, 2)
      sample_sort_header_click("bpm", "BPM", list_ui.col_bpm_w, list_ui.header_h)
      r.ImGui_TableSetColumnIndex(ctx, 3)
      sample_sort_header_click("key", "Key", list_ui.col_key_w, list_ui.header_h)
      r.ImGui_TableSetColumnIndex(ctx, 4)
      r.ImGui_Text(ctx, "Fav")

      local function draw_row(row_idx)
        local row = state.rows[row_idx]
        if not row then return end

        local ok_tr = pcall(function()
          r.ImGui_TableNextRow(ctx, 0, SAMPLE_LIST_ROW_MIN_H)
        end)
        if not ok_tr then
          r.ImGui_TableNextRow(ctx)
        end

        r.ImGui_TableSetColumnIndex(ctx, 0)
        if cover_art and state.runtime.cover_art then
          local url = row.pack_cover_url and tostring(row.pack_cover_url) or ""
          if url == "" then
            if r.ImGui_Dummy then
              r.ImGui_Dummy(ctx, SAMPLE_LIST_THUMB, SAMPLE_LIST_THUMB)
            end
          else
            cover_art.draw_cell(
              ctx,
              state.runtime.cover_art,
              row.pack_id,
              url,
              SAMPLE_LIST_THUMB,
              true
            )
          end
        elseif r.ImGui_Dummy then
          r.ImGui_Dummy(ctx, SAMPLE_LIST_THUMB, SAMPLE_LIST_THUMB)
        end

        r.ImGui_TableSetColumnIndex(ctx, 1)
        local rid_for_sel = tonumber(row.id)
        local is_bulk_selected = rid_for_sel and (state.selected_sample_ids[rid_for_sel] == true) or false
        local label = row.filename or ""
        local is_playing_row = state.playing and (state.runtime.preview_path == row.path)
        if is_playing_row then
          label = "▶ " .. label
        end
        -- Keep Selectable's selected-state logic same as before for stable Ctrl/Shift behavior.
        local selected = (state.selected_row == row_idx)
        local selectable_clicked = false
        local selectable_flags = 0
        -- Keep hit-test inside filename column so Fav control remains easy to click.
        if r.ImGui_SelectableFlags_SpanAvailWidth then
          selectable_flags = selectable_flags | r.ImGui_SelectableFlags_SpanAvailWidth()
        end
        local ok_sel, sel_ret = pcall(function()
          return r.ImGui_Selectable(ctx, label, selected, selectable_flags)
        end)
        if ok_sel then
          selectable_clicked = sel_ret == true
        else
          selectable_clicked = r.ImGui_Selectable(ctx, label, selected) == true
        end
        if is_bulk_selected then
          draw_selected_overlay_for_last_item()
        end
        if selectable_clicked then
          local ctrl_down = imgui_mod_down("ctrl")
          local shift_down = imgui_mod_down("shift")
          if shift_down then
            local anchor = tonumber(state.runtime.selection_anchor_row_idx) or row_idx
            if anchor < 1 then anchor = 1 end
            if anchor > #state.rows then anchor = #state.rows end
            local a = math.min(anchor, row_idx)
            local b = math.max(anchor, row_idx)
            if not ctrl_down then
              bulk_clear_all_selection()
            end
            for i = a, b do
              bulk_set_row_selected(i, true)
            end
            set_selected_row(row_idx)
          elseif ctrl_down then
            bulk_toggle_sample_id(tonumber(row.id), nil)
            set_selected_row(row_idx)
            state.runtime.selection_anchor_row_idx = row_idx
          else
            bulk_clear_all_selection()
            bulk_set_row_selected(row_idx, true)
            state.runtime.selection_anchor_row_idx = row_idx
            local clicked_path = row.path
            local is_same_preview = state.playing and (state.runtime.preview_path == clicked_path)
            if is_same_preview then
              stop_preview()
              set_runtime_notice("Preview stopped.")
            else
              set_selected_row(row_idx, state.ui.auto_preview_on_select == true)
              if state.ui.auto_preview_on_select then
                play_selected_sample_preview()
              end
            end
          end
        end

        if r.ImGui_BeginPopupContextItem then
          local popup_id = "##sample_row_ctx_" .. tostring(row.id or row_idx)
          if r.ImGui_BeginPopupContextItem(ctx, popup_id) then
            local sel_n = bulk_selected_count()
            local row_id = tonumber(row.id)
            local row_in_multi = row_id and (state.selected_sample_ids[row_id] == true) and sel_n > 1
            if row_in_multi then
              if r.ImGui_Selectable(ctx, "Edit selected (" .. tostring(sel_n) .. ")...") then
                open_sample_edit_popup_for_ids(bulk_selected_ids_list(), row)
              end
            end
            if r.ImGui_Selectable(ctx, "Edit sample...") then
              open_sample_edit_popup_for_row(row)
            end
            r.ImGui_EndPopup(ctx)
          end
        end
        begin_drag_for_row(row, row_idx)

        r.ImGui_TableSetColumnIndex(ctx, 2)
        r.ImGui_Text(ctx, row.bpm and tostring(row.bpm) or "--")

        r.ImGui_TableSetColumnIndex(ctx, 3)
        local key_compact = key_label_compact(row.key_estimate)
        r.ImGui_Text(ctx, key_compact)
        if r.ImGui_IsItemHovered and r.ImGui_SetTooltip then
          local ok_h, hv = pcall(function() return r.ImGui_IsItemHovered(ctx) end)
          if ok_h and hv == true then
            local full = key_label_full_dual(row.key_estimate)
            pcall(function() r.ImGui_SetTooltip(ctx, full) end)
          end
        end

        local function center_next_item_in_column(item_w)
          if not (r.ImGui_GetContentRegionAvail and r.ImGui_GetCursorPosX and r.ImGui_SetCursorPosX) then return end
          local ok_avail, avail_w = pcall(function()
            local aw = r.ImGui_GetContentRegionAvail(ctx)
            if type(aw) == "number" then return aw end
            return select(1, aw)
          end)
          local ok_x, cur_x = pcall(function() return r.ImGui_GetCursorPosX(ctx) end)
          if not (ok_avail and ok_x and type(avail_w) == "number" and type(cur_x) == "number") then return end
          local dx = math.floor(math.max(0, (avail_w - (tonumber(item_w) or 0)) * 0.5))
          if dx > 0 then
            pcall(function() r.ImGui_SetCursorPosX(ctx, cur_x + dx) end)
          end
        end
        r.ImGui_TableSetColumnIndex(ctx, 4)
        if state.store.available and sqlite_store and type(sqlite_store.set_sample_favorite) == "function" and tonumber(row.id) then
          local rid = tonumber(row.id)
          local fav_on = row.is_favorite == true
          local checkbox_w = 18
          if r.ImGui_GetFrameHeight then
            local ok_h, h = pcall(function() return r.ImGui_GetFrameHeight(ctx) end)
            if ok_h and type(h) == "number" and h > 0 then
              checkbox_w = h
            end
          end
          center_next_item_in_column(checkbox_w)
          local fav_changed, fav_next = r.ImGui_Checkbox(ctx, "##fav_ck_" .. tostring(row.id) .. "_" .. tostring(row_idx), fav_on)
          if fav_changed then
            local want = fav_next == true
            local selected_n = bulk_selected_count()
            local row_in_multi = (state.selected_sample_ids[rid] == true) and selected_n > 1
            if row_in_multi then
              local ok_all = true
              for sid, on_sel in pairs(state.selected_sample_ids or {}) do
                if on_sel == true then
                  local sid_n = tonumber(sid)
                  if sid_n then
                    local ok_pcall, ok_db = pcall(function()
                      return sqlite_store.set_sample_favorite({ db = state.store.conn }, sid_n, want)
                    end)
                    if not (ok_pcall and ok_db) then
                      ok_all = false
                    end
                  end
                end
              end
              if ok_all then
                for _, rrow in ipairs(state.rows or {}) do
                  local sid = tonumber(rrow and rrow.id)
                  if sid and state.selected_sample_ids[sid] == true then
                    rrow.is_favorite = want == true
                  end
                end
                if state.ui.favorites_only_filter == true and want == false then
                  set_runtime_notice("Favorites removed for selected samples. List updates on next filter change.")
                end
              else
                set_runtime_notice("Could not update favorites for selected samples.")
              end
            else
              local ok_pcall, ok_db = pcall(function()
                return sqlite_store.set_sample_favorite({ db = state.store.conn }, rid, want)
              end)
              if ok_pcall and ok_db then
                row.is_favorite = want == true
                if state.ui.favorites_only_filter == true and want == false then
                  set_runtime_notice("Favorite removed. List updates on next filter change.")
                end
              else
                set_runtime_notice("Could not update favorite.")
              end
            end
          end
        else
          r.ImGui_Text(ctx, "--")
        end
      end

      draw_rows_virtualized(#state.rows, draw_row, "sample_row_clipper")
      r.ImGui_EndTable(ctx)
    end
    r.ImGui_EndChild(ctx)
  end
  r.ImGui_PopStyleVar(ctx, 1)
  safe_pop_font(pushed_font)
end

return M
