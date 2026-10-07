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
local OPEN_SHAPE_KEYS =
  { model = true, provider_order = true, ["policy.allowed"] = true, keys = true }

---Tables in which an unknown key must not be ignored, each with what it
---refuses (`effect`) and the table that replaces it (`replace`) when one is
---found: the same reasoning as `FAIL_CLOSED` below, for a key instead of a
---value. `policy = { alowed = { "claude" } }` is a rule that was meant and is
---not in force, and ignoring it leaves the default -- no restriction -- in
---place with nothing but a warning; `bulk = { max_sesion_chars = 100 }` is a
---cost cap that was meant and is not in force. `close_unknown_keys` reports
---and replaces; `warn_unknown_keys` leaves these keys to it.
---@type table<string, { effect: string, replace: fun(): table }>
local CLOSED_TABLES = {
  policy = {
    effect = "every provider is refused",
    replace = function()
      return { allowed = { M.INVALID_POLICY } }
    end,
  },
  bulk = {
    effect = "every bulk request is refused",
    replace = function()
      return { max_session_chars = 0 }
    end,
  },
}

---The two spellings of the top-level option that holds the allow-list: its name
---and its plural, which is the other thing it gets called. `policies` is three
---edits from `policy`, so it needs to be a spelling of its own.
---@type string[]
local POLICY_SPELLINGS = { "policy", "policies" }

---How many edits away from a `POLICY_SPELLINGS` entry an unknown top-level key
---still counts as that option, misspelt (`polcy`, `plicy`, `Policy`).
local POLICY_TYPO_EDITS = 2

---The longest key that can be within `POLICY_TYPO_EDITS` of a spelling; what is
---longer is not compared at all.
local POLICY_KEY_MAX = 10

---@internal
---Levenshtein distance (insert, delete, substitute) of two short strings.
---@param a string
---@param b string
---@return integer
local function edit_distance(a, b)
  local prev, cur = {}, {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    cur[0] = i
    for j = 1, #b do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev, cur = cur, prev
  end
  return prev[#b]
end

---@internal
---Whether `key`, a top-level key of the options that `DEFAULTS` does not have, is
---the allow-list's `policy` spelt wrong. Unlike any other unknown key that is not
---a typo to shrug at: ignoring it leaves the default, which is no restriction, in
---place (see `close_misspelt_policy`). Only these two are compared -- an unknown
---key near some other option stays a warning.
---@param key any
---@return boolean
local function misspelt_policy(key)
  if type(key) ~= "string" or #key > POLICY_KEY_MAX or DEFAULTS[key] ~= nil then
    return false
  end
  local lowered = key:lower()
  for _, spelling in ipairs(POLICY_SPELLINGS) do
    if edit_distance(lowered, spelling) <= POLICY_TYPO_EDITS then
      return true
    end
  end
  return false
end

---@internal
---Warn about every key in `opts` that `defaults` doesn't know about, at any
---nesting level -- a typo in a nested option (`{ ui = { panel_them = "x" } }`)
---would otherwise vanish silently into `vim.tbl_deep_extend`'s merge instead
---of surfacing anywhere. Warns rather than raising: an unknown/invalid value
---degrades to its default (the merge already does that), it does not abort
---`setup()`. A misspelt `policy` is left to `close_misspelt_policy`, which
---says more than that.
---@param opts table
---@param defaults table
---@param path string dotted prefix for the warning, e.g. `"ui."`
---@return nil
local function warn_unknown_keys(opts, defaults, path)
  local closed = CLOSED_TABLES[path:sub(1, -2)] ~= nil
  for key, value in pairs(opts) do
    local full_key = path .. tostring(key)
    if not OPEN_SHAPE_KEYS[full_key] then
      if defaults[key] == nil then
        if not closed and not (path == "" and misspelt_policy(key)) then
          require("lib.nvim.notify")
            .create("[ai]")
            .warn(("unknown config key %q -- check for a typo"):format(full_key))
        end
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
  policy = "table",
  ["policy.allowed"] = "string[]",
  timeout_ms = "number",
  bulk = "table",
  ["bulk.max_session_chars"] = "number>=0|false",
  log_level = "number",
  ["ui.progress_style"] = { "auto", "notify", "statusline", "fidget", "float" },
  ["ui.badge_timeout_ms"] = "number",
  ["completion.trigger"] = { "manual", "auto" },
  ["completion.idle_ms"] = "number",
  ["completion.max_context_lines"] = "number",
}

---What `policy.allowed` holds when its configured value is malformed: a
---non-empty list that matches no provider id, so every provider is refused
---(`ai.policy` reads it like any other list, `describe()` shows it).
---@type string
M.INVALID_ALLOWED = "<invalid policy.allowed>"

---What `policy.allowed` holds when `policy` has a key ai.nvim does not know --
---the same kind of marker, a different cause (see `CLOSED_TABLES`).
---@type string
M.INVALID_POLICY = "<unknown policy key>"

---What `policy.allowed` holds when the options have a top-level key that is
---`policy` spelt wrong (see `close_misspelt_policy`).
---@type string
M.MISSPELT_POLICY = "<misspelt policy key>"

---@internal
---Values that must not degrade to their default, because the default is the
---permissive state: an empty `policy.allowed` means "no restriction", so a
---malformed one dropped to `{}` would switch the allow-list off without a
---word; `bulk.max_session_chars = false` means "no cost cap", so one that is
---`"500000"` or `-1` must not become that. These are replaced by a value that
---refuses instead (ERR-22's "degrade to the default" is for values where the
---default is harmless), and `setup()` says so right away rather than leaving
---it to `:checkhealth`. `effect` is what the refusal is.
---@type table<string, { effect: string, replace: fun(): any }>
local FAIL_CLOSED = {
  ["policy.allowed"] = {
    effect = "every provider is refused",
    replace = function()
      return { M.INVALID_ALLOWED }
    end,
  },
  policy = {
    effect = "every provider is refused",
    replace = function()
      return { allowed = { M.INVALID_ALLOWED } }
    end,
  },
  bulk = {
    effect = "every bulk request is refused",
    replace = function()
      return { max_session_chars = 0 }
    end,
  },
  ["bulk.max_session_chars"] = {
    effect = "every bulk request is refused",
    replace = function()
      return 0
    end,
  },
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
    -- A list, not a map: `{ claude = true }` has no `ipairs` entries and would
    -- otherwise pass as an empty list.
    if type(value) ~= "table" or not vim.islist(value) then
      return false
    end
    for _, item in ipairs(value) do
      if type(item) ~= "string" then
        return false
      end
    end
    return true
  end
  if kind == "number>=0|false" then
    -- NaN fails `>= 0`; a negative number is no cap either.
    return value == false or (type(value) == "number" and value >= 0)
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
---The `FAIL_CLOSED` keys are the exception: they are replaced, not dropped.
---@param opts table
---@param path string dotted prefix, e.g. `"completion."`
---@param issues string[]
---@return nil
local function sanitize_values(opts, path, issues)
  for key, value in pairs(opts) do
    local full_key = path .. tostring(key)
    local kind = VALUE_SCHEMA[full_key]
    if kind and not value_ok(kind, value) then
      local closed = FAIL_CLOSED[full_key]
      if closed then
        local issue = ("%s: invalid value (%s) -- %s until it is fixed"):format(
          full_key,
          vim.inspect(value),
          closed.effect
        )
        issues[#issues + 1] = issue
        require("lib.nvim.notify").create("[ai]").warn(issue)
        opts[key] = closed.replace()
      else
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

---@internal
---Replace every `CLOSED_TABLES` table of `opts` that holds a key `DEFAULTS` does
---not have by the table that refuses, and record that for `:checkhealth` and
---tell the user right away, like a `FAIL_CLOSED` value. Runs after
---`sanitize_values`, so a malformed `policy.allowed` next to the unknown key is
---still reported on its own.
---@param opts table
---@param issues string[]
---@return nil
local function close_unknown_keys(opts, issues)
  for name, closed in pairs(CLOSED_TABLES) do
    local value = opts[name]
    local unknown = {}
    for key in pairs(type(value) == "table" and value or {}) do
      if DEFAULTS[name][key] == nil then
        unknown[#unknown + 1] = name .. "." .. tostring(key)
      end
    end
    if #unknown > 0 then
      table.sort(unknown)
      local known = vim.tbl_keys(DEFAULTS[name])
      table.sort(known)
      local issue = ("%s: unknown key (%s has: %s) -- %s until it is fixed"):format(
        table.concat(unknown, ", "),
        name,
        table.concat(known, ", "),
        closed.effect
      )
      issues[#issues + 1] = issue
      require("lib.nvim.notify").create("[ai]").warn(issue)
      opts[name] = closed.replace()
    end
  end
end

---@internal
---A top-level key of `opts` that is `policy` spelt wrong (`polcy`, `plicy`,
---`Policy`, `policies`) is a rule that was meant and is not in force: the real
---`policy` stays at its default, which is no restriction. So it fails closed like a
---malformed `policy` does -- every provider is refused -- and is reported for
---`:checkhealth` and warned about right away. Only this key: an unknown key
---anywhere else, near some other option or near none, stays a warning (a typo in
---`ui` must not refuse every provider). The misspelt key is dropped from `opts`,
---and `policy` is replaced even when a valid one stands next to it.
---@param opts table
---@param issues string[]
---@return nil
local function close_misspelt_policy(opts, issues)
  local misspelt = {}
  for key in pairs(opts) do
    if misspelt_policy(key) then
      misspelt[#misspelt + 1] = key
    end
  end
  if #misspelt == 0 then
    return
  end
  table.sort(misspelt)
  local quoted = {}
  for i, key in ipairs(misspelt) do
    quoted[i] = ("%q"):format(key)
    opts[key] = nil
  end
  local issue = ("%s: looks like a misspelt `policy` -- every provider is refused until it is fixed"):format(
    table.concat(quoted, ", ")
  )
  issues[#issues + 1] = issue
  require("lib.nvim.notify").create("[ai]").warn(issue)
  opts.policy = { allowed = { M.MISSPELT_POLICY } }
end

---@type string[]
local _issues = {}

local switch_group = require("lib.nvim.normalize").normalize_switch_group

---@internal
---A feature group (`keymaps`, `usercmds`, ...) is a table with an `enable`
---switch, but `keymaps = false` is the natural way to say "none of it". Turn a
---boolean written in place of such a table into the table form, so every reader
---can index `cfg.<group>.enable` without a type check: `false` -> `{ enable =
---false }`, `true` -> `{}` (the defaults). The switch itself stays the one place
---that decides.
---@param opts table the caller's copy, changed in place
local function normalize_switch_groups(opts)
  for key, default in pairs(DEFAULTS) do
    if type(default) == "table" and type(default.enable) == "boolean" then
      if type(opts[key]) == "boolean" then
        opts[key] = switch_group(opts[key])
      end
    end
  end
end

---Merge user options over the defaults and store the result. `user_opts` is
---typed loosely (`Ai.Config|table`, not a strict `Ai.Config`) because a
---caller legitimately passes a partial table (e.g. `{ ui = { panel_theme = "double" } }`)
----- `vim.tbl_deep_extend` fills in every field `Ai.Config`'s nested classes
---otherwise require. Unknown keys are warned about (see `warn_unknown_keys`)
---and invalid-typed known values are dropped (see `sanitize_values`) before
---the merge, not after -- by the time `vim.tbl_deep_extend` has run, either
---kind of mistake is indistinguishable from "the user meant to leave this at
---its default". Where the default is the permissive state, the mistake refuses
---instead (`FAIL_CLOSED`, an unknown key under `policy` or `bulk`, see
---`close_unknown_keys`, and a top-level key that is `policy` misspelt, see
---`close_misspelt_policy`).
---@param user_opts? Ai.Config|table
---@return Ai.Config
function M.setup(user_opts)
  -- A copy: the checks below replace values in place, and the caller's table
  -- (a lazy.nvim `opts`, say) must still say what was written when `setup()`
  -- runs again.
  user_opts = type(user_opts) == "table" and vim.deepcopy(user_opts) or {}
  normalize_switch_groups(user_opts)
  warn_unknown_keys(user_opts, DEFAULTS, "")
  _issues = {}
  sanitize_values(user_opts, "", _issues)
  close_unknown_keys(user_opts, _issues)
  close_misspelt_policy(user_opts, _issues)
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
---to a known provider id or `auto` via its own `enum`, so no validation
---happens on this side too.
---@param id string
---@return nil
function M.set_provider(id)
  M.get().provider = id
end

return M
