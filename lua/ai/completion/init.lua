---@module 'ai.completion'
--- Inline completion orchestration: owns the request lifecycle shared by
--- both trigger modes (an explicit keymap, or an idle-while-typing timer),
--- the stale-response guard, and the reactive dismiss-on-type/dismiss-on-
--- leave-insert behavior. `ai.completion.context`/`ai.completion.prompt`/
--- `ai.ui.ghost` do the actual context extraction / prompt shaping /
--- rendering -- this module only wires them together and tracks state.
---
--- Deliberately its own module rather than another `bindings.actions` body
--- like `ask_prompt`/`explain_badge`: those are one-shot calls, this is
--- stateful (an in-flight request, a shown-but-unaccepted suggestion, an
--- optional idle timer) and needs its own lifecycle management.
---
--- A completion request failure is silent by design (no notify popup) --
--- unlike an explicit `:Ai ask`, a completion attempt is best-effort and
--- often automatic (auto-trigger mode); popping an error on every failed
--- attempt (e.g. no provider configured) would be noise, not signal.

require("ai.@types")

local context = require("ai.completion.context")
local prompt = require("ai.completion.prompt")
local ghost = require("ai.ui.ghost")

local M = {}

---@internal
--- Bumped on every `trigger()` call; a response only renders if this still
--- matches the generation it was fired under -- guards against a newer
--- trigger superseding an older still-in-flight one. `ask()` (non-
--- streaming) exposes no handle to actually cancel the underlying request,
--- so this is what makes a superseded response a no-op instead.
local generation = 0

---@type Lib.Debounce.Handle|nil
--- Only ever built once, in `M.setup()`, when `cfg.completion.trigger ==
--- "auto"` -- `lib.nvim.debounce` owns the actual `vim.uv` timer (idempotent
--- stop/close, `vim.schedule`-wrapped callback) so this module doesn't hand-
--- roll that lifecycle itself.
local auto_debounce = nil

---@internal
local function cancel_auto_trigger()
  if auto_debounce then
    auto_debounce.cancel()
  end
end

---@internal
---Clear any shown suggestion and stop a pending auto-trigger timer -- used
---whenever a state that could make a suggestion stale occurs (typing,
---cursor movement, leaving insert mode).
local function reset()
  ghost.clear()
  cancel_auto_trigger()
end

---Request a completion suggestion at the cursor. Fired by the manual
---trigger keymap, or by the auto-trigger timer. No-op if completion is
---disabled or a provider can't be resolved.
---@return nil
function M.trigger()
  local cfg = require("ai").config()
  if not cfg.completion or not cfg.completion.enable then
    return
  end

  ghost.clear()
  generation = generation + 1
  local my_generation = generation

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local filetype = vim.bo[bufnr].filetype

  local prefix, suffix = context.extract({ max_lines = cfg.completion.max_context_lines })
  local req_prompt, req_system = prompt.build(prefix, suffix, filetype)

  require("ai").ask({
    prompt = req_prompt,
    system = req_system,
    provider = cfg.completion.provider,
    model = cfg.completion.model,
    timeout_ms = cfg.timeout_ms,
  }, function(ok, res)
    if my_generation ~= generation then
      return -- superseded by a newer trigger
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    -- Stale-response guard: the buffer or cursor moved since this request
    -- was fired, so the context it was computed from no longer matches
    -- reality -- rendering it now would misplace or misinsert text.
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= changedtick then
      return
    end
    local current_cursor = vim.api.nvim_win_get_cursor(0)
    if current_cursor[1] ~= row or current_cursor[2] ~= col then
      return
    end
    if not ok then
      return
    end

    local text = prompt.parse(res.text)
    if text ~= "" then
      ghost.show(bufnr, row - 1, col, text)
    end
  end)
end

---Insert the currently shown suggestion at the cursor and clear it.
---@return boolean accepted `false` if nothing was shown -- the caller
---(the keymap) should fall through to that key's normal behavior in that case
function M.accept()
  local suggestion = ghost.current()
  if not suggestion then
    return false
  end

  local bufnr = suggestion.bufnr
  local lines = vim.split(suggestion.text, "\n", { plain = true })
  ghost.clear()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  vim.api.nvim_buf_set_text(
    bufnr,
    suggestion.row,
    suggestion.col,
    suggestion.row,
    suggestion.col,
    lines
  )

  local end_row = suggestion.row + #lines - 1
  local end_col = #lines > 1 and #lines[#lines] or (suggestion.col + #lines[1])
  pcall(vim.api.nvim_win_set_cursor, 0, { end_row + 1, end_col })

  return true
end

---Clear the currently shown suggestion without inserting it.
---@return nil
function M.dismiss()
  ghost.clear()
end

---Install the reactive dismiss-on-type/dismiss-on-leave-insert behavior,
---and the idle-while-typing auto-trigger timer if `cfg.completion.trigger
---== "auto"`. A no-op if completion is disabled.
---@param cfg Ai.Config
---@return nil
function M.setup(cfg)
  if not cfg.completion or not cfg.completion.enable then
    return
  end

  local group = vim.api.nvim_create_augroup("AiCompletion", { clear = true })

  vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
    group = group,
    desc = "ai.nvim: dismiss a shown completion suggestion once the buffer/cursor moves past it",
    callback = function()
      if ghost.current() then
        ghost.clear()
      end
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    desc = "ai.nvim: clear any completion state on leaving insert mode",
    callback = reset,
  })

  if cfg.completion.trigger == "auto" then
    local idle_ms = cfg.completion.idle_ms or 500
    auto_debounce = require("lib.nvim.debounce").new(function()
      M.trigger()
    end, idle_ms)
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = group,
      desc = "ai.nvim: schedule an auto-trigger completion after an idle pause",
      callback = function()
        auto_debounce.call()
      end,
    })
  end
end

return M
