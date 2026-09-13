---@module 'ai.ui.badge'
--- The second quick-action from the concept: a small, colored,
--- auto-dismissing note (not a chat panel) that briefly explains the
--- current context or error -- `kit.popup({type="note"})` already is
--- exactly this "post-it" primitive, so this module only shapes the call.

local M = {}

---@param opts { title?: string, message: string, timeout_ms?: integer }
---@return nil
function M.show(opts)
  local kit = require("lib.nvim.ui.kit")
  kit.popup({
    type = "note",
    title = opts.title or "AI",
    message = opts.message,
    timeout = opts.timeout_ms or 6000,
  })
end

return M
