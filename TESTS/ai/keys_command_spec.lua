-- The `command` key source (lua/ai/keys.lua): an argument vector, no shell,
-- asynchronous with a timeout, cached for the session, never shown.
--
-- The fake commands are Neovim itself running a small Lua script (`nvim -l`),
-- so the specs need no other executable and run the same on every platform.
---@diagnostic disable: missing-fields, need-check-nil
describe("ai.keys command source", function()
  local saved_key, dir

  local function reload()
    for _, name in ipairs({
      "ai.config",
      "ai.keys",
      "ai.providers",
      "ai.providers.claude",
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

  local function read_text(name)
    local fh = io.open(dir .. "/" .. name, "rb")
    if not fh then
      return nil
    end
    local text = fh:read("*a")
    fh:close()
    return text
  end

  ---A fake key command: `body` is Lua run by `nvim -l`; `counter` (a file in
  ---`dir`) gets one line per run, so a spec can count the runs.
  ---@param body string
  ---@param extra? string[] further arguments after the script
  ---@return string[] argv
  local function fake(body, extra)
    local script = write_file(
      "cmd.lua",
      ("local c = io.open(%q, 'ab'); c:write('run\\n'); c:close()\n%s\n"):format(
        dir .. "/counter",
        body
      )
    )
    local argv = { vim.v.progpath, "--headless", "-u", "NONE", "-l", script }
    for _, a in ipairs(extra or {}) do
      argv[#argv + 1] = a
    end
    return argv
  end

  local function runs()
    local text = read_text("counter") or ""
    return select(2, text:gsub("run", ""))
  end

  local function setup(command_spec)
    command_spec.timeout_ms = command_spec.timeout_ms or 20000
    require("ai.config").setup({
      keys = { claude = { active = "firma", profiles = { firma = command_spec } } },
    })
    return require("ai.keys")
  end

  ---Run `keys.fetch` and wait for its callback.
  local function fetch(keys)
    local done, ok, err
    keys.fetch("claude", function(o, e)
      done, ok, err = true, o, e
    end)
    assert.is_true(
      vim.wait(20000, function()
        return done
      end, 20),
      "fetch did not finish"
    )
    return ok, err
  end

  before_each(function()
    reload()
    saved_key = vim.env.ANTHROPIC_API_KEY
    vim.env.ANTHROPIC_API_KEY = "default-key"
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.env.ANTHROPIC_API_KEY = saved_key
    vim.fn.delete(dir, "rf")
    reload()
  end)

  describe("before it has run", function()
    it("counts as available, starts nothing and never falls back to the default key", function()
      local keys = setup({ command = fake("io.write('the-key')") })
      assert.is_true(keys.pending("claude"))
      assert.is_true(keys.needs_fetch("claude"))
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.is_false(keys.blocked("claude"))
      assert.is_true(require("ai.providers.claude").available())
      assert.are.equal(0, runs())
      assert.is_truthy(keys.describe("claude"):find("key not fetched yet", 1, true))
    end)
  end)

  describe("fetch", function()
    it("takes the first non-empty stdout line, trimmed, and caches it", function()
      local keys = setup({ command = fake("io.write('\\n  the-key  \\nsecond\\n')") })
      local ok = fetch(keys)
      assert.is_true(ok)
      assert.are.equal("the-key", keys.get("claude", "ANTHROPIC_API_KEY"))
      assert.is_false(keys.needs_fetch("claude"))
      -- A second fetch is served from the cache: the command does not run again.
      assert.is_true((fetch(keys)))
      assert.are.equal(1, runs())
      assert.is_truthy(keys.describe("claude"):find("key present", 1, true))
    end)

    it("forget() drops the cache, so the next fetch runs the command again", function()
      local keys = setup({ command = fake("io.write('k')") })
      fetch(keys)
      keys.forget("claude")
      assert.is_true(keys.needs_fetch("claude"))
      fetch(keys)
      assert.are.equal(2, runs())
    end)

    it("concurrent fetches share one run", function()
      local keys = setup({ command = fake("io.write('k')") })
      local finished = 0
      for _ = 1, 3 do
        keys.fetch("claude", function(ok)
          assert.is_true(ok)
          finished = finished + 1
        end)
      end
      assert.is_true(vim.wait(20000, function()
        return finished == 3
      end, 20))
      assert.are.equal(1, runs())
    end)

    it("a cancelled fetch calls nothing back", function()
      local keys = setup({ command = fake("io.write('k')") })
      local called = false
      local cancel = keys.fetch("claude", function()
        called = true
      end)
      cancel()
      assert.is_true(vim.wait(20000, function()
        return not keys.needs_fetch("claude")
      end, 20))
      assert.is_false(called)
    end)

    it("without a command source it is a no-op that succeeds at once", function()
      require("ai.config").setup({})
      local keys = require("ai.keys")
      local ok
      keys.fetch("claude", function(o)
        ok = o
      end)
      assert.is_true(ok)
    end)
  end)

  describe("no shell", function()
    it("passes every argument literally, metacharacters included", function()
      local marker = dir .. "/injected"
      local evil = ("x; echo hacked > %s && echo $(id) `id` | %%PATH%% \"'"):format(marker)
      local keys = setup({
        command = fake(
          "local f = io.open(arg[1] .. '.args', 'wb'); f:write(arg[2]); f:close(); io.write('k')",
          { dir .. "/out", evil }
        ),
      })
      assert.is_true((fetch(keys)))
      assert.are.equal(evil, read_text("out.args"))
      assert.is_nil(read_text("injected"))
    end)

    it("a shell string is no command: refused with a clear issue, never run", function()
      local keys = setup({ command = "pass show anthropic" })
      assert.is_true(keys.pending("claude") == false)
      local joined = table.concat(keys.issues(), "\n")
      assert.is_truthy(joined:find("must be a list of strings", 1, true))
      assert.is_false(keys.pending("claude"))
    end)

    it("an empty list or a list with a non-string is refused at fetch time", function()
      for _, bad in ipairs({ {}, { "nvim", 5 }, { "nvim", "" } }) do
        reload()
        local keys = setup({ command = bad })
        if keys.pending("claude") then
          local ok, err = fetch(keys)
          assert.is_false(ok)
          assert.are.equal("missing_api_key", err.kind)
          assert.is_truthy(err.message:find("must be a list of strings", 1, true))
        end
        assert.is_truthy(#keys.issues() > 0)
      end
    end)
  end)

  describe("failures", function()
    it(
      "a non-zero exit is a missing_api_key error naming profile and code, not the output",
      function()
        local keys = setup({
          command = fake("io.write('leaked-secret'); io.stderr:write('leaked-err'); os.exit(3)"),
        })
        local ok, err = fetch(keys)
        assert.is_false(ok)
        assert.are.equal("missing_api_key", err.kind)
        assert.is_truthy(err.message:find("firma", 1, true))
        assert.is_truthy(err.message:find("exited with code 3", 1, true))
        local dump = vim.inspect(err) .. keys.describe("claude")
        assert.is_nil(dump:find("leaked", 1, true))
        assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
        assert.is_truthy(keys.describe("claude"):find("KEY MISSING: exited with code 3", 1, true))
        -- A failure is not cached: the next request runs the command again.
        assert.is_true(keys.needs_fetch("claude"))
      end
    )

    it("a command that hangs is killed after timeout_ms", function()
      local keys = setup({ command = fake("vim.uv.sleep(15000); io.write('k')"), timeout_ms = 400 })
      local started = vim.uv.now()
      local ok, err = fetch(keys)
      assert.is_false(ok)
      assert.is_truthy(err.message:find("timed out after 400 ms", 1, true))
      assert.is_true(vim.uv.now() - started < 10000)
    end)

    it("a fractional timeout_ms still ends in a result instead of hanging", function()
      local keys =
        setup({ command = fake("vim.uv.sleep(15000); io.write('k')"), timeout_ms = 400.5 })
      local ok, err = fetch(keys)
      assert.is_false(ok)
      assert.is_truthy(err.message:find("timed out after 400 ms", 1, true))
    end)

    it("an unusable or extreme timeout_ms falls back or is clamped, never hangs", function()
      for _, value in ipairs({ 0, -5, 0.5, 0 / 0, math.huge, -math.huge, 1e300, "soon" }) do
        reload()
        local keys = setup({ command = fake("io.write('k')"), timeout_ms = value })
        local ok, err = fetch(keys)
        assert.is_true(ok, tostring(value) .. ": " .. vim.inspect(err))
        assert.is_false(keys.needs_fetch("claude"), tostring(value))
      end
    end)

    it("empty output is an error, not a nil key", function()
      local keys = setup({ command = fake("io.write('  \\n\\n')") })
      local ok, err = fetch(keys)
      assert.is_false(ok)
      assert.is_truthy(err.message:find("printed no key", 1, true))
    end)

    it("a missing executable is reported without spawning anything", function()
      local keys = setup({ command = { dir .. "/no-such-binary", "secret-arg" } })
      local ok, err = fetch(keys)
      assert.is_false(ok)
      assert.is_truthy(err.message:find("executable not found", 1, true))
      assert.is_nil(err.message:find("secret-arg", 1, true))
      -- And health says so up front.
      assert.is_truthy(table.concat(keys.issues(), "\n"):find("not found", 1, true))
    end)
  end)

  describe("cache_ms", function()
    it("an expired key is fetched again", function()
      local keys = setup({ command = fake("io.write('k')"), cache_ms = 1000 })
      fetch(keys)
      assert.is_false(keys.needs_fetch("claude"))
      vim.wait(1100)
      assert.is_true(keys.needs_fetch("claude"))
      assert.is_nil(keys.get("claude", "ANTHROPIC_API_KEY"))
      fetch(keys)
      assert.are.equal(2, runs())
    end)
  end)

  describe("what is shown", function()
    it(
      "describe and the info line carry the executable's name, not arguments or the key",
      function()
        local keys = setup({
          command = fake("io.write('the-key')", { "super-secret-arg" }),
        })
        fetch(keys)
        local text = keys.describe("claude")
        assert.is_truthy(text:find("command nvim", 1, true) or text:find("command ", 1, true))
        assert.is_nil(text:find("the-key", 1, true))
        assert.is_nil(text:find("super-secret-arg", 1, true))
        assert.is_nil(text:find("cmd.lua", 1, true))
      end
    )
  end)

  describe("batch files on Windows", function()
    it("are recognised by name, only on Windows", function()
      local keys = setup({ command = fake("io.write('k')") })
      assert.is_true(keys._batch_file("C:/tools/key.CMD", true))
      assert.is_true(keys._batch_file("get-key.bat", true))
      assert.is_false(keys._batch_file("C:/tools/key.exe", true))
      assert.is_false(keys._batch_file("get-key.cmd", false))
      assert.is_false(keys._batch_file("pass", false))
    end)

    it("are refused with a way out instead of being spawned or wrapped in cmd.exe", function()
      if vim.fn.has("win32") == 0 then
        return
      end
      local path = write_file("get-key.cmd", "@echo the-key\r\n")
      local keys = setup({ command = { path, "secret-arg" } })
      local ok, err = fetch(keys)
      assert.is_false(ok)
      assert.is_truthy(err.message:find(".cmd/.bat batch file", 1, true))
      assert.is_truthy(err.message:find("-File", 1, true))
      assert.is_nil(err.message:find("secret-arg", 1, true))
      local joined = table.concat(keys.issues(), "\n")
      assert.is_truthy(joined:find("get-key.cmd", 1, true))
      assert.is_truthy(joined:find("batch file", 1, true))
      assert.is_nil(joined:find("secret-arg", 1, true))
    end)
  end)

  describe("validation", function()
    it("needs exactly one source and positive numbers", function()
      local keys = setup({ command = fake("io.write('k')"), env = "X" })
      assert.is_truthy(table.concat(keys.issues(), "\n"):find("exactly one of", 1, true))
      reload()
      keys = setup({ command = fake("io.write('k')"), timeout_ms = -1, cache_ms = "soon" })
      local joined = table.concat(keys.issues(), "\n")
      assert.is_truthy(joined:find("timeout_ms", 1, true))
      assert.is_truthy(joined:find("cache_ms", 1, true))
    end)

    it("a non-finite or NaN timeout_ms is an issue, not accepted", function()
      for _, value in ipairs({ 0 / 0, math.huge }) do
        reload()
        local keys = setup({ command = fake("io.write('k')"), timeout_ms = value })
        assert.is_truthy(
          table.concat(keys.issues(), "\n"):find("timeout_ms", 1, true),
          tostring(value)
        )
      end
    end)

    it("a good command is no issue", function()
      local keys = setup({ command = fake("io.write('k')") })
      assert.are.same({}, keys.issues())
    end)
  end)

  describe("key files", function()
    it("a missing file is a clear issue, not only a silent nil", function()
      require("ai.config").setup({
        keys = { claude = { active = "f", profiles = { f = { file = dir .. "/nope.key" } } } },
      })
      local joined = table.concat(require("ai.keys").issues(), "\n")
      assert.is_truthy(joined:find("does not exist", 1, true))
      assert.is_nil(joined:find(dir, 1, true), "the path is not echoed")
    end)

    it("a file other users can read is flagged on POSIX, not on Windows", function()
      local path = write_file("k.key", "the-key")
      require("ai.config").setup({
        keys = { claude = { active = "f", profiles = { f = { file = path } } } },
      })
      local keys = require("ai.keys")
      if vim.fn.has("win32") == 1 then
        assert.are.same({}, keys.issues())
        return
      end
      vim.uv.fs_chmod(path, tonumber("644", 8))
      assert.is_truthy(table.concat(keys.issues(), "\n"):find("group or others", 1, true))
      vim.uv.fs_chmod(path, tonumber("600", 8))
      assert.are.same({}, keys.issues())
    end)
  end)

  describe("through ai.ask / ai.stream", function()
    local seen

    local function register_fake_provider()
      require("ai.providers").register({
        id = "claude",
        available = function()
          return true
        end,
        ask = function(_, cb)
          seen = require("ai.keys").get("claude", "ANTHROPIC_API_KEY")
          cb(true, { text = "ok" })
        end,
        stream = function(_, handlers)
          seen = require("ai.keys").get("claude", "ANTHROPIC_API_KEY")
          handlers.on_done({ text = "ok" })
          return { kill = function() end }
        end,
      })
    end

    before_each(function()
      seen = nil
    end)

    it("ask fetches the key first, then calls the provider with it cached", function()
      require("ai.config").setup({
        provider = "claude",
        keys = {
          claude = {
            active = "firma",
            profiles = { firma = { command = fake("io.write('the-key')") } },
          },
        },
      })
      register_fake_provider()
      local done, ok
      require("ai").ask({ prompt = "hi" }, function(o)
        done, ok = true, o
      end)
      assert.is_nil(seen, "the provider must not be called synchronously")
      assert.is_true(vim.wait(20000, function()
        return done
      end, 20))
      assert.is_true(ok)
      assert.are.equal("the-key", seen)
    end)

    it("ask reports a failing command through the callback and never calls the provider", function()
      require("ai.config").setup({
        provider = "claude",
        keys = {
          claude = {
            active = "firma",
            profiles = { firma = { command = fake("os.exit(2)") } },
          },
        },
      })
      register_fake_provider()
      local done, ok, err
      require("ai").ask({ prompt = "hi" }, function(o, e)
        done, ok, err = true, o, e
      end)
      assert.is_true(vim.wait(20000, function()
        return done
      end, 20))
      assert.is_false(ok)
      assert.are.equal("missing_api_key", err.kind)
      assert.is_nil(seen)
    end)

    it("stream returns a handle at once and continues when the key is there", function()
      require("ai.config").setup({
        provider = "claude",
        keys = {
          claude = {
            active = "firma",
            profiles = { firma = { command = fake("io.write('the-key')") } },
          },
        },
      })
      register_fake_provider()
      local done
      local handle = require("ai").stream({ prompt = "hi" }, {
        on_done = function()
          done = true
        end,
      })
      assert.is_truthy(handle)
      assert.is_function(handle.kill)
      assert.is_true(vim.wait(20000, function()
        return done
      end, 20))
      assert.are.equal("the-key", seen)
    end)

    it("killing the handle while the key is being fetched cancels the stream", function()
      require("ai.config").setup({
        provider = "claude",
        keys = {
          claude = {
            active = "firma",
            profiles = { firma = { command = fake("io.write('the-key')") } },
          },
        },
      })
      register_fake_provider()
      local called = false
      local handle = require("ai").stream({ prompt = "hi" }, {
        on_done = function()
          called = true
        end,
      })
      handle:kill(15)
      assert.is_true(vim.wait(20000, function()
        return not require("ai.keys").needs_fetch("claude")
      end, 20))
      vim.wait(100)
      assert.is_false(called)
      assert.is_nil(seen)
    end)

    it("a request with its own api_key does not run the command", function()
      require("ai.config").setup({
        provider = "claude",
        keys = {
          claude = {
            active = "firma",
            profiles = { firma = { command = fake("io.write('the-key')") } },
          },
        },
      })
      register_fake_provider()
      local done
      require("ai").ask({ prompt = "hi", api_key = "own" }, function()
        done = true
      end)
      assert.is_true(done)
      assert.are.equal(0, runs())
    end)
  end)
end)
