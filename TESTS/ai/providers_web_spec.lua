---@diagnostic disable: missing-fields, need-check-nil

-- `capabilities.web` says whether a provider's request can use web search in a
-- single turn. No built-in wires a web-search parameter into its request, so
-- every one must say `false` explicitly: a caller (casedesk) checks the field
-- instead of guessing from the provider's name, and an absent field would read
-- as "unknown" rather than "no".
describe("ai.providers capabilities.web", function()
  local providers

  before_each(function()
    package.loaded["ai.providers"] = nil
    providers = require("ai.providers")
    providers.load_builtin()
  end)

  it("is an explicit false on every built-in provider", function()
    local ids = providers.ids()
    assert.is_true(#ids >= 6)
    for _, id in ipairs(ids) do
      local caps = providers.get(id).capabilities
      assert.are.equal(false, caps.web, id .. ": web must be an explicit false")
    end
  end)

  it("capability_names lists what a provider can do, in a fixed order", function()
    local names = providers.capability_names({
      capabilities = { web = true, documents = true, vision = true, streaming = true },
    })
    assert.are.same({ "streaming", "image", "document", "web" }, names)
  end)

  it("capability_names is empty for a provider without capabilities", function()
    assert.are.same({}, providers.capability_names({ id = "bare" }))
    assert.are.same({}, providers.capability_names(nil))
  end)

  it(":Ai info shows the capabilities of each provider", function()
    local lines
    package.loaded["ui.kit"] = {
      popup = function(o)
        lines = o.lines
      end,
    }
    require("ai.config").setup({})
    require("ai.bindings.actions").info()
    package.loaded["ui.kit"] = nil
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("can: streaming, image, document", 1, true))
    assert.is_nil(text:find("web", 1, true), "no built-in claims web search")
  end)
end)
