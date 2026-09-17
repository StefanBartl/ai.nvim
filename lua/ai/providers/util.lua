---@module 'ai.providers.util'
--- Small helpers shared by the built-in provider backends. Kept out of
--- `ai.providers` (the registry) on purpose -- registration/resolution and
--- these implementation-detail helpers are different responsibilities.

local lib_error = require("lib.lua.error")

local M = {}

---curl's `CURLE_OPERATION_TIMEDOUT`. `ai.providers.transport` passes curl its
---own `--max-time` precisely so that a request that runs long ends *here*,
---with a documented, platform-independent exit code, rather than as a
---`vim.system`-killed process whose code says nothing about why it died.
---@type integer
M.CURL_EXIT_TIMEOUT = 28

---@type table<string, boolean>
local executable_cache = {}

---Cached `vim.fn.executable(name) == 1`. `available()` runs on every
---`"auto"` resolution (see `Ai.Provider`'s own doc comment) -- a
---*successful* probe stops at the first PATH hit and is cheap, but a
---*failing* one walks every PATH entry against every PATHEXT extension
---uncached, and would otherwise re-run that full walk on every single
---`:Ai ask`/`:Ai stream` call for as long as the tool stays missing. A
---binary appearing/disappearing from PATH mid-session (without a Neovim
---restart) is not a case this needs to track.
---@param name string
---@return boolean
function M.executable(name)
  local cached = executable_cache[name]
  if cached == nil then
    cached = vim.fn.executable(name) == 1
    executable_cache[name] = cached
  end
  return cached
end

---Read an environment variable, trimmed of leading/trailing whitespace
---(including a trailing newline, a common shape for a value sourced from a
---file or `.env` loader via e.g. `export KEY=$(cat key.txt)`). Returns
---`fallback` (default `nil`) when the variable is unset or empty/whitespace
---after trimming.
---@overload fun(name: string): string|nil
---@overload fun(name: string, fallback: string): string
---@param name string
---@param fallback string|nil
---@return string|nil
function M.env_value(name, fallback)
  local value = vim.env[name]
  if type(value) ~= "string" then
    return fallback
  end
  local trimmed = value:match("^%s*(.-)%s*$")
  return (trimmed ~= "") and trimmed or fallback
end

---Build the "curl exited non-zero" error every streaming provider's
---`on_done` reports identically once `fetch_stream` hands it a raw process
---object (see that function's doc comment: it never checks `obj.code`
---itself).
---@param id string provider id, e.g. "claude"
---@param obj vim.SystemCompleted
---@param timeout_ms? integer the request's own timeout, for the message when `obj.code` is `CURL_EXIT_TIMEOUT`
---@return LibErrorValue
function M.curl_exit_error(id, obj, timeout_ms)
  if obj.code == M.CURL_EXIT_TIMEOUT then
    return lib_error.new(
      "timeout",
      timeout_ms and string.format("%s: request timed out after %d ms", id, timeout_ms)
        or (id .. ": request timed out"),
      obj
    )
  end
  return lib_error.new(
    "network_error",
    string.format("%s: curl exited %d: %s", id, obj.code, obj.stderr or ""),
    obj
  )
end

---Build the error for a failed `ai.providers.transport.post_json`. Same
---timeout/network split as `curl_exit_error`, but for the buffered tier,
---where `lib.nvim.net.curl` has already reduced the failure to a message
---string and the exit code survives only on the raw process object.
---@param id string provider id, e.g. "claude"
---@param err any `fetch_json`'s error value (a string in practice)
---@param obj vim.SystemCompleted|nil
---@param timeout_ms? integer
---@return LibErrorValue
function M.fetch_error(id, err, obj, timeout_ms)
  if type(obj) == "table" and obj.code == M.CURL_EXIT_TIMEOUT then
    return M.curl_exit_error(id, obj, timeout_ms)
  end
  return lib_error.new("network_error", id .. ": " .. tostring(err), err)
end

---Recursively replace `vim.NIL` with Lua `nil` in a decoded JSON value, in
---place. `vim.json.decode` produces `vim.NIL` (a userdata sentinel) for a
---JSON `null`, never a plain Lua `nil` -- indexing into it later (e.g.
---`decoded.delta.stop_reason` when `decoded.delta` itself is JSON `null`)
---throws "attempt to index a userdata value" instead of behaving like an
---absent field the way every provider's `type(x) == "table"`/`x and
---x.field` guards already assume. Every provider calls this once right
---after decoding, rather than teaching each field access about the second
---flavor of "missing" JSON can produce.
---@param value any
---@return any value the same table, with every `vim.NIL` replaced by `nil`
function M.denil(value)
  if value == vim.NIL then
    return nil
  end
  if type(value) ~= "table" then
    return value
  end
  for k, v in pairs(value) do
    if v == vim.NIL then
      value[k] = nil
    elseif type(v) == "table" then
      M.denil(v)
    end
  end
  return value
end

return M
