-- @noindex
-- Low-resolution waveform from PCM_Source_GetPeaks (REAPER).
-- Buffer layout (mono, want_extra_type=0): indices 1..N = max block, N+1..2N = min block.

local r = reaper

local M = {}

local sep = package.config:sub(1, 1)

local DEFAULT_NUM_PEAKS = 384
local MAX_CACHE_ENTRIES = 36

-- 0xRRGGBBAA (ReaImGui / ImGui on REAPER)
local COL_BG = 0x101010FF -- almost-black gray
local COL_WAVE_IDLE = 0x4A4A4AFF -- dark gray (default / not yet played)
local COL_WAVE_PLAYED = 0x5599E6FF -- blue (played portion)
local SILENCE_HALF_PX = 1.0 -- half-height in px so zero peaks still draw a line
local WAVE_DRAW_FILLED_BARS = true

local function current_background_color(ctx)
  if not ctx then return COL_BG end
  if r.ImGui_GetStyleColor and r.ImGui_Col_WindowBg then
    local ok_bg, col = pcall(function()
      return r.ImGui_GetStyleColor(ctx, r.ImGui_Col_WindowBg())
    end)
    if ok_bg and type(col) == "number" then return col end
  end
  return COL_BG
end

local cache_peaks = {}
local cache_order = {}

local CACHE_VER = "2"

local function cache_key(path, fingerprint, num_peaks)
  return tostring(path or "") .. "|" .. tostring(fingerprint or "") .. "|" .. tostring(num_peaks or "") .. "|" .. CACHE_VER
end

local function cache_trim()
  while #cache_order > MAX_CACHE_ENTRIES do
    local k = table.remove(cache_order, 1)
    cache_peaks[k] = nil
  end
end

local function cache_get(path, fp, num_peaks)
  return cache_peaks[cache_key(path, fp, num_peaks)]
end

local function cache_set(path, fp, num_peaks, peaks)
  local k = cache_key(path, fp, num_peaks)
  if not cache_peaks[k] then
    cache_order[#cache_order + 1] = k
    cache_trim()
  end
  cache_peaks[k] = peaks
end

function M.clear_cache()
  cache_peaks = {}
  cache_order = {}
end

function M.file_fingerprint(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, sz = pcall(function()
    f:seek("end", 0)
    return f:seek()
  end)
  f:close()
  if ok and type(sz) == "number" then return tostring(sz) end
  return "0"
end

local PEAK_SIGNAL_THRESHOLD = 1e-8

local function maybe_build_peaks_async(src)
  if not r.PCM_Source_BuildPeaks then return end
  local ok0, v0 = pcall(function() return r.PCM_Source_BuildPeaks(src, 0) end)
  if not ok0 or not v0 or v0 == 0 then return end
  for _ = 1, 128 do
    local ok1, left = pcall(function() return r.PCM_Source_BuildPeaks(src, 1) end)
    if not ok1 or not left or left == 0 then break end
  end
  pcall(function() r.PCM_Source_BuildPeaks(src, 2) end)
end

local function path_has_non_ascii(p)
  if not p or p == "" then return false end
  for pos = 1, #p do
    if string.byte(p, pos) >= 128 then return true end
  end
  return false
end

local function ensure_dir(dir_path)
  if r.RecursiveCreateDirectory then
    pcall(function() r.RecursiveCreateDirectory(dir_path, 0) end)
  end
end

local function copy_file_binary(src_path, dst_path)
  local fin = io.open(src_path, "rb")
  if not fin then return false end
  local data, read_ok = fin:read("*a"), true
  fin:close()
  if not data then return false end
  local fout = io.open(dst_path, "wb")
  if not fout then return false end
  fout:write(data)
  fout:close()
  return true
end

local function copy_to_ascii_temp_path(src_path)
  local base = (r.GetResourcePath() or "") .. sep .. "SampleLodeManager_wave_tmp"
  if base == sep .. "SampleLodeManager_wave_tmp" then return nil end
  ensure_dir(base)
  local stamp = tostring(r.time_precise and r.time_precise() or os.time())
  local rnd = tostring(math.random(100000, 999999))
  local dst = base .. sep .. "wf_" .. rnd .. "_" .. stamp .. ".wav"
  if copy_file_binary(src_path, dst) then return dst end
  return nil
end

local function safe_remove_file(p)
  if not p or p == "" then return end
  pcall(function() os.remove(p) end)
end

-- Pick best mono layout: offsets, swapped min/max blocks, optional Lua [0] base.
local function parse_mono_peak_table(t, n)
  local best_p, best_g = nil, 0
  local n_t = #t
  for _, swap in ipairs({ false, true }) do
    for off = 0, 1 do
      if n_t >= 2 * n + off then
        local p, g = {}, 1e-12
        for i = 1, n do
          local hi = tonumber(t[i + off]) or 0
          local lo = tonumber(t[n + i + off]) or 0
          if swap then hi, lo = lo, hi end
          local a = math.max(math.abs(hi), math.abs(lo))
          p[i] = a
          if a > g then g = a end
        end
        if g > best_g then best_g, best_p = g, p end
      end
    end
  end
  if rawget(t, 0) ~= nil then
    local p, g = {}, 1e-12
    for i = 1, n do
      local hi = tonumber(rawget(t, i - 1)) or 0
      local lo = tonumber(rawget(t, n + i - 1)) or 0
      local a = math.max(math.abs(hi), math.abs(lo))
      p[i] = a
      if a > g then g = a end
    end
    if g > best_g then best_g, best_p = g, p end
  end
  return best_p, best_g
end

local function parse_stereo_peak_table(t, n, nch)
  if nch < 2 then return nil, 0 end
  local need = n * nch * 2
  if #t < need then return nil, 0 end
  local p, g = {}, 1e-12
  -- Interleaved: max block length n*nch, then min block n*nch (REAPER docs).
  for i = 1, n do
    local a = 0
    for c = 1, nch do
      local idx_hi = (i - 1) * nch + c
      local idx_lo = n * nch + (i - 1) * nch + c
      local hi = tonumber(t[idx_hi]) or 0
      local lo = tonumber(t[idx_lo]) or 0
      a = math.max(a, math.abs(hi), math.abs(lo))
    end
    p[i] = a
    if a > g then g = a end
  end
  return p, g
end

local function normalize_peak_array(peaks, glob)
  if not peaks or glob <= 0 then return peaks end
  if glob < PEAK_SIGNAL_THRESHOLD then return peaks end
  for i = 1, #peaks do
    peaks[i] = math.min(1, peaks[i] / glob)
  end
  return peaks
end

-- Try GetPeaks with several rates / channel counts; return peaks, glob (pre-normalize).
local function peaks_from_source_handle(src, num_peaks, len)
  maybe_build_peaks_async(src)
  local rates = {
    num_peaks / len,
    256.0 / math.max(len, 0.001),
  }
  local n_ch_try = { 1 }
  if r.GetMediaSourceNumChannels then
    local nc = r.GetMediaSourceNumChannels(src)
    if type(nc) == "number" and nc >= 2 then
      n_ch_try[#n_ch_try + 1] = math.min(nc, 2)
    end
  end
  local best_p, best_g = nil, 0
  for _, nch in ipairs(n_ch_try) do
    for _, peakrate in ipairs(rates) do
      local buf_size = math.max(num_peaks * nch * 2 + 64, 256)
      local arr = r.new_array(buf_size)
      arr.clear()
      local ok2 = pcall(function()
        r.PCM_Source_GetPeaks(src, peakrate, 0, nch, num_peaks, 0, arr)
      end)
      if ok2 then
        local tab = arr.table()
        if type(tab) == "table" then
          local p, g
          if nch == 1 then
            p, g = parse_mono_peak_table(tab, num_peaks)
          else
            p, g = parse_stereo_peak_table(tab, num_peaks, nch)
          end
          if p and g > best_g then best_g, best_p = g, p end
        end
      end
    end
  end
  return best_p, best_g
end

local function build_peaks_inner(path, num_peaks)
  local ok, src = pcall(function() return r.PCM_Source_CreateFromFile(path) end)
  if not ok or not src then return nil end
  local len = select(1, r.GetMediaSourceLength(src))
  if type(len) ~= "number" or len <= 0.0001 then
    pcall(function() r.PCM_Source_Destroy(src) end)
    return nil
  end
  local peaks, glob = peaks_from_source_handle(src, num_peaks, len)
  pcall(function() r.PCM_Source_Destroy(src) end)
  if not peaks then return nil end
  normalize_peak_array(peaks, glob)
  return peaks
end

--- @return table|nil peaks array of N values in [0,1]
function M.build_peaks(path, num_peaks)
  num_peaks = num_peaks or DEFAULT_NUM_PEAKS
  if not path or path == "" then return nil end
  if not r.PCM_Source_CreateFromFile or not r.PCM_Source_GetPeaks or not r.new_array then
    return nil
  end

  local fp = M.file_fingerprint(path)
  if not fp then return nil end
  local cached = cache_get(path, fp, num_peaks)
  if cached then return cached end

  local peaks = build_peaks_inner(path, num_peaks)
  local function peak_energy(p)
    if not p then return 0 end
    local s = 0
    for i = 1, #p do s = s + (tonumber(p[i]) or 0) end
    return s
  end

  if (not peaks or peak_energy(peaks) < PEAK_SIGNAL_THRESHOLD * num_peaks) and path_has_non_ascii(path) then
    local tmp = copy_to_ascii_temp_path(path)
    if tmp then
      local alt = build_peaks_inner(tmp, num_peaks)
      safe_remove_file(tmp)
      if alt and (not peaks or peak_energy(alt) > peak_energy(peaks)) then
        peaks = alt
      end
    end
  end

  if not peaks then return nil end

  cache_set(path, fp, num_peaks, peaks)
  return peaks
end

-- ReaImGui exposes DrawList as ImGui_DrawList_* (not ImDrawList_*).
local function dl_add_rect_filled(dl, x1, y1, x2, y2, col, rounding)
  rounding = rounding or 0
  if r.ImGui_DrawList_AddRectFilled then
    r.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, col, rounding)
  elseif r.ImDrawList_AddRectFilled then
    r.ImDrawList_AddRectFilled(dl, x1, y1, x2, y2, col, rounding)
  end
end

local function dl_add_line(dl, x1, y1, x2, y2, col, thick)
  thick = thick or 1
  if r.ImGui_DrawList_AddLine then
    r.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, col, thick)
  elseif r.ImDrawList_AddLine then
    r.ImDrawList_AddLine(dl, x1, y1, x2, y2, col, thick)
  end
end

--- play_ratio: nil = not playing (all bars idle color); 0..1 = bars with center <= ratio use played color.
--- played_col_opt: optional override for played portion color (0xRRGGBBAA).
--- Blue vs gray boundary is the effective play position (no separate cursor line).
--- @return table|nil screen rect { x0, y0, w, h } for hit-testing / scrub (same coords as GetMousePosition)
function M.draw(ctx, peaks, x0, y0, w, h, play_ratio, played_col_opt)
  local rect = { x0 = x0, y0 = y0, w = w, h = h }
  if not ctx or not w or not h or w < 2 or h < 4 then return nil end

  if r.ImGui_InvisibleButton then
    r.ImGui_InvisibleButton(ctx, "##rsm_waveform", w, h)
  end

  local dl = r.ImGui_GetWindowDrawList and r.ImGui_GetWindowDrawList(ctx)
  local can_draw = dl and ((r.ImGui_DrawList_AddLine or r.ImDrawList_AddLine) or (r.ImGui_DrawList_AddRectFilled or r.ImDrawList_AddRectFilled))
  if not can_draw then
    if r.ImGui_ProgressBar then
      r.ImGui_ProgressBar(ctx, (peaks and #peaks > 0) and 0.35 or 0.08, w, h)
    end
    return rect
  end

  pcall(function()
    dl_add_rect_filled(dl, x0, y0, x0 + w, y0 + h, current_background_color(ctx), 0)
  end)

  local pr = nil
  if type(play_ratio) == "number" then
    pr = play_ratio
    if pr < 0 then pr = 0 end
    if pr > 1 then pr = 1 end
  end
  local played_col = tonumber(played_col_opt) or COL_WAVE_PLAYED

  if peaks and #peaks > 0 then
    local n = #peaks
    local y_mid = y0 + h * 0.5
    local amp_scale = h * 0.46
    local step = w / n
    local thick = math.max(1, step * 0.85)
    for i = 1, n do
      local raw = (tonumber(peaks[i]) or 0) * amp_scale
      local amp = math.max(SILENCE_HALF_PX, raw)
      local cx = x0 + (i - 0.5) * step
      local t_center = (i - 0.5) / n
      local played = pr ~= nil and t_center <= pr
      local col_bar = played and played_col or COL_WAVE_IDLE
      pcall(function()
        if WAVE_DRAW_FILLED_BARS and (r.ImGui_DrawList_AddRectFilled or r.ImDrawList_AddRectFilled) then
          local x1 = x0 + (i - 1) * step
          local x2 = x0 + i * step
          -- Slight overlap removes anti-aliased seams between adjacent bars.
          x1 = math.floor(x1)
          x2 = math.ceil(x2 + 0.25)
          if x2 <= x1 then x2 = x1 + 1 end
          dl_add_rect_filled(dl, x1, y_mid - amp, x2, y_mid + amp, col_bar, 0)
        else
          dl_add_line(dl, cx, y_mid - amp, cx, y_mid + amp, col_bar, thick)
        end
      end)
    end
  else
    -- No fake waveform: draw only a thin center line until real peaks are ready.
    local y_mid = y0 + h * 0.5
    local col_line = (pr ~= nil) and played_col or COL_WAVE_IDLE
    pcall(function()
      dl_add_line(dl, x0, y_mid, x0 + w, y_mid, col_line, 1)
    end)
  end
  return rect
end

--- Seconds to skip from file start for preview (first sustained non-silent peaks). 0 if unknown.
function M.leading_silence_skip_sec(path)
  if not path or path == "" then return 0 end
  if not r.PCM_Source_CreateFromFile or not r.PCM_Source_GetPeaks or not r.new_array then
    return 0
  end
  local num_peaks = 512
  local ok, src = pcall(function()
    return r.PCM_Source_CreateFromFile(path)
  end)
  if not ok or not src then return 0 end
  local len = select(1, r.GetMediaSourceLength(src))
  if type(len) ~= "number" or len <= 0.0001 then
    pcall(function()
      r.PCM_Source_Destroy(src)
    end)
    return 0
  end
  local peaks, glob = peaks_from_source_handle(src, num_peaks, len)
  pcall(function()
    r.PCM_Source_Destroy(src)
  end)
  if not peaks or not glob or glob <= 0 then return 0 end
  normalize_peak_array(peaks, glob)
  local thr = 0.045
  local need_run = 2
  local run = 0
  local start_bin = nil
  for i = 1, #peaks do
    if (tonumber(peaks[i]) or 0) >= thr then
      run = run + 1
      if run >= need_run then
        start_bin = i - need_run + 1
        break
      end
    else
      run = 0
    end
  end
  if not start_bin or start_bin <= 1 then return 0 end
  local t = (start_bin - 1) / #peaks * len
  t = math.max(0, t - 0.004)
  local cap = math.min(len * 0.5, 12.0)
  if t > cap then t = cap end
  return t
end

return M
