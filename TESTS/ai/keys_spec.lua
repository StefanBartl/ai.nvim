-- Named key profiles (lua/ai/keys.lua) and how the providers use them.
---@diagnostic disable: missing-fields, need-check-nil
describe("ai.keys", function()
  local saved, dir

  local function reload()
    for _, name in ipairs({
      "ai.config",
      "ai.keys",
      "ai.providers",
      "ai.providers.claude",
      "ai.providers.openai",
      "ai.providers.util",
      "ai",
    }) do
      package.loaded[name] = nil
    end
  end

  local function write_file(name, text)
    local path = dir .. "/" .. name
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
    return path
  end

  local function setup(keys)
    require("ai.config").setup({ keys = keys })
    return require("ai.keys")
  end

  before_each(function()
    reload()
    saved = {
      vim.env.ANTHROPIC_API_KEY,
      vim.env.AI_TEST_KEY_PRIVATE,
      vim.env.AI_TEST_KEY_COMPANY,
    }
    vim.env.ANTHROPIC_API_KEY = "default-key"
    vim.env.AI_TEST_KEY_PRIVATE = "private-key"
    vim.env.AI_TEST_KEY_COMPANY = nil
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.env.ANTHROPIC_API_KEY = saved[1]
    vim.env.AI_TEST_KEY_PRIVATE = saved[2]
    vim.env.AI_TEST_KEY_COMPANY = saved[3]
    vim.fn.delete(dir, "rf")
    reload()
  end)

  describe("without any profile", function()
    it("reads the provider's own variable, exactly as before", function()
      local keys = setup({})
      assert.are.equal("default-key", keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.is_nil(keys.active("claude"))
      assert.are.equal("default variable", keys.describe("claude"))
      assert.are.same({}, keys.providers())
    end)
  end)

  describe("profiles", function()
    it("an env profile reads its own variable, not the default one", function()
      local keys = setup({
        claude = { active = "private", profiles = { private = { env = "AI_TEST_KEY_PRIVATE" } } },
      })
      assert.are.equal("private-key", keys.get("claude", "ANTHROPIC_API_KEY"))
    end)

    it("a file profile takes the first non-empty line, trimmed", function()
      local path = write_file("c.key", "\n  from-file  \nsecond\n")
      local keys =
        setup({ claude = { active = "company", profiles = { company = { file = path } } } })
      assert.are.equal("from-file", keys.get("claude", "ANTHROPIC_API_KEY"))
    end)

    it("a changed file is picked up without a restart", function()
      local path = write_file("c.key", "first")
      local keys =
        setup({ claude = { active = "company", profiles = { company = { file = path } } } })
      assert.are.equal("first", keys.get("claude", "ANTHROPIC_API_KEY"))
      write_file("c.key", "second-longer")
      assert.are.equal("second-longer", keys.get("claude", "ANTHROPIC_API_KEY"))
    end)

    it("an active profile with an empty source gives nil and never the default key", function()
      local keys = setup({
        claude = { active = "company", profiles = { company = { env = "AI_TEST_KEY_COMPANY" } } },
      })
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"), "must not fall back")
      assert.is_truthy(keys.describe("claude"):find("KEY MISSING", 1, true))
    end)

    it("a missing file gives nil", function()
      local keys = setup({
        claude = { active = "company", profiles = { company = { file = dir .. "/nope.key" } } },
      })
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
    end)

    it("describe never contains the key", function()
      local keys = setup({
        claude = { active = "private", profiles = { private = { env = "AI_TEST_KEY_PRIVATE" } } },
      })
      local text = keys.describe("claude")
      assert.is_nil(text:find("private-key", 1, true))
      assert.is_truthy(text:find("key present", 1, true))
      assert.is_truthy(text:find("env AI_TEST_KEY_PRIVATE", 1, true))
    end)
  end)

  describe("the session switch", function()
    local function two_profiles()
      return setup({
        claude = {
          active = "private",
          profiles = {
            private = { env = "AI_TEST_KEY_PRIVATE" },
            company = { file = write_file("c.key", "company-key") },
          },
        },
        openai = { profiles = { company = { file = write_file("o.key", "openai-company") } } },
      })
    end

    it("use() switches every provider that defines the profile", function()
      local keys = two_profiles()
      assert.are.same({ "claude", "openai" }, keys.use("company"))
      assert.are.equal("company-key", keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.are.equal("openai-company", keys.get("openai", "OPENAI_API_KEY"))
    end)

    it("use() can be limited to one provider", function()
      local keys = two_profiles()
      assert.are.same({ "claude" }, keys.use("company", "claude"))
      assert.are.equal("company", keys.active("claude"))
      assert.is_nil(keys.active("openai"))
    end)

    it("an unknown profile switches nothing and changes nothing", function()
      local keys = two_profiles()
      assert.are.same({}, keys.use("nope"))
      assert.are.equal("private", keys.active("claude"))
    end)

    it("reset() returns to the configured active profile", function()
      local keys = two_profiles()
      keys.use("company")
      keys.reset()
      assert.are.equal("private", keys.active("claude"))
      assert.are.equal("private-key", keys.get("claude", "ANTHROPIC_API_KEY"))
    end)

    it("is not persisted: a fresh module state starts at the configured profile", function()
      local keys = two_profiles()
      keys.use("company")
      package.loaded["ai.keys"] = nil
      assert.are.equal("private", require("ai.keys").active("claude"))
    end)
  end)

  describe("validation (config issues)", function()
    it("is silent for a good config and for none", function()
      assert.are.same({}, setup({}).issues())
      local keys = setup({
        claude = { active = "a", profiles = { a = { env = "X" }, b = { file = "y" } } },
      })
      assert.are.same({}, keys.issues())
    end)

    it("flags a profile with both or neither source, and an unknown active", function()
      local keys = setup({
        claude = {
          active = "ghost",
          profiles = { both = { env = "X", file = "y" }, none = {} },
        },
      })
      local text = table.concat(keys.issues(), "\n")
      assert.is_truthy(text:find("both", 1, true))
      assert.is_truthy(text:find("none", 1, true))
      assert.is_truthy(text:find("ghost", 1, true))
    end)

    it("flags a provider entry without profiles", function()
      local keys = setup({ claude = { active = "a" } })
      assert.is_truthy(table.concat(keys.issues(), "\n"):find("profiles", 1, true))
    end)

    it("setup() accepts a keys table without an unknown-key warning", function()
      local warned = false
      package.loaded["lib.nvim.notify"] = {
        create = function()
          return {
            warn = function()
              warned = true
            end,
          }
        end,
      }
      setup({ claude = { profiles = { a = { env = "X" } } } })
      package.loaded["lib.nvim.notify"] = nil
      assert.is_false(warned)
    end)
  end)

  describe("the providers", function()
    it("claude uses the active profile's key and is unavailable when it is empty", function()
      local keys = setup({
        claude = { active = "company", profiles = { company = { env = "AI_TEST_KEY_COMPANY" } } },
      })
      local claude = require("ai.providers.claude")
      assert.is_false(claude.available())
      vim.env.AI_TEST_KEY_COMPANY = "now-set"
      assert.is_true(claude.available())
      assert.are.equal("now-set", keys.get("claude", "ANTHROPIC_API_KEY"))
    end)

    it("a per-request api_key still wins over the profile", function()
      setup({
        claude = { active = "company", profiles = { company = { env = "AI_TEST_KEY_COMPANY" } } },
      })
      assert.is_true(require("ai.providers.claude").available({ api_key = "explicit" }))
    end)

    it("the missing-key error names the profile instead of the default variable", function()
      setup({
        claude = { active = "company", profiles = { company = { env = "AI_TEST_KEY_COMPANY" } } },
      })
      local ok, err
      require("ai.providers.claude").ask({ prompt = "x" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("missing_api_key", err.kind)
      assert.is_truthy(err.message:find("company", 1, true))
      assert.is_nil(err.message:find("ANTHROPIC_API_KEY not set", 1, true))
    end)

    it("without a profile the missing-key error is the unchanged default one", function()
      setup({})
      vim.env.ANTHROPIC_API_KEY = nil
      local ok, err
      require("ai.providers.claude").ask({ prompt = "x" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("claude: ANTHROPIC_API_KEY not set", err.message)
      assert.are.same({ env_var = "ANTHROPIC_API_KEY" }, err.data)
    end)
  end)
end)
