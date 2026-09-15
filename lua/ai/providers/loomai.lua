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

require("ai.@types")

local curl = require("lib.nvim.net.curl")
local sse = require("ai.providers.sse")
local util = require("ai.providers.util")

--- Declared as a class (not `---@type Ai.Provider`) so the `function M.*`
--- methods defined below the literal count as fulfilling the interface --
--- see `claude.lua`.
---@class Ai.Providers.Loomai : Ai.Provider
local M = {
  id = "loomai",
  name = "loomAI (local)",
  capabilities = { streaming = true, vision = false },
}

local DEFAULT_HOST = "http://127.0.0.1:8080"

---@return string
local function host()
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
---@param cb fun(ok: boolean, res_or_err: Ai.Response|string)
function M.ask(req, cb)
  curl.fetch_json(host() .. "/ask", {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = build_body(req),
    timeout_ms = req.timeout_ms or 60000,
  }, function(ok, data)
    if not ok then
      cb(false, "loomai: " .. tostring(data))
      return
    end
    -- curl exits 0 regardless of HTTP status (see fetch_json's own doc), so
    -- a loomAI 4xx/5xx with a valid `{"error":{"message":...}}` body still
    -- decodes fine here and must be checked explicitly.
    if type(data) ~= "table" then
      cb(false, "loomai: invalid response")
      return
    end
    data = util.denil(data)
    if data.error ~= nil then
      local msg = type(data.error) == "table" and data.error.message or data.error
      cb(false, "loomai error: " .. tostring(msg))
      return
    end
    cb(true, {
      text = data.text or "",
      usage = data.usage,
      stop_reason = data.stop_reason,
      provider = "loomai",
    })
  end)
end

---@param req Ai.Request
---@param handlers Ai.StreamHandlers
---@return vim.SystemObj|nil
function M.stream(req, handlers)
  local text_parts = {}

  return curl.fetch_stream(host() .. "/ask/stream", {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = build_body(req),
    timeout_ms = req.timeout_ms or 60000,
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
          handlers.on_error("loomai error: " .. tostring(msg))
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
          handlers.on_error(util.curl_exit_error("loomai", obj))
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
    on_error = handlers.on_error,
  })
end

return M
