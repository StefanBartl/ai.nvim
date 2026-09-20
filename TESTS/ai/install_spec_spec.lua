-- docs/install.json is data, and data is where a typo goes unnoticed: nothing
-- in the plugin requires it, no `luacheck` run reads it, and a broken entry
-- surfaces only as a tool quietly missing from `:Lib deps show ai.nvim`. A tool
-- that is simply absent from a report looks exactly like a tool nobody
-- declared.
--
-- So: parse the real file with the real parser, insist it validates
-- completely, and pin what it declares against what the plugin actually uses.

describe("docs/install.json", function()
  local spec = require("lib.nvim.deps.spec")

  local root = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") .. "../..")
  local result, err = spec.load(root .. "/docs/install.json")

  local function tool(bin)
    for _, t in ipairs(result.tools) do
      if t.bin == bin then
        return t
      end
    end
  end

  it("is readable and validates with no errors", function()
    assert.is_not_nil(result, tostring(err))
    -- Zero, not "few": a rejected entry is silently dropped from `tools`, so a
    -- partial parse is indistinguishable from a shorter file.
    assert.are.equal(0, #result.errors)
  end)

  it("declares exactly the two tools the plugin shells out to", function()
    local bins = {}
    for _, t in ipairs(result.tools) do
      bins[#bins + 1] = t.bin
    end
    table.sort(bins)
    assert.are.equal("curl,ollama", table.concat(bins, ","))
  end)

  it("marks curl required -- every provider goes through it -- and ollama optional", function()
    assert.is_true(tool("curl").required)
    assert.is_false(tool("ollama").required)
  end)

  it("maps every tool to the package managers it can be installed with", function()
    for _, bin in ipairs({ "curl", "ollama" }) do
      assert.is_not_nil(tool(bin).pkg.winget, bin .. " has no winget entry")
      assert.is_not_nil(tool(bin).pkg.brew, bin .. " has no brew entry")
    end
  end)
end)
