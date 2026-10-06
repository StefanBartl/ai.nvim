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
--- that its provider never answers is failed by a watchdog. A field of the
--- wrong type or a NUL byte in the text is such a refusal, not an exception.
--- What still raises is the check `ai.ask` makes before it gets here, with or
--- without `bulk`: `req` must be a table with a string `prompt`, or the call is
--- a programming error and asserts instead of reaching the callback.

local lib_error = require("lib.lua.error")

local M = {}

---Extra time past the request's own `timeout_ms` before the watchdog gives up
---on a provider that never answers.
M.watchdog_grace_ms = 5000

---The watchdog's base when the request carries no usable `timeout_ms`.
local DEFAULT_TIMEOUT_MS = 60000

---The longest `timeout_ms` the watchdog is armed with (one hour), so a huge or
---infinite value cannot overflow the timer.
local MAX_TIMEOUT_MS = 3600000

---@class Ai.Bulk.Deps
---@field resolve fun(req: Ai.Request): (Ai.Provider|nil, LibErrorValue|nil, Ai.Request, string[]|nil)
---@field dispatch fun(provider: Ai.Provider, req: Ai.Request, cb: function, alive?: fun(): boolean)

---@class Ai.Bulk.Job
---@field run? fun() starts the request (the slot is already counted); never raises
---@field cancel? fun() ends the job as cancelled, exactly once
---@field fail? fun(err: LibErrorValue) ends the job with `err`, exactly once
---@field provider_id? string the provider that will answer it
---@field started boolean
---@field queued boolean waiting in `Ai.Bulk.Group.queue`, counted in `queued`
---@field done boolean
---@field chars integer

---@class Ai.Bulk.Group
---@field active integer in-flight requests
---@field chars integer characters admitted under this label
---@field queue table<integer, Ai.Bulk.Job> the waiting jobs, `head` to `tail`
---@field head integer index of the next job to start
---@field tail integer index of the last job in the queue (`head - 1` when empty)
---@field queued integer live jobs in the queue (a cancelled one lingers there)
---@field pumping boolean a drain of the queue is running up the stack
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
    g = {
      active = 0,
      chars = 0,
      queue = {},
      head = 1,
      tail = 0,
      queued = 0,
      pumping = false,
      jobs = {},
      gen = 0,
    }
    groups[label] = g
  end
  return g
end

---@internal
---Characters (code points) of `s`. `vim.fn.strchars` turns a string with a NUL
---byte into a Blob and raises E976 (which `nvim_buf_get_lines` can well hand
---over, from a file with NULs), so the NULs are swapped for another byte first:
---one character either way. An invalid UTF-8 byte counts as one, as in
---`strchars`; counting only lead bytes would let a run of them count as zero.
---@param s string
---@return integer
local function char_count(s)
  return vim.fn.strchars((s:gsub("%z", "\1")))
end

---@internal
---@param v any
---@return boolean
local function positive_int(v)
  return type(v) == "number" and v >= 1 and v == math.floor(v)
end

---@internal
---@param v any
---@return boolean
local function finite_number(v)
  return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

---@internal
---The milliseconds the watchdog waits on top of its grace: a whole number in
---1..MAX_TIMEOUT_MS. Anything that is not a number of at least 1 (a string,
---NaN, 0) is the default; a huge or infinite value is the maximum.
---@param v any
---@return integer
local function request_timeout_ms(v)
  if type(v) ~= "number" or v ~= v or v < 1 then
    return DEFAULT_TIMEOUT_MS
  end
  return math.floor(math.min(v, MAX_TIMEOUT_MS))
end

---@internal
---Check the shape of `req.bulk` and of the request around it. Nothing past
---this point has to guess a type, so nothing downstream can raise on one.
---@param req Ai.Request
---@return LibErrorValue|nil
local function validate(req)
  local b = req.bulk
  local function bad(msg, field)
    return lib_error.new("invalid_request", "ai.bulk: " .. msg, { field = field or "bulk" })
  end
  if type(b) ~= "table" then
    return bad("`bulk` must be a table (label, max_chars, ...)")
  end
  if type(req.prompt) ~= "string" then
    return bad("`prompt` must be a string", "prompt")
  end
  if req.system ~= nil and type(req.system) ~= "string" then
    return bad("`system` must be a string", "system")
  end
  if req.provider ~= nil and type(req.provider) ~= "string" then
    return bad("`provider` must be a string", "provider")
  end
  if req.timeout_ms ~= nil and not (type(req.timeout_ms) == "number" and req.timeout_ms >= 1) then
    return bad("`timeout_ms` must be a number of at least 1", "timeout_ms")
  end
  if req.temperature ~= nil and not finite_number(req.temperature) then
    return bad("`temperature` must be a finite number", "temperature")
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
  if b.temperature ~= nil and b.temperature ~= false and not finite_number(b.temperature) then
    return bad("`bulk.temperature` must be a finite number, or false to send none")
  end
  if req.allow_unlisted ~= nil then
    return bad(
      "`allow_unlisted` does not apply to a bulk request; use `bulk.allow_unlisted` "
        .. "or `ai.policy.grant_bulk(id)` after asking the user"
    )
  end
  if req.attachments ~= nil and (type(req.attachments) ~= "table" or #req.attachments > 0) then
    return bad("a bulk request carries its text in `prompt`; attachments are not supported")
  end
  if type(req.context) == "table" and next(req.context) ~= nil then
    return bad("a bulk request gathers no editor context; put the text in `prompt`")
  end
  return nil
end

---@internal
---Configured cap for the whole session, or nil for none. This is a cost guard,
---so a value that cannot be a cap fails closed to 0 (every bulk request is
---refused) rather than to "no cap": `ai.config` replaces a malformed value
---itself, this covers one that got into the live table some other way. A cap
---of 0 is a cap too -- it forbids bulk requests.
---@return number|nil
local function session_cap()
  local bulk_cfg = require("ai.config").get().bulk
  if bulk_cfg == nil then
    return nil
  end
  if type(bulk_cfg) ~= "table" then
    return 0
  end
  local n = bulk_cfg.max_session_chars
  if n == nil or n == false then
    return nil
  end
  if type(n) == "number" and n >= 0 then
    return math.floor(n)
  end
  return 0
end

---@internal
---Start queued jobs of `g` while slots are free (the loop of `pump`).
---@param g Ai.Bulk.Group
---@param limit integer
local function drain(g, limit)
  while g.active < limit and g.head <= g.tail do
    local job = g.queue[g.head]
    g.queue[g.head] = nil
    g.head = g.head + 1
    if not job.done then
      job.queued = false
      g.queued = g.queued - 1
      g.active = g.active + 1
      job.started = true
      job.run()
    end
  end
  if g.head > g.tail then
    g.head, g.tail = 1, 0
  end
end

---@internal
---Run `drain`, never nested. Not reentrant on purpose: a provider that answers
---at once (a missing key, a refused argument, a cache hit) makes `job.run`
---finish the job inside the call, and finishing pumps again -- one set of
---stack frames per queued job, an overflow for a long queue and the label
---stuck with a slot that is never freed. The nested call returns at once and
---the loop in `drain` picks the freed slot up. The flag is cleared however
---`drain` ends, or the label would never start another job.
---@param g Ai.Bulk.Group
---@param limit integer
local function pump(g, limit)
  if g.pumping then
    return
  end
  g.pumping = true
  local ok, err = pcall(drain, g, limit)
  g.pumping = false
  if not ok then
    error(err, 0)
  end
end

---@internal
---A copy of a provider's error for a request that never ran. `err` is whatever
---the provider handed to its callback, a custom one registered through
---`providers.register` included, so its `message` may be missing or not a
---string; `lib_error.new` asserts on that, and a throw here would abort the
---copies of everything still waiting. A message that cannot be used becomes a
---generic one.
---@param err table `err.kind` is a string
---@param provider_id string
---@return LibErrorValue
local function copy_error(err, provider_id)
  local message = err.message
  if type(message) ~= "string" then
    message = ("ai.bulk: no API key for provider '%s'"):format(provider_id)
  end
  return lib_error.new(err.kind, message, err.data)
end

---@internal
---A request ended with `missing_api_key`. A key that is not there (a locked
---vault, a cancelled passphrase prompt, an unset variable) is not there for the
---requests that wait behind it either, and asking for it once more for each
---one -- 300 chunks, 300 runs of the key command -- is a prompt storm in a run
---nobody is watching. Every job of `g` still waiting for the same provider
---ends with the same error instead, with neither a request nor a key command.
---@param g Ai.Bulk.Group
---@param provider_id string
---@param err LibErrorValue
local function fail_waiting(g, provider_id, err)
  for i = g.head, g.tail do
    local job = g.queue[i]
    if job and not job.done and job.provider_id == provider_id then
      job.fail(copy_error(err, provider_id))
    end
  end
end

---Ask once under the bulk guard rails. Called by `ai.ask` when `req.bulk` is set.
---@param req Ai.Request
---@param cb fun(ok: boolean, res_or_err: Ai.Response|LibErrorValue)
---@param deps Ai.Bulk.Deps
---@return table handle `kill()` ends the call (callback once with kind `cancelled`), `is_closing()` says it ended
function M.ask(req, cb, deps)
  local done = false
  local timer ---@type uv.uv_timer_t|nil
  ---@type Ai.Bulk.Job
  local job = { started = false, queued = false, done = false, chars = 0 }
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
      elseif job.queued then
        job.queued = false
        g.queued = g.queued - 1
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
    end
    -- Before the next job starts: its answer may come at once, and the order
    -- of the callbacks is the order of the requests.
    vim.schedule(function()
      cb(ok, res)
    end)
    if g then
      pump(g, limit)
    end
  end

  local function cancel()
    finish(
      false,
      lib_error.new(
        "cancelled",
        "ai.bulk: request cancelled",
        { label = type(req.bulk) == "table" and req.bulk.label or nil }
      )
    )
  end
  job.cancel = cancel
  job.fail = function(err)
    finish(false, err)
  end

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

  ---False once the call has ended (cancelled, timed out, answered): a request
  ---that is still waiting for a command-sourced key must then not be sent.
  local function alive()
    return not done
  end

  ---Everything up to the start of the request. Raises on a malformed input
  ---the checks missed; `M.ask` turns that into a refusal.
  local function admit()
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
    if cap and (cap == 0 or session_chars + chars > cap) then
      return refuse(
        lib_error.new(
          "bulk_limit",
          ("ai.bulk: this session would reach %d bulk characters, over bulk.max_session_chars (%d)%s"):format(
            session_chars + chars,
            cap,
            cap == 0
                and " -- a cap of 0 refuses every bulk request; check config.bulk (:checkhealth ai)"
              or ""
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
    local grp = g
    g.chars = g.chars + chars
    session_chars = session_chars + chars
    refund = chars
    refund_gen, refund_session_gen = g.gen, session_gen

    -- Determinism, where the provider can take it. What is sent is decided
    -- here, once, and `res.bulk` reports exactly that: `bulk.temperature`
    -- (a number, or false for none) wins over the request's own, which stands
    -- when `bulk.temperature` is not set; without either it is 0. A provider
    -- that has no temperature parameter gets none.
    local can_temp = type(provider.capabilities) == "table" and provider.capabilities.temperature
    local sent_temperature = nil ---@type number|nil
    local bulk_temperature = bulk.temperature
    if can_temp and bulk_temperature ~= false then
      sent_temperature = bulk_temperature
      if sent_temperature == nil then
        sent_temperature = resolved.temperature
      end
      if sent_temperature == nil then
        sent_temperature = 0
      end
    end
    resolved.temperature = sent_temperature

    local model = resolved.model or provider.default_model or "default"

    ---@param ok boolean
    ---@param res Ai.Response|LibErrorValue
    local function on_result(ok, res)
      if done then
        return -- cancelled or timed out meanwhile: the late answer is dropped
      end
      if ok and type(res) == "table" then
        res.bulk = {
          provider = provider.id,
          model = model,
          label = bulk.label,
          temperature = sent_temperature,
          deterministic = sent_temperature == 0,
          chars = chars,
        }
      end
      if
        not ok
        and sent_temperature ~= nil
        and type(res) == "table"
        and type(res.message) == "string"
        and res.message:lower():find("temperature", 1, true)
      then
        res.message = res.message
          .. " (bulk sent temperature = "
          .. tostring(sent_temperature)
          .. "; set bulk.temperature = false to send none)"
      end
      if not ok and type(res) == "table" and res.kind == "missing_api_key" then
        -- Fail fast (see `fail_waiting`). This job's own callback goes first,
        -- and the queue is held until the waiting ones are ended, or `finish`
        -- would start the next one -- and run the key command again. Whatever
        -- raises while it is held must not leave it held, or the label would
        -- never start another job: the flag is put back and the queue drained
        -- in every case, then the error goes on to the caller, as `pump` does.
        local nested = grp.pumping
        grp.pumping = true
        local held_ok, held_err = pcall(function()
          finish(ok, res)
          fail_waiting(grp, provider.id, res --[[@as LibErrorValue]])
        end)
        grp.pumping = nested
        pump(grp, limit)
        if not held_ok then
          error(held_err, 0)
        end
        return
      end
      finish(ok, res)
    end

    -- Never raises (the queue drain relies on it): whatever goes wrong while
    -- arming the watchdog or handing the request over ends the job instead.
    job.run = function()
      -- From here on the characters are spent, whatever happens.
      refund = 0
      local started, start_err = pcall(function()
        local wait_ms = math.floor(request_timeout_ms(resolved.timeout_ms) + M.watchdog_grace_ms)
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
        deps.dispatch(provider, resolved, on_result, alive)
      end)
      if not started then
        finish(
          false,
          lib_error.new(
            "network_error",
            "ai.bulk: starting the request raised: " .. tostring(start_err),
            { provider = provider.id }
          )
        )
      end
    end

    job.provider_id = provider.id
    g.jobs[job] = true
    job.queued = true
    g.queued = g.queued + 1
    g.tail = g.tail + 1
    g.queue[g.tail] = job
    pump(g, limit)
    return handle
  end

  local ok, err = lib_error.safe_call(admit)
  if not ok then
    -- A malformed input the checks missed: the callback gets it, the caller
    -- gets no exception. Whatever the job already holds is released by
    -- `finish` (a no-op when it ended already).
    local text = type(err) == "table" and err.message or tostring(err)
    refuse(
      lib_error.new(
        "invalid_request",
        "ai.bulk: the request could not be prepared: " .. text:match("^[^\n]*"),
        { field = "bulk", traceback = text }
      )
    )
  end
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
  g.queue, g.head, g.tail = {}, 1, 0
  local n = 0
  for _, job in ipairs(vim.tbl_keys(g.jobs)) do
    n = n + 1
    job.cancel()
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
    queued = g and g.queued or nil,
  }
end

---One line for `:Ai info` and `:checkhealth`: the session cap and what this
---session has used of it so far.
---@return string
function M.describe()
  local cap = session_cap()
  local cap_text = (cap and cap < math.huge) and ("%d characters"):format(cap) or "none"
  return ("session cap %s, %d characters used"):format(cap_text, session_chars)
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
