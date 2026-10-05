---@module 'ai.bindings.usrcmds'
--- Registers `:Ai <subcommand>` via lib.nvim's composer (`:Verb sub ... +
--- <Tab> completion + Markdown docgen`). Every action mirrors a default
--- keymap 1:1 (see `ai.bindings.keymaps`) but is an independent entry point
--- -- both call into `ai.bindings.actions`, neither calls the other.

local composer = require("lib.nvim.bindings.usercmd.composer")
local actions = require("ai.bindings.actions")

local M = {}

---@internal
---`range = true` is a whole-verb setting (composer's own rule: "a single
---command-level option, not per-route"), so every `:Ai` subcommand accepts
---a `-range` even though only rewrite/append/prepend read one -- Neovim
---itself no longer rejects e.g. `:'<,'>Ai ask ...` the way a range-less
---command would (`E481: No range allowed`), so a route that ignores
---`ctx.range` warns instead of silently discarding it, to give back that
---feedback.
---@param ctx table
local function warn_if_ranged(ctx)
  if ctx.range and (ctx.range.range or 0) > 0 then
    require("lib.nvim.notify")
      .create("[ai]")
      .warn("this :Ai subcommand does not use a range -- ignored")
  end
end

---@return nil
function M.setup()
  -- Evaluated once, at registration time: the composer's `enum` is a plain
  -- string[], not a live callback, so a provider registered later via
  -- `require("ai.providers").register(...)` will not appear in `<Tab>`
  -- completion here until the next `:Ai` command reload. Acceptable for a
  -- closed set that in practice only grows at startup (see NEW-26); the
  -- built-ins are always present.
  local provider_ids = require("ai.providers").ids()
  -- Same registration-time snapshot for the profile names of `config.keys`.
  local key_names, seen = { "reset" }, { reset = true }
  local keys = require("ai.keys")
  for _, id in ipairs(keys.providers()) do
    for _, name in ipairs(keys.profiles(id)) do
      if not seen[name] then
        seen[name] = true
        key_names[#key_names + 1] = name
      end
    end
  end

  composer.verb("Ai", {
    desc = "Ask or stream a prompt to the active AI provider",
    -- Command-level, not per-route (composer's own rule): every route below
    -- accepts a `-range`, but only rewrite/append/prepend read `ctx.range`
    -- -- the others just ignore it, same as any range-less invocation.
    range = true,
    default = function(ctx)
      warn_if_ranged(ctx)
      actions.ask_prompt(table.concat(ctx.rest or {}, " "))
    end,
    routes = {
      {
        path = { "ask" },
        desc = "Ask once, non-streaming (prompts for text if omitted)",
        run = function(ctx)
          warn_if_ranged(ctx)
          actions.ask_prompt(table.concat(ctx.rest or {}, " "))
        end,
      },
      {
        path = { "stream" },
        desc = "Ask, streaming the answer into a panel (prompts for text if omitted)",
        run = function(ctx)
          warn_if_ranged(ctx)
          actions.stream_prompt(table.concat(ctx.rest or {}, " "))
        end,
      },
      {
        path = { "rewrite" },
        desc = "Replace the range (default: current line) with AI-generated code",
        run = function(ctx)
          actions.rewrite_prompt(
            table.concat(ctx.rest or {}, " "),
            { line1 = ctx.range.line1, line2 = ctx.range.line2 }
          )
        end,
      },
      {
        path = { "append" },
        desc = "Insert AI-generated code after the range (default: current line)",
        run = function(ctx)
          actions.append_prompt(
            table.concat(ctx.rest or {}, " "),
            { line1 = ctx.range.line1, line2 = ctx.range.line2 }
          )
        end,
      },
      {
        path = { "prepend" },
        desc = "Insert AI-generated code before the range (default: current line)",
        run = function(ctx)
          actions.prepend_prompt(
            table.concat(ctx.rest or {}, " "),
            { line1 = ctx.range.line1, line2 = ctx.range.line2 }
          )
        end,
      },
      {
        path = { "provider" },
        args = {
          { name = "name", type = "STRING", enum = provider_ids },
        },
        desc = "Switch the active provider (one outside the allow-list asks first)",
        run = function(ctx)
          warn_if_ranged(ctx)
          actions.set_provider(ctx.args.name)
        end,
      },
      {
        path = { "key" },
        args = {
          { name = "profile", type = "STRING", optional = true, enum = key_names },
          { name = "provider", type = "STRING", optional = true, enum = provider_ids },
        },
        desc = "Choose the API-key profile for this session (reset = back to the configured one)",
        run = function(ctx)
          warn_if_ranged(ctx)
          actions.set_key(ctx.args.profile, ctx.args.provider)
        end,
      },
      {
        path = { "info" },
        desc = "Show the active provider, resolution order, and per-provider availability",
        run = function(ctx)
          warn_if_ranged(ctx)
          actions.info()
        end,
      },
    },
  })
end

return M
