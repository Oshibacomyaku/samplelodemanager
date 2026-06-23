-- @noindex
-- REAPER resource-path layout for Sample Lode Manager (DB + Python work files).
local M = {}

local sep = package.config:sub(1, 1)

--- Normalize user-entered or pasted filesystem paths (quotes, trailing slashes, drive roots).
--- @param raw string|nil
--- @param opts table|nil { empty_as_nil = bool } — when true, empty result is nil (DB); else "" (UI input)
function M.sanitize_root_path(raw, opts)
  opts = type(opts) == "table" and opts or {}
  if raw == nil then
    if opts.empty_as_nil then return nil end
    return ""
  end
  local s = tostring(raw)
  s = s:gsub("\r", ""):gsub("\n", "")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if #s >= 2 then
    local first = s:sub(1, 1)
    local last = s:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
      s = s:sub(2, -2)
      s = s:gsub("^%s+", ""):gsub("%s+$", "")
    end
  end
  if s ~= "" then
    local drive = s:match("^([A-Za-z]:)[/\\]?$")
    if drive then
      s = drive .. sep
    else
      s = s:gsub("[/\\]+$", "")
    end
  end
  if s == "" then
    if opts.empty_as_nil then return nil end
    return ""
  end
  return s
end

function M.ensure_dir(dir_path)
  if not dir_path or dir_path == "" then return false end
  if sep == "\\" then
    local win = dir_path:gsub("/", "\\")
    os.execute(string.format('if not exist "%s" mkdir "%s"', win, win))
  else
    os.execute(string.format('mkdir -p "%s" 2>/dev/null', dir_path))
  end
  return true
end

function M.get_resource_root(r)
  if not r or not r.GetResourcePath then return nil end
  local root = r.GetResourcePath()
  if not root or root == "" then return nil end
  return root
end

--- {ResourcePath}/SampleLodeManager/
function M.get_data_dir(r)
  local res = M.get_resource_root(r)
  if not res then return nil end
  local dir = res .. sep .. "SampleLodeManager"
  M.ensure_dir(dir)
  return dir
end

--- {ResourcePath}/SampleLodeManager/work/ — Python batch TSV interchange (ephemeral).
function M.get_work_dir(r)
  local data = M.get_data_dir(r)
  if not data then return nil end
  local dir = data .. sep .. "work"
  M.ensure_dir(dir)
  return dir
end

function M.safe_remove(path)
  if not path or path == "" then return end
  pcall(os.remove, path)
end

function M.remove_paths(paths)
  if type(paths) ~= "table" then return end
  for _, p in ipairs(paths) do
    M.safe_remove(p)
  end
end

--- Stem e.g. "phase_a" -> work/phase_a_in.tsv, work/phase_a_out.tsv
function M.work_pair(r, stem)
  local dir = M.get_work_dir(r)
  if not dir or not stem or stem == "" then return nil end
  return {
    in_path = dir .. sep .. stem .. "_in.tsv",
    out_path = dir .. sep .. stem .. "_out.tsv",
  }
end

function M.work_file(r, stem, suffix)
  local dir = M.get_work_dir(r)
  if not dir or not stem or stem == "" then return nil end
  return dir .. sep .. stem .. tostring(suffix or "")
end

function M.cleanup_work_pair(pair)
  if type(pair) ~= "table" then return end
  M.remove_paths({ pair.in_path, pair.out_path })
end

--- DB path with one-time migration from legacy {ResourcePath}/SampleLodeManager.sqlite
function M.get_db_path(r)
  local res = M.get_resource_root(r)
  local data = M.get_data_dir(r)
  if not res or not data then return nil end
  local new_path = data .. sep .. "SampleLodeManager.sqlite"
  local legacy = res .. sep .. "SampleLodeManager.sqlite"
  if legacy == new_path then return new_path end

  local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
  end

  if exists(legacy) and not exists(new_path) then
    pcall(os.rename, legacy, new_path)
    if exists(legacy .. "-wal") and not exists(new_path .. "-wal") then
      pcall(os.rename, legacy .. "-wal", new_path .. "-wal")
    end
    if exists(legacy .. "-shm") and not exists(new_path .. "-shm") then
      pcall(os.rename, legacy .. "-shm", new_path .. "-shm")
    end
  end
  return new_path
end

function M.get_waveform_temp_base(r)
  local dir = M.get_work_dir(r)
  if not dir then return nil end
  return dir .. sep .. "wave_tmp"
end

return M
