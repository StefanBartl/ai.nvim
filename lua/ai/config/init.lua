---@module 'ai.config'
--- Runtime configuration store for ai.nvim.
---
--- Merges user options over the immutable DEFAULTS and exposes the active
--- config via `get()`.

require("ai.@types")

local DEFAULTS = require("ai.config.DEFAULTS")

local M = {}

---@type Ai.Config|nil
local _active = nil

---@internal
---Full dotted paths whose sub-table has an intentionally open-ended shape --
---arbitrary user data, not a fixed set of options -- and must not be checked
---against `DEFAULTS` key-for-key: top-level `model` is
---`table<provider_id, model_name>` (any provider id, including a custom one
---registered at runtime, is a valid key), `provider_order` is a plain array
---(its keys are indices, not option names). Keyed by full path rather than
---bare key name so a *different*, fixed-shape option that happens to share
---one of these names at another nesting level (e.g. `completion.model`, a
---single string) still gets checked normally.
---@type table<string, true>
local OPEN_SHAPE_KEYS = { model = true, provider_order = true }

---@internal
---Warn about every key in `opts` that `defaults` doesn't know about, at any
---nesting level -- a typo in a nested option (`{ ui = { panel_them = "x" } }`)
---would otherwise vanish silently into `vim.tbl_deep_extend`'s merge instead
---of surfacing anywhere. Warns rather than raising: an unknown/invalid value
---degrades to its default (the merge already does that), it does not abort
---`setup()`.
---@param opts table
---@param defaults table
---@param path string dotted prefix for the warning, e.g. `"ui."`
---@return nil
local function warn_unknown_keys(opts, defaults, path)
  for key, value in pairs(opts) do
    local full_key = path .. tostring(key)
    if not OPEN_SHAPE_KEYS[full_key] then
      if defaults[key] == nil then
        require("lib.nvim.notify")
          .create("[ai]")
          .warn(("unknown config key %q -- check for a typo"):format(full_key))
      elseif type(value) == "table" and type(defaults[key]) == "table" then
        warn_unknown_keys(value, defaults[key], path .. key .. ".")
      end
    end
  end
end

---@internal
---Expected shape for the config values that are both cheap to check and
---known to break something downstream when wrong-typed -- not every field
---`Ai.Config` has, deliberately: an open-ended one (`model`) has no fixed
---shape to check, and most string fields (`provider`, `ui.panel_theme`, ...)
---already fail their own consumer gracefully (an unknown provider id, an
---unrecognized `ui.kit` theme) without ever reaching an unguarded API call.
---These are the ones that don't -- `provider_order` reaches a bare
---`ipairs(order)` in `ai.providers.resolve` and `table.concat` in
---`health.lua`, and `completion.trigger` silently means "never auto-trigger"
---for any value that isn't exactly `"auto"` instead of surfacing the typo.
---A plain Lua type name checks `type(value)`; a list of strings is a closed
---enum.
---@type table<string, string|string[]>
local VALUE_SCHEMA = {
  provider_order = "string[]",
  timeout_ms = "number",
  log_level = "number",
  ["ui.progress_style"] = { "auto", "notify", "statusline", "fidget", "float" },
  ["ui.badge_timeout_ms"] = "number",
  ["completion.trigger"] = { "manual", "auto" },
  ["completion.idle_ms"] = "number",
  ["completion.max_context_lines"] = "number",
}

---@internal
---@param kind string|string[]
---@param value unknown
---@return boolean
local function value_ok(kind, value)
  if type(kind) == "table" then
    for _, allowed in ipairs(kind) do
      if value == allowed then
        return true
      end
    end
    return false
  end
  if kind == "string[]" then
    if type(value) ~= "table" then
      return false
    end
    for _, item in ipairs(value) do
      if type(item) ~= "string" then
        return false
      end
    end
    return true
  end
  return type(value) == kind
end

---@internal
---Drop every value in `opts` that fails its `VALUE_SCHEMA` check, in place,
---so the following merge falls back to `DEFAULTS`'s own value for that key
---instead of carrying the invalid one through -- ERR-22 requires a bad
---single value to degrade to its default, not abort `setup()` or reach a
---consumer unchecked. Every drop is recorded into `issues` for `:checkhealth`
---to surface (see `M.issues()`); silently degrading with no visible trace
---would just move the same problem from "crashes" to "quietly ignored".
---@param opts table
---@param path string dotted prefix, e.g. `"completion."`
---@param issues string[]
---@return nil
local function sanitize_values(opts, path, issues)
  for key, value in pairs(opts) do
    local full_key = path .. tostring(key)
    local kind = VALUE_SCHEMA[full_key]
    if kind then
      if not value_ok(kind, value) then
        issues[#issues + 1] = ("%s: invalid value (%s) -- using the default instead"):format(
          full_key,
          vim.inspect(value)
        )
        opts[key] = nil
      end
    elseif type(value) == "table" then
      sanitize_values(value, full_key .. ".", issues)
    end
  end
end

---@type string[]
local _issues = {}

---Merge user options over the defaults and store the result. `user_opts` is
---typed loosely (`Ai.Config|table`, not a strict `Ai.Config`) because a
---caller legitimately passes a partial table (e.g. `{ ui = { panel_theme = "double" } }`)
----- `vim.tbl_deep_extend` fills in every field `Ai.Config`'s nested classes
---otherwise require. Unknown keys are warned about (see `warn_unknown_keys`)
---and invalid-typed known values are dropped (see `sanitize_values`) before
---the merge, not after -- by the time `vim.tbl_deep_extend` has run, either
---kind of mistake is indistinguishable from "the user meant to leave this at
---its default".
---@param user_opts? Ai.Config|table
---@return Ai.Config
function M.setup(user_opts)
  if type(user_opts) ~= "table" then
    user_opts = {}
  end
  warn_unknown_keys(user_opts, DEFAULTS, "")
  _issues = {}
  sanitize_values(user_opts, "", _issues)
  _active = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), user_opts)
  return _active
end

---Config values from the last `setup()` call that failed their `VALUE_SCHEMA`
---check and were dropped to their default instead (see `sanitize_values`) --
---empty when nothing was dropped. This is the `:checkhealth` surface ERR-22
---requires: a degraded value must stay visible, not just stay non-fatal.
---@return string[]
function M.issues()
  return _issues
end

---Returns the active config table **by reference**, not a copy -- callers
---may read it freely but must not mutate it in place (`M.set_provider`
---below is the one sanctioned exception, and exists precisely so other
---call sites don't need to reach for direct mutation themselves).
---@return Ai.Config
function M.get()
  if _active == nil then
    _active = vim.deepcopy(DEFAULTS)
  end
  return _active
end

---Switch the active provider id directly, without a full `setup()` merge --
---the one runtime write this module needs to support (`:Ai provider
---<name>`). `id` is trusted here: the composer route already constrains it
---to a known provider id via its own `enum`, so no validation happens on
---this side too.
---@param id string
---@return nil
function M.set_provider(id)
  M.get().provider = id
end

return M
