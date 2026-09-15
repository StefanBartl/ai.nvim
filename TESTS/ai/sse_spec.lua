-- The test body itself is the guard against a nil field, same reasoning as
-- providers_claude_spec.lua.
---@diagnostic disable: need-check-nil
describe("ai.providers.sse", function()
  local sse = require("ai.providers.sse")

  describe("data_payload", function()
    it("extracts the payload after 'data:', with or without a space", function()
      assert.are.equal("{}", sse.data_payload("data: {}"))
      assert.are.equal("{}", sse.data_payload("data:{}"))
    end)

    it("returns nil for a line that is not an SSE data line", function()
      assert.is_nil(sse.data_payload("event: message_start"))
      assert.is_nil(sse.data_payload(""))
    end)
  end)

  describe("recover_error_body", function()
    it("returns nil for an empty list of lines", function()
      assert.is_nil(sse.recover_error_body({}))
    end)

    it("joins and decodes a pretty-printed multi-line JSON error body", function()
      local decoded = sse.recover_error_body({
        "{",
        '  "type": "error",',
        '  "error": {"message": "bad request"}',
        "}",
      })
      assert.is_table(decoded)
      assert.are.equal("error", decoded.type)
      assert.are.equal("bad request", decoded.error.message)
    end)

    it("returns nil when the joined lines are not valid JSON", function()
      assert.is_nil(sse.recover_error_body({ "not json at all" }))
    end)

    it("returns nil when the decoded JSON is not a table", function()
      assert.is_nil(sse.recover_error_body({ "42" }))
    end)
  end)

  describe("recover_error_body (property)", function()
    -- A grab-bag of fragments that show up across the real failure shapes
    -- this module exists for: valid pretty-printed JSON lines, garbage
    -- text, empty lines and stray punctuation -- shuffled into arbitrary
    -- line lists to check the "never throws" contract the module doc
    -- promises, independent of what the lines actually contain.
    local fragments = {
      "{",
      "}",
      '  "type": "error",',
      '  "error": {"message": "bad request"}',
      "",
      "not json at all",
      "42",
      '{"a": 1',
      "]}",
      "data: {}",
    }

    local function random_lines()
      local lines = {}
      for i = 1, math.random(0, 8) do
        lines[i] = fragments[math.random(#fragments)]
      end
      return lines
    end

    it("never throws for an arbitrary list of lines, and only returns nil or a table", function()
      for _ = 1, 200 do
        local ok, result = pcall(sse.recover_error_body, random_lines())
        assert.is_true(ok)
        assert.is_true(result == nil or type(result) == "table")
      end
    end)
  end)
end)
