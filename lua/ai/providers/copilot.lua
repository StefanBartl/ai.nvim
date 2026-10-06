---@module 'ai.providers.copilot'
--- Provider backend that drives the GitHub Copilot CLI (`copilot`) instead of
--- calling a model API itself, registered as `"copilot"`. Like `claude-cli` the
--- point is the *credential*: the CLI uses the account it is logged in as
--- (`copilot login`, kept in the system credential store), so ai.nvim holds no
--- token of its own and never sends one anywhere.
---
--- Everything below was observed on the real binary (v1.0.92, 2026-10-06) and is
--- written down in the casedesk KI concept (spike notes), except what is marked
--- *unverified*.
---
--- What this provider guarantees, and why:
---
--- - **Text in, text out.** The CLI is an agent (files, shell, web, MCP servers);
---   here it is a plain chat endpoint. `--available-tools=<name that matches no
---   tool>` leaves the model with zero tools (the usage record says
---   `tool_count: 0`; an *empty* `--available-tools=` does NOT restrict: 26 tools
---   stay), backed by `--excluded-tools` for every known built-in,
---   `--deny-tool=shell|write|url` (a denial beats every allow rule),
---   `--disable-builtin-mcps`, `--no-ask-user`, `--no-custom-instructions` and
---   `--disallow-temp-dir`. `--allow-all*` is never passed; the run is
---   non-interactive without it. A model that writes tool-call text anyway (it
---   does, with no tool to call) produces only text -- observed: nothing runs.
---   If the CLI ever reports a real tool request or tool event, the answer is
---   discarded and the call fails (`tool_guard`).
--- - **The prompt never reaches argv.** Piped stdin is read as the prompt when no
---   `-p` is given (with `-p` the CLI ignores stdin). Umlauts, quotes, backslashes
---   and newlines arrive intact. Nothing is interpreted: `@file`, `!cmd` and
---   `/cmd` in the text stay plain text in a piped run (the user message record
---   is the text itself). A leading `/` or `!` is labelled away anyway
---   (`build_stdin`), the same belt as `claude-cli`.
--- - **Nothing is kept on disk.** A run writes the prompt and the answer to
---   `<COPILOT_HOME>/session-state/*/events.jsonl`, `workspace.yaml` and
---   `session-store.db`; there is no switch against it (`--share` is opt-in and
---   not used, memory is off in prompt mode). So every call gets its own
---   `COPILOT_HOME` and working directory under the temp dir, and both are deleted
---   when the process ends. The login survives that (it lives in the credential
---   store, not in the directory) -- *unless* the CLI had to fall back to a plain
---   text file under `~/.copilot` (no credential store): then the isolated run is
---   logged out, which shows up as an `auth` error whose hint names this; set
---   `M.isolate_home = false` to use the real home (sessions are then kept there).
---   A run killed together with the editor leaves its directory in the temp dir.
--- - **The logged-in account is used, not a token from the environment.**
---   `COPILOT_GITHUB_TOKEN`, `GH_TOKEN` and `GITHUB_TOKEN` rank above the login and
---   are removed from the child's environment. (On the development machine a
---   classic `ghp_` PAT in `GITHUB_TOKEN` made every run fail with "Classic
---   Personal Access Tokens are not supported".) So are the variables that send
---   the request elsewhere or widen what the CLI does: `COPILOT_PROVIDER_*` (a
---   bring-your-own-model endpoint), `COPILOT_OFFLINE`, `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`
---   and every `COPILOT_OTEL_*`/`OTEL_*` (telemetry can capture message content);
---   `COPILOT_ALLOW_ALL` is forced to `false` and `COPILOT_AUTO_UPDATE` to `false`.
---   Kept: `COPILOT_MODEL`, `GH_HOST`/`COPILOT_GH_HOST` (an enterprise host),
---   `HTTPS_PROXY`/`NO_PROXY`.
--- - **Errors.** A fatal start-up error (not logged in, bad token, unknown model)
---   is plain text on stderr, empty stdout, exit 1, in JSON mode too (observed).
---   It becomes an `api_error` labelled `auth`, `token`, `credit` or `model`
---   (`classify`), with the CLI's own words after it. A process that dies before
---   its `result` event is a `network_error`; one that exits 0 without text is an
---   `invalid_response`.
---
--- *Unverified* (no way to provoke it without a failing account): the event shape
--- of an error DURING a run (credits used up, rate limit, a model call that
--- fails) -- this reads a `result` event with a non-zero `exitCode`, an event
--- whose type contains `error`, and a `model.call_finished`/`model.call_final_result`
--- whose outcome is not `success`, and falls back to the exit code and stderr.
--- Whether a missing login (as opposed to a bad token) prints a message that
--- `classify` recognises is unverified as well; an unrecognised text still comes
--- back as an error with the CLI's words, never as an empty answer. `:checkhealth
--- ai` says so, and the provider is opt-in (not in the default `provider_order`).
---
--- Attachments: none (`vision`/`documents` false), as for `claude-cli`: a request
--- carrying one fails with `invalid_request` rather than losing it.

require("ai.@types")

local attachments = require("ai.attachments")
local lib_error = require("lib.lua.error")
local util = require("ai.providers.util")

---@class Ai.Providers.CopilotCli : Ai.Provider
local M = {
  id = "copilot",
  name = "GitHub Copilot CLI (logged-in account)",
  capabilities = {
    streaming = true,
    vision = false,
    documents = false,
    web = false,
    temperature = false,
  },
}

---The command prefix. Mutable on purpose: the specs point it at a fake CLI
---(`nvim -l fake.lua`); users who keep `copilot` off `PATH` can set it to an
---absolute path.
---@type string[]
M.command = { "copilot" }

---Run every call in its own throw-away `COPILOT_HOME` (see the module doc).
---Mutable on purpose, for a login that lives in a plain file under `~/.copilot`.
---@type boolean
M.isolate_home = true

---Tokens that outrank the CLI's own login, removed from the child.
local TOKEN_ENV = { "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN" }

---Exact names (upper case) removed from the child, besides `TOKEN_ENV`.
local STRIPPED_ENV = {
  "COPILOT_OFFLINE",
  "COPILOT_CUSTOM_INSTRUCTIONS_DIRS",
}

---Prefixes (upper case) of variables removed from the child.
local STRIPPED_PREFIXES = { "COPILOT_PROVIDER_", "COPILOT_OTEL_", "OTEL_" }

---A tool name no tool has: `--available-tools` then leaves nothing. The CLI says
---"Unknown tool name in the tool allowlist" as a configuration note (observed,
---harmless); an unknown name in `--available-tools` is how "no tools" is
---expressed, an empty list is ignored.
local NO_TOOLS = "ai_nvim_no_tools"

---Every built-in tool of the CLI seen on v1.0.92 (PowerShell and bash flavours),
---excluded as well: a second layer behind `NO_TOOLS`.
local EXCLUDED_TOOLS = table.concat({
  "powershell",
  "bash",
  "read_powershell",
  "stop_powershell",
  "list_powershell",
  "read_bash",
  "stop_bash",
  "list_bash",
  "view",
  "create",
  "edit",
  "web_fetch",
  "fetch_copilot_cli_documentation",
  "search_code_subagent",
  "skill",
  "run_dynamic_workflow",
  "dynamic_workflows_manage",
  "sql",
  "session_store_sql",
  "read_agent",
  "list_agents",
  "write_agent",
  "grep",
  "glob",
  "task",
  "ask_user",
}, ",")

local MODEL_PATTERN = "^[%w][%w%.%-_:%[%]]*$"
local DEFAULT_TIMEOUT_MS = 120000
local MAX_STDERR = 500

---@return boolean
function M.available()
  return util.executable(M.command[1])
end

---@internal
---The CLI's version line (`GitHub Copilot CLI 1.0.92.`), or `nil` when it cannot be
---run. `--version` is local, fast and costs nothing.
---@return string|nil
function M.version()
  local ok, obj = pcall(function()
    return vim
      .system(vim.list_extend(vim.list_extend({}, M.command), { "--version" }), {
        text = true,
        timeout = 8000,
      })
      :wait()
  end)
  if not ok or obj.code ~= 0 then
    return nil
  end
  local line = util.trim((obj.stdout or ""):match("[^\r\n]+") or "")
  return line ~= "" and line or nil
end

---Which of the token variables are set in the editor's environment (names only,
---never a value) and whether one looks like a classic personal access token
---(`ghp_`), which the CLI refuses.
---@return string[] names
---@return boolean classic
function M.env_tokens()
  -- Spelled out (not a loop over `TOKEN_ENV`): the help spec matches the variables
  -- the help names against the `env_value("NAME")` reads of the provider files.
  local values = {
    COPILOT_GITHUB_TOKEN = util.env_value("COPILOT_GITHUB_TOKEN"),
    GH_TOKEN = util.env_value("GH_TOKEN"),
    GITHUB_TOKEN = util.env_value("GITHUB_TOKEN"),
  }
  local names, classic = {}, false
  for _, name in ipairs(TOKEN_ENV) do
    local value = values[name]
    if value then
      names[#names + 1] = name
      if value:sub(1, 4) == "ghp_" then
        classic = true
      end
    end
  end
  return names, classic
end

---@internal
---@param name string
---@return boolean
local function stripped(name)
  local upper = name:upper()
  if vim.tbl_contains(TOKEN_ENV, upper) or vim.tbl_contains(STRIPPED_ENV, upper) then
    return true
  end
  for _, prefix in ipairs(STRIPPED_PREFIXES) do
    if upper:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

---@internal
---@param home string|nil the throw-away `COPILOT_HOME`
---@return table<string,string> env the current environment minus the stripped variables
local function child_env(home)
  local env = {}
  for name, value in pairs(vim.fn.environ()) do
    if not stripped(name) then
      env[name] = value
    end
  end
  env.COPILOT_ALLOW_ALL = "false"
  env.COPILOT_AUTO_UPDATE = "false"
  if home then
    env.COPILOT_HOME = home
  end
  return env
end

---@internal
---@param req Ai.Request
---@return string[] argv
local function build_argv(req)
  local argv = vim.list_extend({}, M.command)
  vim.list_extend(argv, {
    "--output-format",
    "json",
    "--stream",
    "on",
    "--available-tools=" .. NO_TOOLS,
    "--excluded-tools=" .. EXCLUDED_TOOLS,
    "--deny-tool=shell",
    "--deny-tool=write",
    "--deny-tool=url",
    "--disable-builtin-mcps",
    "--no-ask-user",
    "--no-custom-instructions",
    "--disallow-temp-dir",
    "--no-auto-update",
    "--no-remote",
    "--no-remote-export",
    "--no-experimental",
    "--no-bash-env",
    "--no-color",
    "--log-level",
    "none",
  })
  if req.model then
    argv[#argv + 1] = "--model=" .. req.model
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
  -- A piped run takes `/cmd` and `!cmd` as plain text (observed); the label keeps
  -- it so should a later CLI start to interpret them.
  if req.prompt:match("^%s*[/!]") then
    return "User message:\n" .. req.prompt
  end
  return req.prompt
end

---@alias Ai.Providers.CopilotCli.Reason "token"|"auth"|"credit"|"model"|"other"

---@internal
---Sorts a failure text into what the user can do about it. Lower-cased substring
---checks on the CLI's own words; `other` is anything else.
---@param text string
---@return Ai.Providers.CopilotCli.Reason reason
---@return string|nil hint
function M.classify(text)
  local lower = text:lower()
  if lower:find("classic personal access token", 1, true) then
    return "token",
      "a classic ghp_ token is not accepted; ai.nvim ignores token variables, so this comes from the CLI's own login"
  end
  if
    lower:find("not logged in", 1, true)
    or lower:find("not authenticated", 1, true)
    or lower:find("/login", 1, true)
    or lower:find("copilot login", 1, true)
    or lower:find("could not be validated", 1, true)
    or lower:find("bad credentials", 1, true)
    or lower:find("authentication", 1, true)
  then
    return "auth",
      "log in with `copilot login` outside Neovim (if you did, and the CLI keeps the login in a plain file under ~/.copilot, set require('ai.providers.copilot').isolate_home = false)"
  end
  if
    lower:find("quota", 1, true)
    or lower:find("credit", 1, true)
    or lower:find("premium request", 1, true)
    or lower:find("billing", 1, true)
    or lower:find("rate limit", 1, true)
    or lower:find("too many requests", 1, true)
    or lower:find("usage limit", 1, true)
  then
    return "credit", "the account has no Copilot credit/quota left, or it is rate limited"
  end
  if lower:find("model", 1, true) and lower:find("not available", 1, true) then
    return "model", "set another model (`--model` ids are the CLI's own; `auto` lets it choose)"
  end
  return "other", nil
end

---@internal
---@param stderr string
---@return string
local function shorten(stderr)
  local text = util.trim(stderr):gsub("%s+", " ")
  if #text > MAX_STDERR then
    text = text:sub(1, MAX_STDERR) .. "..."
  end
  return text
end

---@internal
---A throw-away `<tmp>/<name>/{home,work}`; `dir` is what gets deleted.
---@return { dir: string, home: string|nil, work: string }|nil
local function make_sandbox()
  local dir = vim.fn.tempname()
  local work = vim.fs.joinpath(dir, "work")
  if vim.fn.mkdir(work, "p") ~= 1 then
    return nil
  end
  local home
  if M.isolate_home then
    home = vim.fs.joinpath(dir, "home")
    if vim.fn.mkdir(home, "p") ~= 1 then
      vim.fn.delete(dir, "rf")
      return nil
    end
  end
  return { dir = dir, home = home, work = work }
end

---@internal
---Run the CLI and report through `h`. Returns the process handle.
---@param req Ai.Request
---@param h { on_chunk?: fun(text: string), on_done: fun(res: Ai.Response), on_error: fun(err: LibErrorValue) }
---@return vim.SystemObj|nil
local function run(req, h)
  local rejected = attachments.unsupported("copilot", M.capabilities, req.attachments)
  if rejected then
    h.on_error(rejected)
    return nil
  end
  if req.model and not req.model:match(MODEL_PATTERN) then
    h.on_error(
      lib_error.new(
        "invalid_request",
        "copilot: invalid model name: " .. tostring(req.model),
        { model = req.model }
      )
    )
    return nil
  end

  local sandbox = make_sandbox()
  if not sandbox then
    h.on_error(lib_error.new("network_error", "copilot: could not create a temporary directory"))
    return nil
  end

  local timeout_ms = req.timeout_ms or DEFAULT_TIMEOUT_MS
  local phases = {} -- messageId -> "final_answer"|"commentary"|...
  local streamed, answer_parts, other_parts = {}, {}, {}
  local usage, exit_code
  local failure, violation, finished, got_result = nil, nil, false, false
  local stderr_parts = {}
  local pending = ""

  local function cleanup()
    pcall(vim.fn.delete, sandbox.dir, "rf")
  end

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
    local kind = type(decoded.type) == "string" and decoded.type or ""
    local data = type(decoded.data) == "table" and decoded.data or {}
    if kind == "assistant.message_start" then
      if type(data.messageId) == "string" then
        phases[data.messageId] = data.phase
      end
    elseif kind == "assistant.message_delta" then
      -- Intermediate "commentary" is not the answer; an unknown phase is.
      local phase = type(data.messageId) == "string" and phases[data.messageId] or nil
      if type(data.deltaContent) == "string" and (phase == nil or phase == "final_answer") then
        streamed[#streamed + 1] = data.deltaContent
        if h.on_chunk then
          h.on_chunk(data.deltaContent)
        end
      end
    elseif kind == "assistant.message" then
      if type(data.toolRequests) == "table" and #data.toolRequests > 0 then
        violation = violation or "an assistant message carried a tool request"
      end
      if type(data.content) == "string" then
        local phase = data.phase
        if phase == nil or phase == "final_answer" then
          answer_parts[#answer_parts + 1] = data.content
        else
          other_parts[#other_parts + 1] = data.content
        end
      end
    elseif kind == "result" then
      got_result = true
      usage = decoded.usage
      exit_code = tonumber(decoded.exitCode)
    elseif kind == "model.call_finished" then
      if data.outcome ~= nil and data.outcome ~= "success" then
        failure = failure or ("model call " .. tostring(data.outcome))
      end
    elseif kind == "model.call_final_result" then
      if data.result ~= nil and data.result ~= "success" then
        failure = failure or ("model call " .. tostring(data.result))
      end
    elseif kind:find("^tool%.") or kind:find("^permission") then
      violation = violation or ("the CLI emitted a " .. kind .. " event")
    elseif kind:find("error", 1, true) and not kind:find("^session%.mcp") then
      -- unverified shape: a message in `data`, else the type itself
      local message = data.message or data.error or decoded.message
      failure = failure or (type(message) == "string" and message or kind)
    end
  end

  local spawned, process = pcall(
    vim.system,
    build_argv(req),
    {
      stdin = build_stdin(req),
      cwd = sandbox.work,
      env = child_env(sandbox.home),
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
      cleanup()
      if pending ~= "" then
        on_line(pending)
        pending = ""
      end
      if finished then
        return
      end
      if violation then
        fail(
          lib_error.new(
            "api_error",
            "copilot: answer discarded, " .. violation .. " although every tool is switched off",
            { reason = "tool_guard" }
          )
        )
        return
      end
      if obj.code == util.SYSTEM_EXIT_TIMEOUT then
        fail(
          lib_error.new(
            "timeout",
            string.format("copilot: request timed out after %d ms", timeout_ms),
            obj
          )
        )
        return
      end
      local stderr = shorten(table.concat(stderr_parts, ""))
      local text = #streamed > 0 and table.concat(streamed, "")
        or (#answer_parts > 0 and table.concat(answer_parts, ""))
        or table.concat(other_parts, "")
      local died = obj.code ~= 0 or (obj.signal or 0) ~= 0
      local failed = failure ~= nil or (got_result and exit_code ~= nil and exit_code ~= 0)
      -- A complete answer (its `result` event said success) survives a non-zero
      -- exit afterwards. Otherwise: the CLI's own failure is text on stderr and exit
      -- 1 (start-up errors, observed), or a `result` with a non-zero exitCode / an
      -- error event (shape unverified).
      local whole = got_result and not failed and text ~= ""
      if (died or failed) and not whole then
        local reason, hint = M.classify((failure or "") .. " " .. stderr)
        if reason ~= "other" or got_result or failure then
          fail(
            lib_error.new(
              "api_error",
              ("copilot: %s: %s%s"):format(
                reason,
                failure or (stderr ~= "" and stderr or "the run failed"),
                hint and (" (" .. hint .. ")") or ""
              ),
              { reason = reason, code = obj.code, exit_code = exit_code }
            )
          )
        else
          fail(
            lib_error.new(
              "network_error",
              string.format(
                "copilot: exited %d (signal %d) before a complete answer: %s",
                obj.code,
                obj.signal or 0,
                stderr
              ),
              obj
            )
          )
        end
        return
      end
      if text == "" then
        fail(
          lib_error.new(
            "invalid_response",
            "copilot: exited without any answer text" .. (stderr ~= "" and (": " .. stderr) or ""),
            obj
          )
        )
        return
      end
      finished = true
      h.on_done({ text = text, usage = usage, provider = "copilot" })
    end)
  )
  if not spawned then
    cleanup()
    h.on_error(lib_error.new("network_error", "copilot: could not start: " .. tostring(process)))
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
