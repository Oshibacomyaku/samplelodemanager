-- @noindex
-- Python batch workers for phase A/B2/C/D/E and auto-alias suggestion.
local M = {}

local tag_inference = nil
do
  local ok, mod = pcall(require, "lib.db.tag_inference")
  if ok then tag_inference = mod end
end

local r = nil
local resource_paths = nil
local sep = nil
local exec_safe = nil
local sql_quote = nil

function M.setup(deps)
  deps = type(deps) == "table" and deps or {}
  r = deps.r
  resource_paths = deps.resource_paths
  sep = deps.sep or package.config:sub(1, 1)
  exec_safe = deps.exec_safe
  sql_quote = deps.sql_quote
end

-- Safety default: Phase C audio rerank is expensive when called per-sample.
-- Keep disabled unless reworked to true batch/incremental processing.
local ENABLE_PHASE_C_AUDIO_RERANK = false
-- UMAP feature preset for quick experimentation.
-- "core5" | "no_mfcc" | "no_tonal" | "with_flatness" | "spectral_only" | "envelope_only"
local PHASE_E_PRESET = "core5"
local PHASE_E_PRESET_ALLOWED = {
  core5 = true,
  no_mfcc = true,
  no_tonal = true,
  with_flatness = true,
  spectral_only = true,
  envelope_only = true,
}
-- Min count of numeric (non-nil) fields in the 10-vector to send a row to phase_e (1 = effectively off).
local PHASE_E_MIN_VALID_FEATURES = 1
local PHASE_E_NEAR_NEUTRAL_EPS = 0.03
local PHASE_E_NEAR_NEUTRAL_MIN_COUNT = 8
local PHASE_E_LAST_INFO = {
  mode = "unknown",
  rows = 0,
  dims = 0,
  dropped_low_valid = 0,
  dropped_near_neutral = 0,
  excluded_low_valid_ids = "",
  excluded_near_neutral_ids = "",
  min_valid_used = 0,
}
local GALAXY_EMBED_PROFILE_VARIANTS = {
  { key = "balanced", umap_neighbors = 48, umap_min_dist = 0.30 },
}
local function work_paths(stem)
  if resource_paths then
    return resource_paths.work_pair(r, stem)
  end
  local base = r.GetResourcePath() .. sep .. "SampleLodeManager_" .. stem
  return { in_path = base .. "_in.tsv", out_path = base .. "_out.tsv" }
end

local function cleanup_work_files(paths)
  if resource_paths then
    resource_paths.remove_paths(paths)
  end
end
function M.get_python_phase_a_script_path()
  local src = debug.getinfo(1, "S")
  local source = src and src.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  if source == "" then return nil end
  local dir = source:gsub("[/\\][^/\\]+$", "")
  if dir == "" then return nil end
  return dir .. sep .. ".." .. sep .. ".." .. sep .. "python" .. sep .. "phase_a_filename_nlp.py"
end

function M.get_python_phase_b2_script_path()
  local src = debug.getinfo(1, "S")
  local source = src and src.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  if source == "" then return nil end
  local dir = source:gsub("[/\\][^/\\]+$", "")
  if dir == "" then return nil end
  return dir .. sep .. ".." .. sep .. ".." .. sep .. "python" .. sep .. "phase_b2_audio_hints.py"
end

function M.get_python_auto_alias_script_path()
  local src = debug.getinfo(1, "S")
  local source = src and src.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  if source == "" then return nil end
  local dir = source:gsub("[/\\][^/\\]+$", "")
  if dir == "" then return nil end
  return dir .. sep .. ".." .. sep .. ".." .. sep .. "python" .. sep .. "auto_alias_suggest.py"
end

function M.get_python_phase_c_script_path()
  local src = debug.getinfo(1, "S")
  local source = src and src.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  if source == "" then return nil end
  local dir = source:gsub("[/\\][^/\\]+$", "")
  if dir == "" then return nil end
  return dir .. sep .. ".." .. sep .. ".." .. sep .. "python" .. sep .. "phase_c_rerank.py"
end

function M.get_python_phase_d_script_path()
  local src = debug.getinfo(1, "S")
  local source = src and src.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  if source == "" then return nil end
  local dir = source:gsub("[/\\][^/\\]+$", "")
  if dir == "" then return nil end
  return dir .. sep .. ".." .. sep .. ".." .. sep .. "python" .. sep .. "phase_d_audio_features.py"
end

function M.get_python_phase_e_script_path()
  local src = debug.getinfo(1, "S")
  local source = src and src.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  if source == "" then return nil end
  local dir = source:gsub("[/\\][^/\\]+$", "")
  if dir == "" then return nil end
  return dir .. sep .. ".." .. sep .. ".." .. sep .. "python" .. sep .. "phase_e_embed_umap.py"
end
local function split_csv_simple(text)
  local out = {}
  local s = tostring(text or "")
  if s == "" then return out end
  for token in s:gmatch("([^,]+)") do
    local t = token:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end
function M.run_python_auto_alias_batch(unknown_tokens, splice_vocab)
  local out = {}
  if type(unknown_tokens) ~= "table" or #unknown_tokens == 0 then return out end
  if type(splice_vocab) ~= "table" or next(splice_vocab) == nil then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = M.get_python_auto_alias_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local in_path = (resource_paths and resource_paths.work_file(r, "auto_alias", "_unknown.tsv"))
    or (r.GetResourcePath() .. sep .. "SampleLodeManager_auto_alias_unknown.tsv")
  local vocab_path = (resource_paths and resource_paths.work_file(r, "auto_alias", "_vocab.tsv"))
    or (r.GetResourcePath() .. sep .. "SampleLodeManager_auto_alias_vocab.tsv")
  local out_path = (resource_paths and resource_paths.work_file(r, "auto_alias", "_out.tsv"))
    or (r.GetResourcePath() .. sep .. "SampleLodeManager_auto_alias_out.tsv")

  local f1 = io.open(in_path, "wb")
  if not f1 then return out end
  for _, tok in ipairs(unknown_tokens) do
    f1:write(tostring(tok), "\n")
  end
  f1:close()

  local f2 = io.open(vocab_path, "wb")
  if not f2 then return out end
  for tag, _cnt in pairs(splice_vocab) do
    f2:write(tostring(tag), "\n")
  end
  f2:close()

  local cmd = string.format('python "%s" --unknown "%s" --vocab "%s" --output "%s"', script, in_path, vocab_path, out_path)
  local ok_exec, _ = pcall(function()
    return r.ExecProcess(cmd, 10000)
  end)
  if not ok_exec then
    cleanup_work_files({ in_path, vocab_path, out_path })
    return out
  end

  local rf = io.open(out_path, "rb")
  if not rf then
    cleanup_work_files({ in_path, vocab_path, out_path })
    return out
  end
  for line in rf:lines() do
    local alias, canon, conf = line:match("^([^\t]+)\t([^\t]+)\t([%d%.]+)$")
    local c = tonumber(conf or "")
    if alias and canon and c then
      out[#out + 1] = { alias = alias, canonical = canon, confidence = c }
    end
  end
  rf:close()
  cleanup_work_files({ in_path, vocab_path, out_path })
  return out
end

function M.apply_auto_alias_rows(db, rows)
  if not db or type(rows) ~= "table" or #rows == 0 then return 0 end
  local now = os.time()
  local changed = 0
  for _, row in ipairs(rows) do
    local a = tostring(row.alias or ""):lower()
    local c = tostring(row.canonical or ""):lower()
    local conf = tonumber(row.confidence or 0) or 0
    if a ~= "" and c ~= "" and conf >= 0.82 then
      exec_safe(db, string.format([[
        INSERT OR IGNORE INTO tag_aliases(alias, canonical_tag, source, created_at, confidence, last_used_at, enabled)
        VALUES(%s, %s, 'auto', %d, %s, %d, 1);
      ]], sql_quote(a), sql_quote(c), now, tostring(conf), now))
      exec_safe(db, string.format([[
        UPDATE tag_aliases
        SET canonical_tag=%s, confidence=%s, last_used_at=%d, enabled=1
        WHERE alias=%s AND source='auto';
      ]], sql_quote(c), tostring(conf), now, sql_quote(a)))
      changed = changed + 1
    end
  end
  return changed
end

local function to_set(list)
  local s = {}
  for _, v in ipairs(list or {}) do
    s[v] = true
  end
  return s
end

local function jaccard_tokens(a, b)
  local sa = to_set(a)
  local sb = to_set(b)
  local inter, uni = 0, 0
  for k, _ in pairs(sa) do
    uni = uni + 1
    if sb[k] then inter = inter + 1 end
  end
  for k, _ in pairs(sb) do
    if not sa[k] then uni = uni + 1 end
  end
  if uni == 0 then return 0 end
  return inter / uni
end

function M.run_python_phase_a_batch(rows, pack_name)
  local out = {}
  if type(rows) ~= "table" or #rows == 0 then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = M.get_python_phase_a_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local pair = work_paths("phase_a")
  local in_path = pair.in_path
  local out_path = pair.out_path
  local f = io.open(in_path, "wb")
  if not f then return out end
  for i, row in ipairs(rows) do
    local fn = tostring((row and row.filename) or ""):gsub("[\t\r\n]", " ")
    local fp = tostring((row and row.full_path) or ""):gsub("[\t\r\n]", " ")
    local pk = tostring(pack_name or ""):gsub("[\t\r\n]", " ")
    f:write(tostring(i), "\t", fn, "\t", fp, "\t", pk, "\n")
  end
  f:close()

  local cmd = string.format('python "%s" --input "%s" --output "%s"', script, in_path, out_path)
  local ok_exec, _ = pcall(function()
    return r.ExecProcess(cmd, 8000)
  end)
  if not ok_exec then
    cleanup_work_files({ in_path, out_path })
    return out
  end

  local rf = io.open(out_path, "rb")
  if not rf then
    cleanup_work_files({ in_path, out_path })
    return out
  end
  for line in rf:lines() do
    local idx_text, tags_csv = line:match("^(%d+)\t(.*)$")
    local idx = tonumber(idx_text or "")
    if idx and idx > 0 then
      out[idx] = split_csv_simple(tags_csv)
    end
  end
  rf:close()
  cleanup_work_files({ in_path, out_path })
  return out
end

function M.run_python_phase_b2_batch(rows, pack_name)
  local out = {}
  if type(rows) ~= "table" or #rows == 0 then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = M.get_python_phase_b2_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local pair = work_paths("phase_b2")
  local in_path = pair.in_path
  local out_path = pair.out_path
  local f = io.open(in_path, "wb")
  if not f then return out end
  for i, row in ipairs(rows) do
    local fn = tostring((row and row.filename) or ""):gsub("[\t\r\n]", " ")
    local fp = tostring((row and row.full_path) or ""):gsub("[\t\r\n]", " ")
    local pk = tostring(pack_name or ""):gsub("[\t\r\n]", " ")
    f:write(tostring(i), "\t", fn, "\t", fp, "\t", pk, "\n")
  end
  f:close()

  local cmd = string.format('python "%s" --input "%s" --output "%s"', script, in_path, out_path)
  local ok_exec, _ = pcall(function()
    return r.ExecProcess(cmd, 10000)
  end)
  if not ok_exec then
    cleanup_work_files({ in_path, out_path })
    return out
  end

  local rf = io.open(out_path, "rb")
  if not rf then
    cleanup_work_files({ in_path, out_path })
    return out
  end
  for line in rf:lines() do
    local idx_text, tags_csv = line:match("^(%d+)\t(.*)$")
    local idx = tonumber(idx_text or "")
    if idx and idx > 0 then
      out[idx] = split_csv_simple(tags_csv)
    end
  end
  rf:close()
  cleanup_work_files({ in_path, out_path })
  return out
end

function M.run_python_phase_d_batch(rows, pack_name)
  local out = {}
  if type(rows) ~= "table" or #rows == 0 then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = M.get_python_phase_d_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local pair = work_paths("phase_d")
  local in_path = pair.in_path
  local out_path = pair.out_path
  local f = io.open(in_path, "wb")
  if not f then return out end
  local wrote = 0
  for i, row in ipairs(rows) do
    if row and row.skip_phase_d == true then
      goto continue
    end
    if not (row and row.force_phase_d == true) then
      -- Speed mode: analyze only one-shot candidates, skip likely loops.
      local fn_for_guess = tostring((row and row.filename) or "")
      local g = tag_inference and tag_inference.guess_type_and_bpm_and_key(fn_for_guess)
      local class_guess = g and tostring(g.class_primary or ""):lower() or ""
      if class_guess ~= "oneshot" then
        goto continue
      end
    end
    local fn = tostring((row and row.filename) or ""):gsub("[\t\r\n]", " ")
    local fp = tostring((row and row.full_path) or ""):gsub("[\t\r\n]", " ")
    local pk = tostring(pack_name or ""):gsub("[\t\r\n]", " ")
    f:write(tostring(i), "\t", fn, "\t", fp, "\t", pk, "\n")
    wrote = wrote + 1
    ::continue::
  end
  f:close()
  if wrote == 0 then return out end

  local cmd = string.format('python "%s" --input "%s" --output "%s"', script, in_path, out_path)
  local ok_exec, _ = pcall(function()
    -- Spectral feature extraction over large libraries can take several minutes.
    return r.ExecProcess(cmd, 900000)
  end)
  if not ok_exec then
    cleanup_work_files({ in_path, out_path })
    return out
  end

  local rf = io.open(out_path, "rb")
  if not rf then
    cleanup_work_files({ in_path, out_path })
    return out
  end
  for line in rf:lines() do
    local clean = tostring(line or ""):gsub("\r$", "")
    local idx_t, b_t, n_t, a_t, d_t, t_t, c_t, r_t, bw_t, fl_t, mf_t, inh_t, met_t =
      clean:match("^(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
    if not idx_t then
      -- Backward compatibility: old phase_d output (idx + 10 values).
      idx_t, b_t, n_t, a_t, d_t, t_t, c_t, r_t, bw_t, fl_t, mf_t =
      clean:match("^(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
    end
    local idx = tonumber(idx_t or "")
    if idx and idx > 0 then
      local b = tonumber(b_t or "")
      local n = tonumber(n_t or "")
      local a = tonumber(a_t or "")
      local d = tonumber(d_t or "")
      local t = tonumber(t_t or "")
      local c = tonumber(c_t or "")
      local r0 = tonumber(r_t or "")
      local bw = tonumber(bw_t or "")
      local fl = tonumber(fl_t or "")
      local mf = tonumber(mf_t or "")
      local inh = tonumber(inh_t or "")
      local met = tonumber(met_t or "")
      out[idx] = {
        brightness = b,
        noisiness = n,
        attack_sharpness = a,
        decay_length = d,
        tonalness = t,
        spectral_centroid_norm = c,
        spectral_rolloff_norm = r0,
        spectral_bandwidth_norm = bw,
        spectral_flatness = fl,
        mfcc_timbre_norm = mf,
        inharmonicity = inh,
        metallicity = met,
      }
    end
  end
  rf:close()
  cleanup_work_files({ in_path, out_path })
  return out
end

function M.table_count_keys(t)
  if type(t) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local PHASE_D_FEATURE_KEYS = {
  "brightness", "noisiness", "attack_sharpness", "decay_length", "tonalness",
  "spectral_centroid_norm", "spectral_rolloff_norm", "spectral_bandwidth_norm", "spectral_flatness", "mfcc_timbre_norm",
}

function M.phase_d_row_complete(feat)
  if type(feat) ~= "table" then return false end
  for _, k in ipairs(PHASE_D_FEATURE_KEYS) do
    if tonumber(feat[k]) == nil then return false end
  end
  return true
end

function M.get_existing_phase_d_for_entries(db, entries)
  local out = {}
  if not db or type(entries) ~= "table" then return out end
  for i, e in ipairs(entries) do
    local sid = tonumber(e and e.sample_id)
    if sid and sid > 0 then
      for row in db:nrows(string.format([[
        SELECT brightness, noisiness, attack_sharpness, decay_length, tonalness,
               spectral_centroid_norm, spectral_rolloff_norm, spectral_bandwidth_norm, spectral_flatness,
               mfcc_timbre_norm
        FROM analysis WHERE sample_id=%d LIMIT 1;
      ]], sid)) do
        out[i] = {
          brightness = row.brightness or row[1],
          noisiness = row.noisiness or row[2],
          attack_sharpness = row.attack_sharpness or row[3],
          decay_length = row.decay_length or row[4],
          tonalness = row.tonalness or row[5],
          spectral_centroid_norm = row.spectral_centroid_norm or row[6],
          spectral_rolloff_norm = row.spectral_rolloff_norm or row[7],
          spectral_bandwidth_norm = row.spectral_bandwidth_norm or row[8],
          spectral_flatness = row.spectral_flatness or row[9],
          mfcc_timbre_norm = row.mfcc_timbre_norm or row[10],
        }
        break
      end
    end
  end
  return out
end

function M.run_python_phase_e_batch(phase_d_by_index, pe_opts)
  pe_opts = type(pe_opts) == "table" and pe_opts or {}
  local min_valid_needed = tonumber(pe_opts.min_valid_features) or PHASE_E_MIN_VALID_FEATURES
  if min_valid_needed < 1 then min_valid_needed = 1 end
  if min_valid_needed > 10 then min_valid_needed = 10 end
  -- Off unless opts explicitly set exclude_near_neutral = true (legacy strict mode).
  local exclude_near_neutral = pe_opts.exclude_near_neutral == true
  local near_eps = tonumber(pe_opts.near_neutral_eps) or PHASE_E_NEAR_NEUTRAL_EPS
  local near_min_count = tonumber(pe_opts.near_neutral_min_count) or PHASE_E_NEAR_NEUTRAL_MIN_COUNT
  local max_excluded_ids = math.max(1, math.min(24, tonumber(pe_opts.max_excluded_ids) or 8))
  local umap_neighbors = math.floor(tonumber(pe_opts.umap_neighbors) or 0)
  local umap_min_dist = tonumber(pe_opts.umap_min_dist) or -1.0

  local out = {}
  if type(phase_d_by_index) ~= "table" then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = M.get_python_phase_e_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local pair = work_paths("phase_e")
  local in_path = pair.in_path
  local out_path = pair.out_path
  local meta_path = (resource_paths and resource_paths.work_file(r, "phase_e", "_meta.txt"))
    or (r.GetResourcePath() .. sep .. "SampleLodeManager_phase_e_meta.txt")
  local f = io.open(in_path, "wb")
  if not f then return out end
  local dropped_low_valid = 0
  local dropped_near_neutral = 0
  local dropped_low_ids = {}
  local dropped_nn_ids = {}
  for idx, feat in pairs(phase_d_by_index) do
    local idn = tonumber(idx)
    if idn then
      local valid = 0
      local function pick(v)
        local n = tonumber(v)
        if n ~= nil then valid = valid + 1 end
        return n
      end
      local b0 = pick(feat and feat.brightness)
      local n0 = pick(feat and feat.noisiness)
      local a0 = pick(feat and feat.attack_sharpness)
      local d0 = pick(feat and feat.decay_length)
      local t0 = pick(feat and feat.tonalness)
      local c0 = pick(feat and feat.spectral_centroid_norm)
      local r00 = pick(feat and feat.spectral_rolloff_norm)
      local bw0 = pick(feat and feat.spectral_bandwidth_norm)
      local fl0 = pick(feat and feat.spectral_flatness)
      local mf0 = pick(feat and feat.mfcc_timbre_norm)
      if valid < min_valid_needed then
        dropped_low_valid = dropped_low_valid + 1
        if #dropped_low_ids < max_excluded_ids then
          dropped_low_ids[#dropped_low_ids + 1] = idn
        end
        goto continue
      end
      -- Fill missing values with neutral defaults to avoid dropping rows.
      local b = b0 or 0.5
      local n = n0 or 0.5
      local a = a0 or 0.5
      local d = d0 or 0.5
      local t = t0 or 0.5
      local c = c0 or 0.5
      local r0 = r00 or c
      local bw = bw0 or n
      local fl = fl0 or n
      local mf = mf0 or 0.5
      local near = 0
      for _, v in ipairs({ b, n, a, d, t, c, r0, bw, fl, mf }) do
        if math.abs(tonumber(v) - 0.5) < near_eps then
          near = near + 1
        end
      end
      if exclude_near_neutral and near >= near_min_count then
        dropped_near_neutral = dropped_near_neutral + 1
        if #dropped_nn_ids < max_excluded_ids then
          dropped_nn_ids[#dropped_nn_ids + 1] = idn
        end
        goto continue
      end
      -- Pass full 10-feature vector; phase_e preset selects subset.
      -- [brightness, noisiness, attack, decay, tonalness, centroid, rolloff, bandwidth, flatness, mfcc]
      f:write(string.format(
        "%d\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\n",
        idn, b, n, a, d, t, c, r0, bw, fl, mf
      ))
    end
    ::continue::
  end
  f:close()

  -- Prevent stale output reuse when python fails.
  pcall(function() os.remove(out_path) end)
  pcall(function() os.remove(meta_path) end)
  local cmd = string.format(
    'python "%s" --input "%s" --output "%s" --preset "%s" --meta "%s" --neighbors %d --min-dist %s',
    script, in_path, out_path, tostring(PHASE_E_PRESET or "core5"), meta_path, umap_neighbors, tostring(umap_min_dist)
  )
  local ok_exec, _ = pcall(function()
    -- UMAP import/JIT can also be slow on large inputs.
    return r.ExecProcess(cmd, 600000)
  end)
  if not ok_exec then
    cleanup_work_files({ in_path, out_path, meta_path })
    return out
  end

  PHASE_E_LAST_INFO = {
    mode = "unknown",
    rows = 0,
    dims = 0,
    dropped_low_valid = dropped_low_valid,
    dropped_near_neutral = dropped_near_neutral,
    excluded_low_valid_ids = table.concat(dropped_low_ids, ","),
    excluded_near_neutral_ids = table.concat(dropped_nn_ids, ","),
    min_valid_used = min_valid_needed,
  }
  local mf = io.open(meta_path, "rb")
  if mf then
    for line in mf:lines() do
      local k, v = tostring(line or ""):match("^([a-z_]+)=(.*)$")
      if k == "mode" then PHASE_E_LAST_INFO.mode = tostring(v or "unknown")
      elseif k == "rows" then PHASE_E_LAST_INFO.rows = tonumber(v or "") or 0
      elseif k == "dims" then PHASE_E_LAST_INFO.dims = tonumber(v or "") or 0
      end
    end
    mf:close()
  end

  local rf = io.open(out_path, "rb")
  if not rf then return out end
  for line in rf:lines() do
    line = tostring(line or ""):gsub("\r$", "")
    local idx_t, x_t, y_t = line:match("^(%d+)\t([%+%-]?[%d%.eE]+)\t([%+%-]?[%d%.eE]+)$")
    local idx = tonumber(idx_t or "")
    local x = tonumber(x_t or "")
    local y = tonumber(y_t or "")
    if idx and x and y then
      out[idx] = { embed_x = x, embed_y = y }
    end
  end
  rf:close()
  cleanup_work_files({ in_path, out_path, meta_path })
  return out
end

function M.run_python_phase_c_single(file_path, candidate_tags)
  local out = {}
  if not ENABLE_PHASE_C_AUDIO_RERANK then return out end
  if not file_path or tostring(file_path) == "" then return out end
  if type(candidate_tags) ~= "table" or #candidate_tags == 0 then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = M.get_python_phase_c_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local tags_path = (resource_paths and resource_paths.work_file(r, "phase_c", "_tags.tsv"))
    or (r.GetResourcePath() .. sep .. "SampleLodeManager_phase_c_tags.tsv")
  local out_path = (resource_paths and resource_paths.work_file(r, "phase_c", "_out.tsv"))
    or (r.GetResourcePath() .. sep .. "SampleLodeManager_phase_c_out.tsv")
  local f = io.open(tags_path, "wb")
  if not f then return out end
  for _, tg in ipairs(candidate_tags) do
    local t = tostring(tg or ""):gsub("[\t\r\n]", " ")
    if t ~= "" then f:write(t, "\n") end
  end
  f:close()

  local cmd = string.format(
    'python "%s" --audio "%s" --candidates "%s" --output "%s"',
    script,
    tostring(file_path):gsub('"', '\\"'),
    tags_path,
    out_path
  )
  local ok_exec, _ = pcall(function()
    return r.ExecProcess(cmd, 12000)
  end)
  if not ok_exec then
    cleanup_work_files({ tags_path, out_path })
    return out
  end

  local rf = io.open(out_path, "rb")
  if not rf then
    cleanup_work_files({ tags_path, out_path })
    return out
  end
  for line in rf:lines() do
    local tag, score = line:match("^([^\t]+)\t([%d%.%-]+)$")
    local sc = tonumber(score or "")
    if tag and sc then
      out[tostring(tag):lower()] = sc
    end
  end
  rf:close()
  cleanup_work_files({ tags_path, out_path })
  return out
end

function M.get_phase_d_feature_keys()
  return PHASE_D_FEATURE_KEYS
end

function M.set_phase_e_preset(preset)
  local p = tostring(preset or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if p == "" then return false, "empty preset" end
  if not PHASE_E_PRESET_ALLOWED[p] then
    return false, "invalid preset"
  end
  PHASE_E_PRESET = p
  return true
end

function M.get_phase_e_preset()
  return tostring(PHASE_E_PRESET or "core5")
end

function M.get_phase_e_last_info()
  return PHASE_E_LAST_INFO
end

function M.get_phase_e_min_valid_features()
  return PHASE_E_MIN_VALID_FEATURES
end

function M.get_galaxy_embed_profile_variants()
  return GALAXY_EMBED_PROFILE_VARIANTS
end

return M
