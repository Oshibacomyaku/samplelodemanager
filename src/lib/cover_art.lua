-- Splice pack cover URLs: download to local cache + optional ReaImGui texture.
local r = reaper

local M = {}

local sep = package.config:sub(1, 1)

local cache_dir = nil

local function ensure_cache_dir()
  if not cache_dir or cache_dir == "" then return false end
  if r.RecursiveCreateDirectory then
    pcall(function() r.RecursiveCreateDirectory(cache_dir, 0) end)
  end
  return true
end

function M.init(script_base_path)
  local base = script_base_path or ""
  if base == "" then
    base = "." .. sep
  end
  local last = base:sub(-1)
  if last ~= "\\" and last ~= "/" then
    base = base .. sep
  end
  cache_dir = base .. "cover_cache"
  ensure_cache_dir()
end

local function hash_url(u)
  local h = 5381
  for i = 1, #u do
    h = ((h * 33) + string.byte(u, i)) % 2147483647
  end
  return string.format("%08x", h)
end

local function url_to_ext(u)
  local path_only = u:match("^[^?]+") or u
  local ext = path_only:match("%.([a-zA-Z0-9]+)$")
  ext = ext and ext:lower() or nil
  if ext == "jpeg" then ext = "jpg" end
  if ext == "jpg" or ext == "png" or ext == "webp" then
    return "." .. ext
  end
  return ".bin"
end

function M.cache_file_path(url)
  if not url or url == "" or not cache_dir then return nil end
  return cache_dir .. sep .. "c_" .. hash_url(tostring(url)) .. url_to_ext(tostring(url))
end

local function file_nonempty(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local n = f:seek("end", 0)
  f:close()
  return n and n > 100
end

local function path_ext(path)
  if not path then return "" end
  local ext = tostring(path):match("%.([^%.\\/]+)$")
  return (ext and ext:lower()) or ""
end

local function file_magic(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local b = f:read(16) or ""
  f:close()
  return b
end

local function guess_image_kind(path)
  local ext = path_ext(path)
  local m = file_magic(path)
  if m:sub(1, 4) == "\x89PNG" then return "png" end
  if m:sub(1, 3) == "\xFF\xD8\xFF" then return "jpg" end
  if m:sub(1, 4) == "RIFF" and m:sub(9, 12) == "WEBP" then return "webp" end
  if ext ~= "" then return ext end
  return "unknown"
end

local function quote_cmd_arg(s)
  return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

local function now_sec()
  if r.time_precise then
    local ok, v = pcall(r.time_precise)
    if ok and type(v) == "number" then return v end
  end
  return os.clock()
end

-- Prefer ExecProcess to avoid popping visible console windows on Windows.
local function run_cmd_silent(cmd, timeout_ms)
  timeout_ms = tonumber(timeout_ms) or 20000
  if r.ExecProcess then
    local ok, rv = pcall(function()
      local code = r.ExecProcess(cmd, timeout_ms)
      return tonumber(code) or -1
    end)
    if ok then
      return rv == 0
    end
  end
  local code = os.execute(cmd)
  return code == 0 or code == true
end

local function download_via_curl(url, dest_path)
  local cmd = string.format("curl -sL -f -o %s %s", quote_cmd_arg(dest_path), quote_cmd_arg(url))
  return run_cmd_silent(cmd, 25000)
end

local function try_convert_webp_to_png(src_path)
  local ext = path_ext(src_path)
  if ext ~= "webp" then return src_path, false end
  local dst_path = src_path:gsub("%.webp$", ".png")
  if dst_path == src_path then
    dst_path = src_path .. ".png"
  end
  if file_nonempty(dst_path) then
    return dst_path, true
  end
  local cmd_magick = "magick " .. quote_cmd_arg(src_path) .. " " .. quote_cmd_arg(dst_path)
  if run_cmd_silent(cmd_magick, 20000) and file_nonempty(dst_path) then
    return dst_path, true
  end
  local cmd_ffmpeg = "ffmpeg -y -loglevel error -i " .. quote_cmd_arg(src_path) .. " " .. quote_cmd_arg(dst_path)
  if run_cmd_silent(cmd_ffmpeg, 20000) and file_nonempty(dst_path) then
    return dst_path, true
  end
  return src_path, false
end

local function download_via_ps1(url, dest_path)
  if sep ~= "\\" or not cache_dir then return false end
  ensure_cache_dir()
  local script_path = cache_dir .. sep .. "_dl_" .. hash_url(url) .. ".ps1"
  local f = io.open(script_path, "w")
  if not f then return false end
  f:write("$ProgressPreference='SilentlyContinue'\n")
  f:write("$u = " .. string.format("%q", tostring(url)) .. "\n")
  f:write("$o = " .. string.format("%q", tostring(dest_path)) .. "\n")
  f:write("try { Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing } catch { exit 1 }\n")
  f:close()
  local cmd = 'powershell -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File '
    .. quote_cmd_arg(script_path:gsub("/", "\\"))
  return run_cmd_silent(cmd, 30000)
end

function M.download_to_file(url, dest_path)
  if not url or url == "" or not dest_path or dest_path == "" then return false end
  ensure_cache_dir()
  if download_via_curl(url, dest_path) and file_nonempty(dest_path) then
    return true
  end
  if sep == "\\" and download_via_ps1(url, dest_path) and file_nonempty(dest_path) then
    return true
  end
  return false
end

--- Try ImGui_CreateTextureFromFile (ReaImGui). Returns tex, disp_w, disp_h or nil.
function M.try_texture_from_file(ctx, path, max_side)
  max_side = max_side or 40
  if not ctx or not path then return nil end
  local tex, tw, th = nil, nil, nil

  -- Keep one handle type only (ImGui_Image*) to avoid mixed-pointer instability.
  if r.ImGui_CreateImageFromFile then
    local ok, a, b, c = pcall(function()
      return r.ImGui_CreateImageFromFile(ctx, path)
    end)
    if ok and a then
      tex, tw, th = a, b, c
    end
    if not tex then
      local ok2, a2, b2, c2 = pcall(function()
        return r.ImGui_CreateImageFromFile(path)
      end)
      if ok2 and a2 then
        tex, tw, th = a2, b2, c2
      end
    end
  end

  -- Fallback: load bytes and create image from memory.
  if (not tex) and r.ImGui_CreateImageFromMem then
    local f = io.open(path, "rb")
    local bytes = nil
    if f then
      bytes = f:read("*a")
      f:close()
    end
    if bytes and #bytes > 0 then
      local ok3, a3, b3, c3 = pcall(function()
        return r.ImGui_CreateImageFromMem(ctx, bytes)
      end)
      if ok3 and a3 then
        tex, tw, th = a3, b3, c3
      end
      if not tex then
        local ok4, a4, b4, c4 = pcall(function()
          return r.ImGui_CreateImageFromMem(bytes)
        end)
        if ok4 and a4 then
          tex, tw, th = a4, b4, c4
        end
      end
    end
  end

  if not tex then return nil end
  tw = tonumber(tw)
  th = tonumber(th)
  if (not tw or not th) and r.ImGui_GetTextureDimensions then
    local ok2, w2, h2 = pcall(function()
      return r.ImGui_GetTextureDimensions(ctx, tex)
    end)
    if ok2 then
      tw = tonumber(w2) or tw
      th = tonumber(h2) or th
    end
  end
  tw = tw or max_side
  th = th or max_side
  local scale = max_side / math.max(tw, th)
  if scale > 1 then scale = 1 end
  return tex, tw * scale, th * scale
end

function M.destroy_texture(ctx, tex)
  if not tex then return end
  -- Match creation API: image handles are destroyed via DestroyImage only.
  if ctx and r.ImGui_DestroyImage then
    pcall(function() r.ImGui_DestroyImage(ctx, tex) end)
    pcall(function() r.ImGui_DestroyImage(tex) end)
  end
end

local function touch_texture_entry(runtime_cover, pid, ent)
  if not runtime_cover or not ent then return end
  runtime_cover.tick = (runtime_cover.tick or 0) + 1
  ent.last_used_tick = runtime_cover.tick
  ent.last_used_at = now_sec()
  ent.pack_id = pid
end

local function evict_lru_if_needed(ctx, runtime_cover, keep_pid)
  if not runtime_cover or not runtime_cover.by_pack then return end
  local max_tex = tonumber(runtime_cover.max_textures) or 24
  if max_tex < 8 then max_tex = 8 end

  local live = {}
  for pid, ent in pairs(runtime_cover.by_pack) do
    if ent and ent.tex then
      live[#live + 1] = { pid = pid, ent = ent, tick = tonumber(ent.last_used_tick) or 0 }
    end
  end
  if #live <= max_tex then return end
  table.sort(live, function(a, b) return a.tick < b.tick end)
  local need_drop = #live - max_tex
  for i = 1, #live do
    if need_drop <= 0 then break end
    local it = live[i]
    if it and it.ent and it.pid ~= keep_pid then
      M.destroy_texture(ctx, it.ent.tex)
      it.ent.tex = nil
      it.ent.dw = nil
      it.ent.dh = nil
      it.ent.fail_tex = false
      it.ent.fail_reason = nil
      it.ent.next_retry_at = nil
      need_drop = need_drop - 1
    end
  end
end

function M.process_queue(queue, max_per_tick)
  max_per_tick = max_per_tick or 1
  if type(queue) ~= "table" or #queue == 0 then return end
  local n = 0
  while n < max_per_tick and #queue > 0 do
    local job = table.remove(queue, 1)
    if job and job.url and job.path and job.pack_id then
      if job.runtime and type(job.runtime.queue_by_pack) == "table" then
        job.runtime.queue_by_pack[tonumber(job.pack_id)] = nil
      end
      local ok = false
      if file_nonempty(job.path) then
        ok = true
      else
        ok = M.download_to_file(job.url, job.path)
      end
      if job.runtime and job.runtime.by_pack then
        local ent = job.runtime.by_pack[job.pack_id]
        if ent then
          ent.queued = false
          if ok then
            ent.local_ready = true
          else
            ent.fail_dl = true
            ent.local_ready = false
          end
        end
      end
    end
    n = n + 1
  end
end

function M.ensure_queued(runtime_cover, pack_id, url)
  if not runtime_cover or not pack_id or not url or url == "" then return end
  local pid = tonumber(pack_id)
  if not pid then return end
  runtime_cover.by_pack = runtime_cover.by_pack or {}
  local ent = runtime_cover.by_pack[pid]
  if ent and ent.url ~= url then
    if ent.tex then
      M.destroy_texture(runtime_cover.ctx_ref, ent.tex)
    end
    ent.tex = nil
    ent.fail_dl = false
    ent.fail_tex = false
    ent.queued = false
    ent.fail_reason = nil
    ent.image_kind = nil
    ent.render_path = nil
    ent.convert_attempted = false
    ent.convert_ok = false
    ent.fail_count = 0
    ent.next_retry_at = nil
    ent.last_used_tick = nil
    ent.url = url
  end
  if not ent then
    ent = { url = url }
    runtime_cover.by_pack[pid] = ent
  end
  local path = M.cache_file_path(url)
  ent.path = path
  if not path then return end
  if file_nonempty(path) then
    ent.local_ready = true
    ent.image_kind = guess_image_kind(path)
    ent.render_path = ent.render_path or path
    return
  end
  ent.local_ready = false
  if ent.fail_dl then return end
  if ent.queued then return end
  runtime_cover.queue_by_pack = runtime_cover.queue_by_pack or {}
  if runtime_cover.queue_by_pack[pid] then return end
  ent.queued = true
  runtime_cover.queue = runtime_cover.queue or {}
  runtime_cover.queue_by_pack[pid] = true
  runtime_cover.queue[#runtime_cover.queue + 1] = {
    url = url,
    path = path,
    pack_id = pid,
    runtime = runtime_cover,
  }
end

function M.draw_cell(ctx, runtime_cover, pack_id, url, thumb_max, allow_enqueue)
  thumb_max = thumb_max or 36
  if not ctx then return end
  if not url or url == "" or not tonumber(pack_id) then
    if r.ImGui_Dummy then
      r.ImGui_Dummy(ctx, thumb_max, thumb_max)
    end
    return
  end
  runtime_cover = runtime_cover or {}
  local pid = tonumber(pack_id)
  runtime_cover.by_pack = runtime_cover.by_pack or {}
  local ent = runtime_cover.by_pack[pid]
  if not ent then
    local path = M.cache_file_path(url)
    ent = {
      url = url,
      path = path,
      local_ready = path and file_nonempty(path) or false,
    }
    runtime_cover.by_pack[pid] = ent
  end
  if allow_enqueue == true then
    M.ensure_queued(runtime_cover, pid, url)
    ent = runtime_cover.by_pack[pid] or ent
  end
  local path = ent and ent.path
  if ent and ent.local_ready == nil and path then
    ent.local_ready = file_nonempty(path)
  end
  if path and ent and ent.local_ready == true and not ent.tex then
    local ts = now_sec()
    if ent.next_retry_at and ts < ent.next_retry_at then
      if r.ImGui_Dummy then
        r.ImGui_Dummy(ctx, thumb_max, thumb_max)
      end
      return
    end
    local src_path = ent.render_path or path
    if ent.image_kind == nil then
      ent.image_kind = guess_image_kind(path)
    end
    if (not ent.convert_attempted) and ent.image_kind == "webp" then
      ent.convert_attempted = true
      local conv_path, ok_conv = try_convert_webp_to_png(path)
      ent.convert_ok = ok_conv == true
      if ok_conv and conv_path and conv_path ~= "" then
        src_path = conv_path
        ent.render_path = conv_path
        ent.image_kind = "png"
      else
        ent.render_path = path
      end
    end
    local t, dw, dh = M.try_texture_from_file(ctx, src_path, thumb_max)
    if t then
      ent.tex = t
      ent.dw = dw
      ent.dh = dh
      ent.fail_reason = nil
      ent.fail_tex = false
      ent.fail_count = 0
      ent.next_retry_at = nil
      touch_texture_entry(runtime_cover, pid, ent)
      evict_lru_if_needed(ctx, runtime_cover, pid)
    else
      ent.fail_tex = true
      ent.fail_reason = "create_texture_failed"
      ent.render_path = src_path
      if not r.ImGui_CreateImageFromFile and not r.ImGui_CreateImageFromMem then
        ent.fail_reason = "no_image_create_api"
      end
      ent.fail_count = (tonumber(ent.fail_count) or 0) + 1
      ent.next_retry_at = ts + math.min(5.0, 0.4 * ent.fail_count)
    end
  end
  if ent and ent.tex and r.ImGui_Image then
    local dw = ent.dw or thumb_max
    local dh = ent.dh or thumb_max
    if r.ImGui_ValidatePtr then
      local ok_v, valid = pcall(function()
        return r.ImGui_ValidatePtr(ent.tex, "ImGui_Image*")
      end)
      if ok_v and (not valid) then
        M.destroy_texture(ctx, ent.tex)
        ent.tex = nil
        ent.fail_tex = true
        ent.fail_reason = "invalid_image_ptr"
        ent.fail_count = (tonumber(ent.fail_count) or 0) + 1
        ent.next_retry_at = now_sec() + math.min(5.0, 0.4 * ent.fail_count)
      end
    end
  end

  if ent and ent.tex and r.ImGui_Image then
    local dw = ent.dw or thumb_max
    local dh = ent.dh or thumb_max
    local ok_draw = pcall(function()
      r.ImGui_Image(ctx, ent.tex, dw, dh)
    end)
    if not ok_draw then
      -- Pointer may become stale across frames; invalidate safely and retry via reload path.
      M.destroy_texture(ctx, ent.tex)
      ent.tex = nil
      ent.fail_tex = true
      ent.fail_reason = "image_draw_failed"
      ent.fail_count = (tonumber(ent.fail_count) or 0) + 1
      ent.next_retry_at = now_sec() + math.min(5.0, 0.4 * ent.fail_count)
    else
      touch_texture_entry(runtime_cover, pid, ent)
    end
  elseif r.ImGui_Dummy then
    r.ImGui_Dummy(ctx, thumb_max, thumb_max)
  end
end

function M.get_entry_status(runtime_cover, pack_id, url)
  if not url or tostring(url) == "" then
    return "no_url"
  end
  if not runtime_cover or not runtime_cover.by_pack then
    return "unseen"
  end
  local pid = tonumber(pack_id)
  if not pid then
    return "bad_pack_id"
  end
  local ent = runtime_cover.by_pack[pid]
  if not ent then
    return "unseen"
  end
  if ent.tex then
    return "tex_ready"
  end
  if ent.fail_dl then
    return "dl_failed"
  end
  if ent.fail_tex then
    return "tex_failed"
  end
  if ent.queued then
    return "queued"
  end
  if ent.local_ready == true then
    return "cached_not_loaded"
  end
  if ent.local_ready == false then
    return "not_cached"
  end
  return "unknown"
end

function M.describe_entry(runtime_cover, pack_id, url)
  local st = M.get_entry_status(runtime_cover, pack_id, url)
  if not runtime_cover or not runtime_cover.by_pack then
    return st
  end
  local pid = tonumber(pack_id)
  local ent = pid and runtime_cover.by_pack[pid] or nil
  if not ent then return st end
  local parts = { st }
  if ent.image_kind then parts[#parts + 1] = "kind=" .. tostring(ent.image_kind) end
  if ent.convert_attempted then
    parts[#parts + 1] = "convert=" .. (ent.convert_ok and "ok" or "fail")
  end
  if ent.fail_reason then parts[#parts + 1] = "reason=" .. tostring(ent.fail_reason) end
  if ent.path then parts[#parts + 1] = "path=" .. tostring(ent.path) end
  if ent.render_path and ent.render_path ~= ent.path then
    parts[#parts + 1] = "render=" .. tostring(ent.render_path)
  end
  return table.concat(parts, " | ")
end

function M.summarize_rows(rows, runtime_cover, scan_limit)
  local out = {
    scanned = 0,
    no_url = 0,
    unseen = 0,
    queued = 0,
    dl_failed = 0,
    tex_failed = 0,
    tex_ready = 0,
    cached_not_loaded = 0,
    not_cached = 0,
    unknown = 0,
    kind_webp = 0,
    kind_png = 0,
    kind_jpg = 0,
  }
  if type(rows) ~= "table" then return out end
  local limit = tonumber(scan_limit) or #rows
  if limit < 1 then return out end
  local max_i = math.min(#rows, math.floor(limit))
  for i = 1, max_i do
    local row = rows[i]
    if row then
      local url = row.pack_cover_url and tostring(row.pack_cover_url) or ""
      local status = M.get_entry_status(runtime_cover, row.pack_id, url)
      out.scanned = out.scanned + 1
      if out[status] ~= nil then
        out[status] = out[status] + 1
      else
        out.unknown = out.unknown + 1
      end
      local pid = row.pack_id and tonumber(row.pack_id) or nil
      local ent = (pid and runtime_cover and runtime_cover.by_pack and runtime_cover.by_pack[pid]) or nil
      local k = ent and ent.image_kind or nil
      if k == "webp" then out.kind_webp = out.kind_webp + 1 end
      if k == "png" then out.kind_png = out.kind_png + 1 end
      if k == "jpg" or k == "jpeg" then out.kind_jpg = out.kind_jpg + 1 end
    end
  end
  return out
end

return M
