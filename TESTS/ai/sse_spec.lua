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
end)
