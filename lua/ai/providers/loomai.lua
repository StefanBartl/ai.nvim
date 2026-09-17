---@module 'ai.providers.loomai'
--- Provider backend for a local loomAI server (`POST /ask`, `POST
--- /ask/stream`). loomAI's own HTTP contract is specified in
--- `nvim/docs/ROADMAP/reports/loomai-ai-nvim-integration.md` (Aufgabe B/C)
--- and implemented in `E:\repos\loomAI\src\main.cpp` -- unlike Claude/OpenAI,
--- loomAI's stream endpoint was designed against that report from the start,
--- so it never hits the "fatal error arrives as a plain, non-SSE JSON body"
--- quirk `ai.providers.sse`'s `recover_error_body` exists for: a loomAI
--- error, streaming or not, is always `{"error":{"message":...}}`, and a
--- stream-time error is always a regular `data: {"error":...}` event.
---
--- Attachments: none. loomAI's `/ask` contract is prompt-and-system text,
--- and there is no field to smuggle bytes through -- so both capability
--- flags are false and any attachment fails the request outright. This is
--- the case `ai.attachments.unsupported` exists for: the alternative is a
--- request that succeeds having quietly discarded the one thing the prompt
--- was asking about.

require("ai.@types")

local attachments = require("ai.attachments")
local lib_error = require("lib.lua.error")
local sse = require("ai.providers.sse")
local transport = require("ai.providers.transport")
local util = require("ai.providers.util")

--- Declared as a class (not `---@type Ai.Provider`) so the `function M.*`
--- methods defined below the literal count as fulfilling the interface --
--- see `claude.lua`.
---@class Ai.Providers.Loomai : Ai.Provider
local M = {
  id = "loomai",
  name = "loomAI (local)",
  capabilities = { streaming = true, vision = false, documents = false },
}

local DEFAULT_HOST = "http://127.0.0.1:8080"

---@param req? Ai.Request
---@return string
local function host(req)
  if req and req.host then
    return req.host
  end
  return util.env_value("LOOMAI_HOST", DEFAULT_HOST)
end

---loomAI is a locally-run server process, not a CLI binary on PATH -- there
---is no "is it installed" proxy the way `ollama.lua` has (the `ollama`
---binary). Per the design decision recorded in `nvim/docs/ROADMAP/reports/
---loomai-ai-nvim-integration.md` (Abschnitt 9, Option a): this stays cheap
---and synchronous rather than making a network round trip against `/health`
----- an unreachable loomAI instance surfaces as a normal `ask`/`stream`
---failure instead, exactly like `ollama.lua`'s own comment describes for an
---unreachable Ollama daemon.
---@return boolean
function M.available()
  return util.executable("curl")
end

---@internal
---@param req Ai.Request
---@return string json
local function build_body(req)
  return vim.json.encode({
    prompt = req.prompt,
    system = req.system,
    model = req.model,
    timeout_ms = req.timeout_ms,
  })
end

---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
function M.ask(req, cb)
  local rejected = attachments.unsupported("loomai", M.capabilities, req.attachments)
  if rejected then
    cb(false, rejected)
    return
  end

  local timeout_ms = req.timeout_ms or 60000
  local prepare_err = transport.post_json(host(req) .. "/ask", {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = build_body(req),
    timeout_ms = timeout_ms,
  }, function(ok, data, obj)
    if not ok then
      cb(false, util.fetch_error("loomai", data, obj, timeout_ms))
      return
    end
    -- curl exits 0 regardless of HTTP status (see fetch_json's own doc), so
    -- a loomAI 4xx/5xx with a valid `{"error":{"message":...}}` body still
    -- decodes fine here and must be checked explicitly.
    if type(data) ~= "table" then
      cb(false, lib_error.new("invalid_response", "loomai: invalid response", data))
      return
    end
    data = util.denil(data)
    if data.error ~= nil then
      local msg = type(data.error) == "table" and data.error.message or data.error
      cb(false, lib_error.new("api_error", "loomai error: " .. tostring(msg), data.error))
      return
    end
    cb(true, {
      text = data.text or "",
      usage = data.usage,
      stop_reason = data.stop_reason,
      provider = "loomai",
    })
  end)
  if prepare_err then
    cb(false, lib_error.new("network_error", "loomai: " .. prepare_err))
  end
end

---@param req Ai.Request
---@param handlers Ai.StreamHandlers
---@return vim.SystemObj|nil
function M.stream(req, handlers)
  local rejected = attachments.unsupported("loomai", M.capabilities, req.attachments)
  if rejected then
    if handlers.on_error then
      handlers.on_error(rejected)
    end
    return nil
  end

  local timeout_ms = req.timeout_ms or 60000
  local text_parts = {}

  local process, prepare_err = transport.stream_json(host(req) .. "/ask/stream", {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = build_body(req),
    timeout_ms = timeout_ms,
  }, {
    on_chunk = function(line)
      local payload = sse.data_payload(line)
      if not payload or payload == "" or payload == "[DONE]" then
        return
      end
      local ok, decoded = pcall(vim.json.decode, payload)
      if not ok or type(decoded) ~= "table" then
        return
      end
      decoded = util.denil(decoded)
      if decoded.error ~= nil then
        if handlers.on_error then
          local msg = type(decoded.error) == "table" and decoded.error.message or decoded.error
          handlers.on_error(
            lib_error.new("api_error", "loomai error: " .. tostring(msg), decoded.error)
          )
        end
        return
      end
      local delta = decoded.delta
      if type(delta) == "string" and delta ~= "" then
        text_parts[#text_parts + 1] = delta
        if handlers.on_chunk then
          handlers.on_chunk(delta)
        end
      end
    end,
    on_done = function(obj)
      if obj.code ~= 0 then
        if handlers.on_error then
          handlers.on_error(util.curl_exit_error("loomai", obj, timeout_ms))
        end
        return
      end
      if handlers.on_done then
        handlers.on_done({
          text = table.concat(text_parts, ""),
          provider = "loomai",
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
    handlers.on_error(lib_error.new("network_error", "loomai: " .. prepare_err))
  end
  return process
end

return M
