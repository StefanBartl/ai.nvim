# Configuration

Every option and its default (`lua/ai/config/DEFAULTS.lua` is the source of
truth; this table mirrors it):

```lua
require("ai").setup({
  provider = "auto",                         -- "auto" | "claude" | "ollama" | "openai" | "loomai" | a custom id
  provider_order = { "claude", "ollama", "openai" }, -- "auto" resolution order; never includes "loomai" (registered, but opt-in), see docs/scope.md
  model = {},                                 -- e.g. { claude = "claude-opus-4-5" }
  timeout_ms = 60000,

  ui = {
    enable = true,
    progress_style = "auto",                  -- "auto" | "notify" | "statusline" | "fidget" | "float"
    panel_theme = "rounded",                   -- lib.nvim.ui.kit theme/preset for the streaming panel
    badge_timeout_ms = 6000,
  },

  keymaps = {
    enable = true,
    prefix = "<leader>a",
    -- Per-action overrides, keyed by action id (ask/quick/explain):
    --   keymaps = { quick = "<leader>xs" }     -- move just one
    --   keymaps = { explain = false }          -- disable just one
  },

  which_key = { enable = true },
  usercmds = { enable = true },

  -- Default context for the quick-action keymaps (<leader>as/<leader>ae).
  -- :Ai ask/stream build no context of their own -- only what a caller
  -- passes to require("ai").ask()/stream() directly.
  context = {
    buffer = false,
    selection = true,
    diagnostics = false,
    cwd = false,           -- expensive (a full cwd sweep); off by default
  },

  log_level = vim.log.levels.WARN,
})
```

## Provider selection

`provider = "auto"` (the default) walks `provider_order` and uses the first
provider whose `available()` is true -- a cheap, synchronous check (an
executable on `PATH` and/or an env var set), never a network round trip.
Set `provider` to an explicit id to always use one provider; `:Ai provider
<name>` switches it at runtime.

## Registering a custom provider

```lua
require("ai.providers").register({
  id = "myproxy",
  available = function() return true end,
  ask = function(req, cb) ... end,
  stream = function(req, handlers) return process_handle_or_nil end,
})
```

Add the id to `provider_order` to make it reachable through `"auto"`.
