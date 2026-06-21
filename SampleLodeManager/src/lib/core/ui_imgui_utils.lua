-- @noindex
-- Shared ImGui helpers: symmetric BeginChild/EndChild when child is visible (ReaImGui / docking safe).
local M = {}

function M.is_ctx_valid(ctx, rr)
  if not (rr and ctx) then return false end
  if not rr.ImGui_ValidatePtr then return true end
  local ok_v, valid = pcall(function()
    return rr.ImGui_ValidatePtr(ctx, "ImGui_Context*")
  end)
  return ok_v and valid == true
end

--- @return boolean begun, boolean visible
function M.begin_child_safe(ctx, rr, id, w, h, border, flags)
  if not M.is_ctx_valid(ctx, rr) then
    return false, false
  end
  local begun = false
  local visible = false
  local ok_begin = pcall(function()
    local ret = rr.ImGui_BeginChild(ctx, id, w, h, border, flags)
    begun = true
    visible = ret == true
  end)
  if not ok_begin then
    return false, false
  end
  return begun, visible
end

function M.end_child_safe(ctx, rr, should_end)
  if not should_end then return end
  if not M.is_ctx_valid(ctx, rr) then return end
  pcall(function()
    rr.ImGui_EndChild(ctx)
  end)
end

--- Runs draw_fn only when child is begun and visible; always balances EndChild with begun and visible.
--- @return boolean draw_ok, any draw_err from pcall(draw_fn)
function M.with_child(ctx, rr, id, w, h, border, flags, draw_fn)
  local begun, visible = M.begin_child_safe(ctx, rr, id, w, h, border, flags)
  local draw_ok, draw_err = true, nil
  if begun and visible and type(draw_fn) == "function" then
    draw_ok, draw_err = pcall(draw_fn)
  end
  M.end_child_safe(ctx, rr, begun and visible)
  return draw_ok, draw_err
end

return M
