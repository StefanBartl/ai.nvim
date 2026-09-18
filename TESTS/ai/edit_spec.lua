describe("ai.bindings.edit", function()
  local edit = require("ai.bindings.edit")

  describe("resolve_range", function()
    local bufnr, winid

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c", "d" })
      winid = vim.api.nvim_open_win(bufnr, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 10,
        height = 4,
      })
    end)

    after_each(function()
      if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_close(winid, true)
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it("returns an explicit range unchanged", function()
      local line1, line2 = edit.resolve_range({ line1 = 2, line2 = 3 }, winid)
      assert.are.equal(2, line1)
      assert.are.equal(3, line2)
    end)

    it("falls back to the cursor line when range is nil", function()
      vim.api.nvim_win_set_cursor(winid, { 3, 0 })
      local line1, line2 = edit.resolve_range(nil, winid)
      assert.are.equal(3, line1)
      assert.are.equal(3, line2)
    end)

    it("falls back to the cursor line when range.line1 is 0 (no Visual mark yet)", function()
      vim.api.nvim_win_set_cursor(winid, { 1, 0 })
      local line1, line2 = edit.resolve_range({ line1 = 0, line2 = 0 }, winid)
      assert.are.equal(1, line1)
      assert.are.equal(1, line2)
    end)
  end)

  describe("code_block", function()
    it("fences the given line range with the buffer's filetype", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[bufnr].filetype = "lua"
      vim.api.nvim_buf_set_lines(
        bufnr,
        0,
        -1,
        false,
        { "local x = 1", "local y = 2", "local z = 3" }
      )

      local block = edit.code_block(bufnr, 2, 3)
      assert.are.equal("```lua\nlocal y = 2\nlocal z = 3\n```", block)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("labels an empty filetype as a bare fence", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "text" })

      local block = edit.code_block(bufnr, 1, 1)
      assert.are.equal("```\ntext\n```", block)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("parse_lines", function()
    it("splits plain multi-line text into lines", function()
      assert.are.same({ "a", "b" }, edit.parse_lines("a\nb"))
    end)

    it("strips a fenced code block with a language tag", function()
      assert.are.same({ "local x = 1" }, edit.parse_lines("```lua\nlocal x = 1\n```"))
    end)

    it("strips a fenced code block with no language tag", function()
      assert.are.same({ "local x = 1" }, edit.parse_lines("```\nlocal x = 1\n```"))
    end)

    it("keeps a multi-line fenced block intact", function()
      assert.are.same(
        { "local x = 1", "local y = 2" },
        edit.parse_lines("```lua\nlocal x = 1\nlocal y = 2\n```")
      )
    end)

    it("trims surrounding whitespace on unfenced text", function()
      assert.are.same({ "local x = 1" }, edit.parse_lines("  local x = 1  \n"))
    end)

    it("returns an empty list for a non-string input", function()
      assert.are.same({}, edit.parse_lines(nil))
    end)

    it("returns an empty list for a blank string", function()
      assert.are.same({}, edit.parse_lines("   \n  "))
    end)
  end)
end)
