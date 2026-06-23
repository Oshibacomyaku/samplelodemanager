-- @noindex
local M = {}

local r = nil
local ctx = nil
local state = nil
local set_runtime_notice = nil
local file_exists = nil
local get_selected_sample_row = nil
local set_selected_row = nil
local stop_preview = nil
local preview_seek_or_restart_from_ratio = nil
local normalize_sample_type = nil
local calc_bpm_match_playrate = nil
local is_imgui_ctx_valid = nil

local function ensure_fn(fn, fallback)
  if type(fn) == "function" then return fn end
  if type(fallback) == "function" then return fallback end
  return function() end
end

local function resolve_insert_target_track(prefer_mouse_point)
  if prefer_mouse_point and type(r.GetTrackFromPoint) == "function" and type(r.GetMousePosition) == "function" then
    local mx, my = r.GetMousePosition()
    local ok_track, track = pcall(function()
      return r.GetTrackFromPoint(mx, my)
    end)
    if ok_track and track then
      return track
    end
    return nil
  end

  if type(r.GetSelectedTrack) == "function" then
    local selected = r.GetSelectedTrack(0, 0)
    if selected then return selected end
  end
  if type(r.GetTrack) == "function" then
    local first = r.GetTrack(0, 0)
    if first then return first end
  end
  return nil
end

local function get_track_label(track)
  if not track then return "unknown track" end
  local idx = nil
  if type(r.CSurf_TrackToID) == "function" then
    idx = r.CSurf_TrackToID(track, false)
  end
  if type(idx) == "number" and idx > 0 then
    return "Track " .. tostring(idx)
  end
  return "target track"
end

local function run_insert_media_on_track(path, target_track, insert_pos_sec)
  local before_items = {}
  if target_track and type(r.CountTrackMediaItems) == "function" and type(r.GetTrackMediaItem) == "function" then
    local cnt = r.CountTrackMediaItems(target_track) or 0
    for i = 0, cnt - 1 do
      local it = r.GetTrackMediaItem(target_track, i)
      if it then
        before_items[tostring(it)] = true
      end
    end
  end
  local original_tracks = {}
  local had_edit_cursor = (type(r.GetCursorPosition) == "function") and (type(r.SetEditCurPos) == "function")
  local original_cursor = had_edit_cursor and r.GetCursorPosition() or nil
  if type(r.CountSelectedTracks) == "function" and type(r.GetSelectedTrack) == "function" then
    local count = r.CountSelectedTracks(0)
    for i = 0, count - 1 do
      original_tracks[#original_tracks + 1] = r.GetSelectedTrack(0, i)
    end
  end

  local set_ok, set_err = pcall(function()
    if type(r.SetOnlyTrackSelected) == "function" and target_track then
      r.SetOnlyTrackSelected(target_track)
    end
  end)
  if not set_ok then
    return false, set_err
  end

  if had_edit_cursor and type(insert_pos_sec) == "number" then
    pcall(function()
      r.SetEditCurPos(insert_pos_sec, false, false)
    end)
  end

  local ok_insert, insert_err = pcall(function()
    r.InsertMedia(path, 0)
  end)

  if type(r.Main_OnCommand) == "function" then
    pcall(function() r.Main_OnCommand(40297, 0) end)
  end
  if type(r.SetTrackSelected) == "function" then
    for _, tr in ipairs(original_tracks) do
      if tr then
        pcall(function() r.SetTrackSelected(tr, true) end)
      end
    end
  end
  if #original_tracks == 0 and target_track and type(r.SetTrackSelected) == "function" then
    pcall(function() r.SetTrackSelected(target_track, true) end)
  end

  if had_edit_cursor and type(original_cursor) == "number" then
    pcall(function()
      r.SetEditCurPos(original_cursor, false, false)
    end)
  end

  local inserted_items = {}
  if ok_insert and target_track and type(r.CountTrackMediaItems) == "function" and type(r.GetTrackMediaItem) == "function" then
    local cnt_after = r.CountTrackMediaItems(target_track) or 0
    for i = 0, cnt_after - 1 do
      local it = r.GetTrackMediaItem(target_track, i)
      if it and not before_items[tostring(it)] then
        inserted_items[#inserted_items + 1] = it
      end
    end
  end
  return ok_insert, insert_err, inserted_items
end

local function is_snap_enabled()
  if type(r.GetToggleCommandStateEx) == "function" then
    local ok, st = pcall(function()
      return r.GetToggleCommandStateEx(0, 1157)
    end)
    if ok then
      return tonumber(st) == 1
    end
  end
  if type(r.GetToggleCommandState) == "function" then
    local ok, st = pcall(function()
      return r.GetToggleCommandState(1157)
    end)
    if ok then
      return tonumber(st) == 1
    end
  end
  return false
end

local function resolve_drop_position_sec()
  local pos = nil
  if type(r.BR_PositionAtMouseCursor) == "function" then
    local ok, mouse_pos = pcall(function()
      return r.BR_PositionAtMouseCursor(false)
    end)
    if ok and type(mouse_pos) == "number" and mouse_pos >= 0 then
      pos = mouse_pos
    end
  end
  if type(pos) ~= "number" and type(r.GetCursorPosition) == "function" then
    pos = r.GetCursorPosition()
  end
  if type(pos) ~= "number" then
    pos = 0
  end

  if is_snap_enabled() and type(r.SnapToGrid) == "function" then
    local ok_snap, snapped = pcall(function()
      return r.SnapToGrid(0, pos)
    end)
    if ok_snap and type(snapped) == "number" and snapped >= 0 then
      pos = snapped
    end
  end
  return pos
end

local function is_drop_in_arrange_view()
  if type(r.BR_GetMouseCursorContext) == "function" then
    local ok, win = pcall(function()
      return r.BR_GetMouseCursorContext()
    end)
    if ok and type(win) == "string" and win ~= "" then
      return win == "arrange"
    end
  end
  if type(r.BR_PositionAtMouseCursor) == "function" then
    local ok, mouse_pos = pcall(function()
      return r.BR_PositionAtMouseCursor(false)
    end)
    if ok and type(mouse_pos) == "number" and mouse_pos >= 0 then
      return true
    end
  end
  return false
end

local function create_new_track_for_drop()
  if type(r.CountTracks) ~= "function" or type(r.InsertTrackAtIndex) ~= "function" or type(r.GetTrack) ~= "function" then
    return nil
  end
  local idx = r.CountTracks(0)
  local ok = pcall(function()
    r.InsertTrackAtIndex(idx, true)
  end)
  if not ok then return nil end
  return r.GetTrack(0, idx)
end

local function apply_insert_item_shaping(inserted_items, sample_bpm, sample_type)
  local normalized_type = normalize_sample_type(sample_type)
  local loopsrc_value = nil
  if normalized_type == "oneshot" then
    loopsrc_value = 0
  elseif normalized_type == "loop" then
    loopsrc_value = 1
  end

  local base_rate = 1.0
  local preserve_pitch = 0
  if state.ui.match_insert_to_project_bpm == true then
    local matched = calc_bpm_match_playrate(sample_bpm)
    if matched then
      base_rate = matched
      preserve_pitch = 1
    end
  end
  local mul = tonumber(state.ui.rate_multiplier) or 1.0
  if mul < 0.25 then mul = 0.25 end
  if mul > 4.0 then mul = 4.0 end
  if math.abs(mul - 1.0) > 0.0001 then
    preserve_pitch = 0
  end
  local rate = base_rate * mul
  if rate < 0.1 then rate = 0.1 end
  if rate > 4.0 then rate = 4.0 end

  for _, item in ipairs(inserted_items or {}) do
    local take = (type(r.GetActiveTake) == "function") and r.GetActiveTake(item) or nil
    if take and type(r.SetMediaItemTakeInfo_Value) == "function" and math.abs(rate - 1.0) > 0.0001 then
      pcall(function()
        r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate)
      end)
      pcall(function()
        r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", preserve_pitch)
      end)
      if type(r.GetMediaItemTake_Source) == "function"
        and type(r.GetMediaSourceLength) == "function"
        and type(r.SetMediaItemInfo_Value) == "function" then
        local src = r.GetMediaItemTake_Source(take)
        if src then
          local src_len = nil
          local ok_len, len = pcall(function()
            return r.GetMediaSourceLength(src)
          end)
          if ok_len and type(len) == "number" and len > 0 then
            src_len = len
          end
          if src_len and rate > 0 then
            local new_item_len = math.max(0.001, src_len / rate)
            pcall(function()
              r.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_len)
            end)
          end
        end
      end
    end
    if loopsrc_value ~= nil and type(r.SetMediaItemInfo_Value) == "function" then
      pcall(function()
        r.SetMediaItemInfo_Value(item, "B_LOOPSRC", loopsrc_value)
      end)
    end
    if type(r.UpdateItemInProject) == "function" then
      pcall(function() r.UpdateItemInProject(item) end)
    end
  end
end

function M.insert_path_at_cursor(path, display_name, forced_track, insert_pos_sec, allow_create_track, skip_fallback_track, sample_bpm, sample_type)
  if not path or path == "" then
    set_runtime_notice("Insert failed: sample path is empty.")
    return
  end
  if not file_exists(path) then
    set_runtime_notice("Insert failed: file not found.")
    return
  end
  local target_track = forced_track
  if (not target_track) and (not skip_fallback_track) then
    target_track = resolve_insert_target_track(false)
  end
  if (not target_track) and allow_create_track then
    target_track = create_new_track_for_drop()
  end
  if not target_track then
    set_runtime_notice("Insert failed: no target track found.")
    return
  end

  if type(r.Undo_BeginBlock) == "function" then
    r.Undo_BeginBlock()
  end
  local ok_insert, err, inserted_items = run_insert_media_on_track(path, target_track, insert_pos_sec)
  if type(r.Undo_EndBlock) == "function" then
    r.Undo_EndBlock("Sample Lode Manager: Insert selected sample", -1)
  end

  if not ok_insert then
    set_runtime_notice("Insert failed: " .. tostring(err))
    return
  end
  apply_insert_item_shaping(inserted_items, sample_bpm, sample_type)
  if type(r.UpdateArrange) == "function" then
    pcall(function() r.UpdateArrange() end)
  end
  local at_sec = (type(insert_pos_sec) == "number") and string.format(" @ %.3fs", insert_pos_sec) or ""
  set_runtime_notice("Inserted to " .. get_track_label(target_track) .. at_sec .. ": " .. tostring(display_name or path))
end

function M.copy_selected_sample_as_item_to_clipboard()
  local row = get_selected_sample_row()
  if not row then
    set_runtime_notice("No sample selected to copy item.")
    return
  end
  local path = row.path
  if not path or path == "" then
    set_runtime_notice("Copy failed: sample path is empty.")
    return
  end
  if not file_exists(path) then
    set_runtime_notice("Copy failed: file not found.")
    return
  end

  local target_track = nil
  if type(r.GetSelectedTrack) == "function" then
    target_track = r.GetSelectedTrack(0, 0)
  end
  if not target_track and type(r.GetTrack) == "function" then
    target_track = r.GetTrack(0, 0)
  end
  if not target_track then
    set_runtime_notice("Copy failed: no target track available.")
    return
  end

  local selected_tracks = {}
  if type(r.CountSelectedTracks) == "function" and type(r.GetSelectedTrack) == "function" then
    local nst = tonumber(r.CountSelectedTracks(0)) or 0
    for i = 0, nst - 1 do
      local tr = r.GetSelectedTrack(0, i)
      if tr then selected_tracks[#selected_tracks + 1] = tr end
    end
  end

  local selected_items = {}
  if type(r.CountSelectedMediaItems) == "function" and type(r.GetSelectedMediaItem) == "function" then
    local nsi = tonumber(r.CountSelectedMediaItems(0)) or 0
    for i = 0, nsi - 1 do
      local it = r.GetSelectedMediaItem(0, i)
      if it then selected_items[#selected_items + 1] = it end
    end
  end

  local existing_by_ptr = {}
  local pre_count = 0
  if type(r.CountTrackMediaItems) == "function" and type(r.GetTrackMediaItem) == "function" then
    pre_count = tonumber(r.CountTrackMediaItems(target_track)) or 0
    for i = 0, pre_count - 1 do
      local it = r.GetTrackMediaItem(target_track, i)
      if it then existing_by_ptr[tostring(it)] = true end
    end
  end

  if type(r.SetOnlyTrackSelected) == "function" then
    pcall(function() r.SetOnlyTrackSelected(target_track) end)
  end

  local ok_insert = pcall(function()
    r.InsertMedia(path, 0)
  end)
  if not ok_insert then
    set_runtime_notice("Copy failed: temporary insert failed.")
    return
  end

  local inserted_items = {}
  if type(r.CountTrackMediaItems) == "function" and type(r.GetTrackMediaItem) == "function" then
    local post_count = tonumber(r.CountTrackMediaItems(target_track)) or 0
    for i = 0, post_count - 1 do
      local it = r.GetTrackMediaItem(target_track, i)
      if it and not existing_by_ptr[tostring(it)] then
        inserted_items[#inserted_items + 1] = it
      end
    end
  end
  if #inserted_items == 0 then
    set_runtime_notice("Copy failed: could not detect inserted item.")
    return
  end

  apply_insert_item_shaping(inserted_items, row.bpm, row.type)

  if type(r.Main_OnCommand) == "function" then
    pcall(function() r.Main_OnCommand(40289, 0) end)
  end
  if type(r.SetMediaItemSelected) == "function" then
    for _, it in ipairs(inserted_items) do
      pcall(function() r.SetMediaItemSelected(it, true) end)
    end
  end

  local copied = false
  if type(r.Main_OnCommand) == "function" then
    local ok_copy = pcall(function() r.Main_OnCommand(40057, 0) end)
    copied = ok_copy == true
  end

  if type(r.DeleteTrackMediaItem) == "function" then
    for _, it in ipairs(inserted_items) do
      pcall(function() r.DeleteTrackMediaItem(target_track, it) end)
    end
  end

  if type(r.Main_OnCommand) == "function" then
    pcall(function() r.Main_OnCommand(40289, 0) end)
  end
  if type(r.SetMediaItemSelected) == "function" then
    for _, it in ipairs(selected_items) do
      pcall(function() r.SetMediaItemSelected(it, true) end)
    end
  end
  if type(r.SetTrackSelected) == "function" then
    if type(r.Main_OnCommand) == "function" then
      pcall(function() r.Main_OnCommand(40297, 0) end)
    end
    for _, tr in ipairs(selected_tracks) do
      pcall(function() r.SetTrackSelected(tr, true) end)
    end
  end
  if type(r.UpdateArrange) == "function" then
    pcall(function() r.UpdateArrange() end)
  end

  if copied then
    set_runtime_notice("Copied item to REAPER clipboard. Press Ctrl+V to paste.")
  else
    set_runtime_notice("Copy failed: REAPER copy command unavailable.")
  end
end

local function get_mouse_left_down()
  if type(r.JS_Mouse_GetState) ~= "function" then
    return nil
  end
  local ok, state_mask = pcall(function()
    return r.JS_Mouse_GetState(1)
  end)
  if not ok or type(state_mask) ~= "number" then
    return nil
  end
  return (state_mask & 1) == 1
end

local function point_in_wave_screen_rect(mx, my, rect)
  if not rect or type(rect.w) ~= "number" or type(rect.h) ~= "number" or rect.w < 1 or rect.h < 1 then
    return false
  end
  local x0 = tonumber(rect.x0) or 0
  local y0 = tonumber(rect.y0) or 0
  return mx >= x0 and mx <= x0 + rect.w and my >= y0 and my <= y0 + rect.h
end

local function mouse_ratio_in_wave_rect(mx, my, rect)
  local x0 = tonumber(rect.x0) or 0
  local ww = tonumber(rect.w) or 1
  return math.max(0, math.min(1, (mx - x0) / ww))
end

local function app_script_window_active_for_input()
  if not is_imgui_ctx_valid() then return false end
  local focused = false
  local hovered = false
  if r.ImGui_IsWindowFocused then
    pcall(function()
      local fl = 0
      if r.ImGui_FocusedFlags_ChildWindows then
        fl = fl | r.ImGui_FocusedFlags_ChildWindows()
      end
      if r.ImGui_FocusedFlags_DockHierarchy then
        fl = fl | r.ImGui_FocusedFlags_DockHierarchy()
      end
      if fl ~= 0 then
        focused = (r.ImGui_IsWindowFocused(ctx, fl) == true)
      else
        focused = (r.ImGui_IsWindowFocused(ctx) == true)
      end
    end)
  end
  if r.ImGui_IsWindowHovered then
    pcall(function()
      local fl = 0
      if r.ImGui_HoveredFlags_ChildWindows then
        fl = fl | r.ImGui_HoveredFlags_ChildWindows()
      end
      if r.ImGui_HoveredFlags_DockHierarchy then
        fl = fl | r.ImGui_HoveredFlags_DockHierarchy()
      end
      if fl ~= 0 then
        hovered = (r.ImGui_IsWindowHovered(ctx, fl) == true)
      else
        hovered = (r.ImGui_IsWindowHovered(ctx) == true)
      end
    end)
  end
  return focused or hovered
end

function M.handle_waveform_mouse()
  local wnd_active = app_script_window_active_for_input()
  local wf_cap = state.runtime and state.runtime.wf_capture == true
  if not (state.runtime and state.runtime.detail_preview_interactive == true) then
    state.runtime.wf_last_mouse_down = false
    state.runtime.wf_capture = false
    state.runtime.wave_scrub_ratio = nil
    return
  end
  if not (wnd_active or wf_cap) then
    state.runtime.wf_last_mouse_down = false
    state.runtime.wf_capture = false
    state.runtime.wave_scrub_ratio = nil
    return
  end
  local mouse_down = get_mouse_left_down()
  if mouse_down == nil then
    state.runtime.wf_last_mouse_down = false
    return
  end

  local R = state.runtime.wave_screen_rect
  local row = get_selected_sample_row()
  local mx, my = r.GetMousePosition()
  mx = tonumber(mx) or 0
  my = tonumber(my) or 0

  local wpath = state.runtime.wf_path
  if state.runtime.wf_capture and wpath then
    local coherent = row and row.path == wpath
    if not coherent then
      if not mouse_down then
        state.runtime.wave_scrub_ratio = nil
        state.runtime.wf_capture = false
        state.runtime.wf_path = nil
        state.runtime.wf_name = nil
      end
      state.runtime.wf_last_mouse_down = mouse_down
      return
    end

    local inside = R and point_in_wave_screen_rect(mx, my, R)

    if mouse_down then
      if inside then
        if state.runtime.dnd_drag_path == wpath then
          state.runtime.dnd_drag_path = nil
          state.runtime.dnd_drag_name = nil
          state.runtime.dnd_drag_bpm = nil
          state.runtime.dnd_drag_type = nil
          state.runtime.dnd_max_dist2 = 0
        end
        local ratio = mouse_ratio_in_wave_rect(mx, my, R)
        state.runtime.wave_scrub_ratio = ratio
      else
        state.runtime.wave_scrub_ratio = nil
        if state.runtime.dnd_drag_path ~= wpath then
          state.runtime.dnd_drag_path = wpath
          state.runtime.dnd_drag_name = state.runtime.wf_name
          state.runtime.dnd_drag_bpm = row and row.bpm or nil
          state.runtime.dnd_drag_type = row and row.type or nil
          state.runtime.dnd_start_x = state.runtime.wf_start_mx
          state.runtime.dnd_start_y = state.runtime.wf_start_my
          state.runtime.dnd_max_dist2 = 100
        end
      end
    else
      if inside then
        local ratio = mouse_ratio_in_wave_rect(mx, my, R)
        preview_seek_or_restart_from_ratio(wpath, row.filename or state.runtime.wf_name, ratio, true)
      end
      state.runtime.wave_scrub_ratio = nil
      state.runtime.wf_capture = false
      state.runtime.wf_path = nil
      state.runtime.wf_name = nil
    end
    state.runtime.wf_last_mouse_down = mouse_down
    return
  end

  if mouse_down and (not state.runtime.wf_last_mouse_down) and R and row and row.path and file_exists(row.path) then
    if point_in_wave_screen_rect(mx, my, R) then
      state.runtime.wf_capture = true
      state.runtime.wf_path = row.path
      state.runtime.wf_name = row.filename or row.path
      state.runtime.wf_start_mx = mx
      state.runtime.wf_start_my = my
      local ratio = mouse_ratio_in_wave_rect(mx, my, R)
      if state.playing then
        stop_preview(true)
      end
      state.runtime.wave_scrub_ratio = ratio
    end
  end

  state.runtime.wf_last_mouse_down = mouse_down
end

function M.begin_drag_for_row(row, row_idx)
  if not row or not row.path or row.path == "" then return end
  local mouse_down = get_mouse_left_down()
  if mouse_down == nil then return end

  local hovered = false
  pcall(function()
    hovered = r.ImGui_IsItemHovered(ctx)
  end)
  local active = false
  pcall(function()
    active = r.ImGui_IsItemActive(ctx)
  end)

  if mouse_down and (hovered or active) and ((not state.runtime.dnd_last_mouse_down) or (not state.runtime.dnd_drag_path)) then
    set_selected_row(row_idx)
    state.runtime.dnd_drag_path = row.path
    state.runtime.dnd_drag_name = row.filename or row.path
    state.runtime.dnd_drag_bpm = row.bpm
    state.runtime.dnd_drag_type = row.type
    local mx, my = r.GetMousePosition()
    state.runtime.dnd_start_x = tonumber(mx) or 0
    state.runtime.dnd_start_y = tonumber(my) or 0
    state.runtime.dnd_max_dist2 = 0
  end
end

function M.handle_drag_drop_insert()
  local wnd_active = app_script_window_active_for_input()
  if (not wnd_active) and (not state.runtime.dnd_drag_path) then
    state.runtime.dnd_last_mouse_down = false
    return
  end
  local mouse_down = get_mouse_left_down()
  if mouse_down == nil then
    if state.runtime.dnd_drag_path and not state.runtime.dnd_warned_no_js_api then
      set_runtime_notice("D&D drop detection requires js_ReaScriptAPI (JS_Mouse_GetState).")
      state.runtime.dnd_warned_no_js_api = true
    end
    return
  end

  if state.runtime.dnd_drag_path and mouse_down then
    local mx, my = r.GetMousePosition()
    local dx = (tonumber(mx) or 0) - (state.runtime.dnd_start_x or 0)
    local dy = (tonumber(my) or 0) - (state.runtime.dnd_start_y or 0)
    local dist2 = dx * dx + dy * dy
    if dist2 > (state.runtime.dnd_max_dist2 or 0) then
      state.runtime.dnd_max_dist2 = dist2
    end
  end

  if state.runtime.dnd_drag_path and state.runtime.dnd_last_mouse_down and (not mouse_down) then
    if (state.runtime.dnd_max_dist2 or 0) >= 1 then
      if is_drop_in_arrange_view() then
        local drop_track = resolve_insert_target_track(true)
        local drop_pos = resolve_drop_position_sec()
        if drop_track then
          M.insert_path_at_cursor(
            state.runtime.dnd_drag_path,
            state.runtime.dnd_drag_name,
            drop_track,
            drop_pos,
            false,
            true,
            state.runtime.dnd_drag_bpm,
            state.runtime.dnd_drag_type
          )
        else
          M.insert_path_at_cursor(
            state.runtime.dnd_drag_path,
            state.runtime.dnd_drag_name,
            nil,
            drop_pos,
            true,
            true,
            state.runtime.dnd_drag_bpm,
            state.runtime.dnd_drag_type
          )
        end
      else
        set_runtime_notice("Drop ignored: release in arrange view to insert.")
      end
    end
    state.runtime.dnd_drag_path = nil
    state.runtime.dnd_drag_name = nil
    state.runtime.dnd_drag_bpm = nil
    state.runtime.dnd_drag_type = nil
    state.runtime.dnd_max_dist2 = 0
    state.runtime.dnd_warned_no_js_api = false
  end

  state.runtime.dnd_last_mouse_down = mouse_down
end

function M.setup(deps)
  deps = type(deps) == "table" and deps or {}
  r = deps.r
  ctx = deps.ctx
  state = deps.state
  set_runtime_notice = ensure_fn(deps.set_runtime_notice)
  file_exists = ensure_fn(deps.file_exists, function() return false end)
  get_selected_sample_row = ensure_fn(deps.get_selected_sample_row)
  set_selected_row = ensure_fn(deps.set_selected_row)
  stop_preview = ensure_fn(deps.stop_preview)
  preview_seek_or_restart_from_ratio = ensure_fn(deps.preview_seek_or_restart_from_ratio)
  normalize_sample_type = ensure_fn(deps.normalize_sample_type)
  calc_bpm_match_playrate = ensure_fn(deps.calc_bpm_match_playrate, function() return nil end)
  is_imgui_ctx_valid = ensure_fn(deps.is_imgui_ctx_valid, function() return false end)
end

return M
