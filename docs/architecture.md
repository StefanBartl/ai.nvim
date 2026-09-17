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

`lua/ai/providers/transport.lua` is the seam between the two: the one place a
provider's encoded JSON body reaches `lib.nvim.net.curl`. See
[Attachments and request size](#attachments-and-request-size) for the two
things it does there and why neither belongs in `lib.nvim`.

## Attachments and request size

`Ai.Request.attachments` is deliberately three fields -- bytes, media type,
`"image"`/`"document"` -- and nothing else. That is the intersection of what
the four wire formats actually carry: Anthropic nests them in a `source`
object per content block, Gemini in an `inline_data` part, OpenAI splices the
media type into a `data:` URI, and Ollama takes a bare `images` array of
base64 strings with no room for a media type at all. Mapping the neutral
shape onto each is the backend's job, the same split as every response
schema in this directory.

Where the formats genuinely disagree -- Ollama and OpenAI have no slot for a
document, loomAI none for anything -- `ai.attachments.unsupported` fails the
request with `"invalid_request"` before it is sent. Dropping the block
instead would be worse than an error: a prompt asking about a page, sent
without the page, does not fail. It answers confidently about nothing.

Two transport consequences fall out of attachments existing at all, and both
live in `providers/transport.lua` rather than in `lib.nvim`, because both are
about *this* plugin's request shape rather than about HTTP:

- **A body too large for argv.** `lib.nvim.net.curl` passes `opts.body` as a
  `-d <body>` element of curl's argv; Windows caps a command line at 32 767
  characters. A base64 PDF is megabytes, so the request would fail at spawn
  time with an error naming neither the body nor its size. Above
  `MAX_INLINE_BODY_BYTES` the body goes to a `0600` temp file read back with
  `--data-binary @file`, removed once the request ends. This was a latent
  ceiling before attachments too -- a large enough `context = { cwd = true }`
  sweep could already reach it.
- **A timeout that says so.** `opts.timeout_ms` reaches `vim.system`, which
  on expiry kills curl and sets the exit code to `124` — a number curl never
  produces and that explains nothing. Passing curl its own `--max-time`
  makes curl end the request itself and exit 28, with a real diagnostic
  (`Operation timed out after 2002 milliseconds with 0 bytes received`).

  For that to happen curl has to expire *first*, and it does not by default:
  `vim.system`'s timer starts at spawn, curl's a moment later, so giving both
  the same number means the backstop always wins and exit 28 is unreachable.
  `transport.lua` therefore hands `vim.system` a `TIMEOUT_GRACE_MS` margin on
  top. `ai.providers.util.curl_exit_error` maps both 28 and 124 to the
  `"timeout"` kind, so the backstop firing is still reported honestly.

## Provider registry

`lua/ai/providers/init.lua` lazy-loads five built-ins (`claude`, `ollama`,
`openai`, `gemini`, `loomai`) behind the same proxy pattern
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

Two of the three SSE-based cloud providers (`claude`, `openai`) had to learn
one non-obvious thing the hard way while building this: an auth/validation
failure on a *streaming* request does not come back as an SSE event -- it is
a plain, pretty-printed (multi-line) JSON error body, and curl itself still
exits 0. Naive line-by-line parsing that only recognizes `data: ...` lines
silently drops that body and reports an empty success. Both providers instead
collect every non-`data:` line and, once the stream ends with no actual
content having arrived, try to parse the joined block as one JSON error
object -- confirmed against the real APIs, not assumed.

`gemini` applies the same `non_data_lines`/`recover_error_body` handling
(`ai.providers.sse`) by analogy, since it is the same SSE transport with a
different response schema -- but this one is **not yet confirmed against a
real Gemini error response** (no `GEMINI_API_KEY` was available while writing
it). Verify this during the next live test pass, see `docs/ROADMAP/reports/
ai/live-testing-plan.md` in the nvim config repo.

`loomai` is SSE too, but deliberately does not need any of that: its server
(a project this collection also controls) was specified and implemented so
that a stream-time error is always a regular `data: {"error":...}` event,
never a raw non-SSE body -- see `nvim/docs/ROADMAP/reports/
loomai-ai-nvim-integration.md`, Aufgabe C/D.

## Inline completion

`lua/ai/completion/` is a separate module tree, not a bolt-on to the
existing quick-actions (`bindings/actions.lua`): those are one-shot calls
sharing no state between invocations, while completion is inherently
stateful (an in-flight request, a shown-but-unaccepted suggestion, an
optional idle timer) and needs its own lifecycle, not another action body.
It still calls straight into `require("ai").ask()` like everything else --
no changes to the provider layer or the registry -- see [scope.md](scope.md)
for why an editor-triggered suggestion is the same single-turn interaction
the rest of this plugin covers, just with a different trigger and renderer.

Three small modules do the actual work, kept separate because each is
independently testable/replaceable: `completion/context.lua` (cursor-
relative prefix/suffix, built on the same `lib.nvim.harvest.scope`
`"range"` kind `ai/context/init.lua` already uses -- no new harvest-scope
kind was needed), `completion/prompt.lua` (pure functions: frame the
fill-in-the-middle task as a chat prompt, then strip a markdown fence a
model adds despite being told not to), and `ui/ghost.lua` (the actual
rendering, `virt_text_pos = "inline"` extmarks -- Neovim >= 0.10, already
this plugin's minimum). `completion/init.lua` is the only one that ties
them together and holds state.

**Stale-response guard.** A request records the buffer id, cursor
position, and `changedtick` at fire time; a response is rendered only if
none of those changed by the time it arrives, and a generation counter
discards a response superseded by a newer trigger before it arrives --
`ask()` exposes no handle to actually cancel an in-flight non-streaming
request, so this is what makes a stale one a no-op instead of misplacing
text. The same buffer/cursor check dismisses an already-shown suggestion
reactively (`TextChangedI`/`CursorMovedI`) the moment it stops matching
where the cursor actually is.

**Two trigger modes, one shared pipeline.** `config.completion.trigger`
picks what calls into that pipeline: `"manual"` (default) wires only the
`trigger` keymap; `"auto"` additionally owns a `vim.uv.new_timer()` reset
on every `TextChangedI`, deliberately not `CursorHoldI`/`updatetime` --
that setting is shared with (and often fought over by) other plugins, an
owned timer is not. `"auto"` is opt-in specifically because it means an
API call -- possibly a paid cloud one -- on every idle pause, not just on
deliberate action.
