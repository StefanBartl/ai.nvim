# Configuration

Every option and its default (`lua/ai/config/DEFAULTS.lua` is the source of
truth; this table mirrors it):

```lua
require("ai").setup({
  provider = "auto",                         -- "auto" | "claude" | "ollama" | "openai" | "gemini" | "loomai" | "claude-cli" | a custom id
  provider_order = { "claude", "ollama", "openai", "gemini", "loomai" }, -- "auto" resolution order; "loomai" last, see docs/scope.md
  policy = {
    allowed = {},                             -- provider ids this machine may use; empty = no restriction, see "Provider policy"
  },
  keys = {},                                  -- named API-key profiles per provider; empty = each provider's own variable, see "Key profiles"
  model = {},                                 -- e.g. { claude = "claude-opus-4-5" } -- not validated here, see "Model ids" below
  timeout_ms = 60000,

  bulk = {
    max_session_chars = false,                -- cap on the characters of all bulk requests of a session; false = none, see bulk.md
  },

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
<name>` switches it at runtime, and `:Ai provider auto` returns to the walk.

## Provider policy

Some machines may only use some providers -- an employer's allow-list, say.
`policy.allowed` says which, once, for everything that goes through ai.nvim:

```lua
-- the options passed to setup():
{
  provider = "claude",
  policy = { allowed = { "copilot", "claude" } },
}
```

Empty or absent (the default) means no restriction, and nothing changes. With a
list:

- `provider = "auto"` walks only the entries of `provider_order` that are listed.
  A provider that happens to have a key set is never picked when the machine does
  not list it -- and a session grant (see below) does not change that: it is for
  the one provider you named, not for `auto`.
- A request that names another provider (`provider = "gemini"`) fails before
  anything is sent, with `err.kind == "provider_resolution"` and
  `err.data.reason == "policy"`. This applies to every caller, including
  `pdfport.nvim` and the inline completion (`completion.provider`).
- `:Ai provider <name>` for an unlisted provider asks first (the dialog opens on
  "No"). A yes allows it for **this Neovim session only**, and it is not asked
  again for that provider in the same session; nothing is written, the next start
  is back inside the list. `:Ai info` marks such a provider, and `:checkhealth ai`
  reports it. `:Ai provider auto` is never asked about: `auto` is the walk above,
  already limited to the list, and it is not a provider that could be outside it.
- A caller that has asked the user itself (a plugin with its own test mode) can set
  `allow_unlisted = true` on that one request. It is an explicit step, never a
  default.

A malformed `policy.allowed` -- a string, a list with a non-string entry, a map such
as `{ claude = true }`, or a `policy` that is not a table -- is **not** treated as
empty: a typo must not switch the rule off. Every provider is refused until it is
fixed, `setup()` warns right away, and `:checkhealth ai` reports it.

The same goes for a key under `policy` that does not exist -- `policy = { alowed =
{ "claude" } }`, or a list written straight into `policy`. `allowed` is the only
key; any other one is a rule that was meant and is not in force, and ignoring it
would leave the default, no restriction, in place. So nothing is allowed until
the key is fixed, even when a valid `allowed` stands next to it. `setup()` warns
once, naming the key, and `:checkhealth ai` reports it as an error under
*provider policy* and as a warning under *configuration*.

The same goes for `policy` itself spelt wrong: a top-level key that is not an
option of ai.nvim but is within two edits of `policy` or of its plural
(`polcy`, `plicy`, `Policy`, `policies`) is a rule that was meant, and the real
`policy` stays at its default. Nothing is allowed until the key is fixed, even
when a valid `policy` stands next to it; `setup()` warns once, naming the key
(the misspelt key is not kept in the config), and `:checkhealth ai` reports it
as an error under *provider policy* and a warning under *configuration*. This is
only for that one option: any other unknown top-level key, near some other option
or near none, is a warning and changes nothing, so a typo in `ui` does not refuse
every provider.

The list is not checked against the registry: an id may be listed before its
provider exists (`"copilot"` today). A plugin on top of ai.nvim reads the policy
with `require("ai").policy()` and may restrict further, never widen it.

## Bulk requests

`bulk.max_session_chars` caps the characters of all `req.bulk` requests of one
Neovim session (see [bulk.md](bulk.md)). `false`, the default, means no cap. A
bulk request has its own, stricter policy rule: a provider outside
`policy.allowed` needs a confirmation for document text, `allow_unlisted` and
`:Ai provider` do not count.

## Key profiles

A person can have more than one credential for the same provider -- a private
key now, a company account later. `keys` names them and says where each comes
from; `:Ai key <profile>` picks one for the session:

```lua
-- the options passed to setup():
{
  keys = {
    claude = {
      active = "privat",                      -- in force at startup (optional)
      profiles = {
        privat = { env = "ANTHROPIC_API_KEY_PRIVAT" },   -- a variable name
        firma = { file = "~/.config/ai/firma.key" },     -- first non-empty line
      },
    },
  },
}
```

- Without `keys` nothing changes: every provider reads its own variable
  (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`). A per-request
  `api_key` still wins over everything.
- A profile has exactly one source: `env` (the name of an environment variable)
  or `file` (a path; `~` is expanded, the file is re-read when it changes; UTF-8
  with or without a BOM, or UTF-16 with a BOM as Windows PowerShell 5.1 writes it).
  Or `command` (see "Key from a command" below). `:checkhealth ai` warns about a
  key file that does not exist, cannot be read or (on POSIX) can be read by group
  or others; on Windows only existence and readability count.
- **A chosen profile never falls back to the default variable.** If its source
  is empty, the request fails with `missing_api_key` naming the profile; it does
  not quietly send with the other account's key. `provider = "auto"` does not move
  on to another provider either. This holds for `active` too: one that names no
  defined profile (a typo, a profile that is not a table) gives no key, and
  `:checkhealth ai` says why. `active = false` means no profile.
- `:Ai key firma` switches every provider that defines a `firma` profile for
  this session (`:Ai key firma claude` only that one), `:Ai key reset` goes back
  to `active` / the default variable, `:Ai key` shows the setup. Nothing is
  written; the next start is back at `active`.
- A key is never printed: `:Ai info`, `:Ai key` and `:checkhealth ai` show the
  profile, the kind of source and "key present"/"KEY MISSING", nothing else. An
  `env` that is a vendor's key and not a variable name (a key pasted there by
  mistake) is not echoed either. That is anything that is not an identifier
  (every `sk-...` key has hyphens), and the keys that have none by their shape: a
  Gemini `AIza...` key (39 characters or more), a Groq `gsk_` key (40 or more letters and
  digits after the prefix), a Hugging Face `hf_` key (34 or more), and a bare
  token of 32 or more letters and digits, mixed-case, without an underscore. A
  long name with words in it, such as `Company_Anthropic_Key_Production_2`, is a
  name and is shown; the same shape written without underscores
  (`CompanyAnthropicKeyProductionAccount2`) is taken for a key, which is the price
  of the bare-token rule.
- `claude-cli` and the local providers have no key and are not affected.

Keys switch the *account*; whether customer data may go to that account at all
is a policy question (see "Provider policy" and your employer's rules).

### Key from a command

A profile can take its key from a command, for a password manager or a secret
store, instead of a variable or a file:

```lua
-- the options passed to setup():
{
  keys = {
    claude = {
      active = "firma",
      profiles = {
        firma = {
          command = { "pass", "show", "anthropic/firma" },  -- an argument list, never a string
          timeout_ms = 10000,                               -- optional, default 10000
          cache_ms = 3600000,                               -- optional, default: the whole session
        },
      },
    },
  },
}
```

- **No shell.** `command` is an argument vector that is started directly, so
  nothing in it is interpreted by `sh` or `cmd`. A string, an empty list or a
  list with a non-string is refused (`:checkhealth ai` says so, a request fails).
- **Never blocks.** The command runs asynchronously with a timeout; a command
  that waits for input is killed after `timeout_ms`. `ai.ask` and `ai.stream` run
  it before the first request and go on when it has finished (`:Ai` shows nothing
  different; a stream returns a handle at once and `kill()` also cancels the wait).
- **Available without running.** A configured command counts as available, so
  `provider = "auto"` and `:Ai info` never start it; it runs when a request is
  made. `:checkhealth ai` only checks that the executable exists.
- **Cached in memory, never written.** The key lives in memory for `cache_ms`
  (at least one second; default the whole session). A failed run is not cached.
  Requests that arrive while it runs share one run. A per-request `api_key` skips
  the command.
- **First non-empty line of stdout is the key.** stderr is discarded. An error
  (`missing_api_key`) names the profile and a reason (`exited with code 3`,
  `timed out after 10000 ms`, `printed no key`, `executable not found`), never
  output and never an argument. `:Ai info`, `:Ai key` and `:checkhealth ai` show
  `command <executable name>` and "key present", "key not fetched yet" or
  "KEY MISSING: reason" -- not the arguments, since one may be a secret.

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
