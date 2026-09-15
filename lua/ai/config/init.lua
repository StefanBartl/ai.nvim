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
---Keys whose sub-table has an intentionally open-ended shape -- arbitrary
---user data, not a fixed set of options -- and must not be checked against
---`DEFAULTS` key-for-key: `model` is `table<provider_id, model_name>` (any
---provider id, including a custom one registered at runtime, is a valid
---key), `provider_order` is a plain array (its keys are indices, not option
---names).
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
    if not OPEN_SHAPE_KEYS[key] then
      if defaults[key] == nil then
        require("lib.nvim.notify")
          .create("[ai]")
          .warn(("unknown config key %q -- check for a typo"):format(path .. tostring(key)))
      elseif type(value) == "table" and type(defaults[key]) == "table" then
        warn_unknown_keys(value, defaults[key], path .. key .. ".")
      end
    end
  end
end

---Merge user options over the defaults and store the result. `user_opts` is
---typed loosely (`Ai.Config|table`, not a strict `Ai.Config`) because a
---caller legitimately passes a partial table (e.g. `{ ui = { panel_theme = "double" } }`)
----- `vim.tbl_deep_extend` fills in every field `Ai.Config`'s nested classes
---otherwise require. Unknown keys are warned about (see `warn_unknown_keys`)
---before the merge, not after -- by the time `vim.tbl_deep_extend` has run,
---a typo is indistinguishable from "the user meant to leave this at its
---default".
---@param user_opts? Ai.Config|table
---@return Ai.Config
function M.setup(user_opts)
  if type(user_opts) ~= "table" then
    user_opts = {}
  end
  warn_unknown_keys(user_opts, DEFAULTS, "")
  _active = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), user_opts)
  return _active
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
