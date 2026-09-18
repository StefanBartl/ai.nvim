-- ai.completion's request lifecycle (M.trigger()'s stale-response guards and
-- successful ghost.show() call) and M.accept()'s text-insertion logic --
-- neither is covered by completion_auto_trigger_spec.lua, which only
-- exercises the debounce/autocmd wiring around auto-trigger mode (its own
-- `ask` stub always calls back `false`, so the success path never runs).
--
-- Only `require("ai")` is stubbed (`ai.completion.context`/`ai.ui.ghost` are
-- both pure vim.api, same reasoning completion_auto_trigger_spec.lua's
-- module doc gives), and `ai.completion` itself is re-required fresh each
-- test so `generation` always starts at 0.
---@diagnostic disable: need-check-nil
describe("ai.completion", function()
  local bufnr

  before_each(function()
    package.loaded["ai.completion"] = nil
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    package.loaded["ai"] = nil
    package.loaded["ai.completion"] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe("trigger", function()
    it("is a no-op when completion is disabled", function()
      local ask_called = false
      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = false } }
        end,
        ask = function()
          ask_called = true
        end,
      }
      require("ai.completion").trigger()
      assert.is_false(ask_called)
    end)

    it("shows the parsed suggestion via ai.ui.ghost on a successful response", function()
      -- "local x = Z", not "local x = " -- normal-mode `nvim_win_set_cursor`
      -- clamps to the last real character's column, so a trailing-space line
      -- would silently move the cursor one column short of 10 and this test
      -- would be exercising the wrong column.
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = Z" })
      vim.api.nvim_win_set_cursor(0, { 1, 10 })

      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = true, max_context_lines = 10 } }
        end,
        ask = function(_, cb)
          cb(true, { text = "1" })
        end,
      }
      require("ai.completion").trigger()

      local ghost = require("ai.ui.ghost")
      local shown = ghost.current()
      assert.are.equal(bufnr, shown.bufnr)
      assert.are.equal(0, shown.row) -- row - 1, 0-indexed for the extmark API
      assert.are.equal(10, shown.col)
      assert.are.equal("1", shown.text)
      ghost.clear()
    end)

    it("strips a markdown fence off the response before showing it", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = true, max_context_lines = 10 } }
        end,
        ask = function(_, cb)
          cb(true, { text = "```lua\nprint(1)\n```" })
        end,
      }
      require("ai.completion").trigger()

      local ghost = require("ai.ui.ghost")
      assert.are.equal("print(1)", ghost.current().text)
      ghost.clear()
    end)

    it("shows nothing when the response text is empty after parsing", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = true, max_context_lines = 10 } }
        end,
        ask = function(_, cb)
          cb(true, { text = "" })
        end,
      }
      require("ai.completion").trigger()
      assert.is_nil(require("ai.ui.ghost").current())
    end)

    it("shows nothing on a failed response", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = true, max_context_lines = 10 } }
        end,
        ask = function(_, cb)
          cb(false, "stubbed error")
        end,
      }
      require("ai.completion").trigger()
      assert.is_nil(require("ai.ui.ghost").current())
    end)

    it("a superseded (stale) response is discarded, only the newest generation renders", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local pending = {}
      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = true, max_context_lines = 10 } }
        end,
        -- Defers the callback instead of calling it synchronously, so a
        -- second trigger() can bump `generation` before the first's
        -- response arrives -- the real ordering an in-flight request racing
        -- a newer keystroke produces.
        ask = function(_, cb)
          pending[#pending + 1] = cb
        end,
      }
      local completion = require("ai.completion")
      completion.trigger() -- generation 1
      completion.trigger() -- generation 2

      pending[1](true, { text = "stale" })
      assert.is_nil(require("ai.ui.ghost").current())

      pending[2](true, { text = "fresh" })
      assert.are.equal("fresh", require("ai.ui.ghost").current().text)
      require("ai.ui.ghost").clear()
    end)

    it("a response for a buffer that was since deleted is discarded", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local saved_cb
      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = true, max_context_lines = 10 } }
        end,
        ask = function(_, cb)
          saved_cb = cb
        end,
      }
      require("ai.completion").trigger()
      vim.api.nvim_buf_delete(bufnr, { force = true })

      assert.has_no.errors(function()
        saved_cb(true, { text = "too late" })
      end)
      assert.is_nil(require("ai.ui.ghost").current())
    end)

    it("a response after the buffer changed (changedtick mismatch) is discarded", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local saved_cb
      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = true, max_context_lines = 10 } }
        end,
        ask = function(_, cb)
          saved_cb = cb
        end,
      }
      require("ai.completion").trigger()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })

      saved_cb(true, { text = "stale" })
      assert.is_nil(require("ai.ui.ghost").current())
    end)

    it("a response after the cursor moved is discarded", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "0123456789" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local saved_cb
      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = true, max_context_lines = 10 } }
        end,
        ask = function(_, cb)
          saved_cb = cb
        end,
      }
      require("ai.completion").trigger()
      vim.api.nvim_win_set_cursor(0, { 1, 5 })

      saved_cb(true, { text = "stale" })
      assert.is_nil(require("ai.ui.ghost").current())
    end)
  end)

  describe("accept", function()
    before_each(function()
      package.loaded["ai"] = {
        config = function()
          return { completion = { enable = true, max_context_lines = 10 } }
        end,
      }
    end)

    it("returns false and touches nothing when no suggestion is shown", function()
      require("ai.ui.ghost").clear()
      assert.is_false(require("ai.completion").accept())
    end)

    it("inserts a single-line suggestion at the cursor and clears it", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = " })
      require("ai.ui.ghost").show(bufnr, 0, 10, "1")

      local accepted = require("ai.completion").accept()
      assert.is_true(accepted)
      assert.are.same({ "local x = 1" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_nil(require("ai.ui.ghost").current())
    end)

    it("moves the cursor to just after the inserted single-line text", function()
      -- Reading the cursor back via `nvim_win_get_cursor` after the fact
      -- would be unreliable here: `accept()`'s own `pcall`-guarded call sets
      -- column 12 (one past "local x = 42"'s last character, index 11) --
      -- correct for the insert-mode context the real `accept` keymap actually
      -- fires in (`mode = "i"`, see ai.bindings.keymaps), but normal mode (the
      -- headless test's default) clamps a cursor set to the end-of-line back
      -- one column, which would make this test check the wrong thing. Spying
      -- on the call directly checks what `accept()` itself computed instead.
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = " })
      require("ai.ui.ghost").show(bufnr, 0, 10, "42")

      local seen
      local original = vim.api.nvim_win_set_cursor
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.api.nvim_win_set_cursor = function(win, pos)
        seen = pos
        return original(win, pos)
      end
      require("ai.completion").accept()
      vim.api.nvim_win_set_cursor = original

      assert.are.same({ 1, 12 }, seen)
    end)

    it("inserts a multi-line suggestion, splitting the current line around it", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before|after" })
      require("ai.ui.ghost").show(bufnr, 0, 7, "one\ntwo\nthree")

      require("ai.completion").accept()
      assert.are.same(
        { "before|one", "two", "threeafter" },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )
    end)

    it("moves the cursor to the end of a multi-line insert's last line", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before|after" })
      require("ai.ui.ghost").show(bufnr, 0, 7, "one\ntwo\nthree")
      require("ai.completion").accept()
      -- Row 3 (1-indexed): "threeafter" -- "three" is 5 bytes, so the cursor
      -- lands right after the inserted text, before "after".
      assert.are.same({ 3, 5 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("returns false without raising when the suggestion's buffer was since deleted", function()
      local scratch = vim.api.nvim_create_buf(false, true)
      require("ai.ui.ghost").show(scratch, 0, 0, "x")
      vim.api.nvim_buf_delete(scratch, { force = true })

      local accepted
      assert.has_no.errors(function()
        accepted = require("ai.completion").accept()
      end)
      assert.is_false(accepted)
    end)
  end)

  describe("dismiss", function()
    it("clears a shown suggestion", function()
      require("ai.ui.ghost").show(bufnr, 0, 0, "x")
      require("ai.completion").dismiss()
      assert.is_nil(require("ai.ui.ghost").current())
    end)
  end)
end)
