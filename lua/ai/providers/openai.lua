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
  capabilities = {
    streaming = true,
    vision = true,
    documents = false,
    web = false,
    temperature = true,
  },
}

local DEFAULT_BASE_URL = "https://api.openai.com"
local DEFAULT_MODEL = "gpt-4o"
M.default_model = DEFAULT_MODEL

--- Hosts that may be reached over plain `http`: a server on this machine (LM Studio, vLLM, llama.cpp).
--- Anything else must be `https`, because a key and the prompt travel with the request.
---@type table<string, true>
local LOOPBACK = { ["localhost"] = true, ["127.0.0.1"] = true, ["[::1]"] = true }

---@internal
---The base URL of this request: `req.host`, else `AI_OPENAI_BASE_URL`, else the OpenAI API. Returns
---whether it is a custom (non-OpenAI) endpoint, or an error for a URL that must not be used.
---@param req? Ai.Request
---@return string|nil base
---@return boolean custom
---@return string|nil err
local function base_url(req)
  local raw = (req and type(req.host) == "string" and req.host ~= "") and req.host
    or util.env_value("AI_OPENAI_BASE_URL", DEFAULT_BASE_URL)
  local base = raw:gsub("/+$", "")
  if base == DEFAULT_BASE_URL then
    return base, false, nil
  end
  local scheme, host = base:match("^(%a[%w+.-]*)://([^/:]+)")
  if not scheme then
    return nil, true, ("openai: base URL %q is not an http(s) URL"):format(raw)
  end
  scheme = scheme:lower()
  if scheme ~= "https" and not (scheme == "http" and LOOPBACK[host:lower()]) then
    return nil,
      true,
      ("openai: base URL %q must use https (plain http only for localhost)"):format(raw)
  end
  return base, true, nil
end

---@internal
---The Chat Completions endpoint below `base`: a base that already ends in `/v1` (LM Studio's own
---spelling, `http://localhost:1234/v1`) gets `/chat/completions`, any other `/v1/chat/completions`.
---@param base string
---@return string
local function endpoint(base)
  if base:match("/v1$") then
    return base .. "/chat/completions"
  end
  return base .. "/v1/chat/completions"
end

---The key for this request. For the OpenAI API: `req.api_key`, else `OPENAI_API_KEY` (or a key profile).
---For a custom endpoint the OpenAI key is NEVER sent -- a key meant for api.openai.com must not travel to
---another host -- only `req.api_key` or `AI_OPENAI_COMPAT_API_KEY`; none at all is fine for a local server.
---@param req? Ai.Request
---@param custom boolean
---@return string|nil
local function api_key(req, custom)
  if req and req.api_key then
    return req.api_key
  end
  if custom then
    return util.env_value("AI_OPENAI_COMPAT_API_KEY", nil)
  end
  return require("ai.keys").get("openai", "OPENAI_API_KEY")
end

---@internal
---Whether "openai" was chosen on purpose, by the request or the config (not reached by `provider = "auto"`).
---@param req? Ai.Request
---@return boolean
local function chosen_explicitly(req)
  if req and req.provider == "openai" then
    return true
  end
  local ok, cfg = pcall(function()
    return require("ai").config()
  end)
  return ok and type(cfg) == "table" and cfg.provider == "openai"
end

---@param req? Ai.Request
---@return boolean
function M.available(req)
  if not util.executable("curl") then
    return false
  end
  local base, custom = base_url(req)
  if not base then
    return false
  end
  if custom then
    -- A local server often needs no key, but "auto" must not pick an endpoint nobody vouched for: without a
    -- key it counts only when openai was chosen explicitly.
    return api_key(req, true) ~= nil or chosen_explicitly(req)
  end
  -- A command key profile counts as available before it has run (ai.keys).
  return api_key(req, false) ~= nil or require("ai.keys").pending("openai")
end

---@internal
---Resolve URL and key for a request; `err` is a ready `LibErrorValue` when it must not go out.
---@param req Ai.Request
---@return string|nil url
---@return string|nil key
---@return LibErrorValue|nil err
local function target(req)
  local base, custom, url_err = base_url(req)
  if not base then
    return nil, nil, lib_error.new("invalid_request", url_err)
  end
  local key = api_key(req, custom)
  if not key and not custom then
    return nil, nil, util.missing_key_error("openai", "OPENAI_API_KEY")
  end
  return endpoint(base), key, nil
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
    temperature = req.temperature,
    stream = stream or nil,
  })
end

---@internal
---`data.error`/`decoded.error` should be a `{message = ...}` table (OpenAI's
---own error shape), but this provider also has to work against any
---OpenAI-Chat-Completions-compatible endpoint (a self-hosted gateway or
---proxy) that reports a failure differently, e.g. `{"error": true}` or
---`{"error": 1}`. Indexing `.message` off a non-table value there raises
---inside the transport callback -- which is wrapped in `vim.schedule` by
---`lib.nvim.net.curl.fetch_json`/`fetch_stream`, so the error is swallowed
---and `cb`/`handlers` never fires at all -- see loomai.lua's identical
---`error_message` helper for the same guard.
---@param err table|string|boolean|number
---@return string
local function error_message(err)
  if type(err) == "table" then
    if type(err.message) == "string" then
      return err.message
    end
    return "unknown error"
  end
  return tostring(err)
end

---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
function M.ask(req, cb)
  local url, key, target_err = target(req)
  if not url then
    cb(false, target_err)
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
  local prepare_err = transport.post_json(url, {
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
    -- A 200 whose body decodes to something that is not an object (a bare
    -- number, string or `null`) reaches this point as `ok`. Reading fields
    -- off it raises inside curl's own callback, which means `cb` is never
    -- called at all and the caller waits forever -- so it is reported as a
    -- response we could not understand, the way ollama.lua/loomai.lua
    -- already do.
    if type(data) ~= "table" then
      cb(false, lib_error.new("invalid_response", "openai: invalid response body", data))
      return
    end
    data = util.denil(data)
    if data.error then
      cb(
        false,
        lib_error.new("api_error", "openai API error: " .. error_message(data.error), data.error)
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
    cb(false, lib_error.new("network_error", "openai: " .. prepare_err))
  end
end

---@param req Ai.Request
---@param handlers Ai.StreamHandlers
---@return vim.SystemObj|nil
function M.stream(req, handlers)
  local url, key, target_err = target(req)
  if not url then
    if handlers.on_error then
      handlers.on_error(target_err)
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
  -- Set once an error is reported mid-stream so `on_done` below doesn't
  -- also fire with an empty-but-"successful" response afterwards.
  local failed = false

  local process, prepare_err = transport.stream_json(url, {
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
        failed = true
        if handlers.on_error then
          handlers.on_error(
            lib_error.new(
              "api_error",
              "openai API error: " .. error_message(decoded.error),
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
      if failed then
        return
      end
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
                "openai API error: " .. error_message(decoded_err.error),
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
    --
    -- Also see claude.lua: this transport-level failure fires independently
    -- of the process exit callback, so `failed` must be set here too or a
    -- subsequent `on_done` with `obj.code == 0` calls `handlers.on_done`
    -- right after this already reported the request as failed.
    on_error = function(err)
      failed = true
      if handlers.on_error then
        handlers.on_error(lib_error.new("network_error", err))
      end
    end,
  })

  -- See claude.lua: a body that never reached curl fires none of the
  -- handlers above, so it has to be reported here.
  if prepare_err and handlers.on_error then
    handlers.on_error(lib_error.new("network_error", "openai: " .. prepare_err))
  end
  return process
end

return M
