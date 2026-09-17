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
  [attachments.md](attachments.md).
- **configuration** -- the active `provider` and `provider_order`.
- **composer route pre-flight** -- `:Ai`'s own route table, validated by
  `lib.nvim.usercmd.composer`.
