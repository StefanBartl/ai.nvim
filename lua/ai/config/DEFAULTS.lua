---@module 'ai.config.DEFAULTS'
--- Immutable default configuration for ai.nvim.
---
--- Single source of truth. `config/init.lua` deep-merges user options over a
--- copy of this table; it is never mutated at runtime.

---@type Ai.Config
local DEFAULTS = {
  provider = "auto",

  -- "auto" resolution order. "loomai" is last: it needs a local server the
  -- user must run themselves (see lua/ai/providers/loomai.lua), so it should
  -- not shadow a cloud/CLI provider that is already configured and working.
  provider_order = { "claude", "ollama", "openai", "gemini", "loomai" },

  -- Per-provider default model, e.g. { claude = "claude-opus-4-5" }. Empty
  -- means each provider module's own built-in default.
  model = {},

  timeout_ms = 60000,

  ui = {
    enable = true,
    progress_style = "auto",
    panel_theme = "rounded",
    badge_timeout_ms = 6000,
  },

  keymaps = {
    enable = true,
    prefix = "<leader>a",
  },

  which_key = {
    enable = true,
  },

  usercmds = {
    enable = true,
  },

  -- Default context assembly for the quick-action keymaps (:Ai ask/stream
  -- build no context of their own -- only what the caller passes).
  context = {
    buffer = false,
    selection = true,
    diagnostics = false,
    cwd = false,
    -- Requires data.nvim (optional soft dep); silent no-op without it or
    -- outside a json/yaml/xml block. Off by default like buffer/diagnostics/
    -- cwd -- only selection is on out of the box.
    structured_data = false,
  },

  -- Inline completion (ghost text). "manual" (default): only the trigger
  -- keymap fires a suggestion. "auto" is an explicit opt-in -- it means an
  -- API call (possibly a paid cloud one) on every typing pause, not just on
  -- deliberate action, so it is never the default.
  completion = {
    enable = true,
    trigger = "manual",
    idle_ms = 500,
    max_context_lines = 60,
    provider = nil,
    model = nil,
    keymap = {
      trigger = "<C-\\><C-a>",
      accept = "<Tab>",
      dismiss = "<C-]>",
    },
  },

  log_level = vim.log.levels.WARN,
}

return DEFAULTS
