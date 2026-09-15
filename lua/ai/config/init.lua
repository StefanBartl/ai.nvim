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

---Merge user options over the defaults and store the result. `user_opts` is
---typed loosely (`Ai.Config|table`, not a strict `Ai.Config`) because a
---caller legitimately passes a partial table (e.g. `{ ui = { panel_theme = "double" } }`)
----- `vim.tbl_deep_extend` fills in every field `Ai.Config`'s nested classes
---otherwise require.
---@param user_opts? Ai.Config|table
---@return Ai.Config
function M.setup(user_opts)
  if type(user_opts) ~= "table" then
    user_opts = {}
  end
  _active = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), user_opts)
  return _active
end

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
