# Configuration

Every option and its default (`lua/ai/config/DEFAULTS.lua` is the source of
truth; this table mirrors it):

```lua
require("ai").setup({
  provider = "auto",                         -- "auto" | "claude" | "ollama" | "openai" | "gemini" | "loomai" | a custom id
  provider_order = { "claude", "ollama", "openai", "gemini", "loomai" }, -- "auto" resolution order; "loomai" last, see docs/scope.md
  model = {},                                 -- e.g. { claude = "claude-opus-4-5" } -- not validated here, see "Model ids" below
  timeout_ms = 60000,

  ui = {
    enable = true,
    progress_style = "auto",                  -- "auto" | "notify" | "statusline" | "fidget" | "float"
    panel_theme = "rounded",                   -- ui.kit theme/preset for the streaming panel
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
    cwd = false,                 -- expensive (a full cwd sweep); off by default
    structured_data = false,     -- flattened json/yaml/xml block under the cursor, via data.nvim (optional soft dep); off by default
    conflict = false,            -- both sides of every unresolved merge conflict, labeled "ours"/"theirs", via gitsuite.nvim (optional soft dep); off by default
  },

  -- Inline completion (ghost text at the cursor). "manual" (default): only
  -- the trigger keymap fires a suggestion. "auto" additionally fires one
  -- after an idle pause while typing -- an explicit opt-in, since that
  -- means an API call (possibly a paid cloud one) on every typing pause,
  -- not just on deliberate action.
  completion = {
    enable = true,
    trigger = "manual",          -- "manual" | "auto"
    idle_ms = 500,                -- auto-mode idle debounce; unused in "manual"
    max_context_lines = 60,       -- buffer lines included before/after the cursor
    provider = false,               -- overrides `provider` for completion requests only; `false` = unset
    model = false,
    keymap = {
      trigger = "<C-\\><C-a>",    -- insert mode; manual mode only
      accept = "<Tab>",            -- insert mode; falls through to normal Tab when nothing is shown
      dismiss = "<C-]>",           -- insert mode
    },
  },

  log_level = vim.log.levels.WARN,
})
```

## Model ids

`model`/`completion.model` are never validated at request time -- whatever
string is configured goes straight onto the wire (see `lua/ai/init.lua`'s
`resolve()`), so a typo'd or discontinued model id still fails as a normal
API error rather than being caught early.

`:checkhealth ai` catches the common case instead: it checks every
configured model against `lua/ai/providers/models.lua`'s per-provider
registry (Claude, Gemini, OpenAI) and warns about one it doesn't recognize.
`ollama`/`loomai` are deliberately exempt -- both run whatever local model
the user has pulled or loaded, so there is no fixed catalogue to check
against; any model id is accepted for them. See
[health.md](health.md#configuration).

## Inline completion

A suggestion is a single `ask()` call framed as a fill-in-the-middle prompt
(prefix/suffix around the cursor) -- not a true FIM API, so quality varies
by provider/model. `completion.provider`/`completion.model` override the
regular `provider`/`model` resolution for completion requests only, e.g. to
always use a local Ollama model for completion regardless of what `:Ai ask`
uses:

```lua
completion = { provider = "ollama", model = "qwen2.5-coder:7b-q5_K_M" }
```

The `accept` keymap (`<Tab>` by default) is an `expr` mapping: it steps
aside while a completion-menu plugin's own popup is open (`pumvisible()`),
and falls through to that key's normal behavior when no suggestion is
shown. It cannot know whether another plugin *also* claims the same key
when no popup is open -- change `completion.keymap.accept` if that
conflicts with an existing binding.

Set `completion.keymap.<name> = false` to drop just that one key, or
`completion.enable = false` to disable the feature entirely.

**A note on `trigger = "auto"`:** this fires a request on every idle pause
while typing, not just on deliberate action. Against a paid cloud provider
(Claude/OpenAI/Gemini) that is a real, ongoing cost, not a one-time one --
consider setting `completion.provider = "ollama"` (or similar) alongside
`trigger = "auto"` if that matters to you. `:checkhealth ai` warns about
this combination.

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
