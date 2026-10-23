---@module 'ai.bindings.actions'
--- Shared action bodies for both `:Ai` subcommands and the quick-action
--- keymaps -- one place owns "what does ask/stream/explain/info actually
--- do"; keymaps and usercmds both only wire input into it (`PRIN-01`: one
--- reason to change).

require("ai.@types")

local M = {}

---@internal
---@param cb fun(text: string)
local function prompt_for_text(cb)
  require("ui.kit").popup({
    type = "input",
    prompt = "Ai prompt",
    on_submit = function(text)
      if text and text ~= "" then
        cb(text)
      end
    end,
  })
end

---Ask once, non-streaming; shows the answer in a read-only viewer popup.
---Prompts for text first when `prompt` is empty.
---@param prompt string
---@param context? Ai.ContextDefaults
---@return nil
function M.ask_prompt(prompt, context)
  local function run(text)
    local notify = require("lib.nvim.notify").create("[ai]")
    local progress = require("lib.nvim.progress").create({ title = "[ai]" })
    require("ai").ask({ prompt = text, context = context }, function(ok, res)
      progress:finish()
      if not ok then
        ---@cast res LibErrorValue
        notify.error(res.message)
        return
      end
      require("ui.kit").popup({
        type = "viewer",
        title = "AI",
        lines = vim.split(res.text, "\n", { plain = true }),
      })
    end)
  end

  if prompt ~= "" then
    run(prompt)
  else
    prompt_for_text(run)
  end
end

---Ask, streaming the answer into an `ai.ui.panel`. Prompts for text first
---when `prompt` is empty.
---@param prompt string
---@param context? Ai.ContextDefaults
---@return nil
function M.stream_prompt(prompt, context)
  local function run(text)
    local cfg = require("ai").config()
    local panel = require("ai.ui.panel").open({
      title = "AI",
      theme = cfg.ui.panel_theme,
      progress_style = cfg.ui.progress_style,
    })
    local process = require("ai").stream({ prompt = text, context = context }, {
      on_chunk = function(delta)
        require("ai.ui.panel").append(panel, delta)
      end,
      on_done = function(res)
        require("ai.ui.panel").finish(
          panel,
          res.stop_reason and ("[" .. res.stop_reason .. "]") or nil
        )
      end,
      on_error = function(err)
        require("ai.ui.panel").append(panel, "\n\n[error] " .. err.message)
        require("ai.ui.panel").finish(panel, "error")
      end,
    })
    require("ai.ui.panel").attach_process(panel, process)
  end

  if prompt ~= "" then
    run(prompt)
  else
    prompt_for_text(run)
  end
end

---Quick-action from the concept: send the current context straight to the
---AI together with a user-typed task, streaming the answer immediately --
---e.g. Trouble/quickfix has 5 errors listed, hit the hotkey, type "fix the
---quickfix list", get a streamed answer without any other setup.
---@param context Ai.ContextDefaults
---@return nil
function M.quick_action(context)
  prompt_for_text(function(text)
    M.stream_prompt(text, context)
  end)
end

local edit = require("ai.bindings.edit")

---@internal
local REWRITE_SYSTEM = "You rewrite code on request. Respond with only the "
  .. "replacement code for the given block -- no explanation, no markdown "
  .. "code fences, no commentary. Match the original indentation style."

---@internal
local INSERT_AFTER_SYSTEM = "You write code on request. Respond with only "
  .. "the code to insert immediately after the given block -- no "
  .. "explanation, no markdown code fences, no commentary. Match the "
  .. "surrounding indentation style."

---@internal
local INSERT_BEFORE_SYSTEM = "You write code on request. Respond with only "
  .. "the code to insert immediately before the given block -- no "
  .. "explanation, no markdown code fences, no commentary. Match the "
  .. "surrounding indentation style."

---@internal
---Shared body for rewrite/append/prepend: resolve the target range, ask
---non-streaming (an in-place edit needs the full answer before it can write
---anything -- no partial line half-written mid-stream), then hand the
---parsed response lines to `apply` for exactly one `nvim_buf_set_lines`
---call, so the whole edit is a single undo step. Prompts for the task first
---when `prompt` is empty.
---@param system string
---@param prompt string
---@param range? {line1: integer, line2: integer}
---@param apply fun(bufnr: integer, line1: integer, line2: integer, new_lines: string[])
---@return nil
local function run_edit(system, prompt, range, apply)
  local function run(task)
    local bufnr = vim.api.nvim_get_current_buf()
    local line1, line2 = edit.resolve_range(range)
    local block = edit.code_block(bufnr, line1, line2)
    -- `ai.ask` is a full network round-trip -- snapshot the tick now so the
    -- callback can tell a buffer closed or edited elsewhere meanwhile from
    -- one still safe to write `line1`/`line2` into (see `edit.buffer_changed`'s
    -- own doc for why a silent overwrite of the wrong lines is the real risk,
    -- not just a deleted-buffer crash).
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local notify = require("lib.nvim.notify").create("[ai]")
    -- a read-only buffer can never take the answer: say so before the request, not after a round-trip
    if not vim.bo[bufnr].modifiable then
      notify.error("This buffer is not modifiable -- nothing was sent")
      return
    end
    local progress = require("lib.nvim.progress").create({ title = "[ai]" })
    require("ai").ask({
      prompt = block .. "\n\nTask: " .. task,
      system = system,
      -- Only the claude backend reads this today (Ai.Request's own doc),
      -- but a rewrite/append/prepend answer is plausibly longer than a
      -- short chat reply, and the plugin-wide default (4096) is sized for
      -- the latter -- give edit requests more headroom before hitting it.
      max_tokens = 8192,
    }, function(ok, res)
      progress:finish()
      if not ok then
        ---@cast res LibErrorValue
        notify.error(res.message)
        return
      end
      if edit.buffer_changed(bufnr, changedtick) then
        notify.warn(
          "Buffer changed while waiting for a response -- discarded it rather than risk editing the wrong lines"
        )
        return
      end
      if edit.is_truncated(res.stop_reason) then
        notify.warn(
          "Response was cut off (stop_reason: "
            .. tostring(res.stop_reason)
            .. ") -- discarded rather than write incomplete code. Try a smaller selection."
        )
        return
      end
      local new_lines = edit.parse_lines(res.text)
      if #new_lines == 0 then
        notify.warn("Empty response, buffer left unchanged")
        return
      end
      -- `edit.buffer_changed` checks validity and changedtick, not 'modifiable': a read-only
      -- buffer (help, a viewer, a plugin's scratch) makes `nvim_buf_set_lines` raise
      local applied, apply_err = pcall(apply, bufnr, line1, line2, new_lines)
      if not applied then
        -- the API error arrives with the closure's `file:line:` in front: not for the user's eyes
        local reason = tostring(apply_err):gsub("^.-:%d+: ", "", 1)
        notify.error("Could not write the answer into the buffer: " .. reason)
      end
    end)
  end

  if prompt ~= "" then
    run(prompt)
  else
    prompt_for_text(run)
  end
end

---Replace the target range (the Visual selection just left, or the current
---line) with AI-generated code -- e.g. select a function, run this, type
---"add error handling". Prompts for the task first when `prompt` is empty.
---@param prompt string
---@param range? {line1: integer, line2: integer}
---@return nil
function M.rewrite_prompt(prompt, range)
  run_edit(REWRITE_SYSTEM, prompt, range, function(bufnr, line1, line2, new_lines)
    vim.api.nvim_buf_set_lines(bufnr, line1 - 1, line2, false, new_lines)
  end)
end

---Insert AI-generated code immediately after the target range (the Visual
---selection just left, or the current line). Prompts for the task first
---when `prompt` is empty.
---@param prompt string
---@param range? {line1: integer, line2: integer}
---@return nil
function M.append_prompt(prompt, range)
  run_edit(INSERT_AFTER_SYSTEM, prompt, range, function(bufnr, _, line2, new_lines)
    vim.api.nvim_buf_set_lines(bufnr, line2, line2, false, new_lines)
  end)
end

---Insert AI-generated code immediately before the target range (the Visual
---selection just left, or the current line). Prompts for the task first
---when `prompt` is empty.
---@param prompt string
---@param range? {line1: integer, line2: integer}
---@return nil
function M.prepend_prompt(prompt, range)
  run_edit(INSERT_BEFORE_SYSTEM, prompt, range, function(bufnr, line1, _, new_lines)
    vim.api.nvim_buf_set_lines(bufnr, line1 - 1, line1 - 1, false, new_lines)
  end)
end

---Second quick-action from the concept: explain the current context
---without a chat panel -- a small, auto-dismissing badge instead.
---@param context Ai.ContextDefaults
---@return nil
function M.explain_badge(context)
  local ctx_block, ctx_errors = require("ai.context").assemble(context)
  if ctx_errors then
    require("lib.nvim.notify")
      .create("[ai]")
      .warn("Failed to gather context: " .. table.concat(ctx_errors, "; "))
    return
  end
  if ctx_block == "" then
    require("lib.nvim.notify").create("[ai]").warn("Nothing to explain in the current context")
    return
  end

  local cfg = require("ai").config()
  require("ai").ask({
    prompt = "Explain this briefly, in at most 3 sentences.",
    context = context,
  }, function(ok, res)
    if not ok then
      ---@cast res LibErrorValue
      require("ai.ui.badge").show({
        title = "AI (error)",
        message = res.message,
        timeout_ms = cfg.ui.badge_timeout_ms,
      })
      return
    end
    require("ai.ui.badge").show({
      title = "AI",
      message = res.text,
      timeout_ms = cfg.ui.badge_timeout_ms,
    })
  end)
end

---Stop every running stream (the panels' curl requests). Only streams: `ask`, `rewrite`/`append`/`prepend` and
---completion hold no process handle to cancel yet (decision of 2026-10-04), which the message says when it
---stopped nothing.
---@return integer cancelled
function M.stop()
  local cancelled = require("ai.ui.panel").cancel_all()
  local notify = require("lib.nvim.notify").create("[ai]")
  if cancelled > 0 then
    notify.info(("stopped %d running stream%s"):format(cancelled, cancelled == 1 and "" or "s"))
  else
    notify.info(
      "no stream is running (only streams can be stopped; a one-shot ask or an edit runs to its end)"
    )
  end
  return cancelled
end

---@internal
---One line for an agent: its name and what it sets.
---@param name string
---@param def Ai.Agent
---@return string
local function describe_agent(name, def)
  local parts = {}
  if def.provider then
    parts[#parts + 1] = "provider=" .. def.provider
  end
  if def.model then
    parts[#parts + 1] = "model=" .. def.model
  end
  if def.system then
    parts[#parts + 1] = ("system=%d chars"):format(#def.system)
  end
  return ("%s (%s)"):format(name, #parts > 0 and table.concat(parts, ", ") or "no fields set")
end

---Switch the active agent for this session (`none` = no agent; no name shows
---the active one). Nothing is written anywhere, like `set_provider`: the next
---Neovim starts with `config.agent` again. An agent whose provider the policy
---does not allow is switched to all the same, with a warning: the policy
---refuses its requests, as it refuses any request for that provider.
---@param name string|nil
---@return nil
function M.set_agent(name)
  local config = require("ai.config")
  local notify = require("lib.nvim.notify").create("[ai]")
  local active, def = config.agent()
  if name == nil or name == "" then
    notify.info("agent: " .. (active and describe_agent(active, def) or "none"))
    return
  end
  if name == "none" then
    config.set_agent(false)
    notify.info("agent: none")
    return
  end
  local agents = config.get().agents or {}
  local chosen = agents[name]
  if not chosen then
    local names = config.agent_names()
    notify.warn(
      ("unknown agent %q (configured: %s)"):format(
        name,
        #names > 0 and table.concat(names, ", ") or "none"
      )
    )
    return
  end
  config.set_agent(name)
  notify.info("agent: " .. describe_agent(name, chosen))
  if chosen.provider and chosen.provider ~= "auto" then
    local policy = require("ai.policy")
    if not policy.is_allowed(chosen.provider) then
      notify.warn(
        ("provider '%s' of this agent is not on the allow-list (%s): its requests are refused"):format(
          chosen.provider,
          policy.describe()
        )
      )
    end
  end
end

---Switch to the next configured agent, in name order, wrapping around.
---@return nil
function M.next_agent()
  local config = require("ai.config")
  local names = config.agent_names()
  if #names == 0 then
    require("lib.nvim.notify").create("[ai]").warn("no agents configured (config.agents)")
    return
  end
  local active = config.agent()
  local at = 0
  for i, name in ipairs(names) do
    if name == active then
      at = i
    end
  end
  M.set_agent(names[at % #names + 1])
end

---Show the active provider, the auto-resolution order, and per-provider
---availability -- never a key's actual value.
---@return nil
function M.info()
  local cfg = require("ai").config()
  local providers = require("ai.providers")
  local policy = require("ai.policy")

  local active, def = require("ai.config").agent()
  local lines = {
    "provider: " .. cfg.provider,
    "agent: " .. (active and describe_agent(active, def) or "none"),
    "provider_order: " .. table.concat(cfg.provider_order, ", "),
    "policy: " .. policy.describe(),
  }
  for _, id in ipairs(policy.granted()) do
    lines[#lines + 1] = ("  session grant outside the list: %s"):format(id)
  end
  lines[#lines + 1] = "bulk: " .. require("ai.bulk").describe()
  for _, id in ipairs(policy.bulk_granted()) do
    lines[#lines + 1] = ("  session grant for bulk requests outside the list: %s"):format(id)
  end
  local keys = require("ai.keys")
  for _, id in ipairs(keys.providers()) do
    lines[#lines + 1] = ("keys.%s: %s"):format(id, keys.describe(id))
  end
  lines[#lines + 1] = ""
  for _, id in ipairs(providers.ids()) do
    local p = providers.get(id)
    local avail = p and type(p.available) == "function" and p.available()
    local flag = ""
    if policy.restricted() and not policy.is_listed(id) then
      flag = policy.is_allowed(id) and " [outside the allow-list, granted]" or " [not allowed]"
    end
    lines[#lines + 1] =
      string.format("  %s: %s%s", id, avail and "available" or "not available", flag)
    -- Where the CLI will really send its requests, if that was changed by the
    -- environment (host only, see `gateway_note`).
    local gateway = id == "claude-cli" and require("ai.providers.claude_cli").gateway_note()
    for _, line in ipairs(gateway or {}) do
      lines[#lines + 1] = "    " .. line
    end
    if id == "copilot" and avail then
      lines[#lines + 1] =
        "    login: not checked (a check would use credit); the first request reports it"
    end
    local names = providers.capability_names(p)
    lines[#lines + 1] = "    can: " .. (#names > 0 and table.concat(names, ", ") or "text only")
  end

  require("ui.kit").popup({ type = "viewer", title = "Ai info", lines = lines })
end

---`:Ai key [<profile>|reset] [<provider>]`. Chooses the API-key profile for the
---session on every provider that defines it (or only on `<provider>`); `reset`
---returns to the configured `active` profile / the default variable; no
---argument shows the setup. Session only, nothing is written. Never prints a key.
---@param profile? string
---@param provider? string
---@return nil
function M.set_key(profile, provider)
  local keys = require("ai.keys")
  local notify = require("lib.nvim.notify").create("[ai]")
  if not profile then
    local lines = {}
    for _, id in ipairs(keys.providers()) do
      lines[#lines + 1] = ("%s: %s  [profiles: %s]"):format(
        id,
        keys.describe(id),
        table.concat(keys.profiles(id), ", ")
      )
    end
    if #lines == 0 then
      lines[1] =
        "no key profiles configured (config.keys is empty) -- providers use their own variable"
    end
    require("ui.kit").popup({ type = "viewer", title = "Ai keys", lines = lines })
    return
  end
  if profile == "reset" then
    keys.reset(provider)
    notify.info("key profile reset" .. (provider and (" for " .. provider) or ""))
    return
  end
  local switched = keys.use(profile, provider)
  if #switched == 0 then
    notify.warn(("no provider defines a key profile '%s'"):format(profile))
    return
  end
  notify.info(
    ("key profile '%s' for %s (this session)"):format(profile, table.concat(switched, ", "))
  )
end

---`:Ai provider <name>`. A provider that is allowed -- on the machine's
---allow-list, granted earlier in this session, or any provider when there is no
---list -- is set at once. One outside it is a deliberate step, not an accident:
---the user is asked, and a yes allows it for this session only
---(`ai.policy.grant`) -- nothing is written anywhere, the next Neovim starts
---back inside the list. `auto` is not a provider but the walk over
---`provider_order`, which the policy already narrows to the listed entries
---(and a grant never widens), so it is set at once on every machine.
---@param name string
---@return nil
function M.set_provider(name)
  local policy = require("ai.policy")
  local config = require("ai.config")
  local notify = require("lib.nvim.notify").create("[ai]")
  local auto = name == "auto"

  local function switch()
    config.set_provider(name)
    if auto or policy.is_listed(name) then
      notify.info("provider set to " .. name)
    else
      notify.warn(("provider set to %s (outside the allow-list, this session only)"):format(name))
    end
  end

  if auto or policy.is_allowed(name) then
    switch()
    return
  end

  require("ui.kit").confirm({
    question = ("'%s' is not on this machine's allow-list (%s).\nUse it anyway, for this session only?"):format(
      name,
      policy.describe()
    ),
    -- "No" first: the dialog opens on the first button, so a stray <CR> (a double
    -- tap, a typed-ahead key) must decline. Anything but "Yes" -- <Esc>, `q`, a
    -- dialog that failed to open (`nil`) -- declines too.
    choices = { "No", "Yes" },
    on_answer = function(choice)
      if choice ~= "Yes" then
        notify.warn("provider unchanged")
        return
      end
      policy.grant(name)
      switch()
    end,
  })
end

return M
