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

  describe("a configured active that resolves to nothing", function()
    -- The default variable holds the *other* account's key here. Every shape of
    -- "active names nothing usable" has to give no key, never that one.
    it("a typo'd active fails closed instead of reading the default variable", function()
      local keys = setup({
        claude = { active = "Firma", profiles = { firma = { env = "AI_TEST_KEY_PRIVATE" } } },
      })
      assert.are.equal("Firma", keys.active("claude"))
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.is_true(keys.blocked("claude"))
      local text = keys.describe("claude")
      assert.is_truthy(text:find("Firma", 1, true))
      assert.is_truthy(text:find("KEY MISSING", 1, true))
      assert.is_false(require("ai.providers.claude").available())
    end)

    it("a profile spec that is not a table fails closed too", function()
      local keys = setup({
        claude = { active = "firma", profiles = { firma = "AI_TEST_KEY_PRIVATE" } },
      })
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.is_truthy(keys.describe("claude"):find("KEY MISSING", 1, true))
    end)

    it("an active without any profiles fails closed", function()
      local keys = setup({ claude = { active = "firma" } })
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
    end)

    it("the missing-key error names the profile", function()
      setup({ claude = { active = "Firma", profiles = { firma = { env = "X" } } } })
      local ok, err
      require("ai.providers.claude").ask({ prompt = "x" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("missing_api_key", err.kind)
      assert.is_truthy(err.message:find("Firma", 1, true))
      assert.is_nil(err.message:find("ANTHROPIC_API_KEY", 1, true))
    end)

    it("the broken setup still shows in providers(), so :Ai info can print it", function()
      local keys = setup({ claude = { active = "firma", profiles = { firma = "X" } } })
      assert.are.same({ "claude" }, keys.providers())
    end)

    it("active = false means no profile: the default variable applies", function()
      local keys = setup({
        claude = { active = false, profiles = { firma = { env = "AI_TEST_KEY_PRIVATE" } } },
      })
      assert.is_nil(keys.active("claude"))
      assert.is_false(keys.blocked("claude"))
      assert.are.equal("default-key", keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.are.same({}, keys.issues())
    end)

    it("a stale session choice is ignored and the configured active applies", function()
      local keys = setup({
        claude = {
          active = "private",
          profiles = { private = { env = "AI_TEST_KEY_PRIVATE" }, other = { env = "X" } },
        },
      })
      keys.use("other")
      require("ai.config").setup({
        keys = {
          claude = { active = "private", profiles = { private = { env = "AI_TEST_KEY_PRIVATE" } } },
        },
      })
      assert.are.equal("private", keys.active("claude"))
    end)

    it("the issue says requests fail until it is fixed", function()
      local keys = setup({ claude = { active = "ghost", profiles = { a = { env = "X" } } } })
      assert.is_truthy(table.concat(keys.issues(), "\n"):find("requests fail", 1, true))
    end)
  end)

  describe("key files", function()
    ---@param text string
    ---@return string|nil
    local function key_of(text)
      local path = write_file("k.key", text)
      local keys = setup({ claude = { active = "c", profiles = { c = { file = path } } } })
      return keys.get("claude", "ANTHROPIC_API_KEY")
    end

    ---@param text string
    ---@return string
    local function utf16le(text)
      return (text:gsub(".", "%0\0"))
    end

    it("strips a UTF-8 BOM", function()
      assert.are.equal("sk-ant-abc", key_of("\239\187\191sk-ant-abc\r\n"))
    end)

    it("strips the BOM before trimming, and skips a first line that is only the BOM", function()
      assert.are.equal("sk-ant-abc", key_of("\239\187\191   sk-ant-abc  \n"))
      assert.are.equal("sk-ant-abc", key_of("\239\187\191\nsk-ant-abc\n"))
    end)

    it("decodes UTF-16LE with a BOM (PowerShell 5.1's `>` and Out-File)", function()
      assert.are.equal("sk-ant-abc", key_of("\255\254" .. utf16le("sk-ant-abc\r\n")))
    end)

    it("decodes UTF-16BE with a BOM", function()
      local be = ("sk-ant-abc\n"):gsub(".", "\0%0")
      assert.are.equal("sk-ant-abc", key_of("\254\255" .. be))
    end)

    it("UTF-16 that is not plain ASCII is not a key", function()
      local path = write_file("k.key", "\255\254" .. utf16le("k\233y\n"))
      local keys = setup({ claude = { active = "c", profiles = { c = { file = path } } } })
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
    end)

    it("UTF-16 without a BOM is not a key: nothing is reported as present", function()
      local path = write_file("k.key", utf16le("sk-ant-abc\r\n"))
      local keys = setup({ claude = { active = "c", profiles = { c = { file = path } } } })
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.is_truthy(keys.describe("claude"):find("KEY MISSING", 1, true))
    end)

    -- The file is read whole and its line trimmed on `available()`: a line with a
    -- long run of blanks must not take quadratic time (`^%s*(.-)%s*$`: 8 s for 120 kB).
    it("trims a line with a long run of blanks in linear time (120 kB)", function()
      local n = 120000
      local inner = "a" .. (" "):rep(n) .. "b"
      for _, case in ipairs({
        { inner .. "\n", inner },
        { (" "):rep(n) .. "\nkey\n", "key" },
        { "key" .. (" "):rep(n) .. "\n", "key" },
      }) do
        local t0 = vim.uv.hrtime()
        local value = key_of(case[1])
        local ms = (vim.uv.hrtime() - t0) / 1e6
        assert.is_true(ms < 1000, ("%d ms for %d bytes"):format(ms, #case[1]))
        assert.are.equal(case[2], value)
      end
      assert.are.equal("a b", key_of("  a b \t\n"))
    end)

    it("a directory instead of a file gives no key and no error", function()
      local keys = setup({ claude = { active = "c", profiles = { c = { file = dir } } } })
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.is_truthy(keys.describe("claude"):find("KEY MISSING", 1, true))
    end)

    it("a failed open is not cached: the key appears once the file can be read again", function()
      local path = write_file("k.key", "locked-then-free")
      local keys = setup({ claude = { active = "c", profiles = { c = { file = path } } } })
      -- A sharing violation (editor, antivirus, sync client) fails the open but
      -- leaves mtime and size alone, so nothing else would ever invalidate it.
      local real_open = io.open
      io.open = function()
        return nil, "Permission denied"
      end
      local ok, locked = pcall(keys.get, "claude", "ANTHROPIC_API_KEY")
      io.open = real_open
      assert.is_true(ok)
      assert.is_nil(locked)
      assert.are.equal("locked-then-free", keys.get("claude", "ANTHROPIC_API_KEY"))
    end)
  end)

  describe("an env that is not a variable name", function()
    -- A key pasted where the variable name belongs: an Anthropic- and an
    -- OpenAI-style one (hyphens), and the vendors' keys that have none: Gemini's
    -- `AIza` and Groq's `gsk_` and Hugging Face's `hf_` prefixes, and a bare
    -- mixed-case token of 32 or more letters and digits.
    local pasted = {
      "sk-ant-api03-REALKEYVALUE",
      "sk-proj-AbCd1234EfGh5678",
      "AIzaSyD4kFq8xV2mN7pLrT9wZcB3eH6jU1oYgXs",
      "AIza_" .. ("x"):rep(34),
      "gsk_" .. ("aB3dE5gH7j"):rep(5) .. "kL",
      "gsk_" .. ("a"):rep(40),
      "hf_" .. ("aBcDeFgHiJ"):rep(3) .. "kLmN",
      "hf_" .. ("a"):rep(34),
      "xK3mP9qR2sT7uV4wY8zA1bC5dE6fG0hJ",
      "Gk3mP9qR2sT7uV4wY8zA1bC5dE6fG0hJmN2",
    }

    for _, key in ipairs(pasted) do
      it(("is never echoed: %s..."):format(key:sub(1, 8)), function()
        local keys = setup({ claude = { active = "c", profiles = { c = { env = key } } } })
        assert.is_nil(keys.describe("claude"):find(key, 1, true))
        assert.is_truthy(keys.describe("claude"):find("KEY MISSING", 1, true))
        local issues = table.concat(keys.issues(), "\n")
        assert.is_truthy(issues:find("not a variable name", 1, true))
        assert.is_nil(issues:find(key, 1, true))
        local err = require("ai.providers.util").missing_key_error("claude", "ANTHROPIC_API_KEY")
        assert.is_nil(err.message:find(key, 1, true))
      end)
    end

    it("a conventional name is still shown, and is no issue", function()
      local keys =
        setup({ claude = { active = "c", profiles = { c = { env = "AI_TEST_KEY_COMPANY" } } } })
      assert.is_truthy(keys.describe("claude"):find("env AI_TEST_KEY_COMPANY", 1, true))
      assert.are.same({}, keys.issues())
    end)

    it("a long name with words in it is a name: shown, no issue, and it works", function()
      -- Long, mixed-case, one digit: also the shape of a pasted token, which is why
      -- a rule on those three cannot tell the two apart. What does is a vendor's
      -- key shape: hyphens, a prefix with its length, or a bare token of letters
      -- and digits -- and a name with an underscore between words is none of them.
      for _, name in ipairs({
        "Company_Anthropic_Key_Production_2",
        "Company_Anthropic_Key_Production_Account_Number_2",
        "gsk_company_groq_key_for_the_production_team_account",
        "hf_company_hugging_face_token_for_production",
        "gsk_" .. ("a"):rep(39),
        "hf_" .. ("a"):rep(33),
        ("A"):rep(40),
        ("a"):rep(40),
        "ANTHROPIC_API_KEY_COMPANY_PRODUCTION_2",
        "CompanyAnthropicKey2",
      }) do
        vim.env[name] = "long-name-key"
        local keys = setup({ claude = { active = "c", profiles = { c = { env = name } } } })
        local described, issues, key =
          keys.describe("claude"), keys.issues(), keys.get("claude", "ANTHROPIC_API_KEY")
        vim.env[name] = nil
        assert.is_truthy(described:find("env " .. name .. ", key present", 1, true))
        assert.is_nil(described:find("not a variable name", 1, true))
        assert.are.same({}, issues)
        assert.are.equal("long-name-key", key)
      end
    end)

    -- The price of the bare-token rule: the same shape written as one long
    -- CamelCase name is not echoed either (and is reported as not being a name).
    it("a 32+ character mixed-case name without an underscore is taken for a key", function()
      local name = "CompanyAnthropicKeyProductionAccount2"
      local keys = setup({ claude = { active = "c", profiles = { c = { env = name } } } })
      assert.is_nil(keys.describe("claude"):find(name, 1, true))
      assert.is_truthy(keys.describe("claude"):find("not a variable name", 1, true))
      assert.is_nil(table.concat(keys.issues(), "\n"):find(name, 1, true))
    end)

    it("39 characters alone are no key; the AIza prefix gives one away", function()
      local name = "Gemini_Key_" .. ("x"):rep(28)
      assert.are.equal(39, #name)
      local keys = setup({ gemini = { active = "g", profiles = { g = { env = name } } } })
      assert.is_truthy(keys.describe("gemini"):find("env " .. name, 1, true))
      assert.are.same({}, keys.issues())

      local token = "AIza" .. ("x"):rep(35)
      keys = setup({ gemini = { active = "g", profiles = { g = { env = token } } } })
      assert.is_nil(keys.describe("gemini"):find(token, 1, true))
      assert.is_truthy(keys.describe("gemini"):find("not a variable name", 1, true))
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
      local path = write_file("y.key", "k")
      vim.uv.fs_chmod(path, tonumber("600", 8))
      local keys = setup({
        claude = { active = "a", profiles = { a = { env = "X" }, b = { file = path } } },
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

  -- Through the public path: a provider that is unavailable *because* its chosen
  -- profile has no key must fail the request naming the profile, and "auto" must
  -- not move on to another provider (and so another account).
  describe("through providers.resolve and ai.ask", function()
    ---@param id string
    ---@param available boolean
    local function fake(id, available)
      return {
        id = id,
        available = function()
          return available
        end,
        ask = function(_, cb)
          cb(true, { text = "ok", provider = id })
        end,
      }
    end

    local function company_without_key()
      setup({
        claude = { active = "company", profiles = { company = { env = "AI_TEST_KEY_COMPANY" } } },
      })
    end

    it("an explicit provider fails with missing_api_key naming the profile", function()
      company_without_key()
      local providers = require("ai.providers")
      providers.register(fake("claude", false))
      local p, err = providers.resolve("claude", { "claude" })
      assert.is_nil(p)
      assert.are.equal("missing_api_key", err.kind)
      assert.is_truthy(err.message:find("company", 1, true))
    end)

    it("auto stops at the blocked provider instead of moving on to the next one", function()
      company_without_key()
      local providers = require("ai.providers")
      providers.register(fake("claude", false))
      providers.register(fake("second", true))
      local p, err = providers.resolve("auto", { "claude", "second" })
      assert.is_nil(p)
      assert.are.equal("missing_api_key", err.kind)
      assert.is_truthy(err.message:find("company", 1, true))
    end)

    it("auto still reaches a provider listed before the blocked one", function()
      company_without_key()
      local providers = require("ai.providers")
      providers.register(fake("claude", false))
      providers.register(fake("first", true))
      local p = providers.resolve("auto", { "first", "claude" })
      assert.are.equal("first", p.id)
    end)

    it("an unavailable provider without a profile is skipped as before", function()
      company_without_key()
      local providers = require("ai.providers")
      providers.register(fake("first", false))
      providers.register(fake("second", true))
      local p = providers.resolve("auto", { "first", "second" })
      assert.are.equal("second", p.id)
      local _, err = providers.resolve("first", { "first" })
      assert.are.equal("provider_resolution", err.kind)
    end)

    it("a present key does not block, and neither does a per-request api_key", function()
      company_without_key()
      local providers = require("ai.providers")
      local p = providers.resolve("claude", { "claude" }, { prompt = "x", api_key = "explicit" })
      assert.are.equal("claude", p.id)
      vim.env.AI_TEST_KEY_COMPANY = "now-set"
      assert.is_false(require("ai.keys").blocked("claude"))
      assert.are.equal("claude", providers.resolve("claude", { "claude" }).id)
    end)

    it("ai.ask reports it to the caller", function()
      company_without_key()
      local ok, err
      require("ai").ask({ prompt = "x", provider = "claude" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("missing_api_key", err.kind)
      assert.is_truthy(err.message:find("company", 1, true))
    end)
  end)
end)
