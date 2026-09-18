---@module 'ai.bindings.keymaps'
--- Default normal/visual-mode keymaps, declared through
--- `lib.nvim.bindings.keymap`'s registry (this collection's
--- Keymaps-als-Daten convention) so each one is individually
--- overridable/disableable via `config.keymaps[id]`, not just movable as a
--- block via `prefix`.
---
--- Completion's insert-mode keys (`M.setup_completion`) are registered as a
--- second, separate `surface` on the same "Ai" plugin name -- a genuinely
--- different keymap set (insert-mode chords, no shared `prefix`) bound at
--- the same time, exactly the case `lib.nvim.bindings.keymap`'s own module
--- doc describes `opts.surface` for. Their effective `lhs` is already fully
--- resolved by `config.setup()`'s deep-merge over `DEFAULTS.completion.keymap`
--- by the time this runs, so `default` is set directly from `cfg` and no
--- second override table is passed to `register()`.

require("ai.@types")

local M = {}

---Install the default ai.nvim keymaps under `cfg.keymaps.prefix`.
---@param cfg Ai.Config
---@return Lib.Keymap.Registered[]
function M.setup(cfg)
  local prefix = cfg.keymaps.prefix or "<leader>a"
  local keymap = require("lib.nvim.bindings.keymap")
  local actions = require("ai.bindings.actions")

  -- The Visual-mode binds below read `'<`/`'>` directly rather than passing
  -- `context.selection` -- these actions target a buffer range to edit, not
  -- a context block to prefix a prompt with, so they need line numbers
  -- (`ai.context.assemble` only ever returns formatted text). Valid at this
  -- point because leaving Visual mode (which is how a Visual-mode keymap's
  -- Lua callback ever runs) is exactly what sets those marks.
  ---@return {line1: integer, line2: integer}
  local function visual_range()
    -- rewrite/append/prepend only ever operate on whole lines (there is no
    -- column-aware nvim_buf_set_text path here) -- for a linewise ("V")
    -- selection that is exactly what the user asked for, but a charwise
    -- ("v") or blockwise selection spanning only part of a line still
    -- replaces/inserts around the FULL line(s) it touches. Silent for that
    -- case would mean unrelated text on the same line (a trailing comment,
    -- a second statement) gets discarded without the user ever being told
    -- why -- warn instead of guessing at a narrower edit.
    if vim.fn.visualmode() ~= "V" then
      require("lib.nvim.notify").create("[ai]").warn(
        "rewrite/append/prepend act on whole lines -- the full line(s) your selection touches will be affected, not just the selected characters"
      )
    end
    return { line1 = vim.fn.getpos("'<")[2], line2 = vim.fn.getpos("'>")[2] }
  end

  ---@type Lib.Keymap.Spec
  local spec = {
    prefix = prefix,
    which_key = cfg.which_key.enable and { group = "ai.nvim" } or nil,
    order = { "ask", "quick", "explain", "rewrite", "append", "prepend" },
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
      -- Replace/insert code in place -- the gp.nvim-shaped gap: an answer
      -- that writes back into the buffer instead of a popup/panel.
      rewrite = {
        default = prefix .. "r",
        binds = {
          {
            mode = "n",
            rhs = function()
              actions.rewrite_prompt("")
            end,
            desc = "Rewrite current line with AI-generated code",
          },
          {
            mode = "v",
            rhs = function()
              actions.rewrite_prompt("", visual_range())
            end,
            desc = "Rewrite selection with AI-generated code",
          },
        },
      },
      -- `o`/`O` mnemonic: Vim's own "open line below/above", same relation
      -- append/prepend have to the target range here.
      append = {
        default = prefix .. "o",
        binds = {
          {
            mode = "n",
            rhs = function()
              actions.append_prompt("")
            end,
            desc = "Insert AI-generated code after current line",
          },
          {
            mode = "v",
            rhs = function()
              actions.append_prompt("", visual_range())
            end,
            desc = "Insert AI-generated code after selection",
          },
        },
      },
      prepend = {
        default = prefix .. "O",
        binds = {
          {
            mode = "n",
            rhs = function()
              actions.prepend_prompt("")
            end,
            desc = "Insert AI-generated code before current line",
          },
          {
            mode = "v",
            rhs = function()
              actions.prepend_prompt("", visual_range())
            end,
            desc = "Insert AI-generated code before selection",
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

---Install the completion insert-mode keymaps (trigger/accept/dismiss) as
---their own keymap surface, if `cfg.completion.enable` is true. `accept` is
---an `expr` mapping so it can fall through to that key's normal behavior
---when nothing is shown, and steps aside entirely while a completion-menu
---plugin's own popup is open (`pumvisible()`) -- it never fights that
---plugin's own key for menu navigation, though it cannot know whether that
---plugin *also* claims the same key when no popup is open; changing
---`cfg.completion.keymap.accept` away from the default resolves that case.
---@param cfg Ai.Config
---@return Lib.Keymap.Registered[]|nil
function M.setup_completion(cfg)
  if not cfg.completion or not cfg.completion.enable then
    return nil
  end

  local keymap = require("lib.nvim.bindings.keymap")
  local completion = require("ai.completion")
  local km = cfg.completion.keymap or {}
  -- A user sets `keymap.<action> = false` to drop just that one key; `or
  -- nil` normalizes that to the same "no default key" the registry itself
  -- expects (its own doc: "Absent = no key by default").
  local accept_key = km.accept or nil

  ---@type Lib.Keymap.Spec
  local spec = {
    which_key = false,
    order = { "trigger", "accept", "dismiss" },
    actions = {
      trigger = {
        default = km.trigger or nil,
        mode = "i",
        desc = "Request a completion suggestion at the cursor",
        rhs = function()
          completion.trigger()
        end,
      },
      accept = {
        default = accept_key,
        mode = "i",
        desc = "Accept the shown completion suggestion",
        opts = { expr = true, replace_keycodes = true },
        rhs = function()
          if accept_key and vim.fn.pumvisible() ~= 0 then
            return vim.keycode(accept_key)
          end
          if completion.accept() then
            return ""
          end
          return accept_key and vim.keycode(accept_key) or ""
        end,
      },
      dismiss = {
        default = km.dismiss or nil,
        mode = "i",
        desc = "Dismiss the shown completion suggestion",
        rhs = function()
          completion.dismiss()
        end,
      },
    },
  }

  -- `nil`, not `false`, for `user`: `false` there means "all off" (see the
  -- registry's own module doc), which would silently unbind every one of
  -- these regardless of `cfg.completion.enable` -- the `default` fields
  -- above already carry the fully-resolved (possibly user-overridden)
  -- value, so no separate override table is needed here at all.
  return keymap.register("Ai", spec, nil, { surface = "completion" })
end

return M
