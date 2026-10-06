---@module 'ai.bulk'
--- Guard rails for unattended bulk requests: `ai.ask({ ..., bulk = {...} })`.
---
--- A plugin that sends a whole document to a provider in many small requests
--- (a translation of a markdown buffer, say) is a different case from a person
--- who selected a region and pressed a key: nobody looks at each request, and
--- the text may be long. This module is the leash, once, on the ai.nvim side
--- instead of in every calling plugin. It contains **no** task logic -- no
--- prompt, no chunking, no validation of the answer; the caller owns those.
---
--- What `req.bulk` enforces (`Ai.BulkOptions`):
---   * `max_chars` -- the largest request (prompt plus system) accepted;
---     anything bigger fails at once with `bulk_limit`, nothing is sent.
---   * `concurrency` -- how many requests of one `label` are in flight at the
---     same time; the rest wait in a FIFO queue (default 1).
---   * `label` -- names the run: the concurrency group and the budget group.
---   * `max_total_chars` -- cumulative cap for one `label` in this session.
---     `config.bulk.max_session_chars` caps all bulk requests of the session.
---     Past a cap the request fails with `bulk_limit` instead of costing more.
---   * policy -- see `ai.policy.is_bulk_allowed`: a provider outside the
---     allow-list is refused unless the user confirmed it for document text
---     (`policy.grant_bulk`) or the request says `bulk.allow_unlisted`. The
---     plain `allow_unlisted` and `:Ai provider` grants do not count here.
---   * determinism -- `temperature = 0` where the provider can take one.
---
--- The callback runs exactly once, always asynchronously (never inside `ask`),
--- and every refusal arrives as `cb(false, err)` -- nothing hangs: a request
--- that its provider never answers is failed by a watchdog.

local lib_error = require("lib.lua.error")

local M = {}

---Extra time past the request's own `timeout_ms` before the watchdog gives up
---on a provider that never answers.
M.watchdog_grace_ms = 5000

---@class Ai.Bulk.Job
---@field run? fun() starts the request (the slot is already counted)
---@field cancel? fun() ends the job as cancelled, exactly once
---@field started boolean
---@field done boolean
---@field chars integer

---@class Ai.Bulk.Group
---@field active integer in-flight requests
---@field chars integer characters admitted under this label
---@field queue Ai.Bulk.Job[]
---@field jobs table<Ai.Bulk.Job, true> every queued or in-flight job
---@field gen integer bumped by `reset`; a refund from an older generation is dropped

---@type table<string, Ai.Bulk.Group>
local groups = {}

---Characters admitted by every bulk request of this session.
---@type integer
local session_chars = 0

---Bumped by a full `reset()`, so a refund admitted before it is dropped.
---@type integer
local session_gen = 0

---@param label string
---@return Ai.Bulk.Group
local function group(label)
  local g = groups[label]
  if not g then
    g = { active = 0, chars = 0, queue = {}, jobs = {}, gen = 0 }
    groups[label] = g
  end
  return g
end

---@internal
---@param s string
---@return integer
local function char_count(s)
  return vim.fn.strchars(s)
end

---@internal
---@param v any
---@return boolean
local function positive_int(v)
  return type(v) == "number" and v >= 1 and v == math.floor(v)
end

---@internal
---Check the shape of `req.bulk` and the request around it.
---@param req Ai.Request
---@return LibErrorValue|nil
local function validate(req)
  local b = req.bulk
  local function bad(msg)
    return lib_error.new("invalid_request", "ai.bulk: " .. msg, { field = "bulk" })
  end
  if type(b) ~= "table" then
    return bad("`bulk` must be a table (label, max_chars, ...)")
  end
  if type(b.label) ~= "string" or b.label == "" then
    return bad("`bulk.label` is required (a non-empty string naming the run)")
  end
  if not positive_int(b.max_chars) then
    return bad("`bulk.max_chars` is required (a positive integer)")
  end
  if b.concurrency ~= nil and not positive_int(b.concurrency) then
    return bad("`bulk.concurrency` must be a positive integer")
  end
  if b.max_total_chars ~= nil and not positive_int(b.max_total_chars) then
    return bad("`bulk.max_total_chars` must be a positive integer")
  end
  if b.allow_unlisted ~= nil and type(b.allow_unlisted) ~= "boolean" then
    return bad("`bulk.allow_unlisted` must be a boolean")
  end
  if b.temperature ~= nil and b.temperature ~= false and type(b.temperature) ~= "number" then
    return bad("`bulk.temperature` must be a number, or false to send none")
  end
  if req.allow_unlisted ~= nil then
    return bad(
      "`allow_unlisted` does not apply to a bulk request; use `bulk.allow_unlisted` "
        .. "or `ai.policy.grant_bulk(id)` after asking the user"
    )
  end
  if req.attachments ~= nil and #req.attachments > 0 then
    return bad("a bulk request carries its text in `prompt`; attachments are not supported")
  end
  if type(req.context) == "table" and next(req.context) ~= nil then
    return bad("a bulk request gathers no editor context; put the text in `prompt`")
  end
  return nil
end

---@internal
---Configured cap for the whole session, or nil.
---@return integer|nil
local function session_cap()
  local cfg = require("ai.config").get()
  local n = cfg.bulk and cfg.bulk.max_session_chars
  if type(n) == "number" and n >= 1 then
    return n
  end
  return nil
end

---@internal
---Start queued jobs of `g` while slots are free.
---@param g Ai.Bulk.Group
---@param limit integer
local function pump(g, limit)
  while g.active < limit and #g.queue > 0 do
    local job = table.remove(g.queue, 1)
    if not job.done then
      g.active = g.active + 1
      job.started = true
      job.run()
    end
  end
end

---Ask once under the bulk guard rails. Called by `ai.ask` when `req.bulk` is set.
---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
---@param deps { resolve: fun(req: Ai.Request): Ai.Provider|nil, LibErrorValue|nil, Ai.Request, string[]|nil, dispatch: fun(provider: Ai.Provider, req: Ai.Request, cb: function) }
---@return table handle `kill()` ends the call (callback once with kind `cancelled`), `is_closing()` says it ended
function M.ask(req, cb, deps)
  local done = false
  local timer ---@type uv.uv_timer_t|nil
  ---@type Ai.Bulk.Job
  local job = { started = false, done = false, chars = 0 }
  local g ---@type Ai.Bulk.Group|nil
  local limit = 1
  local refund = 0
  local refund_gen, refund_session_gen = 0, 0

  local handle = {}

  ---Deliver the result, once and always asynchronously: a refusal must not
  ---run before `ask` has returned the handle, and a provider that answers
  ---synchronously must not either.
  local function finish(ok, res)
    if done then
      return
    end
    done = true
    job.done = true
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end
    if g then
      g.jobs[job] = nil
      if job.started then
        g.active = g.active - 1
      end
      if refund > 0 then
        -- A reset since admission already forgot these characters.
        if g.gen == refund_gen then
          g.chars = math.max(0, g.chars - refund)
          if session_gen == refund_session_gen then
            session_chars = math.max(0, session_chars - refund)
          end
        end
        refund = 0
      end
      pump(g, limit)
    end
    vim.schedule(function()
      cb(ok, res)
    end)
  end

  local function cancel()
    finish(
      false,
      lib_error.new(
        "cancelled",
        "ai.bulk: request cancelled",
        { label = req.bulk and req.bulk.label }
      )
    )
  end
  job.cancel = cancel

  function handle.kill(_, _signal)
    cancel()
  end

  function handle.is_closing(_)
    return done
  end

  local function refuse(err)
    finish(false, err)
    return handle
  end

  local verr = validate(req)
  if verr then
    return refuse(verr)
  end
  local bulk = req.bulk --[[@as Ai.BulkOptions]]
  limit = bulk.concurrency or 1

  local policy = require("ai.policy")
  local cfg = require("ai.config").get()
  local requested = req.provider or cfg.provider or "auto"
  -- An explicit provider is checked before resolution so the refusal can say
  -- what to do for bulk; "auto" only walks listed entries, so it cannot step
  -- outside the list.
  local explicit = requested ~= "auto"
  if explicit and not policy.is_bulk_allowed(requested, bulk) then
    return refuse(policy.bulk_refusal(requested))
  end

  local pre = vim.tbl_extend("force", {}, req)
  pre.bulk = nil
  -- Only an explicitly named provider that passed the bulk check may be
  -- opened past the plain allow-list; for "auto" this must stay unset.
  pre.allow_unlisted = (explicit and not policy.is_listed(requested)) or nil

  local provider, rerr, resolved = deps.resolve(pre)
  if not provider then
    return refuse(
      rerr or lib_error.new("provider_resolution", "ai: unknown error resolving a provider")
    )
  end
  -- Defence in depth: whatever resolved must itself pass the bulk check.
  if not policy.is_bulk_allowed(provider.id, bulk) then
    return refuse(policy.bulk_refusal(provider.id))
  end
  resolved.allow_unlisted = nil

  local chars = char_count(req.prompt) + char_count(req.system or "")
  job.chars = chars
  if chars > bulk.max_chars then
    return refuse(
      lib_error.new(
        "bulk_limit",
        ("ai.bulk: request is %d characters, over bulk.max_chars (%d)"):format(
          chars,
          bulk.max_chars
        ),
        { reason = "max_chars", chars = chars, limit = bulk.max_chars, label = bulk.label }
      )
    )
  end

  g = group(bulk.label)
  if bulk.max_total_chars and g.chars + chars > bulk.max_total_chars then
    return refuse(
      lib_error.new(
        "bulk_limit",
        ("ai.bulk: label '%s' would reach %d characters, over bulk.max_total_chars (%d)"):format(
          bulk.label,
          g.chars + chars,
          bulk.max_total_chars
        ),
        {
          reason = "max_total_chars",
          chars = chars,
          total = g.chars,
          limit = bulk.max_total_chars,
          label = bulk.label,
        }
      )
    )
  end
  local cap = session_cap()
  if cap and session_chars + chars > cap then
    return refuse(
      lib_error.new(
        "bulk_limit",
        ("ai.bulk: this session would reach %d bulk characters, over bulk.max_session_chars (%d)"):format(
          session_chars + chars,
          cap
        ),
        {
          reason = "max_session_chars",
          chars = chars,
          total = session_chars,
          limit = cap,
          label = bulk.label,
        }
      )
    )
  end

  -- Admitted: reserve the characters now so a burst of calls cannot overshoot.
  -- A request that is cancelled before it starts gives them back.
  g.chars = g.chars + chars
  session_chars = session_chars + chars
  refund = chars
  refund_gen, refund_session_gen = g.gen, session_gen

  -- Determinism, where the provider can take it.
  local can_temp = type(provider.capabilities) == "table" and provider.capabilities.temperature
  local temperature = nil
  if can_temp and bulk.temperature ~= false then
    temperature = resolved.temperature
    if temperature == nil then
      temperature = bulk.temperature or 0
    end
    resolved.temperature = temperature
  end

  local model = resolved.model or provider.default_model or "default"

  job.run = function()
    -- From here on the characters are spent, whatever happens.
    refund = 0
    local wait_ms = (resolved.timeout_ms or 60000) + M.watchdog_grace_ms
    timer = vim.uv.new_timer()
    if timer then
      timer:start(
        wait_ms,
        0,
        vim.schedule_wrap(function()
          finish(
            false,
            lib_error.new(
              "timeout",
              ("ai.bulk: no answer from '%s' within %d ms"):format(provider.id, wait_ms),
              { label = bulk.label, provider = provider.id }
            )
          )
        end)
      )
    end
    local ok_call, call_err = pcall(deps.dispatch, provider, resolved, function(ok, res)
      if done then
        return -- cancelled or timed out meanwhile: the late answer is dropped
      end
      if ok and type(res) == "table" then
        res.bulk = {
          provider = provider.id,
          model = model,
          label = bulk.label,
          temperature = temperature,
          deterministic = temperature == 0,
          chars = chars,
        }
      end
      if
        not ok
        and temperature ~= nil
        and type(res) == "table"
        and type(res.message) == "string"
        and res.message:lower():find("temperature", 1, true)
      then
        res.message = res.message
          .. " (bulk sent temperature = "
          .. tostring(temperature)
          .. "; set bulk.temperature = false to send none)"
      end
      finish(ok, res)
    end)
    if not ok_call then
      finish(
        false,
        lib_error.new(
          "network_error",
          "ai.bulk: provider raised: " .. tostring(call_err),
          { provider = provider.id }
        )
      )
    end
  end

  g.jobs[job] = true
  g.queue[#g.queue + 1] = job
  pump(g, limit)
  return handle
end

---Cancel every queued and in-flight bulk request of `label`. Each callback is
---called once with `kind = "cancelled"`; the queued ones cost nothing.
---@param label string
---@return integer cancelled how many requests were ended
function M.cancel(label)
  local g = groups[label]
  if not g then
    return 0
  end
  -- Empty the queue first, so ending an in-flight job does not start the
  -- queued ones that are about to be cancelled too.
  g.queue = {}
  local n = 0
  for _, job in ipairs(vim.tbl_keys(g.jobs)) do
    n = n + 1
    job.cancel()
  end
  return n
end

---@internal
---Queued jobs that will still run (a cancelled one may linger in the queue).
---@param g Ai.Bulk.Group
---@return integer
local function live_queued(g)
  local n = 0
  for _, job in ipairs(g.queue) do
    if not job.done then
      n = n + 1
    end
  end
  return n
end

---Counters, for a caller that wants to show progress or a cost estimate.
---@param label? string
---@return { session_chars: integer, label_chars: integer|nil, active: integer|nil, queued: integer|nil }
function M.usage(label)
  local g = label and groups[label] or nil
  return {
    session_chars = session_chars,
    label_chars = g and g.chars or nil,
    active = g and g.active or nil,
    queued = g and live_queued(g) or nil,
  }
end

---Forget the counters of one label, or of everything (session total too).
---Does not touch requests that are still running: they stay reachable through
---`cancel(label)`, and their later refund is dropped (generation check).
---@param label? string
---@return nil
function M.reset(label)
  if label then
    local g = groups[label]
    if g then
      session_chars = math.max(0, session_chars - g.chars)
      g.chars = 0
      g.gen = g.gen + 1
    end
    return
  end
  for name, g in pairs(groups) do
    g.chars = 0
    g.gen = g.gen + 1
    if next(g.jobs) == nil then
      groups[name] = nil
    end
  end
  session_gen = session_gen + 1
  session_chars = 0
end

return M
