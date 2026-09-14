---@module 'ai.providers.gemini'
--- Provider backend for Google's Gemini API (Generative Language API).
--- Streaming uses SSE (`alt=sse` query param), same line shape as
--- `claude.lua`/`openai.lua` but yet another response schema -- a chunk's
--- text lives at `candidates[1].content.parts[*].text`, and there is no
--- `[DONE]` sentinel: the stream just ends when the connection closes.
---
--- Auth deliberately uses the `x-goog-api-key` header, not the `?key=...`
--- query parameter most Gemini quickstarts show -- the query-param form
--- would put the key in curl's argv (and thus the process list) once
--- interpolated into the request URL, exactly the class of bug ai.nvim
--- exists to avoid (see claude.lua's module doc). The header form goes
--- through `secret_headers`, same mechanism claude.lua uses for `x-api-key`.
---
--- Caveat: unlike claude.lua/openai.lua, the "a fatal error arrives as a
--- plain, non-SSE JSON body" handling below (via `ai.providers.sse`) is
--- applied defensively by analogy, not verified against a live error
--- response -- no `GEMINI_API_KEY` was available to test against the real
--- API while writing this. Confirm during live testing (see
--- `docs/ROADMAP/reports/ai/live-testing-plan.md` in the nvim config repo).

require("ai.@types")

local curl = require("lib.nvim.net.curl")
local sse = require("ai.providers.sse")
local util = require("ai.providers.util")

--- Declared as a class (not `---@type Ai.Provider`) so the `function M.*`
--- methods defined below the literal count as fulfilling the interface --
--- see `claude.lua`.
---@class Ai.Providers.Gemini : Ai.Provider
local M = {
  id = "gemini",
  name = "Google Gemini API",
  capabilities = { streaming = true, vision = false },
}

local API_BASE = "https://generativelanguage.googleapis.com/v1beta/models/"
local DEFAULT_MODEL = "gemini-2.5-flash"

---@return string|nil
local function api_key()
  return util.env_value("GEMINI_API_KEY")
end

---@return boolean
function M.available()
  return vim.fn.executable("curl") == 1 and api_key() ~= nil
end

---@internal
---@param req Ai.Request
---@return string json
local function build_body(req)
  local body = {
    contents = { { role = "user", parts = { { text = req.prompt } } } },
  }
  if req.system then
    body.systemInstruction = { parts = { { text = req.system } } }
  end
  return vim.json.encode(body)
end

---@internal
---@param decoded table Gemini `GenerateContentResponse` body
---@return string text, string|nil finish_reason
local function candidate_text(decoded)
  local candidate = decoded.candidates and decoded.candidates[1]
  if not candidate then
    return "", nil
  end
  local text_parts = {}
  for _, part in ipairs((candidate.content and candidate.content.parts) or {}) do
    if type(part.text) == "string" then
      text_parts[#text_parts + 1] = part.text
    end
  end
  return table.concat(text_parts, ""), candidate.finishReason
end

---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|string)
function M.ask(req, cb)
  local key = api_key()
  if not key then
    cb(false, "gemini: GEMINI_API_KEY not set")
    return
  end

  local url = API_BASE .. (req.model or DEFAULT_MODEL) .. ":generateContent"
  curl.fetch_json(url, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    secret_headers = { ["x-goog-api-key"] = key },
    body = build_body(req),
    timeout_ms = req.timeout_ms or 60000,
  }, function(ok, data)
    if not ok then
      cb(false, "gemini: " .. tostring(data))
      return
    end
    if type(data) == "table" and data.error then
      cb(false, "gemini API error: " .. tostring(data.error.message))
      return
    end
    local text, finish_reason = candidate_text(data)
    cb(true, {
      text = text,
      usage = data.usageMetadata,
      stop_reason = finish_reason,
      provider = "gemini",
    })
  end)
end

---@param req Ai.Request
---@param handlers Ai.StreamHandlers
---@return vim.SystemObj|nil
function M.stream(req, handlers)
  local key = api_key()
  if not key then
    if handlers.on_error then
      handlers.on_error("gemini: GEMINI_API_KEY not set")
    end
    return nil
  end

  local text_parts = {}
  local finish_reason, usage
  -- See module doc: applied defensively by analogy with claude.lua/
  -- openai.lua, not yet verified against a live Gemini error response.
  local non_data_lines = {}

  local url = API_BASE .. (req.model or DEFAULT_MODEL) .. ":streamGenerateContent?alt=sse"
  return curl.fetch_stream(url, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    secret_headers = { ["x-goog-api-key"] = key },
    body = build_body(req),
    timeout_ms = req.timeout_ms or 60000,
  }, {
    on_chunk = function(line)
      local payload = sse.data_payload(line)
      if not payload then
        if line ~= "" then
          non_data_lines[#non_data_lines + 1] = line
        end
        return
      end
      if payload == "" then
        return
      end
      local ok, decoded = pcall(vim.json.decode, payload)
      if not ok or type(decoded) ~= "table" then
        return
      end
      if decoded.error then
        if handlers.on_error then
          handlers.on_error("gemini API error: " .. tostring(decoded.error.message))
        end
        return
      end
      usage = decoded.usageMetadata or usage
      local delta, reason = candidate_text(decoded)
      if delta ~= "" then
        text_parts[#text_parts + 1] = delta
        if handlers.on_chunk then
          handlers.on_chunk(delta)
        end
      end
      if reason then
        finish_reason = reason
      end
    end,
    on_done = function(obj)
      if obj.code ~= 0 then
        if handlers.on_error then
          handlers.on_error(util.curl_exit_error("gemini", obj))
        end
        return
      end
      if #text_parts == 0 then
        local decoded_err = sse.recover_error_body(non_data_lines)
        if decoded_err and decoded_err.error then
          if handlers.on_error then
            handlers.on_error("gemini API error: " .. tostring(decoded_err.error.message))
          end
          return
        end
      end
      if handlers.on_done then
        handlers.on_done({
          text = table.concat(text_parts, ""),
          usage = usage,
          stop_reason = finish_reason,
          provider = "gemini",
        })
      end
    end,
    on_error = handlers.on_error,
  })
end

return M
