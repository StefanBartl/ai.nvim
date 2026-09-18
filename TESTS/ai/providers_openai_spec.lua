-- Same `package.loaded` stubbing approach as providers_claude_spec.lua --
-- see that file's module doc for why the stub must land before each fresh
-- `require("ai.providers.openai")`.
--
-- Same need-check-nil suppression reasoning as that file: the test body
-- itself is the guard.
---@diagnostic disable: need-check-nil
describe("ai.providers.openai", function()
  local original_key

  before_each(function()
    original_key = vim.env.OPENAI_API_KEY
    vim.env.OPENAI_API_KEY = "test-key"
    package.loaded["ai.providers.openai"] = nil
    -- `ai.providers.transport` sits between this provider and
    -- `lib.nvim.net.curl` and captures `curl` as its own require-time
    -- upvalue too, so it has to be dropped alongside the provider --
    -- otherwise the second test in this file runs against the first's stub.
    package.loaded["ai.providers.transport"] = nil
  end)

  after_each(function()
    vim.env.OPENAI_API_KEY = original_key
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.openai"] = nil
    package.loaded["ai.providers.transport"] = nil
  end)

  describe("ask", function()
    it("maps a successful Chat Completions response to Ai.Response", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, {
            choices = { { message = { content = "hello" }, finish_reason = "stop" } },
            usage = { total_tokens = 3 },
          })
        end,
      }
      local openai = require("ai.providers.openai")
      local ok, res
      openai.ask({ prompt = "hi" }, function(a, b)
        ok, res = a, b
      end)
      assert.is_true(ok)
      assert.are.equal("hello", res.text)
      assert.are.equal("openai", res.provider)
      assert.are.equal("stop", res.stop_reason)
    end)

    it("reports a Chat Completions error body as a failure", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { error = { message = "invalid_api_key" } })
        end,
      }
      local openai = require("ai.providers.openai")
      local ok, err
      openai.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("invalid_api_key", 1, true) ~= nil)
    end)

    it("fails without calling curl when OPENAI_API_KEY is unset", function()
      vim.env.OPENAI_API_KEY = nil
      local called = false
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function()
          called = true
        end,
      }
      local openai = require("ai.providers.openai")
      local ok, err
      openai.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.is_false(called)
      assert.are.equal("missing_api_key", err.kind)
    end)

    it("fails with invalid_response rather than raising on a non-object 200", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, 42, { code = 0 })
        end,
      }
      local openai = require("ai.providers.openai")
      local ok, err
      local raised = not pcall(function()
        openai.ask({ prompt = "hi" }, function(a, b)
          ok, err = a, b
        end)
      end)
      assert.is_false(raised)
      assert.is_false(ok)
      assert.are.equal("invalid_response", err.kind)
    end)

    it("sends the API key as a bearer_token, not a secret header", function()
      local seen_bearer, seen_secret_headers
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          seen_bearer = opts.bearer_token
          seen_secret_headers = opts.secret_headers
          cb(true, { choices = {} }, { code = 0 })
        end,
      }
      local openai = require("ai.providers.openai")
      openai.ask({ prompt = "hi" }, function() end)
      assert.are.equal("test-key", seen_bearer)
      assert.is_nil(seen_secret_headers)
    end)
  end)

  describe("stream", function()
    it("accumulates choices[1].delta.content and reports finish_reason on_done", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk('data: {"choices":[{"delta":{"content":"He"}}]}')
          handlers.on_chunk(
            'data: {"choices":[{"delta":{"content":"llo"},"finish_reason":"stop"}]}'
          )
          handlers.on_chunk("data: [DONE]")
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local openai = require("ai.providers.openai")
      local chunks, done_res = {}, nil
      openai.stream({ prompt = "hi" }, {
        on_chunk = function(d)
          chunks[#chunks + 1] = d
        end,
        on_done = function(r)
          done_res = r
        end,
      })
      assert.are.same({ "He", "llo" }, chunks)
      assert.are.equal("Hello", done_res.text)
      assert.are.equal("stop", done_res.stop_reason)
    end)

    it("recovers a fatal error that arrives as a plain, non-SSE JSON body", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          for _, line in ipairs({
            "{",
            '  "error": {"message": "invalid_api_key"}',
            "}",
          }) do
            handlers.on_chunk(line)
          end
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local openai = require("ai.providers.openai")
      local err
      openai.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("invalid_api_key", 1, true) ~= nil)
    end)

    it("reports a non-zero curl exit as on_error", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_done({ code = 7, signal = 0, stdout = "", stderr = "connection refused" })
        end,
      }
      local openai = require("ai.providers.openai")
      local err
      openai.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("network_error", err.kind)
    end)

    it("fails without calling curl when OPENAI_API_KEY is unset", function()
      vim.env.OPENAI_API_KEY = nil
      local called = false
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function()
          called = true
        end,
      }
      local openai = require("ai.providers.openai")
      local err
      openai.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.is_false(called)
      assert.are.equal("missing_api_key", err.kind)
    end)
  end)

  describe("attachments", function()
    local pic = { kind = "image", media_type = "image/png", data = "AAA" }
    local pdf = { kind = "document", media_type = "application/pdf", data = "BBB" }

    ---Decode the JSON body the provider handed to curl.
    ---@param req table
    ---@return table
    local function body_for(req)
      local seen
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          seen = opts.body
          cb(true, { choices = {} }, { code = 0 })
        end,
      }
      local openai = require("ai.providers.openai")
      openai.ask(req, function() end)
      return vim.json.decode(seen)
    end

    it("keeps content a plain string when there is nothing but the prompt", function()
      local body = body_for({ prompt = "hi" })
      assert.are.equal("hi", body.messages[1].content)
    end)

    it("splices the media type into a data: URI for an image_url part", function()
      local body = body_for({ prompt = "read this", attachments = { pic } })
      local content = body.messages[1].content
      assert.are.equal(2, #content)
      assert.are.equal("image_url", content[1].type)
      assert.are.equal("data:image/png;base64,AAA", content[1].image_url.url)
      assert.are.equal("text", content[2].type)
      assert.are.equal("read this", content[2].text)
    end)

    it(
      "rejects a document attachment without calling curl -- Chat Completions has no document slot here",
      function()
        local called = false
        package.loaded["lib.nvim.net.curl"] = {
          fetch_json = function()
            called = true
          end,
        }
        local openai = require("ai.providers.openai")
        local ok, err
        openai.ask({ prompt = "hi", attachments = { pdf } }, function(a, b)
          ok, err = a, b
        end)
        assert.is_false(ok)
        assert.is_false(called)
        assert.are.equal("invalid_request", err.kind)
      end
    )
  end)

  describe("api_key override", function()
    it("uses req.api_key in place of the environment variable", function()
      local seen
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          seen = opts.bearer_token
          cb(true, { choices = {} }, { code = 0 })
        end,
      }
      local openai = require("ai.providers.openai")
      openai.ask({ prompt = "hi", api_key = "from-caller" }, function() end)
      assert.are.equal("from-caller", seen)
    end)
  end)

  describe("available", function()
    it("is false with neither an env var nor a request key", function()
      vim.env.OPENAI_API_KEY = nil
      local openai = require("ai.providers.openai")
      assert.is_false(openai.available())
    end)

    it("counts a request's own api_key towards availability", function()
      vim.env.OPENAI_API_KEY = nil
      local openai = require("ai.providers.openai")
      assert.is_true(openai.available({ prompt = "hi", api_key = "from-caller" }))
    end)
  end)
end)
