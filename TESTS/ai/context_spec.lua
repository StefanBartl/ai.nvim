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

describe("ai.context -- structured_data error propagation (stubbed data.nvim)", function()
  -- Unlike the describe block above, this one stubs `data.detect`/
  -- `data.scope.resolve`/`data.format` directly via `package.loaded` --
  -- `require()` checks that table before ever touching 'runtimepath', so
  -- these run regardless of whether a real data.nvim checkout is on the
  -- rtp in this test environment. Verifies the fix for the finding that
  -- `add_structured_data_scope` let a raise from `detect.format`/
  -- `scope_resolve.lines` escape `M.assemble` uncaught, unlike every other
  -- scope in this file (see the "scope raises" test above).
  local saved = {}

  before_each(function()
    saved["data.detect"] = package.loaded["data.detect"]
    saved["data.scope.resolve"] = package.loaded["data.scope.resolve"]
    saved["data.format"] = package.loaded["data.format"]
    package.loaded["data.format"] = {
      get = function()
        return {}
      end,
    }
  end)

  after_each(function()
    package.loaded["data.detect"] = saved["data.detect"]
    package.loaded["data.scope.resolve"] = saved["data.scope.resolve"]
    package.loaded["data.format"] = saved["data.format"]
  end)

  it("records into `errors` instead of raising when detect.format() throws", function()
    package.loaded["data.detect"] = {
      format = function()
        error("boom: detect API drift")
      end,
    }
    package.loaded["data.scope.resolve"] = {
      lines = function()
        return 0, 0
      end,
    }

    local ok, block, errors = pcall(function()
      return require("ai.context").assemble({ structured_data = true })
    end)

    assert.is_true(ok)
    assert.are.equal("", block)
    assert.is_not_nil(errors)
    assert.truthy(errors[1]:find("boom", 1, true) ~= nil)
  end)

  it("records into `errors` instead of raising when scope_resolve.lines() throws", function()
    package.loaded["data.detect"] = {
      format = function()
        return "json"
      end,
    }
    package.loaded["data.scope.resolve"] = {
      lines = function()
        error("boom: scope_resolve API drift")
      end,
    }

    local ok, block, errors = pcall(function()
      return require("ai.context").assemble({ structured_data = true })
    end)

    assert.is_true(ok)
    assert.are.equal("", block)
    assert.is_not_nil(errors)
    assert.truthy(errors[1]:find("boom", 1, true) ~= nil)
  end)
end)

describe("ai.context -- conflict (gitsuite.nvim)", function()
  -- Optional soft dependency: see TESTS/minimal_init.lua's GITSUITE_NVIM_DIR.
  -- Registering zero `it`s below (rather than failing) is the correct
  -- "skipped" outcome when it isn't present in this test environment.
  local gitsuite_ok = pcall(require, "gitsuite.features.conflict")
  if not gitsuite_ok then
    return
  end

  it("includes both sides, labeled, for a real conflict region", function()
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "before",
      "<<<<<<< HEAD",
      "our line",
      "=======",
      "their line",
      ">>>>>>> feature",
      "after",
    })

    local block = require("ai.context").assemble({ conflict = true })
    assert.truthy(block:match("Merge conflict %-%- ours %(HEAD%):"))
    assert.truthy(block:match("our line"))
    assert.truthy(block:match("Merge conflict %-%- theirs %(feature%):"))
    assert.truthy(block:match("their line"))
  end)

  it("omits the section when the buffer has no conflict markers", function()
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "plain content" })

    local block = require("ai.context").assemble({ conflict = true })
    assert.are.equal("", block)
  end)

  it("skips an ambiguous region -- no ours/theirs split to hand over", function()
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "<<<<<<< HEAD",
      "Title",
      "=======",
      "our text",
      "=======",
      "their text",
      ">>>>>>> other",
    })

    local block = require("ai.context").assemble({ conflict = true })
    assert.are.equal("", block)
  end)
end)

describe("ai.context -- conflict (stubbed gitsuite.nvim)", function()
  -- `require()` checks `package.loaded` before ever touching 'runtimepath',
  -- so this runs regardless of whether a real gitsuite.nvim checkout is on
  -- the rtp in this test environment -- the CI-guaranteed baseline for this
  -- scope, same role the "stubbed data.nvim" block above plays for
  -- structured_data.
  local saved

  before_each(function()
    saved = package.loaded["gitsuite.features.conflict"]
  end)

  after_each(function()
    package.loaded["gitsuite.features.conflict"] = saved
  end)

  it("formats a resolved region's ours/theirs lines from the buffer, by row", function()
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "OURS_LINE", "THEIRS_LINE" })

    package.loaded["gitsuite.features.conflict"] = {
      scan = function()
        return {
          {
            ambiguous = false,
            ours_first = 0,
            ours_last = 0,
            ours_label = "HEAD",
            theirs_first = 1,
            theirs_last = 1,
            theirs_label = "branch",
          },
        }
      end,
    }

    local block = require("ai.context").assemble({ conflict = true })
    assert.truthy(block:match("Merge conflict %-%- ours %(HEAD%):"))
    assert.truthy(block:match("OURS_LINE"))
    assert.truthy(block:match("Merge conflict %-%- theirs %(branch%):"))
    assert.truthy(block:match("THEIRS_LINE"))
  end)

  it("an empty side (last < first) renders as an empty fenced block, not an error", function()
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "THEIRS_ONLY" })

    package.loaded["gitsuite.features.conflict"] = {
      scan = function()
        return {
          {
            ambiguous = false,
            ours_first = 0,
            ours_last = -1, -- our side deleted the whole block
            ours_label = "",
            theirs_first = 0,
            theirs_last = 0,
            theirs_label = "",
          },
        }
      end,
    }

    local ok, block = pcall(function()
      return require("ai.context").assemble({ conflict = true })
    end)
    assert.is_true(ok)
    assert.truthy(block:match("Merge conflict %-%- ours %(HEAD%):"))
    assert.truthy(block:match("THEIRS_ONLY"))
  end)

  it("scan() raising does not escape assemble() -- silent, like gitsuite being absent", function()
    package.loaded["gitsuite.features.conflict"] = {
      scan = function()
        error("boom: gitsuite API drift")
      end,
    }

    local ok, block = pcall(function()
      return require("ai.context").assemble({ conflict = true })
    end)
    assert.is_true(ok)
    assert.are.equal("", block)
  end)

  it("gitsuite.nvim absent: assemble({conflict=true}) is a silent no-op", function()
    local orig_preload = package.preload["gitsuite.features.conflict"]
    package.loaded["gitsuite.features.conflict"] = nil
    package.preload["gitsuite.features.conflict"] = function()
      error("no gitsuite.nvim here")
    end

    local ok, block = pcall(function()
      return require("ai.context").assemble({ conflict = true })
    end)

    package.preload["gitsuite.features.conflict"] = orig_preload

    assert.is_true(ok)
    assert.are.equal("", block)
  end)
end)
