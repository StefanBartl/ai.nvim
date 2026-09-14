---@module 'ai.providers.util'
--- Small helpers shared by the built-in provider backends. Kept out of
--- `ai.providers` (the registry) on purpose -- registration/resolution and
--- these implementation-detail helpers are different responsibilities.

local M = {}

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

---Format the "curl exited non-zero" error every streaming provider's
---`on_done` reports identically once `fetch_stream` hands it a raw process
---object (see that function's doc comment: it never checks `obj.code`
---itself).
---@param id string provider id, e.g. "claude"
---@param obj vim.SystemCompleted
---@return string
function M.curl_exit_error(id, obj)
  return string.format("%s: curl exited %d: %s", id, obj.code, obj.stderr or "")
end

return M
