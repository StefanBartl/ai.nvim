---@module 'ai.providers.openai'
--- Provider backend for the OpenAI Chat Completions API (streaming SSE, the
--- same line shape as `claude.lua` but a different event schema -- OpenAI's
--- delta lives at `choices[1].delta.content`, with no separate event-type
--- field to branch on).

require("ai.@types")

local curl = require("lib.nvim.net.curl")
local sse = require("ai.providers.sse")
local util = require("ai.providers.util")

--- Declared as a class (not `---@type Ai.Provider`) so the `function M.*`
--- methods defined below the literal count as fulfilling the interface --
--- see `claude.lua`.
---@class Ai.Providers.Openai : Ai.Provider
local M = {
  id = "openai",
  name = "OpenAI Chat Completions",
  capabilities = { streaming = true, vision = false },
}

local API_URL = "https://api.openai.com/v1/chat/completions"
local DEFAULT_MODEL = "gpt-4o"

---@return string|nil
local function api_key()
  return util.env_value("OPENAI_API_KEY")
end

---@return boolean
function M.available()
  return vim.fn.executable("curl") == 1 and api_key() ~= nil
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
    stream = stream or nil,
  })
end

---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|string)
function M.ask(req, cb)
  local key = api_key()
  if not key then
    cb(false, "openai: OPENAI_API_KEY not set")
    return
  end

  -- The Bearer token still goes through fetch_json's existing `-K` stdin
  -- path (bearer_token, not secret_headers) -- that generic mechanism
  -- already covers "Authorization: Bearer ...", which is exactly what this
  -- API expects. secret_headers exists for names that mechanism cannot
  -- recognize (see claude.lua's `x-api-key`), not as a second way to spell
  -- the same thing.
  curl.fetch_json(API_URL, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    bearer_token = key,
    body = build_body(req, false),
    timeout_ms = req.timeout_ms or 60000,
  }, function(ok, data)
    if not ok then
      cb(false, "openai: " .. tostring(data))
      return
    end
    if type(data) == "table" and data.error then
      cb(false, "openai API error: " .. tostring(data.error.message))
      return
    end
    local choice = data.choices and data.choices[1]
    cb(true, {
      text = (choice and choice.message and choice.message.content) or "",
      usage = data.usage,
      stop_reason = choice and choice.finish_reason,
      provider = "openai",
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
      handlers.on_error("openai: OPENAI_API_KEY not set")
    end
    return nil
  end

  local text_parts = {}
  local finish_reason
  -- Lines that are not `data: ...` at all -- see ai.providers.sse's module
  -- doc for why (a real 401 comes back as a plain, pretty-printed JSON body,
  -- not an SSE event, and curl still exits 0; verified against the live API).
  local non_data_lines = {}

  return curl.fetch_stream(API_URL, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    bearer_token = key,
    body = build_body(req, true),
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
      if payload == "" or payload == "[DONE]" then
        return
      end
      local ok, decoded = pcall(vim.json.decode, payload)
      if not ok or type(decoded) ~= "table" then
        return
      end
      if decoded.error then
        if handlers.on_error then
          handlers.on_error("openai API error: " .. tostring(decoded.error.message))
        end
        return
      end
      local choice = decoded.choices and decoded.choices[1]
      local delta = choice and choice.delta and choice.delta.content
      if type(delta) == "string" and delta ~= "" then
        text_parts[#text_parts + 1] = delta
        if handlers.on_chunk then
          handlers.on_chunk(delta)
        end
      end
      if choice and choice.finish_reason then
        finish_reason = choice.finish_reason
      end
    end,
    on_done = function(obj)
      if obj.code ~= 0 then
        if handlers.on_error then
          handlers.on_error(util.curl_exit_error("openai", obj))
        end
        return
      end
      -- No actual event stream ever arrived, but something non-empty did --
      -- exactly the plain-JSON-error-body case above. curl itself exited
      -- cleanly, so without this check on_done would report an empty
      -- success and the failure would vanish silently.
      if #text_parts == 0 then
        local decoded_err = sse.recover_error_body(non_data_lines)
        if decoded_err and decoded_err.error then
          if handlers.on_error then
            handlers.on_error("openai API error: " .. tostring(decoded_err.error.message))
          end
          return
        end
      end
      if handlers.on_done then
        handlers.on_done({
          text = table.concat(text_parts, ""),
          stop_reason = finish_reason,
          provider = "openai",
        })
      end
    end,
    on_error = handlers.on_error,
  })
end

return M
