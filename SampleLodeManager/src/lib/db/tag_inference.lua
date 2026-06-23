-- @noindex
-- Filename/tag inference helpers (type, BPM, key, genre, vocabulary mapping).
local M = {}
function M.guess_type_and_bpm_and_key(filename)
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
    local function try_key_mode(mode_word, mode_name, confidence)
      local root, acc = padded:match("[^%a]([a-g])([#b]?)[%s_%-]*" .. mode_word .. "[^%a]")
      if root then
        return normalize_key_root(root, acc), mode_name, confidence
      end
      return nil
    end
    key_root, key_mode, key_conf = try_key_mode("major", "major", 0.8)
    if not key_root then
      key_root, key_mode, key_conf = try_key_mode("minor", "minor", 0.8)
    end
  end

  if not key_root then
    local root, acc = padded:match("[^%a]([a-g])([#b]?)(maj)[^%a]")
    if root then
      key_root = normalize_key_root(root, acc)
      key_mode = "major"
      key_conf = 0.7
    else
      root, acc = padded:match("[^%a]([a-g])([#b]?)(min)[^%a]")
      if root then
        key_root = normalize_key_root(root, acc)
        key_mode = "minor"
        key_conf = 0.7
      end
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
function M.normalize_key_estimate(audio_key, chord_type)
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

function M.split_csv_tags(tags_text)
  local out = {}
  if not tags_text or tostring(tags_text) == "" then return out end
  for token in tostring(tags_text):gmatch("([^,]+)") do
    local t = token:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end
function M.split_csv_simple(text)
  local out = {}
  local s = tostring(text or "")
  if s == "" then return out end
  for token in s:gmatch("([^,]+)") do
    local t = token:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end

function M.tokenize_words(text)
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

function M.collect_unknown_tokens_from_entries(entries, splice_vocab, alias_map)
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
function M.to_set(list)
  local s = {}
  for _, v in ipairs(list or {}) do
    s[v] = true
  end
  return s
end

function M.jaccard_tokens(a, b)
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
function M.infer_filename_genre_priors(filename, splice_genre_vocab, alias_map)
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

function M.infer_genre_guess_tags(db, filename, bpm_value, splice_genre_vocab, alias_map)
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

function M.candidate_forms(tag)
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

function M.pick_vocab_tag(vocab, candidates)
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

function M.build_filename_guess_tags(filename, file_path, pack_name, splice_vocab, alias_map, phase_a_hints, phase_b2_hints)
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

function M.apply_phase_c_rerank(tag_rows, audio_scores)
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

return M
