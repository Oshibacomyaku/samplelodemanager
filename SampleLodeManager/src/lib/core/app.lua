-- @noindex
local r = reaper

local M = {}

local ctx = nil
local state = nil
local font_main = nil
local font_small = nil
local sep = package.config:sub(1, 1)

-- Bundle keys/constants into tables to stay under Lua's ~200 locals-per-chunk limit.
local XS = {
  section = "SampleLodeManager",
  running = "running_instance",
  heartbeat = "running_heartbeat",
  splice_db_path = "splice_db_path",
  splice_relink_roots = "splice_relink_roots",
  ui_pack_collapsed = "ui_pack_panel_collapsed",
  ui_search_collapsed = "ui_search_panel_collapsed",
  ui_pack_h = "ui_panel_pack_h_px",
  ui_search_h = "ui_panel_search_h_px",
  ui_list_h = "ui_panel_list_h_px",
  ui_dock_id = "ui_dock_id",
  ui_preview_gain = "ui_preview_gain",
  ui_match_preview_bpm = "ui_match_preview_to_project_bpm",
  ui_match_insert_bpm = "ui_match_insert_to_project_bpm",
}

local ui_theme = nil
do
  local ok, mod = pcall(require, "lib.core.ui_theme")
  if ok then ui_theme = mod end
end

local C = {}
if ui_theme and type(ui_theme.default_constants) == "function" then
  local loaded = ui_theme.default_constants()
  if type(loaded) == "table" then
    C = loaded
  end
end
if C.SCRIPT_TITLE == nil then C.SCRIPT_TITLE = "Sample Lode Manager" end
if C.DEBUG_MINIMAL_LAYOUT == nil then C.DEBUG_MINIMAL_LAYOUT = false end
if C.GALAXY_VERBOSE_UPDATE_NOTICE == nil then C.GALAXY_VERBOSE_UPDATE_NOTICE = false end
if C.STYLE_WINDOW_ROUNDING == nil then C.STYLE_WINDOW_ROUNDING = 0.0 end
if C.STYLE_CHILD_ROUNDING == nil then C.STYLE_CHILD_ROUNDING = 0.0 end
if C.STYLE_TAB_ROUNDING == nil then C.STYLE_TAB_ROUNDING = 0.0 end
if C.STYLE_GRAB_ROUNDING == nil then C.STYLE_GRAB_ROUNDING = 0.0 end
if C.STYLE_FRAME_ROUNDING == nil then C.STYLE_FRAME_ROUNDING = 10.0 end
if C.STYLE_BORDER_SIZE == nil then C.STYLE_BORDER_SIZE = 0.0 end
if C.SEARCH_PANEL_MAX_H_PX == nil then C.SEARCH_PANEL_MAX_H_PX = 170 end
if C.ASYNC_SCAN_STEP_BUDGET == nil then C.ASYNC_SCAN_STEP_BUDGET = 8 end
if C.PACK_LIST_ROW_MIN_H == nil then C.PACK_LIST_ROW_MIN_H = 32 end
if C.PACK_LIST_THUMB == nil then C.PACK_LIST_THUMB = 28 end
if C.ACTIVE_PACK_STRIP_H == nil then C.ACTIVE_PACK_STRIP_H = 34 end
if C.ACTIVE_PACK_CHIP_PAD_Y == nil then C.ACTIVE_PACK_CHIP_PAD_Y = 2 end
if C.ACTIVE_PACK_SCROLLBAR_SIZE == nil then C.ACTIVE_PACK_SCROLLBAR_SIZE = 10 end
if C.DETAIL_TAGS_SCROLLBAR_SIZE == nil then C.DETAIL_TAGS_SCROLLBAR_SIZE = 8 end
if C.DETAIL_TAGS_STRIP_H == nil then C.DETAIL_TAGS_STRIP_H = 32 end
if C.DETAIL_PANEL_MIN_H == nil then C.DETAIL_PANEL_MIN_H = 210 end
if C.SAMPLE_SECTION_MIN_H == nil then C.SAMPLE_SECTION_MIN_H = 40 end
if C.SAMPLE_LIST_ROW_MIN_H == nil then C.SAMPLE_LIST_ROW_MIN_H = 26 end
if C.COLLAPSED_PANEL_ROW_H == nil then C.COLLAPSED_PANEL_ROW_H = 20 end
if C.SAMPLE_LIST_THUMB == nil then C.SAMPLE_LIST_THUMB = 34 end
if C.FONT_MAIN_NAME == nil then C.FONT_MAIN_NAME = "Segoe UI Bold" end
if C.FONT_SMALL_NAME == nil then C.FONT_SMALL_NAME = "Segoe UI Semibold" end
if C.TEXT_ONLY_BTN_HOVER_TEXT_COL == nil then C.TEXT_ONLY_BTN_HOVER_TEXT_COL = 0xE8F4FFFF end
if C.DEFAULT_PREVIEW_GAIN == nil then C.DEFAULT_PREVIEW_GAIN = 10.0 ^ (-6.0 / 20.0) end
if type(C.SEARCH_UI) ~= "table" then C.SEARCH_UI = {} end
if type(C.MODERN_UI) ~= "table" then C.MODERN_UI = {} end
if type(C.PACK_UI) ~= "table" then C.PACK_UI = {} end
if type(C.LIST_UI) ~= "table" then C.LIST_UI = {} end

local instance_id = tostring((r.time_precise and r.time_precise()) or os.time())

local function try_require_module(name, out_var)
  local ok, mod_or_err = pcall(require, name)
  if ok and mod_or_err then
    return mod_or_err
  end
  r.ShowConsoleMsg(string.format(
    "[Sample Lode Manager] require failed: %s — %s\n",
    tostring(name),
    tostring(mod_or_err)
  ))
  return nil
end

local db_manager = try_require_module("lib.db.db_manager")
local sqlite_store = try_require_module("lib.db.sqlite_store")
local resource_paths = try_require_module("lib.core.resource_paths")
local waveform = try_require_module("waveform")
local cover_art = try_require_module("lib.cover_art")
local scan_controller = try_require_module("lib.core.scan_controller")
local ui_search = try_require_module("lib.core.ui_search")
local ui_pack = try_require_module("lib.core.ui_pack")
local ui_samples_list = try_require_module("lib.core.ui_samples_list")
local ui_samples_galaxy = try_require_module("lib.core.ui_samples_galaxy")
local ui_dnd = try_require_module("lib.core.ui_dnd")
local ui_edit_popup = try_require_module("lib.core.ui_edit_popup")
local imgui_utils = try_require_module("lib.core.ui_imgui_utils")
if type(imgui_utils) ~= "table" then imgui_utils = nil end
local ext_state = try_require_module("lib.core.ext_state")
if type(ext_state) ~= "table" then ext_state = nil end
local key_bpm = try_require_module("lib.core.key_bpm_utils")
if type(key_bpm) ~= "table" then key_bpm = nil end
local ui_preview = try_require_module("lib.core.ui_preview")

-- forward declarations (defined later)
local tick_galaxy_full_refresh
local draw_panel_heading_row
local draw_rows_virtualized
local tag_ops
local galaxy_ops
local setup_all_ui_modules

local function window_flag_noresize()
  if r.ImGui_WindowFlags_NoResize then
    return r.ImGui_WindowFlags_NoResize()
  end
  -- Dear ImGui fallback: ImGuiWindowFlags_NoResize = 1 << 1
  return 2
end

local function window_flag_noscrollbar()
  if r.ImGui_WindowFlags_NoScrollbar then
    return r.ImGui_WindowFlags_NoScrollbar()
  end
  -- Dear ImGui fallback: ImGuiWindowFlags_NoScrollbar = 1 << 3
  return 8
end

local function window_flag_noscroll_with_mouse()
  if r.ImGui_WindowFlags_NoScrollWithMouse then
    return r.ImGui_WindowFlags_NoScrollWithMouse()
  end
  -- Dear ImGui fallback: ImGuiWindowFlags_NoScrollWithMouse = 1 << 4
  return 16
end

local function window_flag_nosavedsettings()
  if r.ImGui_WindowFlags_NoSavedSettings then
    return r.ImGui_WindowFlags_NoSavedSettings()
  end
  -- Dear ImGui fallback: ImGuiWindowFlags_NoSavedSettings = 1 << 8
  return 256
end

local function window_flag_always_vertical_scrollbar()
  if r.ImGui_WindowFlags_AlwaysVerticalScrollbar then
    return r.ImGui_WindowFlags_AlwaysVerticalScrollbar()
  end
  -- Dear ImGui fallback: ImGuiWindowFlags_AlwaysVerticalScrollbar = 1 << 14
  return 16384
end

local function supports_native_tab_colors()
  return type(r.ImGui_BeginTabBar) == "function"
    and type(r.ImGui_BeginTabItem) == "function"
    and type(r.ImGui_EndTabBar) == "function"
    and type(r.ImGui_Col_Tab) == "function"
    and type(r.ImGui_Col_TabHovered) == "function"
    and type(r.ImGui_Col_TabActive) == "function"
    and type(r.ImGui_Col_TabUnfocused) == "function"
    and type(r.ImGui_Col_TabUnfocusedActive) == "function"
end

local function is_imgui_ctx_valid()
  if not ctx then return false end
  if not r.ImGui_ValidatePtr then return true end
  local ok_v, valid = pcall(function()
    return r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
  end)
  return ok_v and valid == true
end

local function content_width(fallback)
  if not r.ImGui_GetContentRegionAvail then
    return fallback or 0
  end
  if not is_imgui_ctx_valid() then return fallback or 0 end
  local ok_w, w = pcall(function()
    return select(1, r.ImGui_GetContentRegionAvail(ctx))
  end)
  if ok_w and type(w) == "number" and w > 0 then
    return w
  end
  return fallback or 0
end

local function ui_input_text_with_hint(id, hint, value, bufsz)
  local function should_round_search_input(input_id, input_hint)
    local id_text = tostring(input_id or ""):lower()
    local hint_text = tostring(input_hint or ""):lower()
    if id_text:find("query", 1, true) then return true end
    if id_text:find("filter_input", 1, true) then return true end
    if hint_text:find("search", 1, true) then return true end
    return false
  end

  local pushed_rounding = false
  if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FrameRounding then
    local rounding = should_round_search_input(id, hint) and 12.0 or 0.0
    local ok_round = pcall(function()
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), rounding)
    end)
    pushed_rounding = ok_round == true
  end
  local function normalize_input_result(a, b)
    if b ~= nil then return a, b end
    if type(a) == "string" then
      return true, a
    end
    return a, nil
  end
  if type(r.ImGui_InputTextWithHint) == "function" then
    local ok, ra, rb = pcall(function()
      -- ReaImGui builds differ in 4th/5th arg handling; no-flags call is safest.
      return r.ImGui_InputTextWithHint(ctx, id, hint, value)
    end)
    if (not ok) and bufsz ~= nil then
      ok, ra, rb = pcall(function()
        return r.ImGui_InputTextWithHint(ctx, id, hint, value, bufsz)
      end)
    end
    if ok then
      local c, d = normalize_input_result(ra, rb)
      if pushed_rounding and r.ImGui_PopStyleVar then
        pcall(function() r.ImGui_PopStyleVar(ctx, 1) end)
      end
      return c, d
    end
  end
  local ok_plain, a, b = pcall(function()
    return r.ImGui_InputText(ctx, id, value)
  end)
  if ok_plain then
    local c, d = normalize_input_result(a, b)
    if pushed_rounding and r.ImGui_PopStyleVar then
      pcall(function() r.ImGui_PopStyleVar(ctx, 1) end)
    end
    return c, d
  end
  local a2, b2 = r.ImGui_InputText(ctx, id, value, bufsz)
  local c2, d2 = normalize_input_result(a2, b2)
  if pushed_rounding and r.ImGui_PopStyleVar then
    pcall(function() r.ImGui_PopStyleVar(ctx, 1) end)
  end
  return c2, d2
end

local function draw_text_only_button(label, w, h)
  local hover_text_push_n = 0
  if r.ImGui_GetCursorScreenPos and r.ImGui_GetMousePos and r.ImGui_PushStyleColor and r.ImGui_Col_Text then
    local ok_pos, sx, sy = pcall(r.ImGui_GetCursorScreenPos, ctx)
    local ok_mouse, mx, my = pcall(r.ImGui_GetMousePos, ctx)
    if ok_pos and ok_mouse and type(sx) == "number" and type(sy) == "number" and type(mx) == "number" and type(my) == "number" then
      local tw, th = 40, 18
      if r.ImGui_CalcTextSize then
        local ok_sz, w0, h0 = pcall(r.ImGui_CalcTextSize, ctx, tostring(label or ""))
        if ok_sz then
          if type(w0) == "number" then tw = w0 end
          if type(h0) == "number" then th = h0 end
        end
      end
      local bw = (type(w) == "number" and w > 0) and w or (tw + 4)
      local bh = (type(h) == "number" and h > 0) and h or math.max(18, th + 2)
      local hovered = mx >= sx and mx <= (sx + bw) and my >= sy and my <= (sy + bh)
      if hovered then
        local ok_txt = pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), C.TEXT_ONLY_BTN_HOVER_TEXT_COL)
        end)
        if ok_txt then
          hover_text_push_n = 1
        end
      end
    end
  end
  local color_push_n = 0
  local var_push_n = 0
  if r.ImGui_PushStyleColor and r.ImGui_Col_Button then
    local ok1 = pcall(function()
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0)
      color_push_n = color_push_n + 1
    end)
    local ok2 = pcall(function()
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0)
      color_push_n = color_push_n + 1
    end)
    local ok3 = pcall(function()
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0)
      color_push_n = color_push_n + 1
    end)
    if not ok1 and not ok2 and not ok3 then
      color_push_n = 0
    end
  end
  if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FramePadding then
    local okv = pcall(function()
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 1, 0)
    end)
    if okv then
      var_push_n = 1
    end
  end
  if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FrameBorderSize then
    local okvb = pcall(function()
      r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), 0)
    end)
    if okvb then
      var_push_n = var_push_n + 1
    end
  end
  local pressed = false
  local ok_btn, ret = pcall(function()
    return r.ImGui_Button(ctx, label, w or 0, h or 0)
  end)
  if ok_btn and ret then
    pressed = true
  end
  if var_push_n > 0 and r.ImGui_PopStyleVar then
    pcall(function() r.ImGui_PopStyleVar(ctx, var_push_n) end)
  end
  if color_push_n > 0 and r.ImGui_PopStyleColor then
    pcall(function() r.ImGui_PopStyleColor(ctx, color_push_n) end)
  end
  if hover_text_push_n > 0 and r.ImGui_PopStyleColor then
    pcall(function() r.ImGui_PopStyleColor(ctx, hover_text_push_n) end)
  end
  return pressed
end

local function draw_fading_text_line(id, text, width)
  local function color_alpha(col)
    return math.max(0, math.min(255, math.floor(tonumber(col) or 0) % 256))
  end
  local function color_with_alpha_ratio(col, ratio)
    local base = math.floor((tonumber(col) or 0) / 256) * 256
    local base_a = color_alpha(col)
    local rto = tonumber(ratio) or 0
    if rto < 0 then rto = 0 end
    if rto > 1 then rto = 1 end
    local a = math.floor(base_a * rto + 0.5)
    return base + math.max(0, math.min(255, a))
  end
  local function get_fade_base_color()
    local fallback = 0x1E1E1EFF
    if not r.ImGui_GetStyleColor then return fallback end
    local col = nil
    if r.ImGui_Col_ChildBg then
      local ok1, v1 = pcall(function()
        return r.ImGui_GetStyleColor(ctx, r.ImGui_Col_ChildBg())
      end)
      if ok1 and type(v1) == "number" then
        col = v1
      else
        local ok2, v2 = pcall(function()
          return r.ImGui_GetStyleColor(r.ImGui_Col_ChildBg())
        end)
        if ok2 and type(v2) == "number" then
          col = v2
        end
      end
    end
    if not col and r.ImGui_Col_WindowBg then
      local ok3, v3 = pcall(function()
        return r.ImGui_GetStyleColor(ctx, r.ImGui_Col_WindowBg())
      end)
      if ok3 and type(v3) == "number" then
        col = v3
      end
    end
    return type(col) == "number" and col or fallback
  end
  local line_h = 18
  if r.ImGui_GetTextLineHeight then
    local ok_h, lh = pcall(function() return r.ImGui_GetTextLineHeight(ctx) end)
    if ok_h and type(lh) == "number" and lh > 0 then
      line_h = math.ceil(lh)
    end
  end
  local w = math.max(80, math.floor(tonumber(width) or 160))
  local x0, y0 = 0, 0
  if r.ImGui_GetCursorScreenPos then
    local ok_p, sx, sy = pcall(r.ImGui_GetCursorScreenPos, ctx)
    if ok_p and type(sx) == "number" and type(sy) == "number" then
      x0, y0 = sx, sy
    end
  end
  local flags = window_flag_noresize() | window_flag_noscrollbar() | window_flag_noscroll_with_mouse()
  local fade_child_begun = false
  local fade_child_visible = false
  pcall(function()
    fade_child_visible = r.ImGui_BeginChild(ctx, "##fade_text_" .. tostring(id or "txt"), w, line_h + 2, 0, flags) == true
    fade_child_begun = true
  end)
  if fade_child_begun and fade_child_visible then
    r.ImGui_Text(ctx, tostring(text or ""))
    local dl = nil
    pcall(function()
      if r.ImGui_GetWindowDrawList then
        dl = r.ImGui_GetWindowDrawList(ctx)
      end
    end)
    if dl and (r.ImGui_DrawList_AddRectFilled or r.ImDrawList_AddRectFilled) then
      local base_col = get_fade_base_color()
      local fade_w = math.min(22, math.max(10, math.floor(w * 0.14)))
      local n = 6
      local seg_w = fade_w / n
      for i = 1, n do
        local t = i / n
        local col = color_with_alpha_ratio(base_col, t)
        local sx = x0 + w - fade_w + (i - 1) * seg_w
        local ex = x0 + w - fade_w + i * seg_w + 0.5
        if r.ImGui_DrawList_AddRectFilled then
          r.ImGui_DrawList_AddRectFilled(dl, sx, y0, ex, y0 + line_h + 2, col, 0)
        elseif r.ImDrawList_AddRectFilled then
          r.ImDrawList_AddRectFilled(dl, sx, y0, ex, y0 + line_h + 2, col, 0)
        end
      end
    end
  end
  if fade_child_begun and fade_child_visible and is_imgui_ctx_valid() then
    pcall(function()
      r.ImGui_EndChild(ctx)
    end)
  end
end

local PREVIEW_GAIN_DB_MIN = -60.0
local PREVIEW_GAIN_DB_MAX = 6.0

local function preview_gain_linear_to_db(gain)
  local g = tonumber(gain) or 1.0
  if g <= 0 then
    return PREVIEW_GAIN_DB_MIN
  end
  local db = 20.0 * math.log(g, 10)
  if db < PREVIEW_GAIN_DB_MIN then db = PREVIEW_GAIN_DB_MIN end
  if db > PREVIEW_GAIN_DB_MAX then db = PREVIEW_GAIN_DB_MAX end
  return db
end

local function preview_gain_db_to_linear(db)
  local d = tonumber(db) or 0.0
  if d < PREVIEW_GAIN_DB_MIN then d = PREVIEW_GAIN_DB_MIN end
  if d > PREVIEW_GAIN_DB_MAX then d = PREVIEW_GAIN_DB_MAX end
  if d <= PREVIEW_GAIN_DB_MIN + 0.001 then
    return 0.0
  end
  return 10.0 ^ (d / 20.0)
end

local function ui_slider_db(label, value, min_v, max_v, format_str)
  if r.ImGui_SliderDouble then
    local ok, changed, out_v = pcall(function()
      return r.ImGui_SliderDouble(ctx, label, value, min_v, max_v, format_str or "%.1f dB")
    end)
    if ok and type(changed) == "boolean" and type(out_v) == "number" then
      return changed, out_v, true
    end
    local ok2, changed2, out_v2 = pcall(function()
      return r.ImGui_SliderDouble(ctx, label, value, min_v, max_v)
    end)
    if ok2 and type(changed2) == "boolean" and type(out_v2) == "number" then
      return changed2, out_v2, true
    end
  end
  if r.ImGui_DragDouble then
    local ok, changed, out_v = pcall(function()
      return r.ImGui_DragDouble(ctx, label, value, 0.2, min_v, max_v, format_str or "%.1f dB")
    end)
    if ok and type(changed) == "boolean" and type(out_v) == "number" then
      return changed, out_v, true
    end
    local ok2, changed2, out_v2 = pcall(function()
      return r.ImGui_DragDouble(ctx, label, value, 0.2, min_v, max_v)
    end)
    if ok2 and type(changed2) == "boolean" and type(out_v2) == "number" then
      return changed2, out_v2, true
    end
  end
  return false, value, false
end

local function sanitize_root_path_input(raw)
  if resource_paths and type(resource_paths.sanitize_root_path) == "function" then
    return resource_paths.sanitize_root_path(raw, { empty_as_nil = false })
  end
  if raw == nil then return "" end
  return tostring(raw)
end

local function ensure_reaimgui_ctx()
  if not r.ImGui_CreateContext then
    r.MB("ReaImGui is missing. Install via ReaPack.", "Missing Dependency", 0)
    return false
  end

  if ctx and r.ImGui_ValidatePtr then
    local ok_v, valid = pcall(function()
      return r.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    end)
    if ok_v and (not valid) then
      ctx = nil
      font_main = nil
      font_small = nil
    end
  end
  if ctx then return true end

  ctx = r.ImGui_CreateContext(C.SCRIPT_TITLE)

  -- Fonts (keep it simple; only create once)
  local font_main_name = tostring(C.FONT_MAIN_NAME or "Segoe UI Bold")
  local font_small_name = tostring(C.FONT_SMALL_NAME or font_main_name)
  font_main = r.ImGui_CreateFont(font_main_name, 14)
  font_small = r.ImGui_CreateFont(font_small_name, 11)
  r.ImGui_Attach(ctx, font_main)
  r.ImGui_Attach(ctx, font_small)

  return true
end

local function safe_push_font(font, size_px)
  if not r.ImGui_PushFont then return end
  if not is_imgui_ctx_valid() then return false end
  -- This binding expects at least 3 arguments for PushFont(ctx, font, ...).
  local size = tonumber(size_px) or 12
  return pcall(function()
    r.ImGui_PushFont(ctx, font, size)
  end)
end

local function safe_pop_font(pushed)
  if not pushed then return end
  if not r.ImGui_PopFont then return end
  if not is_imgui_ctx_valid() then return end
  pcall(function()
    r.ImGui_PopFont(ctx)
  end)
end

local function get_persisted_splice_db_path()
  if not ext_state then return "" end
  return ext_state.get_persisted_splice_db_path(r, XS.section, XS.splice_db_path)
end

local function set_persisted_splice_db_path(path_text)
  if not ext_state then return end
  ext_state.set_persisted_splice_db_path(r, XS.section, XS.splice_db_path, path_text)
end

local function get_extstate_text(key)
  if not ext_state then return "" end
  return ext_state.get_extstate_text(r, XS.section, key)
end

local function set_extstate_text(key, value, persist)
  if not ext_state then return end
  ext_state.set_extstate_text(r, XS.section, key, value, persist)
end

local function get_persisted_splice_relink_roots()
  if not ext_state then return {} end
  return ext_state.get_persisted_splice_relink_roots(r, XS.section, XS.splice_relink_roots)
end

local function set_persisted_splice_relink_roots(paths_tbl)
  if not ext_state then return end
  ext_state.set_persisted_splice_relink_roots(r, XS.section, XS.splice_relink_roots, paths_tbl)
end

local function get_extstate_bool(key, default_value)
  if not ext_state then return default_value == true end
  return ext_state.get_extstate_bool(r, XS.section, key, default_value)
end

local function get_extstate_number(key)
  if not ext_state then return nil end
  return ext_state.get_extstate_number(r, XS.section, key)
end

local function should_accept_toggle_click(click_map, key, interval_sec)
  local now = (r.time_precise and r.time_precise()) or os.clock()
  local last = click_map[key]
  if last and (now - last) < (interval_sec or 0.12) then
    return false
  end
  click_map[key] = now
  return true
end

local function rebuild_pack_display_name_map()
  local m = {}
  for _, plist in ipairs({ state.packs.splice or {}, state.packs.other or {} }) do
    for _, p in ipairs(plist) do
      local id = tonumber(p.id)
      if id then
        m[id] = (p.display_name and p.display_name ~= "" and p.display_name) or p.name or ("#" .. tostring(id))
      end
    end
  end
  state.runtime.pack_display_name_by_id = m
end

local function reload_pack_lists_impl()
  if not state or not state.store or not state.store.available or not state.store.conn or not sqlite_store then
    return
  end
  local sort_mode = (state.ui and state.ui.pack_sort) or "name"
  local opts = { sort = sort_mode }
  local wrap = { db = state.store.conn }
  local ok1, splice_or_err = pcall(function()
    return sqlite_store.get_packs(wrap, "splice", opts)
  end)
  local ok2, other_or_err = pcall(function()
    return sqlite_store.get_packs(wrap, "other", opts)
  end)
  if ok1 and type(splice_or_err) == "table" then
    state.packs.splice = splice_or_err
  end
  if ok2 and type(other_or_err) == "table" then
    state.packs.other = other_or_err
  end
  if (ok1 and type(splice_or_err) == "table") or (ok2 and type(other_or_err) == "table") then
    rebuild_pack_display_name_map()
  end
end

local function flush_reload_pack_lists_if_needed()
  if not (state and state.runtime and state.runtime.pack_lists_reload_requested) then
    return
  end
  state.runtime.pack_lists_reload_requested = false
  reload_pack_lists_impl()
end

local function reload_pack_lists()
  if not state or not state.runtime then return end
  state.runtime.pack_lists_reload_requested = true
end

local function pack_display_name_by_id(pack_id)
  local want = tonumber(pack_id)
  if not want then return nil end
  local by_id = state.runtime and state.runtime.pack_display_name_by_id
  if type(by_id) == "table" then
    local hit = by_id[want]
    if hit then return hit end
  end
  for _, p in ipairs(state.packs.splice or {}) do
    if tonumber(p.id) == want then
      return (p.display_name and p.display_name ~= "" and p.display_name) or p.name or ("#" .. tostring(want))
    end
  end
  for _, p in ipairs(state.packs.other or {}) do
    if tonumber(p.id) == want then
      return (p.display_name and p.display_name ~= "" and p.display_name) or p.name or ("#" .. tostring(want))
    end
  end
  return "#" .. tostring(want)
end

local function filter_pack_ids_has(list, pack_id)
  local want = tonumber(pack_id)
  if not want or not list then return false end
  if list == state.filter_pack_ids then
    local set = state.runtime.filter_pack_id_set
    if not set then
      set = {}
      for _, x in ipairs(list) do
        local id = tonumber(x)
        if id then set[id] = true end
      end
      state.runtime.filter_pack_id_set = set
    end
    return set[want] == true
  end
  for _, x in ipairs(list) do
    if tonumber(x) == want then return true end
  end
  return false
end

local function filter_pack_ids_invalidate_membership_cache()
  if state and state.runtime then
    state.runtime.filter_pack_id_set = nil
  end
end

local function filter_pack_ids_remove_at(idx)
  if not idx or idx < 1 or idx > #state.filter_pack_ids then return end
  table.remove(state.filter_pack_ids, idx)
  state.needs_reload_samples = true
  filter_pack_ids_invalidate_membership_cache()
end

local function filter_pack_ids_toggle(pack_id)
  local id = tonumber(pack_id)
  if not id or id < 1 then return end
  for i = #state.filter_pack_ids, 1, -1 do
    if tonumber(state.filter_pack_ids[i]) == id then
      table.remove(state.filter_pack_ids, i)
      state.needs_reload_samples = true
      filter_pack_ids_invalidate_membership_cache()
      return
    end
  end
  state.filter_pack_ids[#state.filter_pack_ids + 1] = id
  state.needs_reload_samples = true
  filter_pack_ids_invalidate_membership_cache()
end

local function filter_pack_ids_clear()
  if #state.filter_pack_ids == 0 then return end
  state.filter_pack_ids = {}
  state.needs_reload_samples = true
  filter_pack_ids_invalidate_membership_cache()
end

local function filter_pack_set_single(pack_id)
  local id = tonumber(pack_id)
  if not id or id < 1 then return end
  state.filter_pack_ids = { id }
  state.needs_reload_samples = true
  filter_pack_ids_invalidate_membership_cache()
end

local function init_manage_state(persisted_splice_db_path)
  return {
    root_path_input = "",
    splice_db_path_input = persisted_splice_db_path,
    splice_relink_folder_input = "",
    splice_relink_roots = {},
    splice_relink_last_report = nil,
    focus_root_input_once = false,
    focus_splice_db_input_once = false,
    show_roots_panel = false,
    notice = "",
    scan_progress_pct = nil,
    scan_progress_label = "",
    scan_runner = nil,
    scan_progress_window_open = true,
  }
end

local function init_ui_state()
  return {
    last_toggle_click = {},
    auto_preview_on_select = true,
    pack_sort = "name",
    pack_source_tab = "splice",
    layout_pack_frac = 0.20,
    layout_search_frac = 0.24,
    panel_pack_h_px = nil,
    panel_search_h_px = nil,
    panel_list_h_px = nil,
    panel_detail_h_px = nil,
    pack_panel_collapsed = false,
    search_panel_collapsed = false,
    pack_active_strip_px = 58,
    sample_sort = { column = "random", asc = true },
    sample_view_tab = "list",
    galaxy_zoom = 1.0,
    galaxy_center_x = 0.5,
    galaxy_center_y = 0.5,
    galaxy_embed_preset = "core5",
    galaxy_embed_profile = "balanced",
    galaxy_advanced_collapsed = true,
    galaxy_show_unmapped = true,
    search_popular_tags_open = false,
    follow_arrange_selection = false,
    favorites_only_filter = false,
    pack_favorites_only_filter = false,
    match_preview_to_project_bpm = false,
    match_insert_to_project_bpm = false,
    cover_auto_download = true,
    cover_show = true,
    preview_gain = C.DEFAULT_PREVIEW_GAIN,
    rate_multiplier = 1.0,
  }
end

local function init_runtime_state()
  return {
    notice = "",
    preview_checked = false,
    preview_available = false,
    preview_error = "",
    preview_handle = nil,
    preview_source = nil,
    preview_path = nil,
    preview_sample_bpm = nil,
    preview_last_playrate = nil,
    preview_started_at = nil,
    preview_duration_sec = nil,
    dnd_drag_path = nil,
    dnd_drag_name = nil,
    dnd_drag_bpm = nil,
    dnd_drag_type = nil,
    dnd_last_mouse_down = false,
    dnd_start_x = 0,
    dnd_start_y = 0,
    arrange_follow_last_key = nil,
    pending_arrange_sample_id = nil,
    last_selected_sample_id = nil,
    selected_sample_snapshot = nil,
    dnd_max_dist2 = 0,
    dnd_warned_no_js_api = false,
    wave_screen_rect = nil,
    wf_capture = false,
    wf_last_mouse_down = false,
    wf_path = nil,
    wf_name = nil,
    wf_start_mx = 0,
    wf_start_my = 0,
    wave_scrub_ratio = nil,
    preview_offset_sec = nil,
    preview_full_length_sec = nil,
    panel_split_inited = false,
    split_grab = nil,
    cover_art = {
      by_pack = {},
      queue = {},
      ctx_ref = nil,
      max_textures = 24,
    },
    sample_row_clipper = nil,
    pack_row_clipper = nil,
    galaxy_points_cache = nil,
    galaxy_pan_active = false,
    galaxy_pan_last_mx = nil,
    galaxy_pan_last_my = nil,
    galaxy_trail_segments = {},
    galaxy_paint_drag = false,
    galaxy_paint_last_row = nil,
    galaxy_paint_last_mx = nil,
    galaxy_paint_last_my = nil,
    selection_anchor_row_idx = nil,
    last_sample_filter_signature = nil,
    edit_sample_id = nil,
    edit_bpm_input = "",
    edit_key_input = "",
    edit_popup_open = false,
    edit_popup_ids = nil,
    edit_popup_sample_id = nil,
    edit_popup_snapshot = nil,
    edit_popup_form_sample_id = nil,
    edit_popup_form_key = nil,
    edit_popup_bpm_input = "",
    edit_popup_key_root = "C",
    edit_popup_key_mode = "none",
    edit_popup_tag_input = "",
    preview_skip_cache_by_path = {},
    preview_skip_cache_order = {},
    pack_bulk_tag_open = false,
    pack_bulk_tag_pack_id = nil,
    pack_bulk_tag_pack_name = nil,
    pack_bulk_tag_input = "",
    detail_cache_sample_id = nil,
    detail_cache_path = nil,
    detail_cache_path_changed_at = nil,
    detail_cache_peaks = nil,
    detail_cache_peaks_quality = nil,
    detail_cache_tags = nil,
    ui_state_last_saved_ts = nil,
    dock_restore_pending = false,
    persisted_dock_id = nil,
    dock_restore_attempts = 0,
    main_window_dock_id_for_persist = nil,
    main_window_size_seeded = false,
    perf_enabled = get_extstate_bool("ui_perf_overlay", false),
    perf_last_report_at = nil,
    perf_last_report = "",
    perf_acc = {
      frames = 0,
      tick_scan = 0,
      reload_samples = 0,
      prewarm_galaxy = 0,
      tick_gfr = 0,
      draw_pack = 0,
      draw_search = 0,
      draw_detail = 0,
    },
    pack_lists_reload_requested = false,
    pack_display_name_by_id = nil,
    perf_ext_poll_at = 0,
    heartbeat_write_last = nil,
    tag_sugg_cache_key = nil,
    tag_sugg_cache_rows = nil,
    tag_sugg_cache_at = nil,
    tag_pop_cache_key = nil,
    tag_pop_cache_rows = nil,
    tag_pop_cache_at = nil,
    tag_sugg_debounce_key = nil,
    tag_sugg_debounce_until = nil,
    tag_filter_input_reset_id = 0,
    pack_filtered_cache = {},
    filter_pack_id_set = nil,
    samples_reload_debounce_sig = nil,
    samples_reload_debounce_until = nil,
    galaxy_low_budget_frames = 0,
    row_idx_by_sample_id = nil,
    path_exists_cache = nil,
    detail_cache_next_quick_retry_at = nil,
    detail_cache_next_full_retry_at = nil,
  }
end

local function apply_persisted_ui_from_extstate()
  if not state then return end
  state.ui.pack_panel_collapsed = get_extstate_bool(XS.ui_pack_collapsed, state.ui.pack_panel_collapsed)
  state.ui.search_panel_collapsed = get_extstate_bool(XS.ui_search_collapsed, state.ui.search_panel_collapsed)
  state.ui.panel_pack_h_px = get_extstate_number(XS.ui_pack_h) or state.ui.panel_pack_h_px
  state.ui.panel_search_h_px = get_extstate_number(XS.ui_search_h) or state.ui.panel_search_h_px
  state.ui.panel_list_h_px = get_extstate_number(XS.ui_list_h) or state.ui.panel_list_h_px
  state.ui.preview_gain = get_extstate_number(XS.ui_preview_gain) or state.ui.preview_gain
  state.ui.rate_multiplier = get_extstate_number("ui_rate_multiplier") or state.ui.rate_multiplier
  state.ui.match_preview_to_project_bpm = get_extstate_bool(XS.ui_match_preview_bpm, state.ui.match_preview_to_project_bpm)
  state.ui.match_insert_to_project_bpm = get_extstate_bool(XS.ui_match_insert_bpm, state.ui.match_insert_to_project_bpm)
  state.manage.splice_relink_roots = get_persisted_splice_relink_roots()
  state.ui.preview_gain = math.max(0, math.min(2, tonumber(state.ui.preview_gain) or C.DEFAULT_PREVIEW_GAIN))
  do
    local v = tonumber(state.ui.rate_multiplier) or 1.0
    if v < 0.25 then v = 0.25 end
    if v > 4.0 then v = 4.0 end
    state.ui.rate_multiplier = v
  end
  state.runtime.persisted_dock_id = get_extstate_number(XS.ui_dock_id)
  if state.runtime.persisted_dock_id and state.runtime.persisted_dock_id > 0 then
    state.runtime.dock_restore_pending = true
  end
  if state.ui.panel_pack_h_px ~= nil and state.ui.panel_search_h_px ~= nil then
    state.runtime.panel_split_inited = true
  end
end

local function init_state()
  local persisted_splice_db_path = get_persisted_splice_db_path()
  state = {
    packs_query = "",
    -- empty = all packs; multiple ids = OR (sample in any of those packs)
    filter_pack_ids = {},
    -- filters (v0.1)
    bpm_filter_enabled = false,
    bpm_min = nil,
    bpm_max = nil,
    key_filter_enabled = false,
    key_root = "E",
    key_mode_major = false,
    key_mode_minor = false,
    type_is_one_shot = false,
    type_is_loop = false,
    type_filter_enabled = false,
    filter_tags = {}, -- AND filter: sample must have every tag
    filter_tags_exclude = {}, -- NOT filter: sample must not have any of these tags
    tag_filter_input = "",
    -- results (placeholder)
    selected_row = 1,
    rows = {},
    playing = false,
    bulk_tag_input = "",
    selected_sample_ids = {},

    db = {
      available = false,
      backend = nil,
      module_name = nil,
      error = nil,
    },

    store = {
      available = false,
      backend = nil,
      error = nil,
      conn = nil,
      db_module = nil,
    },

    needs_reload_samples = true,

    packs = {
      splice = {},
      other = {},
    },

    manage = init_manage_state(persisted_splice_db_path),

    ui = init_ui_state(),

    runtime = init_runtime_state(),
  }

  apply_persisted_ui_from_extstate()

  if db_manager and type(db_manager.init) == "function" and type(db_manager.get_status) == "function" then
    local ok = db_manager.init()
    local st = db_manager.get_status() or {}
    state.db.available = st.available == true
    state.db.backend = st.backend
    state.db.module_name = st.module_name
    state.db.error = st.error
  else
    state.db.available = false
    state.db.error = "DB manager module missing."
  end

  -- SQLite store open (if module is available)
  if state.db.available and state.db.backend == "sqlite" and sqlite_store and type(sqlite_store.open) == "function" then
    local db_path = (resource_paths and resource_paths.get_db_path(r))
      or (r.GetResourcePath() .. sep .. "SampleLodeManager.sqlite")
    local db_module = (db_manager and db_manager.sqlite) or nil
    local db, err = sqlite_store.open(db_path, db_module)
    if db then
      state.store.available = true
      state.store.backend = "sqlite"
      state.store.conn = db
      state.store.db = db
      state.store.db_module = db_module
      state.needs_reload_samples = true
      if type(sqlite_store.get_phase_e_preset) == "function" then
        local okp, p = pcall(function() return sqlite_store.get_phase_e_preset() end)
        if okp and p and p ~= "" then state.ui.galaxy_embed_preset = tostring(p) end
      end
    else
      state.store.available = false
      state.store.backend = nil
      state.store.error = tostring(err or "sqlite_store.open failed")
    end
  end

  -- Load packs from DB (if ready)
  if state.store.available then
    reload_pack_lists()
    flush_reload_pack_lists_if_needed()
  end

  if scan_controller and type(scan_controller.setup) == "function" then
    scan_controller.setup({
      r = r,
      state = state,
      sqlite_store = sqlite_store,
      reload_pack_lists = reload_pack_lists,
      set_runtime_notice = set_runtime_notice,
      async_scan_step_budget = C.ASYNC_SCAN_STEP_BUDGET,
    })
  end

  -- Placeholder rows if store isn't ready yet
  if not state.store.available then
    for i = 1, 25 do
      state.rows[#state.rows + 1] = {
        filename = string.format("sample_%02d.wav", i),
        bpm = (i % 7 == 0) and nil or (60 + (i * 5) % 170),
        key_estimate = (i % 5 == 0) and nil or ((i % 12) == 0 and "C" or "E") .. " major",
        type = (i % 3 == 0) and "loop" or "oneshot",
      }
    end
  end
end

local function set_runtime_notice(msg)
  state.runtime.notice = tostring(msg or "")
end

local function file_exists(path)
  if not path or path == "" then return false end
  local f = io.open(path, "rb")
  if not f then return false end
  f:close()
  return true
end

local function file_exists_cached(path)
  local p = tostring(path or "")
  if p == "" then return false end
  if not state.runtime.path_exists_cache then
    state.runtime.path_exists_cache = {}
  end
  local c = state.runtime.path_exists_cache[p]
  if c ~= nil then
    return c == true
  end
  local ok = file_exists(p)
  state.runtime.path_exists_cache[p] = ok
  return ok
end

local function get_detail_waveform_play_ratio(row)
  if ui_preview then return ui_preview.get_detail_waveform_play_ratio(row) end
  return nil
end

--- @param keep_wf_scrub boolean|nil if true, keep waveform drag state and wave_scrub_ratio (scrub: audio off until mouse up)
local function stop_preview(keep_wf_scrub)
  if ui_preview then return ui_preview.stop_preview(keep_wf_scrub) end
end

local function refresh_preview_state()
  if ui_preview then return ui_preview.refresh_preview_state() end
end

local function preview_seek_or_restart_from_ratio(path, label, ratio, quiet)
  if ui_preview then return ui_preview.preview_seek_or_restart_from_ratio(path, label, ratio, quiet) end
end

local function play_selected_sample_preview()
  if ui_preview then return ui_preview.play_selected_sample_preview() end
end

local function get_selected_sample_row()
  if state.rows and #state.rows > 0 then
    local idx = tonumber(state.selected_row)
    if idx and idx >= 1 and idx <= #state.rows then
      return state.rows[idx]
    end
  end
  if state.runtime and state.runtime.selected_sample_snapshot then
    return state.runtime.selected_sample_snapshot
  end
  return nil
end

local function update_selected_sample_snapshot(row)
  if not row then return end
  state.runtime.selected_sample_snapshot = {
    id = row.id,
    path = row.path,
    filename = row.filename,
    bpm = row.bpm,
    key_estimate = row.key_estimate,
    type = row.type,
    brightness = row.brightness,
    noisiness = row.noisiness,
    attack_sharpness = row.attack_sharpness,
    decay_length = row.decay_length,
    tonalness = row.tonalness,
    embed_x = row.embed_x,
    embed_y = row.embed_y,
    pack_id = row.pack_id,
    pack_name = row.pack_name,
    pack_cover_url = row.pack_cover_url,
    is_favorite = row.is_favorite,
  }
end

-- defer_stop_preview: true ?? Auto Preview on Select ??????? play ??????
-- ????????E?ECM ?????E??????E?E???E??????????????????E
local function set_selected_row(row_idx, defer_stop_preview)
  local new_idx = tonumber(row_idx)
  if not new_idx then return end
  if new_idx < 1 or new_idx > #state.rows then return end
  local next_row = state.rows[new_idx]
  if next_row and next_row.id ~= nil then
    state.runtime.last_selected_sample_id = tonumber(next_row.id) or state.runtime.last_selected_sample_id
    update_selected_sample_snapshot(next_row)
  end
  if state.selected_row == new_idx then return end

  local prev = state.rows[state.selected_row]
  local prev_path = prev and prev.path or nil
  local next_path = next_row and next_row.path or nil

  local defer_stop = defer_stop_preview == true and state.ui.auto_preview_on_select == true
  if state.playing and prev_path ~= next_path and not defer_stop then
    stop_preview()
    set_runtime_notice("Selection changed. Preview stopped.")
  end

  state.selected_row = new_idx
end

local function bulk_selected_count()
  local n = 0
  for _, v in pairs(state.selected_sample_ids or {}) do
    if v == true then n = n + 1 end
  end
  return n
end

local function bulk_selected_ids_list()
  local out = {}
  for k, v in pairs(state.selected_sample_ids or {}) do
    if v == true then
      local idn = tonumber(k)
      if idn and idn > 0 then out[#out + 1] = idn end
    end
  end
  if #out == 0 then
    local row = get_selected_sample_row()
    if row and tonumber(row.id) then out[#out + 1] = tonumber(row.id) end
  end
  return out
end

local function bulk_toggle_sample_id(sample_id, on)
  local idn = tonumber(sample_id)
  if not idn or idn < 1 then return end
  if on == nil then
    local cur = state.selected_sample_ids[idn] == true
    state.selected_sample_ids[idn] = not cur
  else
    state.selected_sample_ids[idn] = (on == true)
  end
end

local function bulk_clear_all_selection()
  state.selected_sample_ids = {}
end

local function bulk_set_row_selected(row_idx, on)
  local row = state.rows and state.rows[row_idx]
  if not row then return end
  bulk_toggle_sample_id(tonumber(row.id), on == true)
end

local function imgui_mod_down(mod_name)
  if not (r.ImGui_IsKeyDown and ctx) then return false end
  local key = nil
  if mod_name == "ctrl" and r.ImGui_Mod_Ctrl then
    local ok, v = pcall(function() return r.ImGui_Mod_Ctrl() end)
    if ok then key = v end
  elseif mod_name == "shift" and r.ImGui_Mod_Shift then
    local ok, v = pcall(function() return r.ImGui_Mod_Shift() end)
    if ok then key = v end
  end
  if key == nil then return false end
  local ok2, down = pcall(function()
    return r.ImGui_IsKeyDown(ctx, key)
  end)
  return ok2 and down == true
end

local function normalize_path_key_quick(p)
  if not p or p == "" then return nil end
  return tostring(p):lower():gsub("\\", "/"):gsub("//+", "/")
end

local function get_arrange_first_selected_take_source_path()
  if not r.CountSelectedMediaItems or not r.GetSelectedMediaItem then return nil end
  local proj = 0
  if r.EnumProjects then
    proj = r.EnumProjects(-1, "") or 0
  end
  local n = r.CountSelectedMediaItems(proj)
  if not n or n < 1 then return nil end
  local item = r.GetSelectedMediaItem(proj, 0)
  if not item then return nil end
  local take = r.GetActiveTake and r.GetActiveTake(item)
  if not take then return nil end
  local src = r.GetMediaItemTake_Source and r.GetMediaItemTake_Source(take)
  if not src then return nil end
  if r.PCM_Source_GetFileName then
    local ok, fn = pcall(function() return r.PCM_Source_GetFileName(src) end)
    if ok and type(fn) == "string" and fn ~= "" then return fn end
  end
  if r.GetMediaSourceFileName then
    local ok, a, b = pcall(function() return r.GetMediaSourceFileName(src, "") end)
    if ok then
      if type(a) == "string" and a ~= "" then return a end
      if type(b) == "string" and b ~= "" then return b end
    end
    local ok2, fn2 = pcall(function() return r.GetMediaSourceFileName(src) end)
    if ok2 and type(fn2) == "string" and fn2 ~= "" then return fn2 end
  end
  return nil
end

local function find_row_index_by_sample_id(sample_id)
  if not state.rows or sample_id == nil then return nil end
  local want = tonumber(sample_id)
  if not want then return nil end
  for i, row in ipairs(state.rows) do
    if tonumber(row.id) == want then return i end
  end
  return nil
end

function M._make_sample_row_snapshot(row)
  if not row then return nil end
  return {
    id = row.id,
    path = row.path,
    filename = row.filename,
    bpm = row.bpm,
    key_estimate = row.key_estimate,
    type = row.type,
    brightness = row.brightness,
    noisiness = row.noisiness,
    attack_sharpness = row.attack_sharpness,
    decay_length = row.decay_length,
    tonalness = row.tonalness,
    embed_x = row.embed_x,
    embed_y = row.embed_y,
    pack_id = row.pack_id,
    pack_name = row.pack_name,
    pack_cover_url = row.pack_cover_url,
    is_favorite = row.is_favorite,
  }
end

function M._open_sample_edit_popup_for_row(row)
  local sid = row and tonumber(row.id)
  if not sid or sid < 1 then return end
  state.runtime.edit_popup_open = true
  state.runtime.edit_popup_ids = { sid }
  state.runtime.edit_popup_sample_id = sid
  state.runtime.edit_popup_snapshot = M._make_sample_row_snapshot(row)
  state.runtime.edit_popup_form_sample_id = nil
  state.runtime.edit_popup_form_key = nil
end

function M._open_sample_edit_popup_for_ids(sample_ids, anchor_row)
  local ids = {}
  local seen = {}
  for _, raw in ipairs(sample_ids or {}) do
    local n = tonumber(raw)
    if n and n > 0 and not seen[n] then
      seen[n] = true
      ids[#ids + 1] = n
    end
  end
  if #ids == 0 then return end
  state.runtime.edit_popup_open = true
  state.runtime.edit_popup_ids = ids
  state.runtime.edit_popup_sample_id = ids[1]
  state.runtime.edit_popup_snapshot = M._make_sample_row_snapshot(anchor_row)
  state.runtime.edit_popup_form_sample_id = nil
  state.runtime.edit_popup_form_key = nil
end

function M._collect_popup_tag_groups(ids)
  local out_single = {}
  local out_common = {}
  local out_mixed = {}
  if not (state and state.store and state.store.available and sqlite_store and type(sqlite_store.get_tags_for_sample) == "function") then
    return out_single, out_common, out_mixed
  end
  local valid_ids = {}
  local seen_ids = {}
  for _, raw in ipairs(ids or {}) do
    local n = tonumber(raw)
    if n and n > 0 and not seen_ids[n] then
      seen_ids[n] = true
      valid_ids[#valid_ids + 1] = n
    end
  end
  if #valid_ids == 0 then return out_single, out_common, out_mixed end

  local sample_count = #valid_ids
  local tag_counts = {}
  local display_by_norm = {}
  for _, sid in ipairs(valid_ids) do
    local ok, tags = pcall(function()
      return sqlite_store.get_tags_for_sample({ db = state.store.conn }, sid)
    end)
    if ok and type(tags) == "table" then
      local per_sample_seen = {}
      for _, raw_tag in ipairs(tags) do
        local tag = tostring(raw_tag or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if tag ~= "" then
          local norm = tag:lower()
          if not per_sample_seen[norm] then
            per_sample_seen[norm] = true
            tag_counts[norm] = (tag_counts[norm] or 0) + 1
            if not display_by_norm[norm] then display_by_norm[norm] = tag end
          end
        end
      end
    end
  end

  local keys = {}
  for norm, _ in pairs(tag_counts) do
    keys[#keys + 1] = norm
  end
  table.sort(keys)
  for _, norm in ipairs(keys) do
    local disp = display_by_norm[norm] or norm
    local cnt = tonumber(tag_counts[norm]) or 0
    if sample_count == 1 then
      out_single[#out_single + 1] = disp
    elseif cnt >= sample_count then
      out_common[#out_common + 1] = disp
    else
      out_mixed[#out_mixed + 1] = disp
    end
  end
  return out_single, out_common, out_mixed
end

local function apply_browser_to_sample_hit(hit)
  if not hit or not hit.id then return end
  local idx = find_row_index_by_sample_id(hit.id)
  if idx then
    set_selected_row(idx)
    return
  end
  local pid = tonumber(hit.pack_id)
  if pid and pid > 0 then
    local in_or_set = (#state.filter_pack_ids == 0) or filter_pack_ids_has(state.filter_pack_ids, pid)
    if (not in_or_set) or (#state.filter_pack_ids > 1) then
      state.filter_pack_ids = { pid }
      state.needs_reload_samples = true
      state.runtime.pending_arrange_sample_id = hit.id
      return
    end
  end
  set_runtime_notice("File matched library but is hidden by current filters.")
end

local function sync_browser_from_arrange_selection(force)
  if not state.store.available or not state.store.db or not sqlite_store or not sqlite_store.find_sample_by_path then
    return
  end
  local path = get_arrange_first_selected_take_source_path()
  local key = normalize_path_key_quick(path)

  if state.ui.follow_arrange_selection and not force then
    if key == state.runtime.arrange_follow_last_key then return end
    state.runtime.arrange_follow_last_key = key
  end

  if not path or path == "" then return end

  local hit = sqlite_store.find_sample_by_path(state.store, path)
  if not hit then
    if force or state.ui.follow_arrange_selection then
      set_runtime_notice("No library match for arrange selection.")
    end
    return
  end

  apply_browser_to_sample_hit(hit)
end

local function resolve_pending_arrange_sample_selection()
  local sid = state.runtime.pending_arrange_sample_id
  if not sid then return end
  state.runtime.pending_arrange_sample_id = nil
  local idx = find_row_index_by_sample_id(sid)
  if idx then
    set_selected_row(idx)
  else
    set_runtime_notice("File matched library but is hidden by current filters.")
  end
end

function M._build_sample_filter_signature()
  local pack_ids = {}
  for _, pid in ipairs(state.filter_pack_ids or {}) do
    local n = tonumber(pid)
    if n and n > 0 then pack_ids[#pack_ids + 1] = n end
  end
  table.sort(pack_ids)
  local tags = {}
  for _, tg in ipairs(state.filter_tags or {}) do
    local t = tostring(tg or "")
    if t ~= "" then tags[#tags + 1] = t end
  end
  table.sort(tags)
  local tags_ex = {}
  for _, tg in ipairs(state.filter_tags_exclude or {}) do
    local t = tostring(tg or "")
    if t ~= "" then tags_ex[#tags_ex + 1] = t end
  end
  table.sort(tags_ex)
  local text_query = tostring(state.tag_filter_input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local bits = {
    "packs=" .. table.concat(pack_ids, ","),
    "bpm_en=" .. tostring(state.bpm_filter_enabled == true),
    "bpm_min=" .. tostring(state.bpm_min or ""),
    "bpm_max=" .. tostring(state.bpm_max or ""),
    "key_en=" .. tostring(state.key_filter_enabled == true),
    "key_root=" .. tostring(state.key_root or ""),
    "key_maj=" .. tostring(state.key_mode_major == true),
    "key_min=" .. tostring(state.key_mode_minor == true),
    "type_en=" .. tostring(state.type_filter_enabled == true),
    "type_one=" .. tostring(state.type_is_one_shot == true),
    "type_loop=" .. tostring(state.type_is_loop == true),
    "text=" .. text_query,
    "tags=" .. table.concat(tags, ","),
    "tags_ex=" .. table.concat(tags_ex, ","),
    "fav_only=" .. tostring(state.ui.favorites_only_filter == true),
    "pack_fav_only=" .. tostring(state.ui.pack_favorites_only_filter == true),
  }
  local ss = state.ui.sample_sort or {}
  bits[#bits + 1] = "sort_col=" .. tostring(ss.column or "")
  bits[#bits + 1] = "sort_asc=" .. tostring(ss.asc == true)
  return table.concat(bits, "|")
end

local function reload_samples_if_needed()
  if not state.needs_reload_samples then return end
  local now = (r.time_precise and r.time_precise()) or os.clock()
  local current_sig = M._build_sample_filter_signature()
  local debounce_sec = 0.16
  if state.runtime.last_sample_filter_signature ~= nil then
    if state.runtime.samples_reload_debounce_sig ~= current_sig then
      state.runtime.samples_reload_debounce_sig = current_sig
      state.runtime.samples_reload_debounce_until = now + debounce_sec
      return
    end
    if now < (tonumber(state.runtime.samples_reload_debounce_until) or 0) then
      return
    end
    state.runtime.samples_reload_debounce_sig = nil
    state.runtime.samples_reload_debounce_until = nil
  end

  local prev_sig = state.runtime.last_sample_filter_signature
  if prev_sig ~= nil and prev_sig ~= current_sig then
    bulk_clear_all_selection()
    state.runtime.selection_anchor_row_idx = nil
  end
  state.runtime.last_sample_filter_signature = current_sig
  local preserve_id = nil
  if state.rows and state.selected_row then
    local cur = state.rows[state.selected_row]
    if cur and cur.id ~= nil then
      preserve_id = tonumber(cur.id)
    end
  end
  if not preserve_id and state.runtime and state.runtime.last_selected_sample_id ~= nil then
    preserve_id = tonumber(state.runtime.last_selected_sample_id)
  end
  -- Do not stop preview on list reload (filters, tags, sort, etc.); user or selection-change stops explicitly.
  if state.store.available and state.store.conn then
    local filters = {
      bpm_min = state.bpm_filter_enabled and state.bpm_min or nil,
      bpm_max = state.bpm_filter_enabled and state.bpm_max or nil,
      key_root = state.key_filter_enabled and state.key_root or nil,
      key_mode_major = state.key_filter_enabled and state.key_mode_major or nil,
      key_mode_minor = state.key_filter_enabled and state.key_mode_minor or nil,
      type_is_one_shot = state.type_filter_enabled and state.type_is_one_shot or nil,
      type_is_loop = state.type_filter_enabled and state.type_is_loop or nil,
      text_query = state.tag_filter_input,
      filter_tags = state.filter_tags,
      filter_tags_exclude = state.filter_tags_exclude,
      favorites_only = state.ui.favorites_only_filter == true,
      pack_favorites_only = state.ui.pack_favorites_only_filter == true,
    }
    local pack_sel = nil
    if state.filter_pack_ids and #state.filter_pack_ids > 0 then
      pack_sel = state.filter_pack_ids
    end
    local store_wrap = { db = state.store.conn }
    local sort_spec = state.ui.sample_sort or { column = "random", asc = true }
    local ok, samples_or_err = pcall(function()
      return sqlite_store.get_samples(store_wrap, pack_sel, filters, 100000, sort_spec)
    end)
    if ok and samples_or_err then
      state.rows = samples_or_err
      state.runtime.path_exists_cache = nil
      state.runtime.galaxy_points_cache = nil
      state.runtime.row_idx_by_sample_id = nil
      local id_map = {}
      for i, rrow in ipairs(samples_or_err) do
        local sid = tonumber(rrow and rrow.id)
        if sid then id_map[sid] = i end
      end
      state.runtime.row_idx_by_sample_id = id_map
      state.runtime.galaxy_low_budget_frames = 10
      local sel = nil
      if preserve_id then
        sel = id_map[preserve_id]
      end
      state.selected_row = sel
      if sel and samples_or_err[sel] and samples_or_err[sel].id ~= nil then
        state.runtime.last_selected_sample_id = tonumber(samples_or_err[sel].id) or state.runtime.last_selected_sample_id
        update_selected_sample_snapshot(samples_or_err[sel])
      end
    else
      state.rows = state.rows or {}
      state.runtime.galaxy_points_cache = nil
    end
  end
  state.runtime.samples_reload_debounce_sig = nil
  state.runtime.samples_reload_debounce_until = nil
  state.needs_reload_samples = false
  resolve_pending_arrange_sample_selection()
end

local function prewarm_galaxy_points_cache_step()
  if not (state and state.runtime and state.rows) then return end
  if state.ui and state.ui.sample_view_tab == "galaxy" then return end
  if #state.rows == 0 then return end
  if state.runtime.galaxy_points_cache then return end
  if galaxy_ops and type(galaxy_ops.get_cached_galaxy_points) == "function" then
    galaxy_ops.get_cached_galaxy_points(GALAXY_CACHE_STEP_IDLE)
  end
end

local function parse_sample_bpm(value)
  if not key_bpm then return nil end
  return key_bpm.parse_sample_bpm(value)
end

local KEY_ROOT_OPTIONS = (key_bpm and key_bpm.KEY_ROOT_OPTIONS) or {}

local function normalize_key_root_text(root_raw)
  if not key_bpm then return nil end
  return key_bpm.normalize_key_root_text(root_raw)
end

local function key_root_dual_label(root_raw)
  if not key_bpm then return nil end
  return key_bpm.key_root_dual_label(root_raw)
end

local function format_key_text_dual(key_text, compact_mode)
  if not key_bpm then return "" end
  return key_bpm.format_key_text_dual(key_text, compact_mode)
end

local function parse_edit_key_parts(key_text)
  if not key_bpm then return nil, "none" end
  return key_bpm.parse_edit_key_parts(key_text)
end

local function build_edit_key_text(root, mode)
  if not key_bpm then return nil end
  return key_bpm.build_edit_key_text(root, mode)
end

local function normalize_sample_type(value)
  if not key_bpm then return nil end
  return key_bpm.normalize_sample_type(value)
end

local function get_project_bpm()
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
    local ok, bpm = pcall(function() return r.TimeMap2_GetDividedBpmAtTime(0, t) end)
    if ok and type(bpm) == "number" and bpm > 0 then return bpm end
  end
  return nil
end

local function calc_bpm_match_playrate(sample_bpm)
  local sbpm = parse_sample_bpm(sample_bpm)
  if not sbpm then return nil end
  local pbpm = get_project_bpm()
  if not pbpm or pbpm <= 0 then return nil end
  local rate = pbpm / sbpm
  if type(rate) ~= "number" then return nil end
  if rate < 0.1 then rate = 0.1 end
  if rate > 4.0 then rate = 4.0 end
  return rate
end


local function draw_pack_section(win_w)
  if ui_pack and type(ui_pack.draw) == "function" then
    ui_pack.draw(win_w)
  end
end

tag_ops = {}

function tag_ops.parse_optional_number(s)
  if not s or s == "" then return nil end
  local n = tonumber(s)
  return n
end

local TAG_CHIP_MIN_W = 40
local TAG_CHIP_MAX_W_FILTER = 180
local TAG_CHIP_MAX_W_DETAIL = 160

function tag_ops.filter_tags_has(list, tag)
  if not list or not tag then return false end
  for _, t in ipairs(list) do
    if t == tag then return true end
  end
  return false
end

function tag_ops.filter_tags_add_unique(tag)
  tag = tostring(tag or "")
  if tag == "" or tag_ops.filter_tags_has(state.filter_tags, tag) then return end
  tag_ops.filter_tags_exclude_remove_value(tag)
  state.filter_tags[#state.filter_tags + 1] = tag
  -- Clear free-text query so tag filter and filename search do not stack (ImGui input buffer reset via id bump).
  state.tag_filter_input = ""
  if state.runtime then
    state.runtime.tag_filter_input_reset_id = (tonumber(state.runtime.tag_filter_input_reset_id) or 0) + 1
  end
  state.needs_reload_samples = true
end

function tag_ops.filter_tags_remove_at(idx)
  if not idx or idx < 1 or idx > #state.filter_tags then return end
  table.remove(state.filter_tags, idx)
  state.needs_reload_samples = true
end

function tag_ops.filter_tags_remove_value(tag)
  for i = #state.filter_tags, 1, -1 do
    if state.filter_tags[i] == tag then
      table.remove(state.filter_tags, i)
      state.needs_reload_samples = true
      return
    end
  end
end

function tag_ops.filter_tags_toggle_value(tag)
  if tag_ops.filter_tags_has(state.filter_tags, tag) then
    tag_ops.filter_tags_remove_value(tag)
  else
    tag_ops.filter_tags_add_unique(tag)
  end
end

function tag_ops.filter_tags_clear_all()
  if #state.filter_tags == 0 and #(state.filter_tags_exclude or {}) == 0 then return end
  state.filter_tags = {}
  state.filter_tags_exclude = {}
  state.needs_reload_samples = true
end

function tag_ops.filter_tags_exclude_has(tag)
  return tag_ops.filter_tags_has(state.filter_tags_exclude, tag)
end

function tag_ops.filter_tags_exclude_add_unique(tag)
  tag = tostring(tag or "")
  if tag == "" or tag_ops.filter_tags_has(state.filter_tags_exclude, tag) then return end
  tag_ops.filter_tags_remove_value(tag)
  state.filter_tags_exclude[#state.filter_tags_exclude + 1] = tag
  state.needs_reload_samples = true
end

function tag_ops.filter_tags_exclude_remove_at(idx)
  local arr = state.filter_tags_exclude or {}
  if not idx or idx < 1 or idx > #arr then return end
  table.remove(arr, idx)
  state.filter_tags_exclude = arr
  state.needs_reload_samples = true
end

function tag_ops.filter_tags_exclude_remove_value(tag)
  local arr = state.filter_tags_exclude or {}
  for i = #arr, 1, -1 do
    if arr[i] == tag then
      table.remove(arr, i)
      state.filter_tags_exclude = arr
      state.needs_reload_samples = true
      return
    end
  end
end

function tag_ops.clear_all_search_filters()
  state.favorites_only_filter = false
  state.key_filter_enabled = false
  state.bpm_filter_enabled = false
  state.type_filter_enabled = false
  state.key_mode_major = false
  state.key_mode_minor = false
  state.bpm_min = nil
  state.bpm_max = nil
  state.type_is_one_shot = false
  state.type_is_loop = false
  state.tag_filter_input = ""
  tag_ops.filter_tags_clear_all()
  state.needs_reload_samples = true
end

-- One-shot pipeline: Rescan All (async) ?ERepair missing ?ERebuild embed (stage-driven).
tick_galaxy_full_refresh = function()
  local gfr = state and state.manage and state.manage.galaxy_full_refresh
  if not gfr then return end
  if gfr.cancel_requested then
    state.manage.galaxy_full_refresh = nil
    set_runtime_notice("Update Galaxy cancelled.")
    return
  end
  if not sqlite_store or not state.store or not state.store.conn then
    state.manage.galaxy_full_refresh = nil
    return
  end
  if gfr.stage == "repair_pending" then
    gfr.stage = "repair"
    return
  end
  if gfr.stage ~= "repair" and gfr.stage ~= "rebuild" then
    return
  end

  local wrap = { db = state.store.conn }
  if gfr.stage == "repair" then
    local ok_r, okv_r, info_r = pcall(function()
      return sqlite_store.reanalyze_missing_audio_features(wrap, { only_oneshot = true })
    end)
    state.runtime.galaxy_points_cache = nil
    state.needs_reload_samples = true
    reload_pack_lists()
    if not ok_r then
      state.manage.galaxy_full_refresh = nil
      set_runtime_notice("Update Galaxy failed: " .. tostring(info_r or "unknown"))
      return
    end
    if not okv_r then
      state.manage.galaxy_full_refresh = nil
      set_runtime_notice("Update Galaxy failed at repair: " .. tostring(info_r or "unknown"))
      return
    end
    gfr.repair_info = info_r
    gfr.stage = "rebuild"
    return
  end

  local ok_set, set_ok, set_err = pcall(function()
    return sqlite_store.set_phase_e_preset(state.ui.galaxy_embed_preset)
  end)
  if (not ok_set) or (set_ok ~= true) then
    state.manage.galaxy_full_refresh = nil
    set_runtime_notice("Update Galaxy: set preset failed: " .. tostring(set_err or "unknown"))
    state.runtime.galaxy_points_cache = nil
    state.needs_reload_samples = true
    reload_pack_lists()
    return
  end

  local ok_b, okv_b, info_b = pcall(function()
    return sqlite_store.rebuild_galaxy_embedding_with_profiles(wrap, { only_oneshot = true })
  end)
  state.manage.galaxy_full_refresh = nil
  state.runtime.galaxy_points_cache = nil
  state.needs_reload_samples = true
  reload_pack_lists()
  if not ok_b then
    set_runtime_notice("Update Galaxy failed: " .. tostring(info_b or "unknown"))
    return
  end
  if not okv_b then
    local err = (type(info_b) == "table" and (info_b.err ~= nil and tostring(info_b.err) or "")) or tostring(info_b or "unknown")
    set_runtime_notice("Update Galaxy failed at rebuild: " .. err)
    return
  end

  local ir = type(gfr.repair_info) == "table" and gfr.repair_info or {}
  local ib = type(info_b) == "table" and info_b or {}
  local build_info = type(ib.build) == "table" and ib.build or {}
  if C.GALAXY_VERBOSE_UPDATE_NOTICE then
    local msg = "Update Galaxy complete."
    msg = msg
      .. "\nRepair: target=" .. tostring(ir.target or 0)
      .. ", analyzed=" .. tostring(ir.analyzed or 0)
      .. ", updated=" .. tostring(ir.updated or 0) .. "."
    msg = msg
      .. "\nRebuild: " .. tostring(build_info.embedded or ib.embedded or 0)
      .. " rows (preset=" .. tostring(build_info.preset or ib.preset or "")
      .. ", mode=" .. tostring(build_info.mode or ib.mode or "")
      .. ", dims=" .. tostring(build_info.dims or ib.dims or 0) .. ")."
    local dropped = tonumber(build_info.dropped_low_valid or ib.dropped_low_valid) or 0
    local min_valid = tonumber(build_info.min_valid_features or ib.min_valid_features) or 0
    if dropped > 0 then
      if min_valid <= 1 then
        msg = msg .. "\nSkipped (no numeric analysis fields): " .. tostring(dropped)
          .. " (all NULL in analysis ?Erun forced re-analyze from Manage if needed)"
      else
        msg = msg .. "\nDropped low-valid rows: " .. tostring(dropped) .. " (min_valid=" .. tostring(min_valid) .. ")"
      end
    end
    local dropped_nn = tonumber(build_info.dropped_near_neutral or ib.dropped_near_neutral) or 0
    if dropped_nn > 0 then
      msg = msg .. "\nDropped near-neutral rows: " .. tostring(dropped_nn)
    end
    local ex_l = tostring(build_info.excluded_low_valid_sample_ids or ib.excluded_low_valid_sample_ids or "")
    if ex_l ~= "" then
      msg = msg .. "\nExample excluded sample_ids: " .. ex_l
    end
    set_runtime_notice(msg)
  else
    set_runtime_notice("Update Galaxy complete.")
  end
end

local function tag_chip_label_short(tag, max_chars)
  local t = tostring(tag or "")
  max_chars = max_chars or 11
  if #t > max_chars then
    return t:sub(1, max_chars - 2) .. ".."
  end
  return t
end

local function calc_text_w(s, fallback)
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

--- tag_rows: { { tag = "x", count = n? }, ... } or { "x", ... }
--- active_filter_tags: list of tags currently in the AND filter (for * marker)
local function draw_wrapped_tag_chips(ctx, tag_rows, chip_max_w, chip_h, id_prefix, active_filter_tags, on_toggle_tag)
  if not tag_rows or #tag_rows == 0 then return end
  chip_max_w = tonumber(chip_max_w) or TAG_CHIP_MAX_W_FILTER
  chip_h = chip_h or 22
  local avail = content_width()
  if avail <= 0 then avail = 220 end
  local gap = 4
  local used = 0
  local min_w = TAG_CHIP_MIN_W
  local pad_x = 14
  local reserve_for_id = 8
  for i, row in ipairs(tag_rows) do
    local tag = type(row) == "table" and row.tag or row
    if tag and tostring(tag) ~= "" then
      tag = tostring(tag)
      local display = tag_chip_label_short(tag, 24)
      if tag_ops.filter_tags_has(active_filter_tags, tag) then
        display = "*" .. display
      end
      local text_w = calc_text_w(display, 42)
      local chip_w = math.floor(math.max(min_w, math.min(chip_max_w, text_w + pad_x + reserve_for_id)))
      local wid = display .. "##" .. id_prefix .. "_" .. tostring(i)
      if used > 0 and used + gap + chip_w <= avail + 0.5 then
        r.ImGui_SameLine(ctx, 0, gap)
        used = used + gap + chip_w
      else
        used = chip_w
      end
      local chip_push_var_n = 0
      local chip_push_col_n = 0
      if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FrameRounding then
        local ok_sv = pcall(function()
          r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), tonumber(C.MODERN_UI.tag_chip_rounding) or 3.0)
        end)
        if ok_sv then chip_push_var_n = chip_push_var_n + 1 end
      end
      if r.ImGui_PushStyleColor and r.ImGui_Col_Text then
        local ok_sc = pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), C.MODERN_UI.color_tag_chip_text or 0xC8C9CDFF)
        end)
        if ok_sc then chip_push_col_n = chip_push_col_n + 1 end
      end
      local left_clicked = r.ImGui_Button(ctx, wid, chip_w, chip_h)
      local right_clicked = false
      if r.ImGui_BeginPopupContextItem and r.ImGui_EndPopup then
        local popup_id = "##top_tag_ctx_" .. tostring(id_prefix) .. "_" .. tostring(i)
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
    end
  end
end

local function draw_search_section(win_w)
  if ui_search and type(ui_search.draw) == "function" then
    ui_search.draw(win_w)
  end
end

function draw_rows_virtualized(total_rows, draw_row_fn, clipper_slot_key)
  if total_rows < 1 or type(draw_row_fn) ~= "function" then return end

  local function fallback_full_draw()
    for row_idx = 1, total_rows do
      draw_row_fn(row_idx)
    end
  end

  local has_api =
    r.ImGui_CreateListClipper
    and r.ImGui_ListClipper_Begin
    and r.ImGui_ListClipper_Step
    and r.ImGui_ListClipper_GetDisplayRange
    and r.ImGui_ListClipper_End
  if not has_api then
    fallback_full_draw()
    return false
  end

  local slot = tostring(clipper_slot_key or "sample_row_clipper")
  local clipper = state.runtime[slot]
  if clipper and r.ImGui_ValidatePtr then
    local ok_v, valid = pcall(function()
      return r.ImGui_ValidatePtr(clipper, "ImGui_ListClipper*")
    end)
    if ok_v and (not valid) then
      clipper = nil
      state.runtime[slot] = nil
    end
  end
  if not clipper then
    local ok_new, created = pcall(function()
      return r.ImGui_CreateListClipper(ctx)
    end)
    if ok_new and created then
      clipper = created
      state.runtime[slot] = created
    end
  end
  if not clipper then
    fallback_full_draw()
    return false
  end

  local ok_begin = pcall(function()
    r.ImGui_ListClipper_Begin(clipper, total_rows)
  end)
  if not ok_begin then
    -- Recreate on next frame in case stored pointer became stale.
    state.runtime[slot] = nil
    fallback_full_draw()
    return false
  end

  local drew_any = false
  while true do
    local ok_step, visible = pcall(function()
      return r.ImGui_ListClipper_Step(clipper)
    end)
    if not ok_step or not visible then break end

    local ok_range, display_start, display_end = pcall(function()
      return r.ImGui_ListClipper_GetDisplayRange(clipper)
    end)
    if ok_range then
      local s = (tonumber(display_start) or 0) + 1
      local e = tonumber(display_end) or 0
      if s < 1 then s = 1 end
      if e > total_rows then e = total_rows end
      for row_idx = s, e do
        draw_row_fn(row_idx)
      end
      drew_any = true
    end
  end
  pcall(function()
    r.ImGui_ListClipper_End(clipper)
  end)

  -- Defensive fallback for versions where clipper API shape differs.
  if not drew_any then
    fallback_full_draw()
    return false
  end
  return true
end

galaxy_ops = {}

function galaxy_ops.parse_key_root_index(key_estimate)
  if not key_estimate or key_estimate == "" then return nil end
  local txt = tostring(key_estimate):upper():gsub("^%s+", ""):gsub("%s+$", "")
  local root = txt:match("^([A-G]#?)")
  local map = {
    C = 0, ["C#"] = 1, D = 2, ["D#"] = 3, E = 4, F = 5,
    ["F#"] = 6, G = 7, ["G#"] = 8, A = 9, ["A#"] = 10, B = 11
  }
  return root and map[root] or nil
end

function galaxy_ops.norm_bpm(bpm)
  local n = tonumber(bpm)
  if not n or n <= 0 then return nil end
  local clamped = math.max(60, math.min(200, n))
  return (clamped - 60) / 140
end

function galaxy_ops.clamp01(v)
  if v == nil then return 0.5 end
  v = tonumber(v) or 0.5
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

function galaxy_ops.txt_has_token(txt, token)
  if not txt or txt == "" then return false end
  return txt:find("%f[%a]" .. token .. "%f[^%a]") ~= nil
end

function galaxy_ops.score_tokens(txt, positive, negative, default_value)
  local pos = 0
  local neg = 0
  for _, t in ipairs(positive or {}) do
    if galaxy_ops.txt_has_token(txt, t) then pos = pos + 1 end
  end
  for _, t in ipairs(negative or {}) do
    if galaxy_ops.txt_has_token(txt, t) then neg = neg + 1 end
  end
  local base = tonumber(default_value) or 0.5
  local score = base + (pos * 0.12) - (neg * 0.12)
  return galaxy_ops.clamp01(score)
end

function galaxy_ops.infer_family_norm(filename_lc)
  local families = {
    { n = 0.05, keys = { "kick", "bd", "808" } },
    { n = 0.18, keys = { "snare", "rim" } },
    { n = 0.30, keys = { "clap" } },
    { n = 0.44, keys = { "hat", "hihat", "hh", "cym", "ride", "crash", "shaker" } },
    { n = 0.58, keys = { "tom", "perc", "conga", "bongo", "clave", "cowbell" } },
    { n = 0.74, keys = { "fx", "sfx", "noise", "sweep", "impact", "riser", "downlifter" } },
    { n = 0.88, keys = { "chord", "stab", "pluck", "bass", "lead", "vox", "vocal" } },
  }
  for _, fam in ipairs(families) do
    for _, key in ipairs(fam.keys) do
      if galaxy_ops.txt_has_token(filename_lc, key) then
        return fam.n
      end
    end
  end
  return 0.5
end

function galaxy_ops.infer_family_name(filename_lc)
  local s = tostring(filename_lc or ""):lower()
  local function has(tok)
    return galaxy_ops.txt_has_token(s, tok)
  end
  if has("kick") or has("bd") or has("808") then return "kick" end
  if has("snare") or has("rim") then return "snare" end
  if has("clap") then return "clap" end
  if has("hat") or has("hihat") or has("hh") or has("cym") or has("ride") or has("crash") or has("shaker") then return "hat" end
  if has("tom") or has("percussion") or has("perc") or has("conga") or has("bongo") or has("clave") or has("cowbell") then return "perc" end
  if has("fx") or has("sfx") or has("noise") or has("sweep") or has("impact") or has("riser") or has("downlifter") then return "fx" end
  if has("chord") or has("stab") or has("pluck") or has("bass") or has("lead") or has("vox") or has("vocal") then return "tonal" end
  return "other"
end

-- 0xRRGGBBAA ?Egalaxy dot fill by inferred family (see draw loop for selected: larger fill + same-color ring).
-- GALAXY_VIEW_MARGIN: extra pan range in normalized map space so edge points are not stuck to the canvas border.
local GALAXY_VIEW_MARGIN = 0.22
-- Extra range only toward larger map Y (screen downward) when zoomed out.
local GALAXY_VIEW_MARGIN_BOTTOM_EXTRA = 0.2
local GALAXY_TRAIL_MAX_SEC = 1.05
local GALAXY_TRAIL_STEPS = 26
local GALAXY_PICK_RADIUS_PX = 11
local GALAXY_CACHE_STEP_UI = 220
local GALAXY_CACHE_STEP_IDLE = 96

function galaxy_ops.clamp_galaxy_center(cx, cy, half)
  local lo = half - GALAXY_VIEW_MARGIN
  local hi = 1.0 - half + GALAXY_VIEW_MARGIN
  cx = math.max(lo, math.min(hi, tonumber(cx) or 0.5))
  local lo_y = half - GALAXY_VIEW_MARGIN
  local hi_y = 1.0 - half + GALAXY_VIEW_MARGIN + GALAXY_VIEW_MARGIN_BOTTOM_EXTRA
  cy = math.max(lo_y, math.min(hi_y, tonumber(cy) or 0.5))
  return cx, cy
end

function galaxy_ops.galaxy_now_s()
  if r.time_precise then
    local ok, t = pcall(r.time_precise)
    if ok and type(t) == "number" then return t end
  end
  return os.clock()
end

function galaxy_ops.galaxy_point_fill_color(fam)
  fam = tostring(fam or "other")
  if fam == "unmapped" then return 0xFFFFFFFF end
  if fam == "kick" then return 0xC23B3BFF end
  if fam == "snare" then return 0x2F7EC4FF end
  if fam == "clap" then return 0x6E48C4FF end
  if fam == "hat" then return 0xC99410FF end
  if fam == "perc" then return 0x2FA884FF end
  if fam == "fx" then return 0xB84A86FF end
  if fam == "tonal" then return 0x4E9AD6FF end
  return 0x4A6799FF
end

function galaxy_ops.galaxy_feature_xy(row)
  local ex = tonumber(row and row.embed_x)
  local ey = tonumber(row and row.embed_y)
  if ex and ey then
    return galaxy_ops.clamp01(ex), galaxy_ops.clamp01(ey)
  end
  local fname = (row and row.filename and tostring(row.filename):lower()) or ""
  local bright_guess = galaxy_ops.score_tokens(
    fname,
    { "bright", "air", "top", "hat", "shaker", "crisp", "sharp", "hi" },
    { "dark", "sub", "low", "dull", "muffled", "warm" },
    0.5
  )
  local decay_guess = galaxy_ops.score_tokens(
    fname,
    { "long", "tail", "sustain", "reverb", "ring", "wash", "open" },
    { "short", "tight", "closed", "mute", "dry", "stab" },
    0.5
  )
  local noise_guess = galaxy_ops.score_tokens(
    fname,
    { "noise", "fx", "sizzle", "hiss", "dist", "dirty" },
    { "tone", "sine", "clean", "pure" },
    0.5
  )
  local tonal_guess = galaxy_ops.clamp01(1.0 - noise_guess)

  local brightness = galaxy_ops.clamp01(tonumber(row and row.brightness) or bright_guess)
  local decay = galaxy_ops.clamp01(tonumber(row and row.decay_length) or decay_guess)
  local noise = galaxy_ops.clamp01(tonumber(row and row.noisiness) or noise_guess)
  local tonal = galaxy_ops.clamp01(tonumber(row and row.tonalness) or tonal_guess)

  -- Oneshot map: key/bpm are intentionally ignored (often missing/unreliable for one-shots).
  -- Vertical spread from features; X is a narrow left strip so unmapped rows (often 0.5-filled)
  -- do not pile on top of the UMAP cloud in the center when "Show unmapped" is on.
  local y = (0.45 * decay) + (0.33 * noise) + (0.14 * (1.0 - tonal)) + (0.08 * (1.0 - brightness))

  local sid = tonumber(row and row.id) or 0
  local h1 = (math.sin((((sid * 17) + 3) * 12.9898) + 78.233) * 43758.5453)
  local h2 = (math.sin((((sid * 19) + 7) * 12.9898) + 78.233) * 43758.5453)
  local frac1 = h1 - math.floor(h1)
  local x = 0.03 + frac1 * 0.08
  local jy = ((h2 - math.floor(h2)) - 0.5) * 0.032
  y = y + jy
  return galaxy_ops.clamp01(x), galaxy_ops.clamp01(y)
end

function galaxy_ops.galaxy_map_xy_for_row_idx(row_idx)
  local ri = tonumber(row_idx)
  local row = ri and state.rows and state.rows[ri]
  if not row then return nil, nil end
  return galaxy_ops.galaxy_feature_xy(row)
end

function galaxy_ops.get_cached_galaxy_points(step_budget)
  local show_unmapped = true
  local cache = state.runtime and state.runtime.galaxy_points_cache
  if cache and cache.rows_ref == state.rows then
    return cache.points, cache.oneshot_total, cache.audio_feature_rows, cache.embed_rows, false
  end
  local runtime = state.runtime or {}
  local rows = state.rows or {}
  local build = runtime.galaxy_points_build
  if type(build) ~= "table" or build.rows_ref ~= state.rows then
    build = {
      rows_ref = state.rows,
      next_idx = 1,
      points = {},
      oneshot_total = 0,
      audio_feature_rows = 0,
      embed_rows = 0,
    }
    runtime.galaxy_points_build = build
  end

  local budget = tonumber(step_budget) or GALAXY_CACHE_STEP_UI
  if budget < 1 then budget = 1 end
  local low_frames = tonumber(runtime.galaxy_low_budget_frames) or 0
  if low_frames > 0 then
    runtime.galaxy_low_budget_frames = low_frames - 1
    budget = math.max(1, math.floor(budget * 0.25))
  end
  local n_rows = #rows
  local processed = 0
  while build.next_idx <= n_rows and processed < budget do
    local idx = build.next_idx
    local row = rows[idx]
    local t = row and row.type and tostring(row.type):lower() or ""
    if t == "oneshot" then
      if file_exists_cached(row and row.path) then
        build.oneshot_total = build.oneshot_total + 1
        local has_audio =
          (tonumber(row and row.brightness) ~= nil)
          or (tonumber(row and row.noisiness) ~= nil)
          or (tonumber(row and row.attack_sharpness) ~= nil)
          or (tonumber(row and row.decay_length) ~= nil)
          or (tonumber(row and row.tonalness) ~= nil)
        if has_audio then build.audio_feature_rows = build.audio_feature_rows + 1 end
        local has_embed = tonumber(row and row.embed_x) and tonumber(row and row.embed_y)
        if has_embed then build.embed_rows = build.embed_rows + 1 end
        if show_unmapped or has_embed then
          local fname = (row and row.filename and tostring(row.filename):lower()) or ""
          local gx, gy = galaxy_ops.galaxy_feature_xy(row)
          build.points[#build.points + 1] = {
            row_idx = idx,
            sample_id = tonumber(row.id) or idx,
            x = gx,
            y = gy,
            family = has_embed and galaxy_ops.infer_family_name(fname) or "unmapped",
          }
        end
      end
    end
    build.next_idx = idx + 1
    processed = processed + 1
  end

  local building = build.next_idx <= n_rows
  if building then
    return build.points, build.oneshot_total, build.audio_feature_rows, build.embed_rows, true
  end

  state.runtime.galaxy_points_cache = {
    rows_ref = state.rows,
    points = build.points,
    oneshot_total = build.oneshot_total,
    audio_feature_rows = build.audio_feature_rows,
    embed_rows = build.embed_rows,
  }
  state.runtime.galaxy_points_build = nil
  return build.points, build.oneshot_total, build.audio_feature_rows, build.embed_rows, false
end

function galaxy_ops.get_window_draw_list_safe()
  local dl = nil
  pcall(function()
    if r.ImGui_GetWindowDrawList then
      dl = r.ImGui_GetWindowDrawList(ctx)
    elseif r.ImGui_GetForegroundDrawList then
      dl = r.ImGui_GetForegroundDrawList(ctx)
    end
  end)
  return dl
end

function galaxy_ops.drawlist_add_rect_filled(dl, x1, y1, x2, y2, col)
  pcall(function()
    if r.ImGui_DrawList_AddRectFilled then
      r.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, col)
    elseif r.ImDrawList_AddRectFilled then
      r.ImDrawList_AddRectFilled(dl, x1, y1, x2, y2, col)
    end
  end)
end

function galaxy_ops.drawlist_add_line(dl, x1, y1, x2, y2, col, thick)
  pcall(function()
    if r.ImGui_DrawList_AddLine then
      r.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, col, thick or 1)
    elseif r.ImDrawList_AddLine then
      r.ImDrawList_AddLine(dl, x1, y1, x2, y2, col, thick or 1)
    end
  end)
end

function galaxy_ops.drawlist_add_circle_filled(dl, x, y, radius, col)
  pcall(function()
    if r.ImGui_DrawList_AddCircleFilled then
      r.ImGui_DrawList_AddCircleFilled(dl, x, y, radius, col)
    elseif r.ImDrawList_AddCircleFilled then
      r.ImDrawList_AddCircleFilled(dl, x, y, radius, col)
    end
  end)
end

function galaxy_ops.drawlist_add_circle(dl, x, y, radius, col, thickness, num_segments)
  thickness = tonumber(thickness) or 1.0
  num_segments = tonumber(num_segments) or 12
  pcall(function()
    if r.ImGui_DrawList_AddCircle then
      r.ImGui_DrawList_AddCircle(dl, x, y, radius, col, num_segments, thickness)
    elseif r.ImDrawList_AddCircle then
      r.ImDrawList_AddCircle(dl, x, y, radius, col, num_segments, thickness)
    end
  end)
end

function galaxy_ops.draw_galaxy_scatter_dot(dl, px, py, base_radius, fam, selected, zoom_mul)
  if not dl then return end
  local col = galaxy_ops.galaxy_point_fill_color(fam)
  local z = tonumber(zoom_mul) or 1.0
  if selected then
    local br = tonumber(base_radius) or 1.0
    local r_fill = math.max(br * 1.36 + 0.6 * z, 3.4 * z)
    galaxy_ops.drawlist_add_circle_filled(dl, px, py, r_fill, col)
    local ring_r = r_fill + 2.2 + 0.7 * z
    galaxy_ops.drawlist_add_circle(dl, px, py, ring_r, col, 1.0, 28)
  else
    galaxy_ops.drawlist_add_circle_filled(dl, px, py, base_radius, col)
  end
end

function galaxy_ops.drawlist_line_gradient_fade(dl, ax, ay, bx, by, time_fade)
  if not dl or time_fade < 0.03 then return end
  local steps = GALAXY_TRAIL_STEPS
  for i = 0, steps - 1 do
    local u0 = i / steps
    local u1 = (i + 1) / steps
    local px0 = ax + (bx - ax) * u0
    local py0 = ay + (by - ay) * u0
    local px1 = ax + (bx - ax) * u1
    local py1 = ay + (by - ay) * u1
    local spatial = 0.22 + 0.78 * u1
    local a = math.floor(255 * spatial * time_fade)
    if a >= 12 then
      local thick = 1.1 + 1.1 * spatial * time_fade
      galaxy_ops.drawlist_add_line(dl, px0, py0, px1, py1, 0xFFFFFF00 + a, thick)
    end
  end
end

-- Map space matches galaxy_feature_xy / embed (roughly [0,1]); segments stay aligned when panning/zooming.
function galaxy_ops.galaxy_map_to_screen(mx, my, x0, y0, cw, ch, x_min, x_max, y_min, y_max)
  local sx = (tonumber(x_max) or 0) - (tonumber(x_min) or 0)
  local sy = (tonumber(y_max) or 0) - (tonumber(y_min) or 0)
  if math.abs(sx) < 1e-12 or math.abs(sy) < 1e-12 then return nil, nil end
  local px = (tonumber(x0) or 0) + ((tonumber(mx) or 0) - (tonumber(x_min) or 0)) / sx * (tonumber(cw) or 1)
  local py = (tonumber(y0) or 0) + ((tonumber(my) or 0) - (tonumber(y_min) or 0)) / sy * (tonumber(ch) or 1)
  return px, py
end

function galaxy_ops.galaxy_trail_prune_and_draw(dl, vx)
  if not dl or type(vx) ~= "table" then return end
  if not state.runtime.galaxy_trail_segments then
    state.runtime.galaxy_trail_segments = {}
    return
  end
  local now = galaxy_ops.galaxy_now_s()
  local segs = state.runtime.galaxy_trail_segments
  local kept = {}
  local x0, y0 = vx.x0, vx.y0
  local cw, ch = vx.cw, vx.ch
  local x_min, x_max = vx.x_min, vx.x_max
  local y_min, y_max = vx.y_min, vx.y_max
  for i = 1, #segs do
    local s = segs[i]
    local t0 = tonumber(s.t0) or now
    local age = now - t0
    local fade = 1.0 - (age / GALAXY_TRAIL_MAX_SEC)
    if fade > 0.03 then
      local ax_m = tonumber(s.ax_m or s.ax)
      local ay_m = tonumber(s.ay_m or s.ay)
      local bx_m = tonumber(s.bx_m or s.bx)
      local by_m = tonumber(s.by_m or s.by)
      if ax_m and ay_m and bx_m and by_m then
        local ax, ay = galaxy_ops.galaxy_map_to_screen(ax_m, ay_m, x0, y0, cw, ch, x_min, x_max, y_min, y_max)
        local bx, by = galaxy_ops.galaxy_map_to_screen(bx_m, by_m, x0, y0, cw, ch, x_min, x_max, y_min, y_max)
        if ax and ay and bx and by then
          galaxy_ops.drawlist_line_gradient_fade(dl, ax, ay, bx, by, fade)
        end
      end
      kept[#kept + 1] = s
    end
  end
  state.runtime.galaxy_trail_segments = kept
end

function galaxy_ops.hash01_from_int(n)
  local x = tonumber(n) or 0
  local v = math.sin((x * 12.9898) + 78.233) * 43758.5453
  return v - math.floor(v)
end

setup_all_ui_modules = function()
  if not (state and ctx) then return end
  if ui_preview and type(ui_preview.setup) == "function" then
    ui_preview.setup({
      r = r,
      state = state,
      C = C,
      set_runtime_notice = set_runtime_notice,
      file_exists = file_exists,
      key_bpm = key_bpm,
      get_selected_sample_row = get_selected_sample_row,
    })
  end
  if ui_search and type(ui_search.setup) == "function" then
    ui_search.setup({
      r = r,
      ctx = ctx,
      state = state,
      sqlite_store = sqlite_store,
      safe_push_font = safe_push_font,
      safe_pop_font = safe_pop_font,
      calc_text_w = calc_text_w,
      should_accept_toggle_click = should_accept_toggle_click,
      parse_optional_number = tag_ops.parse_optional_number,
      ui_input_text_with_hint = ui_input_text_with_hint,
      window_flag_noresize = window_flag_noresize,
      window_flag_noscroll_with_mouse = window_flag_noscroll_with_mouse,
      filter_tags_has = tag_ops.filter_tags_has,
      filter_tags_clear_all = tag_ops.filter_tags_clear_all,
      filter_tags_remove_at = tag_ops.filter_tags_remove_at,
      filter_tags_remove_value = tag_ops.filter_tags_remove_value,
      filter_tags_add_unique = tag_ops.filter_tags_add_unique,
      filter_tags_exclude_has = tag_ops.filter_tags_exclude_has,
      filter_tags_exclude_remove_at = tag_ops.filter_tags_exclude_remove_at,
      filter_tags_exclude_remove_value = tag_ops.filter_tags_exclude_remove_value,
      filter_tags_exclude_add_unique = tag_ops.filter_tags_exclude_add_unique,
      draw_text_only_button = draw_text_only_button,
      content_width = content_width,
      tag_chip_label_short = tag_chip_label_short,
      draw_wrapped_tag_chips = draw_wrapped_tag_chips,
      calc_text_w_fallback = 42,
      tag_chip_min_w = TAG_CHIP_MIN_W,
      tag_chip_max_w_filter = TAG_CHIP_MAX_W_FILTER,
      font_small = font_small,
      get_project_bpm = get_project_bpm,
      search_ui = C.SEARCH_UI,
    })
  end
  if ui_pack and type(ui_pack.setup) == "function" then
    ui_pack.setup({
      r = r,
      ctx = ctx,
      state = state,
      sqlite_store = sqlite_store,
      cover_art = cover_art,
      scan_controller = scan_controller,
      font_small = font_small,
      active_pack_strip_h = C.ACTIVE_PACK_STRIP_H,
      active_pack_chip_pad_y = C.ACTIVE_PACK_CHIP_PAD_Y,
      active_pack_scrollbar_size = C.ACTIVE_PACK_SCROLLBAR_SIZE,
      pack_list_row_min_h = C.PACK_LIST_ROW_MIN_H,
      pack_list_thumb = C.PACK_LIST_THUMB,
      content_width = content_width,
      safe_push_font = safe_push_font,
      safe_pop_font = safe_pop_font,
      window_flag_noresize = window_flag_noresize,
      window_flag_noscroll_with_mouse = window_flag_noscroll_with_mouse,
      window_flag_always_vertical_scrollbar = window_flag_always_vertical_scrollbar,
      ui_input_text_with_hint = ui_input_text_with_hint,
      draw_rows_virtualized = draw_rows_virtualized,
      filter_pack_ids_has = filter_pack_ids_has,
      filter_pack_ids_toggle = filter_pack_ids_toggle,
      filter_pack_ids_clear = filter_pack_ids_clear,
      filter_pack_ids_remove_at = filter_pack_ids_remove_at,
      pack_display_name_by_id = pack_display_name_by_id,
      reload_pack_lists = reload_pack_lists,
      set_runtime_notice = set_runtime_notice,
      sanitize_root_path_input = sanitize_root_path_input,
      set_persisted_splice_db_path = set_persisted_splice_db_path,
      set_persisted_splice_relink_roots = set_persisted_splice_relink_roots,
      pack_ui = C.PACK_UI,
      use_native_tabs = supports_native_tab_colors(),
    })
  end
  if ui_samples_list and type(ui_samples_list.setup) == "function" then
    ui_samples_list.setup({
      r = r,
      ctx = ctx,
      state = state,
      sqlite_store = sqlite_store,
      cover_art = cover_art,
      sample_section_min_h = C.SAMPLE_SECTION_MIN_H,
      sample_list_row_min_h = C.SAMPLE_LIST_ROW_MIN_H,
      sample_list_thumb = C.SAMPLE_LIST_THUMB,
      font_main = font_main,
      window_flag_noresize = window_flag_noresize,
      window_flag_noscrollbar = window_flag_noscrollbar,
      window_flag_noscroll_with_mouse = window_flag_noscroll_with_mouse,
      safe_push_font = safe_push_font,
      safe_pop_font = safe_pop_font,
      draw_text_only_button = draw_text_only_button,
      draw_rows_virtualized = draw_rows_virtualized,
      imgui_mod_down = imgui_mod_down,
      bulk_clear_all_selection = bulk_clear_all_selection,
      bulk_set_row_selected = bulk_set_row_selected,
      bulk_toggle_sample_id = bulk_toggle_sample_id,
      bulk_selected_count = bulk_selected_count,
      bulk_selected_ids_list = bulk_selected_ids_list,
      set_selected_row = set_selected_row,
      stop_preview = stop_preview,
      set_runtime_notice = set_runtime_notice,
      play_selected_sample_preview = play_selected_sample_preview,
      begin_drag_for_row = (ui_dnd and ui_dnd.begin_drag_for_row) or nil,
      open_sample_edit_popup_for_row = M._open_sample_edit_popup_for_row,
      open_sample_edit_popup_for_ids = M._open_sample_edit_popup_for_ids,
      list_ui = C.LIST_UI,
    })
  end
  if ui_samples_galaxy and type(ui_samples_galaxy.setup) == "function" then
    ui_samples_galaxy.setup({
      r = r,
      ctx = ctx,
      state = state,
      sqlite_store = sqlite_store,
      scan_controller = scan_controller,
      galaxy_ops = galaxy_ops,
      sample_section_min_h = C.SAMPLE_SECTION_MIN_H,
      galaxy_pick_radius_px = GALAXY_PICK_RADIUS_PX,
      window_flag_noresize = window_flag_noresize,
      window_flag_noscrollbar = window_flag_noscrollbar,
      window_flag_noscroll_with_mouse = window_flag_noscroll_with_mouse,
      content_width = content_width,
      set_runtime_notice = set_runtime_notice,
      bulk_clear_all_selection = bulk_clear_all_selection,
      bulk_set_row_selected = bulk_set_row_selected,
      set_selected_row = set_selected_row,
      play_selected_sample_preview = play_selected_sample_preview,
    })
  end
  if ui_dnd and type(ui_dnd.setup) == "function" then
    ui_dnd.setup({
      r = r,
      ctx = ctx,
      state = state,
      set_runtime_notice = set_runtime_notice,
      file_exists = file_exists,
      get_selected_sample_row = get_selected_sample_row,
      set_selected_row = set_selected_row,
      stop_preview = stop_preview,
      preview_seek_or_restart_from_ratio = preview_seek_or_restart_from_ratio,
      normalize_sample_type = normalize_sample_type,
      calc_bpm_match_playrate = calc_bpm_match_playrate,
      is_imgui_ctx_valid = is_imgui_ctx_valid,
    })
  end
  if ui_edit_popup and type(ui_edit_popup.setup) == "function" then
    ui_edit_popup.setup({
      r = r,
      ctx = ctx,
      state = state,
      sqlite_store = sqlite_store,
      ui_input_text_with_hint = ui_input_text_with_hint,
      window_flag_noresize = window_flag_noresize,
      set_runtime_notice = set_runtime_notice,
      find_row_index_by_sample_id = find_row_index_by_sample_id,
      make_sample_row_snapshot = M._make_sample_row_snapshot,
      parse_edit_key_parts = parse_edit_key_parts,
      build_edit_key_text = build_edit_key_text,
      KEY_ROOT_OPTIONS = KEY_ROOT_OPTIONS,
      is_imgui_ctx_valid = is_imgui_ctx_valid,
      app_mod = M,
    })
  end
end

local function draw_samples_section(win_w, list_h)
  if not is_imgui_ctx_valid() then return end
  local tab = state.ui.sample_view_tab
  if tab ~= "list" and tab ~= "galaxy" then
    tab = "list"
    state.ui.sample_view_tab = tab
  end
  local tabbar_handled = false
  if false and supports_native_tab_colors() and r.ImGui_BeginTabBar then
    local ok_tb, ret_tb = pcall(r.ImGui_BeginTabBar, ctx, "##sample_view_tabbar", 0)
    local open_tb = ok_tb and (ret_tb ~= false)
    if open_tb then
      tabbar_handled = true
      if r.ImGui_BeginTabItem(ctx, "List##sample_view_list_tab") then
        state.ui.sample_view_tab = "list"
        r.ImGui_EndTabItem(ctx)
      end
      if r.ImGui_BeginTabItem(ctx, "Galaxy##sample_view_galaxy_tab") then
        state.ui.sample_view_tab = "galaxy"
        r.ImGui_EndTabItem(ctx)
      end
      if r.ImGui_EndTabBar then
        r.ImGui_EndTabBar(ctx)
      end
      r.ImGui_Spacing(ctx)
    end
  end
  if not tabbar_handled then
    local function draw_mono_tab_button(label, id, selected, w, h)
      local push_n = 0
      if r.ImGui_PushStyleColor and r.ImGui_Col_Button then
        pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), selected and 0xEDEDEDFF or 0x00000000)
          push_n = push_n + 1
        end)
        pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), selected and 0xEDEDEDFF or (C.MODERN_UI.color_border or 0x45464DFF))
          push_n = push_n + 1
        end)
        pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), selected and 0xEDEDEDFF or (C.MODERN_UI.color_border or 0x45464DFF))
          push_n = push_n + 1
        end)
        pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), selected and 0x2A2A2AFF or (C.MODERN_UI.color_text or 0xF2F2F2FF))
          push_n = push_n + 1
        end)
      end
      local clicked = false
      pcall(function()
        clicked = r.ImGui_Button(ctx, label .. id, w, h) == true
      end)
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
    local wtab = 84
    local clicked_list, rect1 = draw_mono_tab_button("List", "##sample_view_list", tab == "list", wtab, 22)
    if clicked_list then
      state.ui.sample_view_tab = "list"
    end
    local sample_view_tab_gap = 6
    pcall(function()
      r.ImGui_SameLine(ctx, 0, sample_view_tab_gap)
    end)
    local clicked_gal, rect2 = draw_mono_tab_button("Galaxy", "##sample_view_galaxy", tab == "galaxy", wtab, 22)
    if clicked_gal then
      state.ui.sample_view_tab = "galaxy"
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
          local col = C.MODERN_UI.color_border or 0x45464DFF
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
    r.ImGui_Spacing(ctx)
  end

  if state.ui.sample_view_tab == "galaxy" then
    if ui_samples_galaxy and type(ui_samples_galaxy.draw) == "function" then
      ui_samples_galaxy.draw(win_w, math.max(C.SAMPLE_SECTION_MIN_H, list_h - 28))
    end
  else
    if ui_samples_list and type(ui_samples_list.draw) == "function" then
      ui_samples_list.draw(win_w, math.max(C.SAMPLE_SECTION_MIN_H, list_h - 28))
    end
  end
end

local function draw_detail_section(win_w, detail_h)
  if not is_imgui_ctx_valid() then return end
  detail_h = math.max(C.DETAIL_PANEL_MIN_H, math.floor(tonumber(detail_h) or 120))
  -- Scrollable detail: vertical scrollbar always visible; mouse wheel scrolls when hovered.
  local flags = window_flag_noresize() | window_flag_always_vertical_scrollbar()
  local detail_panel_visible = false
  local detail_child_begun = false
  local detail_pre_w, detail_pre_h = nil, nil
  pcall(function()
    detail_pre_w, detail_pre_h = r.ImGui_GetWindowSize(ctx)
  end)
  local ok_detail_begin = pcall(function()
    detail_panel_visible = r.ImGui_BeginChild(ctx, "##detail_panel", 0, detail_h, 1, flags) == true
    detail_child_begun = true
  end)
  local detail_post_w, detail_post_h = nil, nil
  pcall(function()
    detail_post_w, detail_post_h = r.ImGui_GetWindowSize(ctx)
  end)  if ok_detail_begin and detail_panel_visible then
    if state.runtime then
      state.runtime.detail_preview_interactive = false
      state.runtime.wave_screen_rect = nil
    end
    local row = get_selected_sample_row()
    local function draw_preview_tab()
      if state.runtime then
        state.runtime.detail_preview_interactive = true
      end
      do
        local now = (r.time_precise and r.time_precise()) or os.clock()
        local min_interval = 0.08
        local dragging = (state.runtime and state.runtime.galaxy_paint_drag == true)
        if dragging then
          local last_ts = tonumber(state.runtime.detail_throttle_last_row_ts) or 0
          local cached_row = state.runtime.detail_throttle_row
          if cached_row and (now - last_ts) < min_interval then
            row = cached_row
          else
            state.runtime.detail_throttle_row = row
            state.runtime.detail_throttle_last_row_ts = now
          end
        else
          state.runtime.detail_throttle_row = row
          state.runtime.detail_throttle_last_row_ts = now
        end
      end
      if row then
        local meta_cw = math.max(220, content_width(win_w))
        local file_w = math.max(140, math.floor(meta_cw - 4))
        draw_fading_text_line("detail_filename", row.filename or "No selection", file_w)
      else
        r.ImGui_Text(ctx, "No selection")
      end
      if row then
        local pack_label = (row.pack_name and tostring(row.pack_name) ~= "") and tostring(row.pack_name) or "--"
        local pid = tonumber(row.pack_id)
        if pid and pid > 0 and r.ImGui_SmallButton and r.ImGui_SmallButton(ctx, pack_label) then
          filter_pack_set_single(pid)
          set_runtime_notice("Pack filter: " .. pack_label)
        elseif not (pid and pid > 0) then
          r.ImGui_Text(ctx, pack_label)
        end
        local bpm_txt = row.bpm and tostring(row.bpm) or nil
        local key_txt = nil
        if row.key_estimate and tostring(row.key_estimate) ~= "" then
          key_txt = format_key_text_dual(tostring(row.key_estimate), true)
        end
        local typ = tostring(row.type or ""):lower()
        local type_txt = nil
        if typ == "oneshot" then
          type_txt = "oneshots"
        elseif typ == "loop" then
          type_txt = "loops"
        elseif typ ~= "" then
          type_txt = typ
        end
        local meta_parts = {}
        if bpm_txt then meta_parts[#meta_parts + 1] = bpm_txt end
        if key_txt then meta_parts[#meta_parts + 1] = key_txt end
        if type_txt then meta_parts[#meta_parts + 1] = type_txt end
        local meta_text = table.concat(meta_parts, "  ")
        if meta_text ~= "" then
          r.ImGui_SameLine(ctx, 0, 8)
          r.ImGui_Text(ctx, meta_text)
        end
      end
      r.ImGui_Spacing(ctx)
      local ww = math.max(120, content_width(win_w) - 2)
      local wh = 60
      local wx, wy = r.ImGui_GetCursorScreenPos(ctx)
      local peaks = nil
      do
        local sid = row and tonumber(row.id) or nil
        local pth = row and row.path or nil
        local now = (r.time_precise and r.time_precise()) or os.clock()
        local changed = (state.runtime.detail_cache_sample_id ~= sid) or (state.runtime.detail_cache_path ~= pth)
        if changed then
          state.runtime.detail_cache_sample_id = sid
          state.runtime.detail_cache_path = pth
          state.runtime.detail_cache_path_changed_at = now
          state.runtime.detail_cache_peaks = nil
          state.runtime.detail_cache_peaks_quality = nil
          state.runtime.detail_cache_next_quick_retry_at = nil
          state.runtime.detail_cache_next_full_retry_at = nil
          state.runtime.detail_cache_tags = nil
        end
        if waveform and pth and file_exists(pth) then
          local changed_at = tonumber(state.runtime.detail_cache_path_changed_at) or now
          if state.runtime.detail_cache_peaks == nil then
            local next_quick_retry_at = tonumber(state.runtime.detail_cache_next_quick_retry_at) or 0
            if now >= next_quick_retry_at then
              -- Fast path: show REAL waveform quickly at lower resolution.
              local okq, pks_q = pcall(function() return waveform.build_peaks(pth, 96) end)
              if okq and type(pks_q) == "table" and #pks_q > 0 then
                state.runtime.detail_cache_peaks = pks_q
                state.runtime.detail_cache_peaks_quality = "quick"
                state.runtime.detail_cache_next_quick_retry_at = nil
              else
                state.runtime.detail_cache_next_quick_retry_at = now + 0.25
              end
            end
          end
          if state.runtime.detail_cache_peaks_quality ~= "full" then
            local age = now - changed_at
            local hover_stable = (age >= 0.35) and (state.runtime.galaxy_paint_drag ~= true)
            local can_upgrade_full = (not state.playing and age >= 0.06) or hover_stable
            local next_full_retry_at = tonumber(state.runtime.detail_cache_next_full_retry_at) or 0
            if can_upgrade_full and now >= next_full_retry_at then
              -- Upgrade only after stop or stable hover to avoid thrash during rapid audition.
              local okf, pks_f = pcall(function() return waveform.build_peaks(pth, 384) end)
              if okf and type(pks_f) == "table" and #pks_f > 0 then
                state.runtime.detail_cache_peaks = pks_f
                state.runtime.detail_cache_peaks_quality = "full"
                state.runtime.detail_cache_next_full_retry_at = nil
              else
                state.runtime.detail_cache_next_full_retry_at = now + 0.45
              end
            end
          end
          peaks = state.runtime.detail_cache_peaks
        end
      end
      local play_ratio = get_detail_waveform_play_ratio(row)
      state.runtime.wave_screen_rect = nil
      if waveform then
        local waveform_played_col = nil
        if row and row.filename and galaxy_ops and type(galaxy_ops.infer_family_name) == "function"
          and type(galaxy_ops.galaxy_point_fill_color) == "function" then
          local fam = galaxy_ops.infer_family_name(tostring(row.filename):lower())
          waveform_played_col = galaxy_ops.galaxy_point_fill_color(fam)
        end
        local wave_rect = nil
        pcall(function() wave_rect = waveform.draw(ctx, peaks, wx, wy, ww, wh, play_ratio, waveform_played_col) end)
        state.runtime.wave_screen_rect = wave_rect
      elseif r.ImGui_ProgressBar then
        r.ImGui_ProgressBar(ctx, state.playing and 0.6 or 0.2, ww, 0)
      end

      local action_area_w = math.max(220, content_width(win_w) - 2)
      local action_gap = 6
      local slider_right_pad = 10
      local play_w = 76
      local copy_w = 96
      local rate_w = math.max(96, math.floor(action_area_w - play_w - copy_w - (action_gap * 2) - slider_right_pad))
      if r.ImGui_Button(ctx, state.playing and "Stop" or "Play", play_w, 20) then
        if state.playing then stop_preview(); set_runtime_notice("Preview stopped.") else play_selected_sample_preview() end
      end
      r.ImGui_SameLine(ctx, 0, action_gap)
      if r.ImGui_Button(ctx, "Copy item", copy_w, 20) then
        if ui_dnd and type(ui_dnd.copy_selected_sample_as_item_to_clipboard) == "function" then
          ui_dnd.copy_selected_sample_as_item_to_clipboard()
        end
      end
      r.ImGui_SameLine(ctx, 0, action_gap)
      local rm = tonumber(state.ui.rate_multiplier) or 1.0
      if rm < 0.25 then rm = 0.25 end
      if rm > 4.0 then rm = 4.0 end
      state.ui.rate_multiplier = rm
      -- If a double-click reset happened while mouse is still down, ignore slider output until mouse up.
      local lock_rate_until_mouse_up = (state.runtime and state.runtime.rate_slider_lock_until_mouse_up) == true
      if lock_rate_until_mouse_up then
        local mouse_down = false
        if r.ImGui_IsMouseDown then
          local ok_md, md = pcall(function() return r.ImGui_IsMouseDown(ctx, 0) end)
          mouse_down = ok_md and md == true
        end
        if not mouse_down then
          state.runtime.rate_slider_lock_until_mouse_up = false
          lock_rate_until_mouse_up = false
        end
      end
      if lock_rate_until_mouse_up then
        rm = 1.0
      end
      if r.ImGui_PushItemWidth and r.ImGui_PopItemWidth then
        r.ImGui_PushItemWidth(ctx, rate_w)
      end
      local slider_style_var_n = 0
      if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FramePadding then
        local ok_sv = pcall(function()
          -- Make slider height visually match the 20px Play/Copy buttons.
          r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), tonumber(C.MODERN_UI.frame_padding_x) or 8, 2)
        end)
        if ok_sv then slider_style_var_n = slider_style_var_n + 1 end
      end
      -- Piecewise "equal spacing" slider around 1.00x.
      -- 0.25, 0.33, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0 are equally spaced along the slider.
      local anchors = { 0.25, 0.33, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0 }
      local function clamp01(x)
        if x < 0 then return 0 end
        if x > 1 then return 1 end
        return x
      end
      local function rate_to_pos(rate)
        local v = tonumber(rate) or 1.0
        if v <= anchors[1] then return 0.0 end
        if v >= anchors[#anchors] then return (#anchors - 1) * 1.0 end
        for i = 1, #anchors - 1 do
          local a = anchors[i]
          local b = anchors[i + 1]
          if v >= a and v <= b then
            local t = (b ~= a) and ((v - a) / (b - a)) or 0.0
            t = clamp01(t)
            return (i - 1) + t
          end
        end
        return 4.0
      end
      local function pos_to_rate(pos)
        local p = tonumber(pos) or 4.0
        if p < 0 then p = 0 end
        local maxp = (#anchors - 1) * 1.0
        if p > maxp then p = maxp end
        local i = math.floor(p) + 1
        if i < 1 then i = 1 end
        if i >= #anchors then return anchors[#anchors] end
        local t = p - math.floor(p)
        local a = anchors[i]
        local b = anchors[i + 1]
        return a + (b - a) * t
      end

      local rm_pos = rate_to_pos(rm)
      local ch_rm, out_rm, rendered = false, rm, false
      local reset_to_one = false
      do
        local ch_pos, out_pos, pos_rendered = false, rm_pos, false
        if r.ImGui_SliderDouble then
          local ok, changed, out_v = pcall(function()
            return r.ImGui_SliderDouble(ctx, "##rate_multiplier_preview_row", rm_pos, 0.0, (#anchors - 1) * 1.0, string.format("%.2fx", rm))
          end)
          if ok and type(changed) == "boolean" and type(out_v) == "number" then
            ch_pos, out_pos, pos_rendered = changed, out_v, true
          else
            local ok2, changed2, out_v2 = pcall(function()
              return r.ImGui_SliderDouble(ctx, "##rate_multiplier_preview_row", rm_pos, 0.0, (#anchors - 1) * 1.0)
            end)
            if ok2 and type(changed2) == "boolean" and type(out_v2) == "number" then
              ch_pos, out_pos, pos_rendered = changed2, out_v2, true
            end
          end
        end
        if (not pos_rendered) and r.ImGui_DragDouble then
          local ok, changed, out_v = pcall(function()
            return r.ImGui_DragDouble(ctx, "##rate_multiplier_preview_row", rm_pos, 0.02, 0.0, (#anchors - 1) * 1.0, string.format("%.2fx", rm))
          end)
          if ok and type(changed) == "boolean" and type(out_v) == "number" then
            ch_pos, out_pos, pos_rendered = changed, out_v, true
          else
            local ok2, changed2, out_v2 = pcall(function()
              return r.ImGui_DragDouble(ctx, "##rate_multiplier_preview_row", rm_pos, 0.02, 0.0, (#anchors - 1) * 1.0)
            end)
            if ok2 and type(changed2) == "boolean" and type(out_v2) == "number" then
              ch_pos, out_pos, pos_rendered = changed2, out_v2, true
            end
          end
        end
        if pos_rendered and ch_pos then
          ch_rm, out_rm, rendered = true, pos_to_rate(out_pos), true
        else
          rendered = pos_rendered
        end
      end
      -- Double-click on slider resets to 1.00x (common UX for "rate" knobs).
      do
        local hovered = false
        if r.ImGui_IsItemHovered then
          local ok_h, hv = pcall(function() return r.ImGui_IsItemHovered(ctx) end)
          hovered = ok_h and hv == true
        end
        local active = false
        if r.ImGui_IsItemActive then
          local ok_a, av = pcall(function() return r.ImGui_IsItemActive(ctx) end)
          active = ok_a and av == true
        end
        if hovered and r.ImGui_IsMouseDoubleClicked then
          -- Use literal 0 for left mouse button (avoid enum mismatches across bindings).
          local ok_d, v = pcall(function() return r.ImGui_IsMouseDoubleClicked(ctx, 0) end)
          if ok_d and v == true then
            reset_to_one = true
          end
        elseif active and r.ImGui_IsMouseDoubleClicked then
          -- When dragging, hover may be false; allow reset while active too.
          local ok_d, v = pcall(function() return r.ImGui_IsMouseDoubleClicked(ctx, 0) end)
          if ok_d and v == true then
            reset_to_one = true
          end
        end
      end
      if r.ImGui_PushItemWidth and r.ImGui_PopItemWidth then
        r.ImGui_PopItemWidth(ctx)
      end
      if slider_style_var_n > 0 and r.ImGui_PopStyleVar then
        pcall(function() r.ImGui_PopStyleVar(ctx, slider_style_var_n) end)
      end
      if reset_to_one then
        state.ui.rate_multiplier = 1.0
        if state.runtime then
          state.runtime.rate_slider_lock_until_mouse_up = true
        end
        if state.playing and state.runtime.preview_handle and type(r.CF_Preview_SetValue) == "function" then
          if ui_preview and type(ui_preview.apply_preview_playrate) == "function" then
            ui_preview.apply_preview_playrate(state.runtime.preview_handle, state.runtime.preview_sample_bpm)
          end
        end
      elseif (not lock_rate_until_mouse_up) and rendered and ch_rm then
        local nv = tonumber(out_rm) or rm
        if nv < 0.25 then nv = 0.25 end
        if nv > 4.0 then nv = 4.0 end
        state.ui.rate_multiplier = nv
        if state.playing and state.runtime.preview_handle and type(r.CF_Preview_SetValue) == "function" then
          if ui_preview and type(ui_preview.apply_preview_playrate) == "function" then
            ui_preview.apply_preview_playrate(state.runtime.preview_handle, state.runtime.preview_sample_bpm)
          end
        end
      end
      r.ImGui_Separator(ctx)
      local tags = nil
      -- Tags: one SQLite fetch per selected row (detail_cache_* reset when sample id/path changes above).
      if row and tonumber(row.id) and state.store.available and sqlite_store and type(sqlite_store.get_tags_for_sample) == "function" then
        if type(state.runtime.detail_cache_tags) ~= "table" then
          local ok_t, list = pcall(function() return sqlite_store.get_tags_for_sample({ db = state.store.conn }, tonumber(row.id)) end)
          if ok_t and type(list) == "table" then
            state.runtime.detail_cache_tags = list
          else
            state.runtime.detail_cache_tags = {}
          end
        end
        tags = state.runtime.detail_cache_tags
      end
      if tags and #tags > 0 then
        local child_flags = window_flag_noresize() | window_flag_noscroll_with_mouse()
        if r.ImGui_WindowFlags_HorizontalScrollbar then
          child_flags = child_flags | r.ImGui_WindowFlags_HorizontalScrollbar()
        end
        local pushed_tags_scrollbar_size = false
        if r.ImGui_PushStyleVar and r.ImGui_StyleVar_ScrollbarSize then
          local ok_sv = pcall(function()
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ScrollbarSize(), C.DETAIL_TAGS_SCROLLBAR_SIZE)
          end)
          pushed_tags_scrollbar_size = ok_sv == true
        end
        local tags_child_visible = r.ImGui_BeginChild(ctx, "##detail_tags_hscroll", 0, C.DETAIL_TAGS_STRIP_H, 0, child_flags)        if tags_child_visible then
          local gap = 4
          for i, raw_tag in ipairs(tags) do
            local tag = tostring(raw_tag or "")
            if tag ~= "" then
              if i > 1 then
                r.ImGui_SameLine(ctx, 0, gap)
              end
              local display = tag_chip_label_short(tag, 24)
              if tag_ops.filter_tags_has(state.filter_tags, tag) then
                display = "*" .. display
              end
              local text_w = calc_text_w(display, 42)
              local chip_w = math.floor(math.max(TAG_CHIP_MIN_W, math.min(TAG_CHIP_MAX_W_DETAIL, text_w + 22)))
              local chip_push_var_n = 0
              local chip_push_col_n = 0
              if r.ImGui_PushStyleVar and r.ImGui_StyleVar_FrameRounding then
                local ok_sv = pcall(function()
                  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), tonumber(C.MODERN_UI.tag_chip_rounding) or 3.0)
                end)
                if ok_sv then chip_push_var_n = chip_push_var_n + 1 end
              end
              if r.ImGui_PushStyleColor and r.ImGui_Col_Text then
                local ok_sc = pcall(function()
                  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), C.MODERN_UI.color_tag_chip_text or 0xC8C9CDFF)
                end)
                if ok_sc then chip_push_col_n = chip_push_col_n + 1 end
              end
              if r.ImGui_Button(ctx, display .. "##detail_tag_h_" .. tostring(i), chip_w, 20) then
                tag_ops.filter_tags_toggle_value(tag)
              end
              if chip_push_col_n > 0 and r.ImGui_PopStyleColor then
                pcall(function() r.ImGui_PopStyleColor(ctx, chip_push_col_n) end)
              end
              if chip_push_var_n > 0 and r.ImGui_PopStyleVar then
                pcall(function() r.ImGui_PopStyleVar(ctx, chip_push_var_n) end)
              end
            end
          end
        end
        if tags_child_visible then
          local ok_end_tags, err_end_tags = pcall(function()
            r.ImGui_EndChild(ctx)
          end)
          if not ok_end_tags then          end
        else        end
        if pushed_tags_scrollbar_size and r.ImGui_PopStyleVar then
          pcall(function() r.ImGui_PopStyleVar(ctx, 1) end)
        end
      else
        r.ImGui_Text(ctx, "No tags")
      end
    end

    local function draw_settings_tab()
      local changed_auto, auto_preview = r.ImGui_Checkbox(ctx, "Auto Preview on Select", state.ui.auto_preview_on_select == true)
      if changed_auto then
        state.ui.auto_preview_on_select = auto_preview == true
      end
      local changed_match_preview, on_match_preview = r.ImGui_Checkbox(
        ctx,
        "Match preview rate to project BPM",
        state.ui.match_preview_to_project_bpm == true
      )
      if changed_match_preview then
        state.ui.match_preview_to_project_bpm = on_match_preview == true
      end
      local changed_match_insert, on_match_insert = r.ImGui_Checkbox(
        ctx,
        "Match insert rate to project BPM",
        state.ui.match_insert_to_project_bpm == true
      )
      if changed_match_insert then
        state.ui.match_insert_to_project_bpm = on_match_insert == true
      end
      r.ImGui_Separator(ctx)
      local g = tonumber(state.ui.preview_gain) or C.DEFAULT_PREVIEW_GAIN
      if g < 0 then g = 0 end
      if g > 2 then g = 2 end
      local old_g = g
      state.ui.preview_gain = g
      local g_db = preview_gain_linear_to_db(g)
      r.ImGui_Text(ctx, string.format("Preview volume: %.1f dB", g_db))
      local changed_db, out_db, slider_rendered = false, g_db, false
      if (r.ImGui_SliderDouble ~= nil) or (r.ImGui_DragDouble ~= nil) then
        if r.ImGui_PushItemWidth and r.ImGui_PopItemWidth then
          r.ImGui_PushItemWidth(ctx, -1)
        end
        changed_db, out_db, slider_rendered = ui_slider_db("##preview_gain_db", g_db, PREVIEW_GAIN_DB_MIN, PREVIEW_GAIN_DB_MAX, "%.1f dB")
        if r.ImGui_PushItemWidth and r.ImGui_PopItemWidth then
          r.ImGui_PopItemWidth(ctx)
        end
      end
      if slider_rendered then
        if changed_db then
          g = preview_gain_db_to_linear(out_db)
        end
      else
        if r.ImGui_Button(ctx, "-6 dB##preview_gain_fallback_down", 76, 20) then
          g = preview_gain_db_to_linear(g_db - 6.0)
        end
        r.ImGui_SameLine(ctx, 0, 6)
        if r.ImGui_Button(ctx, "0 dB##preview_gain_fallback_reset", 76, 20) then
          g = 1.0
        end
        r.ImGui_SameLine(ctx, 0, 6)
        if r.ImGui_Button(ctx, "+3 dB##preview_gain_fallback_up", 76, 20) then
          g = preview_gain_db_to_linear(g_db + 3.0)
        end
      end
      state.ui.preview_gain = g
      local gain_changed = math.abs(g - old_g) > 0.0001
      if state.playing and state.runtime.preview_handle and type(r.CF_Preview_SetValue) == "function" then
        if gain_changed then
          pcall(function()
            r.CF_Preview_SetValue(state.runtime.preview_handle, "D_VOLUME", tonumber(state.ui.preview_gain) or C.DEFAULT_PREVIEW_GAIN)
          end)
        end
        if changed_match_preview then
          if ui_preview and type(ui_preview.apply_preview_playrate) == "function" then
            ui_preview.apply_preview_playrate(state.runtime.preview_handle, state.runtime.preview_sample_bpm)
          end
        end
      end
    end

    do
      local detail_tab = tostring(state.ui.detail_tab or "preview")
      if detail_tab ~= "preview" and detail_tab ~= "settings" then
        detail_tab = "preview"
      end
      local function draw_mono_tab_button(label, id, selected, w, h)
        local push_n = 0
        if r.ImGui_PushStyleColor and r.ImGui_Col_Button then
          pcall(function()
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), selected and 0xF0F0F0FF or 0x00000000)
            push_n = push_n + 1
          end)
          pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), selected and 0xF0F0F0FF or (C.MODERN_UI.color_border or 0x45464DFF))
            push_n = push_n + 1
          end)
          pcall(function()
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), selected and 0xF0F0F0FF or (C.MODERN_UI.color_border or 0x45464DFF))
            push_n = push_n + 1
          end)
          pcall(function()
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), selected and 0x2A2A2AFF or (C.MODERN_UI.color_text or 0xF2F2F2FF))
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
      local clicked_preview, rect1 = draw_mono_tab_button("Preview", "##detail_preview_tab_btn", detail_tab == "preview", 96, 22)
      if clicked_preview then
        detail_tab = "preview"
      end
      local detail_tab_gap = 6
      r.ImGui_SameLine(ctx, 0, detail_tab_gap)
      local clicked_settings, rect2 = draw_mono_tab_button("Settings", "##detail_settings_tab_btn", detail_tab == "settings", 96, 22)
      if clicked_settings then
        detail_tab = "settings"
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
            local col = C.MODERN_UI.color_border or 0x45464DFF
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
      state.ui.detail_tab = detail_tab
      r.ImGui_Spacing(ctx)
      if detail_tab == "settings" then
        draw_settings_tab()
      else
        draw_preview_tab()
      end
    end

  end
  if detail_child_begun and detail_panel_visible and is_imgui_ctx_valid() then
    local ok_end_detail, err_end_detail = pcall(function() r.ImGui_EndChild(ctx) end)
    if not ok_end_detail then    end
    local ok_after_end_probe, p_w, p_h = pcall(function()
      return r.ImGui_GetWindowSize(ctx)
    end)  elseif detail_child_begun and (not detail_panel_visible) then  end
end

-- ImGui packed color 0xRRGGBBAA (same convention as waveform.lua)
local SPLIT_LINE_IDLE = 0x45464DFF
local SPLIT_LINE_HOVER = 0x6A6B72FF
local SPLIT_LINE_ACTIVE = 0x8A8B93FF

local function splitter_draw_line(col, thick)
  thick = thick or 2
  local dl = nil
  pcall(function()
    if r.ImGui_GetWindowDrawList then
      dl = r.ImGui_GetWindowDrawList(ctx)
    end
  end)
  if not dl then return end
  local x1, y1, x2, y2
  pcall(function()
    if r.ImGui_GetItemRectMin and r.ImGui_GetItemRectMax then
      x1, y1 = r.ImGui_GetItemRectMin(ctx)
      x2, y2 = r.ImGui_GetItemRectMax(ctx)
    end
  end)
  if not x1 or not y1 or not x2 or not y2 then return end
  local ym = (y1 + y2) * 0.5
  pcall(function()
    if r.ImGui_DrawList_AddLine then
      r.ImGui_DrawList_AddLine(dl, x1, ym, x2, ym, col, thick)
    elseif r.ImDrawList_AddLine then
      r.ImDrawList_AddLine(dl, x1, ym, x2, ym, col, thick)
    end
  end)
end

--- Y coordinate for splitter math: never mix ImGui vs REAPER within one drag (avoids jumps).
local function splitter_mouse_y(grab)
  if grab and grab.use_reaper_mouse and r.GetMousePosition then
    local _, my = r.GetMousePosition()
    return tonumber(my)
  end
  if r.ImGui_GetMousePos then
    -- pcall(f, ctx) preserves multiple returns from f (pcall(function() return ... end) does not).
    local ok, mx, my = pcall(r.ImGui_GetMousePos, ctx)
    if ok and type(my) == "number" then
      return my
    end
  end
  if r.GetMousePosition then
    local _, my = r.GetMousePosition()
    return tonumber(my)
  end
  return nil
end

--- Drag uses absolute reference: height = grab.start_h + (mouse_y - grab.start_my). Returns new panel height.
local function draw_panel_splitter_resolve(win_w, which, current_h, min_h, max_h)
  min_h = math.max(40, math.floor(tonumber(min_h) or 72))
  max_h = math.max(min_h + 1, math.floor(tonumber(max_h) or 400))
  current_h = math.max(min_h, math.min(max_h, math.floor(tonumber(current_h) or min_h)))
  if not is_imgui_ctx_valid() then
    return current_h
  end

  local spl_h = 8
  local w = math.max(24, content_width(win_w))
  local id = "##hsplit_" .. tostring(which)
  local item_drawn = false
  if r.ImGui_InvisibleButton then
    local ok_btn = pcall(function()
      item_drawn = r.ImGui_InvisibleButton(ctx, id, w, spl_h) ~= nil
    end)
    item_drawn = item_drawn or ok_btn
  elseif r.ImGui_Button then
    local ok_btn = pcall(function()
      item_drawn = r.ImGui_Button(ctx, " " .. id, w, spl_h) ~= nil
    end)
    item_drawn = item_drawn or ok_btn
  end
  if not item_drawn then
    return current_h
  end

  local active = false
  local hovered = false
  pcall(function()
    active = r.ImGui_IsItemActive(ctx) == true
  end)
  pcall(function()
    hovered = r.ImGui_IsItemHovered(ctx) == true
  end)

  if hovered or active then
    pcall(function()
      if r.ImGui_SetMouseCursor and r.ImGui_MouseCursor_ResizeNS then
        r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_ResizeNS())
      end
    end)
  end

  local line_col = SPLIT_LINE_IDLE
  local line_thick = 1
  if active then
    line_col = SPLIT_LINE_ACTIVE
    line_thick = 3
  elseif hovered then
    line_col = SPLIT_LINE_HOVER
    line_thick = 2
  end
  splitter_draw_line(line_col, line_thick)

  if hovered and r.ImGui_SetTooltip and not active then
    pcall(function()
      r.ImGui_SetTooltip(ctx, "Drag to resize panel height")
    end)
  end

  local g = state.runtime.split_grab

  if not active then
    if g and g.which == which then
      state.runtime.split_grab = nil
    end
    return current_h
  end

  -- First frame of drag: lock origin height and mouse Y (same coordinate source for whole drag).
  if not g or g.which ~= which then
    local use_reaper = false
    local my0 = nil
    if r.ImGui_GetMousePos then
      local ok, _, my = pcall(r.ImGui_GetMousePos, ctx)
      if ok and type(my) == "number" then
        my0 = my
      end
    end
    if my0 == nil and r.GetMousePosition then
      local _, my = r.GetMousePosition()
      my0 = tonumber(my)
      use_reaper = true
    end
    if my0 == nil then
      return current_h
    end
    state.runtime.split_grab = {
      which = which,
      start_my = my0,
      start_h = current_h,
      use_reaper_mouse = use_reaper,
    }
    return current_h
  end

  local my = splitter_mouse_y(g)
  if my == nil or type(g.start_my) ~= "number" or type(g.start_h) ~= "number" then
    return current_h
  end

  local new_h = math.floor(g.start_h + (my - g.start_my) + 0.5)
  new_h = math.max(min_h, math.min(max_h, new_h))
  return new_h
end

local function persist_ui_state(now_ts)
  if not state or not state.ui then return end
  local now = tonumber(now_ts) or ((r.time_precise and r.time_precise()) or os.time())
  local last = tonumber(state.runtime and state.runtime.ui_state_last_saved_ts)
  if last and (now - last) < 0.5 then return end
  if state.runtime then state.runtime.ui_state_last_saved_ts = now end

  set_extstate_text(XS.ui_pack_collapsed, state.ui.pack_panel_collapsed and "1" or "0", true)
  set_extstate_text(XS.ui_search_collapsed, state.ui.search_panel_collapsed and "1" or "0", true)
  if state.ui.panel_pack_h_px ~= nil then
    set_extstate_text(XS.ui_pack_h, tostring(math.floor(tonumber(state.ui.panel_pack_h_px) or 0)), true)
  end
  if state.ui.panel_search_h_px ~= nil then
    set_extstate_text(XS.ui_search_h, tostring(math.floor(tonumber(state.ui.panel_search_h_px) or 0)), true)
  end
  if state.ui.panel_list_h_px ~= nil then
    set_extstate_text(XS.ui_list_h, tostring(math.floor(tonumber(state.ui.panel_list_h_px) or 0)), true)
  end
  set_extstate_text(XS.ui_preview_gain, tostring(tonumber(state.ui.preview_gain) or C.DEFAULT_PREVIEW_GAIN), true)
  set_extstate_text("ui_rate_multiplier", tostring(tonumber(state.ui.rate_multiplier) or 1.0), true)
  set_extstate_text(
    XS.ui_match_preview_bpm,
    state.ui.match_preview_to_project_bpm and "1" or "0",
    true
  )
  set_extstate_text(
    XS.ui_match_insert_bpm,
    state.ui.match_insert_to_project_bpm and "1" or "0",
    true
  )

  do
    local dock_num = state.runtime and tonumber(state.runtime.main_window_dock_id_for_persist)
    if dock_num ~= nil then
      set_extstate_text(
        XS.ui_dock_id,
        (dock_num > 0) and tostring(math.floor(dock_num)) or "0",
        true
      )
    end
  end
end

local function draw_pack_summary_inline()
  if #state.filter_pack_ids == 0 then
    if r.ImGui_PushStyleColor and r.ImGui_Col_Text and r.ImGui_Col_TextDisabled then
      local ok = pcall(function()
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), C.MODERN_UI.color_text_disabled or 0x45464DFF)
      end)
      r.ImGui_Text(ctx, "— all")
      if ok and r.ImGui_PopStyleColor then pcall(function() r.ImGui_PopStyleColor(ctx, 1) end) end
    else
      r.ImGui_Text(ctx, "— all")
    end
  else
    if r.ImGui_SmallButton(ctx, "Clear##collapsed_pack_clear") then
      filter_pack_ids_clear()
    end
    for i, pid in ipairs(state.filter_pack_ids) do
      r.ImGui_SameLine(ctx, 0, 4)
      local nm = tostring(pack_display_name_by_id(pid) or ("#" .. tostring(pid)))
      if #nm > 20 then nm = nm:sub(1, 20) .. "..." end
      if r.ImGui_SmallButton(ctx, "x " .. nm .. "##collapsed_pack_rm_" .. tostring(i)) then
        filter_pack_ids_remove_at(i)
        break
      end
    end
  end
end

local function draw_filter_summary_inline()
  local has_any = false
  if state.favorites_only_filter then
    has_any = true
    if r.ImGui_SmallButton(ctx, "x Favorites##flt_fav_off") then
      state.favorites_only_filter = false
      state.needs_reload_samples = true
    end
  end
  if state.key_filter_enabled then
    if has_any then r.ImGui_SameLine(ctx, 0, 4) end
    has_any = true
    local key_lbl = key_root_dual_label(state.key_root or "E") or tostring(state.key_root or "E")
    if state.key_mode_minor and state.key_mode_major then
      key_lbl = key_lbl .. " (maj+min)"
    elseif state.key_mode_minor then
      key_lbl = key_lbl .. " min"
    elseif state.key_mode_major then
      key_lbl = key_lbl .. " maj"
    end
    if r.ImGui_SmallButton(ctx, "x Key:" .. key_lbl .. "##flt_key_off") then
      state.key_filter_enabled = false
      state.needs_reload_samples = true
    end
  end
  if state.bpm_filter_enabled then
    if has_any then r.ImGui_SameLine(ctx, 0, 4) end
    has_any = true
    local min_s = state.bpm_min and tostring(state.bpm_min) or "-"
    local max_s = state.bpm_max and tostring(state.bpm_max) or "-"
    if r.ImGui_SmallButton(ctx, "x BPM:" .. min_s .. "-" .. max_s .. "##flt_bpm_off") then
      state.bpm_filter_enabled = false
      state.bpm_min = nil
      state.bpm_max = nil
      state.needs_reload_samples = true
    end
  end
  if state.type_filter_enabled and (state.type_is_one_shot or state.type_is_loop) then
    if has_any then r.ImGui_SameLine(ctx, 0, 4) end
    has_any = true
    local t = (state.type_is_one_shot and "oneshot" or "") .. ((state.type_is_one_shot and state.type_is_loop) and "+" or "") .. (state.type_is_loop and "loops" or "")
    if r.ImGui_SmallButton(ctx, "x Type:" .. t .. "##flt_type_off") then
      state.type_filter_enabled = false
      state.type_is_one_shot = false
      state.type_is_loop = false
      state.needs_reload_samples = true
    end
  end
  do
    local q = tostring(state.tag_filter_input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if q ~= "" then
      if has_any then r.ImGui_SameLine(ctx, 0, 4) end
      has_any = true
      local q_disp = q
      if #q_disp > 18 then q_disp = q_disp:sub(1, 18) .. "..." end
      if r.ImGui_SmallButton(ctx, "x Search:" .. q_disp .. "##flt_text_query_off") then
        state.tag_filter_input = ""
        state.needs_reload_samples = true
      end
    end
  end
  for i, tag in ipairs(state.filter_tags or {}) do
    if has_any then r.ImGui_SameLine(ctx, 0, 4) end
    has_any = true
    local t = tostring(tag or "")
    if #t > 16 then t = t:sub(1, 16) .. "..." end
    if r.ImGui_SmallButton(ctx, "x " .. t .. "##flt_tag_rm_" .. tostring(i)) then
      tag_ops.filter_tags_remove_at(i)
      break
    end
  end
  for i, tag in ipairs(state.filter_tags_exclude or {}) do
    if has_any then r.ImGui_SameLine(ctx, 0, 4) end
    has_any = true
    local t = "- " .. tostring(tag or "")
    if #t > 16 then t = t:sub(1, 16) .. "..." end
    if r.ImGui_SmallButton(ctx, "x " .. t .. "##flt_tag_ex_rm_" .. tostring(i)) then
      tag_ops.filter_tags_exclude_remove_at(i)
      break
    end
  end
  if has_any then
    r.ImGui_SameLine(ctx, 0, 6)
    if r.ImGui_SmallButton(ctx, "Clear all##collapsed_filter_clear_all") then
      tag_ops.clear_all_search_filters()
    end
  else
    if r.ImGui_PushStyleColor and r.ImGui_Col_Text then
      local ok = pcall(function()
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), C.MODERN_UI.color_text_disabled or 0x45464DFF)
      end)
      r.ImGui_Text(ctx, "— none")
      if ok and r.ImGui_PopStyleColor then pcall(function() r.ImGui_PopStyleColor(ctx, 1) end) end
    else
      r.ImGui_Text(ctx, "— none")
    end
  end
end

local function filter_summary_has_active()
  if state.favorites_only_filter then return true end
  if state.key_filter_enabled then return true end
  if state.bpm_filter_enabled then return true end
  if state.type_filter_enabled and (state.type_is_one_shot or state.type_is_loop) then return true end
  local q = tostring(state.tag_filter_input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if q ~= "" then return true end
  if state.filter_tags and #state.filter_tags > 0 then return true end
  if state.filter_tags_exclude and #state.filter_tags_exclude > 0 then return true end
  return false
end

local function collapsed_panel_row_h()
  return math.max(18, math.floor(tonumber(C.COLLAPSED_PANEL_ROW_H) or 20))
end

local function collapsed_panel_scrollbar_h()
  return math.max(8, math.floor(tonumber(C.MODERN_UI and C.MODERN_UI.scrollbar_size) or 10))
end

local function collapsed_panel_outer_h(summary_scrollable)
  local h = collapsed_panel_row_h()
  if summary_scrollable then
    h = h + collapsed_panel_scrollbar_h()
  end
  return h
end

local function draw_collapsed_panel_row(collapsed_key, title, draw_summary_fn, summary_scrollable)
  if not is_imgui_ctx_valid() then return end
  local content_h = collapsed_panel_row_h()
  local collapsed = state.ui[collapsed_key] == true
  local icon = collapsed and ">" or "v"
  if draw_text_only_button(icon .. "##tog_" .. collapsed_key, 16, content_h) then
    state.ui[collapsed_key] = not collapsed
  end
  pcall(function() r.ImGui_SameLine(ctx, 0, 6) end)
  pcall(function() r.ImGui_Text(ctx, tostring(title or "")) end)
  if type(draw_summary_fn) ~= "function" then return end
  pcall(function() r.ImGui_SameLine(ctx, 0, 6) end)
  if summary_scrollable then
    local child_h = content_h + collapsed_panel_scrollbar_h()
    local flags = window_flag_noresize() | window_flag_noscroll_with_mouse()
    if r.ImGui_WindowFlags_HorizontalScrollbar then
      flags = flags | r.ImGui_WindowFlags_HorizontalScrollbar()
    end
    if imgui_utils then
      imgui_utils.with_child(ctx, r, "##collapsed_scroll_" .. tostring(collapsed_key), 0, child_h, 0, flags, draw_summary_fn)
    else
      draw_summary_fn()
    end
  else
    draw_summary_fn()
  end
end

draw_panel_heading_row = function(collapsed_key, title)
  if not is_imgui_ctx_valid() then return end
  local collapsed = state.ui[collapsed_key] == true
  local icon = collapsed and ">" or "v"
  if draw_text_only_button(icon .. "##tog_" .. collapsed_key, 16, 18) then
    state.ui[collapsed_key] = not collapsed
  end
  pcall(function() r.ImGui_SameLine(ctx, 0, 6) end)
  pcall(function() r.ImGui_Text(ctx, title) end)
end

local function draw_scan_progress_window()
  if not is_imgui_ctx_valid() then return end
  local runner = state and state.manage and state.manage.scan_runner or nil
  local gfr = state and state.manage and state.manage.galaxy_full_refresh or nil
  local has_scan = runner and (not runner.done)
  local has_gfr = gfr and (gfr.stage == "scanning" or gfr.stage == "repair_pending" or gfr.stage == "repair" or gfr.stage == "rebuild")
  local has_pack_scan_only = has_scan and (not has_gfr)
  if has_pack_scan_only then return end
  if not has_scan and not has_gfr then return end
  if r.ImGui_SetNextWindowSize then
    local cond = 0
    if r.ImGui_Cond_FirstUseEver then cond = r.ImGui_Cond_FirstUseEver() end
    pcall(function() r.ImGui_SetNextWindowSize(ctx, 420, 0, cond) end)
  end
  local win_flags = window_flag_noresize()
  local visible2, open2 = false, true
  local begin2_ok, begin2_visible_ret, begin2_open_ret = pcall(r.ImGui_Begin, ctx, "Scan Progress", true, win_flags)
  local begin2_has_window = begin2_ok and begin2_visible_ret ~= nil  if begin2_ok then
    visible2 = begin2_visible_ret == true
    open2 = begin2_open_ret ~= false
  end
  if begin2_has_window and visible2 then
    if has_scan then
      local label = tostring(state.manage.scan_progress_label or "Scanning...")
      r.ImGui_TextWrapped(ctx, label)
      local pct = tonumber(state.manage.scan_progress_pct) or 0
      if pct < 0 then pct = 0 end
      if pct > 100 then pct = 100 end
      if r.ImGui_ProgressBar then
        r.ImGui_ProgressBar(ctx, pct / 100.0, -1, 0, tostring(math.floor(pct + 0.5)) .. "%")
      else
        r.ImGui_Text(ctx, tostring(math.floor(pct + 0.5)) .. "%")
      end
      r.ImGui_Spacing(ctx)
      if not runner.cancel_requested then
        if r.ImGui_Button(ctx, "Cancel scan", -1, 24) then
          runner.cancel_requested = true
          state.manage.scan_progress_label = "Cancelling scan..."
          if has_gfr and gfr.stage == "scanning" then
            gfr.cancel_requested = true
          end
        end
      else
        r.ImGui_Text(ctx, "Cancelling...")
      end
    else
      local stage = tostring(gfr and gfr.stage or "")
      if stage == "repair_pending" then
        r.ImGui_TextWrapped(ctx, "Update Galaxy: ready to repair missing analysis...")
      elseif stage == "repair" then
        r.ImGui_TextWrapped(ctx, "Update Galaxy: repairing missing analysis...")
        r.ImGui_TextWrapped(ctx, "Note: this step may freeze REAPER for several seconds while audio features are recomputed.")
      elseif stage == "rebuild" then
        r.ImGui_TextWrapped(ctx, "Update Galaxy: rebuilding embedding...")
        r.ImGui_TextWrapped(ctx, "Note: UMAP rebuild may freeze REAPER for a long time on large libraries.")
      else
        r.ImGui_TextWrapped(ctx, "Update Galaxy: scanning libraries...")
      end
      if r.ImGui_ProgressBar then
        local v = stage == "rebuild" and 0.8 or (stage == "repair" and 0.6 or (stage == "repair_pending" and 0.5 or 0.2))
        r.ImGui_ProgressBar(ctx, v, -1, 0, stage)
      end
      r.ImGui_Spacing(ctx)
      if not gfr.cancel_requested then
        if r.ImGui_Button(ctx, "Cancel Update Galaxy", -1, 24) then
          gfr.cancel_requested = true
          if has_scan and runner and not runner.done then
            runner.cancel_requested = true
          end
        end
      else
        r.ImGui_Text(ctx, "Cancelling Update Galaxy...")
      end
    end
  end
  if begin2_has_window and is_imgui_ctx_valid() then
    local ok_end2, err_end2 = pcall(function() r.ImGui_End(ctx) end)
    if not ok_end2 then    end
  end
  if open2 == false then
    state.manage.scan_progress_window_open = false
  end
end

function M._draw_sample_edit_popup_window()
  if ui_edit_popup and type(ui_edit_popup.draw_sample_edit_popup_window) == "function" then
    ui_edit_popup.draw_sample_edit_popup_window()
  end
end

function M._draw_pack_bulk_tag_window()
  if ui_edit_popup and type(ui_edit_popup.draw_pack_bulk_tag_window) == "function" then
    ui_edit_popup.draw_pack_bulk_tag_window()
  end
end


local function rebind_ui_modules_for_ctx()
  setup_all_ui_modules()
end

local function loop()
  if state and state.runtime and state.runtime.ctx_recreate_requested then
    ctx = nil
    state.runtime.ctx_recreate_requested = false
    state.runtime.main_window_size_seeded = false
    state.runtime.ui_ctx_binding_sig = nil
  end
  if not ensure_reaimgui_ctx() then return end
  if r.GetExtState then
    local owner = tostring(r.GetExtState(XS.section, XS.running) or "")
    if owner ~= "" and owner ~= instance_id then
      return
    end
  end
  if r.SetExtState then
    local now = (r.time_precise and r.time_precise()) or os.time()
    r.SetExtState(XS.section, XS.running, instance_id, false)
    local last_hb = tonumber(state and state.runtime and state.runtime.heartbeat_write_last) or 0
    if (now - last_hb) >= 0.75 then
      if state and state.runtime then
        state.runtime.heartbeat_write_last = now
      end
      r.SetExtState(XS.section, XS.heartbeat, tostring(now), false)
    end
  end
  if state and state.runtime and ext_state then
    local t = (r.time_precise and r.time_precise()) or os.clock()
    local next_poll = tonumber(state.runtime.perf_ext_poll_at) or 0
    if t >= next_poll then
      state.runtime.perf_ext_poll_at = t + 2.0
      state.runtime.perf_enabled = ext_state.get_extstate_bool(r, XS.section, "ui_perf_overlay", state.runtime.perf_enabled == true)
    end
  end
  if state and state.runtime and ctx then
    local sig = tostring(ctx)
    if state.runtime.ui_ctx_binding_sig ~= sig then
      rebind_ui_modules_for_ctx()
      state.runtime.ui_ctx_binding_sig = sig
    end
  end

  -- Window flags: no collapse keeps it stable for dock usage; resizing enabled (horizontal + vertical).
  local flags = r.ImGui_WindowFlags_NoCollapse()
  -- Top-level scrollbar off: avoids double-gutter look inside dock; inner children scroll as needed.
  flags = flags
    | window_flag_noscrollbar()
    | window_flag_noscroll_with_mouse()
  local style_push_n = 0
  local color_push_n = 0
  local function push_style_var_1(var_fn, value, value_y)
    if type(r.ImGui_PushStyleVar) ~= "function" or type(var_fn) ~= "function" then return end
    local ok_var, var = pcall(var_fn)
    if not ok_var or var == nil then return end
    pcall(function()
      if value_y ~= nil then
        r.ImGui_PushStyleVar(ctx, var, value, value_y)
      else
        r.ImGui_PushStyleVar(ctx, var, value)
      end
      style_push_n = style_push_n + 1
    end)
  end
  local function push_style_color_1(col_fn, value)
    if type(r.ImGui_PushStyleColor) ~= "function" or type(col_fn) ~= "function" then return end
    local ok_col, col = pcall(col_fn)
    if not ok_col or col == nil then return end
    pcall(function()
      r.ImGui_PushStyleColor(ctx, col, value)
      color_push_n = color_push_n + 1
    end)
  end
  -- Global look tuning:
  -- - remove most panel/container rounding and borders
  -- - keep frame/button rounding visibly round
  push_style_var_1(r.ImGui_StyleVar_WindowRounding, C.STYLE_WINDOW_ROUNDING)
  push_style_var_1(r.ImGui_StyleVar_ChildRounding, C.STYLE_CHILD_ROUNDING)
  push_style_var_1(r.ImGui_StyleVar_TabRounding, C.STYLE_TAB_ROUNDING)
  push_style_var_1(r.ImGui_StyleVar_GrabRounding, C.STYLE_GRAB_ROUNDING)
  push_style_var_1(r.ImGui_StyleVar_FrameRounding, C.STYLE_FRAME_ROUNDING)
  push_style_var_1(r.ImGui_StyleVar_WindowBorderSize, C.STYLE_BORDER_SIZE)
  push_style_var_1(r.ImGui_StyleVar_ChildBorderSize, C.STYLE_BORDER_SIZE)
  push_style_var_1(r.ImGui_StyleVar_PopupBorderSize, C.STYLE_BORDER_SIZE)
  push_style_var_1(r.ImGui_StyleVar_FrameBorderSize, C.STYLE_BORDER_SIZE)
  push_style_var_1(r.ImGui_StyleVar_ItemSpacing, tonumber(C.MODERN_UI.item_spacing_x) or 8, tonumber(C.MODERN_UI.item_spacing_y) or 7)
  push_style_var_1(r.ImGui_StyleVar_FramePadding, tonumber(C.MODERN_UI.frame_padding_x) or 8, tonumber(C.MODERN_UI.frame_padding_y) or 5)
  push_style_var_1(r.ImGui_StyleVar_CellPadding, tonumber(C.MODERN_UI.cell_padding_x) or 8, tonumber(C.MODERN_UI.cell_padding_y) or 4)
  push_style_var_1(r.ImGui_StyleVar_ScrollbarSize, tonumber(C.MODERN_UI.scrollbar_size) or 10)
  push_style_var_1(r.ImGui_StyleVar_FrameBorderSize, tonumber(C.MODERN_UI.frame_border_size) or 1)
  push_style_var_1(
    r.ImGui_StyleVar_ButtonTextAlign,
    tonumber(C.MODERN_UI.button_text_align_x) or 0.5,
    tonumber(C.MODERN_UI.button_text_align_y) or 0.42
  )

  push_style_color_1(r.ImGui_Col_WindowBg, C.MODERN_UI.color_window_bg or 0x0F1115FF)
  push_style_color_1(r.ImGui_Col_ChildBg, C.MODERN_UI.color_child_bg or 0x11141AFF)
  push_style_color_1(r.ImGui_Col_PopupBg, C.MODERN_UI.color_popup_bg or 0x161A22FF)
  push_style_color_1(r.ImGui_Col_Border, C.MODERN_UI.color_border or 0x45464DFF)
  push_style_color_1(r.ImGui_Col_FrameBg, C.MODERN_UI.color_frame_bg or 0x1A2230FF)
  push_style_color_1(r.ImGui_Col_FrameBgHovered, C.MODERN_UI.color_frame_bg_hovered or 0x24344DFF)
  push_style_color_1(r.ImGui_Col_FrameBgActive, C.MODERN_UI.color_frame_bg_active or 0x2B4366FF)
  push_style_color_1(r.ImGui_Col_Button, C.MODERN_UI.color_button or 0x183357FF)
  push_style_color_1(r.ImGui_Col_ButtonHovered, C.MODERN_UI.color_button_hovered or 0x224A7AFF)
  push_style_color_1(r.ImGui_Col_ButtonActive, C.MODERN_UI.color_button_active or 0x2E5F95FF)
  push_style_color_1(r.ImGui_Col_SliderGrab, C.MODERN_UI.color_slider_grab or C.MODERN_UI.color_border or 0x45464DFF)
  push_style_color_1(r.ImGui_Col_SliderGrabActive, C.MODERN_UI.color_slider_grab_active or C.MODERN_UI.color_separator or 0x6A6B72FF)
  push_style_color_1(r.ImGui_Col_Header, C.MODERN_UI.color_header or 0x1A2B42FF)
  push_style_color_1(r.ImGui_Col_HeaderHovered, C.MODERN_UI.color_header_hovered or 0x234063FF)
  push_style_color_1(r.ImGui_Col_HeaderActive, C.MODERN_UI.color_header_active or 0x2E5686FF)
  push_style_color_1(r.ImGui_Col_Text, C.MODERN_UI.color_text or 0xE8EDF5FF)
  push_style_color_1(r.ImGui_Col_TextDisabled, C.MODERN_UI.color_text_disabled or 0x8D9AAEFF)
  push_style_color_1(r.ImGui_Col_CheckMark, C.MODERN_UI.color_check_mark or 0xFFFFFFFF)
  push_style_color_1(r.ImGui_Col_Separator, C.MODERN_UI.color_separator or 0x45464DFF)
  push_style_color_1(r.ImGui_Col_TableHeaderBg, C.MODERN_UI.color_table_header_bg or 0x141A24FF)
  push_style_color_1(r.ImGui_Col_TableBorderStrong, C.MODERN_UI.color_table_border_strong or 0x45464DFF)
  push_style_color_1(r.ImGui_Col_TableBorderLight, C.MODERN_UI.color_table_border_light or 0x45464DFF)
  push_style_color_1(r.ImGui_Col_TableRowBg, C.MODERN_UI.color_table_row_bg or 0x121721FF)
  push_style_color_1(r.ImGui_Col_TableRowBgAlt, C.MODERN_UI.color_table_row_bg_alt or 0x151C28FF)
  push_style_color_1(r.ImGui_Col_Tab, C.MODERN_UI.color_tab or C.MODERN_UI.color_button or 0x00000000)
  push_style_color_1(r.ImGui_Col_TabHovered, C.MODERN_UI.color_tab_hovered or C.MODERN_UI.color_button_hovered or 0x2E2E2EFF)
  push_style_color_1(r.ImGui_Col_TabActive, C.MODERN_UI.color_tab_active or C.MODERN_UI.color_button_active or 0xFFFFFFFF)
  push_style_color_1(r.ImGui_Col_TabUnfocused, C.MODERN_UI.color_tab_unfocused or C.MODERN_UI.color_button or 0x00000000)
  push_style_color_1(
    r.ImGui_Col_TabUnfocusedActive,
    C.MODERN_UI.color_tab_unfocused_active or C.MODERN_UI.color_frame_bg_hovered or 0x1B1B1BFF
  )
  if state and state.runtime and state.runtime.dock_restore_pending and r.ImGui_SetNextWindowDockID then
    local dock_id = tonumber(state.runtime.persisted_dock_id)
    if dock_id and dock_id > 0 then
      local cond = 0
      if r.ImGui_Cond_Always then
        local ok_cond, cond_v = pcall(function() return r.ImGui_Cond_Always() end)
        if ok_cond and cond_v then cond = cond_v end
      end
      local ok_set = pcall(function() r.ImGui_SetNextWindowDockID(ctx, dock_id, cond) end)
      if not ok_set then
        ok_set = pcall(function() r.ImGui_SetNextWindowDockID(ctx, dock_id) end)
      end
      state.runtime.dock_restore_attempts = (tonumber(state.runtime.dock_restore_attempts) or 0) + 1
      if state.runtime.dock_restore_attempts > 180 then
        state.runtime.dock_restore_pending = false
      end
    else
      state.runtime.dock_restore_pending = false
    end
  end
  -- Undocked (floating) script window: seed default size once only. Calling SetNextWindowSize every frame with
  -- cond 0 (Always) locks size and hides the resize grip; if Cond_FirstUseEver is missing/fails, use ImGui enum 4.
  do
    local def_w, def_h = 920, 720
    local min_w, min_h = 340, 220
    local max_w, max_h = 100000, 100000
    if not state.runtime.main_window_size_seeded and r.ImGui_SetNextWindowSize then
      local cond_fue = 4 -- ImGuiCond_FirstUseEver
      if type(r.ImGui_Cond_FirstUseEver) == "function" then
        local ok_c, c = pcall(function() return r.ImGui_Cond_FirstUseEver() end)
        if ok_c and type(c) == "number" then cond_fue = c end
      end
      local ok_sz = pcall(function() r.ImGui_SetNextWindowSize(ctx, def_w, def_h, cond_fue) end)
      if ok_sz then state.runtime.main_window_size_seeded = true end
    end
    if r.ImGui_SetNextWindowSizeConstraints then
      pcall(function()
        r.ImGui_SetNextWindowSizeConstraints(ctx, min_w, min_h, max_w, max_h)
      end)
    end
  end
  local function is_ctx_valid()
    return is_imgui_ctx_valid()
  end
  local function safe_separator()
    if not is_ctx_valid() then return end
    pcall(function() r.ImGui_Separator(ctx) end)
  end
  local function safe_text(text)
    if not is_ctx_valid() then return end
    pcall(function() r.ImGui_Text(ctx, tostring(text or "")) end)
  end
  local function safe_end_window(begin_has_window, label)
    if not begin_has_window then return true end
    local ok_probe_window, probe_win_w, probe_win_h = pcall(function()
      return r.ImGui_GetWindowSize(ctx)
    end)
    local ok_end, end_err = pcall(function() r.ImGui_End(ctx) end)
    if not ok_end then
      if state and state.runtime then
        state.runtime.ctx_recreate_requested = true
      end
      set_runtime_notice(tostring(label or "Window") .. " End failed: " .. tostring(end_err or "unknown"))
      return false
    end
    return true
  end

  -- Existing ReaScripts typically use this 4-arg form.
  local begin_ok, begin_visible_ret, begin_open_ret = pcall(r.ImGui_Begin, ctx, C.SCRIPT_TITLE, true, flags)
  local begin_has_window = begin_ok
  local visible = begin_has_window and begin_visible_ret == true
  local open = true
  if begin_ok then
    open = begin_open_ret ~= false
  end
  if begin_has_window and visible then
    local ok_main_draw, main_draw_err = pcall(function()
    state.runtime.perf_gate = state and state.runtime and state.runtime.perf_enabled == true
    if state.runtime.perf_gate then
      state.runtime.perf_scan_t0 = (r.time_precise and r.time_precise()) or os.clock()
    end
    if scan_controller and type(scan_controller.tick_async_rescan) == "function" then
      scan_controller.tick_async_rescan()
    end
    if state.runtime.perf_gate then
      state.runtime.perf_acc.tick_scan = (tonumber(state.runtime.perf_acc.tick_scan) or 0) + (((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(state.runtime.perf_scan_t0) or 0))
    end
    do
      local gfr = state.manage and state.manage.galaxy_full_refresh
      if gfr and gfr.stage == "scanning" then
        local scan_runner = state.manage.scan_runner
        if scan_runner and scan_runner.done and not scan_runner.cancelled then
          gfr.stage = "repair_pending"
        elseif scan_runner and scan_runner.done and scan_runner.cancelled then
          state.manage.galaxy_full_refresh = nil
        end
      end
    end
    flush_reload_pack_lists_if_needed()
    local win_w, win_h = r.ImGui_GetWindowSize(ctx)
    refresh_preview_state()

    if C.DEBUG_MINIMAL_LAYOUT then
      r.ImGui_Text(ctx, "DEBUG_MINIMAL_LAYOUT")
      safe_separator()
      r.ImGui_TextWrapped(ctx, "If blue resize line still appears now, cause is top-level host/docking behavior, not child/table layout.")
      if r.ImGui_Button(ctx, "Dummy Button", -1, 28) then end
    end

    if not C.DEBUG_MINIMAL_LAYOUT and not state.runtime.panel_split_inited then
      state.runtime.panel_split_inited = true
      local lpf = tonumber(state.ui.layout_pack_frac) or 0.20
      local lsf = tonumber(state.ui.layout_search_frac) or 0.24
      state.ui.panel_pack_h_px = math.floor(win_h * lpf)
      state.ui.panel_search_h_px = math.floor(win_h * lsf)
    end

    local pack_h = math.max(72, math.floor(tonumber(state.ui.panel_pack_h_px) or 160))
    local search_h = math.max(64, math.floor(tonumber(state.ui.panel_search_h_px) or 160))
    pack_h = math.min(pack_h, math.floor(win_h * 0.62))
    search_h = math.min(search_h, math.floor(win_h * 0.62), C.SEARCH_PANEL_MAX_H_PX)

    if not C.DEBUG_MINIMAL_LAYOUT then
    state.ui.follow_arrange_selection = false

    if not state.ui.pack_panel_collapsed then
      draw_panel_heading_row("pack_panel_collapsed", "Packs")
      if imgui_utils then
        imgui_utils.with_child(ctx, r, "##pack_section", 0, pack_h, 1, window_flag_noresize(), function()
          local ok_pack_draw, pack_draw_err = pcall(function()
            if state.runtime.perf_gate then
              state.runtime.perf_pack_t0 = (r.time_precise and r.time_precise()) or os.clock()
            end
            draw_pack_section(win_w)
            if state.runtime.perf_gate then
              state.runtime.perf_acc.draw_pack = (tonumber(state.runtime.perf_acc.draw_pack) or 0) + (((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(state.runtime.perf_pack_t0) or 0))
            end
          end)
          if not ok_pack_draw then
            set_runtime_notice("Pack section draw failed: " .. tostring(pack_draw_err or "unknown"))
          end
        end)
      end
      safe_separator()
      local max_ph = math.floor(win_h * 0.62)
      pack_h = draw_panel_splitter_resolve(win_w, "pack", pack_h, 72, max_ph)
      state.ui.panel_pack_h_px = pack_h
    else
      draw_collapsed_panel_row("pack_panel_collapsed", "Packs", draw_pack_summary_inline, #state.filter_pack_ids > 0)
      safe_separator()
    end

    if not state.ui.search_panel_collapsed then
      draw_panel_heading_row("search_panel_collapsed", "Search & filters")
      if is_ctx_valid() and imgui_utils then
        imgui_utils.with_child(ctx, r, "##search_section", 0, search_h, 1, r.ImGui_WindowFlags_NoScrollbar() | window_flag_noresize(), function()
          if state.runtime.perf_gate then
            state.runtime.perf_search_t0 = (r.time_precise and r.time_precise()) or os.clock()
          end
          draw_search_section(win_w)
          if state.runtime.perf_gate then
            state.runtime.perf_acc.draw_search = (tonumber(state.runtime.perf_acc.draw_search) or 0) + (((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(state.runtime.perf_search_t0) or 0))
          end
        end)
      end
      safe_separator()
      local max_sh = math.min(math.floor(win_h * 0.62), C.SEARCH_PANEL_MAX_H_PX)
      search_h = draw_panel_splitter_resolve(win_w, "search", search_h, 64, max_sh)
      state.ui.panel_search_h_px = search_h
    else
      draw_collapsed_panel_row("search_panel_collapsed", "Search & filters", draw_filter_summary_inline, filter_summary_has_active())
      safe_separator()
    end

    safe_text("Samples & preview")
    safe_separator()

    local rest_h = win_h
    local cy = nil
    if is_ctx_valid() then
      pcall(function()
        if r.ImGui_GetCursorPos then
          local x, y = r.ImGui_GetCursorPos(ctx)
          cy = tonumber(y)
        elseif r.ImGui_GetCursorPosY then
          cy = tonumber(r.ImGui_GetCursorPosY(ctx))
        end
      end)
    end
    if type(cy) == "number" and cy > 0 then
      rest_h = math.max(140, math.floor(win_h - cy - 10))
    else
      local hdr = 26
      local spl = 4
      local used = 0
      if not state.ui.pack_panel_collapsed then
        used = used + hdr + pack_h + spl
      else
        used = used + collapsed_panel_outer_h(#state.filter_pack_ids > 0) + spl
      end
      if not state.ui.search_panel_collapsed then
        used = used + hdr + search_h + spl
      else
        used = used + collapsed_panel_outer_h(filter_summary_has_active()) + spl
      end
      used = used + hdr + 22
      rest_h = math.max(140, win_h - used)
    end

    local required_rest_h = C.SAMPLE_SECTION_MIN_H + C.DETAIL_PANEL_MIN_H + 8
    if rest_h < required_rest_h then
      rest_h = required_rest_h
    end

    local splitter_h = 8
    local min_list_h = C.SAMPLE_SECTION_MIN_H
    local min_detail_h = C.DETAIL_PANEL_MIN_H
    local max_detail_h = math.max(min_detail_h, math.floor(rest_h - min_list_h - splitter_h))
    local preferred_detail_h = tonumber(state.ui.panel_detail_h_px)
    if not preferred_detail_h then
      local list_seed = tonumber(state.ui.panel_list_h_px)
      if list_seed then
        preferred_detail_h = rest_h - list_seed - splitter_h
      else
        preferred_detail_h = rest_h * 0.48
      end
    end
    local detail_h = math.floor(math.max(min_detail_h, math.min(max_detail_h, preferred_detail_h)))
    local list_h = math.max(min_list_h, math.floor(rest_h - detail_h - splitter_h))

    if state.runtime.perf_gate then
      state.runtime.perf_reload_t0 = (r.time_precise and r.time_precise()) or os.clock()
    end
    reload_samples_if_needed()
    if state.runtime.perf_gate then
      state.runtime.perf_acc.reload_samples = (tonumber(state.runtime.perf_acc.reload_samples) or 0)
        + (((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(state.runtime.perf_reload_t0) or 0))
      state.runtime.perf_prewarm_t0 = (r.time_precise and r.time_precise()) or os.clock()
    end
    prewarm_galaxy_points_cache_step()
    if state.runtime.perf_gate then
      state.runtime.perf_acc.prewarm_galaxy = (tonumber(state.runtime.perf_acc.prewarm_galaxy) or 0)
        + (((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(state.runtime.perf_prewarm_t0) or 0))
    end

    local ok_samples_draw, samples_draw_err = pcall(draw_samples_section, win_w, list_h)
    if not ok_samples_draw then
      set_runtime_notice("Samples section draw failed: " .. tostring(samples_draw_err or "unknown"))
    end    safe_separator()
    local max_list_h = math.max(min_list_h, math.floor(rest_h - min_detail_h - splitter_h))
    list_h = draw_panel_splitter_resolve(win_w, "listdetail", list_h, min_list_h, max_list_h)
    state.ui.panel_list_h_px = list_h
    detail_h = math.max(min_detail_h, math.floor(rest_h - list_h - splitter_h))
    state.ui.panel_detail_h_px = detail_h
    if state.runtime.perf_gate then
      state.runtime.perf_detail_t0 = (r.time_precise and r.time_precise()) or os.clock()
    end
    local ok_detail_draw, detail_draw_err = pcall(draw_detail_section, win_w, detail_h)
    if not ok_detail_draw then
      set_runtime_notice("Detail section draw failed: " .. tostring(detail_draw_err or "unknown"))
    end    if state.runtime.perf_gate then
      state.runtime.perf_acc.draw_detail = (tonumber(state.runtime.perf_acc.draw_detail) or 0) + (((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(state.runtime.perf_detail_t0) or 0))
      state.runtime.perf_acc.frames = (tonumber(state.runtime.perf_acc.frames) or 0) + 1
      state.runtime.perf_now = (r.time_precise and r.time_precise()) or os.clock()
      state.runtime.perf_last = tonumber(state.runtime.perf_last_report_at) or 0
      if (state.runtime.perf_now - state.runtime.perf_last) >= 1.0 then
        state.runtime.perf_frames = math.max(1, tonumber(state.runtime.perf_acc.frames) or 1)
        state.runtime.perf_last_report = string.format(
          "Perf(avg ms): scan=%.2f rld=%.2f pre=%.2f gfr=%.2f | pack=%.2f search=%.2f detail=%.2f",
          ((tonumber(state.runtime.perf_acc.tick_scan) or 0) * 1000.0) / state.runtime.perf_frames,
          ((tonumber(state.runtime.perf_acc.reload_samples) or 0) * 1000.0) / state.runtime.perf_frames,
          ((tonumber(state.runtime.perf_acc.prewarm_galaxy) or 0) * 1000.0) / state.runtime.perf_frames,
          ((tonumber(state.runtime.perf_acc.tick_gfr) or 0) * 1000.0) / state.runtime.perf_frames,
          ((tonumber(state.runtime.perf_acc.draw_pack) or 0) * 1000.0) / state.runtime.perf_frames,
          ((tonumber(state.runtime.perf_acc.draw_search) or 0) * 1000.0) / state.runtime.perf_frames,
          ((tonumber(state.runtime.perf_acc.draw_detail) or 0) * 1000.0) / state.runtime.perf_frames
        )
        state.runtime.perf_last_report_at = state.runtime.perf_now
        state.runtime.perf_acc.frames = 0
        state.runtime.perf_acc.tick_scan = 0
        state.runtime.perf_acc.reload_samples = 0
        state.runtime.perf_acc.prewarm_galaxy = 0
        state.runtime.perf_acc.tick_gfr = 0
        state.runtime.perf_acc.draw_pack = 0
        state.runtime.perf_acc.draw_search = 0
        state.runtime.perf_acc.draw_detail = 0
      end
    end
    if ui_dnd and type(ui_dnd.handle_waveform_mouse) == "function" then
      ui_dnd.handle_waveform_mouse()
    end
    if ui_dnd and type(ui_dnd.handle_drag_drop_insert) == "function" then
      ui_dnd.handle_drag_drop_insert()
    end
    if state.runtime.perf_gate then
      state.runtime.perf_gfr_t0 = (r.time_precise and r.time_precise()) or os.clock()
    end
    tick_galaxy_full_refresh()
    if state.runtime.perf_gate then
      state.runtime.perf_acc.tick_gfr = (tonumber(state.runtime.perf_acc.tick_gfr) or 0)
        + (((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(state.runtime.perf_gfr_t0) or 0))
    end

    if state and state.runtime and state.runtime.dock_restore_pending and r.ImGui_GetWindowDockID then
      local want = tonumber(state.runtime.persisted_dock_id)
      local ok_cur, cur = pcall(function() return r.ImGui_GetWindowDockID(ctx) end)
      local cur_id = ok_cur and tonumber(cur) or 0
      if want and want > 0 and cur_id == want then
        state.runtime.dock_restore_pending = false
      end
    end
    if state.runtime.perf_gate and state.runtime.perf_last_report ~= "" then
      safe_separator()
      safe_text(state.runtime.perf_last_report)
    end

    end -- not DEBUG_MINIMAL_LAYOUT (full layout)
    if state and state.runtime and r.ImGui_GetWindowDockID and is_ctx_valid() then
      local ok_snap, sid = pcall(function()
        return r.ImGui_GetWindowDockID(ctx)
      end)
      if ok_snap then
        local dock_id_now = tonumber(sid) or 0
        state.runtime.main_window_dock_id_prev_frame = dock_id_now
        state.runtime.main_window_dock_id_for_persist = dock_id_now
      end
    end
    end)
    if not ok_main_draw then      set_runtime_notice("Main window draw failed: " .. tostring(main_draw_err or "unknown"))
      if state and state.runtime then
        state.runtime.ctx_recreate_requested = true
      end
    end
  end
  if not is_ctx_valid() then    if state and state.runtime then
      state.runtime.ctx_recreate_requested = true
    end
    if r.defer then
      r.defer(loop)
    end
    return
  end
  safe_end_window(begin_has_window and visible, "Main window")  if style_push_n > 0 then
    local ok_pop_var, err_pop_var = pcall(function() r.ImGui_PopStyleVar(ctx, style_push_n) end)
    if not ok_pop_var then    end
  end
  if color_push_n > 0 then
    local ok_pop_col, err_pop_col = pcall(function() r.ImGui_PopStyleColor(ctx, color_push_n) end)
    if not ok_pop_col then    end
  end

  local esc_pressed = false
  if is_ctx_valid() then
    local ok_esc, esc = pcall(function()
      return r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape())
    end)
    esc_pressed = ok_esc and esc == true
  end

  if begin_has_window and visible and C.DEBUG_MINIMAL_LAYOUT then
    if open and not esc_pressed then
      r.defer(loop)
    end
    return
  end

  if is_ctx_valid() then
    draw_scan_progress_window()
    M._draw_sample_edit_popup_window()
    M._draw_pack_bulk_tag_window()
  end

  persist_ui_state((r.time_precise and r.time_precise()) or os.time())
  if open and not esc_pressed and is_ctx_valid() then
    r.defer(loop)
  end
end

local function exit()
  -- Best effort cleanup; ReaImGui doesn't require explicit destroy in most scripts.
  -- Keep it minimal to avoid shutdown issues.
  persist_ui_state((r.time_precise and r.time_precise()) or os.time())
  if r.SetExtState then
    r.SetExtState(XS.section, XS.running, "", false)
    r.SetExtState(XS.section, XS.heartbeat, "", false)
  end
  if state and state.runtime and state.runtime.preview_handle then
    stop_preview()
  end
end

function M.run()
  if not ensure_reaimgui_ctx() then return end
  -- Single-instance guard with heartbeat (prevents duplicated loops).
  if r.GetExtState and r.SetExtState then
    local already = r.GetExtState(XS.section, XS.running)
    local hb = r.GetExtState(XS.section, XS.heartbeat)
    local now = (r.time_precise and r.time_precise()) or os.time()
    local hb_ts = tonumber(hb or "")
    if already and already ~= "" and hb_ts and (now - hb_ts) < 3 then
      return
    end
    r.SetExtState(XS.section, XS.running, instance_id, false)
    r.SetExtState(XS.section, XS.heartbeat, tostring(now), false)
  end
  init_state()
  setup_all_ui_modules()

  r.atexit(exit)
  r.defer(loop)
end

return M

