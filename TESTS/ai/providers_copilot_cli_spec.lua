-- The provider is exercised against a fake `copilot` (fixtures/fake_copilot.lua,
-- run through the test Neovim itself), so these specs cover what ai.nvim does --
-- argv, stdin, environment, the throw-away home, event parsing, error mapping --
-- without a network, an account or a billing balance. The success events of the
-- fake are a trimmed copy of a recording of the real CLI (1.0.92); the mid-run
-- error events (CREDIT, ERROREVENT) are a guess and are labelled so in the fake.
---@diagnostic disable: need-check-nil
local FAKE = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  .. "/fixtures/fake_copilot.lua"

-- Credentials and routing that must never reach the child: the tokens outrank the
-- CLI's login, COPILOT_PROVIDER_* send the request to another endpoint, OTEL_*
-- can export message content.
local STRIPPED = {
  "COPILOT_GITHUB_TOKEN",
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "COPILOT_PROVIDER_BASE_URL",
  "COPILOT_PROVIDER_API_KEY",
  "COPILOT_OFFLINE",
  "COPILOT_CUSTOM_INSTRUCTIONS_DIRS",
  "COPILOT_OTEL_ENABLED",
  "OTEL_EXPORTER_OTLP_ENDPOINT",
  "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT",
}
-- Left alone on purpose: an enterprise host, a proxy.
local KEPT = { "GH_HOST", "HTTPS_PROXY" }
local FORCED = { "COPILOT_ALLOW_ALL", "COPILOT_AUTO_UPDATE", "COPILOT_MODEL", "COPILOT_HOME" }

describe("ai.providers.copilot", function()
  local cli, saved_env

  ---Run `ask` and wait for the callback.
  local function ask(req)
    local ok, res
    cli.ask(req, function(a, b)
      ok, res = a, b
    end)
    assert.is_true(vim.wait(15000, function()
      return ok ~= nil
    end, 20))
    return ok, res
  end

  local function index_of(list, value)
    for i, v in ipairs(list) do
      if v == value then
        return i
      end
    end
  end

  local function has_arg(argv, wanted)
    return index_of(argv, wanted) ~= nil
  end

  ---The value of the first `--name=value` argument, or nil.
  local function flag_value(argv, name)
    for _, a in ipairs(argv) do
      local v = a:match("^%-%-" .. name .. "=(.+)$")
      if v then
        return v
      end
    end
  end

  before_each(function()
    package.loaded["ai.providers.copilot"] = nil
    cli = require("ai.providers.copilot")
    cli.command = { vim.v.progpath, "-u", "NONE", "-l", FAKE }
    saved_env = {}
    for _, list in ipairs({ STRIPPED, KEPT, FORCED }) do
      for _, name in ipairs(list) do
        saved_env[name] = vim.env[name] or false
      end
    end
  end)

  after_each(function()
    for name, value in pairs(saved_env) do
      vim.env[name] = value or nil
    end
    package.loaded["ai.providers.copilot"] = nil
  end)

  it("is registered as an opt-in built-in without attachment support", function()
    local providers = require("ai.providers")
    providers.load_builtin()
    assert.is_truthy(providers.get("copilot"))
    assert.are.equal("copilot", cli.id)
    assert.is_false(cli.capabilities.vision)
    assert.is_false(cli.capabilities.documents)
    assert.is_true(cli.capabilities.streaming)
    assert.is_false(vim.tbl_contains(require("ai.config.DEFAULTS").provider_order, "copilot"))
    assert.is_true(require("ai.providers.models").OPEN_ENDED.copilot)
  end)

  it("is available exactly when its command is on PATH", function()
    assert.is_true(cli.available())
    cli.command = { "definitely-not-a-copilot-binary-xyz" }
    assert.is_false(cli.available())
  end)

  it("reports a command that cannot be started", function()
    cli.command = { "definitely-not-a-copilot-binary-xyz" }
    local ok, err = ask({ prompt = "OK" })
    assert.is_false(ok)
    assert.are.equal("network_error", err.kind)
    assert.is_truthy(err.message:find("could not start", 1, true))
  end)

  it("reads the CLI's version line, and nil for a command that does not run", function()
    cli.command = { vim.v.progpath, "--version" }
    assert.is_truthy(cli.version())
    cli.command = { "definitely-not-a-copilot-binary-xyz" }
    assert.is_nil(cli.version())
  end)

  it("ask returns the final answer without the commentary, and the provider id", function()
    local ok, res = ask({ prompt = "OK please" })
    assert.is_true(ok)
    assert.are.equal("Hello", res.text)
    assert.are.equal("copilot", res.provider)
    assert.are.same({ premiumRequests = 1 }, res.usage)
  end)

  it("stream delivers the answer deltas in order and none of the commentary", function()
    local chunks, done = {}, nil
    cli.stream({ prompt = "OK" }, {
      on_chunk = function(t)
        chunks[#chunks + 1] = t
      end,
      on_done = function(res)
        done = res
      end,
      on_error = function(e)
        error(vim.inspect(e))
      end,
    })
    assert.is_true(vim.wait(15000, function()
      return done ~= nil
    end, 20))
    assert.are.same({ "Hel", "lo" }, chunks)
    assert.are.equal("Hello", done.text)
  end)

  it("falls back to the commentary text when there is no final answer at all", function()
    local ok, res = ask({ prompt = "COMMENTARYONLY" })
    assert.is_true(ok)
    assert.are.equal("only commentary", res.text)
  end)

  it("takes the answer of a run that printed no result event but exited 0", function()
    local ok, res = ask({ prompt = "NORESULT" })
    assert.is_true(ok)
    assert.are.equal("no result event", res.text)
  end)

  it("accepts a complete result even if the process exits non-zero afterwards", function()
    local ok, res = ask({ prompt = "RESULTEXIT" })
    assert.is_true(ok)
    assert.are.equal("Hello", res.text)
  end)

  describe("what the child process gets", function()
    local function echo(req)
      req.prompt = "ECHO\n" .. (req.prompt or "")
      local ok, res = ask(req)
      assert.is_true(ok)
      return vim.json.decode(res.text)
    end

    it("receives the prompt on stdin and never in argv, without -p", function()
      local info = echo({ prompt = "secret customer text" })
      assert.is_truthy(info.stdin:find("secret customer text", 1, true))
      for _, a in ipairs(info.argv) do
        assert.is_nil(a:find("secret customer text", 1, true))
      end
      assert.is_false(has_arg(info.argv, "-p"))
      assert.is_false(has_arg(info.argv, "--prompt"))
    end)

    it("hands umlauts, quotes, backslashes and newlines over intact", function()
      local text = 'Grüße äöüß € "quote" \\ back\nzweite Zeile'
      assert.is_truthy(echo({ prompt = text }).stdin:find(text, 1, true))
    end)

    it("prefixes the system text onto stdin", function()
      local info = echo({ prompt = "q", system = "be brief" })
      assert.is_truthy(info.stdin:find("be brief", 1, true))
    end)

    it("passes a plain prompt through unchanged", function()
      assert.are.equal("ECHO\nq", echo({ prompt = "q" }).stdin)
    end)

    it("keeps a leading slash or bang from being the first byte", function()
      for _, prompt in ipairs({ "/usage ECHO", "  !hostname ECHO" }) do
        local ok, res = ask({ prompt = prompt })
        assert.is_true(ok)
        local info = vim.json.decode(res.text)
        assert.is_falsy(info.stdin:find("^[/!]"))
        assert.is_truthy(info.stdin:find(prompt, 1, true), "the user text must arrive intact")
      end
    end)

    it("leaves the model no tool and never grants a permission", function()
      local argv = echo({}).argv
      -- zero tools: one name that matches none (an empty list would not restrict)
      local available = flag_value(argv, "available%-tools")
      assert.is_truthy(available, "--available-tools missing or empty")
      assert.is_nil(available:find(",", 1, true), "exactly one (non-existent) name")
      assert.is_false(vim.tbl_contains({ "view", "powershell", "bash", "edit" }, available))
      local excluded = flag_value(argv, "excluded%-tools") or ""
      for _, tool in ipairs({ "powershell", "bash", "view", "create", "edit", "web_fetch", "task" }) do
        assert.is_truthy(excluded:find(tool, 1, true), tool .. " not excluded")
      end
      for _, flag in ipairs({
        "--deny-tool=shell",
        "--deny-tool=write",
        "--deny-tool=url",
        "--disable-builtin-mcps",
        "--no-ask-user",
        "--no-custom-instructions",
        "--disallow-temp-dir",
        "--no-auto-update",
        "--no-remote",
        "--no-remote-export",
      }) do
        assert.is_true(has_arg(argv, flag), "missing " .. flag)
      end
      for _, forbidden in ipairs({
        "--allow-all",
        "--yolo",
        "--allow-all-tools",
        "--allow-all-paths",
        "--allow-all-urls",
        "--allow-tool",
        "--share",
        "--share-gist",
        "--enable-memory",
        "--add-dir",
      }) do
        assert.is_false(has_arg(argv, forbidden), forbidden .. " must never be passed")
      end
    end)

    it("asks for JSON events with streaming on", function()
      local argv = echo({}).argv
      assert.are.equal("json", argv[index_of(argv, "--output-format") + 1])
      assert.are.equal("on", argv[index_of(argv, "--stream") + 1])
    end)

    it("passes --model only when one is requested", function()
      assert.is_nil(flag_value(echo({}).argv, "model"))
      assert.are.equal(
        "claude-haiku-4.5",
        flag_value(echo({ model = "claude-haiku-4.5" }).argv, "model")
      )
    end)

    it("refuses a model name that could be read as a flag", function()
      for _, model in ipairs({ "--allow-all", "-p", "x y", "a;b" }) do
        local ok, err = ask({ prompt = "OK", model = model })
        assert.is_false(ok, model)
        assert.are.equal("invalid_request", err.kind)
      end
    end)

    it("removes the tokens and routing variables, keeps the rest", function()
      for _, list in ipairs({ STRIPPED, KEPT }) do
        for _, name in ipairs(list) do
          vim.env[name] = "test-value-for-" .. name
        end
      end
      local info = echo({})
      for _, name in ipairs(STRIPPED) do
        assert.is_nil(info.env[name], name .. " reached the child")
      end
      for _, name in ipairs(KEPT) do
        assert.is_true(info.env[name], name .. " must still reach the child")
      end
      assert.is_true(info.path, "the rest of the environment must still reach the child")
    end)

    it("forces the permission and update switches, whatever the editor was started with", function()
      vim.env.COPILOT_ALLOW_ALL = "true"
      vim.env.COPILOT_AUTO_UPDATE = "true"
      local info = echo({})
      assert.are.equal("false", info.allow_all)
      assert.are.equal("false", info.auto_update)
    end)

    it("keeps COPILOT_MODEL, a model choice and no route", function()
      vim.env.COPILOT_MODEL = "gpt-5.4"
      assert.are.equal("gpt-5.4", echo({}).model)
    end)

    it("does not run in the editor's working directory", function()
      local info = echo({})
      assert.are_not.equal(vim.uv.cwd(), info.cwd)
    end)

    it("gives every call its own COPILOT_HOME and deletes it afterwards", function()
      vim.env.COPILOT_HOME = "C:/must/not/be/used"
      local first, second = echo({}), echo({})
      assert.is_truthy(first.home)
      assert.are_not.equal("C:/must/not/be/used", first.home)
      assert.are_not.equal(first.home, second.home)
      -- the fake wrote a session file there, like the real CLI does
      assert.are.equal(0, vim.fn.isdirectory(first.home))
      assert.are.equal(0, vim.fn.isdirectory(first.cwd))
    end)

    it("deletes the directories after a failed run too", function()
      local parent = vim.fs.dirname(vim.fn.tempname())
      local function count()
        return #vim.fn.glob(parent .. "/*/work", false, true)
      end
      local before = count()
      for _, prompt in ipairs({ "CRASH", "NOLOGIN", "CREDIT" }) do
        ask({ prompt = prompt })
      end
      assert.are.equal(before, count())
    end)

    it("uses the real home only when isolate_home is switched off", function()
      cli.isolate_home = false
      vim.env.COPILOT_HOME = "C:/real/home"
      assert.are.equal("C:/real/home", echo({}).home)
    end)
  end)

  describe("what the provider says about the environment", function()
    it("names the token variables that are set, never a value", function()
      vim.env.GITHUB_TOKEN = "ghp_secretvalue"
      vim.env.GH_TOKEN = "github_pat_other"
      vim.env.COPILOT_GITHUB_TOKEN = nil
      local names, classic = cli.env_tokens()
      assert.are.same({ "GH_TOKEN", "GITHUB_TOKEN" }, names)
      assert.is_true(classic)
      assert.is_nil(vim.inspect(names):find("secretvalue", 1, true))
      vim.env.GITHUB_TOKEN = nil
      local _, classic_after = cli.env_tokens()
      assert.is_false(classic_after)
    end)
  end)

  describe("errors", function()
    ---@param prompt string
    ---@return table err
    local function fails(prompt)
      local ok, err = ask({ prompt = prompt })
      assert.is_false(ok)
      return err
    end

    it("maps a classic PAT refusal to api_error `token` with the CLI's words", function()
      local err = fails("CLASSICPAT")
      assert.are.equal("api_error", err.kind)
      assert.are.equal("token", err.data.reason)
      assert.is_truthy(err.message:find("Classic Personal Access Tokens", 1, true))
    end)

    it("maps a token that cannot be validated to `auth`", function()
      local err = fails("BADTOKEN")
      assert.are.equal("api_error", err.kind)
      assert.are.equal("auth", err.data.reason)
      assert.is_truthy(err.message:find("could not be validated", 1, true))
      assert.is_truthy(err.message:find("copilot login", 1, true))
    end)

    it("maps a missing login to `auth`", function()
      assert.are.equal("auth", fails("NOLOGIN").data.reason)
    end)

    it("maps an unknown model to `model`", function()
      local err = fails("BADMODEL")
      assert.are.equal("api_error", err.kind)
      assert.are.equal("model", err.data.reason)
    end)

    it("maps a failed run with a quota message to `credit` (shape of the event guessed)", function()
      local err = fails("CREDIT")
      assert.are.equal("api_error", err.kind)
      assert.are.equal("credit", err.data.reason)
    end)

    it("reports an error event of a run, never an empty or partial answer", function()
      local err = fails("ERROREVENT")
      assert.are.equal("api_error", err.kind)
      assert.is_truthy(err.message:find("backend exploded", 1, true))
    end)

    it("discards an answer when the CLI reports a tool request", function()
      local err = fails("TOOLREQ")
      assert.are.equal("api_error", err.kind)
      assert.are.equal("tool_guard", err.data.reason)
    end)

    it("discards an answer when the CLI emits a tool event", function()
      assert.are.equal("tool_guard", fails("TOOLEVENT").data.reason)
    end)

    it("reports a result without any text as invalid_response", function()
      assert.are.equal("invalid_response", fails("NOTEXT").kind)
    end)

    it("reports a crash without any result event as network_error with stderr", function()
      local err = fails("CRASH")
      assert.are.equal("network_error", err.kind)
      assert.is_truthy(err.message:find("boom", 1, true))
    end)

    it("reports a crash after partial output as network_error, not a shortened answer", function()
      local chunks = {}
      local ok, err
      cli.stream({ prompt = "PARTIALCRASH" }, {
        on_chunk = function(t)
          chunks[#chunks + 1] = t
        end,
        on_done = function()
          ok = true
        end,
        on_error = function(e)
          ok, err = false, e
        end,
      })
      assert.is_true(vim.wait(15000, function()
        return ok ~= nil
      end, 20))
      assert.are.same({ "Hel" }, chunks)
      assert.is_false(ok)
      assert.are.equal("network_error", err.kind)
      assert.is_truthy(err.message:find("boom", 1, true))
    end)

    it("reports a process killed mid-answer as an error, never as done", function()
      local proc, done, err
      proc = cli.stream({ prompt = "PARTIALSLEEP" }, {
        on_chunk = function()
          proc:kill(15)
        end,
        on_done = function(res)
          done = res
        end,
        on_error = function(e)
          err = e
        end,
      })
      assert.is_true(vim.wait(15000, function()
        return done ~= nil or err ~= nil
      end, 20))
      assert.is_nil(done)
      assert.are.equal("network_error", err.kind)
    end)

    it("times out a hanging run", function()
      local ok, err = ask({ prompt = "SLEEP", timeout_ms = 400 })
      assert.is_false(ok)
      assert.are.equal("timeout", err.kind)
    end)

    it("rejects a request with an attachment instead of dropping it", function()
      local ok, err = ask({
        prompt = "OK",
        attachments = { { kind = "image", mime = "image/png", data = "AAAA" } },
      })
      assert.is_false(ok)
      assert.are.equal("invalid_request", err.kind)
    end)
  end)

  describe("classify", function()
    it("sorts failure texts by what the user can do", function()
      local cases = {
        { "Classic Personal Access Tokens (ghp_) are not supported", "token" },
        { "Bad credentials", "auth" },
        { "Please run copilot login", "auth" },
        { "Quota exceeded", "credit" },
        { "429 Too Many Requests", "credit" },
        { 'Model "x" from --model flag is not available.', "model" },
        { "something else entirely", "other" },
      }
      for _, case in ipairs(cases) do
        assert.are.equal(case[2], (cli.classify(case[1])), case[1])
      end
    end)
  end)
end)
