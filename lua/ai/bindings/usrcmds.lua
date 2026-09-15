---@module 'ai.bindings.usrcmds'
--- Registers `:Ai <subcommand>` via lib.nvim's composer (`:Verb sub ... +
--- <Tab> completion + Markdown docgen`). Every action mirrors a default
--- keymap 1:1 (see `ai.bindings.keymaps`) but is an independent entry point
--- -- both call into `ai.bindings.actions`, neither calls the other.

local composer = require("lib.nvim.usercmd.composer")
local actions = require("ai.bindings.actions")

local M = {}

---@return nil
function M.setup()
  -- Evaluated once, at registration time: the composer's `enum` is a plain
  -- string[], not a live callback, so a provider registered later via
  -- `require("ai.providers").register(...)` will not appear in `<Tab>`
  -- completion here until the next `:Ai` command reload. Acceptable for a
  -- closed set that in practice only grows at startup (see NEW-26); the
  -- built-ins are always present.
  local provider_ids = require("ai.providers").ids()

  composer.verb("Ai", {
    desc = "Ask or stream a prompt to the active AI provider",
    default = function(ctx)
      actions.ask_prompt(table.concat(ctx.rest or {}, " "))
    end,
    routes = {
      {
        path = { "ask" },
        desc = "Ask once, non-streaming (prompts for text if omitted)",
        run = function(ctx)
          actions.ask_prompt(table.concat(ctx.rest or {}, " "))
        end,
      },
      {
        path = { "stream" },
        desc = "Ask, streaming the answer into a panel (prompts for text if omitted)",
        run = function(ctx)
          actions.stream_prompt(table.concat(ctx.rest or {}, " "))
        end,
      },
      {
        path = { "provider" },
        args = {
          { name = "name", type = "STRING", enum = provider_ids },
        },
        desc = "Switch the active provider",
        run = function(ctx)
          require("ai.config").set_provider(ctx.args.name)
          require("lib.nvim.notify").create("[ai]").info("provider set to " .. ctx.args.name)
        end,
      },
      {
        path = { "info" },
        desc = "Show the active provider, resolution order, and per-provider availability",
        run = function()
          actions.info()
        end,
      },
    },
  })
end

return M
