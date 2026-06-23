-- @noindex
require("spec_helper")
local resource_paths = require("lib.core.resource_paths")

describe("resource_paths.sanitize_root_path", function()
  it("trims whitespace and quotes", function()
    assert.are.equal("C:/Samples", resource_paths.sanitize_root_path('  "C:/Samples/"  '))
  end)

  it("returns empty string for UI mode by default", function()
    assert.are.equal("", resource_paths.sanitize_root_path(nil))
    assert.are.equal("", resource_paths.sanitize_root_path("   "))
  end)

  it("returns nil for empty when empty_as_nil", function()
    assert.is_nil(resource_paths.sanitize_root_path(nil, { empty_as_nil = true }))
    assert.is_nil(resource_paths.sanitize_root_path("", { empty_as_nil = true }))
  end)

  it("normalizes Windows drive root", function()
    local sep = package.config:sub(1, 1)
    assert.are.equal("D:" .. sep, resource_paths.sanitize_root_path("D:"))
  end)
end)
