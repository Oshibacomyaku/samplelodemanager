-- @description Sample Lode Manager
-- @version 0.2.0
-- @author motit
-- @changelog Prepare ReaPack distribution metadata.
-- @about Sample browser and manager for REAPER. Requires ReaImGui. Optional Python workers are bundled.
-- @provides [main] SampleLodeManager.lua
-- @provides [nomain] src/**/*.lua
-- @provides [nomain] src/python/**/*.py
-- @provides [nomain] licenses/*.txt
-- Sample Lode Manager

local r = reaper

local function get_script_path()
  local info = debug.getinfo(1, "S")
  local src = info.source
  -- src looks like "@C:\\path\\file.lua"
  return src:match[[^@?(.*[\/\\])[^\/\\]-$]] or src:match[[^@?(.*[\/\\]).*]] or ""
end

local script_path = get_script_path()
if script_path == "" then script_path = r.get_action_context and r.GetResourcePath() or "" end

-- ReaImGui dependency check
if not r.ImGui_GetBuiltinPath then
  if r.APIExists("ReaPack_BrowsePackages") then
    r.ReaPack_BrowsePackages("ReaImGui: ReaScript binding for Dear ImGui")
  end
  r.MB("ReaImGui is not installed or is out of date. Please install/update via ReaPack.", "Missing Dependency", 0)
  return
end

-- Allow requiring local modules
local package_builtin = r.ImGui_GetBuiltinPath()
package.path = package.path
  .. ";" .. script_path .. "src/?.lua"
  .. ";" .. script_path .. "src/lib/?.lua"
  .. ";" .. script_path .. "src/lib/*/?.lua"
  .. ";" .. package_builtin .. "/?.lua"

-- SQLite native modules (lsqlite3/sqlite3) may require DLL lookup via package.cpath.
-- If you place lsqlite3.dll / sqlite3.dll under ./bin, this will allow `require()` to find it.
package.cpath = package.cpath
  .. ";" .. script_path .. "bin/?.dll"
  .. ";" .. script_path .. "?.dll"

-- LuaRocks-installed modules (e.g. lsqlite3complete) need their own path additions.
do
  local appdata = os.getenv("APPDATA") or ""
  local lua_ver = (_VERSION or ""):match("(%d+%.%d+)") or "5.4"
  if appdata ~= "" then
    local luarocks_root = appdata .. "/luarocks"
    package.path = package.path
      .. ";" .. luarocks_root .. "/share/lua/" .. lua_ver .. "/?.lua"
      .. ";" .. luarocks_root .. "/share/lua/" .. lua_ver .. "/?/init.lua"
    package.cpath = package.cpath
      .. ";" .. luarocks_root .. "/lib/lua/" .. lua_ver .. "/?.dll"
  end
end

-- ReaImGui shim: optional
local ImGui = nil
if package_builtin and package_builtin ~= "" then
  package.path = package.path .. ";" .. package_builtin .. "/?.lua"
  local ok, imgui_mod = pcall(function() return require("imgui") end)
  if ok then ImGui = imgui_mod end
end

local ok_co, cover_art_mod = pcall(require, "lib.cover_art")
if ok_co and cover_art_mod and cover_art_mod.init then
  cover_art_mod.init(script_path)
end

local ok, app = pcall(require, "lib.core.app")
if not ok then
  r.ShowConsoleMsg("Failed to load app module: " .. tostring(app) .. "\n")
  r.MB("App module missing: lib.core.app", "Error", 0)
  return
end

app.run()

