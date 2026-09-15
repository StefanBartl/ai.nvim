-- Integration-style, not a pure-function test like completion_prompt_spec.lua:
-- exercises ai.completion.setup()'s real autocmd/lib.nvim.debounce wiring
-- against a real scratch buffer, with only `require("ai")` stubbed (via
-- package.loaded) so no network call happens. Added alongside the PERF-64
-- fix (hand-rolled vim.uv timer -> lib.nvim.debounce) since nothing
-- previously covered this file at all -- see TESTS/minimal_init.lua's own
-- note on why ui.nvim-touching modules aren't otherwise covered here (this
-- one doesn't touch ui.kit: ai.ui.ghost is pure vim.api/extmarks).
describe("ai.completion auto-trigger", function()
  local bufnr

  before_each(function()
    package.loaded["ai.completion"] = nil
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    package.loaded["ai"] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("debounces a burst of TextChangedI into exactly one trigger after idle_ms", function()
    local calls = 0
    package.loaded["ai"] = {
      config = function()
        return { completion = { enable = true, max_context_lines = 10 } }
      end,
      ask = function(_, cb)
        calls = calls + 1
        cb(false, "stubbed")
      end,
    }

    local completion = require("ai.completion")
    completion.setup({ completion = { enable = true, trigger = "auto", idle_ms = 20 } })

    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    assert.are.equal(0, calls) -- still inside the idle window, not fired yet

    vim.wait(500, function()
      return calls > 0
    end, 10)
    assert.are.equal(1, calls) -- the burst coalesced into a single trigger
  end)

  it("cancels a pending auto-trigger on InsertLeave", function()
    local calls = 0
    package.loaded["ai"] = {
      config = function()
        return { completion = { enable = true, max_context_lines = 10 } }
      end,
      ask = function(_, cb)
        calls = calls + 1
        cb(false, "stubbed")
      end,
    }

    local completion = require("ai.completion")
    completion.setup({ completion = { enable = true, trigger = "auto", idle_ms = 30 } })

    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = bufnr })

    vim.wait(200)
    assert.are.equal(0, calls)
  end)

  it("does not install the auto-trigger autocmd in manual mode", function()
    local calls = 0
    package.loaded["ai"] = {
      config = function()
        return { completion = { enable = true, max_context_lines = 10 } }
      end,
      ask = function(_, cb)
        calls = calls + 1
        cb(false, "stubbed")
      end,
    }

    local completion = require("ai.completion")
    completion.setup({ completion = { enable = true, trigger = "manual", idle_ms = 20 } })

    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    vim.wait(200)
    assert.are.equal(0, calls)
  end)
end)
