---@meta
---@module 'ai.@types'
--- Type declarations for ai.nvim's configuration, requests and provider
--- interface.

---@class Ai.Config
---@field provider? string Active provider id, or `"auto"` (default) to pick the first available id in `provider_order`
---@field provider_order? string[] `"auto"` resolution order (default `{"claude","ollama","openai","gemini","loomai"}`) -- `"loomai"` is last since it needs a local server the user must run themselves; see `ai.providers`'s module doc
---@field policy? Ai.PolicyOptions Which providers this machine may use at all (`lua/ai/policy.lua`)
---@field keys? table<string, Ai.KeyProvider> Named API-key profiles per provider id (`lua/ai/keys.lua`); empty (default) = each provider reads its own environment variable
---@field model? table<string, string> Default model per provider id, e.g. `{ claude = "claude-opus-4-5" }`
---@field timeout_ms? integer Request timeout in ms, passed through to lib.nvim.net.curl (default 60000)
---@field bulk? Ai.BulkConfig Guard rails for unattended bulk requests (`lua/ai/bulk.lua`)
---@field ui? Ai.UiOptions
---@field keymaps? Ai.KeymapOptions
---@field which_key? Ai.WhichKeyOptions
---@field usercmds? Ai.UsercmdOptions
---@field context? Ai.ContextDefaults Default context assembly for the quick-action keymaps
---@field completion? Ai.CompletionOptions Inline completion suggestions (ghost text)
---@field log_level? integer vim.log.levels

---@class Ai.PolicyOptions
---@field allowed? string[] Provider ids this machine may use. Empty or absent (the default) means no restriction. Non-empty: `provider = "auto"` walks only these, and a request or `:Ai provider` naming anything else is refused unless the caller asked for it explicitly (`Ai.Request.allow_unlisted`, or a confirmed `:Ai provider`). A malformed value (not a list of strings) refuses every provider until it is fixed, and so does any other key under `policy` (a typo such as `alowed`): `allowed` is the only one. Ids are not checked against the registry, so an id may be listed before its provider exists.

---@class Ai.BulkConfig
---@field max_session_chars? integer|false Cap on the characters of all bulk requests (`Ai.Request.bulk`) of one Neovim session; past it a bulk request fails with `bulk_limit`. `false` (default) = no cap.

---Guard rails of an unattended bulk request, `Ai.Request.bulk` (`lua/ai/bulk.lua`).
---ai.nvim enforces them and does nothing else: the prompt, the splitting of the
---text and the check of the answer stay with the caller.
---@class Ai.BulkOptions
---@field label string Names the run: requests with the same label share the concurrency limit and the `max_total_chars` budget. Required.
---@field max_chars integer Largest request (prompt plus system, in characters) accepted; a bigger one fails with `bulk_limit`, nothing is sent. Required.
---@field concurrency? integer Requests of this label in flight at once; the rest wait in a queue (default 1)
---@field max_total_chars? integer Cumulative cap for this label in this session; a request that would pass it fails with `bulk_limit` (`require("ai.bulk").reset(label)` starts a fresh budget)
---@field allow_unlisted? boolean This one request may use a provider outside `config.policy.allowed`. Set it only after asking the user that document text may go there. The plain `Ai.Request.allow_unlisted` and a `:Ai provider` confirmation do not count for bulk requests.
---@field temperature? number|false Sampling temperature to send (default 0, for repeatable answers); `false` sends none. Only sent to providers that take one (`capabilities.temperature`).

---What `ai.ask` returns for a bulk request. `kill()` ends the call; the callback runs once with `kind = "cancelled"`.
---@class Ai.BulkHandle
---@field kill fun(self: Ai.BulkHandle, signal?: integer|string)
---@field is_closing fun(self: Ai.BulkHandle): boolean

---What a successful bulk request adds to `Ai.Response.bulk`, for the caller's cache key.
---@class Ai.BulkResult
---@field provider string Provider id that answered
---@field model string Model that was asked: `req.model`, the configured one, the provider's built-in default, or `"default"` where the provider picks it itself
---@field label string
---@field temperature? number Temperature sent, nil when none was
---@field deterministic boolean `true` when temperature 0 was sent (repeatable as far as the provider allows)
---@field chars integer Characters counted against the budgets

---@class Ai.KeyProvider
---@field active? string|false Profile in force at startup; must be one of `profiles` (one that is not still counts as chosen and yields no key). `false` or absent = none. A chosen profile never falls back to the provider's default variable.
---@field profiles table<string, Ai.KeyProfile>

---One credential's source: exactly one of `env`, `file` or `command`.
---@class Ai.KeyProfile
---@field env? string Name of an environment variable holding the key
---@field file? string Path of a file whose first non-empty line is the key (`~` is expanded; re-read when the file changes)
---@field command? string[] Argument list of a command whose first non-empty stdout line is the key; started without a shell, asynchronously, cached in memory (see `lua/ai/keys.lua`)
---@field timeout_ms? integer `command` only: kill the command after this many ms (default 10000)
---@field cache_ms? integer `command` only: how long the key stays cached (at least 1000; default the whole session)

---@class Ai.UiOptions
---@field enable boolean
---@field progress_style? "auto"|"notify"|"statusline"|"fidget"|"float" Passed straight to `lib.nvim.progress`
---@field panel_theme? string `ui.kit` theme/preset for the streaming answer panel
---@field badge_timeout_ms? integer Auto-dismiss delay for the explain badge (`kit.popup({type="note"})`)

---@class Ai.KeymapOptions
---@field enable boolean
---@field prefix? string

---@class Ai.WhichKeyOptions
---@field enable boolean

---@class Ai.UsercmdOptions
---@field enable boolean

---@class Ai.ContextDefaults
---@field buffer? boolean Include the whole current buffer
---@field selection? boolean Include the current visual selection (range), if any
---@field diagnostics? boolean Include `vim.diagnostic.get()` for the current buffer
---@field cwd? boolean Include a harvest.scope("cwd") sweep -- expensive, off by default
---@field structured_data? boolean Include the flattened JSON/YAML/XML block under the cursor, via `data.nvim` (optional soft dep) -- off by default
---@field conflict? boolean Include both sides of every unresolved merge-conflict region in the buffer, labeled "ours"/"theirs", via `gitsuite.nvim` (optional soft dep) -- off by default

---@class Ai.CompletionOptions
---@field enable boolean
---@field trigger? "manual"|"auto" `"manual"` (default): only an explicit keymap fires a suggestion. `"auto"`: an idle-while-typing timer fires one too -- pick this deliberately, it means an API call (possibly a paid cloud one) on every typing pause, not just on deliberate action.
---@field idle_ms? integer Auto-mode idle debounce before firing, in ms (default 500). Unused in `"manual"` mode.
---@field max_context_lines? integer Lines of buffer context to include before/after the cursor (default 60)
---@field provider? string Overrides `config.provider` for completion requests only
---@field model? string Overrides the resolved provider's default model for completion requests only
---@field keymap? Ai.CompletionKeymapOptions

---@class Ai.CompletionKeymapOptions
---@field trigger? string Insert-mode: request a suggestion at the cursor (manual mode only)
---@field accept? string Insert-mode: insert the currently shown suggestion
---@field dismiss? string Insert-mode: clear the currently shown suggestion without inserting it

---One binary payload sent alongside the prompt. Deliberately provider-
---neutral: bytes, what they are, and what role they play. Every wire format
---this maps onto carries exactly those three things and differs only in how
---it spells them -- Anthropic nests them in a `source` object per content
---block, Gemini in an `inline_data` part, OpenAI in a `data:` URI, Ollama in
---a bare `images` array that has no room for the media type at all. Turning
---this into that is each provider backend's job, the same way each already
---owns its own response schema.
---
---`data` is base64 *without* a `data:` URI prefix or line breaks --
---`ai.attachments.from_file()` produces exactly that shape, and is the
---intended way to build one.
---@class Ai.Attachment
---@field kind "image"|"document" What the payload is *for*. Not derivable from `media_type` alone in general, and it is what decides whether a provider can carry it at all (see `Ai.Provider.capabilities`).
---@field media_type string IANA media type, e.g. `"image/png"`, `"application/pdf"`
---@field data string Base64-encoded bytes, unwrapped
---@field name? string Optional display name (a file name), used only in error messages -- no provider sends it

---@class Ai.Request
---@field prompt string
---@field system? string
---@field context? Ai.ContextDefaults|table Explicit context flags for this request; a prebuilt context string can also be prepended into `prompt` by the caller
---@field provider? string Provider id, or `"auto"` (default: `require("ai").config().provider`)
---@field model? string Overrides the provider's default model for this request
---@field max_tokens? integer Overrides the provider's default response-length cap for this request. Only the `claude` backend reads it today (Anthropic's Messages API requires `max_tokens` on every request); ignored by providers that don't need one.
---@field timeout_ms? integer
---@field attachments? Ai.Attachment[] Binary payloads sent with the prompt. A provider that cannot carry one fails the request with `"invalid_request"` before sending -- an attachment is never silently dropped.
---@field api_key? string Overrides the provider's own env-var lookup for this request only. For an embedding plugin that already has the key in its own config (`pdfport.nvim`'s `claude_api_key`) and must not have to write it into the user's environment to use ai.nvim. Ignored by providers that need no key. **Set `provider` explicitly alongside it** -- a key belongs to one specific API, and under `provider = "auto"` it would be offered to whichever provider resolves first.
---@field host? string Overrides a self-hosted provider's base URL for this request only (`ollama`, `loomai`) -- same reasoning as `api_key`. Ignored by the cloud providers, whose endpoint is not a user choice.
---@field temperature? number Sampling temperature, sent by the providers that take one (`capabilities.temperature`: claude, openai, gemini, ollama); ignored by the others
---@field bulk? Ai.BulkOptions Run this request under the guard rails for unattended bulk use (`ai.ask` only; see `Ai.BulkOptions`). Not combinable with `allow_unlisted`, `attachments` or `context`.
---@field allow_unlisted? boolean This request may use a provider outside `config.policy.allowed`. Set it only after asking the user; it exists so a caller with its own confirmation (a test mode for a provider the machine does not list) can go through, and so nothing steps outside the list by accident.

---@class Ai.Response
---@field text string
---@field usage? table Provider-specific usage/token accounting, passed through as-is
---@field stop_reason? string
---@field provider string
---@field bulk? Ai.BulkResult Present on the answer to a bulk request

---@class Ai.StreamHandlers
---@field on_chunk? fun(delta: string)
---@field on_done? fun(res: Ai.Response)
---@field on_error? fun(err: LibErrorValue) `err.kind` is one of: `"missing_api_key"`
---(a provider's own API key env var is unset, `err.data = {env_var}`; or the
---chosen key profile has no key, `err.data = {profile}` -- `ai.providers.resolve()`
---reports that one too, instead of "not available" or moving on under `"auto"`),
---`"invalid_request"` (a client-side check rejected the request before it was
---sent, e.g. an unsafe model name, or an attachment this provider cannot
---carry), `"timeout"` (the request outlived its own `timeout_ms` -- curl
---exited 28, or the `vim.system` backstop behind it exited 124; see
---`ai.providers.transport`), `"network_error"` (the request could not be sent
---at all, or curl exited non-zero for any reason *other* than a timeout --
---this covers a curl that could not be spawned and a request body that could
---not be written out; `err.data` is the raw `vim.SystemCompleted`/curl error
---value where available), `"api_error"`
---(the provider's API returned a
---structured error body; `err.data` is that body's own `error` field),
---`"invalid_response"` (a 200 response whose body could not be understood),
---`"blocked"` (a provider-side safety/policy block, not a hard API error),
---`"bulk_limit"` (a bulk request went over `bulk.max_chars`, `bulk.max_total_chars` or
---`config.bulk.max_session_chars`; `err.data.reason` says which), `"cancelled"` (a bulk
---request was killed through its handle),
---or `"provider_resolution"` (`ai.providers.resolve()`/`require("ai").ask()`/
---`.stream()` could not resolve a usable provider at all -- no provider
---backend was ever reached). See `lib.lua.error` for the `LibErrorValue`
---shape itself.

---A single AI backend. `available()` must be cheap and synchronous (it runs
---on every `"auto"` resolution) -- an executable-on-PATH / env-var check, not
---a network round trip.
---
---`available()` receives the request being resolved, when there is one, so a
---provider whose availability depends on a credential can see a per-request
---`api_key` as well as its own env var. It is called with no argument from
---`:checkhealth ai` and `:Ai info`, which ask the standing question ("is this
---usable as configured?") rather than about one request -- so every
---implementation has to treat the parameter as optional.
---@class Ai.Provider
---@field id string
---@field name? string
---@field available fun(req?: Ai.Request): boolean
---@field ask fun(req: Ai.Request, cb: fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)): nil
---@field stream fun(req: Ai.Request, handlers: Ai.StreamHandlers): vim.SystemObj|nil returns the underlying process handle so a caller can `:kill()` it to cancel
---@field capabilities? Ai.ProviderCapabilities
---@field default_model? string The model the provider asks when `req.model` is unset (named in the result of a bulk request)

---What a provider backend can carry, as a *transport* fact -- "this API has
---a place to put one", not "the model you picked will understand it". The
---two are genuinely different: Ollama's chat endpoint accepts an `images`
---array for every model, and `llama3.2` will ignore it while `llava` reads
---it. Only the first is knowable here, which is why `ai.nvim` refuses an
---attachment the API has nowhere to put and passes through one the API
---accepts, leaving model choice to the caller.
---@class Ai.ProviderCapabilities
---@field streaming? boolean `stream()` is a real event stream, not a single buffered answer
---@field vision? boolean The API accepts `Ai.Attachment` entries with `kind = "image"`
---@field documents? boolean The API accepts `Ai.Attachment` entries with `kind = "document"` (a PDF sent whole, not rasterized by the caller first)
---@field web? boolean The request can use web search in one single-turn round-trip, without a tool-use loop in this plugin. Honest `false` everywhere for now: no provider wires a web-search parameter into its request (see `docs/scope.md`), so a caller must not promise web access on the strength of a provider's name
---@field temperature? boolean The request body can carry `Ai.Request.temperature`
---@field max_tokens? integer
