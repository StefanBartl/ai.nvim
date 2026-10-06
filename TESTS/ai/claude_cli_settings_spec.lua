-- A credential in the claude CLI's own settings (`apiKeyHelper`) ranks above its
-- login and is not an environment variable, so ai.nvim cannot remove it from the
-- child: `:checkhealth ai` says that the login may not be the account in use. It
-- looks up whether the key exists in the user and the managed settings file and
-- never reports a value or any other content.
--
-- Every spec reads FIXTURE files only (a temp directory this file creates): the
-- real settings of the machine hold credential commands and are not touched. The
-- location of the real files is tested as a computed path, never read.
---@diagnostic disable: need-check-nil, missing-fields
local VAR = "CLAUDE_CONFIG_DIR"
local RELOAD = { "ai.providers.claude_cli", "ai.providers", "ai.config", "ai.policy", "ai" }
-- A value that must never show up anywhere: it stands for a command with a secret.
local SECRET = "vault-read --token=TOPSECRET123"

describe("claude-cli: apiKeyHelper in the CLI's own settings", function()
  local cli, dir, saved_env

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

    it("knows the documented system directory of this platform", function()
      vim.env[VAR] = dir .. "/config"
      local env = require("lib.nvim.system.env").get()
      local expected = (env.is_windows and "C:/Program Files/ClaudeCode")
        or (env.is_macos and "/Library/Application Support/ClaudeCode")
        or "/etc/claude-code"
      -- Only the computed path is looked at; whatever lies there is not read here.
      local files = cli.settings_files()
      assert.are.equal("managed", files[2].scope)
      assert.are.equal(norm(expected .. "/managed-settings.json"), norm(files[2].path))
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
      write("user/settings.json", '{"apiKeyHelper":"x"}')
      local calls = 0
      cli.settings_files = function()
        calls = calls + 1
        return { file("user", user_file) }
      end
      check()
      assert.are.equal(1, calls, "once per check")
    end)
  end)
end)
