-- @noindex
local M = {}

local r = nil
local ctx = nil
local state = nil
local sqlite_store = nil
local scan_controller = nil
local galaxy_ops = nil

local SAMPLE_SECTION_MIN_H = 40
local GALAXY_PICK_RADIUS_PX = 11

local window_flag_noresize = nil
local window_flag_noscrollbar = nil
local window_flag_noscroll_with_mouse = nil
local content_width = nil
local set_runtime_notice = nil
local bulk_clear_all_selection = nil
local bulk_set_row_selected = nil
local set_selected_row = nil
local play_selected_sample_preview = nil

local function ensure_fn(fn, fallback)
  if type(fn) == "function" then return fn end
  if type(fallback) == "function" then return fallback end
  return function() end
end

function M.setup(deps)
  deps = type(deps) == "table" and deps or {}
  r = deps.r
  ctx = deps.ctx
  state = deps.state
  sqlite_store = deps.sqlite_store
  scan_controller = deps.scan_controller
  galaxy_ops = deps.galaxy_ops

  SAMPLE_SECTION_MIN_H = tonumber(deps.sample_section_min_h) or SAMPLE_SECTION_MIN_H
  GALAXY_PICK_RADIUS_PX = tonumber(deps.galaxy_pick_radius_px) or GALAXY_PICK_RADIUS_PX

  window_flag_noresize = ensure_fn(deps.window_flag_noresize, function() return 0 end)
  window_flag_noscrollbar = ensure_fn(deps.window_flag_noscrollbar, function() return 0 end)
  window_flag_noscroll_with_mouse = ensure_fn(deps.window_flag_noscroll_with_mouse, function() return 0 end)
  content_width = ensure_fn(deps.content_width, function(fallback) return tonumber(fallback) or 0 end)
  set_runtime_notice = ensure_fn(deps.set_runtime_notice)
  bulk_clear_all_selection = ensure_fn(deps.bulk_clear_all_selection)
  bulk_set_row_selected = ensure_fn(deps.bulk_set_row_selected)
  set_selected_row = ensure_fn(deps.set_selected_row)
  play_selected_sample_preview = ensure_fn(deps.play_selected_sample_preview)
end

function M.draw(win_w, list_h)
  if not (r and ctx and state and type(galaxy_ops) == "table") then return end
  list_h = math.max(SAMPLE_SECTION_MIN_H, math.floor(tonumber(list_h) or 120))
  local galaxy_child_flags = window_flag_noresize() | window_flag_noscrollbar() | window_flag_noscroll_with_mouse()
  if r.ImGui_BeginChild(ctx, "##sample_galaxy", 0, list_h, 1, galaxy_child_flags) then
    local zoom = tonumber(state.ui.galaxy_zoom) or 1.0
    zoom = math.max(1.0, math.min(8.0, zoom))
    state.ui.galaxy_zoom = zoom
    local cx = tonumber(state.ui.galaxy_center_x) or 0.5
    local cy = tonumber(state.ui.galaxy_center_y) or 0.5

    do
      local avail_btn = math.max(200, math.floor(content_width(win_w)))
      local adv_w = math.max(104, math.min(148, math.floor(avail_btn * 0.30)))
      local gap_btn = 8
      local up_w = math.max(120, avail_btn - adv_w - gap_btn)
      if r.ImGui_Button(ctx, "Update Galaxy", up_w, 26) then
        if state.manage.galaxy_full_refresh then
          set_runtime_notice("Update Galaxy already in progress.")
        else
          local scan_runner = state.manage.scan_runner
          if scan_runner and not scan_runner.done then
            set_runtime_notice("Wait: a library scan is already running (Manage -> Library).")
          elseif not (sqlite_store and state.store and state.store.conn) then
            set_runtime_notice("Database not ready.")
          else
            state.manage.galaxy_full_refresh = { stage = "scanning", cancel_requested = false }
            if scan_controller and type(scan_controller.begin_async_rescan_all) == "function" then
              scan_controller.begin_async_rescan_all()
            end
          end
        end
      end
      r.ImGui_SameLine(ctx, 0, gap_btn)
      local collapsed = state.ui.galaxy_advanced_collapsed == true
      local adv_label = collapsed and "> Advanced##gal_adv_btn" or "v Advanced##gal_adv_btn"
      if r.ImGui_Button(ctx, adv_label, adv_w, 26) then
        state.ui.galaxy_advanced_collapsed = not collapsed
      end
    end
    state.ui.galaxy_embed_profile = "balanced"
    if not state.ui.galaxy_advanced_collapsed then
      if r.ImGui_Button(ctx, "Rebuild embed", 110, 22) then
        if sqlite_store and state.store and state.store.conn and type(sqlite_store.set_phase_e_preset) == "function" then
          local ok_set, set_ok, set_err = pcall(function()
            return sqlite_store.set_phase_e_preset(state.ui.galaxy_embed_preset)
          end)
          if (not ok_set) or (set_ok ~= true) then
            set_runtime_notice("Set preset failed: " .. tostring(set_err or "invalid preset"))
          else
            local use_multi = type(sqlite_store.rebuild_galaxy_embedding_with_profiles) == "function"
            local ok_rb, okv, info = pcall(function()
              if use_multi then
                return sqlite_store.rebuild_galaxy_embedding_with_profiles({ db = state.store.conn }, { only_oneshot = true })
              end
              return sqlite_store.rebuild_galaxy_embedding({ db = state.store.conn }, { only_oneshot = true })
            end)
            if ok_rb and okv then
              if use_multi then
                state.ui.galaxy_embed_profile = "balanced"
              end
              state.runtime.galaxy_points_cache = nil
              state.needs_reload_samples = true
              if use_multi then
                local bi = type(info) == "table" and info.build or {}
                local profiles = type(bi) == "table" and bi.profiles or {}
                local p0 = profiles[1] or {}
                set_runtime_notice(
                  "UMAP rebuilt + cached profiles (preset=" .. tostring((bi and bi.preset) or state.ui.galaxy_embed_preset or "") ..
                  "). balanced=" .. tostring(p0.saved or 0) .. "."
                )
              else
                local n = (type(info) == "table" and tonumber(info.embedded)) or 0
                local p = (type(info) == "table" and tostring(info.preset or "")) or tostring(state.ui.galaxy_embed_preset or "")
                set_runtime_notice("Galaxy embedding rebuilt (" .. tostring(n) .. " rows, preset=" .. p .. ").")
              end
            else
              set_runtime_notice("Rebuild embed failed: " .. tostring(info or set_err or "unknown"))
            end
          end
        end
      end
      r.ImGui_SameLine(ctx, 0, 6)
      if r.ImGui_Button(ctx, "Repair missing", 110, 22) then
        if sqlite_store and state.store and state.store.conn and type(sqlite_store.reanalyze_missing_audio_features) == "function" then
          local ok_rm, okv, info = pcall(function()
            return sqlite_store.reanalyze_missing_audio_features({ db = state.store.conn }, { only_oneshot = true })
          end)
          if ok_rm and okv then
            state.runtime.galaxy_points_cache = nil
            state.needs_reload_samples = true
            local target = (type(info) == "table" and tonumber(info.target)) or 0
            local analyzed = (type(info) == "table" and tonumber(info.analyzed)) or 0
            local embedded = (type(info) == "table" and tonumber(info.embedded)) or 0
            local updated = (type(info) == "table" and tonumber(info.updated)) or 0
            local dropped = (type(info) == "table" and tonumber(info.dropped_low_valid)) or 0
            local dropped_nn = (type(info) == "table" and tonumber(info.dropped_near_neutral)) or 0
            set_runtime_notice(
              "Missing-feature repair done (target=" .. tostring(target) ..
              ", analyzed=" .. tostring(analyzed) ..
              ", embedded=" .. tostring(embedded) ..
              ", updated=" .. tostring(updated) ..
              ", dropped_low_valid=" .. tostring(dropped) ..
              ", dropped_near_neutral=" .. tostring(dropped_nn) .. ")."
            )
          else
            set_runtime_notice("Repair missing failed: " .. tostring(info or "unknown"))
          end
        else
          set_runtime_notice("Repair missing not available.")
        end
      end
      r.ImGui_SameLine(ctx, 0, 6)
      if r.ImGui_Button(ctx, "Fill missing embed", 128, 22) then
        if sqlite_store and state.store and state.store.conn and type(sqlite_store.fill_missing_galaxy_embedding) == "function" then
          local ok_set, set_ok, set_err = pcall(function()
            return sqlite_store.set_phase_e_preset(state.ui.galaxy_embed_preset)
          end)
          if (not ok_set) or (set_ok ~= true) then
            set_runtime_notice("Set preset failed: " .. tostring(set_err or "invalid preset"))
          else
            local ok_fm, okv, info = pcall(function()
              return sqlite_store.fill_missing_galaxy_embedding({ db = state.store.conn }, { only_oneshot = true, relax = true })
            end)
            if ok_fm and okv then
              state.runtime.galaxy_points_cache = nil
              state.needs_reload_samples = true
              local miss = (type(info) == "table" and tonumber(info.missing_before)) or 0
              local filled = (type(info) == "table" and tonumber(info.filled)) or 0
              local still = (type(info) == "table" and tonumber(info.still_missing_embed)) or 0
              local mode = (type(info) == "table" and tostring(info.mode or "")) or ""
              local msg = "Fill missing embed done (had_null=" .. tostring(miss) .. ", filled=" .. tostring(filled) .. ", still_null=" .. tostring(still) .. ", mode=" .. mode .. ")."
              local ex_l = (type(info) == "table" and tostring(info.excluded_low_valid_sample_ids or "")) or ""
              local ex_n = (type(info) == "table" and tostring(info.excluded_near_neutral_sample_ids or "")) or ""
              if ex_l ~= "" then msg = msg .. "\nExcluded (low-valid) sample_ids: " .. ex_l end
              if ex_n ~= "" then msg = msg .. "\nExcluded (near-neutral) sample_ids: " .. ex_n end
              set_runtime_notice(msg)
            else
              set_runtime_notice("Fill missing embed failed: " .. tostring(info or set_err or "unknown"))
            end
          end
        else
          set_runtime_notice("Fill missing embed not available.")
        end
      end
    end

    state.ui.galaxy_show_unmapped = true
    zoom = tonumber(state.ui.galaxy_zoom) or 1.0
    local half = 0.5 / zoom
    cx, cy = galaxy_ops.clamp_galaxy_center(state.ui.galaxy_center_x, state.ui.galaxy_center_y, half)
    state.ui.galaxy_center_x = cx
    state.ui.galaxy_center_y = cy

    local x_min = cx - half
    local x_max = cx + half
    local y_min = cy - half
    local y_max = cy + half

    r.ImGui_Spacing(ctx)
    local cw = math.max(180, math.floor(content_width(win_w) - 2))
    local ch = math.max(120, math.floor(list_h - 40))
    local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
    if r.ImGui_InvisibleButton then
      r.ImGui_InvisibleButton(ctx, "##galaxy_canvas", cw, ch)
    else
      r.ImGui_Button(ctx, "##galaxy_canvas", cw, ch)
    end
    local canvas_hovered = false
    pcall(function() canvas_hovered = r.ImGui_IsItemHovered(ctx) == true end)
    local mx, my = nil, nil
    if canvas_hovered and r.ImGui_GetMousePos then
      local okm, mx0, my0 = pcall(r.ImGui_GetMousePos, ctx)
      if okm then mx, my = mx0, my0 end
    end

    if canvas_hovered and r.ImGui_GetMouseWheel then
      local okw, wheel = pcall(r.ImGui_GetMouseWheel, ctx)
      wheel = okw and tonumber(wheel) or 0
      if wheel and math.abs(wheel) > 1e-6 then
        local old_zoom = zoom
        local factor = (wheel > 0) and 1.18 or (1.0 / 1.18)
        local new_zoom = math.max(1.0, math.min(8.0, old_zoom * factor))
        if math.abs(new_zoom - old_zoom) > 1e-9 and mx and my then
          local rx = math.max(0.0, math.min(1.0, (mx - x0) / math.max(1.0, cw)))
          local ry = math.max(0.0, math.min(1.0, (my - y0) / math.max(1.0, ch)))
          local old_half = 0.5 / old_zoom
          local new_half = 0.5 / new_zoom
          local wx = (cx - old_half) + (rx * (old_half * 2.0))
          local wy = (cy - old_half) + (ry * (old_half * 2.0))
          local nx = wx - (rx * (new_half * 2.0)) + new_half
          local ny = wy - (ry * (new_half * 2.0)) + new_half
          state.ui.galaxy_zoom = new_zoom
          state.ui.galaxy_center_x = nx
          state.ui.galaxy_center_y = ny
          zoom = new_zoom
          half = new_half
          cx, cy = galaxy_ops.clamp_galaxy_center(state.ui.galaxy_center_x, state.ui.galaxy_center_y, half)
          state.ui.galaxy_center_x = cx
          state.ui.galaxy_center_y = cy
          x_min = cx - half
          x_max = cx + half
          y_min = cy - half
          y_max = cy + half
        end
      end
    end

    local middle_down = false
    if r.ImGui_IsMouseDown then
      local okd, v = pcall(r.ImGui_IsMouseDown, ctx, 2)
      middle_down = okd and v == true
    end
    if canvas_hovered and middle_down and mx and my then
      if not state.runtime.galaxy_pan_active then
        state.runtime.galaxy_pan_active = true
        state.runtime.galaxy_pan_last_mx = mx
        state.runtime.galaxy_pan_last_my = my
      else
        local lx = tonumber(state.runtime.galaxy_pan_last_mx) or mx
        local ly = tonumber(state.runtime.galaxy_pan_last_my) or my
        local dx = mx - lx
        local dy = my - ly
        local span_x = math.max(1e-9, x_max - x_min)
        local span_y = math.max(1e-9, y_max - y_min)
        state.ui.galaxy_center_x = (tonumber(state.ui.galaxy_center_x) or 0.5) - (dx / math.max(1.0, cw)) * span_x
        state.ui.galaxy_center_y = (tonumber(state.ui.galaxy_center_y) or 0.5) - (dy / math.max(1.0, ch)) * span_y
        state.runtime.galaxy_pan_last_mx = mx
        state.runtime.galaxy_pan_last_my = my
      end
    else
      state.runtime.galaxy_pan_active = false
      state.runtime.galaxy_pan_last_mx = nil
      state.runtime.galaxy_pan_last_my = nil
    end

    cx = tonumber(state.ui.galaxy_center_x) or cx
    cy = tonumber(state.ui.galaxy_center_y) or cy
    cx, cy = galaxy_ops.clamp_galaxy_center(cx, cy, half)
    state.ui.galaxy_center_x = cx
    state.ui.galaxy_center_y = cy
    x_min = cx - half
    x_max = cx + half
    y_min = cy - half
    y_max = cy + half

    zoom = tonumber(state.ui.galaxy_zoom) or 1.0
    local dot_zoom_mul = 1.0 + 0.2 * math.max(0, zoom - 1.0)

    local dl = galaxy_ops.get_window_draw_list_safe()
    if dl then
      galaxy_ops.drawlist_add_rect_filled(dl, x0, y0, x0 + cw, y0 + ch, 0x121214FF)
      galaxy_ops.galaxy_trail_prune_and_draw(dl, {
        x0 = x0,
        y0 = y0,
        cw = cw,
        ch = ch,
        x_min = x_min,
        x_max = x_max,
        y_min = y_min,
        y_max = y_max,
      })
      for i = 1, 4 do
        local gx = x0 + (cw * i / 5)
        local gy = y0 + (ch * i / 5)
        galaxy_ops.drawlist_add_line(dl, gx, y0, gx, y0 + ch, 0x2C2C3255, 1)
        galaxy_ops.drawlist_add_line(dl, x0, gy, x0 + cw, gy, 0x2C2C3255, 1)
      end
      galaxy_ops.drawlist_add_line(dl, x0, y0 + ch - 1, x0 + cw, y0 + ch - 1, 0x3A3A4088, 1)
    end

    local points, oneshot_total, audio_feature_rows, embed_rows, building_cache = galaxy_ops.get_cached_galaxy_points(220)
    local visible = 0
    local nearest_idx = nil
    local nearest_d2 = 1e12
    local hovered = canvas_hovered

    local density = {}
    local max_bin_count = 1
    for _, p in ipairs(points) do
      if p.x >= x_min and p.x <= x_max and p.y >= y_min and p.y <= y_max then
        visible = visible + 1
        local sx_f = x0 + ((p.x - x_min) / (x_max - x_min)) * cw
        local sy_f = y0 + ((p.y - y_min) / (y_max - y_min)) * ch
        local sx = math.floor(sx_f + 0.5)
        local sy = math.floor(sy_f + 0.5)
        local k = tostring(sx) .. ":" .. tostring(sy)
        local bin = density[k]
        if not bin then
          bin = { x = sx, y = sy, count = 0, selected = false, items = {} }
          density[k] = bin
        end
        bin.count = bin.count + 1
        bin.items[#bin.items + 1] = {
          row_idx = p.row_idx,
          sample_id = p.sample_id,
          family = p.family,
          selected = (state.selected_row == p.row_idx),
          scr_x = sx_f,
          scr_y = sy_f,
        }
        if bin.count > max_bin_count then max_bin_count = bin.count end
      end
    end

    for _, bin in pairs(density) do
      if bin.count > 1 then
        table.sort(bin.items, function(a, b)
          return (tonumber(a.sample_id) or 0) < (tonumber(b.sample_id) or 0)
        end)
        local spread = math.min(14.0, 2.0 + math.sqrt(bin.count) * 2.2)
        for j, item in ipairs(bin.items) do
          local h = galaxy_ops.hash01_from_int(item.sample_id)
          local angle = (j * 2.399963229728653) + (h * 6.283185307179586)
          local rr = spread * math.sqrt(j / (bin.count + 1))
          item.scr_x = bin.x + math.cos(angle) * rr
          item.scr_y = bin.y + math.sin(angle) * rr
        end
      end
    end

    local pick_r2 = GALAXY_PICK_RADIUS_PX * GALAXY_PICK_RADIUS_PX
    for _, bin in pairs(density) do
      for _, item in ipairs(bin.items) do
        if mx and my and item.scr_x and item.scr_y then
          local dx = mx - item.scr_x
          local dy = my - item.scr_y
          local d2 = dx * dx + dy * dy
          if d2 < nearest_d2 then
            nearest_d2 = d2
            nearest_idx = item.row_idx
          end
        end
      end
    end

    local visible_bins = 0
    if dl then
      for _, bin in pairs(density) do
        visible_bins = visible_bins + 1
        local ratio = bin.count / max_bin_count
        if bin.count == 1 then
          local item = bin.items[1]
          local sel = item and item.selected == true
          local base_r = (0.85 + (ratio * 1.35)) * dot_zoom_mul
          local px = item.scr_x or bin.x
          local py = item.scr_y or bin.y
          galaxy_ops.draw_galaxy_scatter_dot(dl, px, py, base_r, item and item.family or "other", sel, dot_zoom_mul)
        else
          for j, item in ipairs(bin.items) do
            local dot_ratio = (j / bin.count)
            local base_r = (0.75 + (dot_ratio * 1.05)) * dot_zoom_mul
            local sx = item.scr_x or bin.x
            local sy = item.scr_y or bin.y
            galaxy_ops.draw_galaxy_scatter_dot(dl, sx, sy, base_r, item.family or "other", item.selected == true, dot_zoom_mul)
          end
        end
      end
    end

    local left_clicked = false
    local left_down = false
    local left_released = false
    pcall(function()
      left_clicked = r.ImGui_IsMouseClicked(ctx, 0) == true
      left_down = r.ImGui_IsMouseDown(ctx, 0) == true
      left_released = r.ImGui_IsMouseReleased(ctx, 0) == true
    end)

    if left_released then
      state.runtime.galaxy_paint_drag = false
      state.runtime.galaxy_paint_last_row = nil
    end

    if not middle_down then
      if hovered and left_clicked and nearest_idx and nearest_d2 <= pick_r2 then
        state.runtime.galaxy_trail_segments = {}
        bulk_clear_all_selection()
        bulk_set_row_selected(nearest_idx, true)
        state.runtime.selection_anchor_row_idx = nearest_idx
        set_selected_row(nearest_idx, state.ui.auto_preview_on_select == true)
        state.runtime.galaxy_paint_drag = true
        state.runtime.galaxy_paint_last_row = nearest_idx
        local pmx, pmy = galaxy_ops.galaxy_map_xy_for_row_idx(nearest_idx)
        state.runtime.galaxy_paint_last_mx = pmx
        state.runtime.galaxy_paint_last_my = pmy
        if state.ui.auto_preview_on_select then
          play_selected_sample_preview()
        end
      elseif hovered and left_down and state.runtime.galaxy_paint_drag and nearest_idx and nearest_d2 <= pick_r2 then
        if nearest_idx ~= state.runtime.galaxy_paint_last_row then
          local ax_m = tonumber(state.runtime.galaxy_paint_last_mx)
          local ay_m = tonumber(state.runtime.galaxy_paint_last_my)
          local bx_m, by_m = galaxy_ops.galaxy_map_xy_for_row_idx(nearest_idx)
          if ax_m and ay_m and bx_m and by_m then
            if not state.runtime.galaxy_trail_segments then
              state.runtime.galaxy_trail_segments = {}
            end
            table.insert(state.runtime.galaxy_trail_segments, {
              ax_m = ax_m,
              ay_m = ay_m,
              bx_m = bx_m,
              by_m = by_m,
              t0 = galaxy_ops.galaxy_now_s(),
            })
          end
          bulk_clear_all_selection()
          bulk_set_row_selected(nearest_idx, true)
          set_selected_row(nearest_idx, state.ui.auto_preview_on_select == true)
          state.runtime.selection_anchor_row_idx = nearest_idx
          state.runtime.galaxy_paint_last_row = nearest_idx
          state.runtime.galaxy_paint_last_mx = bx_m
          state.runtime.galaxy_paint_last_my = by_m
          if state.ui.auto_preview_on_select then
            play_selected_sample_preview()
          end
        end
      end
    end

    local no_embed_n = math.max(0, oneshot_total - embed_rows)
    local status = building_cache and " / building cache..." or ""
    r.ImGui_Text(ctx, string.format(
      "Galaxy view: oneshot %d / plotted %d / no_embed %d / feat rows %d / embedded %d / visible %d / dots %d%s",
      oneshot_total, #points, no_embed_n, audio_feature_rows, embed_rows, visible, visible_bins, status
    ))
    r.ImGui_EndChild(ctx)
  end
end

return M
