std = "lua54"
max_line_length = 160

globals = {
  "reaper",
  "describe",
  "it",
  "setup",
  "teardown",
  "before_each",
  "after_each",
  "assert",
  "spy",
  "stub",
  "mock",
  "finally",
  "pending",
}

files["**/src/**.lua"] = {
  globals = { "reaper" },
}

files["tests/**.lua"] = {
  globals = {
    "describe",
    "it",
    "assert",
    "setup",
    "teardown",
    "before_each",
    "after_each",
    "spy",
    "stub",
    "mock",
    "finally",
    "pending",
  },
}
