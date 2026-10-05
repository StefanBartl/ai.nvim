-- Stand-in for `claude -p` in providers_claude_cli_spec.lua, run as
-- `nvim -l fake_claude.lua <the flags ai.nvim passes>`. Which scenario it
-- plays is chosen by a keyword in the prompt on stdin. Emits the same
-- newline-delimited stream-json events the real CLI prints.
local stdin = io.stdin:read("*a") or ""
local scenario = "OK"
-- Order matters: a name must precede any shorter name it contains
-- (PARTIALCRASH before CRASH, PARTIALSLEEP before SLEEP).
for _, name in ipairs({
  "ECHO",
  "BILLING",
  "PARTIALCRASH",
  "PARTIALSLEEP",
  "RESULTEXIT",
  "ASSISTANTONLY",
  "CRASH",
  "SLEEP",
  "NOPARTIAL",
}) do
  if stdin:find(name, 1, true) then
    scenario = name
    break
  end
end

local function emit(ev)
  io.stdout:write(vim.json.encode(ev), "\n")
  io.stdout:flush()
end
local function delta(text)
  emit({
    type = "stream_event",
    event = { type = "content_block_delta", delta = { type = "text_delta", text = text } },
  })
end
local function result(text, is_error)
  emit({
    type = "result",
    subtype = is_error and "error" or "success",
    is_error = is_error or false,
    result = text,
    usage = { output_tokens = 2 },
  })
end

emit({ type = "system", subtype = "init" })

if scenario == "BILLING" then
  emit({
    type = "assistant",
    message = { content = { { type = "text", text = "Credit balance is too low" } } },
  })
  result("Credit balance is too low", true)
  os.exit(1)
elseif scenario == "CRASH" then
  io.stderr:write("boom\n")
  os.exit(3)
elseif scenario == "PARTIALCRASH" then
  -- dies mid-answer: some text was streamed, no result event ever comes
  delta("Hel")
  io.stderr:write("boom\n")
  os.exit(1)
elseif scenario == "PARTIALSLEEP" then
  -- streams the first chunk, then hangs so the spec can kill it mid-answer
  delta("Hel")
  vim.uv.sleep(20000)
elseif scenario == "RESULTEXIT" then
  -- a complete answer, then a non-zero exit: the answer is still whole
  delta("Hello")
  result("Hello")
  os.exit(1)
elseif scenario == "SLEEP" then
  vim.uv.sleep(20000)
elseif scenario == "NOPARTIAL" then
  emit({ type = "assistant", message = { content = { { type = "text", text = "whole answer" } } } })
  result("whole answer")
elseif scenario == "ASSISTANTONLY" then
  -- a success result that carries no `result` field: only the assistant event has the text
  emit({
    type = "assistant",
    message = { content = { { type = "text", text = "assistant only" } } },
  })
  result(nil)
elseif scenario == "ECHO" then
  local info = vim.json.encode({
    argv = vim.list_slice(arg, 1, #arg),
    key = os.getenv("ANTHROPIC_API_KEY"),
    token = os.getenv("ANTHROPIC_AUTH_TOKEN"),
    path = os.getenv("PATH") ~= nil,
    cwd = vim.uv.cwd(),
    stdin = stdin,
  })
  delta(info)
  result(info)
else
  delta("Hel")
  delta("lo")
  emit({ type = "assistant", message = { content = { { type = "text", text = "Hello" } } } })
  result("Hello")
end
os.exit(0)
