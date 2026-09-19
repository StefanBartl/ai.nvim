-- `lib.nvim.net.curl` is stubbed via `package.loaded` before each
-- `require("ai.providers.transport")` -- same pattern, and same reason, as
-- the provider specs: the module captures `curl` as a local upvalue at
-- require-time.
---@diagnostic disable: need-check-nil
describe("ai.providers.transport", function()
  local captured

  ---Stub curl, recording the opts each tier was called with.
  ---@param on_done? fun(handlers: table)
  local function stub_curl(on_done)
    captured = {}
    package.loaded["lib.nvim.net.curl"] = {
      fetch_json = function(url, opts, cb)
        captured = { url = url, opts = opts }
        cb(true, { ok = true }, { code = 0 })
      end,
      fetch_stream = function(url, opts, handlers)
        captured = { url = url, opts = opts, handlers = handlers }
        if on_done then
          on_done(handlers)
        end
        return { kill = function() end }
      end,
    }
  end

  before_each(function()
    package.loaded["ai.providers.transport"] = nil
  end)

  after_each(function()
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.transport"] = nil
  end)

  ---@param extra? integer bytes past the inline ceiling
  ---@return string
  local function oversized_body(extra)
    local transport = require("ai.providers.transport")
    return string.rep("x", transport.MAX_INLINE_BODY_BYTES + (extra or 1))
  end

  ---The `@file` argument curl was told to read the body from, or nil.
  ---@return string|nil
  local function body_file_from(opts)
    local args = opts.raw_args or {}
    for i, arg in ipairs(args) do
      if arg == "--data-binary" then
        return (args[i + 1] or ""):sub(2) -- strip the leading "@"
      end
    end
    return nil
  end

  describe("body routing", function()
    it("leaves a small body inline, as curl's own -d argument", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json("https://example.test", { body = '{"a":1}' }, function() end)
      assert.are.equal('{"a":1}', captured.opts.body)
      assert.is_nil(body_file_from(captured.opts))
    end)

    it("routes a body past the ceiling through a temp file instead", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      local body = oversized_body()
      transport.post_json("https://example.test", { body = body }, function() end)

      assert.is_nil(captured.opts.body)
      local path = body_file_from(captured.opts)
      assert.is_not_nil(path)
      -- The callback already ran (the stub is synchronous), so the file is
      -- gone by now -- what matters is that curl was pointed at one.
      assert.is_true(path:find("%.json$") ~= nil)
    end)

    it("writes the exact body bytes to that file", function()
      local seen
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          local path = body_file_from(opts)
          local f = assert(io.open(path, "rb"))
          seen = f:read("*a")
          f:close()
          cb(true, {}, { code = 0 })
        end,
      }
      local transport = require("ai.providers.transport")
      local body = oversized_body()
      transport.post_json("https://example.test", { body = body }, function() end)
      assert.are.equal(body, seen)
    end)

    it("removes the temp file once the request is done", function()
      local path
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          path = body_file_from(opts)
          cb(true, {}, { code = 0 })
        end,
      }
      local transport = require("ai.providers.transport")
      transport.post_json("https://example.test", { body = oversized_body() }, function() end)
      assert.are.equal(0, vim.fn.filereadable(path))
    end)

    it("removes the temp file after a stream ends, too", function()
      local path
      stub_curl(function(handlers)
        path = body_file_from(captured.opts)
        handlers.on_done({ code = 0 })
      end)
      local transport = require("ai.providers.transport")
      transport.stream_json("https://example.test", { body = oversized_body() }, {
        on_done = function() end,
      })
      assert.are.equal(0, vim.fn.filereadable(path))
    end)

    it("reports a short write instead of treating it as a successful body file", function()
      -- fs_write returns the number of bytes actually written, not a
      -- true/false flag -- a short write (e.g. ENOSPC) returns a positive
      -- number smaller than the body's length and must not be read as
      -- success (ERR-03).
      stub_curl()
      local uv = vim.uv or vim.loop
      local original_write = uv.fs_write
      ---@diagnostic disable-next-line: duplicate-set-field
      uv.fs_write = function(fd, data, offset)
        local real_written = original_write(fd, data, offset)
        return math.floor((real_written or 0) / 2)
      end

      local transport = require("ai.providers.transport")
      local body = oversized_body()
      local cb_called = false
      local err = transport.post_json("https://example.test", { body = body }, function()
        cb_called = true
      end)

      uv.fs_write = original_write

      assert.is_false(cb_called)
      assert.is_not_nil(err)
      assert.is_true(err:find("cannot write request body file", 1, true) ~= nil)
    end)

    it("survives a stream that reports both on_error and on_done", function()
      -- `fetch_stream` can reach both for one request; the second cleanup
      -- must be a no-op rather than deleting a since-reused temp name.
      local errors, dones = 0, 0
      stub_curl(function(handlers)
        handlers.on_error("read failed")
        handlers.on_done({ code = 1 })
      end)
      local transport = require("ai.providers.transport")
      transport.stream_json("https://example.test", { body = oversized_body() }, {
        on_error = function()
          errors = errors + 1
        end,
        on_done = function()
          dones = dones + 1
        end,
      })
      assert.are.equal(1, errors)
      assert.are.equal(1, dones)
    end)
  end)

  describe("--max-time", function()
    it("passes the request's own timeout to curl, in whole seconds", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json(
        "https://example.test",
        { body = "{}", timeout_ms = 90000 },
        function() end
      )
      local args = captured.opts.raw_args
      assert.are.equal("--max-time", args[1])
      assert.are.equal("90", args[2])
    end)

    it("rounds a sub-second timeout up to 1, never down to 0", function()
      -- curl reads `--max-time 0` as "no limit", which would turn the
      -- shortest timeout into none at all.
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json("https://example.test", { body = "{}", timeout_ms = 200 }, function() end)
      assert.are.equal("1", captured.opts.raw_args[2])
    end)

    it("defaults to 60s when the caller set no timeout", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json("https://example.test", { body = "{}" }, function() end)
      assert.are.equal("60", captured.opts.raw_args[2])
      -- The backstop is deliberately longer than the 60s the caller asked
      -- for -- see "the two timeouts" below for why.
      assert.is_true(captured.opts.timeout_ms > 60000)
    end)

    it("keeps raw_args a caller already set", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json(
        "https://example.test",
        { body = "{}", raw_args = { "--compressed" } },
        function() end
      )
      assert.are.equal("--compressed", captured.opts.raw_args[1])
      assert.are.equal("--max-time", captured.opts.raw_args[2])
    end)
  end)

  describe("the two timeouts", function()
    it("gives vim.system a longer deadline than curl's own --max-time", function()
      -- Both timers measure the same request, but vim.system's starts at
      -- spawn and curl's only once curl is running. Handing them the same
      -- number means vim.system always kills curl first (exit 124) and
      -- curl's own exit 28 -- the one that actually says "timed out" -- is
      -- unreachable. Verified against a black-hole server before this guard
      -- existed: 2000 ms in, 2000 ms out, code 124 every time.
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json(
        "https://example.test",
        { body = "{}", timeout_ms = 5000 },
        function() end
      )
      local args = captured.opts.raw_args
      assert.are.equal("5", args[2])
      assert.is_true(
        captured.opts.timeout_ms > 5000,
        "vim.system's backstop must outlast curl's --max-time, got "
          .. tostring(captured.opts.timeout_ms)
      )
    end)

    it("keeps that margin wider than --max-time's rounding up", function()
      -- 1500 ms rounds up to a 2 s --max-time; the backstop has to clear
      -- 2000 ms, not 1500 ms, or the rounding alone loses the race.
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json(
        "https://example.test",
        { body = "{}", timeout_ms = 1500 },
        function() end
      )
      assert.are.equal("2", captured.opts.raw_args[2])
      assert.is_true(captured.opts.timeout_ms > 2000)
    end)
  end)

  describe("a curl that cannot be started", function()
    it("reports it instead of letting the error escape", function()
      -- vim.system raises on ENOENT, and util.executable caches a successful
      -- probe -- so a curl removed mid-session gets this far. Unguarded the
      -- caller's callback never fires at all.
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function()
          error("ENOENT: no such file or directory (cmd): 'curl'")
        end,
      }
      local transport = require("ai.providers.transport")
      local fired = false
      local err
      local ok = pcall(function()
        err = transport.post_json("https://example.test", { body = "{}" }, function()
          fired = true
        end)
      end)
      assert.is_true(ok, "post_json must not propagate the spawn failure")
      assert.is_false(fired)
      assert.is_true(err:find("could not start curl", 1, true) ~= nil)
    end)

    it("removes the body temp file on that path too", function()
      local path
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts)
          path = body_file_from(opts)
          error("spawn failed")
        end,
      }
      local transport = require("ai.providers.transport")
      transport.post_json("https://example.test", { body = oversized_body() }, function() end)
      assert.is_not_nil(path)
      assert.are.equal(0, vim.fn.filereadable(path))
    end)

    it("does the same for a stream", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function()
          error("spawn failed")
        end,
      }
      local transport = require("ai.providers.transport")
      local process, err
      local ok = pcall(function()
        process, err = transport.stream_json("https://example.test", { body = "{}" }, {})
      end)
      assert.is_true(ok)
      assert.is_nil(process)
      assert.is_true(err:find("could not start curl", 1, true) ~= nil)
    end)
  end)

  describe("callback contract", function()
    it("hands the raw process object through to the caller", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(false, "curl exited 28", { code = 28, stderr = "" })
        end,
      }
      local transport = require("ai.providers.transport")
      local seen_obj
      transport.post_json("https://example.test", { body = "{}" }, function(_, _, obj)
        seen_obj = obj
      end)
      -- Without this the exit code never reaches the provider, and a timeout
      -- is indistinguishable from any other transport failure.
      assert.are.equal(28, seen_obj.code)
    end)
  end)
end)
