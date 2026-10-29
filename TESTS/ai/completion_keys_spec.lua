-- Wiring of the completion insert-mode keys (`ai.bindings.keymaps.setup_completion`):
-- completion_spec.lua and ghost_spec.lua call `accept()`/`dismiss()` as functions,
-- this spec presses the real default keys (`DEFAULTS.completion.keymap`) in Insert
-- mode via nvim_feedkeys, so a key that is bound to the wrong action, not bound at
-- all, or unable to do its work from inside its mapping fails here. (The last one
-- was real: `accept` is an expr mapping, and an expr mapping runs under textlock,
-- so writing the suggestion from inside it failed with E565 and <Tab> inserted a
-- tab instead.)
--
-- The ghost suggestion is put up with the real `ai.ui.ghost.show()` (same as
-- ghost_spec.lua); no provider is needed because accept/dismiss never ask one.
---@diagnostic disable: need-check-nil
package.path = vim.fn.getcwd() .. "/TESTS/?.lua;" .. package.path
local S = require("docs_support")

-- The fallback of the accept key runs Neovim's own insert <Tab>, which loads `vim.snippet`; that module
-- creates its augroup at load, and `S.isolate_install()` removes groups a case created, leaving the
-- loaded module with a dead group id ("Invalid 'group'"). Load it before the first case.
local _ = vim.snippet

describe("ai completion keys", function()
  local keys = require("ai.config.DEFAULTS").completion.keymap
  local bufnr

  ---@param s string
  local function feed(s)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), "mx", false)
  end

  ---@return string
  local function line()
    return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  end

  ---@return integer changedtick the ghost was rendered at
  local function show_ghost()
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    require("ai.ui.ghost").show(bufnr, 0, 10, "1", tick)
    return tick
  end

  -- puts back Nvim's own insert <Tab> (snippet jump) that setup_completion replaces
  S.isolate_install()

  before_each(function()
    package.loaded["ai.completion"] = nil
    package.loaded["ai.ui.ghost"] = nil
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].expandtab = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = " })
    require("ai.bindings.keymaps").setup_completion({
      completion = { enable = true, keymap = keys },
    })
  end)

  after_each(function()
    require("ai.ui.ghost").clear()
    require("lib.nvim.bindings.keymap").forget("Ai")
    package.loaded["ai.completion"] = nil
    package.loaded["ai.ui.ghost"] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("binds the default accept/dismiss keys in Insert mode", function()
    assert.are.equal("<Tab>", keys.accept)
    assert.are.equal("<C-]>", keys.dismiss)
    assert.are.equal(
      "Ai: Accept the shown completion suggestion",
      vim.fn.maparg(keys.accept, "i", false, true).desc
    )
    assert.are.equal(
      "Ai: Dismiss the shown completion suggestion",
      vim.fn.maparg(keys.dismiss, "i", false, true).desc
    )
  end)

  it("<Tab> with a ghost shown inserts the suggestion, not a tab", function()
    show_ghost()
    feed("A" .. keys.accept .. "<Esc>")
    assert.are.equal("local x = 1", line())
    assert.is_nil(require("ai.ui.ghost").current())
  end)

  it("<Tab> without a ghost falls through to a plain <Tab>", function()
    feed("A" .. keys.accept .. "<Esc>")
    assert.are.equal("local x = \t", line())
  end)

  it("<Tab> with a stale ghost (buffer changed since) falls through to a plain <Tab>", function()
    show_ghost()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = " })
    feed("A" .. keys.accept .. "<Esc>")
    assert.are.equal("local x = \t", line())
  end)

  -- Without a suggestion the key must still do what it did before we took it. Neovim's own insert
  -- <Tab> jumps to the next snippet placeholder; a bare tab here was the bug.
  -- One feed for the whole sequence: with the `x` flag Insert mode ends when the typeahead does (as
  -- with :normal), which would move the cursor off the end of the line between two feeds.
  local expand = "<Cmd>lua vim.snippet.expand('${1:a} ${2:b}')<CR>"

  -- A bare tab in the text is what the old fallback produced; the jump leaves the snippet text alone.
  --
  -- The snippet session is stopped before the assertion: its autocmds would otherwise make
  -- `S.isolate_install()` delete the augroup of the loaded `vim.snippet` module after the case.
  it("<Tab> without a ghost still jumps to the next snippet placeholder", function()
    feed("A" .. expand .. keys.accept .. "<Esc>")
    local text = line()
    pcall(vim.snippet.stop)
    assert.are.equal("local x = a b", text)
  end)

  it("a second setup keeps that fallback instead of falling back to itself", function()
    require("ai.bindings.keymaps").setup_completion({
      completion = { enable = true, keymap = keys },
    })
    feed("A" .. expand .. keys.accept .. "<Esc>")
    local text = line()
    pcall(vim.snippet.stop)
    assert.are.equal("local x = a b", text)
  end)

  it("<Tab> without a ghost runs another plugin's global imap that was there first", function()
    require("lib.nvim.bindings.keymap").forget("Ai")
    vim.keymap.set("i", keys.accept, "FOREIGN", { desc = "foreign plugin" })
    package.loaded["ai.bindings.keymaps"] = nil
    require("ai.bindings.keymaps").setup_completion({
      completion = { enable = true, keymap = keys },
    })
    feed("A" .. keys.accept .. "<Esc>")
    assert.are.equal("local x = FOREIGN", line())
  end)

  it("<C-]> with a ghost shown dismisses it without touching the text", function()
    show_ghost()
    feed("A" .. keys.dismiss .. "<Esc>")
    assert.is_nil(require("ai.ui.ghost").current())
    assert.are.equal("local x = ", line())
  end)
end)
