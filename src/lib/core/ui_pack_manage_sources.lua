local M = {}

local r = nil
local ctx = nil
local state = nil
local sqlite_store = nil
local scan_controller = nil

local ui_input_text_with_hint = nil
local window_flag_always_vertical_scrollbar = nil
local sanitize_root_path_input = nil
local reload_pack_lists = nil
local set_persisted_splice_db_path = nil
local set_persisted_splice_relink_roots = nil

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

  ui_input_text_with_hint = ensure_fn(deps.ui_input_text_with_hint, function(id, _, v) return false, tostring(v or ""), id end)
  window_flag_always_vertical_scrollbar = ensure_fn(deps.window_flag_always_vertical_scrollbar, function() return 0 end)
  sanitize_root_path_input = ensure_fn(deps.sanitize_root_path_input, function(v) return tostring(v or "") end)
  reload_pack_lists = ensure_fn(deps.reload_pack_lists)
  set_persisted_splice_db_path = ensure_fn(deps.set_persisted_splice_db_path)
  set_persisted_splice_relink_roots = ensure_fn(deps.set_persisted_splice_relink_roots)
end

local function persist_splice_relink_roots()
  if state and state.manage and state.manage.splice_relink_roots and set_persisted_splice_relink_roots then
    set_persisted_splice_relink_roots(state.manage.splice_relink_roots)
  end
end

local function relink_roots_add_path(path_text)
  if not state or not state.manage then return end
  local p = sanitize_root_path_input(path_text)
  if p == "" then return end
  local roots = state.manage.splice_relink_roots
  if type(roots) ~= "table" then
    roots = {}
    state.manage.splice_relink_roots = roots
  end
  local pl = p:lower()
  for _, ex in ipairs(roots) do
    if tostring(ex):lower() == pl then return end
  end
  roots[#roots + 1] = p
  persist_splice_relink_roots()
end

function M.draw_modal()
  if not (r and ctx and state) then return end
  if not r.ImGui_BeginPopupModal then return end

  if r.ImGui_SetNextWindowSize then
    local cond = 0
    if r.ImGui_Cond_FirstUseEver then cond = r.ImGui_Cond_FirstUseEver() end
    pcall(function() r.ImGui_SetNextWindowSize(ctx, 720, 0, cond) end)
  end
  local opened = false
  pcall(function()
    opened = r.ImGui_BeginPopupModal(ctx, "Manage Sources##manage_sources_modal", true, 0) == true
  end)
  if opened then
    r.ImGui_TextWrapped(ctx, "Splice: import sounds.db. External folders: add root/single pack, then rescan.")

    if not state.store.available or not state.store.conn then
      r.ImGui_Text(ctx, "SQLite backend unavailable.")
      r.ImGui_Text(ctx, tostring(state.store.error or ""))
    else
      local tabbar_open = false
      if r.ImGui_BeginTabBar then
        local ok_tb, ret_tb = pcall(r.ImGui_BeginTabBar, ctx, "##manage_sources_tabbar", 0)
        tabbar_open = ok_tb and ret_tb ~= false
      end
      if tabbar_open then
        if r.ImGui_BeginTabItem(ctx, "External") then
          r.ImGui_PushItemWidth(ctx, -1)
          local root_val = tostring(state.manage.root_path_input or "")
          local changed, new_text = ui_input_text_with_hint("##manage_root_path_input", "External root path", root_val, 512)
          r.ImGui_PopItemWidth(ctx)
          if changed and new_text ~= nil then state.manage.root_path_input = tostring(new_text) end
          if r.ImGui_Button(ctx, "Paste root path", -1, 22) then
            local ok_clip, clip_text = pcall(function()
              if r.ImGui_GetClipboardText then return r.ImGui_GetClipboardText(ctx) end
              return nil
            end)
            if ok_clip and clip_text and tostring(clip_text) ~= "" then
              state.manage.root_path_input = sanitize_root_path_input(clip_text)
            else
              state.store.error = "Clipboard is empty (or unsupported)."
            end
          end
          if r.ImGui_Button(ctx, "Add External pack root", -1, 24) then
            local root_path = sanitize_root_path_input(state.manage.root_path_input)
            state.manage.root_path_input = root_path
            if root_path == "" then
              state.store.error = "Root path is empty."
            else
              local ok, err = pcall(function()
                local root_id = sqlite_store.add_root(state.store, "pack_root", "external", root_path)
                if root_id and root_id > 0 then
                  if scan_controller and type(scan_controller.begin_async_rescan_roots) == "function" then
                    scan_controller.begin_async_rescan_roots({ root_id })
                  end
                end
              end)
              if not ok then state.store.error = tostring(err) end
              state.needs_reload_samples = true
              reload_pack_lists()
            end
          end
          if r.ImGui_Button(ctx, "Add External single pack", -1, 24) then
            local root_path = sanitize_root_path_input(state.manage.root_path_input)
            state.manage.root_path_input = root_path
            if root_path == "" then
              state.store.error = "Root path is empty."
            else
              local ok, err = pcall(function()
                local root_id = sqlite_store.add_root(state.store, "single_pack", "external", root_path)
                if root_id and root_id > 0 then
                  if scan_controller and type(scan_controller.begin_async_rescan_roots) == "function" then
                    scan_controller.begin_async_rescan_roots({ root_id })
                  end
                end
              end)
              if not ok then state.store.error = tostring(err) end
              state.needs_reload_samples = true
              reload_pack_lists()
            end
          end
          r.ImGui_Spacing(ctx)
          r.ImGui_Separator(ctx)
          r.ImGui_Text(ctx, "Library")
          r.ImGui_TextWrapped(ctx, "Rescan: sync enabled roots to the database (new/changed files; usually fast).")
          if r.ImGui_Button(ctx, "Rescan All", -1, 24) then
            if scan_controller and type(scan_controller.begin_async_rescan_all) == "function" then
              scan_controller.begin_async_rescan_all()
            end
          end
          r.ImGui_Spacing(ctx)
          r.ImGui_TextWrapped(ctx, "Re-analyze: force audio feature extraction for every oneshot sample (slow; use when analysis looks wrong).")
          if r.ImGui_Button(ctx, "Re-analyze all audio (slow)", -1, 24) then
            if scan_controller and type(scan_controller.begin_async_rescan_all) == "function" then
              scan_controller.begin_async_rescan_all({ force_phase_d_all = true })
            end
          end
          if state.manage.scan_progress_pct ~= nil then
            local pct = tonumber(state.manage.scan_progress_pct) or 0
            if pct < 0 then pct = 0 end
            if pct > 100 then pct = 100 end
            r.ImGui_Text(ctx, tostring(state.manage.scan_progress_label or "Scanning..."))
            if r.ImGui_ProgressBar then
              r.ImGui_ProgressBar(ctx, pct / 100.0, -1, 0, tostring(math.floor(pct + 0.5)) .. "%")
            else
              r.ImGui_Text(ctx, tostring(math.floor(pct + 0.5)) .. "%")
            end
            local runner = state.manage.scan_runner
            if runner and not runner.done then
              if r.ImGui_Button(ctx, "Cancel scan", -1, 22) then
                runner.cancel_requested = true
                state.manage.scan_progress_label = "Cancelling scan..."
              end
            end
          end

          r.ImGui_Separator(ctx)
          r.ImGui_Text(ctx, "Configured paths")
          local root_rows = {}
          if sqlite_store and type(sqlite_store.list_roots) == "function" then
            local ok_lr, rows = pcall(function()
              return sqlite_store.list_roots({ db = state.store.conn })
            end)
            if ok_lr and type(rows) == "table" then
              root_rows = rows
            end
          end
          local list_h = math.min(180, 22 + 24 * math.max(1, #root_rows))
          if r.ImGui_BeginChild(ctx, "##configured_paths_list", 0, list_h, 1, window_flag_always_vertical_scrollbar()) then
            if #root_rows == 0 then
              r.ImGui_Text(ctx, "(none)")
            else
              for i, rr in ipairs(root_rows) do
                local rid = tonumber(rr.id)
                local path = tostring(rr.path or "")
                local src = tostring(rr.source_type or "")
                local mode = tostring(rr.mode or "")
                r.ImGui_PushID(ctx, "root_row_" .. tostring(i))
                if r.ImGui_SmallButton(ctx, "x##del_root") then
                  if sqlite_store and type(sqlite_store.delete_root) == "function" and rid and rid > 0 then
                    local ok_del, ok_ret, err_ret = pcall(function()
                      return sqlite_store.delete_root({ db = state.store.conn }, rid)
                    end)
                    if ok_del and ok_ret then
                      state.needs_reload_samples = true
                      reload_pack_lists()
                    else
                      state.store.error = tostring(err_ret or "delete root failed")
                    end
                  end
                end
                r.ImGui_SameLine(ctx, 0, 6)
                r.ImGui_TextWrapped(ctx, string.format("[%s/%s] %s", src, mode, path))
                r.ImGui_PopID(ctx)
              end
            end
            r.ImGui_EndChild(ctx)
          end
          r.ImGui_EndTabItem(ctx)
        end

        if r.ImGui_BeginTabItem(ctx, "Splice") then
          r.ImGui_PushItemWidth(ctx, -1)
          local db_changed, db_text = ui_input_text_with_hint("##splice_db_path", "Path to sounds.db...", state.manage.splice_db_path_input, 1024)
          r.ImGui_PopItemWidth(ctx)
          if db_changed then
            state.manage.splice_db_path_input = db_text
            set_persisted_splice_db_path(db_text)
          end
          if r.ImGui_Button(ctx, "Paste sounds.db path", -1, 22) then
            local ok_clip2, clip_text2 = pcall(function()
              if r.ImGui_GetClipboardText then return r.ImGui_GetClipboardText(ctx) end
              return nil
            end)
            if ok_clip2 and clip_text2 and tostring(clip_text2) ~= "" then
              state.manage.splice_db_path_input = tostring(clip_text2)
              set_persisted_splice_db_path(state.manage.splice_db_path_input)
            else
              state.store.error = "Clipboard is empty (or unsupported)."
            end
          end
          if r.ImGui_Button(ctx, "Import Splice sounds.db", -1, 24) then
            if not state.manage.splice_db_path_input or state.manage.splice_db_path_input == "" then
              state.store.error = "Splice sounds.db path is empty."
              state.manage.notice = state.store.error
            else
              local path_missing = false
              local f = io.open(state.manage.splice_db_path_input, "rb")
              if not f then
                state.store.error = "Splice sounds.db not found: " .. tostring(state.manage.splice_db_path_input)
                state.manage.notice = state.store.error
                path_missing = true
              else
                f:close()
              end
              if not path_missing then
                local ok_imp, ok2, imported_count_or_err = pcall(function()
                  return sqlite_store.import_splice_db(state.store, state.manage.splice_db_path_input)
                end)
                if ok_imp and ok2 then
                  state.store.error = "Splice import done: " .. tostring(imported_count_or_err) .. " samples"
                  state.manage.notice = state.store.error
                elseif ok_imp then
                  state.store.error = tostring(imported_count_or_err or "Splice import failed")
                  state.manage.notice = state.store.error
                else
                  state.store.error = tostring(ok2 or "Splice import failed")
                  state.manage.notice = state.store.error
                end
                reload_pack_lists()
                state.needs_reload_samples = true
              end
            end
          end

          r.ImGui_Separator(ctx)
          r.ImGui_TextWrapped(ctx, "Relocate Splice files: index audio under the folders below, match by filename to Splice samples, then update paths. Multiple folders allowed.")
          r.ImGui_PushItemWidth(ctx, -1)
          local rel_in = tostring(state.manage.splice_relink_folder_input or "")
          local rel_changed, rel_new = ui_input_text_with_hint("##splice_relink_folder_input", "Folder to search (add several if samples are scattered)...", rel_in, 1024)
          r.ImGui_PopItemWidth(ctx)
          if rel_changed and rel_new ~= nil then state.manage.splice_relink_folder_input = tostring(rel_new) end
          if r.ImGui_Button(ctx, "Add search folder", -1, 22) then
            relink_roots_add_path(state.manage.splice_relink_folder_input)
          end
          if r.ImGui_Button(ctx, "Paste search folder", -1, 22) then
            local ok_cr, clip_r = pcall(function()
              if r.ImGui_GetClipboardText then return r.ImGui_GetClipboardText(ctx) end
              return nil
            end)
            if ok_cr and clip_r and tostring(clip_r) ~= "" then
              relink_roots_add_path(clip_r)
              state.manage.splice_relink_folder_input = sanitize_root_path_input(clip_r)
            else
              state.store.error = "Clipboard is empty (or unsupported)."
            end
          end
          local rel_roots = state.manage.splice_relink_roots
          if type(rel_roots) ~= "table" then rel_roots = {} end
          r.ImGui_Text(ctx, "Search folders:")
          local rel_list_h = math.min(140, 20 + 22 * math.max(1, #rel_roots))
          if r.ImGui_BeginChild(ctx, "##splice_relink_roots_list", 0, rel_list_h, 1, window_flag_always_vertical_scrollbar()) then
            if #rel_roots == 0 then
              r.ImGui_Text(ctx, "(none)")
            else
              for ri, rp in ipairs(rel_roots) do
                r.ImGui_PushID(ctx, "splice_relink_" .. tostring(ri))
                if r.ImGui_SmallButton(ctx, "x##splice_relink_del") then
                  table.remove(rel_roots, ri)
                  persist_splice_relink_roots()
                  r.ImGui_PopID(ctx)
                  break
                end
                r.ImGui_SameLine(ctx, 0, 6)
                r.ImGui_TextWrapped(ctx, tostring(rp))
                r.ImGui_PopID(ctx)
              end
            end
            r.ImGui_EndChild(ctx)
          end
          if r.ImGui_Button(ctx, "Scan folders & update paths (Splice)", -1, 24) then
            if #rel_roots == 0 then
              state.store.error = "Add at least one search folder."
              state.manage.notice = state.store.error
            elseif sqlite_store and type(sqlite_store.relink_splice_sample_paths_by_filename) == "function" then
              local pc_ok, rel_ok, rel_info = pcall(function()
                return sqlite_store.relink_splice_sample_paths_by_filename({ db = state.store.conn }, rel_roots)
              end)
              if not pc_ok then
                state.store.error = tostring(rel_ok or "relink failed")
                state.manage.notice = state.store.error
              elseif rel_ok then
                local info_rl = rel_info
                local dup = info_rl.duplicate_names_on_disk or {}
                local dup_lines = {}
                for _, d in ipairs(dup) do
                  dup_lines[#dup_lines + 1] = string.format("%s x%d", tostring(d.filename), tonumber(d.count) or 0)
                end
                local dup_summary = #dup_lines > 0 and table.concat(dup_lines, "; ") or "(none)"
                local msg = string.format(
                  "Relocate: updated %d, unchanged %d, no match %d, no free path %d. Duplicate names on disk: %s",
                  tonumber(info_rl.updated) or 0,
                  tonumber(info_rl.unchanged) or 0,
                  tonumber(info_rl.no_match) or 0,
                  tonumber(info_rl.skipped_no_free_path) or 0,
                  dup_summary
                )
                state.store.error = msg
                state.manage.notice = msg
                state.manage.splice_relink_last_report = info_rl
                state.needs_reload_samples = true
                reload_pack_lists()
              else
                local info_rl = rel_info
                local err = type(info_rl) == "table" and info_rl.err or tostring(info_rl or "relink failed")
                state.store.error = err
                state.manage.notice = err
                state.manage.splice_relink_last_report = type(info_rl) == "table" and info_rl or { err = err }
              end
            else
              state.store.error = "Relocate is unavailable (store not ready)."
            end
          end
          local rep = state.manage.splice_relink_last_report
          if type(rep) == "table" then
            r.ImGui_Spacing(ctx)
            r.ImGui_TextWrapped(ctx, "Last result:")
            if rep.audio_files_indexed ~= nil then
              r.ImGui_Text(ctx, string.format("Audio files indexed: %s", tostring(rep.audio_files_indexed)))
            end
            if rep.splice_rows ~= nil then
              r.ImGui_Text(ctx, string.format("Splice sample rows: %s", tostring(rep.splice_rows)))
            end
            if rep.updated ~= nil then
              r.ImGui_Text(ctx, string.format("Updated: %s  Unchanged: %s  No match: %s  No free path: %s",
                tostring(rep.updated), tostring(rep.unchanged), tostring(rep.no_match), tostring(rep.skipped_no_free_path)))
            end
            local dups = rep.duplicate_names_on_disk
            if type(dups) == "table" and #dups > 0 then
              r.ImGui_Text(ctx, "Duplicate filenames on disk (arbitrary pick per row):")
              local dup_h = math.min(200, 16 + 18 * math.min(#dups, 12))
              if r.ImGui_BeginChild(ctx, "##splice_relink_dup_list", 0, dup_h, 1, window_flag_always_vertical_scrollbar()) then
                for _, d in ipairs(dups) do
                  r.ImGui_Text(ctx, string.format("  %s  x%s", tostring(d.filename), tostring(d.count)))
                end
                r.ImGui_EndChild(ctx)
              end
            end
            local ee = rep.enumerate_errors
            if type(ee) == "table" and #ee > 0 then
              r.ImGui_Text(ctx, "Folder scan errors:")
              for _, er in ipairs(ee) do
                r.ImGui_TextWrapped(ctx, string.format("%s — %s", tostring(er.root), tostring(er.err)))
              end
            end
          end

          r.ImGui_EndTabItem(ctx)
        end
        if r.ImGui_EndTabBar then r.ImGui_EndTabBar(ctx) end
      end
    end

    if state.store.error and state.store.error ~= "" then
      r.ImGui_Separator(ctx)
      r.ImGui_TextWrapped(ctx, tostring(state.store.error))
    end
    if r.ImGui_Button(ctx, "Close##manage_sources_close", -1, 24) and r.ImGui_CloseCurrentPopup then
      r.ImGui_CloseCurrentPopup(ctx)
    end
    if r.ImGui_EndPopup then
      r.ImGui_EndPopup(ctx)
    end
  end
end

return M
