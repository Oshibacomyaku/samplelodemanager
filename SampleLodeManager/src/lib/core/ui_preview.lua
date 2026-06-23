-- @noindex
local M = {}

local r, state, C
local set_runtime_notice, file_exists, key_bpm
local get_selected_sample_row

local waveform = nil
do
  local ok, mod = pcall(require, "waveform")
  if ok then waveform = mod end
end

function M.setup(deps)
  r = deps.r
  state = deps.state
  C = deps.C
  set_runtime_notice = deps.set_runtime_notice
  file_exists = deps.file_exists
  key_bpm = deps.key_bpm
  get_selected_sample_row = deps.get_selected_sample_row
end

local function pcm_source_length_sec(source)
  if not source or type(r.GetMediaSourceLength) ~= "function" then return nil end
  local ok_len, len = pcall(function()
    return r.GetMediaSourceLength(source)
  end)
  if ok_len and type(len) == "number" and len > 0 then return len end
  return nil
end

local function parse_sample_bpm(value)
  if not key_bpm then return nil end
  return key_bpm.parse_sample_bpm(value)
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

function M.get_detail_waveform_play_ratio(row)
  if not row or not row.path then return nil end
  local sr = tonumber(state.runtime.wave_scrub_ratio)
  if sr then
    if sr < 0 then sr = 0 end
    if sr > 1 then sr = 1 end
    return sr
  end
  if not state.playing or state.runtime.preview_path ~= row.path then return nil end
  local full = tonumber(state.runtime.preview_full_length_sec)
  local off = tonumber(state.runtime.preview_offset_sec) or 0
  if full and full > 0 then
    local now = (r.time_precise and r.time_precise()) or os.clock()
    local start_t = tonumber(state.runtime.preview_started_at) or now
    local elapsed = now - start_t
    local playrate = tonumber(state.runtime.preview_last_playrate) or 1.0
    if playrate < 0.1 then playrate = 0.1 end
    if playrate > 4.0 then playrate = 4.0 end
    local pos = off + (elapsed * playrate)
    local pr = pos / full
    if pr < 0 then pr = 0 end
    if pr > 1 then pr = 1 end
    return pr
  end
  local dur = tonumber(state.runtime.preview_duration_sec)
  if not dur or dur <= 0 then return nil end
  local now = (r.time_precise and r.time_precise()) or os.clock()
  local start_t = tonumber(state.runtime.preview_started_at) or now
  local elapsed = now - start_t
  local pr = elapsed / dur
  if pr < 0 then pr = 0 end
  if pr > 1 then pr = 1 end
  return pr
end

function M.check_preview_api_available()
  if state.runtime.preview_checked then
    return state.runtime.preview_available
  end
  state.runtime.preview_checked = true
  state.runtime.preview_available =
    (type(r.CF_CreatePreview) == "function")
    and (type(r.CF_Preview_Play) == "function")
    and (type(r.CF_Preview_Stop) == "function")
    and (type(r.PCM_Source_CreateFromFile) == "function")
  if not state.runtime.preview_available then
    state.runtime.preview_error = "Preview API is unavailable. Check SWS and REAPER PCM_Source API."
  else
    state.runtime.preview_error = ""
  end
  return state.runtime.preview_available
end

--- @param keep_wf_scrub boolean|nil if true, keep waveform drag state and wave_scrub_ratio (scrub: audio off until mouse up)
function M.stop_preview(keep_wf_scrub)
  local h = state.runtime.preview_handle
  local src = state.runtime.preview_source
  if h and type(r.CF_Preview_Stop) == "function" then
    pcall(function() r.CF_Preview_Stop(h) end)
  end
  if h and type(r.CF_DestroyPreview) == "function" then
    pcall(function() r.CF_DestroyPreview(h) end)
  end
  if src and type(r.PCM_Source_Destroy) == "function" then
    pcall(function() r.PCM_Source_Destroy(src) end)
  end
  state.runtime.preview_handle = nil
  state.runtime.preview_source = nil
  state.runtime.preview_path = nil
  state.runtime.preview_sample_bpm = nil
  state.runtime.preview_last_playrate = nil
  state.runtime.preview_started_at = nil
  state.runtime.preview_duration_sec = nil
  state.runtime.preview_offset_sec = nil
  state.runtime.preview_full_length_sec = nil
  if not keep_wf_scrub then
    state.runtime.wave_scrub_ratio = nil
    state.runtime.wf_capture = false
    state.runtime.wf_path = nil
    state.runtime.wf_name = nil
  end
  state.playing = false
end

function M.refresh_preview_state()
  if not state.playing then return end
  local handle = state.runtime.preview_handle
  if not handle then
    state.playing = false
    return
  end
  local now = (r.time_precise and r.time_precise()) or os.clock()
  local started_at = tonumber(state.runtime.preview_started_at) or now
  local elapsed = now - started_at
  local playrate = tonumber(state.runtime.preview_last_playrate) or 1.0
  if playrate < 0.1 then playrate = 0.1 end
  if playrate > 4.0 then playrate = 4.0 end
  local full = tonumber(state.runtime.preview_full_length_sec)
  if full and full > 0 then
    local off = tonumber(state.runtime.preview_offset_sec) or 0
    if (off + (elapsed * playrate)) >= (full + 0.03) then
      M.stop_preview()
    end
    return
  end
  local duration = tonumber(state.runtime.preview_duration_sec)
  if not duration or duration <= 0 then
    return
  end
  if (elapsed * playrate) >= (duration + 0.03) then
    M.stop_preview()
  end
end

function M.apply_preview_playrate(handle, sample_bpm)
  if not handle or type(r.CF_Preview_SetValue) ~= "function" then return end
  local playrate = 1.0
  local preserve_pitch = 0
  if state.ui.match_preview_to_project_bpm == true then
    local matched = calc_bpm_match_playrate(sample_bpm)
    if matched then
      playrate = matched
      preserve_pitch = 1
    end
  end
  local mul = tonumber(state.ui.rate_multiplier) or 1.0
  if mul < 0.25 then mul = 0.25 end
  if mul > 4.0 then mul = 4.0 end
  if math.abs(mul - 1.0) > 0.0001 then
    preserve_pitch = 0
  end
  playrate = playrate * mul
  if playrate < 0.1 then playrate = 0.1 end
  if playrate > 4.0 then playrate = 4.0 end
  local last = tonumber(state.runtime.preview_last_playrate)
  if last and math.abs(last - playrate) < 0.0001 then
    return
  end
  pcall(function()
    r.CF_Preview_SetValue(handle, "D_PLAYRATE", playrate)
  end)
  -- Preserve pitch for BPM match only (mul==1); allow pitch change when mul!=1.
  pcall(function()
    r.CF_Preview_SetValue(handle, "B_PPITCH", preserve_pitch)
  end)
  state.runtime.preview_last_playrate = playrate
end

--- offset_sec: position in file (seconds) to start playback from (requires CF_Preview_SetValue when > 0).
function M.start_preview_playing(path, label, offset_sec, sample_bpm)
  offset_sec = math.max(0, tonumber(offset_sec) or 0)
  if not path or path == "" then
    set_runtime_notice("Preview failed: path empty.")
    M.stop_preview()
    state.playing = false
    return false
  end
  if not file_exists(path) then
    set_runtime_notice("Preview failed: file not found.")
    M.stop_preview()
    state.playing = false
    return false
  end
  if not M.check_preview_api_available() then
    set_runtime_notice(state.runtime.preview_error)
    M.stop_preview()
    state.playing = false
    return false
  end

  local ok_src, source_or_err = pcall(function()
    return r.PCM_Source_CreateFromFile(path)
  end)
  if not ok_src or not source_or_err then
    set_runtime_notice("Preview source create failed: " .. tostring(source_or_err))
    M.stop_preview()
    state.playing = false
    return false
  end

  local source = source_or_err
  local full = pcm_source_length_sec(source)
  if not full then
    if type(r.PCM_Source_Destroy) == "function" then
      pcall(function() r.PCM_Source_Destroy(source) end)
    end
    set_runtime_notice("Preview failed: could not read media length.")
    M.stop_preview()
    state.playing = false
    return false
  end
  if offset_sec > full then offset_sec = full end

  M.stop_preview()

  local ok_create, handle_or_err = pcall(function()
    return r.CF_CreatePreview(source)
  end)
  if not ok_create or not handle_or_err then
    if type(r.PCM_Source_Destroy) == "function" then
      pcall(function() r.PCM_Source_Destroy(source) end)
    end
    set_runtime_notice("Preview create failed: " .. tostring(handle_or_err))
    state.playing = false
    return false
  end

  local handle = handle_or_err
  state.runtime.preview_last_playrate = nil
  local gain = tonumber(state.ui.preview_gain) or C.DEFAULT_PREVIEW_GAIN
  if gain < 0 then gain = 0 end
  if gain > 2 then gain = 2 end
  state.ui.preview_gain = gain
  if type(r.CF_Preview_SetValue) == "function" then
    pcall(function()
      r.CF_Preview_SetValue(handle, "D_VOLUME", gain)
    end)
    M.apply_preview_playrate(handle, sample_bpm)
  end
  local use_offset = offset_sec
  if use_offset > 0 and type(r.CF_Preview_SetValue) ~= "function" then
    use_offset = 0
    set_runtime_notice("Scrub/seek needs CF_Preview_SetValue (SWS). Playing from start.")
  elseif use_offset > 0 then
    pcall(function()
      r.CF_Preview_SetValue(handle, "D_POSITION", use_offset)
    end)
  end

  local ok_play, play_err = pcall(function()
    r.CF_Preview_Play(handle)
  end)
  if not ok_play then
    set_runtime_notice("Preview play failed: " .. tostring(play_err))
    M.stop_preview()
    return false
  end

  local now = (r.time_precise and r.time_precise()) or os.clock()
  state.runtime.preview_source = source
  state.runtime.preview_handle = handle
  state.runtime.preview_path = path
  state.runtime.preview_sample_bpm = parse_sample_bpm(sample_bpm)
  state.runtime.preview_full_length_sec = full
  state.runtime.preview_offset_sec = use_offset
  state.runtime.preview_started_at = now
  state.runtime.preview_duration_sec = math.max(0, full - use_offset)
  state.playing = true
  return true
end

function M.preview_seek_or_restart_from_ratio(path, label, ratio, quiet)
  ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
  if not path or path == "" then return end
  if not M.check_preview_api_available() then return end

  local full = tonumber(state.runtime.preview_full_length_sec)
  if (not full or full <= 0) or state.runtime.preview_path ~= path then
    local ok_src, src = pcall(function()
      return r.PCM_Source_CreateFromFile(path)
    end)
    if ok_src and src then
      full = pcm_source_length_sec(src)
      if type(r.PCM_Source_Destroy) == "function" then
        pcall(function() r.PCM_Source_Destroy(src) end)
      end
    end
  end
  if not full or full <= 0 then return end

  local off = ratio * full
  local now = (r.time_precise and r.time_precise()) or os.clock()
  local same = state.playing
    and state.runtime.preview_handle
    and state.runtime.preview_path == path

  if same and type(r.CF_Preview_SetValue) == "function" then
    M.apply_preview_playrate(state.runtime.preview_handle, state.runtime.preview_sample_bpm)
    pcall(function()
      r.CF_Preview_SetValue(state.runtime.preview_handle, "D_POSITION", off)
    end)
    pcall(function()
      r.CF_Preview_Play(state.runtime.preview_handle)
    end)
    state.runtime.preview_offset_sec = off
    state.runtime.preview_full_length_sec = full
    state.runtime.preview_started_at = now
    state.runtime.preview_duration_sec = math.max(0, full - off)
    state.playing = true
    return
  end

  local bpm_for_restart = state.runtime.preview_sample_bpm
  local cur = get_selected_sample_row()
  if cur and cur.path == path then
    bpm_for_restart = cur.bpm
  end
  M.start_preview_playing(path, (not quiet) and label or nil, off, bpm_for_restart)
end

function M.play_selected_sample_preview()
  local row = get_selected_sample_row()
  if not row then
    set_runtime_notice("No sample selected.")
    M.stop_preview()
    state.playing = false
    return
  end
  local path = row.path
  if not path or path == "" then
    set_runtime_notice("Selected sample path is empty.")
    M.stop_preview()
    state.playing = false
    return
  end
  local skip_sec = 0
  if waveform and type(waveform.leading_silence_skip_sec) == "function" then
    local cache_by_path = state.runtime.preview_skip_cache_by_path
    local cache_order = state.runtime.preview_skip_cache_order
    if type(cache_by_path) ~= "table" then
      cache_by_path = {}
      state.runtime.preview_skip_cache_by_path = cache_by_path
    end
    if type(cache_order) ~= "table" then
      cache_order = {}
      state.runtime.preview_skip_cache_order = cache_order
    end
    local cached = cache_by_path[path]
    if type(cached) == "number" then
      skip_sec = math.max(0, cached)
    else
      local ok_skip, s = pcall(function()
        return waveform.leading_silence_skip_sec(path)
      end)
      if ok_skip and type(s) == "number" and s > 0 then
        skip_sec = s
      end
      cache_by_path[path] = skip_sec
      cache_order[#cache_order + 1] = path
      local max_entries = 512
      while #cache_order > max_entries do
        local old = table.remove(cache_order, 1)
        if old then
          cache_by_path[old] = nil
        end
      end
    end
  end
  M.start_preview_playing(path, row.filename or path, skip_sec, row.bpm)
end

return M
