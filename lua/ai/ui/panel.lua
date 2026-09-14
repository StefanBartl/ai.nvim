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
  for i = 2, #pieces do
    panel.lines[#panel.lines + 1] = pieces[i]
  end
  if panel.surface then
    panel.surface:set_lines(panel.lines)
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
---`cancel()`/`finish()` a no-op).
---@param panel Ai.Ui.Panel
function M.cancel(panel)
  if panel.process then
    pcall(function()
      panel.process:kill(15)
    end)
    panel.process = nil
  end
  if panel.progress then
    panel.progress:cancel()
  end
end

---Cancel every panel that still has a running stream -- called on
---`VimLeavePre` so quitting Neovim can never leave an orphaned curl request
---behind.
---@return nil
function M.cancel_all()
  for _, panel in ipairs(active_panels) do
    M.cancel(panel)
  end
end

return M
