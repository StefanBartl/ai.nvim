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
  Inline completion (`docs/configuration.md`'s `completion` table) is the
  one exception: it renders through raw extmarks (`lua/ai/ui/ghost.lua`),
  not `ui.kit`, so it still works even if `ui.nvim` is missing (Neovim >=
  0.10 above is the only real requirement it adds, for
  `virt_text_pos = "inline"`).
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

The two external tools -- `curl`, and `ollama` for that provider -- are
declared in [install.json](install.json) and read by lib.nvim's
[deps module](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/deps/README.md):
`:Lib deps show ai.nvim` says what is missing and why it matters, and
`:Lib deps install ai.nvim` offers to install it, asking first.

No provider is required at install time -- `:checkhealth ai` reports which
ones are usable on this machine, and `provider = "auto"` (the default) picks
the first available one in `provider_order`.

## Optional

- [`data.nvim`](https://github.com/StefanBartl/data.nvim) -- backs
  `context.structured_data` (see [configuration.md](configuration.md)):
  when the cursor sits inside a json/yaml/xml block, the assembled prompt
  context includes that block's flattened `path: value` form via
  `data.nvim`'s own detect/scope/format pipeline, the same one `:Data` uses.
  Called via `pcall(require, ...)`, same soft-dependency treatment as every
  other integration here -- without it, `structured_data` is a silent
  no-op and every other context flag still works. `:checkhealth ai` reports
  whether it was found.
