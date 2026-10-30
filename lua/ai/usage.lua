---@module 'ai.usage'
--- Usage reporter: after every request `ai.ask`/`ai.stream` sent to a provider,
--- one event with the request's *metadata* goes to a local ai-desktop server
--- (`POST /usage/events`), which keeps the usage log and shows it on its
--- dashboard. Off by default (`config.usage.report = false`): on, it is one
--- extra network request per AI request, to a server the user runs themselves.
---
--- What goes out is built from `FIELDS` and nothing else -- provider id, model,
--- stream flag, outcome, the error *kind*, token counts and the duration. Never
--- the prompt, the system prompt, the answer or an error message (a message can
--- quote the request). ai-desktop refuses a body that carries such a field
--- (400), so the allow-list here is what keeps the reporter working at all.
---
--- Requests to the `ai_desktop` provider are not reported: that server records
--- its own `/ask` traffic, and a second event would count the request twice.
---
--- Sending is fire-and-forget through `ai.providers.transport` (curl via
--- `vim.system`, asynchronous, a short timeout): a failure never reaches the
--- caller of `ai.ask`, at most one DEBUG notification per session says the
--- server was not reachable.

require("ai.@types")

local M = {}

local uv = vim.uv or vim.loop

---The only keys an event may carry, in the order the body is built. The
---contract with ai-desktop (`source` and `ts` are set by the server).
---@type string[]
M.FIELDS = {
  "provider",
  "model",
  "stream",
  "ok",
  "error_kind",
  "prompt_tokens",
  "completion_tokens",
  "duration_ms",
}

---The provider that keeps its own usage log; a request to it is not reported.
---@type string
M.SELF_RECORDING_PROVIDER = "ai_desktop"

---How long the reporter waits for ai-desktop. Short on purpose: the report
---is a side note to a request that is already answered.
---@type integer
M.TIMEOUT_MS = 3000

---Where each provider puts its token counts in `Ai.Response.usage` (passed
---through as the provider's API sent it). A provider that is not listed, or a
---count that is not a number, reports 0.
---@type table<string, { prompt: string, completion: string }>
local TOKEN_FIELDS = {
  claude = { prompt = "input_tokens", completion = "output_tokens" },
  ["claude-cli"] = { prompt = "input_tokens", completion = "output_tokens" },
  openai = { prompt = "prompt_tokens", completion = "completion_tokens" },
  -- Not `copilot`: the Copilot CLI's `result` event carries `{ premiumRequests = n }`, no token counts.
  gemini = { prompt = "promptTokenCount", completion = "candidatesTokenCount" },
}

---Set once the first failed report has been mentioned, so it is said once.
---@type boolean
local warned = false

---@alias Ai.Usage.Sender fun(url: string, body: string, on_failure: fun(reason: string)) sends `body` (JSON) to `url`; calls `on_failure` when it did not get through

---@internal
---The default sender: `transport.post_json`, the same curl path every HTTP
---provider uses. A 4xx/5xx from ai-desktop arrives as a decoded body with an
---`error` field (curl exits 0 on any HTTP status) and counts as a failure too.
---@type Ai.Usage.Sender
local function default_sender(url, body, on_failure)
  local transport = require("ai.providers.transport")
  local prepare_err = transport.post_json(url, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = body,
    timeout_ms = M.TIMEOUT_MS,
  }, function(ok, data)
    if not ok then
      on_failure(type(data) == "string" and data or "request failed")
    elseif type(data) == "table" and data.error ~= nil then
      local err = data.error
      on_failure(type(err) == "table" and tostring(err.message) or tostring(err))
    end
  end)
  if prepare_err then
    on_failure(prepare_err)
  end
end

---@type Ai.Usage.Sender
local sender = default_sender

---@internal
---Swap the sender (tests inject a stub); `nil` restores the default.
---@param fn Ai.Usage.Sender|nil
---@return nil
function M._set_sender(fn)
  sender = fn or default_sender
  warned = false
end

---Whether reporting is switched on (`config.usage.report == true`, nothing else counts).
---@return boolean
function M.enabled()
  local cfg = require("ai.config").get()
  return type(cfg.usage) == "table" and cfg.usage.report == true
end

---The ai-desktop base URL events go to: `config.usage.host` when set, else the
---one the `ai_desktop` provider resolves (`AI_DESKTOP_HOST`, `LOOMAI_HOST`,
---`http://127.0.0.1:8080`). A trailing slash is dropped so the path joins cleanly.
---@return string
function M.host()
  local cfg = require("ai.config").get()
  local configured = type(cfg.usage) == "table" and cfg.usage.host or nil
  local base = type(configured) == "string" and configured ~= "" and configured
    or require("ai.providers.ai_desktop").default_host()
  return (base:gsub("/+$", ""))
end

---A monotonic timestamp for `duration_ms`; pair with `M.elapsed_ms`.
---@return integer ns
function M.now()
  return uv.hrtime()
end

---Whole milliseconds since `started`, never negative.
---@param started integer from `M.now()`
---@return integer
function M.elapsed_ms(started)
  return math.max(0, math.floor((uv.hrtime() - started) / 1e6))
end

---@internal
---A token count as the contract wants it: a whole number >= 0, 0 for anything
---that is not a finite number.
---@param v any
---@return integer
local function count(v)
  if type(v) ~= "number" or v ~= v or v == math.huge or v < 0 then
    return 0
  end
  return math.floor(v)
end

---Prompt and completion tokens of `usage`, read where `provider_id`'s API
---puts them (see `TOKEN_FIELDS`); 0 and 0 when the provider is not listed or
---the counts are missing.
---@param provider_id string
---@param usage any `Ai.Response.usage`
---@return integer prompt_tokens
---@return integer completion_tokens
function M.tokens(provider_id, usage)
  local fields = TOKEN_FIELDS[provider_id]
  if not fields or type(usage) ~= "table" then
    return 0, 0
  end
  return count(usage[fields.prompt]), count(usage[fields.completion])
end

---What `M.report` is told about one finished request. `res` is the provider's
---result (`Ai.Response` or `LibErrorValue`); only `usage` and `kind` are read from it.
---@class Ai.Usage.Outcome
---@field provider string resolved provider id
---@field model string|nil the model the request named (or the provider's default); `"default"` when neither is known
---@field stream boolean
---@field ok boolean
---@field res any `Ai.Response` on success, the error value on failure
---@field duration_ms integer

---Build the event body for `outcome`: every key is one of `FIELDS`, and the
---values are plain scalars -- nothing of `outcome.res` goes through except
---the token counts and, on failure, `res.kind`.
---@param outcome Ai.Usage.Outcome
---@return table event keys are a subset of `FIELDS`
function M.event(outcome)
  local res = type(outcome.res) == "table" and outcome.res or {}
  local prompt_tokens, completion_tokens = 0, 0
  local error_kind = nil
  if outcome.ok then
    prompt_tokens, completion_tokens = M.tokens(outcome.provider, res.usage)
  elseif type(res.kind) == "string" then
    error_kind = res.kind
  end
  local values = {
    provider = outcome.provider,
    model = type(outcome.model) == "string" and outcome.model ~= "" and outcome.model or "default",
    stream = outcome.stream == true,
    ok = outcome.ok == true,
    error_kind = error_kind,
    prompt_tokens = prompt_tokens,
    completion_tokens = completion_tokens,
    duration_ms = count(outcome.duration_ms),
  }
  -- Through the allow-list, not a copy of `values`: a key added to `values`
  -- above by mistake never reaches the wire unless `FIELDS` names it.
  local event = {}
  for _, key in ipairs(M.FIELDS) do
    event[key] = values[key]
  end
  return event
end

---@internal
---Mention a failed report once per session, at DEBUG: the report is a side
---note, a server that is not running must not nag on every request.
---@param reason string
local function note_failure(reason)
  if warned then
    return
  end
  warned = true
  require("lib.nvim.notify")
    .create("[ai]")
    .debug("usage report to ai-desktop failed (said once per session): " .. tostring(reason))
end

---Report one finished request, when reporting is on and the provider is not
---`ai_desktop`. Never raises and never blocks: whatever goes wrong is swallowed
---(see `note_failure`).
---@param outcome Ai.Usage.Outcome
---@return boolean sent `true` when an event was handed to the sender
function M.report(outcome)
  if not M.enabled() or outcome.provider == M.SELF_RECORDING_PROVIDER then
    return false
  end
  local ok, err = pcall(function()
    local body = vim.json.encode(M.event(outcome))
    sender(M.host() .. "/usage/events", body, note_failure)
  end)
  if not ok then
    note_failure(tostring(err))
    return false
  end
  return true
end

---Wrap a request's completion callback so the result is reported exactly
---once. `started` is taken now; `model` is what the resolved request named.
---Used by `ai.ask` (and through its `dispatch`, `ai.bulk`).
---@param provider Ai.Provider
---@param resolved Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
---@return fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
function M.wrap_callback(provider, resolved, cb)
  local started = M.now()
  local reported = false
  return function(ok, res)
    if not reported then
      reported = true
      M.report({
        provider = provider.id,
        model = resolved.model or provider.default_model,
        stream = false,
        ok = ok == true,
        res = res,
        duration_ms = M.elapsed_ms(started),
      })
    end
    cb(ok, res)
  end
end

---Wrap stream handlers so the first terminal event (`on_done` or `on_error`)
---is reported, once; a copy -- the caller's table is not changed.
---@param provider Ai.Provider
---@param resolved Ai.Request
---@param handlers Ai.StreamHandlers
---@return Ai.StreamHandlers
function M.wrap_handlers(provider, resolved, handlers)
  local started = M.now()
  local reported = false
  local function report(ok, res)
    if reported then
      return
    end
    reported = true
    M.report({
      provider = provider.id,
      model = resolved.model or provider.default_model,
      stream = true,
      ok = ok,
      res = res,
      duration_ms = M.elapsed_ms(started),
    })
  end
  local wrapped = vim.tbl_extend("force", {}, handlers)
  wrapped.on_done = function(res)
    report(true, res)
    if handlers.on_done then
      handlers.on_done(res)
    end
  end
  wrapped.on_error = function(err)
    report(false, err)
    if handlers.on_error then
      handlers.on_error(err)
    end
  end
  return wrapped
end

return M
