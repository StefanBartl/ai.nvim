---@module 'ai.ui.ghost'
--- Inline "ghost text" rendering for completion suggestions: the first
--- suggested line renders as `virt_text_pos = "inline"` virtual text right
--- at the cursor (Neovim >= 0.10, which `health.lua` already requires --
--- older Neovim has no inline virtual text position), any further suggested
--- lines render as `virt_lines` below. A sibling to `ui/panel.lua`/
--- `ui/badge.lua`, not a rework of either -- a fundamentally different
--- rendering primitive (extmarks, not a floating surface), and only one
--- suggestion is ever shown at a time by design (`ai.completion`'s
--- stale-response guard enforces that upstream).

local NAMESPACE = vim.api.nvim_create_namespace("ai_completion_ghost")
local HL_GROUP = "Comment" -- matches the ghost-text convention other completion plugins use

local M = {}

---@class Ai.Ui.Ghost.Shown
---@field bufnr integer
---@field row integer 0-indexed, matching the extmark API
---@field col integer
---@field text string The exact suggestion text last shown, for `accept()` to insert
---@field changedtick integer The buffer's changedtick when this was rendered, for `accept()` to re-verify against before writing (ERR-30)

---@type Ai.Ui.Ghost.Shown|nil
local shown = nil

---Render `text` as ghost text at `(row, col)` (0-indexed) in `bufnr`.
---Replaces any suggestion already shown (in this or any other buffer --
---only one is ever shown at a time). A no-op if `text` is empty.
---@param bufnr integer
---@param row integer
---@param col integer
---@param text string
---@param changedtick integer the buffer's changedtick this suggestion was computed against
---@return nil
function M.show(bufnr, row, col, text, changedtick)
  M.clear()
  if text == "" then
    return
  end

  local lines = vim.split(text, "\n", { plain = true })

  ---@type table
  local opts = {
    virt_text = { { lines[1], HL_GROUP } },
    virt_text_pos = "inline",
  }
  if #lines > 1 then
    local virt_lines = {}
    for i = 2, #lines do
      virt_lines[#virt_lines + 1] = { { lines[i], HL_GROUP } }
    end
    opts.virt_lines = virt_lines
  end

  local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, NAMESPACE, row, col, opts)
  if not ok then
    return
  end
  shown = { bufnr = bufnr, row = row, col = col, text = text, changedtick = changedtick }
end

---Clear the currently shown suggestion, if any.
---@return nil
function M.clear()
  if shown and vim.api.nvim_buf_is_valid(shown.bufnr) then
    vim.api.nvim_buf_clear_namespace(shown.bufnr, NAMESPACE, 0, -1)
  end
  shown = nil
end

---The suggestion currently shown, if any.
---@return Ai.Ui.Ghost.Shown|nil
function M.current()
  return shown
end

return M
