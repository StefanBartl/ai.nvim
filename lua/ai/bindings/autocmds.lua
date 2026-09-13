---@module 'ai.bindings.autocmds'
--- One autocmd: kill every still-running stream when Neovim quits, so
--- closing the editor can never leave an orphaned curl process behind (the
--- same guarantee `ai.ui.panel.cancel`/`on_close` give for closing a single
--- panel while Neovim keeps running).

local M = {}

---@return nil
function M.setup()
  local autocmd = require("lib.nvim.bindings.autocmd")
  local group = autocmd.group("ai_nvim", true)

  autocmd.create("VimLeavePre", function()
    require("ai.ui.panel").cancel_all()
  end, {
    group = group,
    desc = "ai.nvim: cancel every in-progress stream before quitting",
  })
end

return M
