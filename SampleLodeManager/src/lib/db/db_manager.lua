-- @noindex
local M = {}

local status = {
  available = false,
  backend = nil, -- "sqlite" | "json" | nil
  module_name = nil,
  error = nil,
  tried = {},
}

local function try_require(module_name)
  local ok, lib_or_err = pcall(require, module_name)
  if ok and lib_or_err then
    return true, lib_or_err
  end
  return false, lib_or_err
end

-- v0.1は「SQLiteモジュールが無ければ警告を出してUIは継続」する。
-- 後でJSONキャッシュ等に差し替えるため、ここを入口として固定する。
function M.init()
  status.tried = {}
  -- まず SQLite を探す（候補は未確定なので複数）
  local candidates = { "lsqlite3", "lsqlite3complete", "sqlite3" }
  local errs = {}
  for _, name in ipairs(candidates) do
    local ok, lib_or_err = try_require(name)
    status.tried[#status.tried + 1] = { name = name, ok = ok, err = ok and nil or tostring(lib_or_err) }
    if ok then
      status.available = true
      status.backend = "sqlite"
      status.module_name = name
      status.error = nil
      M.sqlite = lib_or_err
      return true
    end
    errs[name] = tostring(lib_or_err)
  end

  -- 未導入: とりあえずUI警告だけ出して継続
  status.available = false
  status.backend = nil
  status.module_name = nil
  local lines = { "SQLite module not found (tried lsqlite3/lsqlite3complete/sqlite3)." }
  for _, name in ipairs(candidates) do
    local e = errs[name]
    if e and e ~= "" then
      lines[#lines + 1] = string.format("[%s] %s", name, e)
    end
  end
  status.error = table.concat(lines, "\n")
  return false
end

function M.get_status()
  return status
end

return M
