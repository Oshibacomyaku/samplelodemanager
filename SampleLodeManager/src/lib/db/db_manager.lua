-- @noindex
local M = {}

local status = {
  available = false,
  backend = nil, -- "sqlite" | "json" | nil
  module_name = nil,
  error = nil,
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
  -- まず SQLite を探す（候補は未確定なので複数）
  local candidates = { "lsqlite3", "lsqlite3complete", "sqlite3" }
  local errs = {}
  for _, name in ipairs(candidates) do
    local ok, lib_or_err = try_require(name)
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
  status.error = "SQLite module not found (tried lsqlite3/lsqlite3complete/sqlite3)."
  local last = errs[candidates[#candidates]] or nil
  if last and last ~= "" then
    status.error = status.error .. " Last error: " .. last
  end
  return false
end

function M.get_status()
  return status
end

return M

