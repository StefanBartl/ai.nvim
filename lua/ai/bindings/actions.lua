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
  require("lib.nvim.ui.kit").popup({
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
        notify.error(tostring(res))
        return
      end
      require("lib.nvim.ui.kit").popup({
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
        require("ai.ui.panel").append(panel, "\n\n[error] " .. tostring(err))
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
      require("ai.ui.badge").show({
        title = "AI (error)",
        message = tostring(res),
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

  require("lib.nvim.ui.kit").popup({ type = "viewer", title = "Ai info", lines = lines })
end

return M
