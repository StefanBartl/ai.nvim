describe("ai.completion.prompt", function()
  local prompt = require("ai.completion.prompt")

  describe("build", function()
    it("includes the filetype, prefix and suffix", function()
      local text, system = prompt.build("local x = 1\n", "\nreturn x", "lua")
      assert.is_true(text:find("Filetype: lua", 1, true) ~= nil)
      assert.is_true(text:find("local x = 1", 1, true) ~= nil)
      assert.is_true(text:find("return x", 1, true) ~= nil)
      assert.is_string(system)
      assert.is_true(system:find("Do not explain", 1, true) ~= nil)
    end)

    it("falls back to a generic filetype label when empty", function()
      local text = prompt.build("a", "b", "")
      assert.is_true(text:find("Filetype: text", 1, true) ~= nil)
    end)
  end)

  describe("parse", function()
    it("returns plain text unchanged, trimmed", function()
      assert.are.equal("local x = 1", prompt.parse("  local x = 1  \n"))
    end)

    it("strips a fenced code block with a language tag", function()
      assert.are.equal("local x = 1", prompt.parse("```lua\nlocal x = 1\n```"))
    end)

    it("strips a fenced code block with no language tag", function()
      assert.are.equal("local x = 1", prompt.parse("```\nlocal x = 1\n```"))
    end)

    it("keeps a multi-line fenced block intact", function()
      assert.are.equal(
        "local x = 1\nlocal y = 2",
        prompt.parse("```lua\nlocal x = 1\nlocal y = 2\n```")
      )
    end)

    it("returns an empty string for a non-string input", function()
      assert.are.equal("", prompt.parse(nil))
    end)
  end)
end)
