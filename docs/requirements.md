# Requirements

- Neovim >= 0.10 (needs `vim.system`, which `lib.nvim.net.curl` requires).
- [`lib.nvim`](https://github.com/StefanBartl/lib.nvim) -- hard dependency.
  `fetch_stream`/`secret_headers` on `lib.nvim.net.curl` must be present; a
  too-old checkout is flagged by `:checkhealth ai`.
- [`ui.nvim`](https://github.com/StefanBartl/ui.nvim) -- also a hard
  dependency: `ui.kit` backs the streaming answer panel, the explain badge,
  the non-streaming viewer and the prompt popup (`lua/ai/ui/panel.lua`,
  `lua/ai/ui/badge.lua`, `lua/ai/bindings/actions.lua`). All lazy-loaded (no
  cost until an `:Ai` action actually runs), but none of them has another
  rendering path -- `ask`/`stream`/`explain`/`info` all fail without it.
- `curl` on `PATH` -- every provider shells out to it.
- At least one provider actually usable:
  - **claude**: `ANTHROPIC_API_KEY` set in the environment.
  - **openai**: `OPENAI_API_KEY` set in the environment.
  - **gemini**: `GEMINI_API_KEY` set in the environment.
  - **ollama**: the `ollama` binary on `PATH`, with the daemon running
    (default `http://127.0.0.1:11434`, override with `AI_OLLAMA_HOST` --
    deliberately not `OLLAMA_HOST`, which is Ollama's own env var for the
    *server*'s bind address, not a client target).
  - **loomai**: a loomAI server reachable at `http://127.0.0.1:8080` (default,
    override with `LOOMAI_HOST`). Last in the default `provider_order`, see
    `docs/scope.md`.

No provider is required at install time -- `:checkhealth ai` reports which
ones are usable on this machine, and `provider = "auto"` (the default) picks
the first available one in `provider_order`.
