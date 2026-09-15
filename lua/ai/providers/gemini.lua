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
local lib_error = require("lib.lua.error")
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

-- Unlike claude.lua/openai.lua, `model` here is interpolated straight into
-- the request URL's path (Gemini has no way to pass it in the JSON body
-- instead). cpp-httplib on the loomAI side escapes `\r`/`\n` but not `/`, so
-- an unchecked `model` could redirect the authenticated request to an
-- arbitrary path on Google's host. Real model names are alphanumeric plus
-- `.`/`-`/`_`; anything else is rejected before it ever reaches the URL.
local MODEL_PATTERN = "^[%w%.%-_]+$"

---@return string|nil
local function api_key()
  return util.env_value("GEMINI_API_KEY")
end

---@return boolean
function M.available()
  return util.executable("curl") and api_key() ~= nil
end

---@internal
---@param model string
---@return boolean
local function valid_model(model)
  return type(model) == "string" and model:match(MODEL_PATTERN) ~= nil
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

---@internal
--- Gemini reports a safety/policy block as a normal 200 response with a
--- `promptFeedback.blockReason` and no `candidates` at all -- there is no
--- `error` field, so `candidate_text` alone would silently return `""` and
--- look like an empty-but-successful answer instead of a blocked request.
---@param decoded table Gemini `GenerateContentResponse` body
---@return string|nil reason
local function prompt_block_reason(decoded)
  local feedback = decoded.promptFeedback
  if not feedback or not feedback.blockReason then
    return nil
  end
  if decoded.candidates and decoded.candidates[1] then
    return nil
  end
  return feedback.blockReason
end

---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
function M.ask(req, cb)
  local key = api_key()
  if not key then
    cb(
      false,
      lib_error.new(
        "missing_api_key",
        "gemini: GEMINI_API_KEY not set",
        { env_var = "GEMINI_API_KEY" }
      )
    )
    return
  end

  local model = req.model or DEFAULT_MODEL
  if not valid_model(model) then
    cb(
      false,
      lib_error.new(
        "invalid_request",
        "gemini: invalid model name: " .. tostring(model),
        { model = model }
      )
    )
    return
  end

  local url = API_BASE .. model .. ":generateContent"
  curl.fetch_json(url, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    secret_headers = { ["x-goog-api-key"] = key },
    body = build_body(req),
    timeout_ms = req.timeout_ms or 60000,
  }, function(ok, data)
    if not ok then
      cb(false, lib_error.new("network_error", "gemini: " .. tostring(data), data))
      return
    end
    if type(data) == "table" then
      data = util.denil(data)
    end
    if type(data) == "table" and data.error then
      cb(
        false,
        lib_error.new("api_error", "gemini API error: " .. tostring(data.error.message), data.error)
      )
      return
    end
    local block_reason = prompt_block_reason(data)
    if block_reason then
      cb(
        false,
        lib_error.new(
          "blocked",
          "gemini: prompt blocked (" .. tostring(block_reason) .. ")",
          { block_reason = block_reason }
        )
      )
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
      handlers.on_error(
        lib_error.new(
          "missing_api_key",
          "gemini: GEMINI_API_KEY not set",
          { env_var = "GEMINI_API_KEY" }
        )
      )
    end
    return nil
  end

  local model = req.model or DEFAULT_MODEL
  if not valid_model(model) then
    if handlers.on_error then
      handlers.on_error(
        lib_error.new(
          "invalid_request",
          "gemini: invalid model name: " .. tostring(model),
          { model = model }
        )
      )
    end
    return nil
  end

  local text_parts = {}
  local finish_reason, usage
  -- See module doc: applied defensively by analogy with claude.lua/
  -- openai.lua, not yet verified against a live Gemini error response.
  local non_data_lines = {}
  -- Set once an error is reported mid-stream so `on_done` below doesn't
  -- also fire with an empty-but-"successful" response afterwards.
  local failed = false

  local url = API_BASE .. model .. ":streamGenerateContent?alt=sse"
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
      decoded = util.denil(decoded)
      if decoded.error then
        failed = true
        if handlers.on_error then
          handlers.on_error(
            lib_error.new(
              "api_error",
              "gemini API error: " .. tostring(decoded.error.message),
              decoded.error
            )
          )
        end
        return
      end
      local block_reason = prompt_block_reason(decoded)
      if block_reason then
        failed = true
        if handlers.on_error then
          handlers.on_error(
            lib_error.new(
              "blocked",
              "gemini: prompt blocked (" .. tostring(block_reason) .. ")",
              { block_reason = block_reason }
            )
          )
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
      if failed then
        return
      end
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
            handlers.on_error(
              lib_error.new(
                "api_error",
                "gemini API error: " .. tostring(decoded_err.error.message),
                decoded_err.error
              )
            )
          end
          return
        end
        local recovered_block_reason = decoded_err and prompt_block_reason(decoded_err)
        if recovered_block_reason then
          if handlers.on_error then
            handlers.on_error(
              lib_error.new(
                "blocked",
                "gemini: prompt blocked (" .. tostring(recovered_block_reason) .. ")",
                { block_reason = recovered_block_reason }
              )
            )
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
    -- See claude.lua's identical comment: `fetch_stream`'s own `on_error` is
    -- `lib.nvim.net.curl`'s plain-string API, not `Ai.StreamHandlers`'s.
    on_error = function(err)
      if handlers.on_error then
        handlers.on_error(lib_error.new("network_error", err))
      end
    end,
  })
end

return M
