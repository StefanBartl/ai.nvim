# `:checkhealth ai`

What each section reports:

- **core** -- Neovim version (`vim.system` needs >= 0.10), `curl` on `PATH`.
- **lib.nvim** -- each required submodule (`net.curl`, `harvest.scope`,
  `progress`, `ui.kit`, `usercmd.composer`, `bindings.keymap`), plus a
  specific check that `lib.nvim.net.curl.fetch_stream` exists -- a too-old
  `lib.nvim` checkout has every other module present but not this one.
- **providers** -- every registered provider id and whether `available()`
  is currently true (missing binary and/or API key otherwise). Never shows
  a key's value, only whether one is set. For each available provider, an
  extra line names the attachment kinds its API can carry (`image`,
  `document`, or "none (text only)") -- the same fact that decides whether
  an `attachments` request fails with `invalid_request`, reported where
  someone can look it up before making the request rather than after. See
  [attachments.md](attachments.md). While `ANTHROPIC_BASE_URL` is set, one
  entry under `claude-cli` says the CLI will talk to that host and send its
  login and your prompts there (it can be a company gateway) -- the variable is
  passed on to it on purpose, and `policy.allowed` does not see where it
  points. It is a warning when the CLI can be run -- `claude` is on `PATH`, or
  `claude-cli` is the `provider`, in `provider_order` or the `completion.provider`
  -- and an info line otherwise (someone who set the variable for other tools
  and never uses `claude-cli` is not nagged on every check). Only the host is
  printed, and nothing when the variable is unset. A second entry under
  `claude-cli`, at the same levels, says when the claude CLI's own settings
  define an `apiKeyHelper`: a command that supplies the credential and ranks
  above the CLI's login, so `claude-cli` may use another account than the one
  `claude auth login` set up, and ai.nvim cannot take it out of the child's
  environment because it is a setting. The check looks in the user's settings
  file (`settings.json` in `CLAUDE_CONFIG_DIR` when that variable is set, else
  in `~/.claude`) and in the managed settings (`managed-settings.json` and the
  `managed-settings.d/*.json` drop-ins in the CLI's system directory), and
  names the layer, `user` and/or `managed`, never the file. A third entry, at the
  same levels, says when the `env` block of those same settings sets
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `CLAUDE_CODE_OAUTH_TOKEN` (the
  match ignores case, as the process environment of Windows does): the CLI
  applies that block itself once it runs, so ai.nvim cannot remove the variable
  from the child's environment, and it may override the login in the same way.
  It names the layer and the variable. Both checks only look whether the
  keys exist: the value (a command or a key that can carry a secret) and the
  rest of the file are neither read out nor shown. A file that is missing, over
  1 MiB, unreadable or not JSON counts as "no". Not detected: an active federation
  profile (it lives in another tool's configuration directory, and nothing there
  is read), server-managed settings and MDM policy (they are not files), and
  project settings (the child runs in a neutral directory). See
  [scope.md](scope.md).
- <a id="configuration"></a>**configuration** -- the active `provider` and `provider_order`, plus a
  warning for every config value that failed its type/shape check and was
  dropped back to its default instead of surviving the merge (e.g.
  `provider_order = "claude"` instead of a list, or `completion.trigger =
  "atuo"`) -- the value degrades silently everywhere else, this is where it
  becomes visible (a malformed `policy.allowed` is the exception: it is not
  dropped but refuses every provider, and is reported as an error under
  *provider policy*; so is an unknown key under `policy`, such as `alowed`, and
  a top-level key that is `policy` misspelt, such as `polcy`, which are named
  here as well). Also a warning for a configured
  `model`/`completion.model` that isn't a known id for its provider, per
  `lua/ai/providers/models.lua`'s registry (Claude/Gemini/OpenAI only --
  `ollama`/`loomai`/`claude-cli` run arbitrary local or CLI-side models, so any id is accepted for
  them). Reporting only: an unrecognized model still reaches the provider
  and fails there as a normal API error, `opts.model` is never blocked here.
  See [configuration.md](configuration.md#model-ids).
- **provider policy** -- whether `policy.allowed` is set, an error for a
  malformed `policy.allowed`, an unknown key under `policy` or a misspelt
  `policy` (every provider is refused until it is fixed), and a warning for a `provider`, a
  `completion.provider` or a `provider_order` that falls outside the list
  (requests that use them are refused, `provider = "auto"` could never
  resolve; a provider granted for this session is not counted as refused),
  plus one for a provider allowed only for this session after a confirmed `:Ai
  provider`. An allowed id with no registered provider (yet) is an info line,
  not a warning. See [configuration.md](configuration.md#provider-policy).
- **composer route pre-flight** -- `:Ai`'s own route table, validated by
  `lib.nvim.bindings.usercmd.composer`.
