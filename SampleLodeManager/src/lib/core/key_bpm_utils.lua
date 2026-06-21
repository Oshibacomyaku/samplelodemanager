-- @noindex
-- Key / BPM / sample-type string helpers (no ImGui, no global state).
local M = {}

M.KEY_ROOT_OPTIONS = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

M.KEY_SHARP_TO_FLAT = {
  ["C#"] = "Db",
  ["D#"] = "Eb",
  ["F#"] = "Gb",
  ["G#"] = "Ab",
  ["A#"] = "Bb",
}

function M.parse_sample_bpm(value)
  local bpm = tonumber(value)
  if not bpm or bpm <= 0 then return nil end
  if bpm < 20 or bpm > 400 then return nil end
  return bpm
end

function M.normalize_key_root_text(root_raw)
  local root = tostring(root_raw or ""):upper():gsub("^%s+", ""):gsub("%s+$", "")
  local flat_to_sharp = {
    DB = "C#", EB = "D#", GB = "F#", AB = "G#", BB = "A#",
  }
  if flat_to_sharp[root] then return flat_to_sharp[root] end
  for _, k in ipairs(M.KEY_ROOT_OPTIONS) do
    if root == k then return k end
  end
  return nil
end

function M.key_root_dual_label(root_raw)
  local sharp = M.normalize_key_root_text(root_raw)
  if not sharp then return nil end
  local flat = M.KEY_SHARP_TO_FLAT[sharp]
  if flat then
    return sharp .. " / " .. flat
  end
  return sharp
end

function M.format_key_text_dual(key_text, compact_mode)
  local txt = tostring(key_text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if txt == "" then return "" end
  local root_raw = txt:match("^([A-Ga-g][#bB]?)")
  local root_dual = M.key_root_dual_label(root_raw)
  if not root_dual then return txt end
  local suffix = txt:sub(#tostring(root_raw) + 1):gsub("^%s+", "")
  if compact_mode then
    suffix = suffix:gsub("%f[%a][Mm][Aa][Jj][Oo][Rr]%f[%A]", "maj")
    suffix = suffix:gsub("%f[%a][Mm][Ii][Nn][Oo][Rr]%f[%A]", "min")
  end
  if suffix ~= "" then
    return root_dual .. " " .. suffix
  end
  return root_dual
end

function M.parse_edit_key_parts(key_text)
  local txt = tostring(key_text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if txt == "" then return nil, "none" end
  local up = txt:upper()
  local root = up:match("^([A-G][#B]?)")
  root = M.normalize_key_root_text(root)
  local low = txt:lower()
  local mode = "none"
  if low:find("minor", 1, true) or low:find(" min", 1, true) then
    mode = "minor"
  elseif low:find("major", 1, true) or low:find(" maj", 1, true) then
    mode = "major"
  end
  return root, mode
end

function M.build_edit_key_text(root, mode)
  local rtxt = M.normalize_key_root_text(root)
  if not rtxt then return nil end
  if mode == "major" then return rtxt .. " major" end
  if mode == "minor" then return rtxt .. " minor" end
  return rtxt
end

function M.normalize_sample_type(value)
  local t = tostring(value or ""):lower()
  if t == "oneshot" or t == "one-shot" or t == "oneshots" then
    return "oneshot"
  end
  if t == "loop" or t == "loops" then
    return "loop"
  end
  return nil
end

return M
