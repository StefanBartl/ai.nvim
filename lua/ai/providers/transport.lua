---@module 'ai.providers.transport'
--- The one place a provider's already-encoded JSON body meets
--- `lib.nvim.net.curl`. Two things live here that every backend would
--- otherwise repeat, and that only became load-bearing once requests started
--- carrying attachments.
---
--- **1. A body too large for argv.** `lib.nvim.net.curl` sends `opts.body`
--- as a `-d <body>` element of curl's argv. Windows caps a whole command
--- line at 32 767 characters and Linux' `ARG_MAX` is commonly ~2 MB; a
--- base64-encoded PDF is routinely megabytes, so an attachment request built
--- that way fails at `spawn` time -- before curl runs, with an error that
--- names neither the body nor its size. Above `MAX_INLINE_BODY_BYTES` the
--- body therefore goes to a temp file and curl reads it back with
--- `--data-binary @file`. This is not attachment-specific: a long enough
--- `context = { cwd = true }` sweep could already reach the same ceiling.
---
--- **2. A timeout that says so.** `opts.timeout_ms` reaches `vim.system`,
--- which on expiry kills curl and sets the exit code to `124` (documented in
--- `:help vim.system()`) -- so the caller learns "curl exited 124", a number
--- curl itself never produces and that says nothing about what went wrong.
--- Passing curl its own `--max-time` makes curl end the request itself and
--- exit **28**, the documented, cross-platform "operation timed out", with
--- its own diagnostics on stderr.
---
--- For curl to get there it has to expire *first*, which is what
--- `TIMEOUT_GRACE_MS` is for: `vim.system`'s timer starts at spawn while
--- curl's starts a moment later, so handing both the same number means the
--- backstop always wins the race and exit 28 is unreachable. The grace
--- margin keeps `vim.system` what it is meant to be -- the backstop for a
--- curl that ignores its own limit. `ai.providers.util.curl_exit_error`
--- maps both codes to the `"timeout"` error kind, so the backstop firing is
--- still reported honestly rather than as a mystery exit code.

local curl = require("lib.nvim.net.curl")

local M = {}

local uv = vim.uv or vim.loop

---Bodies at or below this go in argv as before; larger ones go through a
---temp file. Well under Windows' 32 767-character command-line ceiling,
---because the body is not the only thing on that line -- the URL, the
---method, every `-H` header and curl's own flags share it.
---@type integer
M.MAX_INLINE_BODY_BYTES = 8192

---How much longer than curl's own `--max-time` the `vim.system` backstop is
---allowed to run. It has to cover two things: `max_time_seconds` rounding a
---timeout *up* to the next whole second (under 1000 ms), and the process
---start-up between `vim.system` starting its timer and curl starting its
---own. Two seconds clears both comfortably -- this is the difference between
---two timeouts of the same request, not a timeout extension anyone waits out
---in practice.
---@type integer
local TIMEOUT_GRACE_MS = 2000

---@internal
---Write `json` to a fresh temp file, created 0600.
---
---The mode matters even though the API key never goes in here (that path is
---curl's `-K` stdin config): the body is the user's prompt, their buffer
---context and, now, whole documents they chose to send. On a multi-user
---POSIX box a world-readable temp file hands all of that to every other
---account for the duration of the request. On Windows the mode bits are
---largely inert, which is why this is the floor and not the whole story.
---@param json string
---@return string|nil path
---@return string|nil err
local function write_body_file(json)
  local path = vim.fn.tempname() .. ".json"
  -- "wx", not "w": O_EXCL refuses to open anything that already exists at
  -- this path, so a pre-planted file or symlink cannot be followed and
  -- written through. `vim.fn.tempname()` is unpredictable and its directory
  -- is already private, which makes this belt-and-braces rather than a fix
  -- -- but the whole point of the file is that the body is the user's
  -- document, so the cheap guarantee is worth having.
  local fd, open_err = uv.fs_open(path, "wx", 384) -- 0600
  if not fd then
    return nil, "cannot create request body file: " .. tostring(open_err)
  end
  local written, write_err = uv.fs_write(fd, json, 0)
  uv.fs_close(fd)
  if not written then
    pcall(os.remove, path)
    return nil, "cannot write request body file: " .. tostring(write_err)
  end
  return path, nil
end

---@internal
---curl's `--max-time` is in seconds. Rounded up, floored at 1 -- a sub-second
---`timeout_ms` must not round down to `0`, which curl reads as "no limit"
---and which would turn a very short timeout into none at all.
---@param timeout_ms integer
---@return string
local function max_time_seconds(timeout_ms)
  return tostring(math.max(1, math.ceil(timeout_ms / 1000)))
end

---@internal
---@param opts table `Lib.Net.Curl.FetchOpts`-shaped, with `body` as the JSON string
---@return table|nil prepared
---@return fun() cleanup
---@return string|nil err
local function prepare(opts)
  local timeout_ms = opts.timeout_ms or 60000
  local prepared = vim.tbl_extend("force", {}, opts)
  -- See TIMEOUT_GRACE_MS: curl's --max-time below is the request's real
  -- deadline, and this one only catches a curl that blows through it.
  prepared.timeout_ms = timeout_ms + TIMEOUT_GRACE_MS

  local raw_args = vim.list_extend({}, opts.raw_args or {})
  raw_args[#raw_args + 1] = "--max-time"
  raw_args[#raw_args + 1] = max_time_seconds(timeout_ms)

  ---@type fun()
  local cleanup = function() end

  local body = opts.body
  if type(body) == "string" and #body > M.MAX_INLINE_BODY_BYTES then
    local path, err = write_body_file(body)
    if not path then
      return nil, cleanup, err
    end
    prepared.body = nil
    raw_args[#raw_args + 1] = "--data-binary"
    raw_args[#raw_args + 1] = "@" .. path
    -- Idempotent: `fetch_stream` can reach both `on_done` and `on_error` for
    -- one request, and the second call must not delete a *reused* temp name.
    local removed = false
    cleanup = function()
      if removed then
        return
      end
      removed = true
      pcall(os.remove, path)
    end
  end

  prepared.raw_args = raw_args
  return prepared, cleanup, nil
end

---`curl.fetch_json`, with the body routing and `--max-time` above applied.
---
---Unlike `fetch_json`'s own callback, `cb` also receives the raw
---`vim.SystemCompleted` on failure -- that is what carries curl's exit code,
---and therefore the only way to tell a timeout from a connection error.
---@param url string
---@param opts table
---@param cb fun(ok: boolean, data_or_err: any, obj: vim.SystemCompleted|nil)
---@return string|nil err a body-preparation failure; nothing was sent and `cb` is never called
function M.post_json(url, opts, cb)
  local prepared, cleanup, err = prepare(opts)
  if not prepared then
    return err
  end
  -- `vim.system` *raises* when the binary cannot be spawned (ENOENT), and
  -- `util.executable` deliberately caches a successful probe -- so a curl
  -- that disappears mid-session passes `available()` and then throws here.
  -- Unguarded, that error escapes into the caller's stack with `cb` never
  -- called: an extraction that waits forever rather than failing. It also
  -- strands the body temp file, since nothing would run `cleanup`.
  local spawned, spawn_err = pcall(curl.fetch_json, url, prepared, function(ok, data, obj)
    cleanup()
    cb(ok, data, obj)
  end)
  if not spawned then
    cleanup()
    return "could not start curl: " .. tostring(spawn_err)
  end
  return nil
end

---`curl.fetch_stream`, same two adjustments, with the temp body file removed
---once the process is done with it either way.
---@param url string
---@param opts table
---@param handlers Lib.Net.Curl.StreamHandlers
---@return vim.SystemObj|nil process
---@return string|nil err a body-preparation failure; nothing was sent and no handler fires
function M.stream_json(url, opts, handlers)
  local prepared, cleanup, err = prepare(opts)
  if not prepared then
    return nil, err
  end
  -- Same spawn-failure guard as `post_json`; see its comment.
  local spawned, process = pcall(curl.fetch_stream, url, prepared, {
    on_chunk = handlers.on_chunk,
    on_done = function(obj)
      cleanup()
      if handlers.on_done then
        handlers.on_done(obj)
      end
    end,
    on_error = function(stream_err)
      cleanup()
      if handlers.on_error then
        handlers.on_error(stream_err)
      end
    end,
  })
  if not spawned then
    cleanup()
    return nil, "could not start curl: " .. tostring(process)
  end
  return process, nil
end

return M
