-- Test path bootstrap for Sample Lode Manager (no REAPER required).
local function repo_root()
  local info = debug.getinfo(1, "S")
  local src = info.source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  return src:match("^(.*)[/\\]tests[/\\]") or "."
end

local root = repo_root()
local slm = root .. "/SampleLodeManager"
package.path = package.path
  .. ";" .. slm .. "/src/?.lua"
  .. ";" .. slm .. "/src/lib/?.lua"
  .. ";" .. slm .. "/src/lib/*/?.lua"

return { repo_root = root, slm_root = slm }
