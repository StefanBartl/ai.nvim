-- Test doubles below deliberately implement only the `Ai.Provider` fields
-- each test actually exercises (usually just `id`/`available`) -- the
-- registry itself never calls `ask`/`stream`, so completing them would only
-- add noise, not coverage.
---@diagnostic disable: missing-fields

describe("ai.providers", function()
  before_each(function()
    -- Every test gets a fresh registry (module-local `registered` table),
    -- so a fake provider registered in one test never leaks into the next.
    package.loaded["ai.providers"] = nil
  end)

  it("register/get round-trip a custom provider", function()
    local providers = require("ai.providers")
    providers.register({
      id = "fake",
      available = function()
        return true
      end,
    })
    assert.are.equal("fake", providers.get("fake").id)
  end)

  it("register overrides a previous registration under the same id", function()
    local providers = require("ai.providers")
    providers.register({ id = "fake", name = "first" })
    providers.register({ id = "fake", name = "second" })
    assert.are.equal("second", providers.get("fake").name)
  end)

  it("register rejects a provider with no string id", function()
    local providers = require("ai.providers")
    assert.has_error(function()
      providers.register({})
    end)
  end)

  it("ids() lists every registered provider, sorted", function()
    local providers = require("ai.providers")
    providers.register({ id = "zeta" })
    providers.register({ id = "alpha" })
    assert.are.same({ "alpha", "zeta" }, providers.ids())
  end)

  it("resolve('auto', order) returns the first available provider in order", function()
    local providers = require("ai.providers")
    providers.register({
      id = "unavailable",
      available = function()
        return false
      end,
    })
    providers.register({
      id = "available",
      available = function()
        return true
      end,
    })
    local p, err = providers.resolve("auto", { "unavailable", "available" })
    assert.is_nil(err)
    assert.are.equal("available", p.id)
  end)

  it("resolve('auto', order) errors when nothing in order is available", function()
    local providers = require("ai.providers")
    providers.register({
      id = "nope",
      available = function()
        return false
      end,
    })
    local p, err = providers.resolve("auto", { "nope" })
    assert.is_nil(p)
    assert.is_string(err)
  end)

  it("resolve(explicit_id, order) checks that provider directly, ignoring order", function()
    local providers = require("ai.providers")
    providers.register({
      id = "direct",
      available = function()
        return true
      end,
    })
    local p, err = providers.resolve("direct", {})
    assert.is_nil(err)
    assert.are.equal("direct", p.id)
  end)

  it("resolve(explicit_id) errors for an unregistered id", function()
    local providers = require("ai.providers")
    local p, err = providers.resolve("does-not-exist", {})
    assert.is_nil(p)
    assert.is_string(err)
  end)

  it("resolve(explicit_id) errors when that provider is registered but unavailable", function()
    local providers = require("ai.providers")
    providers.register({
      id = "down",
      available = function()
        return false
      end,
    })
    local p, err = providers.resolve("down", {})
    assert.is_nil(p)
    assert.is_string(err)
  end)

  it(
    "resolve(explicit_id) treats a provider with no .available field as unavailable, not a crash",
    function()
      -- Stands in for a lazy proxy whose module failed to require(): every
      -- field, including `available`, comes back nil (see providers/init.lua's
      -- `make_lazy`). resolve() must not call a nil field.
      local providers = require("ai.providers")
      providers.register({ id = "broken" })
      local p, err = providers.resolve("broken", {})
      assert.is_nil(p)
      assert.is_string(err)
    end
  )

  it(
    "resolve('auto', order) skips a provider with no .available field instead of crashing",
    function()
      local providers = require("ai.providers")
      providers.register({ id = "broken" })
      providers.register({
        id = "fine",
        available = function()
          return true
        end,
      })
      local p, err = providers.resolve("auto", { "broken", "fine" })
      assert.is_nil(err)
      assert.are.equal("fine", p.id)
    end
  )

  it("load_builtin() registers loomai, but DEFAULTS.provider_order leaves it opt-in", function()
    -- Registration and reachability-through-"auto" are deliberately
    -- separate: see ai.providers's module doc. config_spec.lua's own
    -- default-provider_order assertion is the other half of this contract.
    local providers = require("ai.providers")
    providers.load_builtin()
    assert.is_true(vim.tbl_contains(providers.ids(), "loomai"))
  end)

  it("'auto' never reaches a provider absent from order, even if registered", function()
    local providers = require("ai.providers")
    -- Stands in for "loomai": present in the registry, but never listed in
    -- provider_order -- ai.providers's whole point is that "auto" cannot
    -- reach it by accident.
    providers.register({
      id = "sidelined",
      available = function()
        return true
      end,
    })
    local p, err = providers.resolve("auto", { "does-not-exist-either" })
    assert.is_nil(p)
    assert.is_string(err)
  end)
end)
