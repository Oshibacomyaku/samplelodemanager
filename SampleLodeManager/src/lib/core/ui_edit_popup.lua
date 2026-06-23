-- @noindex
local M = {}

local r = nil
local ctx = nil
local state = nil
local sqlite_store = nil
local ui_input_text_with_hint = nil
local window_flag_noresize = nil
local set_runtime_notice = nil
local find_row_index_by_sample_id = nil
local make_sample_row_snapshot = nil
local parse_edit_key_parts = nil
local build_edit_key_text = nil
local KEY_ROOT_OPTIONS = {}
local is_imgui_ctx_valid = nil
local app_mod = nil

local key_bpm = nil
do
  local ok, mod = pcall(require, "lib.core.key_bpm_utils")
  if ok and type(mod) == "table" then key_bpm = mod end
end

local function ensure_fn(fn, fallback)
  if type(fn) == "function" then return fn end
  if type(fallback) == "function" then return fallback end
  return function() end
end

local function normalize_key_root_text(root_raw)
  if not key_bpm then return nil end
  return key_bpm.normalize_key_root_text(root_raw)
end

local function key_root_dual_label(root_raw)
  if not key_bpm then return nil end
  return key_bpm.key_root_dual_label(root_raw)
end

local function collect_popup_tag_groups(ids)
  if app_mod and type(app_mod._collect_popup_tag_groups) == "function" then
    return app_mod._collect_popup_tag_groups(ids)
  end
  return {}, {}, {}
end

function M.draw_sample_edit_popup_window()
  if not is_imgui_ctx_valid() then return end
  if not state or not state.runtime or state.runtime.edit_popup_open ~= true then return end
  local ids = {}
  do
    local raw_ids = state.runtime.edit_popup_ids
    if type(raw_ids) == "table" and #raw_ids > 0 then
      local seen = {}
      for _, raw in ipairs(raw_ids) do
        local n = tonumber(raw)
        if n and n > 0 and not seen[n] then
          seen[n] = true
          ids[#ids + 1] = n
        end
      end
    end
    if #ids == 0 then
      local sid0 = tonumber(state.runtime.edit_popup_sample_id)
      if sid0 and sid0 > 0 then
        ids[1] = sid0
      end
    end
  end
  local sid = tonumber(ids[1])
  if #ids == 0 or not sid or sid < 1 then
    state.runtime.edit_popup_open = false
    return
  end

  local row = nil
  local idx = find_row_index_by_sample_id(sid)
  if idx and state.rows and state.rows[idx] then
    row = state.rows[idx]
    state.runtime.edit_popup_snapshot = make_sample_row_snapshot(row)
  else
    row = state.runtime.edit_popup_snapshot
  end

  if not row then
    state.runtime.edit_popup_open = false
    return
  end

  local form_key = (#ids == 1) and ("single:" .. tostring(sid)) or ("multi:" .. tostring(sid) .. ":" .. tostring(#ids))
  if state.runtime.edit_popup_form_key ~= form_key then
    state.runtime.edit_popup_form_key = form_key
    state.runtime.edit_popup_form_sample_id = sid
    state.runtime.edit_popup_bpm_input = row.bpm and tostring(row.bpm) or ""
    local init_root, init_mode = parse_edit_key_parts(row.key_estimate)
    state.runtime.edit_popup_key_root = init_root or "C"
    state.runtime.edit_popup_key_mode = init_mode or "none"
    state.runtime.edit_popup_tag_input = ""
  end

  if r.ImGui_SetNextWindowSize then
    local cond = 0
    if r.ImGui_Cond_FirstUseEver then cond = r.ImGui_Cond_FirstUseEver() end
    pcall(function() r.ImGui_SetNextWindowSize(ctx, 420, 560, cond) end)
  end

  local visible, open = false, true
  local begin_ok, begin_ret_visible, begin_ret_open = pcall(r.ImGui_Begin, ctx, "Sample Edit", true, window_flag_noresize())
  local begin_has_window = begin_ok and begin_ret_visible ~= nil
  if begin_ok then
    visible = begin_ret_visible == true
    open = begin_ret_open ~= false
  end
  if begin_has_window and visible then
    if #ids == 1 then
      r.ImGui_TextWrapped(ctx, tostring(row.filename or ("sample #" .. tostring(sid))))
      if row.pack_name and tostring(row.pack_name) ~= "" then
        r.ImGui_Text(ctx, "Pack: " .. tostring(row.pack_name))
      end
    else
      r.ImGui_TextWrapped(ctx, tostring(#ids) .. " selected samples")
      if row and row.filename then
        r.ImGui_TextWrapped(ctx, "Anchor: " .. tostring(row.filename))
      end
    end
    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, "Target: " .. tostring(#ids) .. " sample(s)")
    r.ImGui_Separator(ctx)
    r.ImGui_Text(ctx, "BPM")

    r.ImGui_PushItemWidth(ctx, -1)
    local ch_bpm, bpm_txt = ui_input_text_with_hint("##popup_manual_bpm", "BPM", state.runtime.edit_popup_bpm_input or "", 32)
    if ch_bpm then state.runtime.edit_popup_bpm_input = bpm_txt end
    r.ImGui_PopItemWidth(ctx)
    local bpm_raw = tostring(state.runtime.edit_popup_bpm_input or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if r.ImGui_Button(ctx, "Apply BPM##popup", -1, 22) and sqlite_store and type(sqlite_store.set_manual_bpm_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.set_manual_bpm_for_samples({ db = state.store.conn }, ids, bpm_raw ~= "" and bpm_raw or nil)
      end)
      if ok and ret_ok then state.needs_reload_samples = true else set_runtime_notice("Set BPM failed: " .. tostring(ret_msg or "unknown")) end
    end
    if r.ImGui_Button(ctx, "Clear BPM value##popup", -1, 22) and sqlite_store and type(sqlite_store.set_manual_bpm_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.set_manual_bpm_for_samples({ db = state.store.conn }, ids, "__CLEAR__")
      end)
      if ok and ret_ok then
        state.runtime.edit_popup_bpm_input = ""
        state.needs_reload_samples = true
      else
        set_runtime_notice("Clear BPM failed: " .. tostring(ret_msg or "unknown"))
      end
    end
    if r.ImGui_Button(ctx, "Reset BPM to detected##popup", -1, 22) and sqlite_store and type(sqlite_store.reset_bpm_to_detected_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.reset_bpm_to_detected_for_samples({ db = state.store.conn }, ids)
      end)
      if ok and ret_ok then
        state.runtime.edit_popup_bpm_input = row.bpm and tostring(row.bpm) or ""
        state.needs_reload_samples = true
      else
        set_runtime_notice("Reset BPM failed: " .. tostring(ret_msg or "unknown"))
      end
    end

    r.ImGui_Separator(ctx)
    r.ImGui_Text(ctx, "Key")
    local mode = state.runtime.edit_popup_key_mode or "none"
    local root_sharp = normalize_key_root_text(state.runtime.edit_popup_key_root) or "C"
    local root_label = key_root_dual_label(root_sharp) or root_sharp
    if r.ImGui_Button(ctx, "Root: " .. root_label .. " v##popup_edit_key_root_btn", 150, 20) and r.ImGui_OpenPopup then
      r.ImGui_OpenPopup(ctx, "##popup_edit_key_root_popup")
    end
    if r.ImGui_BeginPopup and r.ImGui_BeginPopup(ctx, "##popup_edit_key_root_popup") then
      for _, key_root in ipairs(KEY_ROOT_OPTIONS) do
        local option_label = key_root_dual_label(key_root) or key_root
        if r.ImGui_Selectable(ctx, option_label, root_sharp == key_root) then
          state.runtime.edit_popup_key_root = key_root
        end
      end
      r.ImGui_EndPopup(ctx)
    end
    r.ImGui_SameLine(ctx, 0, 6)
    local major_on = (mode == "major")
    if r.ImGui_Button(ctx, (major_on and "?EMajor" or "?EMajor") .. "##popup_edit_key_mode_major", 88, 20) then
      state.runtime.edit_popup_key_mode = major_on and "none" or "major"
    end
    r.ImGui_SameLine(ctx, 0, 6)
    local minor_on = (mode == "minor")
    if r.ImGui_Button(ctx, (minor_on and "?EMinor" or "?EMinor") .. "##popup_edit_key_mode_minor", 88, 20) then
      state.runtime.edit_popup_key_mode = minor_on and "none" or "minor"
    end
    local key_text = build_edit_key_text(state.runtime.edit_popup_key_root, state.runtime.edit_popup_key_mode) or ""

    if r.ImGui_Button(ctx, "Apply key##popup", -1, 22) and sqlite_store and type(sqlite_store.set_manual_key_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.set_manual_key_for_samples({ db = state.store.conn }, ids, key_text ~= "" and key_text or nil)
      end)
      if ok and ret_ok then state.needs_reload_samples = true else set_runtime_notice("Set key failed: " .. tostring(ret_msg or "unknown")) end
    end
    if r.ImGui_Button(ctx, "Clear key value##popup", -1, 22) and sqlite_store and type(sqlite_store.set_manual_key_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.set_manual_key_for_samples({ db = state.store.conn }, ids, "__CLEAR__")
      end)
      if ok and ret_ok then
        state.runtime.edit_popup_key_root = "C"
        state.runtime.edit_popup_key_mode = "none"
        state.needs_reload_samples = true
      else
        set_runtime_notice("Clear key failed: " .. tostring(ret_msg or "unknown"))
      end
    end
    if r.ImGui_Button(ctx, "Reset key to detected##popup", -1, 22) and sqlite_store and type(sqlite_store.reset_key_to_detected_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.reset_key_to_detected_for_samples({ db = state.store.conn }, ids)
      end)
      if ok and ret_ok then
        local rt, md = parse_edit_key_parts(row.key_estimate)
        state.runtime.edit_popup_key_root = rt or "C"
        state.runtime.edit_popup_key_mode = md or "none"
        state.needs_reload_samples = true
      else
        set_runtime_notice("Reset key failed: " .. tostring(ret_msg or "unknown"))
      end
    end

    r.ImGui_Separator(ctx)
    r.ImGui_Text(ctx, "Tags")
    local single_tags, common_tags, mixed_tags = collect_popup_tag_groups(ids)
    local function draw_tag_list_block(title, tags)
      r.ImGui_Text(ctx, title)
      if not tags or #tags == 0 then
        r.ImGui_Text(ctx, "--")
        return
      end
      local shown = 0
      for i, tg in ipairs(tags) do
        local label = tostring(tg or "")
        if label ~= "" then
          if shown > 0 then r.ImGui_SameLine(ctx, 0, 6) end
          if r.ImGui_Button(ctx, label .. "##popup_tag_state_" .. title .. "_" .. tostring(i), 0, 20) then
            state.runtime.edit_popup_tag_input = label
          end
          shown = shown + 1
        end
      end
    end
    if #ids == 1 then
      draw_tag_list_block("Current tags", single_tags)
    else
      draw_tag_list_block("Common tags", common_tags)
      draw_tag_list_block("Not common tags", mixed_tags)
    end
    r.ImGui_Separator(ctx)
    r.ImGui_Text(ctx, "Tag edit")
    r.ImGui_PushItemWidth(ctx, -1)
    local ch_tag, tag_in = ui_input_text_with_hint("##popup_bulk_tag_input", "Tag", state.runtime.edit_popup_tag_input or "", 128)
    if ch_tag then state.runtime.edit_popup_tag_input = tag_in end
    r.ImGui_PopItemWidth(ctx)
    local tag_text = tostring(state.runtime.edit_popup_tag_input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local tag_suggestions = {}
    if state.store.available and sqlite_store and type(sqlite_store.get_tags_by_usage) == "function" then
      local ok_sug, rows = pcall(function()
        return sqlite_store.get_tags_by_usage({ db = state.store.conn }, { limit = 12, name_contains = (tag_text ~= "" and tag_text or nil) })
      end)
      if ok_sug and type(rows) == "table" then tag_suggestions = rows end
    end
    if #tag_suggestions > 0 then
      r.ImGui_Text(ctx, "Suggestions")
      local shown = 0
      for i, it in ipairs(tag_suggestions) do
        local tg = tostring((type(it) == "table" and it.tag) or "")
        if tg ~= "" then
          if shown > 0 then r.ImGui_SameLine(ctx, 0, 6) end
          local cnt = tonumber((type(it) == "table" and it.count) or 0) or 0
          local chip = (cnt > 0) and (tg .. " (" .. tostring(cnt) .. ")") or tg
          if r.ImGui_Button(ctx, chip .. "##popup_edit_tag_suggest_" .. tostring(i), 0, 20) then
            state.runtime.edit_popup_tag_input = tg
            tag_text = tg
          end
          shown = shown + 1
        end
      end
    end
    if r.ImGui_Button(ctx, "Add tag##popup", -1, 24) and tag_text ~= "" and sqlite_store and type(sqlite_store.set_manual_tag_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.set_manual_tag_for_samples({ db = state.store.conn }, ids, tag_text, true)
      end)
      if ok and ret_ok then state.needs_reload_samples = true else set_runtime_notice("Bulk add tag failed: " .. tostring(ret_msg or "unknown")) end
    end
    if r.ImGui_Button(ctx, "Remove tag##popup", -1, 24) and tag_text ~= "" and sqlite_store and type(sqlite_store.set_manual_tag_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.set_manual_tag_for_samples({ db = state.store.conn }, ids, tag_text, false)
      end)
      if ok and ret_ok then state.needs_reload_samples = true else set_runtime_notice("Bulk remove tag failed: " .. tostring(ret_msg or "unknown")) end
    end
    if r.ImGui_Button(ctx, "Reset tags to default##popup", -1, 24) and sqlite_store and type(sqlite_store.reset_tags_to_default_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.reset_tags_to_default_for_samples({ db = state.store.conn }, ids)
      end)
      if ok and ret_ok then state.needs_reload_samples = true else set_runtime_notice("Reset tags failed: " .. tostring(ret_msg or "unknown")) end
    end

    r.ImGui_Separator(ctx)
    r.ImGui_Text(ctx, "Type override")
    if r.ImGui_Button(ctx, "Set oneshot##popup", -1, 24) and sqlite_store and type(sqlite_store.set_manual_type_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.set_manual_type_for_samples({ db = state.store.conn }, ids, "oneshot")
      end)
      if ok and ret_ok then state.needs_reload_samples = true else set_runtime_notice("Set oneshot failed: " .. tostring(ret_msg or "unknown")) end
    end
    if r.ImGui_Button(ctx, "Set loop##popup", -1, 24) and sqlite_store and type(sqlite_store.set_manual_type_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.set_manual_type_for_samples({ db = state.store.conn }, ids, "loop")
      end)
      if ok and ret_ok then state.needs_reload_samples = true else set_runtime_notice("Set loop failed: " .. tostring(ret_msg or "unknown")) end
    end
    if r.ImGui_Button(ctx, "Clear type override##popup", -1, 24) and sqlite_store and type(sqlite_store.set_manual_type_for_samples) == "function" then
      local ok, ret_ok, ret_msg = pcall(function()
        return sqlite_store.set_manual_type_for_samples({ db = state.store.conn }, ids, nil)
      end)
      if ok and ret_ok then state.needs_reload_samples = true else set_runtime_notice("Clear type override failed: " .. tostring(ret_msg or "unknown")) end
    end
  end
  if begin_has_window and is_imgui_ctx_valid() then
    pcall(function() r.ImGui_End(ctx) end)
  end
  if open == false then
    state.runtime.edit_popup_open = false
    state.runtime.edit_popup_ids = nil
  end
end

function M.draw_pack_bulk_tag_window()
  if not is_imgui_ctx_valid() then return end
  if not state or not state.runtime or state.runtime.pack_bulk_tag_open ~= true then return end
  local pid = tonumber(state.runtime.pack_bulk_tag_pack_id)
  if not pid or pid < 1 then
    state.runtime.pack_bulk_tag_open = false
    return
  end

  if r.ImGui_SetNextWindowSize then
    local cond = 0
    if r.ImGui_Cond_FirstUseEver then cond = r.ImGui_Cond_FirstUseEver() end
    pcall(function() r.ImGui_SetNextWindowSize(ctx, 420, 240, cond) end)
  end
  local title = "Tag pack samples"
  local visible, open = false, true
  local begin_ok, begin_ret_visible, begin_ret_open = pcall(r.ImGui_Begin, ctx, title, true, window_flag_noresize())
  local begin_has_window = begin_ok and begin_ret_visible ~= nil
  if begin_ok then
    visible = begin_ret_visible == true
    open = begin_ret_open ~= false
  end
  if begin_has_window and visible then
    local pack_name = tostring(state.runtime.pack_bulk_tag_pack_name or ("pack #" .. tostring(pid)))
    r.ImGui_TextWrapped(ctx, pack_name)
    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, "Tag")
    r.ImGui_PushItemWidth(ctx, -1)
    local chg, txt = ui_input_text_with_hint("##pack_bulk_tag_input", "Tag", state.runtime.pack_bulk_tag_input or "", 128)
    r.ImGui_PopItemWidth(ctx)
    if chg then state.runtime.pack_bulk_tag_input = txt end
    local tag_text = tostring(state.runtime.pack_bulk_tag_input or ""):gsub("^%s+", ""):gsub("%s+$", "")

    local tag_suggestions = {}
    if state.store and state.store.available and sqlite_store and type(sqlite_store.get_tags_by_usage) == "function" then
      local ok_sug, rows = pcall(function()
        return sqlite_store.get_tags_by_usage({ db = state.store.conn }, { limit = 12, name_contains = (tag_text ~= "" and tag_text or nil) })
      end)
      if ok_sug and type(rows) == "table" then tag_suggestions = rows end
    end
    if #tag_suggestions > 0 then
      r.ImGui_Text(ctx, "Suggestions")
      local shown = 0
      for i, it in ipairs(tag_suggestions) do
        local tg = tostring((type(it) == "table" and it.tag) or "")
        if tg ~= "" then
          if shown > 0 then r.ImGui_SameLine(ctx, 0, 6) end
          local cnt = tonumber((type(it) == "table" and it.count) or 0) or 0
          local chip = (cnt > 0) and (tg .. " (" .. tostring(cnt) .. ")") or tg
          if r.ImGui_Button(ctx, chip .. "##pack_tag_suggest_" .. tostring(i), 0, 20) then
            state.runtime.pack_bulk_tag_input = tg
            tag_text = tg
          end
          shown = shown + 1
        end
      end
      r.ImGui_Separator(ctx)
    end

    local disabled = (tag_text == "") or not (state.store and state.store.available and state.store.conn)
    local pushed_disabled = false
    if disabled and r.ImGui_BeginDisabled then
      local ok_dis = pcall(function() r.ImGui_BeginDisabled(ctx, true) end)
      if not ok_dis then pcall(function() r.ImGui_BeginDisabled(ctx) end) end
      pushed_disabled = true
    end

    if r.ImGui_Button(ctx, "Add tag to pack samples", -1, 24) then
      if sqlite_store and type(sqlite_store.set_manual_tag_for_pack) == "function" then
        local ok, ret_ok, ret_msg = pcall(function()
          return sqlite_store.set_manual_tag_for_pack({ db = state.store.conn }, pid, tag_text, true)
        end)
        if ok and ret_ok then
          state.needs_reload_samples = true
          set_runtime_notice("Tag added to pack.")
        else
          set_runtime_notice("Pack tag failed: " .. tostring(ret_msg or "unknown"))
        end
      end
    end
    if r.ImGui_Button(ctx, "Remove tag from pack samples", -1, 24) then
      if sqlite_store and type(sqlite_store.set_manual_tag_for_pack) == "function" then
        local ok, ret_ok, ret_msg = pcall(function()
          return sqlite_store.set_manual_tag_for_pack({ db = state.store.conn }, pid, tag_text, false)
        end)
        if ok and ret_ok then
          state.needs_reload_samples = true
          set_runtime_notice("Tag removed from pack.")
        else
          set_runtime_notice("Pack tag failed: " .. tostring(ret_msg or "unknown"))
        end
      end
    end
    if pushed_disabled and r.ImGui_EndDisabled then pcall(function() r.ImGui_EndDisabled(ctx) end) end
  end
  if begin_has_window and is_imgui_ctx_valid() then
    pcall(function() r.ImGui_End(ctx) end)
  end
  if open == false then
    state.runtime.pack_bulk_tag_open = false
  end
end

function M.setup(deps)
  deps = type(deps) == "table" and deps or {}
  r = deps.r
  ctx = deps.ctx
  state = deps.state
  sqlite_store = deps.sqlite_store
  ui_input_text_with_hint = ensure_fn(deps.ui_input_text_with_hint, function() return false, "" end)
  window_flag_noresize = ensure_fn(deps.window_flag_noresize, function() return 0 end)
  set_runtime_notice = ensure_fn(deps.set_runtime_notice)
  find_row_index_by_sample_id = ensure_fn(deps.find_row_index_by_sample_id)
  make_sample_row_snapshot = ensure_fn(deps.make_sample_row_snapshot)
  parse_edit_key_parts = ensure_fn(deps.parse_edit_key_parts, function() return nil, "none" end)
  build_edit_key_text = ensure_fn(deps.build_edit_key_text, function() return nil end)
  KEY_ROOT_OPTIONS = type(deps.KEY_ROOT_OPTIONS) == "table" and deps.KEY_ROOT_OPTIONS or {}
  is_imgui_ctx_valid = ensure_fn(deps.is_imgui_ctx_valid, function() return false end)
  app_mod = deps.app_mod
end

return M
