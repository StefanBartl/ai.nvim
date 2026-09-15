describe("ai.providers.util", function()
  local util = require("ai.providers.util")

  describe("denil", function()
    it("replaces a top-level vim.NIL field with nil", function()
      local t = { a = 1, b = vim.NIL }
      util.denil(t)
      assert.are.equal(1, t.a)
      assert.is_nil(t.b)
    end)

    it("replaces vim.NIL nested inside sub-tables, in place", function()
      local t = { delta = { text = "hi", stop_reason = vim.NIL } }
      util.denil(t)
      assert.are.equal("hi", t.delta.text)
      assert.is_nil(t.delta.stop_reason)
    end)

    it("leaves a table with no vim.NIL untouched", function()
      local t = { a = 1, b = { c = "x" } }
      util.denil(t)
      assert.are.equal(1, t.a)
      assert.are.equal("x", t.b.c)
    end)

    it("returns non-table values unchanged", function()
      assert.are.equal("x", util.denil("x"))
      assert.is_nil(util.denil(nil))
      assert.are.equal(5, util.denil(5))
    end)

    it("returns the same table it was given", function()
      local t = { a = vim.NIL }
      assert.are.equal(t, util.denil(t))
    end)
  end)

  describe("env_value", function()
    local original

    before_each(function()
      original = vim.env.AI_TEST_ENV_VALUE
    end)

    after_each(function()
      vim.env.AI_TEST_ENV_VALUE = original
    end)

    it("trims whitespace and a trailing newline", function()
      vim.env.AI_TEST_ENV_VALUE = "  hello \n"
      assert.are.equal("hello", util.env_value("AI_TEST_ENV_VALUE"))
    end)

    it("returns the fallback when unset", function()
      vim.env.AI_TEST_ENV_VALUE = nil
      assert.are.equal("fallback", util.env_value("AI_TEST_ENV_VALUE", "fallback"))
    end)

    it("returns the fallback when set but blank after trimming", function()
      vim.env.AI_TEST_ENV_VALUE = "   "
      assert.are.equal("fallback", util.env_value("AI_TEST_ENV_VALUE", "fallback"))
    end)
  end)

  describe("executable", function()
    before_each(function()
      -- Fresh module each time: the executable cache is module-local state,
      -- and a stub must be in place before it -- see `providers_claude_spec.lua`.
      package.loaded["ai.providers.util"] = nil
    end)

    after_each(function()
      package.loaded["ai.providers.util"] = nil
    end)

    it("caches the result after the first probe", function()
      local calls = 0
      local original = vim.fn.executable
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.executable = function(name)
        calls = calls + 1
        return original(name)
      end

      local fresh_util = require("ai.providers.util")
      local first = fresh_util.executable("curl")
      local second = fresh_util.executable("curl")

      vim.fn.executable = original
      assert.are.equal(first, second)
      assert.are.equal(1, calls)
    end)

    it("caches a failing probe too, not just a successful one", function()
      local calls = 0
      local original = vim.fn.executable
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.executable = function(name)
        calls = calls + 1
        if name == "ai-nvim-test-nonexistent-tool" then
          return 0
        end
        return original(name)
      end

      local fresh_util = require("ai.providers.util")
      assert.is_false(fresh_util.executable("ai-nvim-test-nonexistent-tool"))
      assert.is_false(fresh_util.executable("ai-nvim-test-nonexistent-tool"))

      vim.fn.executable = original
      assert.are.equal(1, calls)
    end)

    it("caches different tool names independently", function()
      local fresh_util = require("ai.providers.util")
      local curl_result = fresh_util.executable("curl")
      local bogus_result = fresh_util.executable("ai-nvim-test-nonexistent-tool-2")
      assert.is_false(bogus_result)
      assert.are.equal(vim.fn.executable("curl") == 1, curl_result)
    end)
  end)

  describe("curl_exit_error", function()
    it("formats the provider id, exit code and stderr", function()
      local msg = util.curl_exit_error("claude", { code = 7, stderr = "connection refused" })
      assert.are.equal("claude: curl exited 7: connection refused", msg)
    end)

    it("handles a missing stderr", function()
      local msg = util.curl_exit_error("claude", { code = 7 })
      assert.are.equal("claude: curl exited 7: ", msg)
    end)
  end)
end)
