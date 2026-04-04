local M = {}

local r = nil
local state = nil
local sqlite_store = nil
local reload_pack_lists = nil
local set_runtime_notice = nil
local async_scan_step_budget = 8

local function ensure_fn(fn)
  if type(fn) == "function" then return fn end
  return function() end
end

function M.setup(deps)
  deps = type(deps) == "table" and deps or {}
  r = deps.r
  state = deps.state
  sqlite_store = deps.sqlite_store
  reload_pack_lists = ensure_fn(deps.reload_pack_lists)
  set_runtime_notice = ensure_fn(deps.set_runtime_notice)
  async_scan_step_budget = tonumber(deps.async_scan_step_budget) or 8
end

function M.begin_async_rescan_roots(root_ids, scan_opts)
  if not (state and state.store and state.store.available and state.store.conn and sqlite_store) then
    return false
  end
  scan_opts = type(scan_opts) == "table" and scan_opts or {}
  local current = state.manage and state.manage.scan_runner or nil
  if current and not current.done then
    set_runtime_notice("A scan is already running. Cancel it first.")
    return false
  end
  local ids = {}
  local seen = {}
  for _, raw in ipairs(root_ids or {}) do
    local rid = tonumber(raw)
    if rid and rid > 0 and not seen[rid] then
      seen[rid] = true
      ids[#ids + 1] = rid
    end
  end
  state.manage.scan_runner = {
    root_ids = ids,
    root_idx = 1,
    total_roots = #ids,
    job = nil,
    done = (#ids == 0),
    cancelled = false,
    cancel_requested = false,
    force_phase_d_all = scan_opts.force_phase_d_all == true,
    step_budget = async_scan_step_budget,
  }
  state.manage.scan_progress_pct = 0
  if #ids == 0 then
    state.manage.scan_progress_label = "No roots to scan."
  elseif scan_opts.force_phase_d_all then
    state.manage.scan_progress_label = "Preparing forced audio re-analyze (oneshot)..."
  else
    state.manage.scan_progress_label = "Preparing scan..."
  end
  state.manage.scan_progress_window_open = true
  return true
end

function M.begin_async_rescan_all(scan_opts)
  if not (state and state.store and state.store.available and state.store.conn and sqlite_store) then return end
  scan_opts = type(scan_opts) == "table" and scan_opts or {}
  local roots = sqlite_store.list_roots(state.store)
  local root_ids = {}
  for _, rt in ipairs(roots or {}) do
    local rid = tonumber(rt.id)
    local src = tostring(rt.source_type or "")
    local include = true
    if src == "splice" and scan_opts.force_phase_d_all ~= true then
      include = false
    end
    if rid and rid > 0 and include then
      root_ids[#root_ids + 1] = rid
    end
  end
  M.begin_async_rescan_roots(root_ids, scan_opts)
end

function M.tick_async_rescan()
  local runner = state and state.manage and state.manage.scan_runner or nil
  if not runner or runner.done then return end
  if not sqlite_store then return end

  if runner.cancel_requested then
    runner.cancelled = true
    runner.done = true
    runner.job = nil
    state.manage.scan_progress_label = "Scan cancelled."
    if state.manage.scan_progress_pct == nil then
      state.manage.scan_progress_pct = 0
    end
    reload_pack_lists()
    state.needs_reload_samples = true
    local gfr = state.manage and state.manage.galaxy_full_refresh or nil
    if gfr and gfr.stage == "scanning" then
      state.manage.galaxy_full_refresh = nil
      set_runtime_notice("Update Galaxy cancelled.")
    end
    return
  end

  if not runner.job then
    local rid = runner.root_ids[runner.root_idx]
    if not rid then
      runner.done = true
      state.manage.scan_progress_pct = 100
      state.manage.scan_progress_label = "Scan complete (100%)"
      reload_pack_lists()
      state.needs_reload_samples = true
      return
    end
    local r_opts = runner.force_phase_d_all and { force_phase_d_all = true } or nil
    local job, err = sqlite_store.begin_rescan_root(state.store, rid, r_opts)
    if not job then
      state.store.error = tostring(err or "begin_rescan_root failed")
      runner.root_idx = runner.root_idx + 1
      return
    end
    runner.job = job
  end

  runner.step_budget = tonumber(runner.step_budget) or async_scan_step_budget
  if runner.step_budget < 1 then runner.step_budget = 1 end
  if runner.step_budget > 8 then runner.step_budget = 8 end
  runner.step_t0 = (r.time_precise and r.time_precise()) or os.clock()
  local done, err, p = sqlite_store.step_rescan_job(runner.job, runner.step_budget)
  runner.step_elapsed = ((r.time_precise and r.time_precise()) or os.clock()) - (tonumber(runner.step_t0) or 0)
  if runner.step_elapsed > (0.004 * 1.25) then
    runner.step_budget = math.max(1, runner.step_budget - 1)
  elseif runner.step_elapsed < (0.004 * 0.5) then
    runner.step_budget = math.min(8, runner.step_budget + 1)
  end
  if err then
    state.store.error = tostring(err or "step_rescan_job failed")
    runner.root_idx = runner.root_idx + 1
    runner.job = nil
    return
  end
  if p then
    local local_ratio = tonumber(p.ratio or 0) or 0
    if local_ratio < 0 then local_ratio = 0 end
    if local_ratio > 1 then local_ratio = 1 end
    local roots_done = math.max(0, (runner.root_idx or 1) - 1)
    local total_roots = math.max(1, runner.total_roots or 1)
    local overall = (roots_done + local_ratio) / total_roots
    local pct = math.floor(overall * 100 + 0.5)
    state.manage.scan_progress_pct = pct
    local name = tostring(p.pack_name or "")
    local dcnt = tonumber(p.phase_d_count or 0) or 0
    local ecnt = tonumber(p.phase_e_count or 0) or 0
    local tcnt = tonumber(p.total or 0) or 0
    local dext = string.format(" [total:%d d:%d e:%d]", tcnt, dcnt, ecnt)
    if name ~= "" then
      state.manage.scan_progress_label = string.format("Scanning %s (%d%%)%s", name, pct, dext)
    else
      state.manage.scan_progress_label = string.format("Scanning... %d%%%s", pct, dext)
    end
  end
  if done then
    runner.root_idx = runner.root_idx + 1
    runner.job = nil
  end
end

return M
