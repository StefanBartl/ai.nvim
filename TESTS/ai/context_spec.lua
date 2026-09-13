describe("ai.context.diagnostics", function()
  it("formats diagnostics as file:line:[severity]:message, sorted by line", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c" })
    local ns = vim.api.nvim_create_namespace("ai_test_diag")
    vim.diagnostic.set(ns, bufnr, {
      { lnum = 2, col = 0, severity = vim.diagnostic.severity.WARN, message = "second" },
      { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "first" },
    })

    local lines = require("ai.context.diagnostics").collect(bufnr)
    assert.are.equal(2, #lines)
    assert.truthy(lines[1]:match("1: %[ERROR%] first$"))
    assert.truthy(lines[2]:match("3: %[WARN%] second$"))

    vim.diagnostic.reset(ns, bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("returns an empty list for a buffer with no diagnostics", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local lines = require("ai.context.diagnostics").collect(bufnr)
    assert.are.equal(0, #lines)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

describe("ai.context", function()
  it("assemble({}) returns an empty string when nothing is requested", function()
    local block = require("ai.context").assemble({})
    assert.are.equal("", block)
  end)

  it("assemble({buffer=true}) includes the current buffer, fenced and line-numbered", function()
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line one", "line two" })
    local block = require("ai.context").assemble({ buffer = true })
    assert.truthy(block:match("1: line one"))
    assert.truthy(block:match("2: line two"))
    assert.truthy(block:match("^```"))
  end)

  it("assemble({diagnostics=true}) includes a Diagnostics: section when present", function()
    vim.cmd("enew")
    local bufnr = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_create_namespace("ai_test_context_diag")
    vim.diagnostic.set(ns, bufnr, {
      { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "boom" },
    })

    local block = require("ai.context").assemble({ diagnostics = true })
    assert.truthy(block:match("^Diagnostics:"))
    assert.truthy(block:match("boom"))

    vim.diagnostic.reset(ns, bufnr)
  end)

  it("assemble({diagnostics=true}) omits the section when there is nothing to report", function()
    vim.cmd("enew")
    local block = require("ai.context").assemble({ diagnostics = true })
    assert.are.equal("", block)
  end)
end)
