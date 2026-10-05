---@module 'ai.providers.claude_cli'
--- Provider backend that drives the Claude Code CLI (`claude -p`) instead of
--- calling the Anthropic API itself. The point is the *credential*: the CLI
--- uses whatever account it is logged in as (`claude auth status`) -- a
--- subscription login, a company account, or a key it manages -- so ai.nvim
--- needs no API key of its own and switching accounts is `claude auth login`
--- outside of Neovim.
---
--- What this provider guarantees, and why:
---
--- - **Text in, text out.** The CLI is an agent; here it is used as a plain
---   chat endpoint. `--tools ""` removes every tool, `--safe-mode` drops hooks,
---   plugins, MCP servers and memory files, `--disable-slash-commands` and
---   `--no-session-persistence` keep the call from reading or writing session
---   state. It runs in a neutral working directory so no project `CLAUDE.md`
---   is picked up from wherever Neovim happens to be.
--- - **The text is not interpreted.** The CLI scans the prompt itself, before
---   any model call: an `@<path>` mention is read from disk and sent along (no
---   tool call, no permission prompt -- `--tools ""` does not stop it), and a
---   prompt that starts with `/cost`, `/context`, ... is answered locally
---   as a success. Logs and ticket text are untrusted, so a `Read` deny rule
---   (`--settings`) blocks the first and a leading `/` is labelled away (see
---   `build_stdin`) for the second.
--- - **The prompt never reaches argv.** It is written to the child's stdin
---   (argv is visible in the process list and capped on Windows); the system
---   text, if any, is sent as a labelled preamble of the same message.
--- - **The logged-in account is used, not a key from the environment.**
---   The variables that would replace the login or send the request elsewhere
---   (`CREDENTIAL_ENV`) are removed from the child's environment -- otherwise a
---   stray variable would silently override the login and bill a different
---   account than the one the user is looking at.
--- - **Errors are in-band.** A billing or auth failure is not a non-zero exit:
---   the CLI prints a `result` event with `is_error = true` and exits 1. That
---   event's text is the error message (`kind = "api_error"`). A process that
---   exits non-zero or is killed before its `result` event is a `network_error`:
---   what it streamed up to then is a cut-off answer, not a finished one.
---
--- Attachments: none (`vision`/`documents` false), as for `loomai` -- a request
--- carrying one fails with `invalid_request` rather than losing it. Opt-in:
--- not in the default `provider_order`.

require("ai.@types")

local attachments = require("ai.attachments")
local lib_error = require("lib.lua.error")
local util = require("ai.providers.util")

---@class Ai.Providers.ClaudeCli : Ai.Provider
local M = {
  id = "claude-cli",
  name = "Claude Code CLI (logged-in account)",
  capabilities = { streaming = true, vision = false, documents = false },
}

---The command prefix. Mutable on purpose: the specs point it at a fake CLI
---(`nvim -l fake.lua`); users who keep `claude` off `PATH` can set it to an
---absolute path.
---@type string[]
M.command = { "claude" }

---Child environment variables that would override the CLI's own login: an API
---key or token, a long-lived OAuth token (`claude setup-token`), and the
---switches that route it to Bedrock/Vertex/Foundry/AWS/Mantle instead. Not
---removed on purpose: `CLAUDE_CONFIG_DIR` (where the login lives),
---`CLAUDE_CODE_GIT_BASH_PATH` (needed on Windows) and `ANTHROPIC_BASE_URL`
---(a company gateway may be the only way to reach the API).
---@type string[]
local CREDENTIAL_ENV = {
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "CLAUDE_CODE_USE_BEDROCK",
  "CLAUDE_CODE_USE_VERTEX",
  "CLAUDE_CODE_USE_FOUNDRY",
  "CLAUDE_CODE_USE_ANTHROPIC_AWS",
  "CLAUDE_CODE_USE_MANTLE",
}

---Settings passed inline: the CLI turns `@<path>` in the prompt into the file's
---content before the model is called, and this deny rule is what that read is
---checked against (relative, home and absolute paths).
local DENY_READ_SETTINGS =
  vim.json.encode({ permissions = { deny = { "Read(**)", "Read(//**)" } } })

local MODEL_PATTERN = "^[%w][%w%.%-_:%[%]]*$"
local DEFAULT_TIMEOUT_MS = 120000

---@return boolean
function M.available()
  return util.executable(M.command[1])
end

---@internal
---@return table<string,string> env the current environment minus `CREDENTIAL_ENV`
local function child_env()
  local env = vim.fn.environ()
  for _, name in ipairs(CREDENTIAL_ENV) do
    env[name] = nil
  end
  return env
end

---@internal
---@param req Ai.Request
---@return string[] argv
local function build_argv(req)
  local argv = vim.list_extend({}, M.command)
  vim.list_extend(argv, {
    "-p",
    "--safe-mode",
    "--tools",
    "",
    "--no-session-persistence",
    "--disable-slash-commands",
    "--settings",
    DENY_READ_SETTINGS,
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
  })
  if req.model then
    argv[#argv + 1] = "--model"
    argv[#argv + 1] = req.model
  end
  return argv
end

---@internal
---@param req Ai.Request
---@return string
local function build_stdin(req)
  if req.system and req.system ~= "" then
    return "Instructions for this conversation:\n" .. req.system .. "\n\n---\n\n" .. req.prompt
  end
  -- `/cost`, `/context`, ... at the start are answered by the CLI itself (exit 0,
  -- no model call, the local message as the "answer") even with
  -- --disable-slash-commands; a label keeps the user's text a plain prompt.
  if req.prompt:match("^%s*/") then
    return "User message:\n" .. req.prompt
  end
  return req.prompt
end

---@internal
---Neutral cwd: the temp dir, so no project memory file is discovered.
---@return string
local function neutral_cwd()
  local dir = vim.fs.dirname(vim.fn.tempname())
  return (dir and dir ~= "") and dir or "."
end

---@internal
---Run the CLI and report through `h`. Returns the process handle.
---@param req Ai.Request
---@param h { on_chunk?: fun(text: string), on_done: fun(res: Ai.Response), on_error: fun(err: LibErrorValue) }
---@return vim.SystemObj|nil
local function run(req, h)
  local rejected = attachments.unsupported("claude-cli", M.capabilities, req.attachments)
  if rejected then
    h.on_error(rejected)
    return nil
  end
  if req.model and not req.model:match(MODEL_PATTERN) then
    h.on_error(
      lib_error.new(
        "invalid_request",
        "claude-cli: invalid model name: " .. tostring(req.model),
        { model = req.model }
      )
    )
    return nil
  end

  local timeout_ms = req.timeout_ms or DEFAULT_TIMEOUT_MS
  local text_parts, assistant_text = {}, {}
  local usage, stop_reason, result_text
  local failure, finished, got_result = nil, false, false
  local stderr_parts = {}
  local pending = ""

  local function fail(err)
    if not finished then
      finished = true
      h.on_error(err)
    end
  end

  ---@param line string
  local function on_line(line)
    if line == "" then
      return
    end
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or type(decoded) ~= "table" then
      return
    end
    decoded = util.denil(decoded)
    if decoded.type == "stream_event" then
      local ev = decoded.event
      if
        type(ev) == "table"
        and ev.type == "content_block_delta"
        and type(ev.delta) == "table"
        and ev.delta.type == "text_delta"
        and type(ev.delta.text) == "string"
      then
        text_parts[#text_parts + 1] = ev.delta.text
        if h.on_chunk then
          h.on_chunk(ev.delta.text)
        end
      end
    elseif decoded.type == "assistant" then
      local content = type(decoded.message) == "table" and decoded.message.content
      for _, block in ipairs(type(content) == "table" and content or {}) do
        if block.type == "text" and type(block.text) == "string" then
          assistant_text[#assistant_text + 1] = block.text
        end
      end
    elseif decoded.type == "result" then
      got_result = true
      usage = decoded.usage
      stop_reason = decoded.stop_reason or decoded.subtype
      if decoded.is_error then
        failure = tostring(decoded.result or decoded.subtype or "unknown error")
      elseif type(decoded.result) == "string" then
        result_text = decoded.result
      end
    end
  end

  local spawned, process = pcall(
    vim.system,
    build_argv(req),
    {
      stdin = build_stdin(req),
      cwd = neutral_cwd(),
      env = child_env(),
      clear_env = true,
      text = true,
      timeout = timeout_ms,
      stdout = vim.schedule_wrap(function(_, data)
        if not data then
          return
        end
        pending = pending .. data
        while true do
          local nl = pending:find("\n", 1, true)
          if not nl then
            break
          end
          local line = pending:sub(1, nl - 1):gsub("\r$", "")
          pending = pending:sub(nl + 1)
          on_line(line)
        end
      end),
      stderr = function(_, data)
        if data then
          stderr_parts[#stderr_parts + 1] = data
        end
      end,
    },
    vim.schedule_wrap(function(obj)
      if pending ~= "" then
        on_line(pending)
        pending = ""
      end
      if finished then
        return
      end
      if failure then
        fail(lib_error.new("api_error", "claude-cli: " .. failure, { result = failure }))
        return
      end
      if obj.code == util.SYSTEM_EXIT_TIMEOUT then
        fail(
          lib_error.new(
            "timeout",
            string.format("claude-cli: request timed out after %d ms", timeout_ms),
            obj
          )
        )
        return
      end
      local text = #text_parts > 0 and table.concat(text_parts, "")
        or result_text
        or table.concat(assistant_text, "")
      -- Dead (crashed, killed, cancelled) before its `result` event: whatever it
      -- streamed is a cut-off answer. A signal can leave the exit code at 0.
      local died = obj.code ~= 0 or (obj.signal or 0) ~= 0
      if died and (not got_result or text == "") then
        fail(
          lib_error.new(
            "network_error",
            string.format(
              "claude-cli: exited %d (signal %d) before a complete answer: %s",
              obj.code,
              obj.signal or 0,
              vim.trim(table.concat(stderr_parts, ""))
            ),
            obj
          )
        )
        return
      end
      finished = true
      h.on_done({ text = text, usage = usage, stop_reason = stop_reason, provider = "claude-cli" })
    end)
  )
  if not spawned then
    h.on_error(lib_error.new("network_error", "claude-cli: could not start: " .. tostring(process)))
    return nil
  end
  return process
end

---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
function M.ask(req, cb)
  run(req, {
    on_done = function(res)
      cb(true, res)
    end,
    on_error = function(err)
      cb(false, err)
    end,
  })
end

---@param req Ai.Request
---@param handlers Ai.StreamHandlers
---@return vim.SystemObj|nil
function M.stream(req, handlers)
  return run(req, {
    on_chunk = handlers.on_chunk,
    on_done = function(res)
      if handlers.on_done then
        handlers.on_done(res)
      end
    end,
    on_error = function(err)
      if handlers.on_error then
        handlers.on_error(err)
      end
    end,
  })
end

return M
