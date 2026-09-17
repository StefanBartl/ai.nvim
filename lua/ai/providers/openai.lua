---@module 'ai.providers.openai'
--- Provider backend for the OpenAI Chat Completions API (streaming SSE, the
--- same line shape as `claude.lua` but a different event schema -- OpenAI's
--- delta lives at `choices[1].delta.content`, with no separate event-type
--- field to branch on).
---
--- Attachments: an image becomes an `image_url` content part whose `url` is
--- a `data:` URI rather than an actual URL -- the same field carries both,
--- which is why `Ai.Attachment.media_type` has to be spliced back into the
--- string here instead of travelling in a field of its own. Documents are
--- refused: Chat Completions grew a separate `file` part for them later and
--- with different constraints, and claiming support that has never been
--- exercised against the live API would be worse than saying no.

require("ai.@types")

local attachments = require("ai.attachments")
local lib_error = require("lib.lua.error")
local sse = require("ai.providers.sse")
local transport = require("ai.providers.transport")
local util = require("ai.providers.util")

--- Declared as a class (not `---@type Ai.Provider`) so the `function M.*`
--- methods defined below the literal count as fulfilling the interface --
--- see `claude.lua`.
---@class Ai.Providers.Openai : Ai.Provider
local M = {
  id = "openai",
  name = "OpenAI Chat Completions",
  capabilities = { streaming = true, vision = true, documents = false },
}

local API_URL = "https://api.openai.com/v1/chat/completions"
local DEFAULT_MODEL = "gpt-4o"

---@param req? Ai.Request
---@return string|nil
local function api_key(req)
  if req and req.api_key then
    return req.api_key
  end
  return util.env_value("OPENAI_API_KEY")
end

---@param req? Ai.Request
---@return boolean
function M.available(req)
  return util.executable("curl") and api_key(req) ~= nil
end

---@internal
---See `claude.lua`'s `user_content`: a plain string without attachments, a
---content-part array with them, attachments before the prompt.
---@param req Ai.Request
---@return string|table content
local function user_content(req)
  local list = req.attachments
  if not list or #list == 0 then
    return req.prompt
  end
  local content = {}
  for _, att in ipairs(list) do
    content[#content + 1] = {
      type = "image_url",
      image_url = { url = string.format("data:%s;base64,%s", att.media_type, att.data) },
    }
  end
  content[#content + 1] = { type = "text", text = req.prompt }
  return content
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
  messages[#messages + 1] = { role = "user", content = user_content(req) }
  return vim.json.encode({
    model = req.model or DEFAULT_MODEL,
    messages = messages,
    stream = stream or nil,
  })
end

---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
function M.ask(req, cb)
  local key = api_key(req)
  if not key then
    cb(
      false,
      lib_error.new(
        "missing_api_key",
        "openai: OPENAI_API_KEY not set",
        { env_var = "OPENAI_API_KEY" }
      )
    )
    return
  end

  local rejected = attachments.unsupported("openai", M.capabilities, req.attachments)
  if rejected then
    cb(false, rejected)
    return
  end

  -- The Bearer token still goes through fetch_json's existing `-K` stdin
  -- path (bearer_token, not secret_headers) -- that generic mechanism
  -- already covers "Authorization: Bearer ...", which is exactly what this
  -- API expects. secret_headers exists for names that mechanism cannot
  -- recognize (see claude.lua's `x-api-key`), not as a second way to spell
  -- the same thing.
  local timeout_ms = req.timeout_ms or 60000
  local prepare_err = transport.post_json(API_URL, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    bearer_token = key,
    body = build_body(req, false),
    timeout_ms = timeout_ms,
  }, function(ok, data, obj)
    if not ok then
      cb(false, util.fetch_error("openai", data, obj, timeout_ms))
      return
    end
    if type(data) == "table" then
      data = util.denil(data)
    end
    if type(data) == "table" and data.error then
      cb(
        false,
        lib_error.new("api_error", "openai API error: " .. tostring(data.error.message), data.error)
      )
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
  if prepare_err then
    cb(false, lib_error.new("invalid_request", "openai: " .. prepare_err))
  end
end

---@param req Ai.Request
---@param handlers Ai.StreamHandlers
---@return vim.SystemObj|nil
function M.stream(req, handlers)
  local key = api_key(req)
  if not key then
    if handlers.on_error then
      handlers.on_error(
        lib_error.new(
          "missing_api_key",
          "openai: OPENAI_API_KEY not set",
          { env_var = "OPENAI_API_KEY" }
        )
      )
    end
    return nil
  end

  local rejected = attachments.unsupported("openai", M.capabilities, req.attachments)
  if rejected then
    if handlers.on_error then
      handlers.on_error(rejected)
    end
    return nil
  end

  local timeout_ms = req.timeout_ms or 60000
  local text_parts = {}
  local finish_reason
  -- Lines that are not `data: ...` at all -- see ai.providers.sse's module
  -- doc for why (a real 401 comes back as a plain, pretty-printed JSON body,
  -- not an SSE event, and curl still exits 0; verified against the live API).
  local non_data_lines = {}

  local process, prepare_err = transport.stream_json(API_URL, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    bearer_token = key,
    body = build_body(req, true),
    timeout_ms = timeout_ms,
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
      decoded = util.denil(decoded)
      if decoded.error then
        if handlers.on_error then
          handlers.on_error(
            lib_error.new(
              "api_error",
              "openai API error: " .. tostring(decoded.error.message),
              decoded.error
            )
          )
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
          handlers.on_error(util.curl_exit_error("openai", obj, timeout_ms))
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
            handlers.on_error(
              lib_error.new(
                "api_error",
                "openai API error: " .. tostring(decoded_err.error.message),
                decoded_err.error
              )
            )
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
    handlers.on_error(lib_error.new("invalid_request", "openai: " .. prepare_err))
  end
  return process
end

return M
