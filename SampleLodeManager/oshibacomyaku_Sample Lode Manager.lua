-- @description Sample Lode Manager
-- @version 0.2.9
-- @author oshibacomyaku
-- @changelog 0.2.9: SQLite 起動診断・cpath 強化・配布モジュール追加（resource_paths 等）。0.2.8: src/python・licenses に @noindex（reapack-index --check 対象）。waveform.lua は @noindex を先頭に。0.2.7: @provides 明示一覧。0.2.6: src .lua @noindex。0.2.5: ImGui/ドック。0.2.4: index 列挙。
-- @about Sample browser and manager for REAPER. Requires ReaImGui (REAPER 7+ / Lua 5.4). Optional Python workers are bundled. Bundled SQLite bindings (lsqlite3complete): MIT — see licenses/lsqlite3complete_LICENSE.txt. SQLite engine: public domain — see licenses/sqlite_PUBLIC_DOMAIN.txt. Layout: bin/README.md.
-- @provides [main] oshibacomyaku_Sample Lode Manager.lua
-- @provides [nomain] src/lib/cover_art.lua
-- @provides [nomain] src/lib/core/app.lua
-- @provides [nomain] src/lib/core/scan_controller.lua
-- @provides [nomain] src/lib/core/ui_pack.lua
-- @provides [nomain] src/lib/core/ui_pack_manage_sources.lua
-- @provides [nomain] src/lib/core/ui_samples_galaxy.lua
-- @provides [nomain] src/lib/core/ui_samples_list.lua
-- @provides [nomain] src/lib/core/ui_search.lua
-- @provides [nomain] src/lib/core/ui_preview.lua
-- @provides [nomain] src/lib/core/ui_dnd.lua
-- @provides [nomain] src/lib/core/ui_edit_popup.lua
-- @provides [nomain] src/lib/core/resource_paths.lua
-- @provides [nomain] src/lib/core/ui_imgui_utils.lua
-- @provides [nomain] src/lib/core/ext_state.lua
-- @provides [nomain] src/lib/core/key_bpm_utils.lua
-- @provides [nomain] src/lib/core/ui_theme.lua
-- @provides [nomain] src/lib/db/db_manager.lua
-- @provides [nomain] src/lib/db/tag_inference.lua
-- @provides [nomain] src/lib/db/python_worker.lua
-- @provides [nomain] src/lib/db/sqlite_store.lua
-- @provides [nomain] src/lib/waveform.lua
-- @provides [nomain] src/python/auto_alias_suggest.py
-- @provides [nomain] src/python/phase_a_filename_nlp.py
-- @provides [nomain] src/python/phase_b2_audio_hints.py
-- @provides [nomain] src/python/phase_c_rerank.py
-- @provides [nomain] src/python/phase_d_audio_features.py
-- @provides [nomain] src/python/phase_e_embed_umap.py
-- @provides [nomain] licenses/lsqlite3complete_LICENSE.txt
-- @provides [nomain] licenses/sqlite_PUBLIC_DOMAIN.txt
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
  local os_name = ""
  if r.GetOS then
    os_name = tostring(r.GetOS() or ""):lower()
  end
  local sub, pat
  if gv:find("macos%-arm64", 1) or os_name:find("arm64", 1) or os_name:find("aarch64", 1) then
    sub, pat = "bin/darwin-arm64/", "?.so"
  elseif gv:find("osx64", 1) or os_name:find("osx", 1) or os_name:find("mac", 1) then
    sub, pat = "bin/darwin64/", "?.so"
  elseif gv:find("/x64", 1) or os_name:find("win64", 1) or os_name:find("x64", 1) then
    sub, pat = "bin/win64/", "?.dll"
  elseif gv:match("^%d+%.%d+$") then
    -- e.g. "7.67" without arch suffix — may be 32-bit Windows OR x64 build that omits /x64
    if os_name:find("win", 1) or package.config:sub(1, 1) == "\\" then
      sub, pat = "bin/win64/", "?.dll"
    else
      sub, pat = "bin/win32/", "?.dll"
    end
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

local function bundled_lsqlite_cpath_prefixes()
  local out = {}
  local primary = bundled_lsqlite_cpath_prefix()
  if primary then out[#out + 1] = primary end
  local os_name = ""
  if r.GetOS then os_name = tostring(r.GetOS() or ""):lower() end
  if os_name:find("win", 1) or package.config:sub(1, 1) == "\\" then
    local win64 = script_path .. "bin/win64/?.dll"
    local win32 = script_path .. "bin/win32/?.dll"
    if win64 ~= primary then out[#out + 1] = win64 end
    if win32 ~= primary then out[#out + 1] = win32 end
  end
  return out
end

do
  local prefixes = bundled_lsqlite_cpath_prefixes()
  local base = package.cpath or ""
  if #prefixes > 0 then
    package.cpath = table.concat(prefixes, ";") .. ";" .. base
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

-- v0.2.0 ユーザー対策: SQLite ネイティブモジュールが require できない場合のみ、
-- 起動直後に行動可能な案内を1回だけ MB で表示する（成功時は無音）。
-- 既存の Manage Sources の "SQLite backend unavailable." はそのまま残り、
-- このダイアログはユーザーが画面を開かなくても気づけるよう補助する役割。
local function diagnose_sqlite_load()
  local candidates = { "lsqlite3", "lsqlite3complete", "sqlite3" }
  local errs = {}
  for _, name in ipairs(candidates) do
    local ok_req = pcall(require, name)
    if ok_req then
      return nil
    end
    errs[#errs + 1] = string.format("  [%s] not found", name)
  end
  return table.concat(errs, "\n")
end

do
  local err_summary = diagnose_sqlite_load()
  if err_summary then
    local expected_dll = script_path .. "bin/win64/lsqlite3complete.dll"
    local lines = {
      "Sample Lode Manager: SQLite native module is missing.",
      "Database features (Manage Sources, Splice import, External roots) will be disabled.",
      "",
      "Recommended action:",
      "  1) REAPER -> Extensions -> ReaPack -> Browse packages...",
      "     Update 'Sample Lode Manager' to v0.2.7+ (DLL is bundled).",
      "  2) If updated and still failing, confirm this file exists:",
      "       " .. expected_dll,
      "",
      "Tried modules:",
      err_summary,
      "",
      "(OK で続行します。Manage Sources に詳しいエラーが表示されます。)",
    }
    local body = table.concat(lines, "\n")
    r.ShowConsoleMsg("[Sample Lode Manager] SQLite load diagnostic:\n" .. body .. "\n")
    r.MB(body, "Sample Lode Manager: SQLite module missing", 0)
  end
end

local ok, app = pcall(require, "lib.core.app")
if not ok then
  r.ShowConsoleMsg("Failed to load app module: " .. tostring(app) .. "\n")
  r.MB("App module missing: lib.core.app", "Error", 0)
  return
end

app.run()
