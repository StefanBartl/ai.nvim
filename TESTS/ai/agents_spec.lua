-- Agent presets: `config.agents` / `config.agent`, how a request resolves
-- against the active agent, and `:Ai agent` with its keymap action.
-- A recording provider stands in for the network; `ui.kit` is not needed.
---@diagnostic disable: missing-fields, need-check-nil

describe("ai agents", function()
  local messages, original_notify, seen

  local function reset()
    for _, name in ipairs({
      "ai",
      "ai.config",
      "ai.providers",
      "ai.policy",
      "ai.bindings.actions",
      "ai.bindings.usrcmds",
    }) do
      package.loaded[name] = nil
    end
  end

  ---Register recording providers `fake` and `other`.
  local function providers()
    local reg = require("ai.providers")
    for _, id in ipairs({ "fake", "other" }) do
      reg.register({
        id = id,
        available = function()
          return true
        end,
        ask = function(req, cb)
          seen = req
          cb(true, { text = "ok", provider = id })
        end,
        stream = function()
          return nil
        end,
      })
    end
  end

  local function ask(req)
    req.prompt = req.prompt or "hi"
    require("ai").ask(req, function() end)
    return seen
  end

  before_each(function()
    reset()
    seen = nil
    messages = {}
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
  end)

  after_each(function()
    vim.notify = original_notify
    pcall(vim.api.nvim_del_user_command, "Ai")
  end)

  describe("config", function()
    it("has no agents by default", function()
      local cfg = require("ai.config").setup({})
      assert.are.same({}, cfg.agents)
      assert.is_false(cfg.agent)
      assert.is_nil(require("ai.config").agent())
    end)

    it("takes agents and an active agent without an unknown-key warning", function()
      local config = require("ai.config")
      config.setup({
        agents = { review = { provider = "fake", model = "m1", system = "You review." } },
        agent = "review",
      })
      local name, def = config.agent()
      assert.are.equal("review", name)
      assert.are.equal("m1", def.model)
      assert.are.same({}, config.issues())
      assert.are.equal(0, #messages)
    end)

    it("an active agent that does not exist is a config error: reported, none is active", function()
      local config = require("ai.config")
      config.setup({ agents = { a = { provider = "fake" } }, agent = "b" })
      assert.is_nil(config.agent())
      assert.is_false(config.get().agent)
      assert.is_truthy(
        config.issues()[1]:find('agent: "b" is not one of the configured agents', 1, true)
      )
      assert.is_truthy(messages[1]:find('"b"', 1, true))
    end)

    it("an agent with an unknown field is dropped and reported", function()
      local config = require("ai.config")
      config.setup({ agents = { good = { provider = "fake" }, bad = { modell = "x" } } })
      assert.is_nil(config.get().agents.bad)
      assert.is_not_nil(config.get().agents.good)
      assert.is_truthy(config.issues()[1]:find('unknown field "modell"', 1, true))
    end)

    it("an agent with a field of the wrong type, or no table, is dropped", function()
      local config = require("ai.config")
      config.setup({ agents = { a = { model = 5 }, b = "claude", c = { system = "" } } })
      assert.are.same({}, config.get().agents)
      assert.are.equal(3, #config.issues())
    end)

    it(
      "an agent name with whitespace is dropped (it could not be typed after :Ai agent)",
      function()
        local config = require("ai.config")
        config.setup({ agents = { ["two words"] = { provider = "fake" } } })
        assert.are.same({}, config.get().agents)
        assert.is_truthy(config.issues()[1]:find("whitespace", 1, true))
      end
    )

    it("an agent named `none` is dropped (`:Ai agent none` clears the agent)", function()
      local config = require("ai.config")
      config.setup({ agents = { none = { provider = "fake" } } })
      assert.are.same({}, config.get().agents)
      assert.is_truthy(config.issues()[1]:find("none", 1, true))
    end)

    it("a non-string agent is dropped to the default", function()
      local config = require("ai.config")
      config.setup({ agent = 5 })
      assert.is_false(config.get().agent)
      assert.is_truthy(config.issues()[1]:find("agent: invalid value", 1, true))
    end)
  end)

  describe("resolution", function()
    local function setup(opts)
      require("ai.config").setup(opts)
      require("ai.providers").load_builtin()
      providers()
    end

    it("with no agent a request resolves as before", function()
      setup({ provider = "fake", model = { fake = "cfg-model" } })
      local req = ask({})
      assert.are.equal("fake", req.provider)
      assert.are.equal("cfg-model", req.model)
      assert.is_nil(req.system)
    end)

    it("the agent supplies provider, model and system", function()
      setup({
        provider = "other",
        agents = { review = { provider = "fake", model = "agent-model", system = "You review." } },
        agent = "review",
      })
      local req = ask({})
      assert.are.equal("fake", req.provider)
      assert.are.equal("agent-model", req.model)
      assert.are.equal("You review.", req.system)
    end)

    it("what the request sets itself wins over the agent", function()
      setup({
        agents = { review = { provider = "fake", model = "agent-model", system = "agent system" } },
        agent = "review",
      })
      local req = ask({ provider = "other", model = "own-model", system = "own system" })
      assert.are.equal("other", req.provider)
      assert.are.equal("own-model", req.model)
      assert.are.equal("own system", req.system)
    end)

    it("the agent's model is not used for another provider", function()
      setup({
        model = { other = "other-default" },
        agents = { review = { provider = "fake", model = "agent-model" } },
        agent = "review",
      })
      local req = ask({ provider = "other" })
      assert.are.equal("other", req.provider)
      assert.are.equal("other-default", req.model)
    end)

    it("an agent with only a system prompt keeps the configured provider and model", function()
      setup({
        provider = "fake",
        model = { fake = "cfg-model" },
        agents = { terse = { system = "Be terse." } },
        agent = "terse",
      })
      local req = ask({})
      assert.are.equal("fake", req.provider)
      assert.are.equal("cfg-model", req.model)
      assert.are.equal("Be terse.", req.system)
    end)

    it("an agent's provider outside the policy is refused like any request for it", function()
      setup({
        policy = { allowed = { "other" } },
        agents = { review = { provider = "fake" } },
        agent = "review",
      })
      local ok, err
      require("ai").ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.is_nil(seen)
      assert.is_not_nil(err)
    end)
  end)

  describe("actions", function()
    local function setup(opts)
      require("ai.config").setup(opts)
      require("ai.providers").load_builtin()
      providers()
      return require("ai.bindings.actions")
    end

    it("set_agent() switches, `none` clears, an unknown name changes nothing", function()
      local actions = setup({ agents = { a = { provider = "fake" }, b = { model = "m" } } })
      local config = require("ai.config")
      actions.set_agent("a")
      assert.are.equal("a", config.agent())
      actions.set_agent("nope")
      assert.are.equal("a", config.agent())
      assert.is_truthy(messages[#messages]:find('unknown agent "nope"', 1, true))
      assert.is_truthy(messages[#messages]:find("a, b", 1, true))
      actions.set_agent("none")
      assert.is_nil(config.agent())
    end)

    it("set_agent() without a name reports the active agent and changes nothing", function()
      local actions = setup({ agents = { a = { provider = "fake", model = "m" } }, agent = "a" })
      actions.set_agent(nil)
      assert.is_truthy(messages[#messages]:find("a (provider=fake, model=m)", 1, true))
      assert.are.equal("a", require("ai.config").agent())
    end)

    it("set_agent() warns when the agent's provider is not allowed", function()
      local actions = setup({
        policy = { allowed = { "other" } },
        agents = { a = { provider = "fake" } },
      })
      actions.set_agent("a")
      assert.are.equal("a", require("ai.config").agent())
      assert.is_truthy(messages[#messages]:find("not on the allow-list", 1, true))
    end)

    it("next_agent() walks the names in order and wraps around", function()
      local actions = setup({ agents = { b = { model = "1" }, a = { model = "2" } } })
      local config = require("ai.config")
      actions.next_agent()
      assert.are.equal("a", config.agent())
      actions.next_agent()
      assert.are.equal("b", config.agent())
      actions.next_agent()
      assert.are.equal("a", config.agent())
    end)

    it("next_agent() with no agents says so", function()
      local actions = setup({})
      actions.next_agent()
      assert.is_truthy(messages[#messages]:find("no agents configured", 1, true))
    end)
  end)

  describe(":Ai agent", function()
    it("reaches the action and completes the configured names plus none", function()
      require("ai.config").setup({ agents = { review = { provider = "fake" }, draft = {} } })
      require("ai.providers").load_builtin()
      local got
      package.loaded["ai.bindings.actions"] = {
        set_agent = function(name)
          got = name
        end,
      }
      require("ai.bindings.usrcmds").setup()
      vim.cmd("Ai agent review")
      assert.are.equal("review", got)
      local choices = vim.fn.getcompletion("Ai agent ", "cmdline")
      assert.is_true(vim.tbl_contains(choices, "review"))
      assert.is_true(vim.tbl_contains(choices, "draft"))
      assert.is_true(vim.tbl_contains(choices, "none"))
      package.loaded["ai.bindings.actions"] = nil
    end)
  end)
end)
