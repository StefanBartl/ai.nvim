---@meta
---@module 'ai.@types'
--- Type declarations for ai.nvim's configuration, requests and provider
--- interface.

---@class Ai.Config
---@field provider? string Active provider id, or `"auto"` (default) to pick the first available id in `provider_order`
---@field provider_order? string[] `"auto"` resolution order (default `{"claude","ollama","openai","gemini","loomai"}`) -- `"loomai"` is last since it needs a local server the user must run themselves; see `ai.providers`'s module doc
---@field model? table<string, string> Default model per provider id, e.g. `{ claude = "claude-opus-4-5" }`
---@field timeout_ms? integer Request timeout in ms, passed through to lib.nvim.net.curl (default 60000)
---@field ui? Ai.UiOptions
---@field keymaps? Ai.KeymapOptions
---@field which_key? Ai.WhichKeyOptions
---@field usercmds? Ai.UsercmdOptions
---@field context? Ai.ContextDefaults Default context assembly for the quick-action keymaps
---@field completion? Ai.CompletionOptions Inline completion suggestions (ghost text)
---@field log_level? integer vim.log.levels

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

---@class Ai.Request
---@field prompt string
---@field system? string
---@field context? Ai.ContextDefaults|table Explicit context flags for this request; a prebuilt context string can also be prepended into `prompt` by the caller
---@field provider? string Provider id, or `"auto"` (default: `require("ai").config().provider`)
---@field model? string Overrides the provider's default model for this request
---@field max_tokens? integer Overrides the provider's default response-length cap for this request. Only the `claude` backend reads it today (Anthropic's Messages API requires `max_tokens` on every request); ignored by providers that don't need one.
---@field timeout_ms? integer

---@class Ai.Response
---@field text string
---@field usage? table Provider-specific usage/token accounting, passed through as-is
---@field stop_reason? string
---@field provider string

---@class Ai.StreamHandlers
---@field on_chunk? fun(delta: string)
---@field on_done? fun(res: Ai.Response)
---@field on_error? fun(err: string)

---A single AI backend. `available()` must be cheap and synchronous (it runs
---on every `"auto"` resolution) -- an executable-on-PATH / env-var check, not
---a network round trip.
---@class Ai.Provider
---@field id string
---@field name? string
---@field available fun(): boolean
---@field ask fun(req: Ai.Request, cb: fun(ok: boolean, res_or_err: Ai.Response|string)): nil
---@field stream fun(req: Ai.Request, handlers: Ai.StreamHandlers): vim.SystemObj|nil returns the underlying process handle so a caller can `:kill()` it to cancel
---@field capabilities? { vision?: boolean, streaming?: boolean, max_tokens?: integer }
