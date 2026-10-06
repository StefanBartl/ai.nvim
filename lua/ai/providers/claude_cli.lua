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
---   (`--settings`) blocks the first -- backed by a second, independent layer
---   that changes no text, the CLI's own attachment switch in the child's
---   environment (see `child_env`) -- and a leading `/` is labelled away (see
---   `build_stdin`) for the second.
--- - **The prompt never reaches argv.** It is written to the child's stdin
---   (argv is visible in the process list and capped on Windows); the system
---   text, if any, is sent as a labelled preamble of the same message.
--- - **The logged-in account is used, not a key from the environment.**
---   The variables that would replace the login or send the request elsewhere
---   (`CREDENTIAL_ENV`) are removed from the child's environment -- otherwise a
---   stray variable would silently override the login and bill a different
---   account than the one the user is looking at. A known limit: the CLI's own
---   *settings* can carry a credential that ranks above the login too (an
---   `apiKeyHelper` script, an API key or token in the `env` block, an active
---   federation profile file). Those are not environment of the child, ai.nvim
---   does not rewrite another tool's settings, and the child is not pointed at an
---   empty configuration directory (that would likely break a login that
---   legitimately lives in a profile). Not changed, but `:checkhealth ai` says when
---   the user's or the managed settings file defines an `apiKeyHelper` or sets such
---   a variable in its `env` block (`settings_credentials`; the keys are looked
---   up, no value is ever read out). A federation profile is not detected: it
---   lives in another tool's configuration directory, and nothing there is read.
---   Documented in `docs/scope.md`.
--- - **Errors are in-band.** A billing or auth failure is not a non-zero exit:
---   the CLI prints a `result` event with `is_error = true` and exits 1. That
---   event's text is the error message (`kind = "api_error"`). A process that
---   exits non-zero or is killed before its `result` event is a `network_error`:
---   what it streamed up to then is a cut-off answer, not a finished one. One
---   that exits 0 without a `result` event and without any text is an
---   `invalid_response`, never an empty answer.
---
--- Attachments: none (`vision`/`documents` false), as for `loomai` -- a request
--- carrying one fails with `invalid_request` rather than losing it. Opt-in:
--- not in the default `provider_order`.

require("ai.@types")

local attachments = require("ai.attachments")
local lib_error = require("lib.lua.error")
local read = require("lib.nvim.fs.read")
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

---The plain credentials among `CREDENTIAL_ENV`: an API key, an auth token and a
---long-lived OAuth token. A settings file's `env` block can set these too, and
---`settings_credentials` looks for exactly these names there.
---@type string[]
local TOKEN_ENV = {
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
}

---Child environment variables that would override the CLI's own login: every
---credential source the CLI's authentication precedence ranks above its
---`/login` credential (code.claude.com/docs/en/authentication). That is an API
---key or token, a long-lived OAuth token (`claude setup-token`), the switches
---that route it to Bedrock/Vertex/Foundry/AWS/Mantle instead, a named Anthropic
---profile (`ANTHROPIC_PROFILE`) and the Workload Identity Federation pair
---(`ANTHROPIC_FEDERATION_RULE_ID` + `ANTHROPIC_ORGANIZATION_ID`; their identity
---token variables are inert without it).
---
---Not removed on purpose: `CLAUDE_CONFIG_DIR` (where the login lives),
---`CLAUDE_CODE_GIT_BASH_PATH` (needed on Windows), `ANTHROPIC_BASE_URL` (a
---company gateway may be the only way to reach the API; `gateway_note` keeps
---it visible in `:Ai info` and `:checkhealth ai`) and
---`CLAUDE_CODE_OAUTH_REFRESH_TOKEN` (documented as the input of
---`claude auth login`, not as a credential of a request, and absent from the
---precedence list). Not reachable from here, because they are settings and not
---environment: an `apiKeyHelper` script, an `env` block that sets one of `TOKEN_ENV`
---again once the CLI is running, and an active federation profile file
---(`settings_credentials` reports the first two).
---@type string[]
local CREDENTIAL_ENV = vim.list_extend(vim.list_extend({}, TOKEN_ENV), {
  "CLAUDE_CODE_USE_BEDROCK",
  "CLAUDE_CODE_USE_VERTEX",
  "CLAUDE_CODE_USE_FOUNDRY",
  "CLAUDE_CODE_USE_ANTHROPIC_AWS",
  "CLAUDE_CODE_USE_MANTLE",
  "ANTHROPIC_PROFILE",
  "ANTHROPIC_FEDERATION_RULE_ID",
  "ANTHROPIC_ORGANIZATION_ID",
})

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

---Longest value `url_host` reads. A URL is 2 kB at most in practice and a gateway
---URL a few dozen bytes. Checked before any pattern runs: what is longer is not a
---base URL, and a pattern that backtracks gets no input to be slow on.
local MAX_URL_BYTES = 2048

---Longest `host[:port]` that is printed: a name is 253 bytes at most, plus the
---brackets of an IPv6 literal, plus `:65535`.
local MAX_HOST_BYTES = 262

---@internal
---`host[:port]` of a URL's authority and nothing else: scheme, userinfo, path,
---query and fragment are dropped. Strict on purpose, because the result goes on
---screen: a value that is not `scheme://host...` (a key pasted into the variable,
---a `host:port` without scheme) gives `nil` and is not echoed in part. Like a
---browser's URL parser, the authority ends at the first `/`, `\`, `?` or `#`,
---and the userinfo at its last `@`.
---
---Linear by construction, on a value of at most `MAX_URL_BYTES`: every pattern is
---anchored, and the name and the port are read by two separate matches that cannot
---give characters back to each other. A single `^(name class)(:?%d*)$` could: the
---class holds the digits, so a digit run followed by a byte outside the class
---(`1111...!`) was retried at every split, 55 s for 120 kB.
---@param url string
---@return string|nil host
local function url_host(url)
  if #url > MAX_URL_BYTES then
    return nil
  end
  local rest = url:match("^%a[%w+.-]*://(.*)$")
  if not rest then
    return nil
  end
  local authority = rest:match("^[^/\\?#]*")
  -- Anchored on purpose: `([^@]*)$` retries from every start position and takes
  -- quadratic time on a long userinfo (72 s for 120 kB).
  local host = authority:match("^.*@(.*)$") or authority
  if #host > MAX_HOST_BYTES then
    return nil
  end
  local name = host:match("^%[[%x:.]+%]") -- an IPv6 literal
    or host:match("^[%w%.%-_\128-\255]+")
  if not name or #name > 253 then
    return nil
  end
  -- Whatever follows the name is a port or the value is not read: `:`, or `:`
  -- and up to five digits.
  local port = host:sub(#name + 1)
  if port ~= "" and (#port > 6 or not port:match("^:%d*$")) then
    return nil
  end
  return name .. (port == ":" and "" or port)
end

---What `:Ai info` and `:checkhealth ai` say about `ANTHROPIC_BASE_URL`, as the
---two short lines of one sentence (the `:Ai info` viewer does not wrap; the
---health report joins them). The variable is passed on to the CLI on purpose (a
---company gateway may be the only way to reach the API), and that means the
---prompts and the CLI's login go to that host, where `policy.allowed` cannot see
---them -- so the setting must at least be visible. Only the host is named: the
---userinfo and the query of such a URL can carry a credential. `nil`, nothing
---at all, when the variable is unset.
---@return string[]|nil lines
function M.gateway_note()
  local url = util.env_value("ANTHROPIC_BASE_URL")
  if not url then
    return nil
  end
  local host = url_host(url)
  if not host then
    return {
      "ANTHROPIC_BASE_URL is set, but no host can be read from it (its value is not shown):",
      "the claude CLI will talk to wherever it points, which can be a company gateway",
    }
  end
  return {
    ("ANTHROPIC_BASE_URL is set: the claude CLI will talk to %s"):format(host),
    "and send its login and your prompts there -- this can be a company gateway",
  }
end

---A settings file of the claude CLI and the layer it belongs to.
---@class Ai.Providers.ClaudeCli.SettingsFile
---@field scope "user"|"managed"
---@field path string

---Largest settings file that is read. One is a few hundred bytes to a few kB; what
---is bigger is no settings file, and the decode stays bounded.
local MAX_SETTINGS_BYTES = 1024 * 1024

---@internal
---The system directory of the CLI's managed settings on a platform
---(code.claude.com/docs/en/settings). Pure: it only names the directory. Mutable
---on purpose, like `command`: the specs replace it, so that none of them lists the
---real system directory of the machine.
---@param platform? { is_windows?: boolean, is_macos?: boolean } defaults to the running one
---@return string dir
function M.managed_settings_dir(platform)
  platform = platform or require("lib.nvim.system.env").get()
  return (platform.is_windows and "C:/Program Files/ClaudeCode")
    or (platform.is_macos and "/Library/Application Support/ClaudeCode")
    or "/etc/claude-code"
end

---The CLI's file-based settings that apply to the child (code.claude.com/docs/en/
---settings, /managed-settings), where an `apiKeyHelper` or a key in the `env` block
---ranks above the login: the user file -- `settings.json` in `CLAUDE_CONFIG_DIR` when
---that is set, else in `~/.claude` (`%USERPROFILE%\.claude` on Windows, as the CLI
---resolves it) -- and the managed `managed-settings.json` plus its
---`managed-settings.d/*.json` drop-ins in the system directory
---(`managed_settings_dir`). The project files are left out: the child runs in a
---neutral directory. Server-managed settings and MDM are not files and cannot be
---seen from here.
---
---Mutable on purpose, like `command`: the specs replace it with fixture files, so
---none of them reads the real home directory. `opts.managed_dir` stands in for the
---system directory (the drop-in listing is tested against a fixture directory).
---@param opts? { managed_dir?: string }
---@return Ai.Providers.ClaudeCli.SettingsFile[]
function M.settings_files(opts)
  local files = {}
  local config_dir = util.env_value("CLAUDE_CONFIG_DIR")
  if not config_dir then
    local home = vim.uv.os_homedir()
    config_dir = home and vim.fs.joinpath(home, ".claude")
  end
  if config_dir then
    files[#files + 1] = { scope = "user", path = vim.fs.joinpath(config_dir, "settings.json") }
  end
  local dir = (opts and opts.managed_dir) or M.managed_settings_dir()
  files[#files + 1] = { scope = "managed", path = dir .. "/managed-settings.json" }
  local dropins, scan = {}, vim.uv.fs_scandir(dir .. "/managed-settings.d")
  while scan do
    local name = vim.uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if name:sub(-5) == ".json" and name:sub(1, 1) ~= "." then
      dropins[#dropins + 1] = name
    end
  end
  table.sort(dropins)
  for _, name in ipairs(dropins) do
    files[#files + 1] = { scope = "managed", path = dir .. "/managed-settings.d/" .. name }
  end
  return files
end

---Whether a decoded settings value counts as defined: there, and not `null`, `false`
---or the empty string. The documented type of both settings read here is a string;
---what else is set is a broken or unfamiliar value, and a login that may not be in
---use is worth a line.
---@param value any
---@return boolean
local function is_set(value)
  return value ~= nil and value ~= vim.NIL and value ~= false and value ~= ""
end

---@internal
---Whether decoded settings JSON defines `apiKeyHelper`: the key is there with a value
---that is not `null`, `false` or the empty string. Only the fact: the value (a
---command that can carry a secret) is not looked at.
---@param settings any
---@return boolean
function M.defines_api_key_helper(settings)
  return type(settings) == "table" and is_set(settings.apiKeyHelper)
end

---@internal
---The `TOKEN_ENV` variables that the `env` block of decoded settings JSON sets (set as
---for `apiKeyHelper`), in `TOKEN_ENV` order. The CLI applies that block to its own
---process once it runs, so unlike a variable of the editor's environment it is not
---removed from the child (`child_env`), and it can take the place of the login just as
---that variable would. The names come from the fixed list and never from the file: the
---value is not looked at beyond being there, and nothing else is returned. The match
---ignores case, because the process environment of Windows does.
---@param settings any
---@return string[] names
function M.settings_env_credentials(settings)
  local env = type(settings) == "table" and settings.env
  if type(env) ~= "table" then
    return {}
  end
  local set = {}
  for key, value in pairs(env) do
    if type(key) == "string" and is_set(value) then
      set[key:upper()] = true
    end
  end
  local names = {}
  for _, name in ipairs(TOKEN_ENV) do
    if set[name] then
      names[#names + 1] = name
    end
  end
  return names
end

---@internal
---The settings object in the file at `path`, or `nil`. The caller looks at the keys
---it needs and drops the rest at once: the content reaches no message, log or error.
---A file that is missing, too large, unreadable, not JSON or not an object gives
---`nil`: there is nothing to report from it, and a decode error is never echoed (it
---can quote the content).
---@param path string
---@return table|nil settings
local function read_settings(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > MAX_SETTINGS_BYTES then
    return nil
  end
  local content = read(path)
  if not content then
    return nil
  end
  if content:sub(1, 3) == "\239\187\191" then -- a UTF-8 BOM, as PowerShell writes one
    content = content:sub(4)
  end
  local ok, decoded = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  return ok and type(decoded) == "table" and decoded or nil
end

---What the settings files define that can take the place of the CLI's login.
---@class Ai.Providers.ClaudeCli.SettingsCredentials
---@field api_key_helper string[] the layers whose settings define `apiKeyHelper`
---@field env string[] the layers whose `env` block sets a `TOKEN_ENV` variable
---@field env_names string[] those variables, of any layer, in `TOKEN_ENV` order

---The credentials of the CLI's own settings that rank above its login and cannot be
---taken out of its child's environment, so `claude -p` may bill and act as another
---account than the one `claude auth login` set up: an `apiKeyHelper`, and an `env`
---block that sets an API key or token. Each file is read once. Reads nothing but
---whether the keys exist; never reports a value, a path or any other content. Layers
---(`"user"`, `"managed"`) are named once each, in the order of the files.
---@param files? Ai.Providers.ClaudeCli.SettingsFile[] defaults to `M.settings_files()`
---@return Ai.Providers.ClaudeCli.SettingsCredentials
function M.settings_credentials(files)
  local found = { api_key_helper = {}, env = {}, env_names = {} }
  local helper_seen, env_seen, name_seen = {}, {}, {}
  for _, file in ipairs(files or M.settings_files()) do
    local settings = read_settings(file.path)
    if settings then
      if not helper_seen[file.scope] and M.defines_api_key_helper(settings) then
        helper_seen[file.scope] = true
        found.api_key_helper[#found.api_key_helper + 1] = file.scope
      end
      local names = M.settings_env_credentials(settings)
      if #names > 0 and not env_seen[file.scope] then
        env_seen[file.scope] = true
        found.env[#found.env + 1] = file.scope
      end
      for _, name in ipairs(names) do
        name_seen[name] = true
      end
    end
  end
  for _, name in ipairs(TOKEN_ENV) do
    if name_seen[name] then
      found.env_names[#found.env_names + 1] = name
    end
  end
  return found
end

---The layers whose settings file defines an `apiKeyHelper` (`settings_credentials`
---for that one question). Empty when there is none.
---@param files? Ai.Providers.ClaudeCli.SettingsFile[] defaults to `M.settings_files()`
---@return string[] scopes
function M.api_key_helper_scopes(files)
  return M.settings_credentials(files).api_key_helper
end

---@internal
---@return table<string,string> env the current environment minus `CREDENTIAL_ENV`, with the CLI's attachment handling off
local function child_env()
  local env = vim.fn.environ()
  for _, name in ipairs(CREDENTIAL_ENV) do
    env[name] = nil
  end
  -- Second layer behind the `Read` deny rule, and independent of it, so a rule
  -- that is not applied (a settings format the CLI no longer reads, say) does
  -- not leave `@path` expanded: the CLI sends such mentions as plain text. Set
  -- last, so a value the editor was started with cannot switch it back on.
  env.CLAUDE_CODE_DISABLE_ATTACHMENTS = "1"
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
              util.trim(table.concat(stderr_parts, ""))
            ),
            obj
          )
        )
        return
      end
      -- A clean exit that said nothing: not an empty answer, a child that did
      -- not do what it is run for (a wrapper script, a CLI that changed its
      -- output). stderr is the only clue left.
      if not got_result and text == "" then
        local stderr = util.trim(table.concat(stderr_parts, ""))
        fail(
          lib_error.new(
            "invalid_response",
            "claude-cli: exited without a result event and without any text"
              .. (stderr ~= "" and (": " .. stderr) or ""),
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
