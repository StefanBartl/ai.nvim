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
    it("stays linear on a long run of blanks inside the response", function()
      local text = "a" .. (" "):rep(120000) .. "b"
      local started = vim.uv.hrtime()
      assert.are.equal(text, prompt.parse(text))
      assert.is_true((vim.uv.hrtime() - started) / 1e6 < 500)
    end)

    it("keeps leading whitespace and drops only one trailing line break", function()
      assert.are.equal("  local x = 1  ", prompt.parse("  local x = 1  \n"))
      assert.are.equal("local x = 1\n", prompt.parse("local x = 1\n\n"))
      assert.are.equal("local x = 1", prompt.parse("local x = 1\r\n"))
    end)

    it("keeps a leading space: it separates the insertion from the prefix", function()
      assert.are.equal(" 5", prompt.parse(" 5"))
    end)

    it("keeps a leading line break and the indentation after it", function()
      assert.are.equal("\n  body\nend", prompt.parse("\n  body\nend"))
    end)

    it("treats an all-blank answer as no suggestion", function()
      assert.are.equal("", prompt.parse("  \n\t \n"))
      assert.are.equal("", prompt.parse(""))
    end)

    it("asks the model for the whitespace that belongs at the cursor", function()
      local _, system = prompt.build("a", "b", "lua")
      assert.is_true(system:find("starts exactly at the cursor", 1, true) ~= nil)
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
