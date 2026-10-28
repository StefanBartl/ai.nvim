--- ai.capture: context taken from the editor, redacted, shown, then sent.

describe("ai.capture", function()
  local capture

  local function esc()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  end

  ---@param lines string[]
  ---@return integer
  local function scratch(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  before_each(function()
    package.loaded["ai.capture"] = nil
    package.loaded["ai.bindings.actions"] = nil
    capture = require("ai.capture")
  end)

  after_each(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    esc()
  end)

  describe("redact", function()
    local env = { home = "C:\\Users\\Jane", user = "jane" }

    it("turns the home folder into ~ in every spelling a message may carry", function()
      assert.are.equal(
        "~\\a.lua, ~/b.lua, ~/x, ~/msys, ~\\\\esc",
        capture.redact(
          "C:\\Users\\Jane\\a.lua, C:/Users/Jane/b.lua, c:/users/jane/x, /c/Users/Jane/msys, C:\\\\Users\\\\Jane\\\\esc",
          env
        )
      )
    end)

    it("stops at a path segment: the home of jane is not the folder janet", function()
      assert.are.equal(
        "~/x and /home/janet/y",
        capture.redact("/home/jane/x and /home/janet/y", { home = "/home/jane", user = "zzz" })
      )
    end)

    it("never treats a drive or filesystem root as the home folder", function()
      assert.are.equal(
        "C:\\x and C:/y",
        capture.redact("C:\\x and C:/y", { home = "C:\\", user = "zzz" })
      )
    end)

    it("masks the user name as a word, not inside other words", function()
      assert.are.equal(
        "by <user>, see janet and jane_x; <user> only",
        capture.redact("by Jane, see janet and jane_x; JANE only", env)
      )
    end)

    it("masks a non-ASCII user name in its other cases too", function()
      assert.are.equal(
        "<user> and <user> and <user>",
        capture.redact("jürgen and JÜRGEN and Jürgen", { home = "/home/x", user = "jürgen" })
      )
    end)

    it("leaves a short user name alone (it would hit ordinary words)", function()
      assert.are.equal(
        "al is here",
        capture.redact("al is here", { home = "/home/al", user = "al" })
      )
    end)
  end)

  describe("the last message", function()
    it("is its last line, or the whole block of a Lua error", function()
      assert.are.equal("plain", capture.last_message_of({ "older", "plain", "" }))
      assert.are.equal(
        "E5108: Error executing lua: x.lua:1: boom\nstack traceback:\n\t[C]: in function 'error'\n\tx.lua:1: in main chunk",
        capture.last_message_of({
          "older",
          "E5108: Error executing lua: x.lua:1: boom",
          "stack traceback:",
          "\t[C]: in function 'error'",
          "\tx.lua:1: in main chunk",
        })
      )
      assert.is_nil(capture.last_message_of({ "", " " }))
    end)

    it("comes from :messages, redacted", function()
      vim.cmd("echomsg 'first message'")
      vim.cmd("echomsg 'Error in /nowhere-home/x.lua for nobodyuser'")
      local cap = capture.get("messages", { env = { home = "/nowhere-home", user = "nobodyuser" } })
      assert.is_table(cap)
      assert.are.equal("Error in ~/x.lua for <user>", cap.text)
    end)
  end)

  describe("get", function()
    local env = { home = "/nowhere-home", user = "nobodyuser" }

    it("takes the selection with its file and first line, or the lines it is given", function()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, "/nowhere-home/sel.lua")
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
      vim.api.nvim_buf_set_mark(buf, "<", 2, 0, {})
      vim.api.nvim_buf_set_mark(buf, ">", 3, 0, {})
      local cap = capture.get("selection", { env = env })
      assert.are.same({ "b\nc", 2 }, { cap.text, cap.line })
      assert.truthy(cap.file:find("^~[/\\]sel%.lua$"), cap.file)
      assert.are.equal("d", capture.get("selection", { line1 = 4, line2 = 4, env = env }).text)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("takes the lines around the cursor for buffer", function()
      local lines = {}
      for i = 1, 30 do
        lines[i] = "line " .. i
      end
      local buf = scratch(lines)
      vim.api.nvim_win_set_cursor(0, { 15, 0 })
      local cap = capture.get("buffer", { env = env })
      assert.are.equal(15 - capture.BUFFER_RADIUS, cap.line)
      assert.are.equal(2 * capture.BUFFER_RADIUS + 1, #vim.split(cap.text, "\n"))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("answers an unknown, an empty and a missing notify source with a reason", function()
      local cap, err = capture.get("clipboard", { env = env })
      assert.is_nil(cap)
      assert.truthy(err:find("unknown source", 1, true))
      local buf = scratch({})
      cap, err = capture.get("buffer", { env = env })
      assert.is_nil(cap)
      assert.truthy(err:find("nothing to capture", 1, true))
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.cmd("echomsg 'a message, not a notification'")
      cap, err = capture.get("notify", { env = env })
      assert.is_nil(cap, "a :messages line was passed off as a notification")
      assert.truthy(err:find("no notification recorded", 1, true))
    end)
  end)

  -- A Lua mapping in Visual mode runs before Visual mode ends: `'<`/`'>` still
  -- hold the previous selection then.
  it("visual_range reads the live selection, not the previous marks", function()
    local buf = scratch({ "1", "2", "3", "4", "5", "6" })
    local got
    vim.keymap.set("x", "<F2>", function()
      got = { capture.visual_range() }
    end, { buffer = buf })
    vim.api.nvim_feedkeys(
      "ggVj" .. vim.api.nvim_replace_termcodes("<F2>", true, false, true),
      "x",
      false
    )
    assert.are.same({ 1, 2 }, got, "first selection")
    vim.api.nvim_feedkeys(
      "4GVj" .. vim.api.nvim_replace_termcodes("<F2>", true, false, true),
      "x",
      false
    )
    assert.are.same({ 4, 5 }, got, "the second selection read the first one's marks")
    assert.are.equal("n", vim.fn.mode(), "Visual mode was not left")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("lines put the file first, so the preview shows (and can strike) it", function()
    local cap = { source = "selection", text = "x = 1", file = "~/a.lua", line = 7 }
    assert.are.same({ "-- ~/a.lua:7", "x = 1" }, capture.lines(cap))
    assert.are.equal("Context (selection):\n```\n-- ~/a.lua:7\nx = 1\n```", capture.format(cap))
    assert.are.equal("Context (selection):\n```\nx = 1\n```", capture.format(cap, "x = 1"))
  end)

  it("format widens the fence past any backtick run in the text", function()
    local cap = { source = "buffer", text = "a\n```lua\nx\n```\nb" }
    local out = capture.format(cap)
    assert.are.equal("Context (buffer):\n````\na\n```lua\nx\n```\nb\n````", out)
  end)

  it("preview sends nothing when every line was struck out", function()
    local called = false
    local win = capture.preview({ source = "messages", text = "secret" }, function()
      called = true
    end)
    local buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert.is_false(called)
  end)

  it("preview sends the edited text on <CR> and nothing on q", function()
    local got
    local cap = { source = "messages", text = "keep\nsecret\nkeep too" }
    local win = capture.preview(cap, function(text)
      got = text
    end)
    assert.is_number(win)
    local buf = vim.api.nvim_win_get_buf(win)
    assert.is_true(vim.bo[buf].modifiable, "the user must be able to strike lines")
    assert.is_true(vim.wo[win].wrap, "a long message line must be visible")
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert.are.equal("keep\nkeep too", got)
    assert.is_false(vim.api.nvim_win_is_valid(win))

    got = nil
    win = capture.preview(cap, function(text)
      got = text
    end)
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_nil(got)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("the action asks for a question and streams it with the shown context", function()
    local actions = require("ai.bindings.actions")
    local orig_kit, orig_stream = package.loaded["ui.kit"], actions.stream_prompt
    local sent
    package.loaded["ui.kit"] = {
      popup = function(opts)
        opts.on_submit("why?")
      end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    actions.stream_prompt = function(prompt)
      sent = prompt
    end
    local ok, err = pcall(function()
      vim.cmd("echomsg 'boom in the last message'")
      actions.capture("messages")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    end)
    package.loaded["ui.kit"], actions.stream_prompt = orig_kit, orig_stream
    assert(ok, err)
    assert.are.equal("why?\n\nContext (messages):\n```\nboom in the last message\n```", sent)
  end)

  it(":Ai capture with a range takes those lines, not the marks", function()
    local actions = require("ai.bindings.actions")
    local orig = actions.capture
    local seen
    ---@diagnostic disable-next-line: duplicate-set-field
    actions.capture = function(source, range)
      seen = { source, range }
    end
    local ok, err = pcall(function()
      require("ai.bindings.usrcmds").setup()
      local buf = scratch({ "a", "b", "c", "d" })
      vim.cmd("2,3Ai capture")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    actions.capture = orig
    pcall(vim.api.nvim_del_user_command, "Ai")
    assert(ok, err)
    assert.are.same({ "selection", { line1 = 2, line2 = 3 } }, seen)
  end)
end)
