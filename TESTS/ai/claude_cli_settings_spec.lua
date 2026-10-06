-- A credential in the claude CLI's own settings (`apiKeyHelper`, or an API key or
-- token in the `env` block) ranks above its login and is not an environment
-- variable of the child, so ai.nvim cannot remove it: `:checkhealth ai` says that
-- the login may not be the account in use. It looks up whether the keys exist in
-- the user and the managed settings file and never reports a value or any other
-- content.
--
-- Every spec reads FIXTURE files only (a temp directory this file creates): the
-- real settings of the machine hold credential commands and are not touched, and
-- the real system directory of the managed settings is not even listed. The
-- location of the real files is tested as a computed path, never read.
---@diagnostic disable: need-check-nil, missing-fields
local VAR = "CLAUDE_CONFIG_DIR"
local RELOAD = { "ai.providers.claude_cli", "ai.providers", "ai.config", "ai.policy", "ai" }
-- A value that must never show up anywhere: it stands for a command with a secret.
local SECRET = "vault-read --token=TOPSECRET123"
-- ... and the same for a key or token in the `env` block.
local TOKEN = "sk-ant-TOPSECRET456"

describe("claude-cli: credentials in the CLI's own settings", function()
  local cli, dir, saved_env, real_managed_dir

  ---Write `content` to `name` in the fixture directory (parents created).
  ---@param name string
  ---@param content string
  ---@return string path
  local function write(name, content)
    local path = dir .. "/" .. name
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
    return path
  end

  ---@param scope string
  ---@param path string
  ---@return Ai.Providers.ClaudeCli.SettingsFile
  local function file(scope, path)
    return { scope = scope, path = path }
  end

  before_each(function()
    saved_env = vim.env[VAR] or false
    for _, name in ipairs(RELOAD) do
      package.loaded[name] = nil
    end
    cli = require("ai.providers.claude_cli")
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    -- Whatever a spec forgets to pass to settings_files(): never the real system
    -- directory (the one spec about its name calls the real resolver, which only
    -- computes a path).
    real_managed_dir = cli.managed_settings_dir
    cli.managed_settings_dir = function()
      return dir .. "/system"
    end
  end)

  after_each(function()
    vim.env[VAR] = saved_env or nil
    vim.fn.delete(dir, "rf")
    for _, name in ipairs(RELOAD) do
      package.loaded[name] = nil
    end
  end)

  describe("defines_api_key_helper(settings)", function()
    it("is true for a key with a command", function()
      assert.is_true(cli.defines_api_key_helper({ apiKeyHelper = "get-key" }))
      assert.is_true(
        cli.defines_api_key_helper({ apiKeyHelper = "~/bin/get key --x", model = "m" })
      )
      assert.is_true(cli.defines_api_key_helper(vim.json.decode('{"apiKeyHelper":"x"}')))
    end)

    it(
      "is true for any other value but null, false and the empty string: report, not guess",
      function()
        -- The documented type is a string; what else is set is a broken or
        -- unfamiliar setting, and a login that may not be in use is worth a line.
        assert.is_true(cli.defines_api_key_helper({ apiKeyHelper = true }))
        assert.is_true(cli.defines_api_key_helper({ apiKeyHelper = 1 }))
        assert.is_true(cli.defines_api_key_helper({ apiKeyHelper = { "x" } }))
        assert.is_true(cli.defines_api_key_helper({ apiKeyHelper = " " }))
      end
    )

    it("is false when the key is absent, null, false or empty", function()
      assert.is_false(cli.defines_api_key_helper({}))
      assert.is_false(cli.defines_api_key_helper({ model = "m" }))
      assert.is_false(cli.defines_api_key_helper({ apiKeyHelper = "" }))
      assert.is_false(cli.defines_api_key_helper({ apiKeyHelper = false }))
      assert.is_false(cli.defines_api_key_helper({ apiKeyHelper = vim.NIL }))
      assert.is_false(cli.defines_api_key_helper(vim.json.decode('{"apiKeyHelper":null}')))
    end)

    it("is false for anything that is not a settings object", function()
      assert.is_false(cli.defines_api_key_helper(nil))
      assert.is_false(cli.defines_api_key_helper(vim.NIL))
      assert.is_false(cli.defines_api_key_helper("apiKeyHelper"))
      assert.is_false(cli.defines_api_key_helper(true))
      assert.is_false(cli.defines_api_key_helper(7))
      assert.is_false(cli.defines_api_key_helper({ "apiKeyHelper" }))
    end)

    it("reads the top-level key with this exact spelling and nothing nested", function()
      assert.is_false(cli.defines_api_key_helper({ apikeyhelper = "x" }))
      assert.is_false(cli.defines_api_key_helper({ ApiKeyHelper = "x" }))
      assert.is_false(cli.defines_api_key_helper({ env = { apiKeyHelper = "x" } }))
      assert.is_false(cli.defines_api_key_helper({ permissions = { allow = { "apiKeyHelper" } } }))
    end)
  end)

  describe("settings_env_credentials(settings)", function()
    ---@param env table
    ---@return string[]
    local function names(env)
      return cli.settings_env_credentials({ env = env })
    end

    it("names each key or token the env block sets", function()
      assert.are.same({ "ANTHROPIC_API_KEY" }, names({ ANTHROPIC_API_KEY = "k" }))
      assert.are.same({ "ANTHROPIC_AUTH_TOKEN" }, names({ ANTHROPIC_AUTH_TOKEN = "t" }))
      assert.are.same({ "CLAUDE_CODE_OAUTH_TOKEN" }, names({ CLAUDE_CODE_OAUTH_TOKEN = "o" }))
      assert.are.same(
        { "ANTHROPIC_API_KEY" },
        cli.settings_env_credentials(vim.json.decode('{"env":{"ANTHROPIC_API_KEY":"k"}}'))
      )
    end)

    it("lists them in a fixed order, whatever the order in the file", function()
      assert.are.same(
        { "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN" },
        names({
          CLAUDE_CODE_OAUTH_TOKEN = "c",
          OTHER = "x",
          ANTHROPIC_AUTH_TOKEN = "b",
          ANTHROPIC_API_KEY = "a",
        })
      )
    end)

    it("counts a null, false or empty value as unset, any other value as set", function()
      for _, unset in ipairs({ vim.NIL, false, "" }) do
        assert.are.same({}, names({ ANTHROPIC_API_KEY = unset }))
      end
      assert.are.same(
        {},
        cli.settings_env_credentials(vim.json.decode('{"env":{"ANTHROPIC_API_KEY":null}}'))
      )
      -- The documented type is a string; what else is set is a broken or unfamiliar
      -- value, and a login that may not be in use is worth a line.
      for _, set in ipairs({ true, 1, " ", { "x" } }) do
        assert.are.same({ "ANTHROPIC_API_KEY" }, names({ ANTHROPIC_API_KEY = set }))
      end
    end)

    it("matches the exact variable names, nothing that merely contains one", function()
      assert.are.same(
        {},
        names({
          ANTHROPIC_BASE_URL = "https://gateway.example",
          ANTHROPIC_API_KEY_FILE = "x",
          ANTHROPIC_API_KEY2 = "x",
          MY_ANTHROPIC_API_KEY = "x",
          CLAUDE_CODE_OAUTH_REFRESH_TOKEN = "x",
          CLAUDE_CODE_OAUTH = "x",
        })
      )
    end)

    it("ignores the case of the name, as the process environment of Windows does", function()
      assert.are.same({ "ANTHROPIC_API_KEY" }, names({ anthropic_api_key = "k" }))
      assert.are.same({ "CLAUDE_CODE_OAUTH_TOKEN" }, names({ Claude_Code_Oauth_Token = "t" }))
      -- Always the canonical name out of the fixed list, never the spelling of the file.
      assert.are.same(
        { "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN" },
        names({ anthropic_api_key = TOKEN, Anthropic_Auth_Token = TOKEN })
      )
    end)

    it("reads the top-level env block with this exact spelling and nothing nested", function()
      assert.are.same({}, cli.settings_env_credentials({ ANTHROPIC_API_KEY = "k" }))
      assert.are.same({}, cli.settings_env_credentials({ Env = { ANTHROPIC_API_KEY = "k" } }))
      assert.are.same(
        {},
        cli.settings_env_credentials({ permissions = { env = { ANTHROPIC_API_KEY = "k" } } })
      )
      assert.are.same({}, names({ nested = { ANTHROPIC_API_KEY = "k" } }))
    end)

    it("is empty for an env that is no object, and for no settings object", function()
      for _, bad in ipairs({ "ANTHROPIC_API_KEY", 1, true, false, vim.NIL, { "ANTHROPIC_API_KEY" } }) do
        assert.are.same({}, cli.settings_env_credentials({ env = bad }), vim.inspect(bad))
      end
      assert.are.same({}, cli.settings_env_credentials({}))
      for _, bad in ipairs({ "env", 7, true, vim.NIL, { "env" } }) do
        assert.are.same({}, cli.settings_env_credentials(bad), vim.inspect(bad))
      end
      assert.are.same({}, cli.settings_env_credentials(nil))
    end)

    it("returns the names and nothing of the file", function()
      local result = names({ ANTHROPIC_API_KEY = TOKEN, ANTHROPIC_AUTH_TOKEN = TOKEN, X = "NOTE" })
      assert.are.same({ "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN" }, result)
      for _, leaked in ipairs({ "TOPSECRET", "sk-ant", "NOTE" }) do
        assert.is_nil(vim.inspect(result):find(leaked, 1, true), leaked)
      end
    end)
  end)

  describe("api_key_helper_scopes(files)", function()
    it("names the layer of a file that defines it", function()
      local user = write("user.json", ('{"apiKeyHelper":"%s"}'):format(SECRET))
      assert.are.same({ "user" }, cli.api_key_helper_scopes({ file("user", user) }))
      local managed = write("managed.json", '{"apiKeyHelper":"x"}')
      assert.are.same({ "managed" }, cli.api_key_helper_scopes({ file("managed", managed) }))
    end)

    it("is empty when no file defines it, and for no file at all", function()
      local plain = write("plain.json", '{"model":"opus","permissions":{"allow":[]}}')
      assert.are.same({}, cli.api_key_helper_scopes({ file("user", plain) }))
      assert.are.same({}, cli.api_key_helper_scopes({}))
    end)

    it("names every layer once, in the order of the files", function()
      local yes = write("yes.json", '{"apiKeyHelper":"x"}')
      local no = write("no.json", "{}")
      assert.are.same(
        { "user", "managed" },
        cli.api_key_helper_scopes({
          file("user", yes),
          file("managed", no),
          file("managed", yes),
          file("managed", yes),
          file("user", yes),
        })
      )
      assert.are.same(
        { "managed" },
        cli.api_key_helper_scopes({ file("managed", yes), file("managed", yes) })
      )
    end)

    it("reads a file with a UTF-8 byte-order mark (PowerShell writes one)", function()
      local path = write("bom.json", '\239\187\191{"apiKeyHelper":"x"}')
      assert.are.same({ "user" }, cli.api_key_helper_scopes({ file("user", path) }))
    end)

    it("counts a file that is missing, empty, not JSON or no object as 'no'", function()
      local files = {
        file("user", dir .. "/missing.json"),
        file("user", write("empty.json", "")),
        file("user", write("garbage.json", '{"apiKeyHelper": "x"')), -- cut off
        file("user", write("text.json", "apiKeyHelper")),
        file("user", write("list.json", '["apiKeyHelper"]')),
        file("user", write("scalar.json", '"apiKeyHelper"')),
        file("user", write("null.json", "null")),
        file("user", write("utf16.json", '\255\254{\0"\0a\0')),
      }
      for _, f in ipairs(files) do
        assert.are.same({}, cli.api_key_helper_scopes({ f }), f.path)
      end
    end)

    it("counts a null, false or empty key as 'no'", function()
      for i, body in ipairs({
        '{"apiKeyHelper":null}',
        '{"apiKeyHelper":false}',
        '{"apiKeyHelper":""}',
      }) do
        local path = write(("unset%d.json"):format(i), body)
        assert.are.same({}, cli.api_key_helper_scopes({ file("user", path) }), body)
      end
    end)

    it("does not read a directory, and keeps going after an unreadable entry", function()
      vim.fn.mkdir(dir .. "/a-directory.json", "p")
      local yes = write("yes.json", '{"apiKeyHelper":"x"}')
      assert.are.same(
        { "managed" },
        cli.api_key_helper_scopes({
          file("user", dir .. "/a-directory.json"),
          file("user", dir .. "/missing.json"),
          file("managed", yes),
        })
      )
    end)

    it("does not read a file above the bound (1 MiB): it is no settings file", function()
      local pad = ('"pad":"%s"'):format(("x"):rep(1024 * 1024))
      local big = write("big.json", '{"apiKeyHelper":"x",' .. pad .. "}")
      assert.are.same({}, cli.api_key_helper_scopes({ file("user", big) }))
      local fits =
        write("fits.json", '{"apiKeyHelper":"x","pad":"' .. ("x"):rep(500 * 1024) .. '"}')
      assert.are.same({ "user" }, cli.api_key_helper_scopes({ file("user", fits) }))
    end)

    it("reports nothing but the layer: no value, no path, no content", function()
      local path =
        write("secret.json", ('{"apiKeyHelper":"%s","note":"PRIVATE-NOTE"}'):format(SECRET))
      local scopes = cli.api_key_helper_scopes({ file("user", path) })
      local text = vim.inspect(scopes)
      assert.are.same({ "user" }, scopes)
      for _, leaked in ipairs({ "TOPSECRET", "vault-read", "PRIVATE-NOTE", dir, "secret.json" }) do
        assert.is_nil(text:find(leaked, 1, true), leaked)
      end
    end)

    it("answers quickly for a settings file of a few hundred kB", function()
      local body = '{"apiKeyHelper":"x","hooks":['
        .. ('{"a":[1,2,3],"b":"c"},'):rep(20000)
        .. "{}]}"
      local path = write("large.json", body)
      local t0 = vim.uv.hrtime()
      local scopes = cli.api_key_helper_scopes({ file("user", path) })
      local ms = (vim.uv.hrtime() - t0) / 1e6
      assert.are.same({ "user" }, scopes)
      assert.is_true(ms < 1000, ("%d ms for %d bytes"):format(ms, #body))
    end)

    it("is read live: a file written later shows up without a reload", function()
      local path = dir .. "/later.json"
      local files = { file("user", path) }
      assert.are.same({}, cli.api_key_helper_scopes(files))
      write("later.json", '{"apiKeyHelper":"x"}')
      assert.are.same({ "user" }, cli.api_key_helper_scopes(files))
      write("later.json", "{}")
      assert.are.same({}, cli.api_key_helper_scopes(files))
    end)
  end)

  describe("settings_credentials(files)", function()
    local NONE = { api_key_helper = {}, env = {}, env_names = {} }

    it("names the layer and the variables of an env block that sets a credential", function()
      local user = write("user.json", ('{"env":{"ANTHROPIC_API_KEY":"%s"}}'):format(TOKEN))
      assert.are.same(
        { api_key_helper = {}, env = { "user" }, env_names = { "ANTHROPIC_API_KEY" } },
        cli.settings_credentials({ file("user", user) })
      )
      local managed = write("managed.json", '{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"x"}}')
      assert.are.same(
        { api_key_helper = {}, env = { "managed" }, env_names = { "CLAUDE_CODE_OAUTH_TOKEN" } },
        cli.settings_credentials({ file("managed", managed) })
      )
    end)

    it("is empty for no file, and when no file defines either", function()
      assert.are.same(NONE, cli.settings_credentials({}))
      local plain = write("plain.json", '{"model":"opus","env":{"ANTHROPIC_BASE_URL":"https://x"}}')
      assert.are.same(NONE, cli.settings_credentials({ file("user", plain) }))
    end)

    it("keeps the helper and the env block apart", function()
      local helper = write("helper.json", '{"apiKeyHelper":"x"}')
      local env = write("env.json", '{"env":{"ANTHROPIC_AUTH_TOKEN":"x"}}')
      local both = write("both.json", '{"apiKeyHelper":"x","env":{"ANTHROPIC_AUTH_TOKEN":"x"}}')
      assert.are.same(
        { api_key_helper = { "user" }, env = {}, env_names = {} },
        cli.settings_credentials({ file("user", helper) })
      )
      assert.are.same(
        { api_key_helper = {}, env = { "user" }, env_names = { "ANTHROPIC_AUTH_TOKEN" } },
        cli.settings_credentials({ file("user", env) })
      )
      assert.are.same(
        { api_key_helper = { "user" }, env = { "user" }, env_names = { "ANTHROPIC_AUTH_TOKEN" } },
        cli.settings_credentials({ file("user", both) })
      )
      assert.are.same(
        { api_key_helper = { "managed" }, env = { "user" }, env_names = { "ANTHROPIC_AUTH_TOKEN" } },
        cli.settings_credentials({ file("user", env), file("managed", helper) })
      )
    end)

    it("names every layer once, in the order of the files, and every variable once", function()
      local a = write("a.json", '{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"x"}}')
      local b = write("b.json", '{"env":{"ANTHROPIC_AUTH_TOKEN":"x"}}')
      local c = write("c.json", '{"env":{"ANTHROPIC_API_KEY":"x","ANTHROPIC_AUTH_TOKEN":"y"}}')
      assert.are.same(
        {
          api_key_helper = {},
          env = { "user", "managed" },
          env_names = { "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN" },
        },
        cli.settings_credentials({
          file("user", a),
          file("managed", b),
          file("managed", c),
          file("user", c),
        })
      )
    end)

    it("does not look past a layer that is already named", function()
      -- The first managed file names the layer; the variable of a later one still counts.
      local first = write("first.json", '{"apiKeyHelper":"x","env":{"ANTHROPIC_API_KEY":"x"}}')
      local later = write("later.json", '{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"x"}}')
      assert.are.same({
        api_key_helper = { "managed" },
        env = { "managed" },
        env_names = { "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN" },
      }, cli.settings_credentials({ file("managed", first), file("managed", later) }))
    end)

    it(
      "reads a file with a byte-order mark, and counts what is no settings file as 'no'",
      function()
        local bom = write("bom.json", '\239\187\191{"env":{"ANTHROPIC_API_KEY":"x"}}')
        assert.are.same({ "user" }, cli.settings_credentials({ file("user", bom) }).env)
        vim.fn.mkdir(dir .. "/a-directory.json", "p")
        local files = {
          file("user", dir .. "/a-directory.json"),
          file("user", dir .. "/missing.json"),
          file("user", write("empty.json", "")),
          file("user", write("cut.json", '{"env":{"ANTHROPIC_API_KEY":"x"')),
          file("user", write("list.json", '["env"]')),
          file("user", write("scalar.json", '"env"')),
          file("user", write("null.json", "null")),
          file("user", write("env-text.json", "env ANTHROPIC_API_KEY")),
        }
        for _, f in ipairs(files) do
          assert.are.same(NONE, cli.settings_credentials({ f }), f.path)
        end
        -- ... and the loop goes on past them.
        table.insert(files, file("managed", write("ok.json", '{"env":{"ANTHROPIC_API_KEY":"x"}}')))
        assert.are.same({ "managed" }, cli.settings_credentials(files).env)
      end
    )

    it("does not read a file above the bound (1 MiB): it is no settings file", function()
      local pad = ('"pad":"%s"'):format(("x"):rep(1024 * 1024))
      local big = write("big.json", '{"env":{"ANTHROPIC_API_KEY":"x"},' .. pad .. "}")
      assert.are.same(NONE, cli.settings_credentials({ file("user", big) }))
    end)

    it("counts a null, false or empty variable as 'no' in a file", function()
      for i, body in ipairs({
        '{"env":{"ANTHROPIC_API_KEY":null}}',
        '{"env":{"ANTHROPIC_API_KEY":false}}',
        '{"env":{"ANTHROPIC_API_KEY":""}}',
        '{"env":null}',
        '{"env":[]}',
      }) do
        local path = write(("unset%d.json"):format(i), body)
        assert.are.same(NONE, cli.settings_credentials({ file("user", path) }), body)
      end
    end)

    it("reports nothing but layers and variable names: no value, no path, no content", function()
      local path = write(
        "secret.json",
        ('{"apiKeyHelper":"%s","env":{"ANTHROPIC_API_KEY":"%s","X":"PRIVATE-ENV"},"note":"PRIVATE-NOTE"}'):format(
          SECRET,
          TOKEN
        )
      )
      local found = cli.settings_credentials({ file("user", path) })
      assert.are.same("user", found.env[1])
      local text = vim.inspect(found)
      for _, leaked in ipairs({
        "TOPSECRET",
        "vault-read",
        "sk-ant",
        "PRIVATE",
        '"X"',
        dir,
        "secret.json",
      }) do
        assert.is_nil(text:find(leaked, 1, true), leaked)
      end
    end)

    it("reads each file once", function()
      local reads = {}
      local real_read = require("lib.nvim.fs.read")
      package.loaded["lib.nvim.fs.read"] = function(path)
        reads[#reads + 1] = path
        return real_read(path)
      end
      package.loaded["ai.providers.claude_cli"] = nil
      local ok, err = pcall(function()
        local counting = require("ai.providers.claude_cli")
        local path = write("once.json", '{"apiKeyHelper":"x","env":{"ANTHROPIC_API_KEY":"x"}}')
        local found = counting.settings_credentials({ file("user", path) })
        assert.are.same({ "user" }, found.api_key_helper)
        assert.are.same({ "user" }, found.env)
      end)
      package.loaded["lib.nvim.fs.read"] = real_read
      package.loaded["ai.providers.claude_cli"] = nil
      assert(ok, err)
      assert.are.equal(1, #reads, "one read for two questions")
    end)

    it("answers quickly for an env block of 120 kB, of 800 kB, and for one huge name", function()
      ---@param entries integer
      ---@return string
      local function body(entries)
        local parts = {}
        for i = 1, entries do
          parts[i] = ('"VAR_%d":"value-%d"'):format(i, i)
        end
        return '{"env":{' .. table.concat(parts, ",") .. ',"anthropic_api_key":"k"}}'
      end
      local cases = {
        { "120 kB", body(5000) },
        { "800 kB", body(32000) },
        { "one name", '{"env":{"' .. ("A"):rep(900 * 1024) .. '":"x","ANTHROPIC_API_KEY":"k"}}' },
      }
      for _, case in ipairs(cases) do
        local path = write("perf.json", case[2])
        local t0 = vim.uv.hrtime()
        local found = cli.settings_credentials({ file("user", path) })
        local ms = (vim.uv.hrtime() - t0) / 1e6
        assert.are.same({ "user" }, found.env, case[1])
        assert.is_true(ms < 1000, ("%s: %d ms for %d bytes"):format(case[1], ms, #case[2]))
      end
    end)

    it("api_key_helper_scopes() is its helper part", function()
      local path = write("scopes.json", '{"apiKeyHelper":"x","env":{"ANTHROPIC_API_KEY":"x"}}')
      assert.are.same({ "user" }, cli.api_key_helper_scopes({ file("user", path) }))
      local env_only = write("env-only.json", '{"env":{"ANTHROPIC_API_KEY":"x"}}')
      assert.are.same({}, cli.api_key_helper_scopes({ file("user", env_only) }))
    end)
  end)

  describe("settings_files()", function()
    ---@param path string
    ---@return string
    local function norm(path)
      return vim.fs.normalize(path)
    end

    it("puts the user file in CLAUDE_CONFIG_DIR when that is set", function()
      vim.env[VAR] = dir
      local files = cli.settings_files({ managed_dir = dir .. "/system" })
      assert.are.equal("user", files[1].scope)
      assert.are.equal(norm(dir .. "/settings.json"), norm(files[1].path))
    end)

    it("trims the variable, and ignores an empty one", function()
      vim.env[VAR] = "  " .. dir .. "  \n"
      assert.are.equal(
        norm(dir .. "/settings.json"),
        norm(cli.settings_files({ managed_dir = dir .. "/system" })[1].path)
      )
      vim.env[VAR] = "  "
      local home = vim.uv.os_homedir()
      assert.are.equal(
        norm(home .. "/.claude/settings.json"),
        norm(cli.settings_files({ managed_dir = dir .. "/system" })[1].path)
      )
    end)

    it("falls back to .claude in the home directory, as the CLI does", function()
      vim.env[VAR] = nil
      local files = cli.settings_files({ managed_dir = dir .. "/system" })
      assert.are.equal("user", files[1].scope)
      assert.are.equal(norm(vim.uv.os_homedir() .. "/.claude/settings.json"), norm(files[1].path))
    end)

    it("adds managed-settings.json of the system directory", function()
      vim.env[VAR] = dir .. "/config"
      local files = cli.settings_files({ managed_dir = dir .. "/system" })
      assert.are.equal(2, #files)
      assert.are.equal("managed", files[2].scope)
      assert.are.equal(norm(dir .. "/system/managed-settings.json"), norm(files[2].path))
    end)

    it("takes the system directory from managed_settings_dir() unless told otherwise", function()
      vim.env[VAR] = dir .. "/config"
      write("system/managed-settings.d/10-a.json", "{}")
      write("elsewhere/managed-settings.d/10-b.json", "{}")
      -- No opts: the (fixture) directory the resolver names, drop-ins included.
      local files = cli.settings_files()
      assert.are.equal("managed", files[2].scope)
      assert.are.equal(norm(dir .. "/system/managed-settings.json"), norm(files[2].path))
      assert.are.equal(norm(dir .. "/system/managed-settings.d/10-a.json"), norm(files[3].path))
      -- opts.managed_dir wins over it.
      files = cli.settings_files({ managed_dir = dir .. "/elsewhere" })
      assert.are.equal(norm(dir .. "/elsewhere/managed-settings.json"), norm(files[2].path))
      assert.are.equal(norm(dir .. "/elsewhere/managed-settings.d/10-b.json"), norm(files[3].path))
    end)

    describe("managed_settings_dir(platform)", function()
      it("knows the documented system directory of each platform", function()
        -- Pure: only the path is computed, nothing is listed or read.
        local resolve = real_managed_dir
        assert.are.equal("C:/Program Files/ClaudeCode", resolve({ is_windows = true }))
        assert.are.equal("/Library/Application Support/ClaudeCode", resolve({ is_macos = true }))
        assert.are.equal("/etc/claude-code", resolve({}))
        assert.are.equal("/etc/claude-code", resolve({ is_windows = false, is_macos = false }))
      end)

      it("uses the running platform when none is given", function()
        local env = require("lib.nvim.system.env").get()
        assert.are.equal(
          real_managed_dir({ is_windows = env.is_windows, is_macos = env.is_macos }),
          real_managed_dir()
        )
      end)
    end)

    it("lists the *.json drop-ins of managed-settings.d, sorted, without hidden files", function()
      vim.env[VAR] = dir .. "/config"
      write("system/managed-settings.d/20-b.json", "{}")
      write("system/managed-settings.d/10-a.json", "{}")
      write("system/managed-settings.d/.hidden.json", "{}")
      write("system/managed-settings.d/notes.txt", "x")
      write("system/managed-settings.d/30-c.JSON.bak", "{}")
      local files = cli.settings_files({ managed_dir = dir .. "/system" })
      local names = {}
      for _, f in ipairs(files) do
        assert.are.equal(f.scope == "user" and "user" or "managed", f.scope)
        names[#names + 1] = vim.fs.basename(f.path)
      end
      assert.are.same({ "settings.json", "managed-settings.json", "10-a.json", "20-b.json" }, names)
    end)

    it("copes with a managed-settings.d that is missing or a plain file", function()
      vim.env[VAR] = dir .. "/config"
      assert.are.equal(2, #cli.settings_files({ managed_dir = dir .. "/system" }))
      write("system/managed-settings.d", "not a directory")
      assert.are.equal(2, #cli.settings_files({ managed_dir = dir .. "/system" }))
    end)

    it("finds a helper defined in a drop-in, as a managed one", function()
      vim.env[VAR] = dir .. "/config"
      write("system/managed-settings.json", "{}")
      write("system/managed-settings.d/10-auth.json", '{"apiKeyHelper":"x"}')
      write("config/settings.json", "{}")
      local files = cli.settings_files({ managed_dir = dir .. "/system" })
      assert.are.same({ "managed" }, cli.api_key_helper_scopes(files))
    end)

    it("does not include project settings: the child runs in a neutral directory", function()
      vim.env[VAR] = dir .. "/config"
      local cwd = norm(vim.fn.getcwd())
      for _, f in ipairs(cli.settings_files({ managed_dir = dir .. "/system" })) do
        assert.is_nil(norm(f.path):find("settings.local.json", 1, true), f.path)
        assert.is_false(vim.startswith(norm(f.path), cwd .. "/"), f.path)
      end
    end)
  end)

  describe(":checkhealth ai", function()
    local report, saved, user_file, managed_file

    before_each(function()
      report, saved = {}, {}
      for _, fn in ipairs({ "start", "ok", "info", "warn", "error" }) do
        saved[fn] = vim.health[fn]
        vim.health[fn] = function(msg, advice)
          report[#report + 1] = { level = fn, msg = tostring(msg), advice = advice }
        end
      end
      require("ai.config").setup({})
      package.loaded["ai.health"] = nil
      -- The CLI is "installed": the test Neovim stands in for `claude`.
      cli.command = { vim.v.progpath }
      user_file = write("user/settings.json", "{}")
      managed_file = write("system/managed-settings.json", "{}")
      -- Fixtures instead of the real files (see the header).
      cli.settings_files = function()
        return { file("user", user_file), file("managed", managed_file) }
      end
    end)

    after_each(function()
      for fn, original in pairs(saved) do
        vim.health[fn] = original
      end
      package.loaded["ai.health"] = nil
    end)

    ---@param opts? table
    local function check(opts)
      report = {}
      require("ai.config").setup(opts or {})
      package.loaded["ai.health"] = nil
      require("ai.health").check()
    end

    ---@param level string
    ---@param needle string
    ---@return integer|nil index
    local function find(level, needle)
      for i, entry in ipairs(report) do
        if entry.level == level and entry.msg:find(needle, 1, true) then
          return i
        end
      end
    end

    ---@return table<string, integer>
    local function starts()
      local out = {}
      for i, entry in ipairs(report) do
        if entry.level == "start" then
          out[entry.msg] = i
        end
      end
      return out
    end

    it("says nothing about apiKeyHelper when no settings file defines it", function()
      check()
      for _, entry in ipairs(report) do
        assert.is_nil(entry.msg:find("apiKeyHelper", 1, true), entry.msg)
        assert.is_nil(table.concat(entry.advice or {}, " "):find("apiKeyHelper", 1, true))
      end
    end)

    it("warns, under the claude-cli entry, when the user settings define it", function()
      write("user/settings.json", ('{"apiKeyHelper":"%s"}'):format(SECRET))
      check()
      local warn = assert(find("warn", "apiKeyHelper"), "no warning")
      local msg = report[warn].msg
      assert.is_truthy(msg:find("user settings", 1, true), msg)
      assert.is_nil(msg:find("managed", 1, true), msg)
      assert.is_truthy(msg:find("ranks above", 1, true), msg)
      assert.is_truthy(msg:find("another account", 1, true), msg)
      assert.is_truthy(
        type(report[warn].advice) == "table" and #report[warn].advice > 0,
        "a warning says what to do about it"
      )
      local heads = starts()
      assert.is_true(warn > heads["ai.nvim: providers"], "after the providers heading")
      assert.is_true(warn < heads["ai.nvim: configuration"], "before the next section")
      local provider_line = find("ok", "claude-cli: available")
        or find("info", "claude-cli: not available")
      assert.is_truthy(provider_line, "no claude-cli line in the providers section")
      assert.is_true(warn > provider_line, "under the claude-cli entry")
    end)

    it("names the managed settings, or both layers", function()
      write("system/managed-settings.json", '{"apiKeyHelper":"x"}')
      check()
      local only = report[assert(find("warn", "apiKeyHelper"))].msg
      assert.is_truthy(only:find("managed settings", 1, true), only)
      assert.is_nil(only:find("user", 1, true), only)
      write("user/settings.json", '{"apiKeyHelper":"x"}')
      check()
      local both = report[assert(find("warn", "apiKeyHelper"))].msg
      assert.is_truthy(both:find("user and managed settings", 1, true), both)
    end)

    it("is one entry however many files define it", function()
      write("user/settings.json", '{"apiKeyHelper":"x"}')
      write("system/managed-settings.json", '{"apiKeyHelper":"y"}')
      cli.settings_files = function()
        return {
          file("user", user_file),
          file("managed", managed_file),
          file("managed", managed_file),
        }
      end
      check()
      local count = 0
      for _, entry in ipairs(report) do
        if entry.msg:find("apiKeyHelper", 1, true) then
          count = count + 1
        end
      end
      assert.are.equal(1, count)
    end)

    it("never prints the value, the file's path or any other content", function()
      write(
        "user/settings.json",
        ('{"apiKeyHelper":"%s","env":{"X":"PRIVATE-ENV"},"note":"PRIVATE-NOTE"}'):format(SECRET)
      )
      check()
      assert.is_truthy(find("warn", "apiKeyHelper"))
      for _, entry in ipairs(report) do
        local text = entry.msg .. " " .. table.concat(entry.advice or {}, " ")
        for _, leaked in ipairs({ "TOPSECRET", "vault-read", "PRIVATE-ENV", "PRIVATE-NOTE" }) do
          assert.is_nil(text:find(leaked, 1, true), leaked .. " leaked into: " .. entry.msg)
        end
        -- The entry about the helper names the layer, not the file.
        if entry.msg:find("apiKeyHelper", 1, true) then
          for _, leaked in ipairs({ ".json", dir, vim.fs.normalize(dir) }) do
            assert.is_nil(text:find(leaked, 1, true), leaked .. " leaked into: " .. entry.msg)
          end
        end
      end
    end)

    it("is a warning when the CLI is installed, an info line when it is not in sight", function()
      write("user/settings.json", '{"apiKeyHelper":"x"}')
      check()
      assert.is_truthy(find("warn", "apiKeyHelper"))
      assert.is_nil(find("info", "apiKeyHelper"))
      cli.command = { "definitely-not-a-claude-binary-xyz" }
      check()
      assert.is_nil(find("ok", "claude-cli: available"))
      local at = assert(find("info", "apiKeyHelper"), "no info line")
      assert.is_nil(find("warn", "apiKeyHelper"), "not a warning")
      assert.is_true(at > find("info", "claude-cli: not available"), "still under claude-cli")
    end)

    for label, opts in pairs({
      ["the provider"] = { provider = "claude-cli" },
      ["in provider_order"] = { provider_order = { "claude", "claude-cli" } },
      ["the completion's provider"] = { completion = { provider = "claude-cli" } },
    }) do
      it(("is a warning when claude-cli is %s, installed or not"):format(label), function()
        write("user/settings.json", '{"apiKeyHelper":"x"}')
        cli.command = { "definitely-not-a-claude-binary-xyz" }
        check(opts)
        assert.is_truthy(find("warn", "apiKeyHelper"))
        assert.is_nil(find("info", "apiKeyHelper"))
      end)
    end

    it("is reported next to the gateway note, as its own entry", function()
      local saved_url = vim.env.ANTHROPIC_BASE_URL or false
      vim.env.ANTHROPIC_BASE_URL = "https://gateway.corp.example:8443/v1"
      write("user/settings.json", '{"apiKeyHelper":"x"}')
      local ok, err = pcall(check)
      vim.env.ANTHROPIC_BASE_URL = saved_url or nil
      assert(ok, err)
      local gateway = assert(find("warn", "gateway.corp.example:8443"))
      local helper = assert(find("warn", "apiKeyHelper"))
      assert.are_not.equal(gateway, helper)
    end)

    it("looks at the settings files once per check", function()
      write("user/settings.json", '{"apiKeyHelper":"x","env":{"ANTHROPIC_API_KEY":"x"}}')
      local calls = 0
      cli.settings_files = function()
        calls = calls + 1
        return { file("user", user_file) }
      end
      check()
      assert.are.equal(1, calls, "once per check")
    end)

    describe("an API key or token in the env block of the settings", function()
      ---@param level? string
      ---@return integer|nil index
      local function env_entry(level)
        return find(level or "warn", "env block")
      end

      it("says nothing when no env block sets one", function()
        write(
          "user/settings.json",
          '{"env":{"ANTHROPIC_BASE_URL":"https://x","MY_ANTHROPIC_API_KEY":"x","ANTHROPIC_API_KEY":""}}'
        )
        write("system/managed-settings.json", '{"env":null}')
        check()
        for _, entry in ipairs(report) do
          assert.is_nil(entry.msg:find("env block", 1, true), entry.msg)
          assert.is_nil(table.concat(entry.advice or {}, " "):find("env block", 1, true))
        end
      end)

      it("warns, under the claude-cli entry, naming the layer and the variable", function()
        write("user/settings.json", ('{"env":{"ANTHROPIC_API_KEY":"%s"}}'):format(TOKEN))
        check()
        local warn = assert(env_entry(), "no warning")
        local msg = report[warn].msg
        assert.is_truthy(msg:find("user settings", 1, true), msg)
        assert.is_nil(msg:find("managed", 1, true), msg)
        assert.is_truthy(msg:find("ANTHROPIC_API_KEY", 1, true), msg)
        assert.is_truthy(msg:find("override its login", 1, true), msg)
        assert.is_truthy(msg:find("another account", 1, true), msg)
        assert.is_truthy(
          type(report[warn].advice) == "table" and #report[warn].advice > 0,
          "a warning says what to do about it"
        )
        -- It is not the apiKeyHelper entry.
        assert.is_nil(msg:find("apiKeyHelper", 1, true), msg)
        assert.is_nil(find("warn", "apiKeyHelper"))
        local heads = starts()
        assert.is_true(warn > heads["ai.nvim: providers"], "after the providers heading")
        assert.is_true(warn < heads["ai.nvim: configuration"], "before the next section")
        local provider_line = find("ok", "claude-cli: available")
          or find("info", "claude-cli: not available")
        assert.is_truthy(provider_line, "no claude-cli line in the providers section")
        assert.is_true(warn > provider_line, "under the claude-cli entry")
      end)

      it("names the managed settings, or both layers, and every variable once", function()
        write("system/managed-settings.json", '{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"x"}}')
        check()
        local only = report[assert(env_entry())].msg
        assert.is_truthy(only:find("managed settings", 1, true), only)
        assert.is_nil(only:find("user", 1, true), only)
        assert.is_truthy(only:find("CLAUDE_CODE_OAUTH_TOKEN", 1, true), only)
        write(
          "user/settings.json",
          '{"env":{"ANTHROPIC_AUTH_TOKEN":"x","CLAUDE_CODE_OAUTH_TOKEN":"y"}}'
        )
        check()
        local both = report[assert(env_entry())].msg
        assert.is_truthy(both:find("user and managed settings", 1, true), both)
        assert.is_truthy(both:find("ANTHROPIC_AUTH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN", 1, true), both)
        local _, count = both:gsub("CLAUDE_CODE_OAUTH_TOKEN", "")
        assert.are.equal(1, count, both)
      end)

      it("is one entry however many files set it", function()
        write("user/settings.json", '{"env":{"ANTHROPIC_API_KEY":"x"}}')
        write("system/managed-settings.json", '{"env":{"ANTHROPIC_API_KEY":"y"}}')
        cli.settings_files = function()
          return {
            file("user", user_file),
            file("managed", managed_file),
            file("managed", managed_file),
          }
        end
        check()
        local count = 0
        for _, entry in ipairs(report) do
          if entry.msg:find("env block", 1, true) then
            count = count + 1
          end
        end
        assert.are.equal(1, count)
      end)

      it("is a second entry next to the apiKeyHelper one when a file defines both", function()
        write(
          "user/settings.json",
          ('{"apiKeyHelper":"%s","env":{"ANTHROPIC_API_KEY":"%s"}}'):format(SECRET, TOKEN)
        )
        check()
        local helper = assert(find("warn", "apiKeyHelper"))
        local env = assert(env_entry())
        assert.are_not.equal(helper, env)
        assert.is_nil(report[env].msg:find("apiKeyHelper", 1, true))
        assert.is_nil(report[helper].msg:find("env block", 1, true))
      end)

      it("never prints the value, the file's path or any other content", function()
        write(
          "user/settings.json",
          ('{"env":{"ANTHROPIC_API_KEY":"%s","X":"PRIVATE-ENV"},"note":"PRIVATE-NOTE"}'):format(
            TOKEN
          )
        )
        check()
        assert.is_truthy(env_entry())
        for _, entry in ipairs(report) do
          local text = entry.msg .. " " .. table.concat(entry.advice or {}, " ")
          for _, leaked in ipairs({ "TOPSECRET", "sk-ant", "PRIVATE-ENV", "PRIVATE-NOTE" }) do
            assert.is_nil(text:find(leaked, 1, true), leaked .. " leaked into: " .. entry.msg)
          end
          if entry.msg:find("env block", 1, true) then
            for _, leaked in ipairs({ ".json", dir, vim.fs.normalize(dir) }) do
              assert.is_nil(text:find(leaked, 1, true), leaked .. " leaked into: " .. entry.msg)
            end
          end
        end
      end)

      it("is a warning when the CLI is installed, an info line when it is not in sight", function()
        write("user/settings.json", '{"env":{"ANTHROPIC_AUTH_TOKEN":"x"}}')
        check()
        assert.is_truthy(env_entry("warn"))
        assert.is_nil(env_entry("info"))
        cli.command = { "definitely-not-a-claude-binary-xyz" }
        check()
        assert.is_nil(find("ok", "claude-cli: available"))
        local at = assert(env_entry("info"), "no info line")
        assert.is_nil(env_entry("warn"), "not a warning")
        assert.is_true(at > find("info", "claude-cli: not available"), "still under claude-cli")
      end)

      for label, opts in pairs({
        ["the provider"] = { provider = "claude-cli" },
        ["in provider_order"] = { provider_order = { "claude", "claude-cli" } },
        ["the completion's provider"] = { completion = { provider = "claude-cli" } },
      }) do
        it(("is a warning when claude-cli is %s, installed or not"):format(label), function()
          write("user/settings.json", '{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"x"}}')
          cli.command = { "definitely-not-a-claude-binary-xyz" }
          check(opts)
          assert.is_truthy(env_entry("warn"))
          assert.is_nil(env_entry("info"))
        end)
      end
    end)
  end)
end)
