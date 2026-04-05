-- @description Sample Lode Manager
-- @version 0.2.3
-- @author oshibacomyaku
-- @changelog 0.2.3: ReaPack 配布が古いコミットを指さないよう index を更新。メインウィンドウは初回のみ SetNextWindowSize（毎フレーム固定をやめ undocked 時のリサイズグリップ復活）。
-- @about Sample browser and manager for REAPER. Requires ReaImGui (REAPER 7+ / Lua 5.4). Optional Python workers are bundled. Bundled SQLite bindings (lsqlite3complete): MIT — see licenses/lsqlite3complete_LICENSE.txt. SQLite engine: public domain — see licenses/sqlite_PUBLIC_DOMAIN.txt. Layout: bin/README.md.
-- @provides [main] oshibacomyaku_Sample Lode Manager.lua
-- @provides [nomain] src/**/*.lua
-- @provides [nomain] src/python/**/*.py
-- @provides [nomain] licenses/*.txt
-- @provides [win64 nomain] bin/win64/lsqlite3complete.dll
-- @provides [darwin64 nomain] bin/darwin64/lsqlite3complete.so
-- @provides [darwin-arm64 nomain] bin/darwin-arm64/lsqlite3complete.so
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

-- SQLite native modules (lsqlite3 / lsqlite3complete / sqlite3): prepend OS-specific bundle dir first.
-- Layout (Lua 5.4 / REAPER 7+): bin/win64/, bin/darwin64/, bin/darwin-arm64/ — see bin/README.md.
local function bundled_lsqlite_cpath_prefix()
  local gv = ""
  if r.GetAppVersion then
    gv = tostring(r.GetAppVersion() or ""):lower()
  end
  local sub, pat
  if gv:find("macos%-arm64", 1) then
    sub, pat = "bin/darwin-arm64/", "?.so"
  elseif gv:find("osx64", 1) then
    sub, pat = "bin/darwin64/", "?.so"
  elseif gv:find("/x64", 1) then
    sub, pat = "bin/win64/", "?.dll"
  elseif gv:match("^%d+%.%d+$") then
    -- e.g. "7.67" without arch suffix => 32-bit Windows (ReaScript docs)
    sub, pat = "bin/win32/", "?.dll"
  elseif gv:find("linux", 1) then
    if gv:find("aarch64", 1) then
      sub, pat = "bin/linux-aarch64/", "?.so"
    else
      sub, pat = "bin/linux-x86_64/", "?.so"
    end
  end
  if sub then
    return script_path .. sub .. pat
  end
  return nil
end

do
  local prefix = bundled_lsqlite_cpath_prefix()
  local base = package.cpath or ""
  if prefix then
    package.cpath = prefix .. ";" .. base
  else
    package.cpath = base
  end
  package.cpath = package.cpath
    .. ";" .. script_path .. "bin/?.dll"
    .. ";" .. script_path .. "bin/?.so"
    .. ";" .. script_path .. "?.dll"
    .. ";" .. script_path .. "?.so"
end

-- LuaRocks-installed modules (e.g. lsqlite3complete) need their own path additions.
do
  local lua_ver = (_VERSION or ""):match("(%d+%.%d+)") or "5.4"
  local appdata = os.getenv("APPDATA") or ""
  if appdata ~= "" then
    local luarocks_root = appdata .. "/luarocks"
    package.path = package.path
      .. ";" .. luarocks_root .. "/share/lua/" .. lua_ver .. "/?.lua"
      .. ";" .. luarocks_root .. "/share/lua/" .. lua_ver .. "/?/init.lua"
    package.cpath = package.cpath
      .. ";" .. luarocks_root .. "/lib/lua/" .. lua_ver .. "/?.dll"
  end
  local unix = package.config and package.config:sub(1, 1) == "/"
  if unix then
    local home = os.getenv("HOME") or ""
    if home ~= "" then
      local luarocks_root = home .. "/.luarocks"
      package.path = package.path
        .. ";" .. luarocks_root .. "/share/lua/" .. lua_ver .. "/?.lua"
        .. ";" .. luarocks_root .. "/share/lua/" .. lua_ver .. "/?/init.lua"
      package.cpath = package.cpath
        .. ";" .. luarocks_root .. "/lib/lua/" .. lua_ver .. "/?.so"
    end
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
