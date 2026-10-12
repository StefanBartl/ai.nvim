---@module 'ai.ui.panel'
--- The streaming answer panel: a `ui.kit.surface` that stays open
--- while text streams in, plus a `lib.nvim.progress` "thinking..." /
--- "streaming..." indicator. Owns the concept's open question
--- ("Streaming-Cancel bei Panel-Schließen"): the panel holds the
--- `vim.SystemObj` a provider's `stream()` returns and kills it both on an
--- explicit cancel and when the panel window itself closes for any reason
--- -- closing the panel can never leave an orphaned curl request running in
--- the background.

local M = {}

---@class Ai.Ui.Panel
---@field surface Ui.Kit.Surface|nil
---@field progress Lib.Progress.Handle|nil
---@field process vim.SystemObj|nil
---@field lines string[]

---@type Ai.Ui.Panel[]
local active_panels = {}

---@internal
---Drop `panel` from `active_panels`, if still present. A no-op the second
---time (`M.cancel` is idempotent, see its own doc) -- keeps a long session
---from accumulating one entry per `:Ai ask/stream` call forever.
---@param panel Ai.Ui.Panel
local function untrack(panel)
  for i, p in ipairs(active_panels) do
    if p == panel then
      table.remove(active_panels, i)
      return
    end
  end
end

---@internal
---Whether the panel should keep scrolling with the stream: only while the user
---sits on the last line (like `tail -f`). A user who scrolled up to read, or
---who is selecting text in the panel, is left alone.
---@param surface table the panel's `ui.kit` surface (`winid`, `bufnr`)
---@return boolean
local function is_following(surface)
  local ok, res = pcall(function()
    local win, buf = surface.winid, surface.bufnr
    if not (win and buf and vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf)) then
      return false
    end
    if win == vim.api.nvim_get_current_win() and vim.fn.mode():find("^[vVs\22]") then
      return false
    end
    return vim.api.nvim_win_get_cursor(win)[1] >= vim.api.nvim_buf_line_count(buf)
  end)
  return ok and res == true
end

---@internal
---Put the cursor at the very end of the buffer, so a wrapped last line shows
---its tail too.
---@param surface table the panel's `ui.kit` surface (`winid`, `bufnr`)
local function follow_tail(surface)
  pcall(function()
    local rows = vim.api.nvim_buf_line_count(surface.bufnr)
    local last = vim.api.nvim_buf_get_lines(surface.bufnr, rows - 1, rows, false)[1] or ""
    vim.api.nvim_win_set_cursor(surface.winid, { rows, #last })
  end)
end

---@param opts { title?: string, theme?: string, progress_style?: string }
---@return Ai.Ui.Panel
function M.open(opts)
  opts = opts or {}
  local kit = require("ui.kit")

  ---@type Ai.Ui.Panel
  local panel = { lines = { "" }, process = nil }

  panel.surface = kit.surface.open({
    lines = { "Thinking..." },
    theme = opts.theme,
    title = opts.title or "AI",
    filetype = "markdown",
    -- Without an explicit size the float is sized from the one "Thinking..."
    -- line and never grows, so everything after the first streamed line was
    -- invisible. Absolute cells, not fractions: fractions need a lib.nvim
    -- that understands them, and an older checkout silently brings the
    -- one-row float back.
    width = math.max(40, math.floor(vim.o.columns * 0.7)),
    height = math.max(8, math.floor(vim.o.lines * 0.5)),
    -- Prose arrives as long single lines; without wrapping they are cut off.
    wo = { wrap = true, linebreak = true },
    -- q / <Esc> in Normal mode close the panel (which cancels the stream).
    nice_quit = true,
  })

  panel.progress = require("lib.nvim.progress").create({
    title = opts.title or "[ai]",
    style = opts.progress_style,
  })
  panel.progress:on_cancel(function()
    M.cancel(panel)
  end)

  if panel.surface then
    panel.surface:on_close(function()
      M.cancel(panel)
    end)
  end

  active_panels[#active_panels + 1] = panel
  return panel
end

---Attach the running stream's process handle so `cancel()` can kill it.
---@param panel Ai.Ui.Panel
---@param process vim.SystemObj|nil
function M.attach_process(panel, process)
  panel.process = process
end

---Append a streamed delta to the panel, redrawing the surface.
---
---Updates the surface incrementally (`set_last_line` + `append_lines`)
---instead of rewriting the whole buffer per chunk: the panel's own `lines`
---table still tracks the full text (needed for `M.finish` callers that read
---it, and as the source of truth for the two surface calls below), but the
---buffer write itself only ever touches the line currently being extended
---plus any brand-new lines a chunk's newlines introduced.
---@param panel Ai.Ui.Panel
---@param delta string
function M.append(panel, delta)
  if delta == "" then
    return
  end
  if panel.progress then
    panel.progress:update({ text = "streaming..." })
  end
  local pieces = vim.split(delta, "\n", { plain = true })
  panel.lines[#panel.lines] = panel.lines[#panel.lines] .. pieces[1]
  local new_lines = {}
  for i = 2, #pieces do
    panel.lines[#panel.lines + 1] = pieces[i]
    new_lines[#new_lines + 1] = pieces[i]
  end
  if panel.surface then
    -- Decided before the write: "was the cursor on the last line" is only
    -- answerable against the buffer as it was.
    local follow = is_following(panel.surface)
    panel.surface:set_last_line(panel.lines[#panel.lines - #new_lines])
    panel.surface:append_lines(new_lines)
    if follow then
      follow_tail(panel.surface)
    end
  end
end

---Mark the stream as finished (successfully or not) -- stops the progress
---indicator, but leaves the panel window open so the answer stays readable.
---@param panel Ai.Ui.Panel
---@param text? string
function M.finish(panel, text)
  if panel.progress then
    panel.progress:finish(text)
  end
  panel.process = nil
end

---Cancel a still-running stream: kills the underlying curl process (if any)
---and finishes the progress indicator. Idempotent -- safe to call from both
---an explicit cancel action and the panel's own `on_close`/`on_cancel`
---callbacks (the progress handle's own `done` guard makes a second
---`cancel()`/`finish()` a no-op). Also untracks the panel -- see `untrack`.
---@param panel Ai.Ui.Panel
function M.cancel(panel)
  if panel.process then
    require("lib.nvim.safe_api").safe_call(function()
      panel.process:kill(15)
    end)
    panel.process = nil
  end
  if panel.progress then
    panel.progress:cancel()
  end
  untrack(panel)
end

---Cancel every panel that still has a running stream -- called on
---`VimLeavePre` so quitting Neovim can never leave an orphaned curl request
---behind. Iterates a snapshot: `M.cancel` mutates `active_panels` itself
---(via `untrack`), which `ipairs` over the live table would not survive.
---@return nil
function M.cancel_all()
  local panels = vim.list_extend({}, active_panels)
  for _, panel in ipairs(panels) do
    M.cancel(panel)
  end
end

return M
