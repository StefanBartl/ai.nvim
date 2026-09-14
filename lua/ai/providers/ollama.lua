---@module 'ai.providers.ollama'
--- Provider backend for a local Ollama daemon. Streaming responses are
--- NDJSON (one complete JSON object per line, no `data:` prefix and no
--- `[DONE]` sentinel -- the `done: true` field on the object itself is the
--- end marker) -- a different line shape than the SSE providers, which is
--- exactly why `lib.nvim.net.curl.fetch_stream` leaves line interpretation
--- to each provider instead of assuming one format.

require("ai.@types")

local curl = require("lib.nvim.net.curl")
local util = require("ai.providers.util")

--- Declared as a class (not `---@type Ai.Provider`) so the `function M.*`
--- methods defined below the literal count as fulfilling the interface --
--- see `claude.lua`.
---@class Ai.Providers.Ollama : Ai.Provider
local M = {
  id = "ollama",
  name = "Ollama (local)",
  capabilities = { streaming = true, vision = false },
}

local DEFAULT_HOST = "http://127.0.0.1:11434"
local DEFAULT_MODEL = "llama3.2"

---@return string
local function host()
  return util.env_value("OLLAMA_HOST", DEFAULT_HOST)
end

---No network round trip here on purpose -- `available()` runs on every
---`"auto"` resolution and must stay cheap. The daemon binary being on PATH
---is a reasonable proxy for "ollama is set up on this machine"; an actually
---unreachable daemon still surfaces as a normal request failure.
---@return boolean
function M.available()
  return vim.fn.executable("curl") == 1 and vim.fn.executable("ollama") == 1
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
  messages[#messages + 1] = { role = "user", content = req.prompt }
  return vim.json.encode({
    model = req.model or DEFAULT_MODEL,
    messages = messages,
    stream = stream,
  })
end

---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|string)
function M.ask(req, cb)
  curl.fetch_json(host() .. "/api/chat", {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = build_body(req, false),
    timeout_ms = req.timeout_ms or 60000,
  }, function(ok, data)
    if not ok then
      cb(false, "ollama: " .. tostring(data))
      return
    end
    if type(data) ~= "table" then
      cb(false, "ollama: invalid response")
      return
    end
    if type(data.error) == "string" then
      cb(false, "ollama error: " .. data.error)
      return
    end
    cb(true, {
      text = (data.message and data.message.content) or "",
      stop_reason = data.done_reason,
      provider = "ollama",
    })
  end)
end

---@param req Ai.Request
---@param handlers Ai.StreamHandlers
---@return vim.SystemObj|nil
function M.stream(req, handlers)
  local text_parts = {}
  local done_reason

  return curl.fetch_stream(host() .. "/api/chat", {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = build_body(req, true),
    timeout_ms = req.timeout_ms or 60000,
  }, {
    on_chunk = function(line)
      if line == "" then
        return
      end
      local ok, decoded = pcall(vim.json.decode, line)
      if not ok or type(decoded) ~= "table" then
        return
      end
      if type(decoded.error) == "string" then
        if handlers.on_error then
          handlers.on_error("ollama error: " .. decoded.error)
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
      if obj.code ~= 0 then
        if handlers.on_error then
          handlers.on_error(util.curl_exit_error("ollama", obj))
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
    on_error = handlers.on_error,
  })
end

return M
