---@module 'ai.bindings.keymaps'
--- Default normal/visual-mode keymaps, declared through
--- `lib.nvim.bindings.keymap`'s registry (this collection's
--- Keymaps-als-Daten convention) so each one is individually
--- overridable/disableable via `config.keymaps[id]`, not just movable as a
--- block via `prefix`.

require("ai.@types")

local M = {}

---Install the default ai.nvim keymaps under `cfg.keymaps.prefix`.
---@param cfg Ai.Config
---@return Lib.Keymap.Registered[]
function M.setup(cfg)
  local prefix = cfg.keymaps.prefix or "<leader>a"
  local keymap = require("lib.nvim.bindings.keymap")
  local actions = require("ai.bindings.actions")

  ---@type Lib.Keymap.Spec
  local spec = {
    prefix = prefix,
    which_key = cfg.which_key.enable and { group = "ai.nvim" } or nil,
    order = { "ask", "quick", "explain" },
    actions = {
      ask = {
        default = prefix .. "a",
        binds = {
          {
            mode = "n",
            rhs = function()
              actions.ask_prompt("")
            end,
            desc = "Ask (prompt for text)",
          },
          {
            mode = "v",
            rhs = function()
              actions.ask_prompt("")
            end,
            desc = "Ask about the selection",
          },
        },
      },
      -- "Quick action" from the concept: current context + a typed task,
      -- streamed immediately.
      quick = {
        default = prefix .. "s",
        binds = {
          {
            mode = "n",
            rhs = function()
              actions.quick_action(cfg.context)
            end,
            desc = "Send context + a typed task, stream the answer",
          },
          {
            mode = "v",
            rhs = function()
              actions.quick_action(vim.tbl_extend("force", cfg.context, { selection = true }))
            end,
            desc = "Send selection + a typed task, stream the answer",
          },
        },
      },
      -- Second quick action: a small auto-dismissing badge, no chat panel.
      explain = {
        default = prefix .. "e",
        binds = {
          {
            mode = "n",
            rhs = function()
              actions.explain_badge(cfg.context)
            end,
            desc = "Explain current context (badge, no panel)",
          },
          {
            mode = "v",
            rhs = function()
              actions.explain_badge(vim.tbl_extend("force", cfg.context, { selection = true }))
            end,
            desc = "Explain selection (badge, no panel)",
          },
        },
      },
    },
  }

  return keymap.register("Ai", spec, cfg.keymaps)
end

return M
