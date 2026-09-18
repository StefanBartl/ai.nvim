---@module 'ai.bindings.actions'
--- Shared action bodies for both `:Ai` subcommands and the quick-action
--- keymaps -- one place owns "what does ask/stream/explain/info actually
--- do"; keymaps and usercmds both only wire input into it (`PRIN-01`: one
--- reason to change).

require("ai.@types")

local M = {}

---@internal
---@param cb fun(text: string)
local function prompt_for_text(cb)
  require("ui.kit").popup({
    type = "input",
    prompt = "Ai prompt",
    on_submit = function(text)
      if text and text ~= "" then
        cb(text)
      end
    end,
  })
end

---Ask once, non-streaming; shows the answer in a read-only viewer popup.
---Prompts for text first when `prompt` is empty.
---@param prompt string
---@return nil
function M.ask_prompt(prompt)
  local function run(text)
    local notify = require("lib.nvim.notify").create("[ai]")
    local progress = require("lib.nvim.progress").create({ title = "[ai]" })
    require("ai").ask({ prompt = text }, function(ok, res)
      progress:finish()
      if not ok then
        ---@cast res LibErrorValue
        notify.error(res.message)
        return
      end
      require("ui.kit").popup({
        type = "viewer",
        title = "AI",
        lines = vim.split(res.text, "\n", { plain = true }),
      })
    end)
  end

  if prompt ~= "" then
    run(prompt)
  else
    prompt_for_text(run)
  end
end

---Ask, streaming the answer into an `ai.ui.panel`. Prompts for text first
---when `prompt` is empty.
---@param prompt string
---@param context? Ai.ContextDefaults
---@return nil
function M.stream_prompt(prompt, context)
  local function run(text)
    local cfg = require("ai").config()
    local panel = require("ai.ui.panel").open({
      title = "AI",
      theme = cfg.ui.panel_theme,
      progress_style = cfg.ui.progress_style,
    })
    local process = require("ai").stream({ prompt = text, context = context }, {
      on_chunk = function(delta)
        require("ai.ui.panel").append(panel, delta)
      end,
      on_done = function(res)
        require("ai.ui.panel").finish(
          panel,
          res.stop_reason and ("[" .. res.stop_reason .. "]") or nil
        )
      end,
      on_error = function(err)
        require("ai.ui.panel").append(panel, "\n\n[error] " .. err.message)
        require("ai.ui.panel").finish(panel, "error")
      end,
    })
    require("ai.ui.panel").attach_process(panel, process)
  end

  if prompt ~= "" then
    run(prompt)
  else
    prompt_for_text(run)
  end
end

---Quick-action from the concept: send the current context straight to the
---AI together with a user-typed task, streaming the answer immediately --
---e.g. Trouble/quickfix has 5 errors listed, hit the hotkey, type "fix the
---quickfix list", get a streamed answer without any other setup.
---@param context Ai.ContextDefaults
---@return nil
function M.quick_action(context)
  prompt_for_text(function(text)
    M.stream_prompt(text, context)
  end)
end

local edit = require("ai.bindings.edit")

---@internal
local REWRITE_SYSTEM = "You rewrite code on request. Respond with only the "
  .. "replacement code for the given block -- no explanation, no markdown "
  .. "code fences, no commentary. Match the original indentation style."

---@internal
local INSERT_AFTER_SYSTEM = "You write code on request. Respond with only "
  .. "the code to insert immediately after the given block -- no "
  .. "explanation, no markdown code fences, no commentary. Match the "
  .. "surrounding indentation style."

---@internal
local INSERT_BEFORE_SYSTEM = "You write code on request. Respond with only "
  .. "the code to insert immediately before the given block -- no "
  .. "explanation, no markdown code fences, no commentary. Match the "
  .. "surrounding indentation style."

---@internal
---Shared body for rewrite/append/prepend: resolve the target range, ask
---non-streaming (an in-place edit needs the full answer before it can write
---anything -- no partial line half-written mid-stream), then hand the
---parsed response lines to `apply` for exactly one `nvim_buf_set_lines`
---call, so the whole edit is a single undo step. Prompts for the task first
---when `prompt` is empty.
---@param system string
---@param prompt string
---@param range? {line1: integer, line2: integer}
---@param apply fun(bufnr: integer, line1: integer, line2: integer, new_lines: string[])
---@return nil
local function run_edit(system, prompt, range, apply)
  local function run(task)
    local bufnr = vim.api.nvim_get_current_buf()
    local line1, line2 = edit.resolve_range(range)
    local block = edit.code_block(bufnr, line1, line2)
    -- `ai.ask` is a full network round-trip -- snapshot the tick now so the
    -- callback can tell a buffer closed or edited elsewhere meanwhile from
    -- one still safe to write `line1`/`line2` into (see `edit.buffer_changed`'s
    -- own doc for why a silent overwrite of the wrong lines is the real risk,
    -- not just a deleted-buffer crash).
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local notify = require("lib.nvim.notify").create("[ai]")
    local progress = require("lib.nvim.progress").create({ title = "[ai]" })
    require("ai").ask({
      prompt = block .. "\n\nTask: " .. task,
      system = system,
      -- Only the claude backend reads this today (Ai.Request's own doc),
      -- but a rewrite/append/prepend answer is plausibly longer than a
      -- short chat reply, and the plugin-wide default (4096) is sized for
      -- the latter -- give edit requests more headroom before hitting it.
      max_tokens = 8192,
    }, function(ok, res)
      progress:finish()
      if not ok then
        ---@cast res LibErrorValue
        notify.error(res.message)
        return
      end
      if edit.buffer_changed(bufnr, changedtick) then
        notify.warn(
          "Buffer changed while waiting for a response -- discarded it rather than risk editing the wrong lines"
        )
        return
      end
      if edit.is_truncated(res.stop_reason) then
        notify.warn(
          "Response was cut off (stop_reason: "
            .. tostring(res.stop_reason)
            .. ") -- discarded rather than write incomplete code. Try a smaller selection."
        )
        return
      end
      local new_lines = edit.parse_lines(res.text)
      if #new_lines == 0 then
        notify.warn("Empty response, buffer left unchanged")
        return
      end
      apply(bufnr, line1, line2, new_lines)
    end)
  end

  if prompt ~= "" then
    run(prompt)
  else
    prompt_for_text(run)
  end
end

---Replace the target range (the Visual selection just left, or the current
---line) with AI-generated code -- e.g. select a function, run this, type
---"add error handling". Prompts for the task first when `prompt` is empty.
---@param prompt string
---@param range? {line1: integer, line2: integer}
---@return nil
function M.rewrite_prompt(prompt, range)
  run_edit(REWRITE_SYSTEM, prompt, range, function(bufnr, line1, line2, new_lines)
    vim.api.nvim_buf_set_lines(bufnr, line1 - 1, line2, false, new_lines)
  end)
end

---Insert AI-generated code immediately after the target range (the Visual
---selection just left, or the current line). Prompts for the task first
---when `prompt` is empty.
---@param prompt string
---@param range? {line1: integer, line2: integer}
---@return nil
function M.append_prompt(prompt, range)
  run_edit(INSERT_AFTER_SYSTEM, prompt, range, function(bufnr, _, line2, new_lines)
    vim.api.nvim_buf_set_lines(bufnr, line2, line2, false, new_lines)
  end)
end

---Insert AI-generated code immediately before the target range (the Visual
---selection just left, or the current line). Prompts for the task first
---when `prompt` is empty.
---@param prompt string
---@param range? {line1: integer, line2: integer}
---@return nil
function M.prepend_prompt(prompt, range)
  run_edit(INSERT_BEFORE_SYSTEM, prompt, range, function(bufnr, line1, _, new_lines)
    vim.api.nvim_buf_set_lines(bufnr, line1 - 1, line1 - 1, false, new_lines)
  end)
end

---Second quick-action from the concept: explain the current context
---without a chat panel -- a small, auto-dismissing badge instead.
---@param context Ai.ContextDefaults
---@return nil
function M.explain_badge(context)
  local ctx_block = require("ai.context").assemble(context)
  if ctx_block == "" then
    require("lib.nvim.notify").create("[ai]").warn("Nothing to explain in the current context")
    return
  end

  local cfg = require("ai").config()
  require("ai").ask({
    prompt = "Explain this briefly, in at most 3 sentences.",
    context = context,
  }, function(ok, res)
    if not ok then
      ---@cast res LibErrorValue
      require("ai.ui.badge").show({
        title = "AI (error)",
        message = res.message,
        timeout_ms = cfg.ui.badge_timeout_ms,
      })
      return
    end
    require("ai.ui.badge").show({
      title = "AI",
      message = res.text,
      timeout_ms = cfg.ui.badge_timeout_ms,
    })
  end)
end

---Show the active provider, the auto-resolution order, and per-provider
---availability -- never a key's actual value.
---@return nil
function M.info()
  local cfg = require("ai").config()
  local providers = require("ai.providers")

  local lines = {
    "provider: " .. cfg.provider,
    "provider_order: " .. table.concat(cfg.provider_order, ", "),
    "",
  }
  for _, id in ipairs(providers.ids()) do
    local p = providers.get(id)
    local avail = p and type(p.available) == "function" and p.available()
    lines[#lines + 1] = string.format("  %s: %s", id, avail and "available" or "not available")
  end

  require("ui.kit").popup({ type = "viewer", title = "Ai info", lines = lines })
end

return M
