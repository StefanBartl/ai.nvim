# Scope: what this plugin does, and what it deliberately doesn't

`ai.nvim` covers **single-turn question/answer and streaming for one plugin
call or one editor action**: ask a question, get an answer; stream a longer
one into a panel; send the current context (buffer/selection/diagnostics)
along with a typed task.

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

## Fallback guarantee

`provider = "auto"` only ever walks `provider_order` (default `{"claude",
"ollama", "openai"}`). A provider not listed there -- including any future
agent-framework-backed one -- is reachable only by naming it explicitly
(`provider = "<name>"` or `:Ai provider <name>`). Nothing in this plugin ever
depends on that other system being installed, running, or reachable.
