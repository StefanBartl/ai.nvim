-- ai.ui.panel's own logic (delta accumulation across `append()` calls,
-- idempotent cancel, snapshot-based cancel_all) does not need a real
-- `ui.kit` surface or `lib.nvim.progress` indicator rendering -- only the
-- shape those two seams hand back. Both are stubbed via `package.loaded`
-- before each fresh `require("ai.ui.panel")`, same upvalue-binding reason
-- providers_claude_spec.lua's module doc gives for `lib.nvim.net.curl`.
---@diagnostic disable: need-check-nil
describe("ai.ui.panel", function()
  ---@return table surface stub tracking `.lines` (mirroring the real
  ---`ui.kit.surface`'s buffer content across whichever of `set_lines`/
  ---`set_last_line`/`append_lines` panel.lua calls) plus a call counter per
  ---method, so tests can assert panel.lua never falls back to a full
  ---`set_lines` rewrite during streaming.
  local function make_surface_stub()
    local surface = {
      closed = false,
      lines = { "" },
      on_close_cb = nil,
      set_lines_calls = 0,
      set_last_line_calls = 0,
      append_lines_calls = 0,
    }
    function surface:set_lines(lines)
      self.set_lines_calls = self.set_lines_calls + 1
      self.lines = lines
    end
    function surface:set_last_line(text)
      self.set_last_line_calls = self.set_last_line_calls + 1
      self.lines[#self.lines] = text
    end
    function surface:append_lines(new_lines)
      self.append_lines_calls = self.append_lines_calls + 1
      for _, line in ipairs(new_lines) do
        self.lines[#self.lines + 1] = line
      end
    end
    function surface:on_close(cb)
      self.on_close_cb = cb
    end
    return surface
  end

  ---@return table progress stub, tracking finish/cancel/update calls
  local function make_progress_stub()
    local progress = { finished = nil, cancelled = false, updates = {}, on_cancel_cb = nil }
    function progress:update(opts)
      self.updates[#self.updates + 1] = opts
    end
    function progress:finish(text)
      self.finished = text or true
    end
    function progress:cancel()
      self.cancelled = true
    end
    function progress:on_cancel(cb)
      self.on_cancel_cb = cb
    end
    return progress
  end

  local surface_stub, progress_stub

  before_each(function()
    package.loaded["ai.ui.panel"] = nil
    surface_stub = make_surface_stub()
    progress_stub = make_progress_stub()
    package.loaded["ui.kit"] = {
      surface = {
        open = function()
          return surface_stub
        end,
      },
    }
    package.loaded["lib.nvim.progress"] = {
      create = function()
        return progress_stub
      end,
    }
    package.loaded["lib.nvim.safe_api"] = {
      safe_call = function(fn)
        local ok, err = pcall(fn)
        return ok, nil, err
      end,
    }
  end)

  after_each(function()
    package.loaded["ai.ui.panel"] = nil
    package.loaded["ui.kit"] = nil
    package.loaded["lib.nvim.progress"] = nil
    package.loaded["lib.nvim.safe_api"] = nil
  end)

  it("open() builds a surface and a progress handle, and wires on_close to cancel", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({ title = "AI" })
    assert.are.equal(surface_stub, panel.surface)
    assert.are.equal(progress_stub, panel.progress)
    assert.is_function(surface_stub.on_close_cb)
  end)

  it("append() accumulates a single-line delta onto the last line", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    panel_mod.append(panel, "Hel")
    panel_mod.append(panel, "lo")
    assert.are.same({ "Hello" }, panel.lines)
    assert.are.same({ "Hello" }, surface_stub.lines)
  end)

  it("append() splits a delta containing newlines across multiple lines", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    panel_mod.append(panel, "line one\nline two")
    panel_mod.append(panel, " continued\nline three")
    assert.are.same({ "line one", "line two continued", "line three" }, panel.lines)
    assert.are.same(panel.lines, surface_stub.lines)
  end)

  it("append() updates the surface incrementally, never rewriting the whole buffer", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    panel_mod.append(panel, "line one\nline two")
    panel_mod.append(panel, " continued\nline three")
    assert.are.equal(0, surface_stub.set_lines_calls)
    assert.are.equal(2, surface_stub.set_last_line_calls)
    assert.are.equal(2, surface_stub.append_lines_calls)
  end)

  it("append('') is a no-op -- no progress update, no line change", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    panel_mod.append(panel, "")
    assert.are.same({ "" }, panel.lines)
    assert.are.equal(0, #progress_stub.updates)
  end)

  it("append() marks the progress indicator as streaming", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    panel_mod.append(panel, "x")
    assert.are.equal("streaming...", progress_stub.updates[1].text)
  end)

  it("finish() stops the progress indicator and clears the process handle", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    panel_mod.attach_process(panel, { kill = function() end })
    panel_mod.finish(panel, "[end_turn]")
    assert.are.equal("[end_turn]", progress_stub.finished)
    assert.is_nil(panel.process)
  end)

  it("cancel() kills the attached process and finishes/cancels the progress indicator", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    local killed_with
    panel_mod.attach_process(panel, {
      kill = function(_, signal)
        killed_with = signal
      end,
    })
    panel_mod.cancel(panel)
    assert.are.equal(15, killed_with)
    assert.is_true(progress_stub.cancelled)
    assert.is_nil(panel.process)
  end)

  it("cancel() with no attached process only cancels the progress indicator", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    assert.has_no.errors(function()
      panel_mod.cancel(panel)
    end)
    assert.is_true(progress_stub.cancelled)
  end)

  it("cancel() is idempotent -- a second call does not re-kill or error", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    local kill_calls = 0
    panel_mod.attach_process(panel, {
      kill = function()
        kill_calls = kill_calls + 1
      end,
    })
    panel_mod.cancel(panel)
    panel_mod.cancel(panel)
    assert.are.equal(1, kill_calls)
  end)

  it("the panel's own on_close callback calls cancel()", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    local killed = false
    panel_mod.attach_process(panel, {
      kill = function()
        killed = true
      end,
    })
    surface_stub.on_close_cb()
    assert.is_true(killed)
    assert.is_true(progress_stub.cancelled)
  end)

  it("the progress handle's own on_cancel callback calls cancel() too", function()
    local panel_mod = require("ai.ui.panel")
    local panel = panel_mod.open({})
    local killed = false
    panel_mod.attach_process(panel, {
      kill = function()
        killed = true
      end,
    })
    progress_stub.on_cancel_cb()
    assert.is_true(killed)
  end)

  it("cancel_all() cancels every open panel", function()
    local panel_mod = require("ai.ui.panel")
    local killed = { false, false }

    local p1 = panel_mod.open({})
    panel_mod.attach_process(p1, {
      kill = function()
        killed[1] = true
      end,
    })

    -- A second panel needs its own surface/progress stub instances -- both
    -- `ui.kit.surface.open`/`lib.nvim.progress.create` are re-stubbed here so
    -- `open()` doesn't hand back the same `surface_stub`/`progress_stub` pair
    -- for both panels.
    local surface2, progress2 = make_surface_stub(), make_progress_stub()
    package.loaded["ui.kit"].surface.open = function()
      return surface2
    end
    package.loaded["lib.nvim.progress"].create = function()
      return progress2
    end
    local p2 = panel_mod.open({})
    panel_mod.attach_process(p2, {
      kill = function()
        killed[2] = true
      end,
    })

    panel_mod.cancel_all()
    assert.is_true(killed[1])
    assert.is_true(killed[2])
  end)

  it("cancel_all() on an empty panel list is a no-op", function()
    local panel_mod = require("ai.ui.panel")
    assert.has_no.errors(function()
      panel_mod.cancel_all()
    end)
  end)
end)
