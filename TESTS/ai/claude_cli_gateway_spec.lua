-- ANTHROPIC_BASE_URL is passed on to the claude CLI on purpose (a company gateway
-- may be the only way to reach the API), so it must at least be visible: with the
-- variable set, `:Ai info` and `:checkhealth ai` say which host the CLI will talk
-- to. Only the host is ever printed -- the userinfo and the query of such a URL
-- can carry a credential -- and nothing at all when the variable is unset.
---@diagnostic disable: need-check-nil, missing-fields
local VAR = "ANTHROPIC_BASE_URL"
local RELOAD = { "ai.providers.claude_cli", "ai.providers", "ai.config", "ai.policy", "ai" }
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

---The shapes that made a pattern for the host take quadratic time (a digit run is
---part of the name class AND of the port, a long userinfo is retried from every
---start), plus the long scheme, the IPv6 forms and high bytes, each about `n`
---bytes. `host` is what the URL's authority reads as when nothing bounds the
---value, `nil` for "no host that is printed".
---@param n integer even
---@return { url: string, host: string|nil }[]
local function hostile_shapes(n)
  local digits = ("1"):rep(n)
  local half = ("1"):rep(n / 2)
  return {
    { url = "https://" .. ("a"):rep(n) .. "@host.example/", host = "host.example" },
    { url = "https://" .. ("a@"):rep(n / 2) .. "host.example", host = "host.example" },
    { url = "https://" .. ("a"):rep(n) .. ":b" },
    { url = "https://" .. ("a"):rep(n) },
    { url = "https://" .. ("@"):rep(n) },
    { url = "https://" .. ("a:"):rep(n / 2) },
    { url = "https://h.example/" .. ("p"):rep(n), host = "h.example" },
    { url = "https://h.example/?" .. ("q="):rep(n / 2), host = "h.example" },
    -- A long scheme, with and without the `://` behind it.
    { url = ("a"):rep(n) .. "://host.example/", host = "host.example" },
    { url = ("a+"):rep(n / 2) .. "://host.example/", host = "host.example" },
    { url = ("a"):rep(n) },
    { url = ("a:"):rep(n / 2) },
    -- Digit runs followed by a byte outside the name class and outside the port.
    { url = "https://host.example:" .. digits },
    { url = "https://" .. digits .. "!" },
    { url = "https://" .. digits .. ":!" },
    { url = "https://" .. digits .. "%" },
    { url = "https://" .. digits .. " x" },
    { url = "https://" .. half .. ":" .. half .. "!" },
    { url = "https://" .. ("1."):rep(n / 2) .. ":!" },
    -- IPv6 literals: a long run inside the brackets, behind them, or unclosed.
    { url = "https://[" .. (":"):rep(n) .. "]" .. digits },
    { url = "https://[" .. digits .. "]" .. digits .. "!" },
    { url = "https://[" .. ("1:"):rep(n / 2) .. "]:" .. half .. "!" },
    { url = "https://[" .. digits },
    -- High bytes in the name, and blanks inside it.
    { url = "https://" .. ("\200"):rep(n) },
    { url = "https://" .. ("\200"):rep(n) .. "!" },
    { url = "https://h" .. (" "):rep(n / 2) .. "x" },
  }
end

---`ai.providers.claude_cli` with the two length bounds in front of the parse lifted
---(MAX_URL_BYTES, MAX_HOST_BYTES), from a copy of its own source: with them in
---place a value of 120 kB or 1 MB is refused before a single pattern runs, so only
---this copy shows whether the patterns themselves stay linear -- the next edit that
---brings a backtracking one back would otherwise hide behind the bound. The module
---itself is untouched; nothing is cached.
---@return Ai.Providers.ClaudeCli
local function load_without_bounds()
  local path = ROOT .. "/lua/ai/providers/claude_cli.lua"
  local file = assert(io.open(path, "rb"))
  local source = file:read("*a")
  file:close()
  local urls, hosts
  source, urls = source:gsub("local MAX_URL_BYTES = [%d_]+", "local MAX_URL_BYTES = math.huge")
  source, hosts = source:gsub("local MAX_HOST_BYTES = [%d_]+", "local MAX_HOST_BYTES = math.huge")
  assert(urls == 1 and hosts == 1, "the length bounds are not where this spec lifts them")
  return assert(load(source, "=claude_cli (bounds lifted)"))()
end

describe("ANTHROPIC_BASE_URL visibility (claude-cli)", function()
  local saved_env, cli

  ---@param value string|nil
  local function set(value)
    vim.env[VAR] = value
  end

  ---The note as the one sentence `:checkhealth` prints.
  ---@return string|nil
  local function note_text()
    local lines = cli.gateway_note()
    return lines and table.concat(lines, " ")
  end

  before_each(function()
    saved_env = vim.env[VAR] or false
    for _, name in ipairs(RELOAD) do
      package.loaded[name] = nil
    end
    set(nil)
    cli = require("ai.providers.claude_cli")
  end)

  after_each(function()
    vim.env[VAR] = saved_env or nil
    for _, name in ipairs(RELOAD) do
      package.loaded[name] = nil
    end
  end)

  describe("gateway_note()", function()
    it("is nil when the variable is unset, empty or blank", function()
      assert.is_nil(note_text())
      set("")
      assert.is_nil(note_text())
      set("   ")
      assert.is_nil(note_text())
    end)

    it("names the host, says the CLI talks to it, and that it can be a company gateway", function()
      set("https://gateway.corp.example/anthropic")
      local note = note_text()
      assert.is_truthy(note:find("gateway.corp.example", 1, true))
      assert.is_truthy(note:find("claude CLI", 1, true))
      assert.is_truthy(note:find("company gateway", 1, true))
      assert.is_truthy(note:find(VAR, 1, true))
    end)

    it(
      "comes as short lines, the host in the first: the `:Ai info` viewer does not wrap",
      function()
        set("https://gateway.corp.example:8443/v1")
        local lines = cli.gateway_note()
        assert.are.equal(2, #lines)
        assert.is_truthy(lines[1]:find("gateway.corp.example:8443", 1, true))
        assert.is_truthy(lines[2]:find("company gateway", 1, true))
        for _, line in ipairs(lines) do
          assert.is_true(#line <= 80, line)
        end
        set("not a url")
        for _, line in ipairs(cli.gateway_note()) do
          assert.is_true(#line <= 90, line)
        end
      end
    )

    it("prints only the host: no scheme, userinfo, path, query or fragment", function()
      set("https://svc-user:s3cretpass@gateway.corp.example:8443/v1/proxy?token=abc123#frag")
      local note = note_text()
      assert.is_truthy(note:find("gateway.corp.example:8443", 1, true))
      for _, leaked in ipairs({
        "https",
        "svc-user",
        "s3cretpass",
        "v1/proxy",
        "token",
        "abc123",
        "frag",
        "//",
      }) do
        assert.is_nil(note:find(leaked, 1, true), leaked .. " must not be printed")
      end
    end)

    -- What a URL parser takes as the host, for the shapes a gateway URL has.
    for url, host in pairs({
      ["http://localhost:4000"] = "localhost:4000",
      ["https://gw.example.com"] = "gw.example.com",
      ["https://gw.example.com/"] = "gw.example.com",
      ["https://gw.example.com?x=1"] = "gw.example.com",
      ["https://gw.example.com#frag"] = "gw.example.com",
      ["https://gw.example.com:/x"] = "gw.example.com",
      ["https://a:b@gw.example.com:8443/p"] = "gw.example.com:8443",
      ["https://a@b@gw.example.com/"] = "gw.example.com",
      ["https://gw.example.com\\@evil.example/"] = "gw.example.com",
      ["HTTPS://GW.Example.com/x"] = "GW.Example.com",
      ["http://[::1]:8080/x"] = "[::1]:8080",
      ["  https://gw.example.com/x\n"] = "gw.example.com",
    }) do
      it(("reads the host of %q as %q"):format(url, host), function()
        set(url)
        local note = note_text()
        assert.is_truthy(note:find(host, 1, true), note)
        assert.is_nil(note:find("evil", 1, true), note)
        assert.is_nil(note:find("not shown", 1, true), "a readable URL names its host")
      end)
    end

    -- Not a URL with a host: say that the variable is set, never echo any of it. The
    -- sentence is the same for every such value, so none of the value is in it.
    local unreadable = {
      "sk-ant-api03-SECRETSECRETSECRET",
      "not a url",
      "gw.example.com:8080",
      "https://user:secret",
      "https://user:secret@",
      "https://",
      "https://@",
      "https://gw example.com/",
      "https://%67w.example.com/",
    }
    for _, value in ipairs(unreadable) do
      it(("does not echo %q, but still says the variable is set"):format(value), function()
        set("!")
        local generic = note_text()
        assert.is_truthy(generic:find(VAR .. " is set", 1, true), generic)
        assert.is_truthy(generic:find("company gateway", 1, true))
        assert.is_truthy(generic:find("not shown", 1, true))
        set(value)
        assert.are.equal(generic, note_text())
      end)
    end

    -- A value is read on every `:Ai info` and `:checkhealth`; a pattern that retries
    -- from every start position (`([^@]*)$` on a long userinfo took 72 s for 120 kB)
    -- would hang the editor. The sentence stays short whatever the value is.
    it("answers in linear time and stays short on a hostile value (120 kB, 1 MB)", function()
      -- Over the bound: refused before it is parsed, and no host is named.
      set("!")
      local generic = note_text()
      for _, n in ipairs({ 120000, 1000000 }) do
        for _, shape in ipairs(hostile_shapes(n)) do
          set(shape.url)
          local t0 = vim.uv.hrtime()
          local note = note_text()
          local ms = (vim.uv.hrtime() - t0) / 1e6
          assert.is_true(ms < 1000, ("%d ms for %d bytes"):format(ms, #shape.url))
          assert.is_true(#note < 400, "the note carries no more than a host")
          assert.are.equal(generic, note, "nothing of an oversized value is read or echoed")
        end
      end
    end)

    -- The same shapes through the parse itself (the bounds lifted, see
    -- `load_without_bounds`). A parse that retries at every split of a digit run, or
    -- from every start of a long userinfo, takes tens of seconds at 120 kB (55 s and
    -- 72 s measured) and far longer at 1 MB; a linear one takes milliseconds, so the
    -- limits are generous. The small size runs first: a regression fails there after
    -- seconds and never gets to the size that would not finish.
    it("parses a hostile value of 120 kB and 1 MB in linear time, bounds lifted", function()
      local unbounded = load_without_bounds()
      local limits = { [120000] = 1000, [1000000] = 3000 }
      for _, n in ipairs({ 120000, 1000000 }) do
        for _, shape in ipairs(hostile_shapes(n)) do
          set(shape.url)
          local t0 = vim.uv.hrtime()
          local note = table.concat(unbounded.gateway_note() or {}, " ")
          local ms = (vim.uv.hrtime() - t0) / 1e6
          assert.is_true(
            ms < limits[n],
            ("%d ms for %d bytes: %s..."):format(ms, #shape.url, shape.url:sub(1, 24))
          )
          assert.is_true(#note < 400, "the note carries no more than a host")
          if shape.host then
            assert.is_truthy(note:find(shape.host, 1, true), note)
            assert.is_nil(note:find("not shown", 1, true), note)
          else
            assert.is_truthy(note:find("not shown", 1, true), note)
          end
        end
      end
    end)

    it("the copy without bounds really lifts them, and the module itself keeps them", function()
      set("https://gw.example.com/" .. ("p"):rep(5000))
      assert.is_truthy(note_text():find("not shown", 1, true))
      local note = table.concat(load_without_bounds().gateway_note(), " ")
      assert.is_truthy(note:find("gw.example.com", 1, true), note)
      assert.is_nil(note:find("not shown", 1, true), note)
      -- (MAX_HOST_BYTES cannot be told apart this way: a host over it is refused by
      -- the bound and, lifted, by the name length -- the same sentence. The loader
      -- asserts that it found and replaced both constants.)
    end)

    -- The same shapes at the size the bound lets through: the parse must not be
    -- slow there either (it is the bound that keeps it short above, and the parse
    -- that keeps it linear below), and they are not a host.
    it("reads a long value up to the bound quickly, and names no host for it", function()
      for _, value in ipairs({
        "https://" .. ("1"):rep(2000) .. "!",
        "https://" .. ("1"):rep(2000) .. ":!",
        "https://" .. ("1"):rep(1000) .. ":" .. ("1"):rep(1000) .. "!",
      }) do
        set(value)
        local t0 = vim.uv.hrtime()
        local note = note_text()
        local ms = (vim.uv.hrtime() - t0) / 1e6
        assert.is_true(ms < 100, ("%d ms for %d bytes"):format(ms, #value))
        assert.is_truthy(note:find("not shown", 1, true), note)
      end
    end)

    it("is bounded before anything is parsed: a base URL is not 2 kB long", function()
      -- Within the bound a long path or query is still just dropped ...
      set("https://gw.example.com/" .. ("p"):rep(1500) .. "?q=" .. ("x"):rep(200))
      assert.is_truthy(note_text():find("gw.example.com", 1, true))
      assert.is_nil(note_text():find("not shown", 1, true))
      -- ... beyond it the value is no base URL: nothing of it is read or echoed.
      set("https://gw.example.com/" .. ("p"):rep(2100))
      local note = note_text()
      assert.is_truthy(note:find("not shown", 1, true), note)
      assert.is_nil(note:find("gw.example.com", 1, true), note)
    end)

    it("still reads a host name that is all digits and dots, and a port", function()
      for url, host in pairs({
        ["https://10.0.0.5:8443/v1"] = "10.0.0.5:8443",
        ["https://10.0.0.5/v1"] = "10.0.0.5",
        ["https://12345"] = "12345",
        ["http://[2001:db8::1]:8080"] = "[2001:db8::1]:8080",
      }) do
        set(url)
        local note = note_text()
        assert.is_truthy(note:find(host, 1, true), url .. " -> " .. note)
        assert.is_nil(note:find("not shown", 1, true), url .. " -> " .. note)
      end
    end)

    it("is read live, so a change of the variable shows up without a reload", function()
      set("https://one.example/")
      assert.is_truthy(note_text():find("one.example", 1, true))
      set("https://two.example/")
      assert.is_truthy(note_text():find("two.example", 1, true))
      set(nil)
      assert.is_nil(note_text())
    end)
  end)

  describe(":Ai info", function()
    local popup_lines, saved_kit

    before_each(function()
      popup_lines = nil
      saved_kit = package.loaded["ui.kit"]
      package.loaded["ui.kit"] = {
        popup = function(opts)
          popup_lines = opts.lines
        end,
      }
      package.loaded["ai.bindings.actions"] = nil
      require("ai.config").setup({})
      require("ai.providers").load_builtin()
    end)

    after_each(function()
      package.loaded["ui.kit"] = saved_kit
      package.loaded["ai.bindings.actions"] = nil
    end)

    ---@return string[]
    local function info()
      require("ai.bindings.actions").info()
      return popup_lines
    end

    ---@param lines string[]
    ---@param prefix string
    ---@return integer|nil
    local function line_starting(lines, prefix)
      for i, line in ipairs(lines) do
        if vim.startswith(line, prefix) then
          return i
        end
      end
    end

    it("says nothing about a gateway when the variable is unset", function()
      local text = table.concat(info(), "\n")
      assert.is_nil(text:find(VAR, 1, true))
      assert.is_nil(text:find("gateway", 1, true))
    end)

    it("puts a line with the host right under the claude-cli provider", function()
      set("https://user:pw@gateway.corp.example:8443/v1?key=zzz")
      local lines = info()
      local at = assert(line_starting(lines, "  claude-cli: "), "no claude-cli line")
      local note = (lines[at + 1] or "") .. " " .. (lines[at + 2] or "")
      assert.is_truthy(lines[at + 1], "no line under the provider")
      assert.is_truthy(lines[at + 1]:find("gateway.corp.example:8443", 1, true), note)
      assert.is_truthy(note:find("company gateway", 1, true), note)
      assert.is_truthy(vim.startswith(lines[at + 1], "    "), "indented under the provider")
      assert.is_truthy(vim.startswith(lines[at + 2], "    "), "indented under the provider")
      local text = table.concat(lines, "\n")
      for _, leaked in ipairs({ "user", "pw@", "key=", "zzz", "/v1", "https" }) do
        assert.is_nil(text:find(leaked, 1, true), leaked .. " must not be printed")
      end
      -- exactly once, and not under any other provider
      local _, count = text:gsub("gateway%.corp%.example", "")
      assert.are.equal(1, count)
    end)
  end)

  describe(":checkhealth ai", function()
    local report, saved

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
      -- The check also looks for an `apiKeyHelper` in the CLI's settings files:
      -- none of these specs is about that (claude_cli_settings_spec.lua is), and
      -- none may read the real ones.
      cli.settings_files = function()
        return {}
      end
    end)

    after_each(function()
      for fn, original in pairs(saved) do
        vim.health[fn] = original
      end
      package.loaded["ai.health"] = nil
    end)

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

    it("reports nothing about a gateway when the variable is unset", function()
      require("ai.health").check()
      for _, entry in ipairs(report) do
        assert.is_nil(entry.msg:find(VAR, 1, true), entry.msg)
        assert.is_nil(entry.msg:find("gateway", 1, true), entry.msg)
      end
    end)

    it("warns, in the providers section, that the CLI talks to that host", function()
      set("https://user:pw@gateway.corp.example:8443/v1?key=zzz")
      require("ai.health").check()
      local warn = assert(find("warn", "gateway.corp.example:8443"), "no warning naming the host")
      assert.is_truthy(report[warn].msg:find("claude CLI", 1, true))
      assert.is_truthy(report[warn].msg:find("company gateway", 1, true))
      assert.is_truthy(
        type(report[warn].advice) == "table" and #report[warn].advice > 0,
        "a warning says what to do about it"
      )
      local starts = {}
      for i, entry in ipairs(report) do
        if entry.level == "start" then
          starts[entry.msg] = i
        end
      end
      assert.is_true(warn > starts["ai.nvim: providers"], "after the providers heading")
      assert.is_true(warn < starts["ai.nvim: configuration"], "before the next section")
      local provider_line = find("ok", "claude-cli: available")
        or find("info", "claude-cli: not available")
      assert.is_truthy(provider_line, "no claude-cli line in the providers section")
      assert.is_true(warn > provider_line, "under the claude-cli entry")
    end)

    -- A warning where the CLI can be run; for someone who set the variable for other
    -- tools and never uses claude-cli, a fact to know and not a defect.
    describe("without the CLI in sight", function()
      local URL = "https://gateway.corp.example:8443/v1"

      before_each(function()
        cli.command = { "definitely-not-a-claude-binary-xyz" }
        set(URL)
      end)

      ---@param opts? table
      local function check(opts)
        require("ai.config").setup(opts or {})
        package.loaded["ai.health"] = nil
        require("ai.health").check()
      end

      it("is an info line, still naming the host, when claude-cli is not in use", function()
        check()
        assert.is_nil(find("ok", "claude-cli: available"))
        local at = assert(find("info", "gateway.corp.example:8443"), "no info line naming the host")
        assert.is_truthy(report[at].msg:find("company gateway", 1, true))
        assert.is_nil(find("warn", "gateway.corp.example"), "not a warning")
        assert.is_nil(find("warn", VAR))
        assert.is_truthy(
          at > find("info", "claude-cli: not available"),
          "still under the claude-cli entry"
        )
      end)

      it("is a warning when the CLI is installed", function()
        cli.command = { vim.v.progpath }
        check()
        assert.is_truthy(find("warn", "gateway.corp.example:8443"))
        assert.is_nil(find("info", "gateway.corp.example"))
      end)

      for label, opts in pairs({
        ["the provider"] = { provider = "claude-cli" },
        ["in provider_order"] = { provider_order = { "claude", "claude-cli" } },
        ["the completion's provider"] = { completion = { provider = "claude-cli" } },
      }) do
        it(("is a warning when claude-cli is %s, installed or not"):format(label), function()
          check(opts)
          assert.is_truthy(find("warn", "gateway.corp.example:8443"))
          assert.is_nil(find("info", "gateway.corp.example"))
        end)
      end

      it("keeps the report of an unreadable value at the same level", function()
        set("sk-ant-api03-SECRETSECRETSECRET")
        check()
        assert.is_truthy(find("info", VAR .. " is set"))
        assert.is_nil(find("warn", VAR))
        check({ provider = "claude-cli" })
        assert.is_truthy(find("warn", VAR .. " is set"))
      end)
    end)

    it("never prints more than the host", function()
      set("https://user:pw@gateway.corp.example:8443/v1?key=zzz")
      require("ai.health").check()
      for _, entry in ipairs(report) do
        local text = entry.msg .. " " .. table.concat(entry.advice or {}, " ")
        for _, leaked in ipairs({ "pw@", "key=", "zzz", "/v1", "https://" }) do
          assert.is_nil(text:find(leaked, 1, true), leaked .. " leaked into: " .. entry.msg)
        end
      end
    end)

    it("reports a value without a readable host as set, without echoing it", function()
      set("sk-ant-api03-SECRETSECRETSECRET")
      require("ai.health").check()
      assert.is_truthy(find("warn", VAR .. " is set"))
      for _, entry in ipairs(report) do
        assert.is_nil(entry.msg:find("SECRETSECRET", 1, true), entry.msg)
      end
    end)
  end)
end)
