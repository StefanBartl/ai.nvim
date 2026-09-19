---@module 'ai.providers.ollama'
--- Provider backend for a local Ollama daemon. Streaming responses are
--- NDJSON (one complete JSON object per line, no `data:` prefix and no
--- `[DONE]` sentinel -- the `done: true` field on the object itself is the
--- end marker) -- a different line shape than the SSE providers, which is
--- exactly why `lib.nvim.net.curl.fetch_stream` leaves line interpretation
--- to each provider instead of assuming one format.
---
--- Attachments: Ollama's chat endpoint takes images as a bare `images` array
--- of base64 strings on the message itself -- no media type, no per-image
--- role, no document equivalent. That is the narrowest of the four wire
--- formats `Ai.Attachment` maps onto, and the reason a *document* attachment
--- is rejected here rather than quietly rasterized into something else: what
--- a PDF should become for a vision model (how many pages, at what DPI) is a
--- decision belonging to the caller that has the PDF, not to a transport
--- backend guessing on its behalf. `capabilities.vision` says the endpoint
--- has a slot, not that the chosen model reads it -- `llava` does,
--- `llama3.2` accepts the field and ignores it.

require("ai.@types")

local attachments = require("ai.attachments")
local lib_error = require("lib.lua.error")
local transport = require("ai.providers.transport")
local util = require("ai.providers.util")

--- Declared as a class (not `---@type Ai.Provider`) so the `function M.*`
--- methods defined below the literal count as fulfilling the interface --
--- see `claude.lua`.
---@class Ai.Providers.Ollama : Ai.Provider
local M = {
  id = "ollama",
  name = "Ollama (local)",
  capabilities = { streaming = true, vision = true, documents = false },
}

local DEFAULT_HOST = "http://127.0.0.1:11434"
local DEFAULT_MODEL = "llama3.2"

--- Deliberately AI_OLLAMA_HOST, not OLLAMA_HOST: the latter is already
--- Ollama's own env var for the *server*'s bind address (commonly something
--- like "0.0.0.0:11434", with no scheme and not a valid client target) --
--- reusing it here as a client override would silently break on any machine
--- that already sets it for that purpose. Same reasoning loomai.lua applies
--- with LOOMAI_HOST vs. LOOMAI_OLLAMA_HOST.
---@param req? Ai.Request
---@return string
local function host(req)
  if req and req.host then
    return req.host
  end
  return util.env_value("AI_OLLAMA_HOST", DEFAULT_HOST)
end

---No network round trip here on purpose -- `available()` runs on every
---`"auto"` resolution and must stay cheap. The daemon binary being on PATH
---is a reasonable proxy for "ollama is set up on this machine"; an actually
---unreachable daemon still surfaces as a normal request failure.
---@return boolean
function M.available()
  return util.executable("curl") and util.executable("ollama")
end

---@internal
---@param req Ai.Request
---@param stream boolean
---@return string json
local function build_body(req, stream)
  local messages = {}
  if req.system then
    messages[#messages + 1] = { role = "system", content = req.system }
  end
  local user = { role = "user", content = req.prompt }
  -- Only `kind == "image"` can reach this point: `M.capabilities.documents`
  -- is false, so a document attachment has already failed the request in
  -- `ask`/`stream` below.
  local images = {}
  for _, att in ipairs(req.attachments or {}) do
    images[#images + 1] = att.data
  end
  if #images > 0 then
    user.images = images
  end
  messages[#messages + 1] = user
  return vim.json.encode({
    model = req.model or DEFAULT_MODEL,
    messages = messages,
    stream = stream,
  })
end

---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
function M.ask(req, cb)
  local rejected = attachments.unsupported("ollama", M.capabilities, req.attachments)
  if rejected then
    cb(false, rejected)
    return
  end

  local timeout_ms = req.timeout_ms or 60000
  local prepare_err = transport.post_json(host(req) .. "/api/chat", {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = build_body(req, false),
    timeout_ms = timeout_ms,
  }, function(ok, data, obj)
    if not ok then
      cb(false, util.fetch_error("ollama", data, obj, timeout_ms))
      return
    end
    if type(data) ~= "table" then
      cb(false, lib_error.new("invalid_response", "ollama: invalid response", data))
      return
    end
    data = util.denil(data)
    if type(data.error) == "string" then
      cb(false, lib_error.new("api_error", "ollama error: " .. data.error, data.error))
      return
    end
    cb(true, {
      text = (data.message and data.message.content) or "",
      stop_reason = data.done_reason,
      provider = "ollama",
    })
  end)
  if prepare_err then
    cb(false, lib_error.new("network_error", "ollama: " .. prepare_err))
  end
end

---@param req Ai.Request
---@param handlers Ai.StreamHandlers
---@return vim.SystemObj|nil
function M.stream(req, handlers)
  local rejected = attachments.unsupported("ollama", M.capabilities, req.attachments)
  if rejected then
    if handlers.on_error then
      handlers.on_error(rejected)
    end
    return nil
  end

  local timeout_ms = req.timeout_ms or 60000
  local text_parts = {}
  local done_reason
  -- Set once an error is reported mid-stream so `on_done` below doesn't
  -- also fire with an empty-but-"successful" response afterwards.
  local failed = false

  local process, prepare_err = transport.stream_json(host(req) .. "/api/chat", {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = build_body(req, true),
    timeout_ms = timeout_ms,
  }, {
    on_chunk = function(line)
      if line == "" then
        return
      end
      local ok, decoded = pcall(vim.json.decode, line)
      if not ok or type(decoded) ~= "table" then
        return
      end
      decoded = util.denil(decoded)
      if type(decoded.error) == "string" then
        failed = true
        if handlers.on_error then
          handlers.on_error(
            lib_error.new("api_error", "ollama error: " .. decoded.error, decoded.error)
          )
        end
        return
      end
      local delta = decoded.message and decoded.message.content
      if type(delta) == "string" and delta ~= "" then
        text_parts[#text_parts + 1] = delta
        if handlers.on_chunk then
          handlers.on_chunk(delta)
        end
      end
      if decoded.done then
        done_reason = decoded.done_reason
      end
    end,
    on_done = function(obj)
      if failed then
        return
      end
      if obj.code ~= 0 then
        if handlers.on_error then
          handlers.on_error(util.curl_exit_error("ollama", obj, timeout_ms))
        end
        return
      end
      if handlers.on_done then
        handlers.on_done({
          text = table.concat(text_parts, ""),
          stop_reason = done_reason,
          provider = "ollama",
        })
      end
    end,
    -- See claude.lua's identical comment: `fetch_stream`'s own `on_error` is
    -- `lib.nvim.net.curl`'s plain-string API, not `Ai.StreamHandlers`'s.
    on_error = function(err)
      if handlers.on_error then
        handlers.on_error(lib_error.new("network_error", err))
      end
    end,
  })

  -- See claude.lua: a body that never reached curl fires none of the
  -- handlers above, so it has to be reported here.
  if prepare_err and handlers.on_error then
    handlers.on_error(lib_error.new("network_error", "ollama: " .. prepare_err))
  end
  return process
end

return M
