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

  it("assemble() returns no errors when a scope legitimately resolves to nothing", function()
    vim.cmd("enew")
    local block, errors = require("ai.context").assemble({ diagnostics = true })
    assert.are.equal("", block)
    assert.is_nil(errors)
  end)

  it("assemble() distinguishes a scope that raises from one that resolves to nothing", function()
    local original = package.loaded["lib.nvim.harvest.scope"]
    package.loaded["lib.nvim.harvest.scope"] = {
      resolve = function()
        error("boom: scope API drift")
      end,
    }

    local ok, block, errors = pcall(function()
      return require("ai.context").assemble({ buffer = true })
    end)

    package.loaded["lib.nvim.harvest.scope"] = original

    assert.is_true(ok)
    assert.are.equal("", block)
    assert.is_not_nil(errors)
    assert.are.equal(1, #errors)
    assert.truthy(errors[1]:find("boom", 1, true) ~= nil)
  end)
end)

describe("ai.context -- structured_data (data.nvim)", function()
  -- Optional soft dependency: see TESTS/minimal_init.lua's DATA_NVIM_DIR.
  -- Registering zero `it`s below (rather than failing) is the correct
  -- "skipped" outcome when it isn't present in this test environment.
  local data_ok = pcall(require, "data.detect")
  if not data_ok then
    return
  end

  it("includes the flattened form of a json buffer under the cursor", function()
    vim.cmd("enew")
    vim.bo.filetype = "json"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '{"a":1,"b":{"c":2}}' })

    local block = require("ai.context").assemble({ structured_data = true })
    assert.truthy(block:match("^Structured data %(json%) under cursor:"))
    assert.truthy(block:match("a: 1"))
    assert.truthy(block:match("b%.c: 2"))
  end)

  it("omits the section when the buffer isn't a recognizable json/yaml/xml block", function()
    vim.cmd("enew")
    vim.bo.filetype = "lua"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = 1" })

    local block = require("ai.context").assemble({ structured_data = true })
    assert.are.equal("", block)
  end)

  it("omits the section when the format is detected but the content fails to decode", function()
    vim.cmd("enew")
    vim.bo.filetype = "json"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "not valid json" })

    local block = require("ai.context").assemble({ structured_data = true })
    assert.are.equal("", block)
  end)
end)
