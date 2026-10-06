-- The provider is exercised against a fake `claude` (fixtures/fake_claude.lua,
-- run through the test Neovim itself), so these specs cover what ai.nvim does
-- -- argv, stdin, environment, event parsing, error mapping -- without a
-- network, an account or a billing balance. The fake mirrors the documented
-- stream-json shape; it is not a recording of a successful live call.
---@diagnostic disable: need-check-nil
local FAKE = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  .. "/fixtures/fake_claude.lua"

-- Every credential source the CLI's authentication precedence ranks above its
-- own /login (code.claude.com/docs/en/authentication): they must never reach
-- the child, or a stray variable silently bills another account.
local STRIPPED = {
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "CLAUDE_CODE_USE_BEDROCK",
  "CLAUDE_CODE_USE_VERTEX",
  "CLAUDE_CODE_USE_FOUNDRY",
  "CLAUDE_CODE_USE_ANTHROPIC_AWS",
  "CLAUDE_CODE_USE_MANTLE",
  "ANTHROPIC_PROFILE",
  "ANTHROPIC_FEDERATION_RULE_ID",
  "ANTHROPIC_ORGANIZATION_ID",
}
-- What it needs, or what was left alone on purpose (a company gateway, the
-- `claude auth login` provisioning input): these must reach it.
local KEPT = {
  "CLAUDE_CONFIG_DIR",
  "CLAUDE_CODE_GIT_BASH_PATH",
  "ANTHROPIC_BASE_URL",
  "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
}
-- Set by the provider itself, whatever the editor was started with.
local FORCED = "CLAUDE_CODE_DISABLE_ATTACHMENTS"

-- Their state when this file loaded, for the last spec: nothing may leak out.
local ALL = vim.list_extend(vim.list_extend({ FORCED }, STRIPPED), KEPT)
local INITIAL = {}
for _, name in ipairs(ALL) do
  INITIAL[name] = vim.env[name] or false
end

describe("ai.providers.claude_cli", function()
  local cli, saved_env, real_system

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

  before_each(function()
    package.loaded["ai.providers.claude_cli"] = nil
    cli = require("ai.providers.claude_cli")
    cli.command = { vim.v.progpath, "-u", "NONE", "-l", FAKE }
    real_system = vim.system
    -- `false` stands for "was unset": a nil value would leave no key behind for
    -- after_each to find, and the variable would stay set (ERR-61).
    saved_env = {}
    for _, list in ipairs({ STRIPPED, KEPT, { FORCED } }) do
      for _, name in ipairs(list) do
        saved_env[name] = vim.env[name] or false
      end
    end
  end)

  after_each(function()
    vim.system = real_system
    for name, value in pairs(saved_env) do
      vim.env[name] = value or nil
    end
    package.loaded["ai.providers.claude_cli"] = nil
  end)

  it("is registered as an opt-in built-in without attachment support", function()
    local providers = require("ai.providers")
    providers.load_builtin()
    assert.is_truthy(providers.get("claude-cli"))
    assert.is_false(cli.capabilities.vision)
    assert.is_false(cli.capabilities.documents)
    assert.is_false(vim.tbl_contains(require("ai.config.DEFAULTS").provider_order, "claude-cli"))
  end)

  it("is available exactly when its command is on PATH", function()
    assert.is_true(cli.available())
    cli.command = { "definitely-not-a-claude-binary-xyz" }
    assert.is_false(cli.available())
  end)

  it("ask returns the streamed text and the provider id", function()
    local ok, res = ask({ prompt = "OK please" })
    assert.is_true(ok)
    assert.are.equal("Hello", res.text)
    assert.are.equal("claude-cli", res.provider)
    assert.are.same({ output_tokens = 2 }, res.usage)
  end)

  it("stream delivers each delta in order, then done with the whole text", function()
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

  it("falls back to the result text when no partial events arrive", function()
    local ok, res = ask({ prompt = "NOPARTIAL" })
    assert.is_true(ok)
    assert.are.equal("whole answer", res.text)
  end)

  it("uses the assistant event text when there is neither a delta nor a result text", function()
    local ok, res = ask({ prompt = "ASSISTANTONLY" })
    assert.is_true(ok)
    assert.are.equal("assistant only", res.text)
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

    it("receives the prompt on stdin and never in argv", function()
      local info = echo({ prompt = "secret customer text" })
      assert.is_truthy(info.stdin:find("secret customer text", 1, true))
      for _, a in ipairs(info.argv) do
        assert.is_nil(a:find("secret customer text", 1, true))
      end
    end)

    it("prefixes the system text onto stdin", function()
      local info = echo({ prompt = "q", system = "be brief" })
      assert.is_truthy(info.stdin:find("be brief", 1, true))
    end)

    it("passes a plain prompt through unchanged", function()
      assert.are.equal("ECHO\nq", echo({ prompt = "q" }).stdin)
    end)

    it("keeps a leading slash from being the first byte, or the CLI answers it itself", function()
      -- `claude -p` handles `/cost`, `/context`, ... locally even with
      -- --disable-slash-commands: no model call, and the local message would
      -- come back as a successful answer.
      for _, prompt in ipairs({ "/cost ECHO", "  /context what does this do ECHO" }) do
        local ok, res = ask({ prompt = prompt })
        assert.is_true(ok)
        assert.is_nil(res.text:find("isn't available", 1, true), "answered locally: " .. res.text)
        local info = vim.json.decode(res.text)
        assert.is_falsy(info.stdin:find("^/"))
        assert.is_truthy(info.stdin:find(prompt, 1, true), "the user text must arrive intact")
      end
    end)

    it("denies the Read tool so @path mentions cannot pull local files into the request", function()
      -- the CLI expands `@<path>` in the prompt itself (no tool call, no
      -- permission prompt); a deny rule is what stops it
      local argv = echo({}).argv
      local at = index_of(argv, "--settings")
      assert.is_truthy(at, "--settings missing")
      local deny = vim.json.decode(argv[at + 1]).permissions.deny
      assert.is_true(vim.tbl_contains(deny, "Read(**)"))
      assert.is_true(vim.tbl_contains(deny, "Read(//**)"))
    end)

    it("runs without tools, hooks or session state", function()
      local info = echo({})
      for _, flag in ipairs({
        "-p",
        "--safe-mode",
        "--no-session-persistence",
        "--disable-slash-commands",
        "stream-json",
        "--include-partial-messages",
      }) do
        assert.is_truthy(index_of(info.argv, flag), "missing " .. flag)
      end
      local at = index_of(info.argv, "--tools")
      assert.is_truthy(at, "--tools missing")
      assert.are.equal("", info.argv[at + 1])
    end)

    it("passes --model only when one is requested", function()
      assert.is_nil(index_of(echo({}).argv, "--model"))
      local argv = echo({ model = "sonnet" }).argv
      assert.are.equal("sonnet", argv[index_of(argv, "--model") + 1])
    end)

    it("removes the variables that override the login, keeps the rest", function()
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

    it(
      "switches the CLI's @-mention expansion off, whatever the editor was started with",
      function()
        -- second layer behind the deny rule; the text itself stays untouched
        vim.env[FORCED] = nil
        assert.are.equal("1", echo({}).disable_attachments)
        vim.env[FORCED] = "0"
        assert.are.equal("1", echo({}).disable_attachments)
      end
    )

    it("does not run in the editor's working directory", function()
      local info = echo({})
      assert.are_not.equal(vim.uv.cwd(), info.cwd)
    end)
  end)

  describe("errors", function()
    it("maps an is_error result (billing/auth) to api_error carrying its text", function()
      local ok, err = ask({ prompt = "BILLING" })
      assert.is_false(ok)
      assert.are.equal("api_error", err.kind)
      assert.is_truthy(err.message:find("Credit balance is too low", 1, true))
    end)

    it("reports a crash without any result event as network_error with stderr", function()
      local ok, err = ask({ prompt = "CRASH" })
      assert.is_false(ok)
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

    ---Run `stream` against a `vim.system` that streams `lines` and then exits as
    ---`exit` says -- the way a kill by signal looks on Unix (code 0, signal 15),
    ---which a real child on Windows never produces.
    ---@param lines string[] stdout lines, each a JSON event
    ---@param exit table what the exit callback receives
    ---@return string[] chunks, table|nil done, table|nil err
    local function stream_with_fake_exit(lines, exit)
      vim.system = function(_, opts, on_exit)
        vim.schedule(function()
          opts.stdout(nil, table.concat(lines, "\n") .. "\n")
          on_exit(vim.tbl_extend("force", { stdout = "", stderr = "" }, exit))
        end)
        return { kill = function() end }
      end
      local chunks, done, err = {}, nil, nil
      cli.stream({ prompt = "q" }, {
        on_chunk = function(t)
          chunks[#chunks + 1] = t
        end,
        on_done = function(res)
          done = res
        end,
        on_error = function(e)
          err = e
        end,
      })
      assert.is_true(vim.wait(5000, function()
        return done ~= nil or err ~= nil
      end, 10))
      return chunks, done, err
    end

    local function delta(text)
      return vim.json.encode({
        type = "stream_event",
        event = { type = "content_block_delta", delta = { type = "text_delta", text = text } },
      })
    end
    local RESULT = vim.json.encode({ type = "result", subtype = "success", result = "Hello" })

    it("treats a signal as a death even when the exit code is 0", function()
      -- Unix: a killed child reports code 0 and signal 15. Without the signal
      -- clause this cut-off "Hel" would be delivered as the finished answer.
      local chunks, done, err = stream_with_fake_exit({ delta("Hel") }, { code = 0, signal = 15 })
      assert.are.same({ "Hel" }, chunks)
      assert.is_nil(done)
      assert.are.equal("network_error", err.kind)
      assert.is_truthy(err.message:find("signal 15", 1, true))
    end)

    it("still accepts a complete result when a signal ended the process afterwards", function()
      local _, done, err = stream_with_fake_exit(
        { delta("Hel"), delta("lo"), RESULT },
        { code = 0, signal = 15 }
      )
      assert.is_nil(err)
      assert.are.equal("Hello", done.text)
    end)

    it("treats a clean exit with no result event and no text as an invalid response", function()
      -- Not an empty successful answer: the caller would show a blank result and
      -- the audit trail would call it a finished request.
      local ok, err = ask({ prompt = "NOEVENTS" })
      assert.is_false(ok)
      assert.are.equal("invalid_response", err.kind)
      assert.is_truthy(err.message:find("claude-cli", 1, true))
      assert.is_truthy(err.message:find("nothing to report", 1, true), "stderr is the only clue")
    end)

    it("reports the same on the stream path, without a chunk or a done", function()
      local chunks, done, err = stream_with_fake_exit({}, { code = 0, signal = 0 })
      assert.are.same({}, chunks)
      assert.is_nil(done)
      assert.are.equal("invalid_response", err.kind)
      assert.is_nil(err.message:find("[:%s]$"), "nothing dangles when stderr is empty")
    end)

    it("reports a timeout as such", function()
      local ok, err = ask({ prompt = "SLEEP", timeout_ms = 800 })
      assert.is_false(ok)
      assert.are.equal("timeout", err.kind)
    end)

    it("rejects an attachment before spawning anything", function()
      local ok, err = ask({
        prompt = "OK",
        attachments = { { kind = "image", media_type = "image/png", data = "AAAA" } },
      })
      assert.is_false(ok)
      assert.are.equal("invalid_request", err.kind)
    end)

    it("rejects an unsafe model name", function()
      local ok, err = ask({ prompt = "OK", model = "x; rm -rf /" })
      assert.is_false(ok)
      assert.are.equal("invalid_request", err.kind)
    end)

    it("reports a command that cannot be started", function()
      cli.command = { "definitely-not-a-claude-binary-xyz" }
      local ok, err = ask({ prompt = "OK" })
      assert.is_false(ok)
      assert.are.equal("network_error", err.kind)
    end)
  end)

  -- Last on purpose (a file's specs run in order): the specs above set variables
  -- that were unset when the file loaded, and after_each has to unset them again.
  it("leaves the environment as it found it", function()
    for _, name in ipairs(ALL) do
      assert.is_true(vim.env[name] == (INITIAL[name] or nil), name .. " leaked out of a spec")
    end
  end)
end)
