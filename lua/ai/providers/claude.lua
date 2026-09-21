---@module 'ai.providers.claude'
--- Provider backend for the Anthropic Messages API. Streaming uses
--- server-sent events; `lib.nvim.net.curl.fetch_stream` hands this module
--- one raw line at a time and it is this file's job -- not the transport's
--- -- to know that Anthropic's event stream carries a `content_block_delta`
--- event per text chunk. The API key never reaches curl's argv: it goes
--- through `secret_headers`, which is the reason this module exists at all
--- (the two real bugs pdfport.nvim's original `claude.lua` backend had --
--- broken JSON escaping and an argv-visible API key -- are what motivated
--- ai.nvim in the first place).
---
--- Attachments: Anthropic takes them as content blocks on the user message,
--- and its own block type names (`"image"`, `"document"`) happen to be
--- exactly `Ai.Attachment.kind`'s two values -- so the mapping below reads
--- like a pass-through and is not one; it is this provider's spelling of a
--- neutral shape, the same as everywhere else in this directory. A `document`
--- block is what lets a PDF be sent whole rather than rasterized page by page
--- first, which is why `capabilities.documents` is true here and almost
--- nowhere else.

require("ai.@types")

local attachments = require("ai.attachments")
local lib_error = require("lib.lua.error")
local sse = require("ai.providers.sse")
local transport = require("ai.providers.transport")
local util = require("ai.providers.util")

--- Declared as a class (not `---@type Ai.Provider`) so the `function M.*`
--- methods defined below the literal count as fulfilling the interface --
--- see pdfport.nvim's `backends/claude.lua` for the same idiom.
---@class Ai.Providers.Claude : Ai.Provider
local M = {
  id = "claude",
  name = "Anthropic Claude API",
  capabilities = { streaming = true, vision = true, documents = true },
}

local API_URL = "https://api.anthropic.com/v1/messages"
local ANTHROPIC_VERSION = "2023-06-01"
local DEFAULT_MODEL = "claude-opus-4-5"
-- Anthropic's Messages API requires max_tokens on every request (unlike
-- OpenAI/Ollama/Gemini, which default it server-side) -- this is that
-- required value's default, overridable per-request via `req.max_tokens`
-- the same way `req.model` overrides `DEFAULT_MODEL`.
local DEFAULT_MAX_TOKENS = 4096

---@param req? Ai.Request
---@return string|nil
local function api_key(req)
  return (req and req.api_key) or util.env_value("ANTHROPIC_API_KEY")
end

---@param req? Ai.Request
---@return boolean
function M.available(req)
  return util.executable("curl") and api_key(req) ~= nil
end

---@internal
---The user message's `content`: a plain string when there is nothing but
---the prompt (the shape Anthropic's own examples use, and one fewer level
---of nesting on the wire), a block array once an attachment is present.
---
---Attachments come first, prompt last. Anthropic documents that ordering as
---producing better results for document/image questions, and pdfport.nvim's
---hand-written backend already did it that way -- keeping it means the
---migrated backend sends a byte-identical request, not a similar one.
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
      type = att.kind,
      source = { type = "base64", media_type = att.media_type, data = att.data },
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
  return vim.json.encode({
    model = req.model or DEFAULT_MODEL,
    max_tokens = req.max_tokens or DEFAULT_MAX_TOKENS,
    system = req.system,
    stream = stream or nil,
    messages = { { role = "user", content = user_content(req) } },
  })
end

---@internal
---@param decoded table Anthropic Messages API response body
---@return Ai.Response
local function to_response(decoded)
  local text_parts = {}
  for _, block in ipairs(decoded.content or {}) do
    if block.type == "text" and type(block.text) == "string" then
      text_parts[#text_parts + 1] = block.text
    end
  end
  return {
    text = table.concat(text_parts, ""),
    usage = decoded.usage,
    stop_reason = decoded.stop_reason,
    provider = "claude",
  }
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
        "claude: ANTHROPIC_API_KEY not set",
        { env_var = "ANTHROPIC_API_KEY" }
      )
    )
    return
  end

  local rejected = attachments.unsupported("claude", M.capabilities, req.attachments)
  if rejected then
    cb(false, rejected)
    return
  end

  local timeout_ms = req.timeout_ms or 60000
  local prepare_err = transport.post_json(API_URL, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json", ["anthropic-version"] = ANTHROPIC_VERSION },
    secret_headers = { ["x-api-key"] = key },
    body = build_body(req, false),
    timeout_ms = timeout_ms,
  }, function(ok, data, obj)
    if not ok then
      cb(false, util.fetch_error("claude", data, obj, timeout_ms))
      return
    end
    -- A 200 whose body decodes to something that is not an object (a bare
    -- number, string or `null`) reaches this point as `ok`. Reading fields
    -- off it raises inside curl's own callback, which means `cb` is never
    -- called at all and the caller waits forever -- so it is reported as a
    -- response we could not understand, the way ollama.lua/loomai.lua
    -- already do.
    if type(data) ~= "table" then
      cb(false, lib_error.new("invalid_response", "claude: invalid response body", data))
      return
    end
    data = util.denil(data)
    if data.type == "error" then
      cb(
        false,
        lib_error.new(
          "api_error",
          "claude API error: " .. tostring(data.error and data.error.message),
          data.error
        )
      )
      return
    end
    cb(true, to_response(data))
  end)
  if prepare_err then
    cb(false, lib_error.new("network_error", "claude: " .. prepare_err))
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
          "claude: ANTHROPIC_API_KEY not set",
          { env_var = "ANTHROPIC_API_KEY" }
        )
      )
    end
    return nil
  end

  local rejected = attachments.unsupported("claude", M.capabilities, req.attachments)
  if rejected then
    if handlers.on_error then
      handlers.on_error(rejected)
    end
    return nil
  end

  local timeout_ms = req.timeout_ms or 60000
  local text_parts = {}
  local usage, stop_reason
  -- Lines that are not `data: ...` at all -- see ai.providers.sse's module
  -- doc for why (a real auth/validation failure comes back as a plain,
  -- pretty-printed JSON body, not an SSE event, and curl still exits 0).
  local non_data_lines = {}
  -- Set once an error is reported mid-stream so `on_done` below doesn't
  -- also fire with an empty-but-"successful" response afterwards.
  local failed = false

  local process, prepare_err = transport.stream_json(API_URL, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json", ["anthropic-version"] = ANTHROPIC_VERSION },
    secret_headers = { ["x-api-key"] = key },
    body = build_body(req, true),
    timeout_ms = timeout_ms,
  }, {
    on_chunk = function(line)
      -- Anthropic's SSE carries both `event: <type>` and `data: {...}` lines
      -- per event; only the payload line is needed, `decoded.type` already
      -- says what kind of event it is.
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
      if
        decoded.type == "content_block_delta"
        and decoded.delta
        and decoded.delta.type == "text_delta"
      then
        local delta_text = decoded.delta.text or ""
        text_parts[#text_parts + 1] = delta_text
        if handlers.on_chunk then
          handlers.on_chunk(delta_text)
        end
      elseif decoded.type == "message_delta" then
        usage = decoded.usage
        stop_reason = decoded.delta and decoded.delta.stop_reason
      elseif decoded.type == "error" then
        failed = true
        if handlers.on_error then
          handlers.on_error(
            lib_error.new(
              "api_error",
              "claude API error: " .. tostring(decoded.error and decoded.error.message),
              decoded.error
            )
          )
        end
      end
    end,
    on_done = function(obj)
      if failed then
        return
      end
      if obj.code ~= 0 then
        if handlers.on_error then
          handlers.on_error(util.curl_exit_error("claude", obj, timeout_ms))
        end
        return
      end
      if #text_parts == 0 then
        local decoded_err = sse.recover_error_body(non_data_lines)
        if decoded_err and decoded_err.type == "error" then
          if handlers.on_error then
            handlers.on_error(
              lib_error.new(
                "api_error",
                "claude API error: " .. tostring(decoded_err.error and decoded_err.error.message),
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
          usage = usage,
          stop_reason = stop_reason,
          provider = "claude",
        })
      end
    end,
    -- `curl.fetch_stream`'s own `on_error` is `lib.nvim.net.curl`'s API
    -- (a plain string, "the process itself could not be read from" -- see
    -- `Lib.Net.Curl.StreamHandlers`'s doc comment), not `Ai.StreamHandlers`'s
    -- -- it must be wrapped into the same `LibErrorValue` shape, not passed
    -- through raw.
    --
    -- This is a transport-level failure (e.g. a stdout read error), reported
    -- independently of the process exit callback -- `on_done` can still fire
    -- afterwards for the same request, so `failed` has to be set here too,
    -- the same as the content-level `decoded.type == "error"` branch above,
    -- or a subsequent `on_done` with `obj.code == 0` would call
    -- `handlers.on_done` right after this already reported the request as
    -- failed.
    on_error = function(err)
      failed = true
      if handlers.on_error then
        handlers.on_error(lib_error.new("network_error", err))
      end
    end,
  })

  -- A body that could not be written out never reached curl, so no handler
  -- above will ever fire for it -- report it here or it is lost silently.
  if prepare_err and handlers.on_error then
    handlers.on_error(lib_error.new("network_error", "claude: " .. prepare_err))
  end
  return process
end

return M
