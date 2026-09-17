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
    it("formats the provider id, exit code and stderr into a network_error", function()
      local obj = { code = 7, stderr = "connection refused" }
      local err = util.curl_exit_error("claude", obj)
      assert.are.equal("network_error", err.kind)
      assert.are.equal("claude: curl exited 7: connection refused", err.message)
      assert.are.equal(obj, err.data)
    end)

    it("reports curl's own exit 28 as a timeout", function()
      local err = util.curl_exit_error("claude", { code = 28, stderr = "" }, 5000)
      assert.are.equal("timeout", err.kind)
      assert.is_true(err.message:find("5000 ms", 1, true) ~= nil)
    end)

    it("reports vim.system's exit 124 as a timeout as well", function()
      -- 124 is what vim.system sets when *its* timeout kills the process
      -- (documented in :help vim.system()). It is the backstop behind
      -- curl's --max-time and should rarely fire -- but curl's own exit
      -- codes stop well below 124, so "curl exited 124" would be a number
      -- nobody can look up.
      local err = util.curl_exit_error("claude", { code = 124, signal = 15 }, 5000)
      assert.are.equal("timeout", err.kind)
    end)

    it("handles a missing stderr", function()
      local err = util.curl_exit_error("claude", { code = 7 })
      assert.are.equal("claude: curl exited 7: ", err.message)
    end)
  end)

  describe("denil (property)", function()
    -- Random nested-table generator: a mix of scalars, vim.NIL and further
    -- nesting, both as array entries and named fields, to a bounded depth so
    -- this terminates.
    local function random_scalar()
      local kind = math.random(4)
      if kind == 1 then
        return vim.NIL
      elseif kind == 2 then
        return math.random(1, 1000)
      elseif kind == 3 then
        return "s" .. math.random(1, 1000)
      end
      return math.random() > 0.5
    end

    local function random_value(depth)
      if depth <= 0 or math.random() > 0.6 then
        return random_scalar()
      end
      local t = {}
      for i = 1, math.random(0, 4) do
        t[i] = random_value(depth - 1)
      end
      for _, key in ipairs({ "a", "b", "c" }) do
        if math.random() > 0.5 then
          t[key] = random_value(depth - 1)
        end
      end
      return t
    end

    ---@param value any
    ---@return boolean
    local function contains_nil(value)
      if value == vim.NIL then
        return true
      end
      if type(value) ~= "table" then
        return false
      end
      for _, v in pairs(value) do
        if contains_nil(v) then
          return true
        end
      end
      return false
    end

    it("never throws and leaves no vim.NIL anywhere, for arbitrary nested input", function()
      for _ = 1, 200 do
        local input = random_value(4)
        local ok, result = pcall(util.denil, input)
        assert.is_true(ok)
        assert.is_false(contains_nil(result))
      end
    end)
  end)
end)
