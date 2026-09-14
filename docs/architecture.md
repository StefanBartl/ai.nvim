# Architecture

Two layers, the same split as [`lsp.nvim`](https://github.com/StefanBartl/lsp.nvim):

```
ai.nvim (this repo)
  Provider registry, context assembly, streaming answer panel, :Ai command

lib.nvim.net.curl (an extension, not a new module)
  fetch_stream  -- a third async tier alongside fetch_json/fetch_raw: one
                   raw line at a time (SSE/NDJSON), instead of buffering the
                   whole response
  secret_headers -- header values that go through curl's `-K` stdin config
                    path instead of argv, for API-specific credential
                    header names (e.g. Anthropic's `x-api-key`) that the
                    existing bearer_token/is_secret_header path cannot
                    recognize generically
```

Transport lives in `lib.nvim` (protocol-level, stable, shared by every
`*.nvim` plugin in this collection); the domain -- which provider, what
context, what UI -- lives here, where it can move fast without pinning a
shared library to one model/endpoint's shape.

## Provider registry

`lua/ai/providers/init.lua` lazy-loads four built-ins (`claude`, `ollama`,
`openai`, `loomai`) behind the same proxy pattern
[`pdfport.nvim`](https://github.com/StefanBartl/pdfport.nvim) uses for its
extraction backends: the real module only loads once one of its fields is
actually touched. `M.register(provider)` lets a user (or a future built-in)
add another under any id; `M.resolve(id, order)` is the only place that
decides which concrete provider answers a request -- see
[scope.md](scope.md) for why `"auto"` never silently reaches a provider
outside `order`.

## Context assembly

`lua/ai/context/init.lua` is a thin wrapper over
[`lib.nvim.harvest.scope`](https://github.com/StefanBartl/lib.nvim) for
buffer/selection/cwd -- it already returns the exact shape
(`file`/`bufnr`/`lines`/`first`) a prompt builder needs. Diagnostics
formatting (`file:line:[SEVERITY]:message`, chosen over raw text because a
model parses that shape more reliably) is the one piece specific enough to
`ai.nvim` that it does not belong in a generic collection library.

## Streaming panel and cancellation

`lua/ai/ui/panel.lua` pairs a `ui.kit.surface` (the answer text)
with a `lib.nvim.progress` handle (a "thinking…"/"streaming…" indicator).
The panel holds the `vim.SystemObj` a provider's `stream()` returns and
kills it both on an explicit cancel and when the panel window itself closes
for any reason -- closing the panel, or quitting Neovim (`VimLeavePre`,
`lua/ai/bindings/autocmds.lua`), can never leave an orphaned curl request
running in the background.

## Error handling: real API errors, not just transport errors

Both SSE-based cloud providers (`claude`, `openai`) had to learn one
non-obvious thing the hard way while building this: an auth/validation
failure on a *streaming* request does not come back as an SSE event -- it is
a plain, pretty-printed (multi-line) JSON error body, and curl itself still
exits 0. Naive line-by-line parsing that only recognizes `data: ...` lines
silently drops that body and reports an empty success. Both providers instead
collect every non-`data:` line and, once the stream ends with no actual
content having arrived, try to parse the joined block as one JSON error
object -- confirmed against the real APIs, not assumed.

`loomai` is SSE too, but deliberately does not need any of that: its server
(a project this collection also controls) was specified and implemented so
that a stream-time error is always a regular `data: {"error":...}` event,
never a raw non-SSE body -- see `nvim/docs/ROADMAP/reports/
loomai-ai-nvim-integration.md`, Aufgabe C/D.
