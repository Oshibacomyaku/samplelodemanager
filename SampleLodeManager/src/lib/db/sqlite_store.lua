local r = reaper

local M = {}

local sep = package.config:sub(1, 1)
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

local function sql_quote(str)
  if str == nil then return "NULL" end
  str = tostring(str)
  -- Escape single quotes for SQLite string literals
  return "'" .. str:gsub("'", "''") .. "'"
end

local function sanitize_root_path(root_path)
  if root_path == nil then return nil end
  local s = tostring(root_path)
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
  if s == "" then return nil end
  return s
end

local function try_db_open(db_module, db_path)
  if not db_module or not db_path or db_path == "" then return nil, "invalid args" end

  local ok, db_or_err = pcall(function()
    if type(db_module.open) == "function" then
      return db_module.open(db_path)
    end
    -- Some variants might expose different entrypoints; keep as minimal fallback
    if type(db_module.sqlite3_open) == "function" then
      return db_module.sqlite3_open(db_path)
    end
    return nil
  end)

  if ok and db_or_err then return db_or_err end
  return nil, tostring(db_or_err)
end

local function exec_safe(db, sql)
  local ok, err = pcall(function()
    if type(db.exec) == "function" then
      db:exec(sql)
      return true
    end
    if type(db.execute) == "function" then
      db:execute(sql)
      return true
    end
    error("no exec")
  end)
  return ok, err
end

local function nrows_safe(db, sql)
  if type(db.nrows) == "function" then
    return db:nrows(sql)
  end
  if type(db.prepare) == "function" then
    local stmt = db:prepare(sql)
    if not stmt then return function() return nil end end
    return function()
      if stmt:step() == false then
        stmt:finalize()
        return nil
      end
      -- lsqlite3 row access differs; fallback to empty
      return {}
    end
  end
  return function() return nil end
end

local function file_size_bytes(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local ok, sz = pcall(function()
    f:seek("end", 0)
    return f:seek()
  end)
  f:close()
  if ok and tonumber(sz) then return tonumber(sz) end
  return 0
end

local function guess_type_and_bpm_and_key(filename)
  local fn = (filename or ""):lower()
  local padded = " " .. fn .. " "

  local function parse_bpm_from_match(raw)
    local n = tonumber(raw)
    if not n then return nil end
    if n < 40 or n > 240 then return nil end
    return n
  end

  local function has_token(tokens, token)
    return tokens[token] == true
  end

  local function normalize_key_root(root, accidental)
    local base = string.upper(root or "")
    local acc = accidental or ""
    local flat_to_sharp = {
      Db = "C#",
      Eb = "D#",
      Gb = "F#",
      Ab = "G#",
      Bb = "A#",
      Cb = "B",
      Fb = "E",
    }
    local merged = base .. acc
    return flat_to_sharp[merged] or merged
  end

  local token_set = {}
  for token in fn:gmatch("[a-z0-9#b]+") do
    token_set[token] = true
  end

  -- type: token-based classification to avoid accidental substring matches.
  local loop_tokens = { "loop", "loops", "lp" }
  local oneshot_tokens = { "oneshot", "one", "shot", "one_shot", "one-shot", "hit", "stab" }
  local loop_score = 0
  local oneshot_score = 0
  for _, tk in ipairs(loop_tokens) do
    if has_token(token_set, tk) then loop_score = loop_score + 1 end
  end
  for _, tk in ipairs(oneshot_tokens) do
    if has_token(token_set, tk) then oneshot_score = oneshot_score + 1 end
  end
  -- User-facing policy:
  -- - any "loop" substring should bias toward loop
  -- - files with BPM in name should also bias toward loop unless fill-like wording is present
  if fn:find("loop", 1, true) then
    loop_score = loop_score + 1
  end

  -- bpm: prefer explicit bpm notation, fallback to numeric token in range.
  local bpm = nil
  local bpm_conf = nil
  do
    local explicit = fn:match("(%d%d?%d)%s*[_%-]?%s*bpm")
      or fn:match("bpm%s*[_%-]?%s*(%d%d?%d)")
      or fn:match("[_%-](%d%d?%d)bpm")
    bpm = parse_bpm_from_match(explicit)
    if bpm then
      bpm_conf = 0.8
    else
      for token in fn:gmatch("%d%d?%d") do
        local cand = parse_bpm_from_match(token)
        if cand then
          bpm = cand
          bpm_conf = 0.35
          break
        end
      end
    end
  end

  local has_fill_like = fn:find("fill", 1, true) ~= nil
  if bpm and not has_fill_like then
    loop_score = loop_score + 1
  end

  local class_primary = "oneshot"
  local class_conf = 0.2
  if loop_score > oneshot_score and loop_score > 0 then
    class_primary = "loop"
    class_conf = 0.7
  elseif oneshot_score > loop_score and oneshot_score > 0 then
    class_primary = "oneshot"
    class_conf = 0.7
  elseif fn:find("loop", 1, true) then
    class_primary = "loop"
    class_conf = 0.55
  end

  -- key: constrained patterns with non-letter boundaries.
  local key_root = nil
  local key_mode = nil
  local key_conf = nil
  do
    local root, acc, mode = padded:match("[^%a]([a-g])([#b]?)[%s_%-]*(major|minor)[^%a]")
    if root then
      key_root = normalize_key_root(root, acc)
      key_mode = mode
      key_conf = 0.8
    end
  end

  if not key_root then
    local root, acc, mode = padded:match("[^%a]([a-g])([#b]?)(maj|min)[^%a]")
    if root then
      key_root = normalize_key_root(root, acc)
      key_mode = (mode == "maj") and "major" or "minor"
      key_conf = 0.7
    end
  end

  if not key_root then
    local root, acc = padded:match("[^%a]([a-g])([#b]?)m[^%a]")
    if root then
      key_root = normalize_key_root(root, acc)
      key_mode = "minor"
      key_conf = 0.55
    end
  end

  -- Root-only key token, e.g. "(C)" or "_F#_". Mode remains unknown.
  if not key_root then
    local root, acc = padded:match("[^%a]([a-g])([#b]?)[^%a]")
    if root then
      key_root = normalize_key_root(root, acc)
      key_mode = nil
      key_conf = 0.4
    end
  end

  local key_estimate = nil
  if key_root and key_mode then
    key_estimate = key_root .. " " .. key_mode
  elseif key_root then
    key_estimate = key_root
  end

  return {
    class_primary = class_primary,
    class_confidence = class_conf,
    bpm = bpm,
    bpm_confidence = bpm_conf,
    key_estimate = key_estimate,
    key_confidence = key_conf,
  }
end

local function is_audio_ext(path)
  if not path then return false end
  local ext = path:match("%.([^%.]+)$")
  if not ext then return false end
  ext = ext:lower()
  local allowed = {
    wav = true, aif = true, aiff = true, flac = true,
    mp3 = true, ogg = true, m4a = true, aac = true,
  }
  return allowed[ext] == true
end

local function enumerate_files_recursive(root_path, on_file)
  if not root_path or root_path == "" then return end

  local function walk(dir)
    local i = 0
    while true do
      local name = r.EnumerateFiles(dir, i)
      if not name then break end
      local full = dir .. sep .. name
      if is_audio_ext(full) then
        on_file(full, name)
      end
      i = i + 1
    end

    local j = 0
    while true do
      local sub = r.EnumerateSubdirectories(dir, j)
      if not sub then break end
      walk(dir .. sep .. sub)
      j = j + 1
    end
  end

  walk(root_path)
end

local function migrate_schema(db)
  if not db then return end
  exec_safe(db, "CREATE INDEX IF NOT EXISTS idx_sample_tags_sample_tag ON sample_tags(sample_id, tag);")
  local has_provider = false
  local has_cover_url = false
  local alias_cols = {}
  for row in db:nrows("PRAGMA table_info(packs);") do
    local nm = row.name
    if type(nm) ~= "string" then
      nm = row[2]
    end
    if nm == "provider_name" then
      has_provider = true
    end
    if nm == "cover_url" then
      has_cover_url = true
    end
  end
  if not has_provider then
    exec_safe(db, "ALTER TABLE packs ADD COLUMN provider_name TEXT NULL;")
  end
  if not has_cover_url then
    exec_safe(db, "ALTER TABLE packs ADD COLUMN cover_url TEXT NULL;")
  end

  for row in db:nrows("PRAGMA table_info(tag_aliases);") do
    local nm = row.name
    if type(nm) ~= "string" then nm = row[2] end
    if nm then alias_cols[tostring(nm)] = true end
  end
  if next(alias_cols) ~= nil then
    if not alias_cols.confidence then
      exec_safe(db, "ALTER TABLE tag_aliases ADD COLUMN confidence REAL NULL;")
    end
    if not alias_cols.last_used_at then
      exec_safe(db, "ALTER TABLE tag_aliases ADD COLUMN last_used_at INTEGER NULL;")
    end
    if not alias_cols.enabled then
      exec_safe(db, "ALTER TABLE tag_aliases ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;")
    end
  end

  local analysis_cols = {}
  for row in db:nrows("PRAGMA table_info(analysis);") do
    local nm = row.name
    if type(nm) ~= "string" then nm = row[2] end
    if nm then analysis_cols[tostring(nm)] = true end
  end
  if next(analysis_cols) ~= nil then
    if not analysis_cols.brightness then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN brightness REAL NULL;")
    end
    if not analysis_cols.noisiness then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN noisiness REAL NULL;")
    end
    if not analysis_cols.attack_sharpness then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN attack_sharpness REAL NULL;")
    end
    if not analysis_cols.decay_length then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN decay_length REAL NULL;")
    end
    if not analysis_cols.tonalness then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN tonalness REAL NULL;")
    end
    if not analysis_cols.spectral_centroid_norm then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN spectral_centroid_norm REAL NULL;")
    end
    if not analysis_cols.spectral_rolloff_norm then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN spectral_rolloff_norm REAL NULL;")
    end
    if not analysis_cols.spectral_bandwidth_norm then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN spectral_bandwidth_norm REAL NULL;")
    end
    if not analysis_cols.spectral_flatness then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN spectral_flatness REAL NULL;")
    end
    if not analysis_cols.embed_x then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN embed_x REAL NULL;")
    end
    if not analysis_cols.embed_y then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN embed_y REAL NULL;")
    end
    if not analysis_cols.mfcc_timbre_norm then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN mfcc_timbre_norm REAL NULL;")
    end
    if not analysis_cols.inharmonicity then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN inharmonicity REAL NULL;")
    end
    if not analysis_cols.metallicity then
      exec_safe(db, "ALTER TABLE analysis ADD COLUMN metallicity REAL NULL;")
    end
  end
end

local function ensure_schema(db)
  exec_safe(db, "PRAGMA journal_mode=WAL;")
  exec_safe(db, "PRAGMA foreign_keys=ON;")

  exec_safe(db, [[
    CREATE TABLE IF NOT EXISTS meta (
      key TEXT PRIMARY KEY,
      value TEXT
    );

    CREATE TABLE IF NOT EXISTS roots (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT UNIQUE NOT NULL,
      mode TEXT NOT NULL,
      source_type TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER,
      updated_at INTEGER
    );

    CREATE TABLE IF NOT EXISTS packs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      root_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      display_name TEXT NULL,
      path TEXT UNIQUE NOT NULL,
      source_type TEXT NOT NULL,
      source_pack_id TEXT NULL,
      provider_name TEXT NULL,
      cover_url TEXT NULL,
      created_at INTEGER,
      updated_at INTEGER,
      FOREIGN KEY(root_id) REFERENCES roots(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS samples (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pack_id INTEGER NOT NULL,
      source TEXT NOT NULL,
      source_sample_id TEXT NULL,
      path TEXT UNIQUE NOT NULL,
      filename TEXT NOT NULL,
      ext TEXT,
      size_bytes INTEGER,
      mtime_unix INTEGER,
      created_at INTEGER,
      updated_at INTEGER,
      FOREIGN KEY(pack_id) REFERENCES packs(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS analysis (
      sample_id INTEGER PRIMARY KEY,
      class_primary TEXT NULL,      -- oneshot|loop
      class_confidence REAL,
      class_source TEXT,
      bpm REAL,
      bpm_confidence REAL,
      bpm_source TEXT,
      key_estimate TEXT,
      key_confidence REAL,
      key_source TEXT,
      brightness REAL NULL,         -- 0..1
      noisiness REAL NULL,          -- 0..1
      attack_sharpness REAL NULL,   -- 0..1
      decay_length REAL NULL,       -- 0..1
      tonalness REAL NULL,          -- 0..1
      spectral_centroid_norm REAL NULL,  -- 0..1
      spectral_rolloff_norm REAL NULL,   -- 0..1
      spectral_bandwidth_norm REAL NULL, -- 0..1
      spectral_flatness REAL NULL,       -- 0..1
      embed_x REAL NULL,            -- 0..1 (2D embedding)
      embed_y REAL NULL,            -- 0..1 (2D embedding)
      mfcc_timbre_norm REAL NULL,   -- 0..1
      inharmonicity REAL NULL,      -- 0..1
      metallicity REAL NULL,        -- 0..1
      analyzed_at INTEGER,
      analysis_version TEXT,
      FOREIGN KEY(sample_id) REFERENCES samples(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS analysis_embed_profiles (
      sample_id INTEGER NOT NULL,
      profile_key TEXT NOT NULL,      -- "<preset>:<variant>"
      embed_x REAL NULL,
      embed_y REAL NULL,
      updated_at INTEGER,
      PRIMARY KEY(sample_id, profile_key),
      FOREIGN KEY(sample_id) REFERENCES samples(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS sample_tags (
      sample_id INTEGER NOT NULL,
      tag TEXT NOT NULL,
      score REAL,
      source TEXT NOT NULL, -- splice|manual|filename_guess
      created_at INTEGER,
      UNIQUE(sample_id, tag, source),
      FOREIGN KEY(sample_id) REFERENCES samples(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS tag_aliases (
      alias TEXT PRIMARY KEY,
      canonical_tag TEXT NOT NULL,
      source TEXT NOT NULL, -- system|user
      created_at INTEGER,
      confidence REAL NULL,
      last_used_at INTEGER NULL,
      enabled INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS manual_type_overrides (
      sample_id INTEGER PRIMARY KEY,
      class_primary TEXT NOT NULL, -- oneshot|loop
      updated_at INTEGER,
      FOREIGN KEY(sample_id) REFERENCES samples(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS manual_tempo_key_overrides (
      sample_id INTEGER PRIMARY KEY,
      bpm REAL NULL,
      key_estimate TEXT NULL,
      updated_at INTEGER,
      FOREIGN KEY(sample_id) REFERENCES samples(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS pack_favorites (
      pack_id INTEGER PRIMARY KEY,
      FOREIGN KEY(pack_id) REFERENCES packs(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_packs_root_id ON packs(root_id);
    CREATE INDEX IF NOT EXISTS idx_samples_pack_id ON samples(pack_id);
    CREATE INDEX IF NOT EXISTS idx_analysis_bpm ON analysis(bpm);
    CREATE INDEX IF NOT EXISTS idx_analysis_embed_profiles_profile ON analysis_embed_profiles(profile_key);
    CREATE INDEX IF NOT EXISTS idx_sample_tags_tag ON sample_tags(tag);
    CREATE INDEX IF NOT EXISTS idx_sample_tags_sample_tag ON sample_tags(sample_id, tag);
  ]])
  migrate_schema(db)

  -- Seed default aliases (idempotent).
  local now = os.time()
  local default_aliases = {
    -- singular/plural and common shorthand in sample names
    { "kick", "kicks" },
    { "snare", "snares" },
    { "clap", "claps" },
    { "rim", "rims" },
    { "hihat", "hats" },
    { "hi hat", "hats" },
    { "hi-hat", "hats" },
    { "open hat", "hats" },
    { "openhat", "hats" },
    { "cymbal", "cymbals" },
    { "shaker", "shakers" },
    { "ambience", "ambient" },
    { "atmos", "ambient" },
    { "atmosphere", "ambient" },
    { "atmospheric", "ambient" },
    { "textures", "texture" },
    { "textural", "texture" },
    { "perc", "percussion" },
    { "reese", "bass" },
    { "neuro", "bass" },
    { "growl", "bass" },
  }
  for _, pair in ipairs(default_aliases) do
    exec_safe(db, string.format([[
      INSERT OR IGNORE INTO tag_aliases(alias, canonical_tag, source, created_at, confidence, last_used_at, enabled)
      VALUES(%s, %s, 'system', %d, 1.0, %d, 1);
    ]], sql_quote(pair[1]), sql_quote(pair[2]), now, now))
  end
end

local function get_singleton_int(db, sql)
  local v = nil
  for row in db:nrows(sql) do
    if row then
      v = row[1] or row.id or row["id"] or row.ID or nil
    end
    break
  end
  if v == nil then return nil end
  local n = tonumber(v)
  return n
end

local function get_or_create_root(db, root_path, mode, source_type)
  local now = os.time()
  local qpath = sql_quote(root_path)
  exec_safe(db, string.format([[
    INSERT OR IGNORE INTO roots(path, mode, source_type, enabled, created_at, updated_at)
    VALUES(%s, %s, %s, 1, %d, %d);
  ]], qpath, sql_quote(mode), sql_quote(source_type), now, now))
  local id = get_singleton_int(db, string.format("SELECT id FROM roots WHERE path=%s;", qpath))
  return id
end

local function get_or_create_pack(db, root_id, name, pack_path, source_type)
  local now = os.time()
  local qpath = sql_quote(pack_path)
  exec_safe(db, string.format([[
    INSERT OR IGNORE INTO packs(root_id, name, display_name, path, source_type, provider_name, created_at, updated_at)
    VALUES(%d, %s, %s, %s, %s, NULL, %d, %d);
  ]], root_id, sql_quote(name), sql_quote(name), qpath, sql_quote(source_type), now, now))
  local id = get_singleton_int(db, string.format("SELECT id FROM packs WHERE path=%s;", qpath))
  return id
end

local function normalize_key_estimate(audio_key, chord_type)
  if not audio_key or tostring(audio_key) == "" then return nil end
  local key = tostring(audio_key):lower()
  key = key:gsub("^%s+", ""):gsub("%s+$", "")
  if key == "" then return nil end

  local root = key:sub(1, 1):upper() .. key:sub(2)
  local mode = nil
  if chord_type ~= nil then
    local m = tostring(chord_type):lower()
    if m == "major" or m == "minor" then
      mode = m
    end
  end
  if mode then
    return root .. " " .. mode
  end
  return root
end

local function split_csv_tags(tags_text)
  local out = {}
  if not tags_text or tostring(tags_text) == "" then return out end
  for token in tostring(tags_text):gmatch("([^,]+)") do
    local t = token:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end

local function get_python_phase_a_script_path()
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

local function get_python_phase_b2_script_path()
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

local function get_python_auto_alias_script_path()
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

local function get_python_phase_c_script_path()
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

local function get_python_phase_d_script_path()
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

local function get_python_phase_e_script_path()
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

local function tokenize_words(text)
  local out = {}
  local seen = {}
  local s = tostring(text or ""):lower()
  for tok in s:gmatch("[a-z0-9#]+") do
    if #tok >= 3 and not seen[tok] then
      seen[tok] = true
      out[#out + 1] = tok
    end
  end
  return out
end

local function collect_unknown_tokens_from_entries(entries, splice_vocab, alias_map)
  local out = {}
  local seen = {}
  local skip = {
    bpm = true, loop = true, loops = true, one = true, shot = true,
    drum = true, drums = true, wav = true, aiff = true, flac = true, mp3 = true,
  }
  for _, e in ipairs(entries or {}) do
    local fn = tostring((e and e.filename) or ""):lower()
    for tok in fn:gmatch("[a-z0-9#]+") do
      if #tok >= 4 and not skip[tok] and not tok:find("%d") then
        local known = (splice_vocab and splice_vocab[tok]) or (alias_map and alias_map[tok])
        if not known and not seen[tok] then
          seen[tok] = true
          out[#out + 1] = tok
        end
      end
    end
  end
  return out
end

local function run_python_auto_alias_batch(unknown_tokens, splice_vocab)
  local out = {}
  if type(unknown_tokens) ~= "table" or #unknown_tokens == 0 then return out end
  if type(splice_vocab) ~= "table" or next(splice_vocab) == nil then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = get_python_auto_alias_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local base = r.GetResourcePath() .. sep .. "SampleLodeManager_auto_alias"
  local in_path = base .. "_unknown.tsv"
  local vocab_path = base .. "_vocab.tsv"
  local out_path = base .. "_out.tsv"

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
  if not ok_exec then return out end

  local rf = io.open(out_path, "rb")
  if not rf then return out end
  for line in rf:lines() do
    local alias, canon, conf = line:match("^([^\t]+)\t([^\t]+)\t([%d%.]+)$")
    local c = tonumber(conf or "")
    if alias and canon and c then
      out[#out + 1] = { alias = alias, canonical = canon, confidence = c }
    end
  end
  rf:close()
  return out
end

local function apply_auto_alias_rows(db, rows)
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

local function run_python_phase_a_batch(rows, pack_name)
  local out = {}
  if type(rows) ~= "table" or #rows == 0 then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = get_python_phase_a_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local base = r.GetResourcePath() .. sep .. "SampleLodeManager_phase_a"
  local in_path = base .. "_in.tsv"
  local out_path = base .. "_out.tsv"
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
  if not ok_exec then return out end

  local rf = io.open(out_path, "rb")
  if not rf then return out end
  for line in rf:lines() do
    local idx_text, tags_csv = line:match("^(%d+)\t(.*)$")
    local idx = tonumber(idx_text or "")
    if idx and idx > 0 then
      out[idx] = split_csv_simple(tags_csv)
    end
  end
  rf:close()
  return out
end

local function run_python_phase_b2_batch(rows, pack_name)
  local out = {}
  if type(rows) ~= "table" or #rows == 0 then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = get_python_phase_b2_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local base = r.GetResourcePath() .. sep .. "SampleLodeManager_phase_b2"
  local in_path = base .. "_in.tsv"
  local out_path = base .. "_out.tsv"
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
  if not ok_exec then return out end

  local rf = io.open(out_path, "rb")
  if not rf then return out end
  for line in rf:lines() do
    local idx_text, tags_csv = line:match("^(%d+)\t(.*)$")
    local idx = tonumber(idx_text or "")
    if idx and idx > 0 then
      out[idx] = split_csv_simple(tags_csv)
    end
  end
  rf:close()
  return out
end

local function run_python_phase_d_batch(rows, pack_name)
  local out = {}
  if type(rows) ~= "table" or #rows == 0 then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = get_python_phase_d_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local base = r.GetResourcePath() .. sep .. "SampleLodeManager_phase_d"
  local in_path = base .. "_in.tsv"
  local out_path = base .. "_out.tsv"
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
      local g = guess_type_and_bpm_and_key(fn_for_guess)
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
  if not ok_exec then return out end

  local rf = io.open(out_path, "rb")
  if not rf then return out end
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
  return out
end

local function table_count_keys(t)
  if type(t) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local PHASE_D_FEATURE_KEYS = {
  "brightness", "noisiness", "attack_sharpness", "decay_length", "tonalness",
  "spectral_centroid_norm", "spectral_rolloff_norm", "spectral_bandwidth_norm", "spectral_flatness", "mfcc_timbre_norm",
}

local function phase_d_row_complete(feat)
  if type(feat) ~= "table" then return false end
  for _, k in ipairs(PHASE_D_FEATURE_KEYS) do
    if tonumber(feat[k]) == nil then return false end
  end
  return true
end

local function get_existing_phase_d_for_entries(db, entries)
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

local function run_python_phase_e_batch(phase_d_by_index, pe_opts)
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

  local script = get_python_phase_e_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local base = r.GetResourcePath() .. sep .. "SampleLodeManager_phase_e"
  local in_path = base .. "_in.tsv"
  local out_path = base .. "_out.tsv"
  local meta_path = base .. "_meta.txt"
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
  if not ok_exec then return out end

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
  return out
end

local function run_python_phase_c_single(file_path, candidate_tags)
  local out = {}
  if not ENABLE_PHASE_C_AUDIO_RERANK then return out end
  if not file_path or tostring(file_path) == "" then return out end
  if type(candidate_tags) ~= "table" or #candidate_tags == 0 then return out end
  if not r.ExecProcess or not r.GetResourcePath then return out end

  local script = get_python_phase_c_script_path()
  if not script then return out end
  local sf = io.open(script, "rb")
  if not sf then return out end
  sf:close()

  local base = r.GetResourcePath() .. sep .. "SampleLodeManager_phase_c"
  local tags_path = base .. "_tags.tsv"
  local out_path = base .. "_out.tsv"
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
  if not ok_exec then return out end

  local rf = io.open(out_path, "rb")
  if not rf then return out end
  for line in rf:lines() do
    local tag, score = line:match("^([^\t]+)\t([%d%.%-]+)$")
    local sc = tonumber(score or "")
    if tag and sc then
      out[tostring(tag):lower()] = sc
    end
  end
  rf:close()
  return out
end

local function get_splice_tag_vocab(db)
  local vocab = {}
  if not db then return vocab end
  for row in db:nrows([[
    SELECT LOWER(TRIM(tag)) AS tag, COUNT(*) AS cnt
    FROM sample_tags
    WHERE source='splice' AND tag IS NOT NULL AND TRIM(tag)!=''
    GROUP BY LOWER(TRIM(tag));
  ]]) do
    local t = row.tag or row[1]
    local c = tonumber(row.cnt or row[2] or 1) or 1
    if t and tostring(t) ~= "" then
      vocab[tostring(t)] = c
    end
  end
  return vocab
end

local function get_tag_alias_map(db)
  local m = {}
  if not db then return m end
  for row in db:nrows([[
    SELECT LOWER(TRIM(alias)) AS alias, LOWER(TRIM(canonical_tag)) AS canonical_tag
    FROM tag_aliases
    WHERE alias IS NOT NULL AND canonical_tag IS NOT NULL
      AND COALESCE(enabled, 1)=1
      AND TRIM(alias) != '' AND TRIM(canonical_tag) != '';
  ]]) do
    local a = row.alias or row[1]
    local c = row.canonical_tag or row[2]
    if a and c then
      m[tostring(a)] = tostring(c)
    end
  end
  return m
end

local function get_splice_genre_vocab(db)
  local out = {}
  if not db then return out end
  local blocked = {
    favorite = true, drums = true, tops = true,
    kicks = true, snares = true, claps = true, rims = true,
    hats = true, percussion = true, shakers = true, cymbals = true,
    bass = true, loop = true, loops = true, oneshot = true, oneshots = true,
  }
  local sql = [[
    SELECT LOWER(t.tag) AS tag, COUNT(*) AS cnt
    FROM sample_tags t
    JOIN samples s ON s.id=t.sample_id
    LEFT JOIN analysis a ON a.sample_id=s.id
    WHERE t.source='splice'
      AND s.source='splice'
      AND COALESCE(a.class_primary, '')='loop'
      AND t.tag IS NOT NULL AND TRIM(t.tag)!=''
    GROUP BY LOWER(t.tag);
  ]]
  for row in db:nrows(sql) do
    local tag = tostring(row.tag or row[1] or "")
    local cnt = tonumber(row.cnt or row[2] or 0) or 0
    if tag ~= "" and cnt >= 20 and not blocked[tag] then
      out[tag] = true
    end
  end
  return out
end

local function infer_filename_genre_priors(filename, splice_genre_vocab, alias_map)
  local priors = {}
  local fn = tostring(filename or ""):lower()
  if fn == "" then return priors end
  for tok in fn:gmatch("[a-z0-9#]+") do
    local cands = { tok }
    local alias = alias_map and alias_map[tok] or nil
    if alias and alias ~= tok then
      cands[#cands + 1] = alias
    end
    for _, c in ipairs(cands) do
      if splice_genre_vocab[c] then
        priors[c] = true
      end
    end
  end
  return priors
end

local function infer_genre_guess_tags(db, filename, bpm_value, splice_genre_vocab, alias_map)
  if not db or type(splice_genre_vocab) ~= "table" or next(splice_genre_vocab) == nil then
    return {}
  end
  local target_tokens = tokenize_words(filename)
  if #target_tokens == 0 then return {} end
  local bpm_num = tonumber(bpm_value)
  local filename_priors = infer_filename_genre_priors(filename, splice_genre_vocab, alias_map)
  local has_filename_opinion = next(filename_priors) ~= nil

  local rows = {}
  local sql
  if bpm_num and bpm_num > 0 then
    local lo = math.max(40, math.floor(bpm_num - 12))
    local hi = math.min(240, math.ceil(bpm_num + 12))
    sql = string.format([[
      SELECT s.id AS id, s.filename AS filename, a.bpm AS bpm
      FROM samples s
      JOIN analysis a ON a.sample_id=s.id
      WHERE s.source='splice'
        AND COALESCE(a.class_primary, '')='loop'
        AND a.bpm BETWEEN %d AND %d
      LIMIT 800;
    ]], lo, hi)
  else
    sql = [[
      SELECT s.id AS id, s.filename AS filename, a.bpm AS bpm
      FROM samples s
      JOIN analysis a ON a.sample_id=s.id
      WHERE s.source='splice'
        AND COALESCE(a.class_primary, '')='loop'
      LIMIT 800;
    ]]
  end

  local scored = {}
  for row in db:nrows(sql) do
    local sid = tonumber(row.id or row[1] or 0) or 0
    if sid > 0 then
      local cfn = tostring(row.filename or row[2] or "")
      local cbpm = tonumber(row.bpm or row[3] or 0)
      local text_sim = jaccard_tokens(target_tokens, tokenize_words(cfn))
      local bpm_sim = 0.3
      if bpm_num and bpm_num > 0 and cbpm and cbpm > 0 then
        local d = math.abs(bpm_num - cbpm)
        bpm_sim = math.max(0, 1.0 - (d / 20.0))
      end
      local total = 0.7 * text_sim + 0.3 * bpm_sim
      if total >= 0.12 then
        scored[#scored + 1] = { id = sid, score = total }
      end
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  if #scored == 0 then return {} end
  while #scored > 80 do table.remove(scored) end

  local id_list = {}
  local by_id_score = {}
  for _, x in ipairs(scored) do
    id_list[#id_list + 1] = tostring(x.id)
    by_id_score[x.id] = x.score
  end
  local tag_scores = {}
  local in_sql = table.concat(id_list, ",")
  local sql_tags = string.format([[
    SELECT sample_id, LOWER(tag) AS tag
    FROM sample_tags
    WHERE source='splice'
      AND sample_id IN (%s);
  ]], in_sql)
  for row in db:nrows(sql_tags) do
    local sid = tonumber(row.sample_id or row[1] or 0) or 0
    local tag = tostring(row.tag or row[2] or "")
    if sid > 0 and tag ~= "" and splice_genre_vocab[tag] then
      tag_scores[tag] = (tag_scores[tag] or 0) + (by_id_score[sid] or 0)
    end
  end

  -- If filename already hints a genre, slightly boost matching tags.
  if has_filename_opinion then
    for tag, _ in pairs(filename_priors) do
      tag_scores[tag] = (tag_scores[tag] or 0) + 0.35
    end
  end

  local ranked = {}
  local best = 0
  for tag, sc in pairs(tag_scores) do
    ranked[#ranked + 1] = { tag = tag, score = sc }
    if sc > best then best = sc end
  end
  table.sort(ranked, function(a, b) return a.score > b.score end)
  if #ranked == 0 then return {} end

  local second = ranked[2] and ranked[2].score or 0
  local margin_ratio = (best > 0) and (second / best) or 1.0
  local out = {}
  local max_items = has_filename_opinion and 3 or 2
  local min_conf_ratio = has_filename_opinion and 0.55 or 0.72
  local min_best_abs = has_filename_opinion and 0.55 or 0.90
  local max_margin_ratio = has_filename_opinion and 0.92 or 0.72

  -- No filename signal: require clearly dominant nearest-neighbor evidence.
  if (not has_filename_opinion) and (best < min_best_abs or margin_ratio > max_margin_ratio) then
    return {}
  end

  for i, row in ipairs(ranked) do
    if i > max_items then break end
    local conf = math.min(0.95, row.score / math.max(1.0, best))
    if conf >= min_conf_ratio then
      if has_filename_opinion then
        if row.score >= (best * 0.35) then
          out[#out + 1] = { tag = row.tag, score = conf }
        end
      else
        if row.score >= (best * 0.55) then
          out[#out + 1] = { tag = row.tag, score = conf }
        end
      end
    end
  end

  -- If filename had explicit genre tokens but NN was too weak, keep filename priors as low-risk fallback.
  if has_filename_opinion and #out == 0 then
    for tag, _ in pairs(filename_priors) do
      out[#out + 1] = { tag = tag, score = 0.62 }
      if #out >= 2 then break end
    end
  end
  return out
end

local function candidate_forms(tag)
  local out = {}
  local seen = {}
  local function push(v)
    if not v or v == "" or seen[v] then return end
    seen[v] = true
    out[#out + 1] = v
  end
  local t = tostring(tag or ""):lower()
  push(t)
  push(t:gsub("%s+", ""))
  push((t:gsub("%-", " ")))
  push((t:gsub("_", " ")))
  if t:sub(-1) == "s" then
    push(t:sub(1, -2))
  else
    push(t .. "s")
  end
  return out
end

local function pick_vocab_tag(vocab, candidates)
  local best_tag = nil
  local best_score = -1
  for _, cand in ipairs(candidates or {}) do
    for _, key in ipairs(candidate_forms(cand)) do
      local score = tonumber(vocab[key] or 0) or 0
      if score > best_score then
        best_score = score
        best_tag = key
      end
    end
  end
  if best_score > 0 then return best_tag end
  return nil
end

local function build_filename_guess_tags(filename, file_path, pack_name, splice_vocab, alias_map, phase_a_hints, phase_b2_hints)
  local fn = tostring(filename or ""):lower()
  local full = tostring(file_path or ""):lower()
  local pack = tostring(pack_name or ""):lower()
  local tags = {}
  local seen = {}
  local has_vocab = type(splice_vocab) == "table" and next(splice_vocab) ~= nil

  local function add_tag(tag, score)
    if not tag or tostring(tag) == "" then return end
    local t = tostring(tag):lower()
    if seen[t] then return end
    seen[t] = true
    tags[#tags + 1] = { tag = t, score = tonumber(score) or 0.5 }
  end

  local function add_from_candidates(candidates, fallback_tag, score, force_fallback)
    if has_vocab then
      local matched = pick_vocab_tag(splice_vocab, candidates)
      if matched then
        add_tag(matched, score)
      elseif force_fallback then
        add_tag(fallback_tag, score)
      end
    else
      add_tag(fallback_tag, score)
    end
  end

  local function has_word(word)
    local padded = " " .. fn .. " "
    return padded:find("[^%a]" .. word .. "[^%a]") ~= nil
  end

  local function remove_tags_by_set(drop_set)
    local filtered = {}
    for _, row in ipairs(tags) do
      local t = tostring((row and row.tag) or ""):lower()
      if t ~= "" and not drop_set[t] then
        filtered[#filtered + 1] = row
      end
    end
    tags = filtered
  end

  -- Detect candidates directly from filename tokens and map to Splice vocabulary.
  -- This keeps "what to detect" driven by existing splice tags, not a fixed hand list.
  if has_vocab then
    local candidates = {}
    local seen_cand = {}
    local tokens = {}
    local token_forms_set = {}
    local skip_vocab_word = {
      bpm = true,
      loop = true,
      loops = true,
      one = true,
      shot = true,
      drum = true,
      drums = true,
    }

    local function push_candidate(v)
      v = tostring(v or ""):lower()
      if v == "" or seen_cand[v] then return end
      seen_cand[v] = true
      candidates[#candidates + 1] = v
    end

    for token in fn:gmatch("[a-z0-9#]+") do
      tokens[#tokens + 1] = token
      push_candidate(token)
      token_forms_set[token] = true
      if token:sub(-1) == "s" then
        token_forms_set[token:sub(1, -2)] = true
      else
        token_forms_set[token .. "s"] = true
      end
    end
    for i = 1, (#tokens - 1) do
      push_candidate(tokens[i] .. " " .. tokens[i + 1])
      push_candidate(tokens[i] .. tokens[i + 1])
    end

    local function resolve_alias(c)
      local v = tostring(c or ""):lower()
      if v == "" then return v end
      return (alias_map and alias_map[v]) or v
    end

    for _, cand in ipairs(candidates) do
      local c0 = resolve_alias(cand)
      local matched = pick_vocab_tag(splice_vocab, { c0, cand })
      if matched then
        add_tag(matched, 0.72)
      end
    end

    -- Generic vocabulary-driven matching:
    -- add any splice tag whose component words are present in filename tokens.
    for vocab_tag, _cnt in pairs(splice_vocab) do
      local words = {}
      for w in tostring(vocab_tag):gmatch("[a-z0-9#]+") do
        words[#words + 1] = w
      end
      if #words >= 1 and #words <= 3 then
        local ok_all = true
        for _, w in ipairs(words) do
          if skip_vocab_word[w] or #w < 3 then
            ok_all = false
            break
          end
          local resolved_w = (alias_map and alias_map[w]) or w
          if not token_forms_set[w] and not token_forms_set[resolved_w] then
            ok_all = false
            break
          end
        end
        if ok_all then
          add_tag(vocab_tag, (#words == 1) and 0.74 or 0.66)
        end
      end
    end
  end

  if type(phase_a_hints) == "table" then
    for _, hint in ipairs(phase_a_hints) do
      local h = tostring(hint or ""):lower()
      if h ~= "" then
        -- Phase-A hints should map to known vocabulary, not create raw/free-form tags.
        add_from_candidates({ h }, h, 0.78, false)
      end
    end
  end
  if type(phase_b2_hints) == "table" then
    for _, hint in ipairs(phase_b2_hints) do
      local h = tostring(hint or ""):lower()
      if h ~= "" then
        -- Keep audio-only bass inference conservative: start as weak candidate by default.
        local hint_score = (h == "bass") and 0.68 or 0.76
        add_from_candidates({ h }, h, hint_score, false)
      end
    end
  end

  local has_kick = has_word("kick")
  local has_snare = has_word("snare")
  local has_clap = has_word("clap")
  local has_hihat = fn:find("hihat", 1, true) or fn:find("hi%-hat") or fn:find("hi_hat") or fn:find(" hi hat ", 1, true)
  local has_open_hat = fn:find("open hat", 1, true) or fn:find("open_hat", 1, true) or fn:find("open%-hat")
  local has_rim = has_word("rim")
  local has_perc = has_word("perc") or has_word("percussion")
  local has_shaker = has_word("shaker") or has_word("shakers")
  local has_cymbal = has_word("cymbal") or has_word("cymbals") or has_word("crash") or has_word("ride") or has_word("splash")
  local has_fx_word = has_word("reverse") or has_word("reversed") or has_word("riser") or has_word("uplifter")
    or has_word("downlifter") or has_word("sweep") or has_word("swell") or has_word("whoosh")
    or has_word("impact") or has_word("transition") or has_word("fx")
  local has_explicit_bass_word = has_word("bass") or has_word("808") or has_word("reese")
    or has_word("neuro") or has_word("growl")
  -- Project policy: these core drum tags are always pluralized.
  if has_kick then add_tag("kicks", 0.95) end
  if has_snare then add_tag("snares", 0.95) end
  if has_clap then add_tag("claps", 0.95) end
  if has_hihat then
    -- Policy: unify hi-hat family to "hats" when possible.
    add_from_candidates({ "hats", "hat", "hihat", "hi hat" }, "hats", 0.9, true)
  end
  if has_open_hat then
    -- Keep "hats" unified for open-hat naming too.
    add_from_candidates({ "hats", "hat", "open hat", "openhat", "hihat" }, "hats", 0.9, true)
  end
  if has_rim then add_tag("rims", 0.85) end
  if has_perc then
    add_from_candidates({ "percussion", "perc" }, "percussion", 0.85, true)
  end
  if has_shaker then
    add_from_candidates({ "shakers", "shaker" }, "shakers", 0.9, true)
  end
  if has_cymbal then
    add_from_candidates({ "cymbals", "cymbal", "crash", "ride", "splash" }, "cymbals", 0.9, true)
  end
  if has_word("808") then
    add_from_candidates({ "808", "bass" }, "808", 0.9, true)
    add_from_candidates({ "bass" }, "bass", 0.8, true)
  end
  if has_word("reese") then
    add_from_candidates({ "reese", "bass" }, "reese", 0.8, true)
    -- Policy: reese implies bass layer in this project.
    add_from_candidates({ "bass" }, "bass", 0.65, true)
  end
  if has_word("neuro") then
    add_from_candidates({ "neuro", "bass" }, "neuro", 0.8, true)
    -- Policy: neuro bass naming should still carry the "bass" family tag.
    add_from_candidates({ "bass" }, "bass", 0.65, true)
  end
  if has_word("growl") then
    add_from_candidates({ "growl", "bass" }, "growl", 0.8, true)
    -- Policy: growl bass naming should still carry the "bass" family tag.
    add_from_candidates({ "bass" }, "bass", 0.65, true)
  end
  if has_word("ambient") or has_word("ambience") or has_word("atmosphere") or has_word("atmospheric") then
    add_from_candidates({ "ambient", "ambience", "atmosphere", "atmospheric" }, "ambient", 0.9, true)
  end
  if has_word("texture") or has_word("textures") or has_word("textural") then
    add_from_candidates({ "texture", "textures", "textural" }, "texture", 0.9, true)
  end

  -- Folder/context hints.
  local ctx = full .. " " .. pack
  local is_loop_context = (
    ctx:find("drums loops", 1, true)
    or ctx:find("drum loops", 1, true)
    or ctx:find("drum loop", 1, true)
    or fn:find(" loop ", 1, true)
    or fn:find("drum loop", 1, true)
  ) ~= nil
  local is_one_shot_context = (
    ctx:find("one shots", 1, true)
    or ctx:find("one shot", 1, true)
    or ctx:find("one%-shot")
    or fn:find("oneshot", 1, true)
    or fn:find("one shot", 1, true)
    or fn:find("one%-shot")
  ) ~= nil
  local is_drum_like = has_kick or has_snare or has_clap or has_hihat or has_open_hat or has_rim or has_perc or has_shaker or has_cymbal
  local has_explicit_mood_words = has_word("ambient") or has_word("ambience")
    or has_word("atmosphere") or has_word("atmospheric")
    or has_word("texture") or has_word("textures") or has_word("textural")

  -- Policy:
  -- - no "oneshot" tag from folder context
  -- - use "drums" (not "drum loop")
  -- - add drums for drum-like one shots
  if is_loop_context then
    add_from_candidates({ "drums", "drum" }, "drums", 0.7, true)
  end
  if is_one_shot_context and is_drum_like then
    add_from_candidates({ "drums", "drum" }, "drums", 0.7, true)
  end

  -- Tops: drum/perc loop that is not kick-focused.
  if is_loop_context and (has_snare or has_clap or has_hihat or has_open_hat or has_rim or has_perc or has_shaker or has_cymbal) and not has_kick then
    add_from_candidates({ "tops", "top loop", "drum tops" }, "tops", 0.65, true)
  end

  -- Policy: if hats is present, drop narrower hi-hat spellings for consistency.
  if seen["hats"] then
    local filtered = {}
    local blocked = {
      ["hat"] = true,
      ["hihat"] = true,
      ["hi hat"] = true,
      ["open hat"] = true,
      ["openhat"] = true,
    }
    for _, row in ipairs(tags) do
      if not blocked[tostring(row.tag or ""):lower()] then
        filtered[#filtered + 1] = row
      end
    end
    tags = filtered
  end

  -- Suppress mood tags on clear drum-instrument loops unless explicitly named.
  -- This keeps "snap/snare/kick..." loops from receiving accidental "texture/ambient"
  -- due to nearest-neighbor or weak audio hints.
  local instrument_loop_markers = {
    kicks = true, snares = true, claps = true, rims = true,
    hats = true, shakers = true, cymbals = true, percussion = true,
    snaps = true, cowbells = true, tops = true,
  }
  local has_instrument_marker = false
  for _, row in ipairs(tags) do
    local t = tostring((row and row.tag) or ""):lower()
    if instrument_loop_markers[t] then
      has_instrument_marker = true
      break
    end
  end
  if is_loop_context and has_instrument_marker and not has_explicit_mood_words then
    remove_tags_by_set({
      ambient = true,
      texture = true,
      atmos = true,
      atmosphere = true,
      atmospheric = true,
    })
  end

  -- Safety guard: cymbal/fx materials should not receive "bass" unless filename explicitly says bass-family words.
  if (has_cymbal or has_fx_word) and not has_explicit_bass_word then
    remove_tags_by_set({
      bass = true,
    })
  end

  return tags
end

local function replace_filename_guess_tags(db, sample_id, tag_rows)
  if not db or not sample_id then return end
  exec_safe(db, string.format(
    "DELETE FROM sample_tags WHERE sample_id=%d AND source='filename_guess';",
    tonumber(sample_id) or -1
  ))
  if type(tag_rows) ~= "table" or #tag_rows == 0 then return end
  local now = os.time()
  for _, row in ipairs(tag_rows) do
    local tag = row and row.tag or nil
    local score = row and tonumber(row.score) or 0.5
    if tag and tostring(tag) ~= "" then
      exec_safe(db, string.format([[
        INSERT OR IGNORE INTO sample_tags(sample_id, tag, score, source, created_at)
        VALUES(%d, %s, %s, 'filename_guess', %d);
      ]], sample_id, sql_quote(tostring(tag)), tostring(score), now))
    end
  end
end

local function replace_tag_candidate_tags(db, sample_id, tag_rows)
  if not db or not sample_id then return end
  exec_safe(db, string.format(
    "DELETE FROM sample_tags WHERE sample_id=%d AND source='tag_candidate';",
    tonumber(sample_id) or -1
  ))
  if type(tag_rows) ~= "table" or #tag_rows == 0 then return end
  local now = os.time()
  for _, row in ipairs(tag_rows) do
    local tag = row and row.tag or nil
    local score = row and tonumber(row.score) or 0.5
    if tag and tostring(tag) ~= "" then
      exec_safe(db, string.format([[
        INSERT OR IGNORE INTO sample_tags(sample_id, tag, score, source, created_at)
        VALUES(%d, %s, %s, 'tag_candidate', %d);
      ]], sample_id, sql_quote(tostring(tag)), tostring(score), now))
    end
  end
end

local function replace_genre_guess_tags(db, sample_id, tag_rows)
  if not db or not sample_id then return end
  exec_safe(db, string.format(
    "DELETE FROM sample_tags WHERE sample_id=%d AND source='genre_guess';",
    tonumber(sample_id) or -1
  ))
  if type(tag_rows) ~= "table" or #tag_rows == 0 then return end
  local now = os.time()
  for _, row in ipairs(tag_rows) do
    local tag = row and row.tag or nil
    local score = row and tonumber(row.score) or 0.5
    if tag and tostring(tag) ~= "" then
      exec_safe(db, string.format([[
        INSERT OR IGNORE INTO sample_tags(sample_id, tag, score, source, created_at)
        VALUES(%d, %s, %s, 'genre_guess', %d);
      ]], sample_id, sql_quote(tostring(tag)), tostring(score), now))
    end
  end
end

local function apply_phase_c_rerank(tag_rows, audio_scores)
  if type(tag_rows) ~= "table" or #tag_rows == 0 then return tag_rows end
  if type(audio_scores) ~= "table" or next(audio_scores) == nil then return tag_rows end
  local out = {}
  for _, row in ipairs(tag_rows) do
    local tag = tostring((row and row.tag) or ""):lower()
    local base = tonumber(row and row.score or 0) or 0
    if tag ~= "" then
      local a = tonumber(audio_scores[tag] or 0) or 0
      local bonus = 0.20 * math.max(0.0, a - 0.5)
      local new_score = math.max(0.0, math.min(1.0, base + bonus))
      out[#out + 1] = { tag = tag, score = new_score }
    end
  end
  return out
end

local function upsert_sample_and_analysis(db, pack_id, source, source_sample_id, file_path, filename, ext, pack_name, splice_vocab, alias_map, phase_a_hints, phase_b2_hints, phase_d_features, phase_e_embed, splice_genre_vocab)
  local now = os.time()
  local qpath = sql_quote(file_path)
  local size = file_size_bytes(file_path)
  local mtime = 0

  exec_safe(db, string.format([[
    INSERT OR IGNORE INTO samples(pack_id, source, source_sample_id, path, filename, ext, size_bytes, mtime_unix, created_at, updated_at)
    VALUES(%d, %s, %s, %s, %s, %s, %d, %d, %d, %d);
  ]], pack_id, sql_quote(source), sql_quote(source_sample_id), qpath,
    sql_quote(filename), sql_quote(ext), size, mtime, now, now))

  -- Update basic fields (for changed size/path)
  exec_safe(db, string.format([[
    UPDATE samples
    SET filename=%s, ext=%s, size_bytes=%d, mtime_unix=%d, updated_at=%d
    WHERE path=%s;
  ]], sql_quote(filename), sql_quote(ext), size, mtime, now, qpath))

  local sample_id = get_singleton_int(db, string.format("SELECT id FROM samples WHERE path=%s;", qpath))

  local guess = guess_type_and_bpm_and_key(filename)
  local feat = (type(phase_d_features) == "table") and phase_d_features or nil
  local emb = (type(phase_e_embed) == "table") and phase_e_embed or nil
  local audio_complete = type(feat) == "table" and phase_d_row_complete(feat)
  local analysis_version = "v0.1_filename_guess"
  if type(feat) == "table" then
    if audio_complete then
      analysis_version = "v0.2_audio_features"
    else
      for _, k in ipairs(PHASE_D_FEATURE_KEYS) do
        if tonumber(feat[k]) ~= nil then
          analysis_version = "v0.2_audio_partial"
          break
        end
      end
    end
  end
  local emb_x_ok = audio_complete and emb and tonumber(emb.embed_x)
  local emb_y_ok = audio_complete and emb and tonumber(emb.embed_y)
  exec_safe(db, string.format([[
    INSERT OR REPLACE INTO analysis(
      sample_id,
      class_primary, class_confidence, class_source,
      bpm, bpm_confidence, bpm_source,
      key_estimate, key_confidence, key_source,
      brightness, noisiness, attack_sharpness, decay_length, tonalness,
      spectral_centroid_norm, spectral_rolloff_norm, spectral_bandwidth_norm, spectral_flatness,
      mfcc_timbre_norm,
      inharmonicity, metallicity,
      embed_x, embed_y,
      analyzed_at, analysis_version
    ) VALUES(
      %d,
      %s, %s, %s,
      %s, %s, %s,
      %s, %s, %s,
      %s, %s, %s, %s, %s,
      %s, %s, %s, %s,
      %s,
      %s, %s,
      %s, %s,
      %d, %s
    );
  ]],
    sample_id,
    sql_quote(guess.class_primary), tostring(guess.class_confidence or "NULL"), sql_quote("filename_guess"),
    guess.bpm and tostring(guess.bpm) or "NULL",
    guess.bpm_confidence and tostring(guess.bpm_confidence) or "NULL",
    guess.bpm and sql_quote("filename_guess") or "NULL",
    sql_quote(guess.key_estimate),
    guess.key_confidence and tostring(guess.key_confidence) or "NULL",
    guess.key_estimate and sql_quote("filename_guess") or "NULL",
    feat and feat.brightness and tostring(feat.brightness) or "NULL",
    feat and feat.noisiness and tostring(feat.noisiness) or "NULL",
    feat and feat.attack_sharpness and tostring(feat.attack_sharpness) or "NULL",
    feat and feat.decay_length and tostring(feat.decay_length) or "NULL",
    feat and feat.tonalness and tostring(feat.tonalness) or "NULL",
    feat and feat.spectral_centroid_norm and tostring(feat.spectral_centroid_norm) or "NULL",
    feat and feat.spectral_rolloff_norm and tostring(feat.spectral_rolloff_norm) or "NULL",
    feat and feat.spectral_bandwidth_norm and tostring(feat.spectral_bandwidth_norm) or "NULL",
    feat and feat.spectral_flatness and tostring(feat.spectral_flatness) or "NULL",
    feat and feat.mfcc_timbre_norm and tostring(feat.mfcc_timbre_norm) or "NULL",
    feat and feat.inharmonicity and tostring(feat.inharmonicity) or "NULL",
    feat and feat.metallicity and tostring(feat.metallicity) or "NULL",
    emb_x_ok and tostring(emb.embed_x) or "NULL",
    emb_y_ok and tostring(emb.embed_y) or "NULL",
    now,
    sql_quote(analysis_version)
  ))

  if tostring(source) ~= "splice" then
    local guess_tags = build_filename_guess_tags(filename, file_path, pack_name, splice_vocab, alias_map, phase_a_hints, phase_b2_hints)
    local candidate_for_audio = {}
    do
      local seen = {}
      for _, r0 in ipairs(guess_tags or {}) do
        local t0 = tostring((r0 and r0.tag) or ""):lower()
        if t0 ~= "" and not seen[t0] then
          seen[t0] = true
          candidate_for_audio[#candidate_for_audio + 1] = t0
        end
      end
      if guess.class_primary == "loop" then
        local g0 = infer_genre_guess_tags(db, filename, guess.bpm, splice_genre_vocab, alias_map)
        for _, gr in ipairs(g0 or {}) do
          local tg = tostring((gr and gr.tag) or ""):lower()
          if tg ~= "" and not seen[tg] then
            seen[tg] = true
            candidate_for_audio[#candidate_for_audio + 1] = tg
          end
        end
      end
    end
    local phase_c_scores = run_python_phase_c_single(file_path, candidate_for_audio)
    guess_tags = apply_phase_c_rerank(guess_tags, phase_c_scores)
    local strong = {}
    local weak = {}
    for _, row in ipairs(guess_tags or {}) do
      local sc = tonumber(row.score or 0) or 0
      if sc >= 0.72 then
        strong[#strong + 1] = row
      else
        weak[#weak + 1] = row
      end
    end
    replace_filename_guess_tags(db, sample_id, strong)
    replace_tag_candidate_tags(db, sample_id, weak)
    if guess.class_primary == "loop" then
      local genre_tags = infer_genre_guess_tags(db, filename, guess.bpm, splice_genre_vocab, alias_map)
      genre_tags = apply_phase_c_rerank(genre_tags, phase_c_scores)
      replace_genre_guess_tags(db, sample_id, genre_tags)
    else
      replace_genre_guess_tags(db, sample_id, {})
    end
  end

  return sample_id
end

-- Writes phase_d + optional embed; NULLs failed/partial fields (no COALESCE — clears bad values).
local function apply_phase_d_to_analysis(db, sample_id, feat, emb)
  local sid = tonumber(sample_id)
  if not sid or sid < 1 or not db then return end
  local now = os.time()
  local function sql_real_or_null(v)
    local n = tonumber(v)
    if n == nil then return "NULL" end
    return tostring(n)
  end
  if type(feat) ~= "table" then
    exec_safe(db, string.format([[
      UPDATE analysis SET
        brightness=NULL, noisiness=NULL, attack_sharpness=NULL, decay_length=NULL, tonalness=NULL,
        spectral_centroid_norm=NULL, spectral_rolloff_norm=NULL, spectral_bandwidth_norm=NULL, spectral_flatness=NULL,
        mfcc_timbre_norm=NULL, inharmonicity=NULL, metallicity=NULL, embed_x=NULL, embed_y=NULL,
        analyzed_at=%d, analysis_version=%s
      WHERE sample_id=%d;
    ]], now, sql_quote("v0.1_filename_guess"), sid))
    return
  end
  local any_num = false
  for _, k in ipairs(PHASE_D_FEATURE_KEYS) do
    if tonumber(feat[k]) ~= nil then
      any_num = true
      break
    end
  end
  local complete = phase_d_row_complete(feat)
  local ver = complete and "v0.2_audio_features" or (any_num and "v0.2_audio_partial" or "v0.1_filename_guess")
  local emb_ok = complete and emb and tonumber(emb.embed_x) and tonumber(emb.embed_y)
  exec_safe(db, string.format([[
    UPDATE analysis SET
      brightness=%s, noisiness=%s, attack_sharpness=%s, decay_length=%s, tonalness=%s,
      spectral_centroid_norm=%s, spectral_rolloff_norm=%s, spectral_bandwidth_norm=%s, spectral_flatness=%s,
      mfcc_timbre_norm=%s, inharmonicity=%s, metallicity=%s,
      embed_x=%s, embed_y=%s,
      analyzed_at=%d, analysis_version=%s
    WHERE sample_id=%d;
  ]],
    sql_real_or_null(feat.brightness),
    sql_real_or_null(feat.noisiness),
    sql_real_or_null(feat.attack_sharpness),
    sql_real_or_null(feat.decay_length),
    sql_real_or_null(feat.tonalness),
    sql_real_or_null(feat.spectral_centroid_norm),
    sql_real_or_null(feat.spectral_rolloff_norm),
    sql_real_or_null(feat.spectral_bandwidth_norm),
    sql_real_or_null(feat.spectral_flatness),
    sql_real_or_null(feat.mfcc_timbre_norm),
    sql_real_or_null(feat.inharmonicity),
    sql_real_or_null(feat.metallicity),
    emb_ok and tostring(emb.embed_x) or "NULL",
    emb_ok and tostring(emb.embed_y) or "NULL",
    now,
    sql_quote(ver),
    sid
  ))
end

function M.open(db_path, db_module)
  local db, err = try_db_open(db_module, db_path)
  if not db then
    return nil, err or "open failed"
  end
  ensure_schema(db)
  return db
end

-- Public API

function M.add_root(store, mode, source_type, root_path)
  if not store or not store.db then return nil, "db not ready" end
  local normalized_path = sanitize_root_path(root_path)
  if not normalized_path then return nil, "invalid root path" end
  local root_id = get_or_create_root(store.db, normalized_path, mode, source_type)
  return root_id
end

local function list_subdirs(dir_path)
  local out = {}
  local j = 0
  while true do
    local sub = r.EnumerateSubdirectories(dir_path, j)
    if not sub then break end
    out[#out + 1] = sub
    j = j + 1
  end
  return out
end

local function build_rescan_job(store, root_id, opts)
  opts = type(opts) == "table" and opts or {}
  local force_phase_d_all = opts.force_phase_d_all == true
  local db = store.db
  if not db then return nil, "no db" end
  local root_row = nil
  for row in db:nrows(string.format("SELECT path, mode, source_type FROM roots WHERE id=%d;", root_id)) do
    root_row = row
    break
  end
  if not root_row then return nil, "root not found" end

  local root_path = root_row.path or root_row[1]
  local mode = root_row.mode or root_row[2]
  local source_type = root_row.source_type or root_row[3]
  if tostring(source_type) == "splice" then
    local entries = {}
    for row in db:nrows(string.format([[
      SELECT s.id, s.path, s.filename
      FROM samples s
      JOIN packs p ON p.id=s.pack_id
      LEFT JOIN analysis a ON a.sample_id=s.id
      WHERE p.root_id=%d AND s.source='splice'
        AND COALESCE(a.class_primary, '')='oneshot'
      ORDER BY s.id ASC;
    ]], root_id)) do
      entries[#entries + 1] = {
        sample_id = tonumber(row.id or row[1]),
        full_path = row.path or row[2],
        filename = row.filename or row[3] or "",
        ext = tostring((row.path or row[2] or ""):match("%.([^%.]+)$") or ""):lower(),
      }
    end
    local existing_phase_d = get_existing_phase_d_for_entries(db, entries)
    return {
      db = db,
      source_type = "splice",
      root_id = root_id,
      pack_name = "",
      current_pack = { id = 0, name = "Splice" },
      entries = entries,
      splice_force_phase_d_all = force_phase_d_all == true,
      splice_existing_phase_d_by_index = existing_phase_d,
      chunk_from = nil,
      chunk_to = nil,
      chunk_phase_d_by_rel = nil,
      chunk_phase_e_by_rel = nil,
      phase_d_count = 0,
      phase_e_count = 0,
      entry_idx = 1,
      processed = 0,
      total = #entries,
      ratio = 0,
      phase = "scan_splice_prepare",
      done = (#entries == 0),
      analysis_batch_size = math.max(1, math.floor(tonumber(opts.analysis_batch_size) or 8)),
    }
  end

  local current_pack_paths = {}
  local packs_to_create = {}
  if mode == "pack_root" then
    local subdirs = list_subdirs(root_path)
    for _, name in ipairs(subdirs) do
      local pack_path = root_path .. sep .. name
      packs_to_create[#packs_to_create + 1] = { name = name, path = pack_path }
      current_pack_paths[pack_path] = true
    end
  elseif mode == "single_pack" then
    local name = root_path:match("([^/\\]+)$") or "pack"
    current_pack_paths[root_path] = true
    packs_to_create[#packs_to_create + 1] = { name = name, path = root_path }
  else
    return nil, "unknown root mode: " .. tostring(mode)
  end

  local existing_packs = {}
  for row in db:nrows(string.format("SELECT id, path FROM packs WHERE root_id=%d;", root_id)) do
    existing_packs[#existing_packs + 1] = { id = row.id or row[1], path = row.path or row[2] }
  end
  for _, p in ipairs(existing_packs) do
    if not current_pack_paths[p.path] then
      exec_safe(db, string.format("DELETE FROM packs WHERE id=%d;", p.id))
    end
  end

  local total_files = 0
  for _, pack in ipairs(packs_to_create) do
    enumerate_files_recursive(pack.path, function() total_files = total_files + 1 end)
  end

  return {
    db = db,
    root_id = root_id,
    source_type = source_type,
    packs_to_create = packs_to_create,
    pack_idx = 1,
    current_pack = nil,
    entries = nil,
    phase_a_by_index = nil,
    phase_b2_by_index = nil,
    phase_d_by_index = nil,
    phase_e_by_index = nil,
    phase_d_count = 0,
    phase_e_count = 0,
    entry_idx = 1,
    processed = 0,
    total = total_files,
    ratio = 0,
    phase = "start",
    done = false,
    analysis_batch_size = math.max(1, math.floor(tonumber(opts.analysis_batch_size) or 8)),
    chunk_from = nil,
    chunk_to = nil,
    chunk_phase_a_by_rel = nil,
    chunk_phase_b2_by_rel = nil,
    chunk_phase_d_by_rel = nil,
    chunk_phase_e_by_rel = nil,
    splice_vocab = get_splice_tag_vocab(db),
    alias_map = get_tag_alias_map(db),
    splice_genre_vocab = get_splice_genre_vocab(db),
  }
end

function M.begin_rescan_root(store, root_id, opts)
  return build_rescan_job(store, root_id, opts)
end

-- Steps a rescan job by up to max_files sample upserts.
-- returns done:boolean, err:string|nil, progress:table
function M.step_rescan_job(job, max_files)
  if not job then return true, "no job", nil end
  if job.done then
    return true, nil, {
      root_id = job.root_id,
      pack_name = job.pack_name or "",
      processed = job.processed or 0,
      total = job.total or 0,
      ratio = job.ratio or 1.0,
      phase = "done",
    }
  end
  local budget = tonumber(max_files) or 50
  if budget < 1 then budget = 1 end

  local processed_now = 0
  if tostring(job.source_type) == "splice" then
    while processed_now < budget and not job.done do
      local e = job.entries and job.entries[job.entry_idx] or nil
      if not e then
        job.done = true
        job.phase = "done"
        job.ratio = 1.0
        break
      end
      local idx = job.entry_idx
      local cf = tonumber(job.chunk_from)
      local ct = tonumber(job.chunk_to)
      if (not cf) or (not ct) or idx < cf or idx > ct then
        local from = idx
        local n_total = #job.entries
        local batch_sz = math.max(1, math.floor(tonumber(job.analysis_batch_size) or 8))
        local to_idx = math.min(n_total, from + batch_sz - 1)
        local chunk_entries = {}
        local chunk_existing_by_rel = {}
        for gi = from, to_idx do
          local src = job.entries[gi]
          if src then
            local rel = gi - from + 1
            local existing = job.splice_existing_phase_d_by_index and job.splice_existing_phase_d_by_index[gi] or nil
            local should_skip = (job.splice_force_phase_d_all ~= true) and phase_d_row_complete(existing)
            chunk_entries[rel] = {
              full_path = src.full_path,
              filename = src.filename,
              ext = src.ext,
              skip_phase_d = should_skip,
              force_phase_d = job.splice_force_phase_d_all == true,
            }
            if should_skip then
              chunk_existing_by_rel[rel] = existing
            end
          end
        end
        job.phase = "scan_splice_analyze"
        local phase_d_new_chunk = run_python_phase_d_batch(chunk_entries, "splice")
        local phase_d_chunk = {}
        for rel, feat in pairs(chunk_existing_by_rel) do
          phase_d_chunk[rel] = feat
        end
        for rel, feat in pairs(phase_d_new_chunk or {}) do
          phase_d_chunk[rel] = feat
        end
        local phase_e_chunk = run_python_phase_e_batch(phase_d_chunk)
        job.phase_d_count = (job.phase_d_count or 0) + table_count_keys(phase_d_new_chunk)
        job.phase_e_count = (job.phase_e_count or 0) + table_count_keys(phase_e_chunk)
        job.chunk_from = from
        job.chunk_to = to_idx
        job.chunk_phase_d_by_rel = phase_d_chunk
        job.chunk_phase_e_by_rel = phase_e_chunk
        cf = from
      end
      local rel = idx - (cf or idx) + 1
      local feat = job.chunk_phase_d_by_rel and job.chunk_phase_d_by_rel[rel] or nil
      local emb = job.chunk_phase_e_by_rel and job.chunk_phase_e_by_rel[rel] or nil
      job.phase = "scan_splice_write"
      if e.sample_id then
        apply_phase_d_to_analysis(job.db, e.sample_id, feat, emb)
      end
      job.entry_idx = job.entry_idx + 1
      job.processed = (job.processed or 0) + 1
      processed_now = processed_now + 1
      if (job.total or 0) > 0 then
        job.ratio = math.max(0.0, math.min(1.0, job.processed / job.total))
      else
        job.ratio = 1.0
      end
    end
    return job.done == true, nil, {
      root_id = job.root_id,
      pack_name = "Splice",
      processed = job.processed or 0,
      total = job.total or 0,
      ratio = job.ratio or 0,
      phase = job.phase or "scan_splice",
      phase_d_count = job.phase_d_count or 0,
      phase_e_count = job.phase_e_count or 0,
    }
  end

  while processed_now < budget and not job.done do
    if not job.current_pack then
      local pack = job.packs_to_create[job.pack_idx]
      if not pack then
        job.done = true
        job.phase = "done"
        job.ratio = 1.0
        break
      end
      local pack_id = get_or_create_pack(job.db, job.root_id, pack.name, pack.path, job.source_type)
      exec_safe(job.db, string.format("DELETE FROM samples WHERE pack_id=%d;", pack_id))

      local entries = {}
      enumerate_files_recursive(pack.path, function(full_path, filename_only)
        local ext2 = full_path:match("%.([^%.]+)$")
        ext2 = ext2 and ext2:lower() or ""
        entries[#entries + 1] = {
          full_path = full_path,
          filename = filename_only,
          ext = ext2,
        }
      end)
      local unknown_tokens = collect_unknown_tokens_from_entries(entries, job.splice_vocab, job.alias_map)
      local auto_alias_rows = run_python_auto_alias_batch(unknown_tokens, job.splice_vocab)
      local changed_alias = apply_auto_alias_rows(job.db, auto_alias_rows)
      if changed_alias > 0 then
        job.alias_map = get_tag_alias_map(job.db)
      end
      job.phase_d_count = 0
      job.phase_e_count = 0
      job.current_pack = { id = pack_id, name = pack.name }
      job.entries = entries
      job.entry_idx = 1
      job.chunk_from = nil
      job.chunk_to = nil
      job.chunk_phase_a_by_rel = nil
      job.chunk_phase_b2_by_rel = nil
      job.chunk_phase_d_by_rel = nil
      job.chunk_phase_e_by_rel = nil
      job.phase = "scan"
    end

    local e = job.entries and job.entries[job.entry_idx] or nil
    if not e then
      job.pack_idx = job.pack_idx + 1
      job.current_pack = nil
      job.entries = nil
      job.phase_a_by_index = nil
      job.phase_b2_by_index = nil
      job.phase_d_by_index = nil
      job.phase_e_by_index = nil
      job.phase_d_count = 0
      job.phase_e_count = 0
      job.chunk_from = nil
      job.chunk_to = nil
      job.chunk_phase_a_by_rel = nil
      job.chunk_phase_b2_by_rel = nil
      job.chunk_phase_d_by_rel = nil
      job.chunk_phase_e_by_rel = nil
      job.entry_idx = 1
    else
      local idx = job.entry_idx
      local cf = tonumber(job.chunk_from)
      local ct = tonumber(job.chunk_to)
      if (not cf) or (not ct) or idx < cf or idx > ct then
        local from = idx
        local n_total = #job.entries
        local batch_sz = math.max(1, math.floor(tonumber(job.analysis_batch_size) or 8))
        local to_idx = math.min(n_total, from + batch_sz - 1)
        local chunk_entries = {}
        for gi = from, to_idx do
          local src = job.entries[gi]
          if src then
            chunk_entries[#chunk_entries + 1] = {
              full_path = src.full_path,
              filename = src.filename,
              ext = src.ext,
            }
          end
        end
        local phase_a_chunk = run_python_phase_a_batch(chunk_entries, job.current_pack.name)
        local phase_b2_chunk = run_python_phase_b2_batch(chunk_entries, job.current_pack.name)
        local phase_d_chunk = run_python_phase_d_batch(chunk_entries, job.current_pack.name)
        local phase_e_chunk = run_python_phase_e_batch(phase_d_chunk)
        job.phase_d_count = (job.phase_d_count or 0) + table_count_keys(phase_d_chunk)
        job.phase_e_count = (job.phase_e_count or 0) + table_count_keys(phase_e_chunk)
        job.chunk_from = from
        job.chunk_to = to_idx
        job.chunk_phase_a_by_rel = phase_a_chunk
        job.chunk_phase_b2_by_rel = phase_b2_chunk
        job.chunk_phase_d_by_rel = phase_d_chunk
        job.chunk_phase_e_by_rel = phase_e_chunk
        cf = from
      end
      local rel = idx - (cf or idx) + 1
      local hints = job.chunk_phase_a_by_rel and job.chunk_phase_a_by_rel[rel] or nil
      local hints_b2 = job.chunk_phase_b2_by_rel and job.chunk_phase_b2_by_rel[rel] or nil
      local features_d = job.chunk_phase_d_by_rel and job.chunk_phase_d_by_rel[rel] or nil
      local embed_e = job.chunk_phase_e_by_rel and job.chunk_phase_e_by_rel[rel] or nil
      local _ = upsert_sample_and_analysis(
        job.db, job.current_pack.id, job.source_type, nil,
        e.full_path, e.filename, e.ext,
        job.current_pack.name, job.splice_vocab, job.alias_map, hints, hints_b2, features_d, embed_e, job.splice_genre_vocab
      )
      job.entry_idx = job.entry_idx + 1
      job.processed = (job.processed or 0) + 1
      processed_now = processed_now + 1
      if (job.total or 0) > 0 then
        job.ratio = math.max(0.0, math.min(1.0, job.processed / job.total))
      else
        job.ratio = 1.0
      end
    end
  end

  return job.done == true, nil, {
    root_id = job.root_id,
    pack_name = (job.current_pack and job.current_pack.name) or "",
    processed = job.processed or 0,
    total = job.total or 0,
    ratio = job.ratio or 0,
    phase = job.phase or "scan",
    phase_d_count = job.phase_d_count or 0,
    phase_e_count = job.phase_e_count or 0,
  }
end

-- Backward-compatible synchronous API.
function M.rescan_root(store, root_id, opts)
  local opts_tbl = opts or {}
  local on_progress = (type(opts_tbl.on_progress) == "function") and opts_tbl.on_progress or nil
  local job, err = M.begin_rescan_root(store, root_id, opts_tbl)
  if not job then return false, err end
  if on_progress then
    pcall(on_progress, {
      root_id = root_id,
      pack_name = "",
      processed = 0,
      total = job.total or 0,
      ratio = 0,
      phase = "start",
    })
  end
  while true do
    local done, step_err, progress = M.step_rescan_job(job, 200)
    if step_err then return false, step_err end
    if on_progress and progress then pcall(on_progress, progress) end
    if done then break end
  end
  if on_progress then
    pcall(on_progress, {
      root_id = root_id,
      pack_name = "",
      processed = job.total or 0,
      total = job.total or 0,
      ratio = 1.0,
      phase = "done",
    })
  end
  return true
end

-- opts.sort: "name" (display/name, case-insensitive Latin), "count_desc", "count_asc"
-- Japanese pack names sort by SQLite UTF-8 byte order (not strict gojuon collation).
function M.get_packs(store, group_source_type, opts)
  local db = store.db
  if not db then return {} end

  local where_sql = ""
  if group_source_type == "splice" then
    where_sql = "WHERE p.source_type='splice'"
  elseif group_source_type == "other" then
    where_sql = "WHERE p.source_type!='splice'"
  end

  local sort_key_expr = "LOWER(COALESCE(NULLIF(TRIM(p.display_name), ''), p.name))"
  local order_sql
  local sort_mode = opts and opts.sort or "name"
  if sort_mode == "count_desc" then
    order_sql = string.format("ORDER BY sample_count DESC, %s ASC", sort_key_expr)
  elseif sort_mode == "count_asc" then
    order_sql = string.format("ORDER BY sample_count ASC, %s ASC", sort_key_expr)
  else
    order_sql = string.format("ORDER BY %s ASC", sort_key_expr)
  end

  local packs = {}
  local sql = string.format([[
    SELECT
      p.id,
      p.name,
      p.display_name,
      p.path,
      p.source_type,
      COUNT(s.id) AS sample_count,
      CASE WHEN EXISTS (SELECT 1 FROM pack_favorites f WHERE f.pack_id = p.id) THEN 1 ELSE 0 END AS is_favorite,
      COALESCE(NULLIF(TRIM(p.provider_name), ''), '') AS provider_name,
      MAX(COALESCE(NULLIF(TRIM(p.cover_url), ''), '')) AS cover_url
    FROM packs p
    LEFT JOIN samples s ON s.pack_id = p.id
    %s
    GROUP BY p.id, p.name, p.display_name, p.path, p.source_type, p.provider_name
    %s;
  ]], where_sql, order_sql)

  for row in db:nrows(sql) do
    local fav_raw = row.is_favorite or row[7]
    local prov = row.provider_name or row[8]
    local cov = row.cover_url or row[9]
    packs[#packs + 1] = {
      id = row.id or row[1],
      name = row.name or row[2],
      display_name = row.display_name or row[3],
      path = row.path or row[4],
      source_type = row.source_type or row[5],
      sample_count = tonumber(row.sample_count or row[6]) or 0,
      is_favorite = (tonumber(fav_raw) == 1) or fav_raw == true,
      provider_name = (prov and tostring(prov)) or "",
      cover_url = (cov and tostring(cov)) or "",
    }
  end
  return packs
end

--- pack_selection: nil = all packs; number >0 = single pack; table of ids = OR (any of those packs).
local function split_search_tokens_simple(text, max_tokens)
  local out = {}
  local s = tostring(text or ""):lower()
  max_tokens = math.max(1, tonumber(max_tokens) or 8)
  for token in s:gmatch("%S+") do
    local t = token:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then
      out[#out + 1] = t
      if #out >= max_tokens then break end
    end
  end
  return out
end

function M.get_samples(store, pack_selection, filters, limit, sort_spec)
  local db = store.db
  if not db then return {} end
  limit = limit or 50

  local where_parts = {}
  if type(pack_selection) == "table" and #pack_selection > 0 then
    local id_parts = {}
    for _, raw in ipairs(pack_selection) do
      local n = tonumber(raw)
      if n and n > 0 then id_parts[#id_parts + 1] = tostring(n) end
    end
    if #id_parts > 0 then
      where_parts[#where_parts + 1] = "s.pack_id IN (" .. table.concat(id_parts, ",") .. ")"
    end
  elseif type(pack_selection) == "number" and pack_selection > 0 then
    where_parts[#where_parts + 1] = string.format("s.pack_id=%d", pack_selection)
  end

  local type_expr = "COALESCE(mto.class_primary, a.class_primary)"
  local bpm_expr = "CASE WHEN mtko.bpm = -1 THEN NULL ELSE COALESCE(mtko.bpm, a.bpm) END"
  local key_expr = "CASE WHEN mtko.key_estimate = '__CLEAR__' THEN NULL ELSE COALESCE(mtko.key_estimate, a.key_estimate) END"

  -- Type
  local type_filters = {}
  if filters and filters.type_is_one_shot and not filters.type_is_loop then
    type_filters = { "oneshot" }
  elseif filters and filters.type_is_loop and not filters.type_is_one_shot then
    type_filters = { "loop" }
  elseif filters and filters.type_is_one_shot and filters.type_is_loop then
    type_filters = { "oneshot", "loop" }
  end
  if #type_filters > 0 then
    where_parts[#where_parts + 1] = type_expr .. " IN (" .. table.concat((function()
      local t = {}
      for _, v in ipairs(type_filters) do t[#t+1] = sql_quote(v) end
      return t
    end)(), ",") .. ")"
  end

  -- BPM range
  if filters and filters.bpm_min then
    where_parts[#where_parts + 1] = string.format("%s >= %f", bpm_expr, tonumber(filters.bpm_min) or 0)
  end
  if filters and filters.bpm_max then
    where_parts[#where_parts + 1] = string.format("%s <= %f", bpm_expr, tonumber(filters.bpm_max) or 0)
  end

  -- Key
  if filters and filters.key_root then
    local kr = tostring(filters.key_root)
    local has_major = filters.key_mode_major == true
    local has_minor = filters.key_mode_minor == true
    if has_major and has_minor then
      -- only major/minor variants (exclude root-only key text)
      where_parts[#where_parts + 1] = "("
        .. key_expr .. " = " .. sql_quote(kr .. " major")
        .. " OR " .. key_expr .. " = " .. sql_quote(kr .. " minor")
        .. ")"
    elseif has_major then
      where_parts[#where_parts + 1] = key_expr .. " = " .. sql_quote(kr .. " major")
    elseif has_minor then
      where_parts[#where_parts + 1] = key_expr .. " = " .. sql_quote(kr .. " minor")
    else
      -- root only: include "E", "E major", "E minor"
      where_parts[#where_parts + 1] = "("
        .. key_expr .. " = " .. sql_quote(kr)
        .. " OR " .. key_expr .. " LIKE " .. sql_quote(kr .. " %")
        .. ")"
    end
  end

  -- Text search (single input): filename or tags must match each token.
  -- Tokens are AND-ed, and each token matches filename OR tag text.
  if filters and filters.text_query and tostring(filters.text_query):gsub("%s+", "") ~= "" then
    local tokens = split_search_tokens_simple(filters.text_query, 8)
    for _, tok in ipairs(tokens) do
      local pattern = "%" .. tok .. "%"
      where_parts[#where_parts + 1] = string.format([[
      (
        LOWER(s.filename) LIKE %s
        OR EXISTS (
          SELECT 1
          FROM sample_tags st
          WHERE st.sample_id=s.id
            AND LOWER(st.tag) LIKE %s
        )
      )
    ]], sql_quote(pattern), sql_quote(pattern))
    end
  end

  -- Tag filter: sample must have ALL listed tags (AND)
  if filters and filters.filter_tags and type(filters.filter_tags) == "table" then
    for _, tg in ipairs(filters.filter_tags) do
      if tg and tostring(tg) ~= "" then
        where_parts[#where_parts + 1] = string.format([[
      EXISTS (
        SELECT 1
        FROM sample_tags t
        WHERE t.sample_id=s.id
          AND (
            t.tag=%s
            OR EXISTS (
              SELECT 1 FROM tag_aliases ta
              WHERE COALESCE(ta.enabled, 1)=1
                AND (
                  (ta.alias=t.tag AND ta.canonical_tag=%s)
                  OR (ta.alias=%s AND ta.canonical_tag=t.tag)
                )
            )
          )
      )
    ]], sql_quote(tostring(tg)), sql_quote(tostring(tg)), sql_quote(tostring(tg)))
      end
    end
  end

  -- Excluded tags: sample must have NONE of listed tags (NOT)
  if filters and filters.filter_tags_exclude and type(filters.filter_tags_exclude) == "table" then
    for _, tg in ipairs(filters.filter_tags_exclude) do
      if tg and tostring(tg) ~= "" then
        where_parts[#where_parts + 1] = string.format([[
      NOT EXISTS (
        SELECT 1
        FROM sample_tags t
        WHERE t.sample_id=s.id
          AND (
            t.tag=%s
            OR EXISTS (
              SELECT 1 FROM tag_aliases ta
              WHERE COALESCE(ta.enabled, 1)=1
                AND (
                  (ta.alias=t.tag AND ta.canonical_tag=%s)
                  OR (ta.alias=%s AND ta.canonical_tag=t.tag)
                )
            )
          )
      )
    ]], sql_quote(tostring(tg)), sql_quote(tostring(tg)), sql_quote(tostring(tg)))
      end
    end
  end

  -- Manual favorites only (tag 'favorite', source 'manual')
  if filters and filters.favorites_only == true then
    where_parts[#where_parts + 1] = [[
      EXISTS (
        SELECT 1 FROM sample_tags tf
        WHERE tf.sample_id=s.id AND tf.tag='favorite' AND tf.source='manual'
      )
    ]]
  end

  -- Samples whose pack is marked favorite (pack_favorites table)
  if filters and filters.pack_favorites_only == true then
    where_parts[#where_parts + 1] = [[
      EXISTS (SELECT 1 FROM pack_favorites pf WHERE pf.pack_id = s.pack_id)
    ]]
  end

  local where_sql = ""
  if #where_parts > 0 then where_sql = "WHERE " .. table.concat(where_parts, " AND ") end

  -- sort_spec.column: "filename" | "bpm" | "key" | "random" (default filename ASC)
  -- sort_spec.asc: boolean, default true
  -- Filename/key: LOWER for case-insensitive order (not strict Japanese collation).
  local function build_order_by(sort_spec)
    local col = (sort_spec and sort_spec.column) or "filename"
    local asc = true
    if sort_spec and sort_spec.asc == false then asc = false end
    local dir = asc and "ASC" or "DESC"
    local parts = {}
    if col == "random" then
      return "ORDER BY RANDOM()"
    elseif col == "bpm" then
      parts[#parts + 1] = "CASE WHEN (" .. bpm_expr .. ") IS NULL OR (" .. bpm_expr .. ") <= 0 THEN 1 ELSE 0 END ASC"
      parts[#parts + 1] = asc and "(" .. bpm_expr .. ") ASC" or "(" .. bpm_expr .. ") DESC"
    elseif col == "key" then
      parts[#parts + 1] =
        "CASE WHEN (" .. key_expr .. ") IS NULL OR TRIM(COALESCE((" .. key_expr .. "), '')) = '' THEN 1 ELSE 0 END ASC"
      parts[#parts + 1] = "LOWER((" .. key_expr .. ")) " .. dir
    else
      parts[#parts + 1] = "LOWER(s.filename) " .. dir
    end
    parts[#parts + 1] = "s.id ASC"
    return "ORDER BY " .. table.concat(parts, ", ")
  end

  local order_sql = build_order_by(sort_spec)

  local sql = string.format([[
    SELECT
      s.id,
      s.path,
      s.filename,
      CASE WHEN mtko.bpm = -1 THEN NULL ELSE COALESCE(mtko.bpm, a.bpm) END AS bpm,
      CASE WHEN mtko.key_estimate = '__CLEAR__' THEN NULL ELSE COALESCE(mtko.key_estimate, a.key_estimate) END AS key_estimate,
      COALESCE(mto.class_primary, a.class_primary) AS type,
      a.brightness AS brightness,
      a.noisiness AS noisiness,
      a.attack_sharpness AS attack_sharpness,
      a.decay_length AS decay_length,
      a.tonalness AS tonalness,
      a.embed_x AS embed_x,
      a.embed_y AS embed_y,
      s.pack_id,
      COALESCE(NULLIF(TRIM(p.display_name), ''), p.name) AS pack_name,
      COALESCE(NULLIF(TRIM(p.cover_url), ''), '') AS pack_cover_url,
      CASE WHEN EXISTS (
        SELECT 1 FROM sample_tags tf
        WHERE tf.sample_id=s.id AND tf.tag='favorite' AND tf.source='manual'
      ) THEN 1 ELSE 0 END AS is_favorite
    FROM samples s
    LEFT JOIN analysis a ON a.sample_id = s.id
    LEFT JOIN manual_type_overrides mto ON mto.sample_id = s.id
    LEFT JOIN manual_tempo_key_overrides mtko ON mtko.sample_id = s.id
    LEFT JOIN packs p ON p.id = s.pack_id
    %s
    %s
    LIMIT %d;
  ]], where_sql, order_sql, limit)

  local out = {}
  for row in db:nrows(sql) do
    -- Normalize to a stable shape for UI.
    -- Some SQLite Lua bindings expose row fields by index only; we unify both.
    local fav_raw = row.is_favorite or row[17]
    out[#out + 1] = {
      id = row.id or row[1],
      path = row.path or row[2],
      filename = row.filename or row[3],
      bpm = row.bpm or row[4],
      key_estimate = row.key_estimate or row[5],
      type = row.type or row[6],
      brightness = row.brightness or row[7],
      noisiness = row.noisiness or row[8],
      attack_sharpness = row.attack_sharpness or row[9],
      decay_length = row.decay_length or row[10],
      tonalness = row.tonalness or row[11],
      embed_x = row.embed_x or row[12],
      embed_y = row.embed_y or row[13],
      pack_id = row.pack_id or row[14],
      pack_name = row.pack_name or row[15],
      pack_cover_url = row.pack_cover_url or row[16] or "",
      is_favorite = (tonumber(fav_raw) == 1) or fav_raw == true,
    }
  end
  return out
end

-- Normalize path for case-insensitive compare (slashes, lower). Not a full realpath.
local function normalize_path_for_match(p)
  if not p or p == "" then return nil end
  p = tostring(p):gsub("\\", "/"):gsub("//+", "/")
  return p:lower()
end

-- Returns one row in the same shape as get_samples entries, or nil.
function M.find_sample_by_path(store, file_path)
  local db = store and store.db
  if not db or not file_path or file_path == "" then return nil end
  local key = normalize_path_for_match(file_path)
  if not key then return nil end
  local sql = string.format([[
    SELECT
      s.id,
      s.path,
      s.filename,
      CASE WHEN mtko.bpm = -1 THEN NULL ELSE COALESCE(mtko.bpm, a.bpm) END AS bpm,
      CASE WHEN mtko.key_estimate = '__CLEAR__' THEN NULL ELSE COALESCE(mtko.key_estimate, a.key_estimate) END AS key_estimate,
      COALESCE(mto.class_primary, a.class_primary) AS type,
      a.brightness AS brightness,
      a.noisiness AS noisiness,
      a.attack_sharpness AS attack_sharpness,
      a.decay_length AS decay_length,
      a.tonalness AS tonalness,
      a.embed_x AS embed_x,
      a.embed_y AS embed_y,
      s.pack_id,
      COALESCE(NULLIF(TRIM(p.display_name), ''), p.name) AS pack_name,
      COALESCE(NULLIF(TRIM(p.cover_url), ''), '') AS pack_cover_url,
      CASE WHEN EXISTS (
        SELECT 1 FROM sample_tags tf
        WHERE tf.sample_id=s.id AND tf.tag='favorite' AND tf.source='manual'
      ) THEN 1 ELSE 0 END AS is_favorite
    FROM samples s
    LEFT JOIN analysis a ON a.sample_id = s.id
    LEFT JOIN manual_type_overrides mto ON mto.sample_id = s.id
    LEFT JOIN manual_tempo_key_overrides mtko ON mtko.sample_id = s.id
    LEFT JOIN packs p ON p.id = s.pack_id
    WHERE lower(replace(replace(s.path, char(92), '/'), '//', '/')) = %s
    LIMIT 1;
  ]], sql_quote(key))
  for row in db:nrows(sql) do
    local fav_raw = row.is_favorite or row[17]
    return {
      id = row.id or row[1],
      path = row.path or row[2],
      filename = row.filename or row[3],
      bpm = row.bpm or row[4],
      key_estimate = row.key_estimate or row[5],
      type = row.type or row[6],
      brightness = row.brightness or row[7],
      noisiness = row.noisiness or row[8],
      attack_sharpness = row.attack_sharpness or row[9],
      decay_length = row.decay_length or row[10],
      tonalness = row.tonalness or row[11],
      embed_x = row.embed_x or row[12],
      embed_y = row.embed_y or row[13],
      pack_id = row.pack_id or row[14],
      pack_name = row.pack_name or row[15],
      pack_cover_url = row.pack_cover_url or row[16] or "",
      is_favorite = (tonumber(fav_raw) == 1) or fav_raw == true,
    }
  end
  return nil
end

local function collect_unique_sample_ids(sample_ids)
  local ids = {}
  local seen = {}
  for _, raw in ipairs(sample_ids or {}) do
    local n = tonumber(raw)
    if n and n > 0 and not seen[n] then
      seen[n] = true
      ids[#ids + 1] = n
    end
  end
  return ids
end

--- Manual override of type(class): oneshot/loop for multiple samples.
--- new_type: "oneshot" | "loop" | nil/"" (clear override)
function M.set_manual_type_for_samples(store, sample_ids, new_type)
  local db = store and store.db
  if not db then return false, "no db" end
  if type(sample_ids) ~= "table" or #sample_ids == 0 then return false, "no sample ids" end

  local norm = nil
  if new_type ~= nil and tostring(new_type) ~= "" then
    norm = tostring(new_type):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if norm ~= "oneshot" and norm ~= "loop" then
      return false, "invalid type"
    end
  end

  local ids = collect_unique_sample_ids(sample_ids)
  if #ids == 0 then return false, "no valid sample ids" end

  local now = os.time()
  exec_safe(db, "BEGIN;")
  for _, id in ipairs(ids) do
    if norm then
      exec_safe(db, string.format([[
        INSERT OR REPLACE INTO manual_type_overrides(sample_id, class_primary, updated_at)
        VALUES(%d, %s, %d);
      ]], id, sql_quote(norm), now))
    else
      exec_safe(db, string.format(
        "DELETE FROM manual_type_overrides WHERE sample_id=%d;",
        id
      ))
    end
  end
  exec_safe(db, "COMMIT;")
  return true, #ids
end

function M.set_manual_bpm_for_samples(store, sample_ids, new_bpm)
  local db = store and store.db
  if not db then return false, "no db" end
  if type(sample_ids) ~= "table" or #sample_ids == 0 then return false, "no sample ids" end
  local ids = collect_unique_sample_ids(sample_ids)
  if #ids == 0 then return false, "no valid sample ids" end

  local bpm = nil
  local clear_bpm = (new_bpm ~= nil and tostring(new_bpm) == "__CLEAR__")
  if (not clear_bpm) and new_bpm ~= nil and tostring(new_bpm) ~= "" then
    bpm = tonumber(new_bpm)
    if not bpm or bpm <= 0 then return false, "invalid bpm" end
  end

  local now = os.time()
  exec_safe(db, "BEGIN;")
  for _, id in ipairs(ids) do
    exec_safe(db, string.format([[
      INSERT OR IGNORE INTO manual_tempo_key_overrides(sample_id, bpm, key_estimate, updated_at)
      VALUES(%d, NULL, NULL, %d);
    ]], id, now))
    exec_safe(db, string.format([[
      UPDATE manual_tempo_key_overrides
      SET bpm=%s, updated_at=%d
      WHERE sample_id=%d;
    ]], clear_bpm and "-1" or (bpm and tostring(bpm) or "NULL"), now, id))
    exec_safe(db, string.format([[
      DELETE FROM manual_tempo_key_overrides
      WHERE sample_id=%d AND bpm IS NULL AND (key_estimate IS NULL OR TRIM(key_estimate)='');
    ]], id))
  end
  exec_safe(db, "COMMIT;")
  return true, #ids
end

--- Remove manual BPM override and go back to detected/default BPM.
function M.reset_bpm_to_detected_for_samples(store, sample_ids)
  return M.set_manual_bpm_for_samples(store, sample_ids, nil)
end

function M.set_manual_key_for_samples(store, sample_ids, new_key)
  local db = store and store.db
  if not db then return false, "no db" end
  if type(sample_ids) ~= "table" or #sample_ids == 0 then return false, "no sample ids" end
  local ids = collect_unique_sample_ids(sample_ids)
  if #ids == 0 then return false, "no valid sample ids" end

  local key_text = nil
  local clear_key = (new_key ~= nil and tostring(new_key) == "__CLEAR__")
  if (not clear_key) and new_key ~= nil and tostring(new_key) ~= "" then
    key_text = tostring(new_key):gsub("^%s+", ""):gsub("%s+$", "")
    if key_text == "" then key_text = nil end
  end

  local now = os.time()
  exec_safe(db, "BEGIN;")
  for _, id in ipairs(ids) do
    exec_safe(db, string.format([[
      INSERT OR IGNORE INTO manual_tempo_key_overrides(sample_id, bpm, key_estimate, updated_at)
      VALUES(%d, NULL, NULL, %d);
    ]], id, now))
    exec_safe(db, string.format([[
      UPDATE manual_tempo_key_overrides
      SET key_estimate=%s, updated_at=%d
      WHERE sample_id=%d;
    ]], clear_key and sql_quote("__CLEAR__") or (key_text and sql_quote(key_text) or "NULL"), now, id))
    exec_safe(db, string.format([[
      DELETE FROM manual_tempo_key_overrides
      WHERE sample_id=%d AND bpm IS NULL AND (key_estimate IS NULL OR TRIM(key_estimate)='');
    ]], id))
  end
  exec_safe(db, "COMMIT;")
  return true, #ids
end

--- Remove manual key override and go back to detected/default key.
function M.reset_key_to_detected_for_samples(store, sample_ids)
  return M.set_manual_key_for_samples(store, sample_ids, nil)
end

--- Distinct tag strings for a sample (excludes manual `favorite` row; UI has its own Favorite control).
function M.get_tags_for_sample(store, sample_id)
  local db = store and store.db
  if not db then return {} end
  local id = tonumber(sample_id)
  if not id or id < 1 then return {} end
  local sql = string.format([[
    SELECT DISTINCT tag FROM sample_tags
    WHERE sample_id=%d
      AND NOT (tag='favorite' AND source='manual')
    ORDER BY LOWER(tag);
  ]], id)
  local out = {}
  for row in db:nrows(sql) do
    local t = row.tag or row[1]
    if t and tostring(t) ~= "" then
      out[#out + 1] = tostring(t)
    end
  end
  return out
end

--- Detailed tag rows for debugging: includes source and score.
function M.get_tag_rows_for_sample(store, sample_id)
  local db = store and store.db
  if not db then return {} end
  local id = tonumber(sample_id)
  if not id or id < 1 then return {} end
  local sql = string.format([[
    SELECT tag, source, score
    FROM sample_tags
    WHERE sample_id=%d
      AND NOT (tag='favorite' AND source='manual')
    ORDER BY source ASC, score DESC, LOWER(tag) ASC;
  ]], id)
  local out = {}
  for row in db:nrows(sql) do
    local t = row.tag or row[1]
    local s = row.source or row[2]
    local sc = tonumber(row.score or row[3])
    if t and s and tostring(t) ~= "" and tostring(s) ~= "" then
      out[#out + 1] = {
        tag = tostring(t),
        source = tostring(s),
        score = sc,
      }
    end
  end
  return out
end

--- Add/remove a manual tag for multiple samples.
--- sample_ids: array of sample_id numbers.
--- tag: non-empty string (favorite is reserved by dedicated favorite UI).
--- want_add: true=insert, false=delete.
--- Returns true, changed_count on success.
function M.set_manual_tag_for_samples(store, sample_ids, tag, want_add)
  local db = store and store.db
  if not db then return false, "no db" end
  if type(sample_ids) ~= "table" or #sample_ids == 0 then return false, "no sample ids" end
  tag = tostring(tag or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if tag == "" then return false, "empty tag" end
  local tag_lc = tag:lower()
  local reserved = {
    favorite = true,
    loop = true,
    loops = true,
    oneshot = true,
    oneshots = true,
  }
  if want_add and reserved[tag_lc] then
    return false, "reserved tag: " .. tag_lc
  end

  local ids = {}
  local seen = {}
  for _, raw in ipairs(sample_ids) do
    local n = tonumber(raw)
    if n and n > 0 and not seen[n] then
      seen[n] = true
      ids[#ids + 1] = n
    end
  end
  if #ids == 0 then return false, "no valid sample ids" end

  local now = os.time()
  local changed = 0
  exec_safe(db, "BEGIN;")
  for _, id in ipairs(ids) do
    if want_add then
      local ok = exec_safe(db, string.format([[
        INSERT OR IGNORE INTO sample_tags(sample_id, tag, score, source, created_at)
        VALUES(%d, %s, 1.0, 'manual', %d);
      ]], id, sql_quote(tag), now))
      if ok then changed = changed + 1 end
    else
      local ok = exec_safe(db, string.format([[
        DELETE FROM sample_tags
        WHERE sample_id=%d AND tag=%s;
      ]], id, sql_quote(tag)))
      if ok then changed = changed + 1 end
    end
  end
  exec_safe(db, "COMMIT;")
  return true, changed
end

--- Add/remove a manual tag for all samples in a pack.
--- pack_id: packs.id (integer).
--- tag: non-empty string (favorite is reserved by dedicated favorite UI).
--- want_add: true=insert, false=delete.
--- Returns true, changed_count_hint on success (may be 0/approx due to SQLite rowcount limitations).
function M.set_manual_tag_for_pack(store, pack_id, tag, want_add)
  local db = store and store.db
  if not db then return false, "no db" end
  local pid = tonumber(pack_id)
  if not pid or pid < 1 then return false, "bad pack_id" end
  tag = tostring(tag or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if tag == "" then return false, "empty tag" end
  local tag_lc = tag:lower()
  local reserved = {
    favorite = true,
    loop = true,
    loops = true,
    oneshot = true,
    oneshots = true,
  }
  if want_add and reserved[tag_lc] then
    return false, "reserved tag: " .. tag_lc
  end

  local now = os.time()
  exec_safe(db, "BEGIN;")
  if want_add then
    exec_safe(db, string.format([[
      INSERT OR IGNORE INTO sample_tags(sample_id, tag, score, source, created_at)
      SELECT s.id, %s, 1.0, 'manual', %d
      FROM samples s
      WHERE s.pack_id=%d;
    ]], sql_quote(tag), now, pid))
  else
    exec_safe(db, string.format([[
      DELETE FROM sample_tags
      WHERE sample_id IN (SELECT id FROM samples WHERE pack_id=%d)
        AND tag=%s;
    ]], pid, sql_quote(tag)))
  end
  exec_safe(db, "COMMIT;")
  return true, 0
end

--- Reset tag edits to default(auto) state for selected samples.
--- - clears manual tags (except manual favorite)
--- - rebuilds filename_guess / tag_candidate / genre_guess for non-splice samples
function M.reset_tags_to_default_for_samples(store, sample_ids)
  local db = store and store.db
  if not db then return false, "no db" end
  if type(sample_ids) ~= "table" or #sample_ids == 0 then return false, "no sample ids" end
  local ids = collect_unique_sample_ids(sample_ids)
  if #ids == 0 then return false, "no valid sample ids" end

  local splice_vocab = get_splice_tag_vocab(db)
  local alias_map = get_tag_alias_map(db)
  local splice_genre_vocab = get_splice_genre_vocab(db)
  local changed = 0

  exec_safe(db, "BEGIN;")
  for _, sid in ipairs(ids) do
    exec_safe(db, string.format([[
      DELETE FROM sample_tags
      WHERE sample_id=%d AND source='manual' AND tag<>'favorite';
    ]], sid))

    local info_sql = string.format([[
      SELECT
        s.id,
        s.path,
        s.filename,
        s.source,
        s.pack_id,
        COALESCE(NULLIF(TRIM(p.display_name), ''), p.name) AS pack_name,
        COALESCE(a.class_primary, '') AS class_primary,
        a.bpm AS bpm
      FROM samples s
      LEFT JOIN packs p ON p.id = s.pack_id
      LEFT JOIN analysis a ON a.sample_id = s.id
      WHERE s.id=%d
      LIMIT 1;
    ]], sid)

    local row = nil
    for r in db:nrows(info_sql) do
      row = r
      break
    end
    if row then
      local source = tostring(row.source or "")
      if source ~= "splice" then
        local filename = tostring(row.filename or "")
        local file_path = tostring(row.path or "")
        local pack_name = tostring(row.pack_name or "")
        local class_primary = tostring(row.class_primary or "")
        local bpm_value = tonumber(row.bpm)

        local guess_tags = build_filename_guess_tags(filename, file_path, pack_name, splice_vocab, alias_map, nil, nil)
        local strong = {}
        local weak = {}
        for _, tg in ipairs(guess_tags or {}) do
          local sc = tonumber(tg.score or 0) or 0
          if sc >= 0.72 then
            strong[#strong + 1] = tg
          else
            weak[#weak + 1] = tg
          end
        end
        replace_filename_guess_tags(db, sid, strong)
        replace_tag_candidate_tags(db, sid, weak)
        if class_primary == "loop" then
          local genre_tags = infer_genre_guess_tags(db, filename, bpm_value, splice_genre_vocab, alias_map)
          replace_genre_guess_tags(db, sid, genre_tags)
        else
          replace_genre_guess_tags(db, sid, {})
        end
      end
    end
    changed = changed + 1
  end
  exec_safe(db, "COMMIT;")
  return true, changed
end

--- Tags grouped by usage count (for chip UI). Excludes manual favorite row.
--- opts.limit: max rows (default 20). opts.name_contains: substring filter on tag text (LIKE).
function M.get_tags_by_usage(store, opts)
  opts = opts or {}
  local limit = tonumber(opts.limit) or 20
  if limit < 1 then limit = 1 end
  if limit > 200 then limit = 200 end
  local db = store and store.db
  if not db then return {} end

  local parts = { "NOT (t.tag='favorite' AND t.source='manual')" }
  local substr = opts.name_contains
  if substr and tostring(substr) ~= "" then
    local tq = tostring(substr)
    tq = tq:gsub("\\", "\\\\"):gsub("%%", "\\%%"):gsub("_", "\\_")
    local like_expr = "%" .. tq .. "%"
    parts[#parts + 1] = "t.tag LIKE " .. sql_quote(like_expr) .. " ESCAPE '\\'"
  end
  local where_sql = "WHERE " .. table.concat(parts, " AND ")

  local sql = string.format([[
    SELECT t.tag AS tag, COUNT(*) AS cnt
    FROM sample_tags t
    %s
    GROUP BY t.tag
    ORDER BY cnt DESC, LOWER(t.tag) ASC
    LIMIT %d;
  ]], where_sql, limit)

  local out = {}
  for row in db:nrows(sql) do
    out[#out + 1] = {
      tag = tostring(row.tag or row[1] or ""),
      count = tonumber(row.cnt or row[2]) or 0,
    }
  end
  return out
end

--- Tag suggestions / co-occurring tags for the filter UI.
--- If filter_tags is non-empty: rank tags by how often they appear on samples that have ALL filter tags (co-occurrence).
--- Optional name_contains: substring filter (LIKE); if omitted/empty, all co-occurring tags are considered (still limited).
--- If filter_tags is empty and name_contains set: same as get_tags_by_usage (global frequency + substring).
--- If both empty: returns {}.
function M.get_tag_filter_suggestions(store, opts)
  opts = opts or {}
  local db = store and store.db
  if not db then return {} end
  local limit = tonumber(opts.limit) or 40
  if limit < 1 then limit = 1 end
  if limit > 200 then limit = 200 end

  local filter_list = opts.filter_tags
  local has_filter = type(filter_list) == "table" and #filter_list > 0

  local substr = opts.name_contains
  local has_substr = substr and tostring(substr) ~= ""

  if not has_filter and not has_substr then
    return {}
  end

  if not has_filter and has_substr then
    return M.get_tags_by_usage(store, { limit = limit, name_contains = substr })
  end

  local like_clause = "1=1"
  if has_substr then
    local tq = tostring(substr)
    tq = tq:gsub("\\", "\\\\"):gsub("%%", "\\%%"):gsub("_", "\\_")
    local like_expr = "%" .. tq .. "%"
    like_clause = "t.tag LIKE " .. sql_quote(like_expr) .. " ESCAPE '\\'"
  end

  local exists_parts = {}
  for _, tg in ipairs(filter_list) do
    if tg and tostring(tg) ~= "" then
      exists_parts[#exists_parts + 1] = string.format(
        "EXISTS (SELECT 1 FROM sample_tags x WHERE x.sample_id=s.id AND x.tag=%s)",
        sql_quote(tostring(tg))
      )
    end
  end
  if #exists_parts == 0 then
    if has_substr then
      return M.get_tags_by_usage(store, { limit = limit, name_contains = substr })
    end
    return {}
  end
  local sample_where = table.concat(exists_parts, " AND ")

  local quoted_filters = {}
  for _, tg in ipairs(filter_list) do
    if tg and tostring(tg) ~= "" then
      quoted_filters[#quoted_filters + 1] = sql_quote(tostring(tg))
    end
  end
  local not_in_sql = ""
  if #quoted_filters > 0 then
    not_in_sql = " AND t.tag NOT IN (" .. table.concat(quoted_filters, ",") .. ")"
  end

  local sql = string.format([[
    SELECT t.tag AS tag, COUNT(DISTINCT t.sample_id) AS cnt
    FROM sample_tags t
    WHERE t.sample_id IN (
      SELECT s.id FROM samples s
      WHERE %s
    )
    AND NOT (t.tag='favorite' AND t.source='manual')
    AND (%s)
    %s
    GROUP BY t.tag
    ORDER BY cnt DESC, LOWER(t.tag) ASC
    LIMIT %d;
  ]], sample_where, like_clause, not_in_sql, limit)

  local out = {}
  for row in db:nrows(sql) do
    out[#out + 1] = {
      tag = tostring(row.tag or row[1] or ""),
      count = tonumber(row.cnt or row[2]) or 0,
    }
  end
  return out
end

function M.list_roots(store)
  local db = store and store.db
  if not db then return {} end
  local out = {}
  for row in db:nrows("SELECT id, path, mode, source_type, enabled FROM roots ORDER BY id ASC;") do
    out[#out + 1] = {
      id = row.id or row[1],
      path = row.path or row[2],
      mode = row.mode or row[3],
      source_type = row.source_type or row[4],
      enabled = row.enabled or row[5],
    }
  end
  return out
end

function M.delete_root(store, root_id)
  local db = store and store.db
  local rid = tonumber(root_id)
  if not db then return false, "no db" end
  if not rid or rid < 1 then return false, "invalid root id" end
  exec_safe(db, string.format("DELETE FROM roots WHERE id=%d;", rid))
  return true
end

function M.import_splice_db(store, splice_db_path)
  local main_db = store and store.db
  if not main_db then return false, "main db not ready" end
  if not splice_db_path or splice_db_path == "" then return false, "splice db path is empty" end
  if not store.db_module then return false, "sqlite module not available in store.db_module" end

  local src_db, open_err = try_db_open(store.db_module, splice_db_path)
  if not src_db then
    return false, "failed to open splice db: " .. tostring(open_err)
  end

  local root_path = "splice_db::" .. tostring(splice_db_path)
  local root_id = get_or_create_root(main_db, root_path, "pack_root", "splice")
  if not root_id then
    if src_db and src_db.close then pcall(function() src_db:close() end) end
    return false, "failed to create/get splice root"
  end

  exec_safe(main_db, "BEGIN;")

  local samples_has_provider = false
  pcall(function()
    for cr in src_db:nrows("PRAGMA table_info(samples);") do
      local cnm = cr.name or cr[2]
      if cnm == "provider_name" then
        samples_has_provider = true
        break
      end
    end
  end)

  local packs_has_cover_url = false
  pcall(function()
    for cr in src_db:nrows("PRAGMA table_info(packs);") do
      local cnm = cr.name or cr[2]
      if cnm == "cover_url" then
        packs_has_cover_url = true
        break
      end
    end
  end)

  -- uuid -> { name, provider, cover_url } from Splice packs (provider/cover may be missing on older sounds.db)
  local pack_info = {}
  do
    local meta_ok = pcall(function()
      if packs_has_cover_url then
        for prow in src_db:nrows("SELECT uuid, name, provider_name, cover_url FROM packs;") do
          local uuid = tostring(prow.uuid or prow[1] or "")
          if uuid ~= "" then
            local nm = prow.name or prow[2]
            local pvn = prow.provider_name or prow[3]
            local cvu = prow.cover_url or prow[4]
            local pnm = (nm and tostring(nm) ~= "") and tostring(nm) or ("pack_" .. uuid)
            local prv = ""
            if pvn and tostring(pvn) ~= "" then
              prv = tostring(pvn):match("^%s*(.-)%s*$") or ""
            end
            local cv = ""
            if cvu and tostring(cvu) ~= "" then
              cv = tostring(cvu):match("^%s*(.-)%s*$") or ""
            end
            pack_info[uuid] = { name = pnm, provider = prv, cover_url = cv }
          end
        end
      else
        for prow in src_db:nrows("SELECT uuid, name, provider_name FROM packs;") do
          local uuid = tostring(prow.uuid or prow[1] or "")
          if uuid ~= "" then
            local nm = prow.name or prow[2]
            local pvn = prow.provider_name or prow[3]
            local pnm = (nm and tostring(nm) ~= "") and tostring(nm) or ("pack_" .. uuid)
            local prv = ""
            if pvn and tostring(pvn) ~= "" then
              prv = tostring(pvn):match("^%s*(.-)%s*$") or ""
            end
            pack_info[uuid] = { name = pnm, provider = prv, cover_url = "" }
          end
        end
      end
    end)
    if not meta_ok or next(pack_info) == nil then
      for prow in src_db:nrows("SELECT uuid, name FROM packs;") do
        local uuid = tostring(prow.uuid or prow[1] or "")
        if uuid ~= "" then
          local nm = prow.name or prow[2]
          pack_info[uuid] = {
            name = (nm and tostring(nm) ~= "") and tostring(nm) or ("pack_" .. uuid),
            provider = "",
            cover_url = "",
          }
        end
      end
    end
  end

  local sample_sql_with_pv = [[
    SELECT id, local_path, filename, sample_type, bpm, audio_key, chord_type, tags, pack_uuid, provider_name
    FROM samples;
  ]]
  local sample_sql_no_pv = [[
    SELECT id, local_path, filename, sample_type, bpm, audio_key, chord_type, tags, pack_uuid FROM samples;
  ]]

  local imported = 0
  local pack_prov_applied = {}
  local pack_cover_applied = {}
  for row in src_db:nrows(samples_has_provider and sample_sql_with_pv or sample_sql_no_pv) do
    local local_path = row.local_path or row[2]
    if local_path and tostring(local_path) ~= "" then
      local source_sample_id = tostring(row.id or row[1] or "")
      local filename = row.filename or row[3] or tostring(local_path):match("([^/\\]+)$") or "unknown"
      local sample_type = tostring(row.sample_type or row[4] or ""):lower()
      local bpm_raw = tonumber(row.bpm or row[5])
      local audio_key = row.audio_key or row[6]
      local chord_type = row.chord_type or row[7]
      local tags_text = row.tags or row[8]
      local pack_uuid = tostring(row.pack_uuid or row[9] or "")
      local sample_provider = ""
      if samples_has_provider then
        local pv = row.provider_name or row[10]
        if pv and tostring(pv) ~= "" then
          sample_provider = tostring(pv):match("^%s*(.-)%s*$") or ""
        end
      end

      local pinf = (pack_uuid ~= "" and pack_info[pack_uuid]) or nil
      local pack_name = (pinf and pinf.name) or "Unknown Splice Pack"
      local pack_path = (pack_uuid ~= "") and ("splice://" .. pack_uuid) or ("splice://unknown_pack")
      local pack_id = get_or_create_pack(main_db, root_id, pack_name, pack_path, "splice")
      local now = os.time()

      local pv_merge = (pinf and pinf.provider) or ""
      if pv_merge == "" and sample_provider ~= "" then
        pv_merge = sample_provider
      end
      if pv_merge ~= "" and not pack_prov_applied[pack_id] then
        exec_safe(main_db, string.format(
          "UPDATE packs SET provider_name=%s, updated_at=%d WHERE id=%d;",
          sql_quote(pv_merge),
          now,
          pack_id
        ))
        pack_prov_applied[pack_id] = true
      end

      local cover_merge = ""
      if pinf and pinf.cover_url and tostring(pinf.cover_url) ~= "" then
        cover_merge = tostring(pinf.cover_url):match("^%s*(.-)%s*$") or ""
      end
      if cover_merge ~= "" and not pack_cover_applied[pack_id] then
        exec_safe(main_db, string.format(
          "UPDATE packs SET cover_url=%s, updated_at=%d WHERE id=%d;",
          sql_quote(cover_merge),
          now,
          pack_id
        ))
        pack_cover_applied[pack_id] = true
      end
      local qpath = sql_quote(tostring(local_path))
      local qfilename = sql_quote(tostring(filename))
      local ext = tostring(local_path):match("%.([^%.]+)$") or ""
      ext = ext:lower()

      exec_safe(main_db, string.format([[
        INSERT OR IGNORE INTO samples(pack_id, source, source_sample_id, path, filename, ext, size_bytes, mtime_unix, created_at, updated_at)
        VALUES(%d, 'splice', %s, %s, %s, %s, 0, 0, %d, %d);
      ]], pack_id, sql_quote(source_sample_id), qpath, qfilename, sql_quote(ext), now, now))

      exec_safe(main_db, string.format([[
        UPDATE samples
        SET pack_id=%d, source='splice', source_sample_id=%s, filename=%s, ext=%s, updated_at=%d
        WHERE path=%s;
      ]], pack_id, sql_quote(source_sample_id), qfilename, sql_quote(ext), now, qpath))

      local sample_id = get_singleton_int(main_db, string.format("SELECT id FROM samples WHERE path=%s;", qpath))
      if sample_id then
        local class_primary = (sample_type == "loop") and "loop" or "oneshot"
        local bpm = (bpm_raw and bpm_raw > 0) and bpm_raw or nil
        local key_estimate = normalize_key_estimate(audio_key, chord_type)

        exec_safe(main_db, string.format([[
          INSERT OR REPLACE INTO analysis(
            sample_id,
            class_primary, class_confidence, class_source,
            bpm, bpm_confidence, bpm_source,
            key_estimate, key_confidence, key_source,
            analyzed_at, analysis_version
          ) VALUES(
            %d,
            %s, %s, 'splice',
            %s, %s, %s,
            %s, %s, %s,
            %d, 'splice_sounds_db_v0_1'
          );
        ]],
          sample_id,
          sql_quote(class_primary),
          "1.0",
          bpm and tostring(bpm) or "NULL",
          bpm and "1.0" or "NULL",
          bpm and "'splice'" or "NULL",
          sql_quote(key_estimate),
          key_estimate and "1.0" or "NULL",
          key_estimate and "'splice'" or "NULL",
          now
        ))

        -- Refresh splice tags for this sample
        exec_safe(main_db, string.format("DELETE FROM sample_tags WHERE sample_id=%d AND source='splice';", sample_id))
        local tags = split_csv_tags(tags_text)
        for _, tag in ipairs(tags) do
          exec_safe(main_db, string.format([[
            INSERT OR IGNORE INTO sample_tags(sample_id, tag, score, source, created_at)
            VALUES(%d, %s, 1.0, 'splice', %d);
          ]], sample_id, sql_quote(tag), now))
        end

        imported = imported + 1
      end
    end
  end

  exec_safe(main_db, "COMMIT;")
  if src_db and src_db.close then pcall(function() src_db:close() end) end
  return true, imported
end

--- Manual favorite: sample_tags row tag='favorite', source='manual' (distinct from Splice tags).
function M.set_sample_favorite(store, sample_id, want_favorite)
  local db = store and store.db
  if not db then return false, "no db" end
  local id = tonumber(sample_id)
  if not id or id < 1 then return false, "bad sample_id" end
  local now = os.time()
  if want_favorite then
    local ok = exec_safe(db, string.format([[
      INSERT OR IGNORE INTO sample_tags(sample_id, tag, score, source, created_at)
      VALUES(%d, 'favorite', 1.0, 'manual', %d);
    ]], id, now))
    return ok == true
  end
  local ok = exec_safe(db, string.format(
    "DELETE FROM sample_tags WHERE sample_id=%d AND tag='favorite' AND source='manual';",
    id
  ))
  return ok == true
end

function M.set_pack_favorite(store, pack_id, want_favorite)
  local db = store and store.db
  if not db then return false, "no db" end
  local id = tonumber(pack_id)
  if not id or id < 1 then return false, "bad pack_id" end
  if want_favorite then
    local ok = exec_safe(db, string.format(
      "INSERT OR IGNORE INTO pack_favorites(pack_id) VALUES(%d);",
      id
    ))
    return ok == true
  end
  local ok = exec_safe(db, string.format("DELETE FROM pack_favorites WHERE pack_id=%d;", id))
  return ok == true
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

local function collect_phase_d_rows_for_embedding(db, only_oneshot)
  local where = only_oneshot and "WHERE COALESCE(class_primary,'')='oneshot'" or ""
  local sql = string.format([[
    SELECT
      sample_id,
      brightness,
      noisiness,
      attack_sharpness,
      decay_length,
      tonalness,
      spectral_centroid_norm,
      spectral_rolloff_norm,
      spectral_bandwidth_norm,
      spectral_flatness,
      mfcc_timbre_norm
    FROM analysis
    %s;
  ]], where)
  local phase_d_by_index = {}
  local total = 0
  for row in db:nrows(sql) do
    local sid = tonumber(row.sample_id or row[1])
    if sid then
      total = total + 1
      phase_d_by_index[sid] = {
        brightness = row.brightness or row[2],
        noisiness = row.noisiness or row[3],
        attack_sharpness = row.attack_sharpness or row[4],
        decay_length = row.decay_length or row[5],
        tonalness = row.tonalness or row[6],
        spectral_centroid_norm = row.spectral_centroid_norm or row[7],
        spectral_rolloff_norm = row.spectral_rolloff_norm or row[8],
        spectral_bandwidth_norm = row.spectral_bandwidth_norm or row[9],
        spectral_flatness = row.spectral_flatness or row[10],
        mfcc_timbre_norm = row.mfcc_timbre_norm or row[11],
      }
    end
  end
  return phase_d_by_index, total, where
end

function M.build_galaxy_embedding_profiles(store, opts)
  local db = store and store.db
  if not db then return false, "no db" end
  opts = type(opts) == "table" and opts or {}
  local only_oneshot = opts.only_oneshot ~= false
  local now = os.time()
  local phase_d_by_index, total = collect_phase_d_rows_for_embedding(db, only_oneshot)
  if total == 0 then return false, "no analysis rows" end
  local base_preset = tostring(PHASE_E_PRESET or "core5")
  local profile_keys = {}
  local profile_stats = {}
  exec_safe(db, "BEGIN;")
  for _, spec in ipairs(GALAXY_EMBED_PROFILE_VARIANTS) do
    local profile_key = base_preset .. ":" .. tostring(spec.key)
    profile_keys[#profile_keys + 1] = profile_key
    local pe_opts = {
      umap_neighbors = spec.umap_neighbors,
      umap_min_dist = spec.umap_min_dist,
      min_valid_features = opts.min_valid_features,
      exclude_near_neutral = opts.exclude_near_neutral,
      near_neutral_eps = opts.near_neutral_eps,
      near_neutral_min_count = opts.near_neutral_min_count,
      max_excluded_ids = opts.max_excluded_ids,
    }
    local emb = run_python_phase_e_batch(phase_d_by_index, pe_opts)
    local saved = 0
    if type(emb) == "table" then
      for sid, e in pairs(emb) do
        local idn = tonumber(sid)
        local ex = idn and type(e) == "table" and tonumber(e.embed_x) or nil
        local ey = idn and type(e) == "table" and tonumber(e.embed_y) or nil
        if idn and ex and ey then
          saved = saved + 1
          exec_safe(db, string.format(
            "INSERT OR REPLACE INTO analysis_embed_profiles(sample_id, profile_key, embed_x, embed_y, updated_at) VALUES(%d, %s, %s, %s, %d);",
            idn, sql_quote(profile_key), tostring(ex), tostring(ey), now
          ))
        end
      end
    end
    profile_stats[#profile_stats + 1] = {
      key = spec.key,
      profile_key = profile_key,
      saved = saved,
      neighbors = spec.umap_neighbors,
      min_dist = spec.umap_min_dist,
    }
  end
  exec_safe(db, "COMMIT;")
  return true, {
    total = total,
    preset = base_preset,
    profile_keys = profile_keys,
    profiles = profile_stats,
  }
end

function M.apply_galaxy_embedding_profile(store, profile_suffix, opts)
  local db = store and store.db
  if not db then return false, "no db" end
  opts = type(opts) == "table" and opts or {}
  local only_oneshot = opts.only_oneshot ~= false
  local suffix = tostring(profile_suffix or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if suffix == "" then return false, "empty profile" end
  local profile_key = tostring(PHASE_E_PRESET or "core5") .. ":" .. suffix
  local cnt = 0
  for row in db:nrows(string.format("SELECT COUNT(*) AS n FROM analysis_embed_profiles WHERE profile_key=%s;", sql_quote(profile_key))) do
    cnt = tonumber(row.n or row[1] or 0) or 0
    break
  end
  if cnt <= 0 then
    return false, "profile not built: " .. profile_key
  end
  local where = only_oneshot and "WHERE COALESCE(class_primary,'')='oneshot'" or ""
  exec_safe(db, "BEGIN;")
  exec_safe(db, string.format("UPDATE analysis SET embed_x=NULL, embed_y=NULL %s;", where))
  local where_apply = only_oneshot and "AND COALESCE(class_primary,'')='oneshot'" or ""
  exec_safe(db, string.format([[
    UPDATE analysis
       SET embed_x = (
             SELECT p.embed_x
             FROM analysis_embed_profiles p
             WHERE p.sample_id=analysis.sample_id AND p.profile_key=%s
           ),
           embed_y = (
             SELECT p.embed_y
             FROM analysis_embed_profiles p
             WHERE p.sample_id=analysis.sample_id AND p.profile_key=%s
           )
     WHERE sample_id IN (
       SELECT sample_id FROM analysis_embed_profiles WHERE profile_key=%s
     )
       %s
  ]], sql_quote(profile_key), sql_quote(profile_key), sql_quote(profile_key), where_apply))
  exec_safe(db, "COMMIT;")
  return true, { profile_key = profile_key, applied = cnt, preset = tostring(PHASE_E_PRESET or "core5") }
end

function M.rebuild_galaxy_embedding_with_profiles(store, opts)
  opts = type(opts) == "table" and opts or {}
  local ok_build, info_build = M.build_galaxy_embedding_profiles(store, opts)
  if not ok_build then return false, info_build end
  local ok_apply, info_apply = M.apply_galaxy_embedding_profile(store, "balanced", opts)
  if not ok_apply then
    return false, { step = "apply_balanced", build = info_build, err = info_apply }
  end
  return true, { build = info_build, apply = info_apply }
end

function M.get_galaxy_embed_profile_points(store, profile_suffix, sample_ids)
  local db = store and store.db
  if not db then return {} end
  local suffix = tostring(profile_suffix or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if suffix == "" then return {} end
  local ids = {}
  if type(sample_ids) == "table" then
    for _, v in ipairs(sample_ids) do
      local n = tonumber(v)
      if n and n > 0 then
        ids[#ids + 1] = math.floor(n)
      end
    end
  end
  if #ids == 0 then return {} end
  local profile_key = tostring(PHASE_E_PRESET or "core5") .. ":" .. suffix
  local ids_sql = table.concat(ids, ",")
  local out = {}
  local sql = string.format([[
    SELECT sample_id, embed_x, embed_y
    FROM analysis_embed_profiles
    WHERE profile_key=%s AND sample_id IN (%s);
  ]], sql_quote(profile_key), ids_sql)
  for row in db:nrows(sql) do
    local sid = tonumber(row.sample_id or row[1])
    local x = tonumber(row.embed_x or row[2])
    local y = tonumber(row.embed_y or row[3])
    if sid and x and y then
      out[sid] = { x = x, y = y }
    end
  end
  return out
end

function M.rebuild_galaxy_embedding(store, opts)
  local db = store and store.db
  if not db then return false, "no db" end
  opts = type(opts) == "table" and opts or {}
  local only_oneshot = true
  if opts.only_oneshot == false then
    only_oneshot = false
  end
  local pe_opts = type(opts.phase_e_opts) == "table" and opts.phase_e_opts or nil
  local where = only_oneshot and "WHERE COALESCE(class_primary,'')='oneshot'" or ""
  local sql = string.format([[
    SELECT
      sample_id,
      brightness,
      noisiness,
      attack_sharpness,
      decay_length,
      tonalness,
      spectral_centroid_norm,
      spectral_rolloff_norm,
      spectral_bandwidth_norm,
      spectral_flatness,
      mfcc_timbre_norm
    FROM analysis
    %s;
  ]], where)
  local phase_d_by_index = {}
  local total = 0
  for row in db:nrows(sql) do
    local sid = tonumber(row.sample_id or row[1])
    if sid then
      total = total + 1
      phase_d_by_index[sid] = {
        brightness = row.brightness or row[2],
        noisiness = row.noisiness or row[3],
        attack_sharpness = row.attack_sharpness or row[4],
        decay_length = row.decay_length or row[5],
        tonalness = row.tonalness or row[6],
        spectral_centroid_norm = row.spectral_centroid_norm or row[7],
        spectral_rolloff_norm = row.spectral_rolloff_norm or row[8],
        spectral_bandwidth_norm = row.spectral_bandwidth_norm or row[9],
        spectral_flatness = row.spectral_flatness or row[10],
        mfcc_timbre_norm = row.mfcc_timbre_norm or row[11],
      }
    end
  end
  if total == 0 then return false, "no analysis rows" end
  local emb = run_python_phase_e_batch(phase_d_by_index, pe_opts)
  if type(emb) ~= "table" then return false, "embedding failed" end
  local embedded = 0
  exec_safe(db, "BEGIN;")
  exec_safe(db, string.format("UPDATE analysis SET embed_x=NULL, embed_y=NULL %s;", where))
  for sid, e in pairs(emb) do
    local idn = tonumber(sid)
    if idn and type(e) == "table" then
      local ex = tonumber(e.embed_x)
      local ey = tonumber(e.embed_y)
      if ex and ey then
        embedded = embedded + 1
        exec_safe(db, string.format(
          "UPDATE analysis SET embed_x=%s, embed_y=%s WHERE sample_id=%d;",
          tostring(ex), tostring(ey), idn
        ))
      end
    end
  end
  exec_safe(db, "COMMIT;")
  local island_top = {}
  local sum_b, sum_n, sum_a, sum_d, sum_t = 0, 0, 0, 0, 0
  local sum_c, sum_r, sum_bw, sum_fl, sum_mf = 0, 0, 0, 0, 0
  local island_count = 0
  for row in db:nrows([[
    SELECT
      a.sample_id AS sample_id,
      COALESCE(s.filename,'') AS filename,
      COALESCE(a.embed_x,0) AS embed_x,
      COALESCE(a.brightness,0.5) AS brightness,
      COALESCE(a.noisiness,0.5) AS noisiness,
      COALESCE(a.attack_sharpness,0.5) AS attack_sharpness,
      COALESCE(a.decay_length,0.5) AS decay_length,
      COALESCE(a.tonalness,0.5) AS tonalness,
      COALESCE(a.spectral_centroid_norm,0.5) AS spectral_centroid_norm,
      COALESCE(a.spectral_rolloff_norm,0.5) AS spectral_rolloff_norm,
      COALESCE(a.spectral_bandwidth_norm,0.5) AS spectral_bandwidth_norm,
      COALESCE(a.spectral_flatness,0.5) AS spectral_flatness,
      COALESCE(a.mfcc_timbre_norm,0.5) AS mfcc_timbre_norm
    FROM analysis a
    JOIN samples s ON s.id = a.sample_id
    WHERE COALESCE(a.class_primary,'')='oneshot'
    ORDER BY a.embed_x DESC
    LIMIT 6;
  ]]) do
    local sid = tonumber(row.sample_id or row[1]) or 0
    local fn = tostring(row.filename or row[2] or "")
    island_top[#island_top + 1] = string.format("%d:%s", sid, fn)
    sum_b = sum_b + (tonumber(row.brightness or row[4]) or 0.5)
    sum_n = sum_n + (tonumber(row.noisiness or row[5]) or 0.5)
    sum_a = sum_a + (tonumber(row.attack_sharpness or row[6]) or 0.5)
    sum_d = sum_d + (tonumber(row.decay_length or row[7]) or 0.5)
    sum_t = sum_t + (tonumber(row.tonalness or row[8]) or 0.5)
    sum_c = sum_c + (tonumber(row.spectral_centroid_norm or row[9]) or 0.5)
    sum_r = sum_r + (tonumber(row.spectral_rolloff_norm or row[10]) or 0.5)
    sum_bw = sum_bw + (tonumber(row.spectral_bandwidth_norm or row[11]) or 0.5)
    sum_fl = sum_fl + (tonumber(row.spectral_flatness or row[12]) or 0.5)
    sum_mf = sum_mf + (tonumber(row.mfcc_timbre_norm or row[13]) or 0.5)
    island_count = island_count + 1
  end
  local feat_summary = ""
  if island_count > 0 then
    feat_summary = string.format(
      "b=%.2f n=%.2f a=%.2f d=%.2f t=%.2f c=%.2f r=%.2f bw=%.2f fl=%.2f mf=%.2f",
      sum_b / island_count, sum_n / island_count, sum_a / island_count, sum_d / island_count, sum_t / island_count,
      sum_c / island_count, sum_r / island_count, sum_bw / island_count, sum_fl / island_count, sum_mf / island_count
    )
  end
  return true, {
    total = total,
    embedded = embedded,
    preset = PHASE_E_PRESET,
    mode = PHASE_E_LAST_INFO.mode or "unknown",
    dims = PHASE_E_LAST_INFO.dims or 0,
    min_valid_features = PHASE_E_LAST_INFO.min_valid_used or PHASE_E_MIN_VALID_FEATURES,
    dropped_low_valid = PHASE_E_LAST_INFO.dropped_low_valid or 0,
    dropped_near_neutral = PHASE_E_LAST_INFO.dropped_near_neutral or 0,
    excluded_low_valid_sample_ids = PHASE_E_LAST_INFO.excluded_low_valid_ids or "",
    excluded_near_neutral_sample_ids = PHASE_E_LAST_INFO.excluded_near_neutral_ids or "",
    island_top = table.concat(island_top, " | "),
    island_feat_summary = feat_summary,
  }
end

-- Re-run phase_e only; update embed for rows that had NULL embed (does not clear existing coords).
-- Uses same phase_e row rules as rebuild (see PHASE_E_MIN_VALID_FEATURES / exclude_near_neutral).
function M.fill_missing_galaxy_embedding(store, opts)
  local db = store and store.db
  if not db then return false, "no db" end
  opts = type(opts) == "table" and opts or {}
  local only_oneshot = opts.only_oneshot ~= false
  local missing_before = {}
  local missing_n = 0
  local sql_miss = only_oneshot
    and "SELECT sample_id FROM analysis WHERE COALESCE(class_primary,'')='oneshot' AND (embed_x IS NULL OR embed_y IS NULL);"
    or "SELECT sample_id FROM analysis WHERE (embed_x IS NULL OR embed_y IS NULL);"
  for row in db:nrows(sql_miss) do
    local sid = tonumber(row.sample_id or row[1])
    if sid then
      missing_before[sid] = true
      missing_n = missing_n + 1
    end
  end
  local where = only_oneshot and "WHERE COALESCE(class_primary,'')='oneshot'" or ""
  local sql = string.format([[
    SELECT
      sample_id,
      brightness,
      noisiness,
      attack_sharpness,
      decay_length,
      tonalness,
      spectral_centroid_norm,
      spectral_rolloff_norm,
      spectral_bandwidth_norm,
      spectral_flatness,
      mfcc_timbre_norm
    FROM analysis
    %s;
  ]], where)
  local phase_d_by_index = {}
  local total = 0
  for row in db:nrows(sql) do
    local sid = tonumber(row.sample_id or row[1])
    if sid then
      total = total + 1
      phase_d_by_index[sid] = {
        brightness = row.brightness or row[2],
        noisiness = row.noisiness or row[3],
        attack_sharpness = row.attack_sharpness or row[4],
        decay_length = row.decay_length or row[5],
        tonalness = row.tonalness or row[6],
        spectral_centroid_norm = row.spectral_centroid_norm or row[7],
        spectral_rolloff_norm = row.spectral_rolloff_norm or row[8],
        spectral_bandwidth_norm = row.spectral_bandwidth_norm or row[9],
        spectral_flatness = row.spectral_flatness or row[10],
        mfcc_timbre_norm = row.mfcc_timbre_norm or row[11],
      }
    end
  end
  if total == 0 then return false, "no analysis rows" end
  local relax = opts.relax ~= false -- retained for callers; phase_e filters match rebuild defaults
  if missing_n == 0 then
    return true, {
      missing_before = 0,
      filled = 0,
      relaxed = relax,
      still_missing_embed = 0,
      preset = PHASE_E_PRESET,
      mode = "skipped",
      dims = 0,
      min_valid_features = PHASE_E_MIN_VALID_FEATURES,
      dropped_low_valid = 0,
      dropped_near_neutral = 0,
      excluded_low_valid_sample_ids = "",
      excluded_near_neutral_sample_ids = "",
    }
  end
  local emb = run_python_phase_e_batch(phase_d_by_index)
  if type(emb) ~= "table" then return false, "embedding failed" end
  local filled = 0
  exec_safe(db, "BEGIN;")
  for sid, e in pairs(emb) do
    local idn = tonumber(sid)
    if idn and missing_before[idn] and type(e) == "table" then
      local ex = tonumber(e.embed_x)
      local ey = tonumber(e.embed_y)
      if ex and ey then
        filled = filled + 1
        exec_safe(db, string.format(
          "UPDATE analysis SET embed_x=%s, embed_y=%s WHERE sample_id=%d;",
          tostring(ex), tostring(ey), idn
        ))
      end
    end
  end
  exec_safe(db, "COMMIT;")
  return true, {
    missing_before = missing_n,
    filled = filled,
    relaxed = relax,
    still_missing_embed = math.max(0, missing_n - filled),
    preset = PHASE_E_PRESET,
    mode = PHASE_E_LAST_INFO.mode or "unknown",
    dims = PHASE_E_LAST_INFO.dims or 0,
    min_valid_features = PHASE_E_LAST_INFO.min_valid_used or PHASE_E_MIN_VALID_FEATURES,
    dropped_low_valid = PHASE_E_LAST_INFO.dropped_low_valid or 0,
    dropped_near_neutral = PHASE_E_LAST_INFO.dropped_near_neutral or 0,
    excluded_low_valid_sample_ids = PHASE_E_LAST_INFO.excluded_low_valid_ids or "",
    excluded_near_neutral_sample_ids = PHASE_E_LAST_INFO.excluded_near_neutral_ids or "",
  }
end

-- After library scan: repair NULL analysis fields, then recompute global UMAP (same as Repair missing + Rebuild embed).
function M.repair_missing_then_rebuild_galaxy(store, opts)
  local ok_r, info_r = M.reanalyze_missing_audio_features(store, opts)
  if not ok_r then return false, { step = "repair", err = info_r } end
  local ok_e, info_e = M.rebuild_galaxy_embedding_with_profiles(store, opts)
  if not ok_e then return false, { step = "rebuild", repair = info_r, err = info_e } end
  return true, { repair = info_r, rebuild = info_e }
end

function M.reanalyze_missing_audio_features(store, opts)
  local db = store and store.db
  if not db then return false, "no db" end
  local only_oneshot = true
  if type(opts) == "table" and opts.only_oneshot == false then
    only_oneshot = false
  end
  local where_type = only_oneshot and "AND COALESCE(a.class_primary,'')='oneshot'" or ""
  local sql = string.format([[
    SELECT s.id AS sample_id, s.path AS path, s.filename AS filename
    FROM samples s
    JOIN analysis a ON a.sample_id=s.id
    WHERE (
      a.brightness IS NULL OR a.noisiness IS NULL OR a.attack_sharpness IS NULL OR a.decay_length IS NULL OR a.tonalness IS NULL OR
      a.spectral_centroid_norm IS NULL OR a.spectral_rolloff_norm IS NULL OR a.spectral_bandwidth_norm IS NULL OR a.spectral_flatness IS NULL OR
      a.mfcc_timbre_norm IS NULL
    )
    %s
    ORDER BY s.id ASC;
  ]], where_type)
  local entries = {}
  for row in db:nrows(sql) do
    local fp = tostring(row.path or row[2] or "")
    entries[#entries + 1] = {
      sample_id = tonumber(row.sample_id or row[1]),
      full_path = fp,
      filename = tostring(row.filename or row[3] or ""),
      ext = tostring(fp:match("%.([^%.]+)$") or ""):lower(),
      force_phase_d = true,
    }
  end
  if #entries == 0 then
    return true, { target = 0, analyzed = 0, embedded = 0, updated = 0, dropped_low_valid = 0, dropped_near_neutral = 0 }
  end

  local phase_d_by_index = run_python_phase_d_batch(entries, "repair_missing")
  local phase_e_by_index = run_python_phase_e_batch(phase_d_by_index)
  local analyzed = table_count_keys(phase_d_by_index)
  local embedded = table_count_keys(phase_e_by_index)
  local updated = 0
  for i, e in ipairs(entries) do
    local sid = tonumber(e.sample_id)
    local feat = phase_d_by_index[i]
    if sid and feat then
      apply_phase_d_to_analysis(db, sid, feat, phase_e_by_index[i])
      updated = updated + 1
    end
  end
  return true, {
    target = #entries,
    analyzed = analyzed,
    embedded = embedded,
    updated = updated,
    dropped_low_valid = PHASE_E_LAST_INFO.dropped_low_valid or 0,
    dropped_near_neutral = PHASE_E_LAST_INFO.dropped_near_neutral or 0,
  }
end

local function path_taken_by_other_sample(db, new_path, sample_id)
  local q = sql_quote(new_path)
  local sql = string.format("SELECT id FROM samples WHERE path=%s AND id<>%d LIMIT 1;", q, sample_id)
  for _ in db:nrows(sql) do
    return true
  end
  return false
end

--- Re-point Splice samples to files found under search folders, matching `samples.filename` (case-insensitive).
-- If several on-disk files share the same name, paths are sorted and the first unused path is taken per row (by sample id order).
-- opts: { roots = { "C:\\a", ... } } or a plain array of root paths.
function M.relink_splice_sample_paths_by_filename(store, opts)
  local db = store and store.db
  if not db then return false, "no db" end
  local roots_in = opts
  if type(opts) == "table" and opts.roots ~= nil then
    roots_in = opts.roots
  end
  if type(roots_in) ~= "table" then return false, "invalid roots" end
  local roots = {}
  for _, p in ipairs(roots_in) do
    local sp = sanitize_root_path(p)
    if sp and sp ~= "" then
      roots[#roots + 1] = sp
    end
  end
  if #roots == 0 then
    return false, { err = "no search folders" }
  end

  local name_to_paths = {}
  local audio_indexed = 0
  local enumerate_errors = {}
  for _, root in ipairs(roots) do
    local ok_e, err_e = pcall(function()
      enumerate_files_recursive(root, function(full, name)
        audio_indexed = audio_indexed + 1
        local key = tostring(name or ""):lower()
        if key == "" then return end
        local list = name_to_paths[key]
        if not list then
          list = {}
          name_to_paths[key] = list
        end
        list[#list + 1] = full
      end)
    end)
    if not ok_e then
      enumerate_errors[#enumerate_errors + 1] = { root = root, err = tostring(err_e) }
    end
  end

  for _, list in pairs(name_to_paths) do
    table.sort(list)
  end

  local duplicate_names_on_disk = {}
  for key, list in pairs(name_to_paths) do
    if #list > 1 then
      duplicate_names_on_disk[#duplicate_names_on_disk + 1] = { filename = list[1]:match("[^/\\]+$") or key, count = #list }
    end
  end
  table.sort(duplicate_names_on_disk, function(a, b)
    return tostring(a.filename):lower() < tostring(b.filename):lower()
  end)

  local rows = {}
  for row in db:nrows("SELECT id, path, filename FROM samples WHERE source='splice' ORDER BY id ASC;") do
    rows[#rows + 1] = {
      id = tonumber(row.id or row[1]),
      path = tostring(row.path or row[2] or ""),
      filename = tostring(row.filename or row[3] or ""),
    }
  end

  local now = os.time()
  local claimed_norm = {}
  local updated = 0
  local unchanged = 0
  local no_match = 0
  local skipped_no_free_path = 0

  for _, rec in ipairs(rows) do
    local sid = rec.id
    local old_path = rec.path
    local fn = rec.filename
    if not sid or fn == "" then
      goto continue_row
    end
    local key = fn:lower()
    local candidates = name_to_paths[key]
    if not candidates or #candidates == 0 then
      no_match = no_match + 1
      goto continue_row
    end
    local old_n = normalize_path_for_match(old_path)
    local chosen = nil
    for _, cand in ipairs(candidates) do
      local cn = normalize_path_for_match(cand)
      if cn and not claimed_norm[cn] and not path_taken_by_other_sample(db, cand, sid) then
        chosen = cand
        break
      end
    end
    if not chosen then
      skipped_no_free_path = skipped_no_free_path + 1
      goto continue_row
    end
    local new_n = normalize_path_for_match(chosen)
    if old_n and new_n and old_n == new_n then
      claimed_norm[new_n] = true
      unchanged = unchanged + 1
      goto continue_row
    end
    exec_safe(db, string.format(
      "UPDATE samples SET path=%s, updated_at=%d WHERE id=%d;",
      sql_quote(chosen),
      now,
      sid
    ))
    claimed_norm[new_n] = true
    updated = updated + 1
    ::continue_row::
  end

  return true, {
    roots_used = #roots,
    enumerate_errors = enumerate_errors,
    audio_files_indexed = audio_indexed,
    splice_rows = #rows,
    updated = updated,
    unchanged = unchanged,
    no_match = no_match,
    skipped_no_free_path = skipped_no_free_path,
    duplicate_names_on_disk = duplicate_names_on_disk,
  }
end

return M

