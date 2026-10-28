---@module 'ai.capture'
--- Takes the current context -- the selection, the last message, the last
--- notification, or the lines around the cursor -- so it can go into a prompt.
---
--- Every capture is redacted before anyone sees it: the home folder becomes
--- `~` and the user name `<user>` (messages carry paths and names). `get()` is
--- the interface for other plugins (tasks.nvim); `preview()` shows a capture
--- in an editable float, so the user sees and can strike what is sent --
--- including the line that names the file.

require("ai.@types")

local M = {}

---@alias Ai.CaptureSource "selection"|"messages"|"notify"|"buffer"

---@class Ai.Capture
---@field source Ai.CaptureSource
---@field text string     # redacted
---@field file? string    # redacted; buffer and selection
---@field line? integer   # first line; buffer and selection

---@class Ai.CaptureOpts
---@field line1? integer  # `selection`: the first line (default: the `'<` mark)
---@field line2? integer  # `selection`: the last line (default: the `'>` mark)
---@field env? { home?: string, user?: string }  # for tests; default: this machine's

---@type Ai.CaptureSource[]
M.SOURCES = { "selection", "messages", "notify", "buffer" }

---Lines above and below the cursor for the `buffer` source.
---@type integer
M.BUFFER_RADIUS = 10

local uv = vim.uv or vim.loop

---Replace `needle` in `text`, ASCII case-insensitive. `edge` decides whether a
---match counts by looking at the characters around it.
---@param text string
---@param needle string
---@param repl string
---@param edge fun(before: string, after: string): boolean
---@return string
local function replace_ci(text, needle, repl, edge)
  if needle == "" then
    return text
  end
  local lower_text, lower_needle = text:lower(), needle:lower()
  local out, i, from = {}, 1, 1
  while true do
    local s, e = lower_text:find(lower_needle, from, true)
    if not s then
      break
    end
    if edge(text:sub(s - 1, s - 1), text:sub(e + 1, e + 1)) then
      out[#out + 1] = text:sub(i, s - 1)
      out[#out + 1] = repl
      i = e + 1
    end
    from = e + 1
  end
  out[#out + 1] = text:sub(i)
  return table.concat(out)
end

---A home path ends where a path segment ends: `/home/jane` is not `/home/janet`.
local function path_edge(_, after)
  return not after:match("[%w_.%-]")
end

---A user name is a word: `jane` is not `janet` or `jane_x`.
local function word_edge(before, after)
  return not before:match("[%w_]") and not after:match("[%w_]")
end

---@return string|nil
local function user_name()
  local ok, pw = pcall(uv.os_get_passwd)
  local name = ok and type(pw) == "table" and pw.username or nil
  return name or vim.env.USERNAME or vim.env.USER
end

---Every spelling of a home folder a message may carry: as given, with `/` or
---`\`, with `\\` (escaped in a string), and the MSYS form `/c/Users/x`.
---@param home string
---@return string[]
local function home_variants(home)
  home = home:gsub("[/\\]+$", "")
  -- A drive or filesystem root (`C:`, ``) as "home" would turn every path into `~`.
  if #home < 4 then
    return {}
  end
  local fwd = home:gsub("\\", "/")
  local list = { home, fwd, (home:gsub("/", "\\")), (home:gsub("[/\\]", "\\\\")) }
  local drive, rest = fwd:match("^(%a):(/.*)$")
  if drive then
    list[#list + 1] = "/" .. drive:lower() .. rest
  end
  -- Longest first: the escaped form contains the plain one's prefix.
  table.sort(list, function(a, b)
    return #a > #b
  end)
  return list
end

---Spellings of a user name: as given and in lower, upper and title case.
---`string.lower` only folds ASCII, so a name like `jürgen` needs its other
---cases spelled out (`vim.fn.toupper` knows them).
---@param user string
---@return string[]
local function user_variants(user)
  local lower, upper = vim.fn.tolower(user), vim.fn.toupper(user)
  local first = vim.fn.strcharpart(user, 0, 1)
  local title = vim.fn.toupper(first) .. vim.fn.tolower(vim.fn.strcharpart(user, 1))
  return { user, lower, upper, title }
end

---Mask the home folder (`~`) and the user name (`<user>`) in `text`.
---@param text string
---@param env? { home?: string, user?: string }  # for tests; default: this machine's
---@return string
function M.redact(text, env)
  env = env or {}
  local homes = {}
  for _, h in ipairs({ env.home or uv.os_homedir(), not env.home and vim.env.HOME or nil }) do
    if type(h) == "string" and h ~= "" then
      vim.list_extend(homes, home_variants(h))
    end
  end
  for _, variant in ipairs(homes) do
    text = replace_ci(text, variant, "~", path_edge)
  end
  local user = env.user or user_name()
  if type(user) == "string" and #user >= 3 then
    for _, variant in ipairs(user_variants(user)) do
      text = replace_ci(text, variant, "<user>", word_edge)
    end
  end
  return text
end

---@param bufnr integer
---@return string|nil
local function file_of(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and name or nil
end

---The last message of `lines` (the output of `:messages`): its last non-empty
---line, and for a Lua error the whole block -- the `E5108: ...` line, the
---`stack traceback:` and the indented frames -- not only its last frame.
---@param lines string[]
---@return string|nil
function M.last_message_of(lines)
  local last = #lines
  while last > 0 and not lines[last]:match("%S") do
    last = last - 1
  end
  if last == 0 then
    return nil
  end
  local first = last
  while first > 1 and (lines[first]:match("^%s") or lines[first]:match("^stack traceback:")) do
    first = first - 1
  end
  return table.concat(vim.list_slice(lines, first, last), "\n")
end

---@return string|nil
local function last_message()
  local ok, res = pcall(vim.api.nvim_exec2, "messages", { output = true })
  if not ok or type(res) ~= "table" or type(res.output) ~= "string" then
    return nil
  end
  return M.last_message_of(vim.split(res.output, "\n", { plain = true }))
end

---The last notification lib.nvim's message ring recorded, or nil: the ring
---only fills with a renderer attached, and a line of `:messages` is no
---notification, so there is no guessing fallback.
---@return string|nil
local function last_notification()
  local ok, messages = pcall(require, "lib.nvim.messages")
  if not ok then
    return nil
  end
  local snap = messages.snapshot({ kinds = { "notify" } })
  local entry = snap[#snap]
  if entry and entry.content and entry.content:match("%S") then
    return entry.content
  end
  return nil
end

---@type table<Ai.CaptureSource, fun(opts: Ai.CaptureOpts): (string|nil, string|nil, integer|nil)>
local COLLECT = {
  selection = function(opts)
    local bufnr = vim.api.nvim_get_current_buf()
    local line1 = opts.line1 or vim.fn.getpos("'<")[2]
    local line2 = opts.line2 or vim.fn.getpos("'>")[2]
    if line1 < 1 or line2 < line1 then
      return nil
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
    return table.concat(lines, "\n"), file_of(bufnr), line1
  end,
  messages = function()
    return last_message()
  end,
  notify = function()
    return last_notification()
  end,
  buffer = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local first = math.max(1, row - M.BUFFER_RADIUS)
    local last = math.min(vim.api.nvim_buf_line_count(bufnr), row + M.BUFFER_RADIUS)
    local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
    return table.concat(lines, "\n"), file_of(bufnr), first
  end,
}

---The lines of the visual selection while Visual mode is still active (a
---Lua mapping runs before Visual mode ends, when `'<`/`'>` still hold the
---previous selection), and Visual mode left. Outside Visual mode: the marks.
---@return integer line1
---@return integer line2
function M.visual_range()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.getpos("v")[2], vim.fn.getpos(".")[2]
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    return math.min(a, b), math.max(a, b)
  end
  return vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2]
end

---The context of `source`, redacted, or nil and the reason.
---@param source Ai.CaptureSource
---@param opts? Ai.CaptureOpts
---@return Ai.Capture|nil
---@return string|nil err
function M.get(source, opts)
  opts = opts or {}
  local collect = COLLECT[source]
  if not collect then
    return nil,
      ("unknown source %q (one of: %s)"):format(tostring(source), table.concat(M.SOURCES, ", "))
  end
  local text, file, line = collect(opts)
  if type(text) ~= "string" or not text:match("%S") then
    if source == "notify" then
      return nil,
        "no notification recorded (lib.nvim's message ring fills only with a renderer); try messages"
    end
    return nil, ("nothing to capture from %s"):format(source)
  end
  return {
    source = source,
    text = M.redact(text, opts.env),
    file = file and M.redact(file, opts.env) or nil,
    line = line,
  }
end

---The lines a capture is shown and sent as: a first line naming the file
---(`-- ~/a.lua:7`) when there is one, then the text.
---@param cap Ai.Capture
---@return string[]
function M.lines(cap)
  local lines = vim.split(cap.text, "\n", { plain = true })
  if cap.file then
    table.insert(lines, 1, ("-- %s:%d"):format(cap.file, cap.line or 1))
  end
  return lines
end

---A prompt section of `text` (default: the capture's own lines).
---@param cap Ai.Capture
---@param text? string  # what the user left after editing the preview
---@return string
function M.format(cap, text)
  return ("Context (%s):\n```\n%s\n```"):format(
    cap.source,
    text or table.concat(M.lines(cap), "\n")
  )
end

---Show `cap` in an editable float. `<CR>` (Normal mode) hands the edited text
---to `on_submit`; `q`/`<Esc>` closes without sending.
---@param cap Ai.Capture
---@param on_submit fun(text: string)
---@return integer|nil winid
function M.preview(cap, on_submit)
  local make_scratch = require("lib.nvim.window.make_scratch")
  local lines = M.lines(cap)
  local winid, bufnr = make_scratch({
    lines = lines,
    width = 0.7,
    height = math.min(#lines + 1, math.max(5, math.floor(vim.o.lines * 0.5))),
    title = (" AI context: %s "):format(cap.source),
    footer = " <CR> (normal) send  q cancel  delete what must not go out ",
    modifiable = true,
    nice_quit = true,
    wo = { wrap = true },
  })
  if not winid or not bufnr then
    return nil
  end
  vim.keymap.set("n", "<CR>", function()
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    pcall(vim.api.nvim_win_close, winid, true)
    on_submit(text)
  end, { buffer = bufnr, nowait = true, desc = "Send this context" })
  return winid
end

return M
