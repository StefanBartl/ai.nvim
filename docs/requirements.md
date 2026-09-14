# Requirements

- Neovim >= 0.10 (needs `vim.system`, which `lib.nvim.net.curl` requires).
- [`lib.nvim`](https://github.com/StefanBartl/lib.nvim) -- hard dependency.
  `fetch_stream`/`secret_headers` on `lib.nvim.net.curl` must be present; a
  too-old checkout is flagged by `:checkhealth ai`.
- `curl` on `PATH` -- every provider shells out to it.
- At least one provider actually usable:
  - **claude**: `ANTHROPIC_API_KEY` set in the environment.
  - **openai**: `OPENAI_API_KEY` set in the environment.
  - **ollama**: the `ollama` binary on `PATH`, with the daemon running
    (default `http://127.0.0.1:11434`, override with `OLLAMA_HOST`).
  - **loomai**: a loomAI server reachable at `http://127.0.0.1:8080` (default,
    override with `LOOMAI_HOST`). Registered but not in the default
    `provider_order` -- reachable only via `provider = "loomai"` until it has
    seen real-world use, see `docs/scope.md`.

No provider is required at install time -- `:checkhealth ai` reports which
ones are usable on this machine, and `provider = "auto"` (the default) picks
the first available one in `provider_order`.
