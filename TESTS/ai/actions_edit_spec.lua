-- ai.bindings.actions' in-place edits (rewrite / append / prepend): the answer is written with one
-- nvim_buf_set_lines call, and a buffer that refuses it (not 'modifiable') must give a readable
-- notification and stay unchanged instead of raising a Lua error out of the response callback.
--
-- `ai.ask`, `lib.nvim.notify` and `lib.nvim.progress` are stubbed; everything else is real.
---@diagnostic disable: need-check-nil
describe("ai.bindings.actions edit actions", function()
  local bufnr
  local errors, warnings
  local saved = {}

  local function stub(name, value)
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end

  before_each(function()
    errors, warnings = {}, {}
    stub("ai", {
      ask = function(_, cb)
        cb(true, { text = "new line", stop_reason = "end_turn" })
      end,
    })
    stub("lib.nvim.notify", {
      create = function()
        return {
          error = function(msg)
            errors[#errors + 1] = msg
          end,
          warn = function(msg)
            warnings[#warnings + 1] = msg
          end,
          info = function() end,
        }
      end,
    })
    stub("lib.nvim.progress", {
      create = function()
        return { finish = function() end }
      end,
    })
    package.loaded["ai.bindings.actions"] = nil
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "old line" })
  end)

  after_each(function()
    for name, value in pairs(saved) do
      package.loaded[name] = value
    end
    saved = {}
    package.loaded["ai.bindings.actions"] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("rewrites the range in a modifiable buffer", function()
    require("ai.bindings.actions").rewrite_prompt("do it", { line1 = 1, line2 = 1 })
    assert.are.same({ "new line" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.are.equal(0, #errors)
  end)

  for _, name in ipairs({ "rewrite_prompt", "append_prompt", "prepend_prompt" }) do
    it(name .. ": a non-modifiable buffer gives an error notification, not a Lua error", function()
      vim.bo[bufnr].modifiable = false
      local ok, err = pcall(require("ai.bindings.actions")[name], "do it", { line1 = 1, line2 = 1 })
      assert.is_true(ok, tostring(err))
      assert.are.same({ "old line" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.are.equal(1, #errors)
      assert.is_truthy(errors[1]:find("Could not write the answer into the buffer", 1, true))
      assert.is_truthy(errors[1]:find("modifiable", 1, true))
    end)
  end
end)
