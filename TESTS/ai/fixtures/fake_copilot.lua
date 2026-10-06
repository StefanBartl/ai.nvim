-- Stand-in for `copilot` (GitHub Copilot CLI) in providers_copilot_cli_spec.lua,
-- run as `nvim -l fake_copilot.lua <the flags ai.nvim passes>`. Which scenario it
-- plays is chosen by a keyword in the prompt on stdin. The success events are a
-- trimmed copy of what copilot 1.0.92 prints with `--output-format json` (observed
-- on the real binary); the error scenarios are modelled on the stderr texts of the
-- real binary (classic PAT, token not validated, unknown model) and, for the
-- mid-run failures (CREDIT, ERROREVENT), on a GUESSED shape -- no failing account
-- was available to record one.
local stdin = io.stdin:read("*a") or ""
local scenario = "OK"
-- Order matters: a name must precede any shorter name it contains
-- (PARTIALCRASH before CRASH, PARTIALSLEEP before SLEEP).
for _, name in ipairs({
  "ECHO",
  "CLASSICPAT",
  "BADTOKEN",
  "NOLOGIN",
  "BADMODEL",
  "CREDIT",
  "ERROREVENT",
  "TOOLREQ",
  "TOOLEVENT",
  "COMMENTARYONLY",
  "NORESULT",
  "NOTEXT",
  "RESULTEXIT",
  "PARTIALCRASH",
  "PARTIALSLEEP",
  "CRASH",
  "SLEEP",
}) do
  if stdin:find(name, 1, true) then
    scenario = name
    break
  end
end

local n = 0
local function emit(kind, data, extra)
  n = n + 1
  local ev =
    { type = kind, data = data or {}, id = "ev" .. n, timestamp = "2026-10-06T15:56:12.266Z" }
  for k, v in pairs(extra or {}) do
    ev[k] = v
  end
  io.stdout:write(vim.json.encode(ev), "\n")
  io.stdout:flush()
end
local function start(id, phase)
  emit("assistant.message_start", { messageId = id, phase = phase }, { ephemeral = true })
end
local function delta(id, text)
  emit("assistant.message_delta", { messageId = id, deltaContent = text }, { ephemeral = true })
end
local function message(id, text, phase, tool_requests)
  emit("assistant.message", {
    messageId = id,
    content = text,
    toolRequests = tool_requests or {},
    phase = phase,
  })
end
local function result(code)
  io.stdout:write(
    vim.json.encode({
      type = "result",
      timestamp = "2026-10-06T15:56:15.735Z",
      sessionId = "s1",
      exitCode = code or 0,
      usage = { premiumRequests = 1 },
    }),
    "\n"
  )
  io.stdout:flush()
end
local function fatal(text)
  io.stderr:write(text, "\n")
  os.exit(1)
end

if scenario == "CLASSICPAT" then
  fatal(
    "Error: Classic Personal Access Tokens (ghp_) are not supported by Copilot.\n\n"
      .. "The GITHUB_TOKEN environment variable contains a classic PAT."
  )
elseif scenario == "BADTOKEN" then
  fatal(
    "Error: Authentication token found but could not be validated.\n\n"
      .. "  Failed to fetch PAT user login (401): GitHub returned: Bad credentials"
  )
elseif scenario == "NOLOGIN" then
  fatal("Error: Not logged in. Run 'copilot login' to authenticate.")
elseif scenario == "BADMODEL" then
  fatal('Error: Model "x" from --model flag is not available.')
end

emit("session.mcp_servers_loaded", { servers = {} }, { ephemeral = true })
emit("user.message", { content = stdin })
emit("assistant.turn_start", { turnId = "0" })

if scenario == "CREDIT" then
  -- GUESSED shape of a run that fails inside the model call
  emit("model.call_finished", { turnId = "0", outcome = "error" }, { ephemeral = true })
  emit("model.call_final_result", { model = "m", result = "error" }, { ephemeral = true })
  result(1)
  io.stderr:write("Error: You have exceeded your premium request quota.\n")
  os.exit(1)
elseif scenario == "ERROREVENT" then
  -- GUESSED shape: an event of a type that names an error, message in data
  emit("session.error", { message = "backend exploded" })
  result(1)
  os.exit(1)
elseif scenario == "TOOLREQ" then
  start("m1", "final_answer")
  delta("m1", "running it")
  message("m1", "running it", "final_answer", { { name = "powershell", arguments = {} } })
  result(0)
elseif scenario == "TOOLEVENT" then
  emit("tool.execution_start", { toolName = "view" })
  start("m1", "final_answer")
  delta("m1", "done")
  message("m1", "done", "final_answer")
  result(0)
elseif scenario == "COMMENTARYONLY" then
  start("m1", "commentary")
  delta("m1", "only commentary")
  message("m1", "only commentary", "commentary")
  result(0)
elseif scenario == "NORESULT" then
  start("m1", "final_answer")
  delta("m1", "no result event")
  message("m1", "no result event", "final_answer")
elseif scenario == "NOTEXT" then
  result(0)
elseif scenario == "RESULTEXIT" then
  start("m1", "final_answer")
  delta("m1", "Hello")
  message("m1", "Hello", "final_answer")
  result(0)
  os.exit(1)
elseif scenario == "CRASH" then
  io.stderr:write("boom\n")
  os.exit(3)
elseif scenario == "PARTIALCRASH" then
  start("m1", "final_answer")
  delta("m1", "Hel")
  io.stderr:write("boom\n")
  os.exit(1)
elseif scenario == "PARTIALSLEEP" then
  start("m1", "final_answer")
  delta("m1", "Hel")
  vim.uv.sleep(20000)
elseif scenario == "SLEEP" then
  vim.uv.sleep(20000)
elseif scenario == "ECHO" then
  -- names only, never values: the editor may be started with real credentials.
  -- The few values echoed are switches the provider sets itself.
  local env = {}
  for name in pairs(vim.fn.environ()) do
    local upper = name:upper()
    if
      upper:find("^COPILOT")
      or upper:find("^OTEL")
      or upper == "GH_TOKEN"
      or upper == "GITHUB_TOKEN"
      or upper == "GH_HOST"
      or upper == "HTTPS_PROXY"
    then
      env[name] = true
    end
  end
  local home = os.getenv("COPILOT_HOME")
  if home then
    -- what the real CLI does: persist the session under its home
    vim.fn.mkdir(home .. "/session-state/s1", "p")
    local f = io.open(home .. "/session-state/s1/events.jsonl", "w")
    if f then
      f:write(stdin)
      f:close()
    end
  end
  local info = vim.json.encode({
    argv = vim.list_slice(arg, 1, #arg),
    env = env,
    allow_all = os.getenv("COPILOT_ALLOW_ALL"),
    auto_update = os.getenv("COPILOT_AUTO_UPDATE"),
    model = os.getenv("COPILOT_MODEL"),
    home = home,
    path = os.getenv("PATH") ~= nil,
    cwd = vim.uv.cwd(),
    stdin = stdin,
  })
  start("m0", "commentary")
  delta("m0", "thinking...")
  message("m0", "thinking...", "commentary")
  start("m1", "final_answer")
  delta("m1", info)
  message("m1", info, "final_answer")
  result(0)
else
  start("m0", "commentary")
  delta("m0", "let me think")
  message("m0", "let me think", "commentary")
  start("m1", "final_answer")
  delta("m1", "Hel")
  delta("m1", "lo")
  message("m1", "Hello", "final_answer")
  result(0)
end
os.exit(0)
