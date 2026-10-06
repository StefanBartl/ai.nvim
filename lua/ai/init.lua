---@module 'ai'
--- Public entry point for ai.nvim: a provider-agnostic ask/stream API,
--- context assembly, and a Neovim-native streaming answer panel -- built on
--- lib.nvim (net.curl, harvest.scope, progress, ui.kit, usercmd.composer).
---
--- Depends on lib.nvim (deliberate hard dependency, like `lsp.nvim`/
--- `dap.nvim`/`documentation.nvim` in this collection).
---
--- Example: >lua
---   require("ai").setup()
---
---   require("ai").ask({ prompt = "Why does this test fail?" }, function(ok, res)
---     if ok then print(res.text) end
---   end)
---
---   require("ai").stream({ prompt = "...", context = { selection = true } }, {
---     on_chunk = function(delta) end,
---     on_done  = function(res) end,
---     on_error = function(err) end,
---   })
--- <

require("ai.@types")

local lib_error = require("lib.lua.error")
local providers = require("ai.providers")

local M = {}

---@type boolean
M._initialized = false

---Set up ai.nvim: merges `opts` over the defaults, registers the built-in
---providers, and (unless disabled) installs the default keymaps/usercmds.
---@param opts? Ai.Config|table
---@return boolean success
function M.setup(opts)
  if M._initialized then
    require("lib.nvim.notify").create("[ai]").warn("Already initialized")
    return false
  end

  local config = require("ai.config")
  local cfg = config.setup(opts)

  providers.load_builtin()

  local safe_api = require("lib.nvim.safe_api")

  if cfg.keymaps.enable then
    local ok, _, err = safe_api.safe_call(function()
      require("ai.bindings.keymaps").setup(cfg)
    end)
    if not ok then
      require("lib.nvim.notify").create("[ai]").warn("Keymap setup failed: " .. tostring(err))
    end
  end

  if cfg.usercmds.enable then
    local ok, _, err = safe_api.safe_call(function()
      require("ai.bindings.usrcmds").setup()
    end)
    if not ok then
      require("lib.nvim.notify").create("[ai]").warn("Usercmd setup failed: " .. tostring(err))
    end
  end

  if cfg.completion and cfg.completion.enable then
    local ok, _, err = safe_api.safe_call(function()
      require("ai.completion").setup(cfg)
      require("ai.bindings.keymaps").setup_completion(cfg)
    end)
    if not ok then
      require("lib.nvim.notify").create("[ai]").warn("Completion setup failed: " .. tostring(err))
    end
  end

  local autocmds_ok, _, autocmds_err = safe_api.safe_call(function()
    require("ai.bindings.autocmds").setup()
  end)
  if not autocmds_ok then
    require("lib.nvim.notify")
      .create("[ai]")
      .warn("Autocmd setup failed: " .. tostring(autocmds_err))
  end

  M._initialized = true
  vim.g.loaded_ai = true
  return true
end

---@return Ai.Config
function M.config()
  return require("ai.config").get()
end

---The machine's provider policy, for a plugin that sits on top of ai.nvim and
---wants to narrow it further (it may restrict, never widen). A copy: changing
---the result changes nothing.
---@return { allowed: string[]|nil, restricted: boolean, granted: string[], bulk_granted: string[] } allowed `nil` when unrestricted; `granted` ids confirmed for this session outside the list; `bulk_granted` ids confirmed for bulk requests (`ai.bulk`) outside the list
function M.policy()
  local policy = require("ai.policy")
  return {
    allowed = policy.allowed(),
    restricted = policy.restricted(),
    granted = policy.granted(),
    bulk_granted = policy.bulk_granted(),
  }
end

---@internal
---Prefix `req.prompt` with the assembled context block, if any.
---@param req Ai.Request
---@return string prompt
---@return string[]|nil errors forwarded from `ai.context.assemble` -- present
---only when at least one requested context scope raised while resolving, not
---when a scope legitimately resolved to nothing (ERR-11); `prompt` still
---carries whatever context succeeded either way
local function build_prompt(req)
  local block, errors = require("ai.context").assemble(req.context)
  if block == "" then
    return req.prompt, errors
  end
  return block .. "\n\n" .. req.prompt, errors
end

---@internal
---Warn, distinctly from a request failure, when part of the requested
---context could not be gathered (ERR-11) -- `ask`/`stream` still send the
---request with whatever context succeeded, the same "don't block on a
---best-effort section" call `ai.completion` already documents, but silently
---dropping a selection/diagnostics/cwd section because a scope *raised*
---(not because it was legitimately empty) must not look identical to it
---never having been requested; see `ai.bindings.actions.explain_badge`,
---which surfaces the same `errors` list from a direct `assemble()` call.
---@param context_errors string[]|nil
local function warn_context_errors(context_errors)
  if context_errors then
    require("lib.nvim.notify").create("[ai]").warn(
      "Failed to gather part of the context -- sending the request without it: "
        .. table.concat(context_errors, "; ")
    )
  end
end

---@internal
---Resolve `req.provider` (or the configured default) to a concrete,
---available provider, and fold in config defaults (timeout, per-provider
---model) plus the assembled context. The model default is looked up by the
---*resolved* provider's own id, never by `"auto"` -- resolving first is
---exactly why this cannot be one linear pass.
---@param req Ai.Request
---@return Ai.Provider|nil provider
---@return LibErrorValue|nil err
---@return Ai.Request resolved_req
---@return string[]|nil context_errors see `build_prompt`'s doc -- `nil` when
---provider resolution itself failed (`err` is what matters then, not this)
local function resolve(req)
  local cfg = M.config()
  local requested = req.provider or cfg.provider or "auto"
  local provider, err = providers.resolve(requested, cfg.provider_order, req)
  if not provider then
    return nil, err, req, nil
  end

  local resolved = vim.tbl_extend("force", {}, req)
  resolved.provider = provider.id
  resolved.timeout_ms = resolved.timeout_ms or cfg.timeout_ms
  resolved.model = resolved.model or cfg.model[provider.id]
  local prompt, context_errors = build_prompt(resolved)
  resolved.prompt = prompt

  return provider, nil, resolved, context_errors
end

---@internal
---True when `provider` takes its key from a command source that has not run
---yet (or whose cached key expired) and the request brings no key of its own.
---@param provider Ai.Provider
---@param req Ai.Request
---@return boolean
local function needs_key_fetch(provider, req)
  return not req.api_key and require("ai.keys").needs_fetch(provider.id)
end

---@internal
---Send a resolved request: fetch a command-sourced key first when needed,
---then hand it to the provider.
---@param provider Ai.Provider
---@param resolved Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
local function dispatch(provider, resolved, cb)
  if needs_key_fetch(provider, resolved) then
    -- A command key source (ai.keys): run it off the UI thread, then go on.
    require("ai.keys").fetch(provider.id, function(ok, kerr)
      if ok then
        provider.ask(resolved, cb)
      else
        cb(false, kerr)
      end
    end)
    return
  end
  provider.ask(resolved, cb)
end

---Ask once, non-streaming. With `req.bulk` set the request runs under the
---guard rails of `ai.bulk` (size and budget caps, concurrency, strict policy,
---temperature 0) and a handle is returned: `handle:kill()` cancels it.
---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
---@return Ai.BulkHandle|nil handle only for a bulk request
function M.ask(req, cb)
  assert(type(req) == "table" and type(req.prompt) == "string", "ai.ask: req.prompt is required")
  if req.bulk ~= nil then
    return require("ai.bulk").ask(req, cb, { resolve = resolve, dispatch = dispatch })
  end
  local provider, err, resolved, context_errors = resolve(req)
  if not provider then
    cb(false, err or lib_error.new("provider_resolution", "ai: unknown error resolving a provider"))
    return
  end
  warn_context_errors(context_errors)
  dispatch(provider, resolved, cb)
end

---Ask, streaming the response.
---@param req Ai.Request
---@param handlers Ai.StreamHandlers
---@return vim.SystemObj|nil process returns the running process handle so a caller can `:kill()` it to cancel
function M.stream(req, handlers)
  assert(type(req) == "table" and type(req.prompt) == "string", "ai.stream: req.prompt is required")
  if req.bulk ~= nil then
    if handlers.on_error then
      handlers.on_error(
        lib_error.new(
          "invalid_request",
          "ai.stream: `bulk` applies to ai.ask() only",
          { field = "bulk" }
        )
      )
    end
    return nil
  end
  local provider, err, resolved, context_errors = resolve(req)
  if not provider then
    if handlers.on_error then
      handlers.on_error(
        err or lib_error.new("provider_resolution", "ai: unknown error resolving a provider")
      )
    end
    return nil
  end
  warn_context_errors(context_errors)
  if needs_key_fetch(provider, resolved) then
    -- The caller gets a handle at once; `kill()` cancels the wait for the key
    -- or, later, the stream itself.
    local inner, killed = nil, false
    local handle = {}
    function handle.kill(_, signal)
      killed = true
      if inner then
        inner:kill(signal)
      end
    end
    require("ai.keys").fetch(provider.id, function(ok, kerr)
      if killed then
        return
      end
      if ok then
        inner = provider.stream(resolved, handlers)
      elseif handlers.on_error then
        handlers.on_error(kerr)
      end
    end)
    ---@diagnostic disable-next-line: return-type-mismatch
    return handle
  end
  return provider.stream(resolved, handlers)
end

return M
