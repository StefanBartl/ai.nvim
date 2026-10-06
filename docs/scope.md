# Scope: what this plugin does, and what it deliberately doesn't

`ai.nvim` covers **single-turn question/answer and streaming**: ask a
question, get an answer; stream a longer one into a panel; send the current
context (buffer/selection/diagnostics) along with a typed task. This
includes more than one *trigger* for that same single-turn call -- an
explicit `:Ai`/keymap action is one; an editor-triggered inline completion
suggestion (`lua/ai/completion/`) is another. Both are still exactly one
`ask()` round-trip under the hood, just with a different trigger source
(explicit command vs. idle-while-typing) and a different renderer (panel/
badge vs. inline ghost text) -- not a new kind of interaction this plugin
supports.

It does **not** cover anything that looks like an autonomous multi-step
agent, a sandboxed execution environment, or tool-use/function-calling loops.
That is a separate, deliberate boundary with a native, independent project
(referred to here only as "the agent framework project" -- see that
project's own docs for details) which is not a Neovim plugin and is not a
dependency of `ai.nvim`.

## Why a registry entry, not a merge

The `Ai.Provider` interface (`id`, `available()`, `ask()`, `stream()`,
`capabilities`) is deliberately narrow -- a synchronous availability check
plus two request/response shapes. Anything that needs multi-step planning,
a sandbox, or persistent agent state does not fit that interface and is not
meant to: a future HTTP-backed provider pointing at such a system is welcome
(the interface is built to allow it without a redesign), but the agent
framework itself stays a separate project with its own release cycle, not a
mode of `ai.nvim`.

`loomai` (`lua/ai/providers/loomai.lua`) is exactly that: a registered
provider talking to loomAI's own `/ask`/`/ask/stream` endpoints, nothing more
-- it does not expose, and will never expose, loomAI's dashboard, sandbox, or
decision-queue machinery through this interface.

`claude-cli` (`lua/ai/providers/claude_cli.lua`) is the other registered
provider that is not an HTTP API: it runs `claude -p` as a child process and
returns its text. The reason it exists is the *credential* -- the CLI uses the
account it is logged in as (a subscription login, a company account), so
nothing about keys is configured in ai.nvim and switching accounts is
`claude auth login` outside of Neovim. It is deliberately a chat endpoint and
nothing more: no tools, no hooks or plugins (`--safe-mode`), no session
persistence, a neutral working directory, the prompt on stdin, the variables
that would replace the login removed from the child's environment, and the
CLI's own prompt handling switched off where it matters: `@path` mentions in
the text are denied and the CLI's expansion of them is switched off (it would
otherwise read local files into the request), and a leading `/` cannot turn the
prompt into a CLI command. `ANTHROPIC_BASE_URL`, which can point the CLI at a
company gateway instead, is passed on on purpose and named (host only) by
`:Ai info` and `:checkhealth ai` while it is set. It is opt-in (not in
`provider_order`) and, like every provider, subject to `policy.allowed`.

**A known limit of "the logged-in account is used".** ai.nvim removes the
*environment variables* the CLI ranks above its login. Credentials that the CLI
reads from its own *settings* rank above the login as well, and are not touched:
an `apiKeyHelper` script in a settings file, an API key or token in the `env`
block of a settings file (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or
`CLAUDE_CODE_OAUTH_TOKEN`: the CLI sets it itself once it runs, so removing it
from the child's environment does not reach it), and an active federation profile
(a profile file selected in the CLI's own configuration). With one of those set
up, `claude -p` can bill and act as that identity instead of the one
`claude auth login` set up. This is documented and not changed: pointing the
child at an empty configuration directory would probably break users whose login
legitimately lives in such a profile, and ai.nvim does not rewrite another tool's
settings. What it does: `:checkhealth ai` warns when the user's settings file
(`settings.json` in `CLAUDE_CONFIG_DIR` when that is set, else in `~/.claude`) or
the managed settings (`managed-settings.json` and `managed-settings.d/*.json` in
the CLI's system directory) define an `apiKeyHelper` or set one of those variables
in their `env` block, so the login may not be the account in use (an info line
instead of a warning while the CLI is neither installed nor in use, see
[health.md](health.md)). It only looks whether the keys exist; the values and the
rest of the file are never read out or shown. Not
detected: an active federation profile (another tool's configuration directory,
nothing there is read), server-managed settings and MDM policy (not files) and
project settings (the child runs in a neutral directory). If the account matters
(a policy question for customer data), check the CLI's own settings once -- `/status`
inside the CLI names the credential it uses.

## The allow-list narrows, it never widens

`policy.allowed` (see [configuration.md](configuration.md#provider-policy)) is
a per-machine restriction, empty by default. It changes nothing else described
here: `provider = "auto"` still walks only `provider_order`, now only the part
of it the allow-list admits, and a provider outside the list is reachable only
by a deliberate step (a confirmed `:Ai provider`, or `allow_unlisted` on one
request).

## Fallback guarantee

`provider = "auto"` only ever walks `provider_order` (default `{"claude",
"ollama", "openai", "gemini", "loomai"}`, `loomai` listed last so it never shadows a
cloud/CLI provider that is already configured and working). A provider not
listed there -- a custom one registered under its own id, or any future
agent-framework-backed one -- is reachable only by naming it explicitly
(`provider = "<name>"` or `:Ai provider <name>`). Nothing in this plugin ever
depends on that other system being installed, running, or reachable.
