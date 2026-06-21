-- @noindex
-- REAPER ExtState helpers (section-scoped).
local M = {}

function M.get_extstate_text(rr, section, key)
  if not rr or not rr.GetExtState then return "" end
  local sec = tostring(section or "")
  local k = tostring(key or "")
  if sec == "" or k == "" then return "" end
  local v = rr.GetExtState(sec, k)
  if not v then return "" end
  return tostring(v)
end

function M.set_extstate_text(rr, section, key, value, persist)
  if not rr or not rr.SetExtState then return end
  local sec = tostring(section or "")
  local k = tostring(key or "")
  if sec == "" or k == "" then return end
  rr.SetExtState(sec, k, tostring(value or ""), persist == true)
end

function M.get_extstate_bool(rr, section, key, default_value)
  local raw = M.get_extstate_text(rr, section, key)
  if raw == "" then return default_value == true end
  raw = raw:lower()
  if raw == "1" or raw == "true" then return true end
  if raw == "0" or raw == "false" then return false end
  return default_value == true
end

function M.get_extstate_number(rr, section, key)
  local raw = M.get_extstate_text(rr, section, key)
  if raw == "" then return nil end
  return tonumber(raw)
end

function M.get_persisted_splice_db_path(rr, section, splice_db_key)
  return M.get_extstate_text(rr, section, splice_db_key)
end

function M.set_persisted_splice_db_path(rr, section, splice_db_key, path_text)
  M.set_extstate_text(rr, section, splice_db_key, tostring(path_text or ""), true)
end

function M.get_persisted_splice_relink_roots(rr, section, relink_key)
  if not rr or not rr.GetExtState then return {} end
  local sec = tostring(section or "")
  local k = tostring(relink_key or "")
  if sec == "" or k == "" then return {} end
  local raw = tostring(rr.GetExtState(sec, k) or "")
  if raw == "" then return {} end
  local out = {}
  for line in string.gmatch(raw, "[^\r\n]+") do
    line = tostring(line):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

function M.set_persisted_splice_relink_roots(rr, section, relink_key, paths_tbl)
  if not rr or not rr.SetExtState then return end
  local sec = tostring(section or "")
  local k = tostring(relink_key or "")
  if sec == "" or k == "" then return end
  local lines = {}
  for _, p in ipairs(paths_tbl or {}) do
    local s = tostring(p or ""):gsub("\r", ""):gsub("\n", "")
    if s ~= "" then lines[#lines + 1] = s end
  end
  rr.SetExtState(sec, k, table.concat(lines, "\n"), true)
end

return M
