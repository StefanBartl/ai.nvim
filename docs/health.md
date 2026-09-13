# `:checkhealth ai`

What each section reports:

- **core** -- Neovim version (`vim.system` needs >= 0.10), `curl` on `PATH`.
- **lib.nvim** -- each required submodule (`net.curl`, `harvest.scope`,
  `progress`, `ui.kit`, `usercmd.composer`, `bindings.keymap`), plus a
  specific check that `lib.nvim.net.curl.fetch_stream` exists -- a too-old
  `lib.nvim` checkout has every other module present but not this one.
- **providers** -- every registered provider id and whether `available()`
  is currently true (missing binary and/or API key otherwise). Never shows
  a key's value, only whether one is set.
- **configuration** -- the active `provider` and `provider_order`.
- **composer route pre-flight** -- `:Ai`'s own route table, validated by
  `lib.nvim.usercmd.composer`.
