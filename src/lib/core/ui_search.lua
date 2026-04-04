local M = {}

local r = nil
local ctx = nil
local state = nil
local sqlite_store = nil

local safe_push_font = nil
local safe_pop_font = nil
local calc_text_w = nil
local should_accept_toggle_click = nil
local parse_optional_number = nil
local ui_input_text_with_hint = nil
local window_flag_noresize = nil
local window_flag_noscroll_with_mouse = nil
local filter_tags_has = nil
local filter_tags_clear_all = nil
local filter_tags_remove_at = nil
local filter_tags_remove_value = nil
local filter_tags_add_unique = nil
local filter_tags_exclude_has = nil
local filter_tags_exclude_remove_at = nil
local filter_tags_exclude_remove_value = nil
local filter_tags_exclude_add_unique = nil
local draw_text_only_button = nil
local content_width = nil
local tag_chip_label_short = nil
local draw_wrapped_tag_chips = nil
local calc_text_w_fallback = nil
local tag_chip_min_w = 40
local tag_chip_max_w_filter = 180
local font_small = nil
local get_project_bpm = nil
local search_ui = nil

local BPM_FILTER_MIN = 20
local BPM_FILTER_MAX = 400
local BPM_AUTO_WINDOW_MIN = 1
local BPM_AUTO_WINDOW_MAX = 64
local BPM_AUTO_PERCENT_MIN = 1
local BPM_AUTO_PERCENT_MAX = 50
local KEY_SHARP_TO_FLAT = {
  ["C#"] = "Db",
  ["D#"] = "Eb",
  ["F#"] = "Gb",
  ["G#"] = "Ab",
  ["A#"] = "Bb",
}

local DEFAULT_SEARCH_UI = {
  font_small_px = 11,
  top_btn_h = 20,
  top_spacing = 6,
  top_toggle_gap = 4,
  key_btn_min_w = 78,
  key_btn_max_w = 160,
  key_btn_fallback_text_w = 54,
  key_btn_pad_w = 24,
  bpm_btn_min_w = 78,
  bpm_btn_max_w = 190,
  bpm_btn_fallback_text_w = 54,
  bpm_btn_pad_w = 24,
  type_btn_min_w = 120,
  type_btn_max_w = 230,
  type_btn_fallback_text_w = 80,
  type_btn_pad_w = 24,
  key_root_btn_w = 108,
  key_mode_btn_w = 60,
  popup_btn_h = 18,
  bpm_input_w = 72,
  type_oneshot_btn_w = 96,
  type_loop_btn_w = 84,
  bpm_mode_rel_btn_w = 120,
  bpm_mode_abs_btn_w = 130,
  active_tags_child_h = 32,
  active_tag_chip_h = 20,
  tag_chip_h = 18,
  tag_chip_rounding = 3.0,
  tag_chip_text_col = 0xC8C9CDFF,
  tag_suggestions_max_h = 160,
  tag_suggestions_visible_rows = 7,
  tag_suggestions_row_h = 22,
  tag_suggestions_base_h = 16,
}

local function ensure_fn(fn, fallback)
  if type(fn) == "function" then return fn end
  if type(fallback) == "function" then return fallback end
  return function() end
end

local function imgui_key_pressed_named(which)
  if not ctx or not r.ImGui_IsKeyPressed then return false end
  local key = nil
  if which == "enter" and r.ImGui_Key_Enter then
    local ok, k = pcall(function() return r.ImGui_Key_Enter() end)
    if ok then key = k end
  elseif which == "kpenter" and r.ImGui_Key_KeypadEnter then
    local ok, k = pcall(function() return r.ImGui_Key_KeypadEnter() end)
    if ok then key = k end
  end
  if key == nil then return false end
  local ok2, pr = pcall(function()
    return r.ImGui_IsKeyPressed(ctx, key, false)
  end)
  return ok2 and pr == true
end

local function clamp_number(v, min_v, max_v)
  local n = tonumber(v)
  if not n then return nil end
  if n < min_v then n = min_v end
  if n > max_v then n = max_v end
  return n
end

local function key_root_dual_label(root_raw)
  local root = tostring(root_raw or ""):upper():gsub("^%s+", ""):gsub("%s+$", "")
  local flat_to_sharp = { DB = "C#", EB = "D#", GB = "F#", AB = "G#", BB = "A#" }
  if flat_to_sharp[root] then root = flat_to_sharp[root] end
  local key_roots = { C = true, ["C#"] = true, D = true, ["D#"] = true, E = true, F = true, ["F#"] = true, G = true, ["G#"] = true, A = true, ["A#"] = true, B = true }
  if not key_roots[root] then return tostring(root_raw or "") end
  local flat = KEY_SHARP_TO_FLAT[root]
  if flat then return root .. " / " .. flat end
  return root
end

local function normalize_bpm_range(min_v, max_v)
  local nmin = clamp_number(min_v, BPM_FILTER_MIN, BPM_FILTER_MAX)
  local nmax = clamp_number(max_v, BPM_FILTER_MIN, BPM_FILTER_MAX)
  if nmin and nmax and nmin > nmax then
    nmin, nmax = nmax, nmin
  end
  return nmin, nmax
end

local function ui_slider_number(label, value, min_v, max_v, format_str)
  if r.ImGui_SliderDouble then
    local ok, changed, out_v = pcall(function()
      return r.ImGui_SliderDouble(ctx, label, tonumber(value) or min_v, min_v, max_v, format_str or "%.0f")
    end)
    if ok and type(changed) == "boolean" and type(out_v) == "number" then
      return changed, out_v, true
    end
    local ok2, changed2, out_v2 = pcall(function()
      return r.ImGui_SliderDouble(ctx, label, tonumber(value) or min_v, min_v, max_v)
    end)
    if ok2 and type(changed2) == "boolean" and type(out_v2) == "number" then
      return changed2, out_v2, true
    end
  end
  if r.ImGui_DragDouble then
    local ok3, changed3, out_v3 = pcall(function()
      return r.ImGui_DragDouble(ctx, label, tonumber(value) or min_v, 1.0, min_v, max_v, format_str or "%.0f")
    end)
    if ok3 and type(changed3) == "boolean" and type(out_v3) == "number" then
      return changed3, out_v3, true
    end
  end
  return false, tonumber(value) or min_v, false
end

local function apply_project_bpm_filter_range(project_bpm, auto_mode, amount)
  local pbpm = tonumber(project_bpm)
  if not pbpm or pbpm <= 0 then return nil, nil end
  local mode = tostring(auto_mode or "relative")
  local half = 0
  if mode == "absolute" then
    half = clamp_number(amount, BPM_AUTO_WINDOW_MIN, BPM_AUTO_WINDOW_MAX) or 8
  else
    local pct = clamp_number(amount, BPM_AUTO_PERCENT_MIN, BPM_AUTO_PERCENT_MAX) or 10
    half = pbpm * (pct / 100.0)
  end
  local auto_min = math.floor(pbpm - half + 0.5)
  local auto_max = math.floor(pbpm + half + 0.5)
  return normalize_bpm_range(auto_min, auto_max)
end

function M.setup(deps)
  deps = type(deps) == "table" and deps or {}
  r = deps.r
  ctx = deps.ctx
  state = deps.state
  sqlite_store = deps.sqlite_store
  safe_push_font = ensure_fn(deps.safe_push_font, function() return false end)
  safe_pop_font = ensure_fn(deps.safe_pop_font)
  calc_text_w = deps.calc_text_w
  should_accept_toggle_click = ensure_fn(deps.should_accept_toggle_click, function() return true end)
  parse_optional_number = ensure_fn(deps.parse_optional_number, function(s) return tonumber(s) end)
  ui_input_text_with_hint = ensure_fn(deps.ui_input_text_with_hint, function(id, _, v) return false, tostring(v or ""), id end)
  window_flag_noresize = ensure_fn(deps.window_flag_noresize, function() return 0 end)
  window_flag_noscroll_with_mouse = ensure_fn(deps.window_flag_noscroll_with_mouse, function() return 0 end)
  filter_tags_has = deps.filter_tags_has
  filter_tags_clear_all = deps.filter_tags_clear_all
  filter_tags_remove_at = deps.filter_tags_remove_at
  filter_tags_remove_value = deps.filter_tags_remove_value
  filter_tags_add_unique = deps.filter_tags_add_unique
  filter_tags_exclude_has = deps.filter_tags_exclude_has
  filter_tags_exclude_remove_at = deps.filter_tags_exclude_remove_at
  filter_tags_exclude_remove_value = deps.filter_tags_exclude_remove_value
  filter_tags_exclude_add_unique = deps.filter_tags_exclude_add_unique
  draw_text_only_button = deps.draw_text_only_button
  content_width = deps.content_width
  tag_chip_label_short = deps.tag_chip_label_short
  draw_wrapped_tag_chips = deps.draw_wrapped_tag_chips
  calc_text_w_fallback = deps.calc_text_w_fallback
  tag_chip_min_w = tonumber(deps.tag_chip_min_w) or 40
  tag_chip_max_w_filter = tonumber(deps.tag_chip_max_w_filter) or 180
  font_small = deps.font_small
  search_ui = {}
  local incoming_ui = type(deps.search_ui) == "table" and deps.search_ui or {}
  for k, v in pairs(DEFAULT_SEARCH_UI) do
    if type(v) == "number" then
      search_ui[k] = tonumber(incoming_ui[k]) or v
    else
      search_ui[k] = incoming_ui[k] ~= nil and incoming_ui[k] or v
    end
  end
  get_project_bpm = deps.get_project_bpm
  if type(get_project_bpm) ~= "function" then
    get_project_bpm = function()
      if not r then return nil end
      if type(r.Master_GetTempo) == "function" then
        local ok, bpm = pcall(function() return r.Master_GetTempo() end)
        if ok and type(bpm) == "number" and bpm > 0 then return bpm end
      end
      if type(r.TimeMap2_GetDividedBpmAtTime) == "function" then
        local t = 0
        if type(r.GetCursorPosition) == "function" then
          local ok_t, v = pcall(function() return r.GetCursorPosition() end)
          if ok_t and type(v) == "number" and v >= 0 then t = v end
        end
        local ok2, bpm2 = pcall(function() return r.TimeMap2_GetDividedBpmAtTime(0, t) end)
        if ok2 and type(bpm2) == "number" and bpm2 > 0 then return bpm2 end
      end
      return nil
    end
  end
  if type(calc_text_w) ~= "function" then
    calc_text_w = function(s, fallback)
      fallback = tonumber(fallback) or 42
      if type(r.ImGui_CalcTextSize) == "function" then
        local ok, w = pcall(function()
          local tw = r.ImGui_CalcTextSize(ctx, tostring(s or ""))
          if type(tw) == "number" then
            return tw
          end
          return select(1, tw)
        end)
        if ok and type(w) == "number" and w > 0 then
          return w
        end
      end
      return fallback
    end
  end
  if type(tag_chip_label_short) ~= "function" then
    tag_chip_label_short = function(tag, max_chars)
      local t = tostring(tag or "")
      max_chars = tonumber(max_chars) or 11
      if #t > max_chars then
        return t:sub(1, max_chars - 2) .. ".."
      end
      return t
    end
  end
  if type(filter_tags_has) ~= "function" then
    filter_tags_has = function(tags, tag)
      for i = 1, #(tags or {}) do
        if tags[i] == tag then return true end
      end
      return false
    end
  end
  if type(content_width) ~= "function" then
    content_width = function()
      if type(r.ImGui_GetContentRegionAvail) == "function" then
        local ok, w = pcall(function()
          local aw = r.ImGui_GetContentRegionAvail(ctx)
          if type(aw) == "number" then return aw end
          return select(1, aw)
        end)
        if ok and type(w) == "number" and w > 0 then return w end
      end
      return 320
    end
  end
  if type(draw_text_only_button) ~= "function" then
    draw_text_only_button = function(label, w, h)
      if type(r.ImGui_Button) == "function" then
        return r.ImGui_Button(ctx, tostring(label or ""), tonumber(w) or 0, tonumber(h) or 0) == true
      end
      return false
    end
  end
  if type(filter_tags_remove_value) ~= "function" then
    filter_tags_remove_value = function(tag)
      for i = #(state.filter_tags or {}), 1, -1 do
        if state.filter_tags[i] == tag then
          table.remove(state.filter_tags, i)
          state.needs_reload_samples = true
          return
        end
      end
    end
  end
  if type(filter_tags_add_unique) ~= "function" then
    filter_tags_add_unique = function(tag)
      local t = tostring(tag or ""):match("^%s*(.-)%s*$") or ""
      if t == "" then return end
      if not filter_tags_has(state.filter_tags, t) then
        if type(filter_tags_exclude_remove_value) == "function" then
          filter_tags_exclude_remove_value(t)
        end
        state.filter_tags[#state.filter_tags + 1] = t
        state.needs_reload_samples = true
      end
    end
  end
  if type(filter_tags_exclude_has) ~= "function" then
    filter_tags_exclude_has = function(tag)
      return filter_tags_has(state.filter_tags_exclude or {}, tag)
    end
  end
  if type(filter_tags_exclude_remove_value) ~= "function" then
    filter_tags_exclude_remove_value = function(tag)
      for i = #(state.filter_tags_exclude or {}), 1, -1 do
        if state.filter_tags_exclude[i] == tag then
          table.remove(state.filter_tags_exclude, i)
          state.needs_reload_samples = true
          return
        end
      end
    end
  end
  if type(filter_tags_exclude_add_unique) ~= "function" then
    filter_tags_exclude_add_unique = function(tag)
      local t = tostring(tag or ""):match("^%s*(.-)%s*$") or ""
      if t == "" then return end
      if not filter_tags_has(state.filter_tags_exclude, t) then
        filter_tags_remove_value(t)
        state.filter_tags_exclude[#state.filter_tags_exclude + 1] = t
        state.needs_reload_samples = true
      end
    end
  end
  if type(filter_tags_exclude_remove_at) ~= "function" then
    filter_tags_exclude_remove_at = function(idx)
      idx = tonumber(idx)
      if idx and idx >= 1 and idx <= #(state.filter_tags_exclude or {}) then
        table.remove(state.filter_tags_exclude, idx)
        state.needs_reload_samples = true
      end
    end
  end
  if type(filter_tags_clear_all) ~= "function" then
    filter_tags_clear_all = function()
      if #(state.filter_tags or {}) == 0 and #(state.filter_tags_exclude or {}) == 0 then return end
      state.filter_tags = {}
      state.filter_tags_exclude = {}
      state.needs_reload_samples = true
    end
  end
  if type(filter_tags_remove_at) ~= "function" then
    filter_tags_remove_at = function(idx)
      idx = tonumber(idx)
      if idx and idx >= 1 and idx <= #(state.filter_tags or {}) then
        table.remove(state.filter_tags, idx)
        state.needs_reload_samples = true
      end
    end
  end
  if type(draw_wrapped_tag_chips) ~= "function" then
    draw_wrapped_tag_chips = function(_ctx, tag_rows, chip_max_w, chip_h, id_prefix, active_filter_tags, on_toggle_tag)
      chip_max_w = tonumber(chip_max_w) or 180
      chip_h = tonumber(chip_h) or 18
      local avail = math.max(120, content_width())
      local used = 0
      for i, rr in ipairs(tag_rows or {}) do
        local tag = type(rr) == "table" and rr.tag or rr
        tag = tostring(tag or "")
        if tag ~= "" then
          local display = tag_chip_label_short(tag, 24)
          if filter_tags_has(active_filter_tags or {}, tag) then
            display = "*" .. display
          end
          local chip_w = math.floor(math.max(tag_chip_min_w, math.min(chip_max_w, calc_text_w(display, calc_text_w_fallback) + 22)))
          if used > 0 and (used + 4 + chip_w) > avail + 0.5 then
            used = 0
          else
            if used > 0 then
              r.ImGui_SameLine(ctx, 0, 4)
            end
          end
          local chip_push_var_n = 0
          local chip_push_col_n = 0
          if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FrameRounding then
            local ok_sv = pcall(function()
              r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), tonumber(search_ui.tag_chip_rounding) or 3.0)
            end)
            if ok_sv then chip_push_var_n = chip_push_var_n + 1 end
          end
          if r.ImGui_PushStyleVar and r.ImGui_StyleVar_ButtonTextAlign then
            local ok_align = pcall(function()
              r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ButtonTextAlign(), 0.5, 0.28)
            end)
            if ok_align then chip_push_var_n = chip_push_var_n + 1 end
          end
          if r.ImGui_PushStyleColor and r.ImGui_Col_Text then
            local ok_sc = pcall(function()
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), tonumber(search_ui.tag_chip_text_col) or 0xC8C9CDFF)
            end)
            if ok_sc then chip_push_col_n = chip_push_col_n + 1 end
          end
          local chip_id = display .. "##" .. tostring(id_prefix or "chip") .. "_" .. tostring(i)
          local left_clicked = r.ImGui_Button(ctx, chip_id, chip_w, chip_h)
          local right_clicked = false
          if r.ImGui_BeginPopupContextItem and r.ImGui_EndPopup then
            local popup_id = "##chip_ctx_" .. tostring(id_prefix or "chip") .. "_" .. tostring(i)
            if r.ImGui_BeginPopupContextItem(ctx, popup_id) then
              right_clicked = true
              r.ImGui_EndPopup(ctx)
            end
          end
          if type(on_toggle_tag) == "function" then
            if left_clicked then on_toggle_tag(tag, "include") end
            if right_clicked then on_toggle_tag(tag, "exclude") end
          end
          if chip_push_col_n > 0 and r.ImGui_PopStyleColor then
            pcall(function() r.ImGui_PopStyleColor(ctx, chip_push_col_n) end)
          end
          if chip_push_var_n > 0 and r.ImGui_PopStyleVar then
            pcall(function() r.ImGui_PopStyleVar(ctx, chip_push_var_n) end)
          end
          used = used + (used > 0 and 4 or 0) + chip_w
        end
      end
    end
  end
end

function M.draw(win_w)
  if not (r and ctx and state) then return end
  local pushed = safe_push_font(font_small, search_ui.font_small_px)
  do
    local key_caption = state.key_filter_enabled and ("Key: " .. key_root_dual_label(state.key_root or "E") .. " v") or "Key v"
    local bpm_caption = "BPM v"
    if state.bpm_filter_enabled then
      local minv = state.bpm_min and tostring(state.bpm_min) or "-"
      local maxv = state.bpm_max and tostring(state.bpm_max) or "-"
      bpm_caption = "BPM: " .. minv .. "~" .. maxv .. " v"
    end
    local type_caption = "One-Shots & Loops v"
    if state.type_filter_enabled then
      local parts = {}
      if state.type_is_one_shot then parts[#parts + 1] = "OS" end
      if state.type_is_loop then parts[#parts + 1] = "Loop" end
      if #parts > 0 then
        type_caption = "Type: " .. table.concat(parts, "/") .. " v"
      else
        type_caption = "Type: Any v"
      end
    end

    local btn_h = search_ui.top_btn_h
    local key_w = math.max(
      search_ui.key_btn_min_w,
      math.min(search_ui.key_btn_max_w, math.floor(calc_text_w(key_caption, search_ui.key_btn_fallback_text_w) + search_ui.key_btn_pad_w))
    )
    local bpm_w = math.max(
      search_ui.bpm_btn_min_w,
      math.min(search_ui.bpm_btn_max_w, math.floor(calc_text_w(bpm_caption, search_ui.bpm_btn_fallback_text_w) + search_ui.bpm_btn_pad_w))
    )
    local type_w = math.max(
      search_ui.type_btn_min_w,
      math.min(search_ui.type_btn_max_w, math.floor(calc_text_w(type_caption, search_ui.type_btn_fallback_text_w) + search_ui.type_btn_pad_w))
    )
    local spacing = search_ui.top_spacing

    local ch_key_top, key_top_on = r.ImGui_Checkbox(ctx, "##flt_key_enable_top", state.key_filter_enabled == true)
    if ch_key_top then
      state.key_filter_enabled = key_top_on == true
      state.needs_reload_samples = true
    end
    r.ImGui_SameLine(ctx, 0, search_ui.top_toggle_gap)
    if r.ImGui_Button(ctx, key_caption .. "##flt_key_btn", key_w, btn_h) then
      r.ImGui_OpenPopup(ctx, "##flt_key_popup")
    end
    r.ImGui_SameLine(ctx, 0, spacing)
    local ch_bpm_top, bpm_top_on = r.ImGui_Checkbox(ctx, "##flt_bpm_enable_top", state.bpm_filter_enabled == true)
    if ch_bpm_top then
      state.bpm_filter_enabled = bpm_top_on == true
      state.needs_reload_samples = true
    end
    r.ImGui_SameLine(ctx, 0, search_ui.top_toggle_gap)
    if r.ImGui_Button(ctx, bpm_caption .. "##flt_bpm_btn", bpm_w, btn_h) then
      r.ImGui_OpenPopup(ctx, "##flt_bpm_popup")
    end
    r.ImGui_SameLine(ctx, 0, spacing)
    local ch_type_top, type_top_on = r.ImGui_Checkbox(ctx, "##flt_type_enable_top", state.type_filter_enabled == true)
    if ch_type_top then
      state.type_filter_enabled = type_top_on == true
      state.needs_reload_samples = true
    end
    r.ImGui_SameLine(ctx, 0, search_ui.top_toggle_gap)
    if r.ImGui_Button(ctx, type_caption .. "##flt_type_btn", type_w, btn_h) then
      r.ImGui_OpenPopup(ctx, "##flt_type_popup")
    end
    r.ImGui_SameLine(ctx, 0, spacing)
    local changed_fav_only, fav_only_on = r.ImGui_Checkbox(ctx, "Favorites only", state.ui.favorites_only_filter == true)
    if changed_fav_only then
      state.ui.favorites_only_filter = fav_only_on == true
      state.needs_reload_samples = true
    end

    if r.ImGui_BeginPopup(ctx, "##flt_key_popup") then
      local key_roots = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
      local key_label = key_root_dual_label(state.key_root or "E")
      if r.ImGui_Button(ctx, key_label .. "##key_popup_root", search_ui.key_root_btn_w, search_ui.popup_btn_h) then
        r.ImGui_OpenPopup(ctx, "##key_root_popup")
      end
      if r.ImGui_BeginPopup(ctx, "##key_root_popup") then
        for _, k in ipairs(key_roots) do
          if r.ImGui_Selectable(ctx, key_root_dual_label(k), state.key_root == k) then
            state.key_root = k
            state.key_filter_enabled = true
            state.needs_reload_samples = true
          end
        end
        r.ImGui_EndPopup(ctx)
      end
      r.ImGui_SameLine(ctx, 0, search_ui.top_toggle_gap)
      local minor_label = (state.key_mode_minor and "● min" or "○ min") .. "##key_mode_min"
      if r.ImGui_Button(ctx, minor_label, search_ui.key_mode_btn_w, search_ui.popup_btn_h) then
        state.key_mode_minor = not state.key_mode_minor
        state.key_filter_enabled = true
        state.needs_reload_samples = true
      end
      r.ImGui_SameLine(ctx, 0, search_ui.top_toggle_gap)
      local major_label = (state.key_mode_major and "● maj" or "○ maj") .. "##key_mode_maj"
      if r.ImGui_Button(ctx, major_label, search_ui.key_mode_btn_w, search_ui.popup_btn_h) then
        state.key_mode_major = not state.key_mode_major
        state.key_filter_enabled = true
        state.needs_reload_samples = true
      end
      r.ImGui_EndPopup(ctx)
    end

    if r.ImGui_BeginPopup(ctx, "##flt_bpm_popup") then
      local min_str = state.bpm_min and tostring(state.bpm_min) or ""
      local max_str = state.bpm_max and tostring(state.bpm_max) or ""
      r.ImGui_PushItemWidth(ctx, search_ui.bpm_input_w)
      local ok_min, tmin = ui_input_text_with_hint("##bpm_min", "Min BPM", min_str, 32)
      if ok_min then
        state.bpm_min = clamp_number(parse_optional_number(tmin), BPM_FILTER_MIN, BPM_FILTER_MAX)
        state.bpm_filter_enabled = true
        state.needs_reload_samples = true
      end
      r.ImGui_SameLine(ctx, 0, 6)
      local ok_max, tmax = ui_input_text_with_hint("##bpm_max", "Max BPM", max_str, 32)
      if ok_max then
        state.bpm_max = clamp_number(parse_optional_number(tmax), BPM_FILTER_MIN, BPM_FILTER_MAX)
        state.bpm_filter_enabled = true
        state.needs_reload_samples = true
      end
      r.ImGui_PopItemWidth(ctx)
      state.bpm_min, state.bpm_max = normalize_bpm_range(state.bpm_min, state.bpm_max)

      local slider_min = tonumber(state.bpm_min) or BPM_FILTER_MIN
      local slider_max = tonumber(state.bpm_max) or BPM_FILTER_MAX
      slider_min, slider_max = normalize_bpm_range(slider_min, slider_max)

      local ch_slider_min, out_slider_min, slider_supported = ui_slider_number(
        "Min slider##bpm_min_slider",
        slider_min,
        BPM_FILTER_MIN,
        BPM_FILTER_MAX,
        "%.0f"
      )
      if slider_supported and ch_slider_min then
        state.bpm_min = math.floor((out_slider_min or slider_min) + 0.5)
        if state.bpm_max and state.bpm_min and state.bpm_min > state.bpm_max then
          state.bpm_max = state.bpm_min
        end
        state.bpm_filter_enabled = true
        state.needs_reload_samples = true
      end

      local ch_slider_max, out_slider_max, slider_supported2 = ui_slider_number(
        "Max slider##bpm_max_slider",
        slider_max,
        BPM_FILTER_MIN,
        BPM_FILTER_MAX,
        "%.0f"
      )
      if slider_supported2 and ch_slider_max then
        state.bpm_max = math.floor((out_slider_max or slider_max) + 0.5)
        if state.bpm_min and state.bpm_max and state.bpm_max < state.bpm_min then
          state.bpm_min = state.bpm_max
        end
        state.bpm_filter_enabled = true
        state.needs_reload_samples = true
      end

      local project_bpm = get_project_bpm and get_project_bpm() or nil
      if project_bpm then
        state.runtime = state.runtime or {}
        local auto_mode = tostring(state.runtime.search_bpm_auto_mode or "relative")
        if auto_mode ~= "relative" and auto_mode ~= "absolute" then auto_mode = "relative" end
        state.runtime.search_bpm_auto_mode = auto_mode

        if r.ImGui_Button(
          ctx,
          ((auto_mode == "relative") and "● Relative (%)" or "○ Relative (%)") .. "##bpm_auto_mode_relative",
          search_ui.bpm_mode_rel_btn_w,
          search_ui.popup_btn_h
        ) then
          state.runtime.search_bpm_auto_mode = "relative"
          auto_mode = "relative"
        end
        r.ImGui_SameLine(ctx, 0, 6)
        if r.ImGui_Button(
          ctx,
          ((auto_mode == "absolute") and "● Absolute (BPM)" or "○ Absolute (BPM)") .. "##bpm_auto_mode_absolute",
          search_ui.bpm_mode_abs_btn_w,
          search_ui.popup_btn_h
        ) then
          state.runtime.search_bpm_auto_mode = "absolute"
          auto_mode = "absolute"
        end

        if auto_mode == "absolute" then
          local window_v = tonumber(state.runtime.search_bpm_auto_window) or 8
          window_v = clamp_number(window_v, BPM_AUTO_WINDOW_MIN, BPM_AUTO_WINDOW_MAX) or 8
          state.runtime.search_bpm_auto_window = window_v
          local ch_window, out_window, window_slider_supported = ui_slider_number(
            "Tolerance (+/- BPM)##bpm_project_window",
            window_v,
            BPM_AUTO_WINDOW_MIN,
            BPM_AUTO_WINDOW_MAX,
            "%.0f"
          )
          if window_slider_supported and ch_window then
            state.runtime.search_bpm_auto_window = math.floor((out_window or window_v) + 0.5)
          end
          if r.ImGui_Button(
            ctx,
            string.format("Use project BPM %.1f +/- %d##bpm_apply_project_abs", project_bpm, state.runtime.search_bpm_auto_window),
            -1,
            0
          ) then
            local auto_min, auto_max = apply_project_bpm_filter_range(
              project_bpm,
              "absolute",
              state.runtime.search_bpm_auto_window
            )
            state.bpm_min = auto_min
            state.bpm_max = auto_max
            state.bpm_filter_enabled = true
            state.needs_reload_samples = true
          end
        else
          local percent_v = tonumber(state.runtime.search_bpm_auto_percent) or 10
          percent_v = clamp_number(percent_v, BPM_AUTO_PERCENT_MIN, BPM_AUTO_PERCENT_MAX) or 10
          state.runtime.search_bpm_auto_percent = percent_v
          local ch_percent, out_percent, percent_slider_supported = ui_slider_number(
            "Tolerance (+/- %)##bpm_project_percent",
            percent_v,
            BPM_AUTO_PERCENT_MIN,
            BPM_AUTO_PERCENT_MAX,
            "%.0f%%"
          )
          if percent_slider_supported and ch_percent then
            state.runtime.search_bpm_auto_percent = math.floor((out_percent or percent_v) + 0.5)
          end
          if r.ImGui_Button(
            ctx,
            string.format("Use project BPM %.1f +/- %d%%%%##bpm_apply_project_rel", project_bpm, state.runtime.search_bpm_auto_percent),
            -1,
            0
          ) then
            local auto_min, auto_max = apply_project_bpm_filter_range(
              project_bpm,
              "relative",
              state.runtime.search_bpm_auto_percent
            )
            state.bpm_min = auto_min
            state.bpm_max = auto_max
            state.bpm_filter_enabled = true
            state.needs_reload_samples = true
          end
        end
      end
      r.ImGui_EndPopup(ctx)
    end

    if r.ImGui_BeginPopup(ctx, "##flt_type_popup") then
      local oneshot_label = (state.type_is_one_shot and "● oneshot" or "○ oneshot") .. "##type_oneshot"
      if r.ImGui_Button(ctx, oneshot_label, search_ui.type_oneshot_btn_w, search_ui.popup_btn_h) then
        if should_accept_toggle_click(state.ui.last_toggle_click, "type_oneshot", 0.12) then
          if state.type_is_one_shot and not state.type_is_loop then
            state.type_is_one_shot = false
          else
            state.type_is_one_shot = true
            state.type_is_loop = false
          end
          state.type_filter_enabled = true
          state.needs_reload_samples = true
        end
      end
      r.ImGui_SameLine(ctx, 0, 6)
      local loop_label = (state.type_is_loop and "● loops" or "○ loops") .. "##type_loops"
      if r.ImGui_Button(ctx, loop_label, search_ui.type_loop_btn_w, search_ui.popup_btn_h) then
        if should_accept_toggle_click(state.ui.last_toggle_click, "type_loops", 0.12) then
          if state.type_is_loop and not state.type_is_one_shot then
            state.type_is_loop = false
          else
            state.type_is_loop = true
            state.type_is_one_shot = false
          end
          state.type_filter_enabled = true
          state.needs_reload_samples = true
        end
      end
      r.ImGui_EndPopup(ctx)
    end
  end

  do
    r.ImGui_Separator(ctx)
    local fts = state.filter_tags
    local fts_ex = state.filter_tags_exclude or {}
    r.ImGui_Text(ctx, "Active tags:")
    if #state.filter_tags > 0 or #fts_ex > 0 then
      r.ImGui_SameLine(ctx, 0, 8)
      if r.ImGui_SmallButton(ctx, "Clear all##tag_clear_all") then
        filter_tags_clear_all()
      end
      r.ImGui_SameLine(ctx, 0, 8)
    else
      r.ImGui_SameLine(ctx, 0, 8)
    end
    if #fts == 0 and #fts_ex == 0 then
      r.ImGui_Text(ctx, "(none)")
    else
      local remove_idx = nil
      local remove_is_exclude = false
      local chip_n = 0
      for i, ft in ipairs(fts) do
        local tag = tostring(ft or "")
        if tag ~= "" then
          chip_n = chip_n + 1
          local display = "x " .. tag_chip_label_short(tag, 24)
          local text_w = calc_text_w(display, calc_text_w_fallback)
          local chip_w = math.floor(math.max(tag_chip_min_w, math.min(tag_chip_max_w_filter, text_w + 22)))
          if chip_n > 1 then r.ImGui_SameLine(ctx, 0, 4) end
          local chip_push_var_n = 0
          local chip_push_col_n = 0
          if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FrameRounding then
            local ok_sv = pcall(function()
              r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), tonumber(search_ui.tag_chip_rounding) or 3.0)
            end)
            if ok_sv then chip_push_var_n = chip_push_var_n + 1 end
          end
          if r.ImGui_PushStyleVar and r.ImGui_StyleVar_ButtonTextAlign then
            local ok_align = pcall(function()
              r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ButtonTextAlign(), 0.5, 0.28)
            end)
            if ok_align then chip_push_var_n = chip_push_var_n + 1 end
          end
          if r.ImGui_PushStyleColor and r.ImGui_Col_Button then
            local ok_btn = pcall(function()
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xF0F0F0FF)
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0xF0F0F0FF)
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0xF0F0F0FF)
            end)
            if ok_btn then chip_push_col_n = chip_push_col_n + 3 end
          end
          if r.ImGui_PushStyleColor and r.ImGui_Col_Text then
            local ok_sc = pcall(function()
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x1A1A1AFF)
            end)
            if ok_sc then chip_push_col_n = chip_push_col_n + 1 end
          end
          if r.ImGui_Button(ctx, display .. "##active_tag_" .. tostring(i), chip_w, search_ui.active_tag_chip_h) then
            remove_idx = i
            remove_is_exclude = false
          end
          local right_clicked = false
          if r.ImGui_BeginPopupContextItem and r.ImGui_EndPopup then
            local popup_id = "##active_tag_ctx_" .. tostring(i)
            if r.ImGui_BeginPopupContextItem(ctx, popup_id) then
              right_clicked = true
              r.ImGui_EndPopup(ctx)
            end
          end
          if right_clicked then
            filter_tags_exclude_add_unique(tag)
          end
          if chip_push_col_n > 0 and r.ImGui_PopStyleColor then
            pcall(function() r.ImGui_PopStyleColor(ctx, chip_push_col_n) end)
          end
          if chip_push_var_n > 0 and r.ImGui_PopStyleVar then
            pcall(function() r.ImGui_PopStyleVar(ctx, chip_push_var_n) end)
          end
        end
      end
      for i, ft in ipairs(fts_ex) do
        local tag = tostring(ft or "")
        if tag ~= "" then
          chip_n = chip_n + 1
          local display = "x - " .. tag_chip_label_short(tag, 24)
          local text_w = calc_text_w(display, calc_text_w_fallback)
          local chip_w = math.floor(math.max(tag_chip_min_w, math.min(tag_chip_max_w_filter, text_w + 22)))
          if chip_n > 1 then r.ImGui_SameLine(ctx, 0, 4) end
          local chip_push_var_n = 0
          local chip_push_col_n = 0
          if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FrameRounding then
            local ok_sv = pcall(function()
              r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), tonumber(search_ui.tag_chip_rounding) or 3.0)
            end)
            if ok_sv then chip_push_var_n = chip_push_var_n + 1 end
          end
          if r.ImGui_PushStyleVar and r.ImGui_StyleVar_ButtonTextAlign then
            local ok_align = pcall(function()
              r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ButtonTextAlign(), 0.5, 0.28)
            end)
            if ok_align then chip_push_var_n = chip_push_var_n + 1 end
          end
          if r.ImGui_PushStyleColor and r.ImGui_Col_Button then
            local ok_btn = pcall(function()
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D2E33FF)
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x393A40FF)
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x44464DFF)
            end)
            if ok_btn then chip_push_col_n = chip_push_col_n + 3 end
          end
          if r.ImGui_PushStyleColor and r.ImGui_Col_Text then
            local ok_sc = pcall(function()
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xF2F2F2FF)
            end)
            if ok_sc then chip_push_col_n = chip_push_col_n + 1 end
          end
          if r.ImGui_Button(ctx, display .. "##active_tag_ex_" .. tostring(i), chip_w, search_ui.active_tag_chip_h) then
            remove_idx = i
            remove_is_exclude = true
          end
          local right_clicked = false
          if r.ImGui_BeginPopupContextItem and r.ImGui_EndPopup then
            local popup_id = "##active_tag_ex_ctx_" .. tostring(i)
            if r.ImGui_BeginPopupContextItem(ctx, popup_id) then
              right_clicked = true
              r.ImGui_EndPopup(ctx)
            end
          end
          if right_clicked then
            filter_tags_add_unique(tag)
          end
          if chip_push_col_n > 0 and r.ImGui_PopStyleColor then
            pcall(function() r.ImGui_PopStyleColor(ctx, chip_push_col_n) end)
          end
          if chip_push_var_n > 0 and r.ImGui_PopStyleVar then
            pcall(function() r.ImGui_PopStyleVar(ctx, chip_push_var_n) end)
          end
        end
      end
      if remove_idx then
        if remove_is_exclude then
          filter_tags_exclude_remove_at(remove_idx)
        else
          filter_tags_remove_at(remove_idx)
        end
      end
    end

    r.ImGui_PushItemWidth(ctx, -1)
    local changed_inp, new_inp = ui_input_text_with_hint(
      "##tag_filter_input",
      "Search filename/tags... (Enter adds first suggestion)",
      state.tag_filter_input,
      256
    )
    r.ImGui_PopItemWidth(ctx)
    if changed_inp then
      state.tag_filter_input = new_inp
      state.needs_reload_samples = true
    end

    local input_focused = false
    if r.ImGui_IsItemActive then
      input_focused = r.ImGui_IsItemActive(ctx) == true
    end
    if not input_focused and r.ImGui_IsItemFocused then
      local okf, fv = pcall(function()
        return r.ImGui_IsItemFocused(ctx)
      end)
      if okf and fv then input_focused = true end
    end

    local inp_trim = (state.tag_filter_input or ""):match("^%s*(.-)%s*$") or ""
    local show_suggestions = (#inp_trim >= 1) and (input_focused == true)
    local sugg = {}
    local filter_sig = table.concat(state.filter_tags or {}, "|")
    local filter_sig_ex = table.concat(state.filter_tags_exclude or {}, "|")
    if show_suggestions and state.store.available and state.store.conn and sqlite_store and type(sqlite_store.get_tag_filter_suggestions) == "function" then
      state.runtime.tag_sugg_cache_key_next = string.format("q:%s|f:%s|fx:%s|l:%d", inp_trim, filter_sig, filter_sig_ex, 40)
      state.runtime.tag_sugg_cache_use = false
      if state.runtime.tag_sugg_cache_key == state.runtime.tag_sugg_cache_key_next then
        state.runtime.tag_sugg_cache_age = ((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(state.runtime.tag_sugg_cache_at) or 0)
        if state.runtime.tag_sugg_cache_age >= 0 and state.runtime.tag_sugg_cache_age <= 0.18 then
          state.runtime.tag_sugg_cache_use = true
        end
      end
      if state.runtime.tag_sugg_cache_use and type(state.runtime.tag_sugg_cache_rows) == "table" then
        sugg = state.runtime.tag_sugg_cache_rows
      else
        pcall(function()
          local raw = sqlite_store.get_tag_filter_suggestions(
            { db = state.store.conn },
            { limit = 40, name_contains = inp_trim, filter_tags = state.filter_tags }
          ) or {}
          local next_rows = {}
          for _, row in ipairs(raw) do
            local tg = row.tag and tostring(row.tag) or ""
            if tg ~= "" and not filter_tags_has(state.filter_tags, tg) and not filter_tags_exclude_has(tg) then
              next_rows[#next_rows + 1] = row
            end
          end
          state.runtime.tag_sugg_cache_key = state.runtime.tag_sugg_cache_key_next
          state.runtime.tag_sugg_cache_rows = next_rows
          state.runtime.tag_sugg_cache_at = (r.time_precise and r.time_precise()) or os.clock()
          sugg = next_rows
        end)
      end
    end

    if show_suggestions then
      if #sugg > 0 then
        local sugg_h = math.min(
          search_ui.tag_suggestions_max_h,
          search_ui.tag_suggestions_base_h + search_ui.tag_suggestions_row_h * math.min(#sugg, search_ui.tag_suggestions_visible_rows)
        )
        if r.ImGui_BeginChild(ctx, "##tag_suggestions", 0, sugg_h, 1, 0) then
          for i, row in ipairs(sugg) do
            local tg = tostring(row.tag or "")
            local cnt = tonumber(row.count) or 0
            local line = tg .. " (" .. tostring(cnt) .. ")##sugg_" .. tostring(i)
            local hi = (i == 1)
            local picked = false
            if r.ImGui_Selectable then
              picked = r.ImGui_Selectable(ctx, line, hi)
            elseif r.ImGui_Button then
              picked = r.ImGui_Button(ctx, line, -1, 20)
            end
            if picked then
              filter_tags_add_unique(tg)
              state.tag_filter_input = ""
            end
          end
          r.ImGui_EndChild(ctx)
        end
      end

      if input_focused and #sugg > 0 then
        if imgui_key_pressed_named("enter") or imgui_key_pressed_named("kpenter") then
          local row = sugg[1]
          if row and row.tag then
            filter_tags_add_unique(tostring(row.tag))
            state.tag_filter_input = ""
          end
        end
      end
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Popular tags")
      local chip_rows = {}
      if state.store.available and state.store.conn and sqlite_store then
        state.runtime.tag_pop_cache_key_next = string.format("pop:q:%s|f:%s|fx:%s|l:%d", inp_trim, filter_sig, filter_sig_ex, 20)
        state.runtime.tag_pop_cache_use = false
        if state.runtime.tag_pop_cache_key == state.runtime.tag_pop_cache_key_next then
          state.runtime.tag_pop_cache_age = ((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(state.runtime.tag_pop_cache_at) or 0)
          if state.runtime.tag_pop_cache_age >= 0 and state.runtime.tag_pop_cache_age <= 0.22 then
            state.runtime.tag_pop_cache_use = true
          end
        end
        if state.runtime.tag_pop_cache_use and type(state.runtime.tag_pop_cache_rows) == "table" then
          chip_rows = state.runtime.tag_pop_cache_rows
        else
          pcall(function()
            if (#state.filter_tags > 0) or (#(state.filter_tags_exclude or {}) > 0) or (inp_trim ~= "") then
              if type(sqlite_store.get_tag_filter_suggestions) == "function" then
                chip_rows = sqlite_store.get_tag_filter_suggestions(
                  { db = state.store.conn },
                  {
                    limit = 20,
                    filter_tags = state.filter_tags,
                    name_contains = inp_trim ~= "" and inp_trim or nil,
                  }
                ) or {}
              end
            elseif type(sqlite_store.get_tags_by_usage) == "function" then
              chip_rows = sqlite_store.get_tags_by_usage({ db = state.store.conn }, { limit = 20 }) or {}
            end
            state.runtime.tag_pop_cache_key = state.runtime.tag_pop_cache_key_next
            state.runtime.tag_pop_cache_rows = chip_rows
            state.runtime.tag_pop_cache_at = (r.time_precise and r.time_precise()) or os.clock()
          end)
        end
      end
      if #chip_rows > 0 then
        draw_wrapped_tag_chips(ctx, chip_rows, tag_chip_max_w_filter, search_ui.tag_chip_h, "top_tag", state.filter_tags, function(tag, action)
          if action == "exclude" then
            filter_tags_exclude_add_unique(tag)
          else
            if filter_tags_has(state.filter_tags, tag) then
              filter_tags_remove_value(tag)
            else
              filter_tags_add_unique(tag)
            end
          end
        end)
      else
        r.ImGui_TextWrapped(ctx, "No matching popular tags. Clear the input or add tags via Splice import.")
      end
  end

  safe_pop_font(pushed)
end

return M
