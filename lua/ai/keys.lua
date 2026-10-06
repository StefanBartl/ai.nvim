---@module 'ai.keys'
--- Named API-key profiles per provider, and the session switch between them.
---
--- A machine (or a person) can have more than one credential for the same
--- provider -- a private key now, a company account later. `config.keys`
--- names them and says where each one comes from; `:Ai key <profile>` picks
--- one for the session. Without any `keys` config nothing here is active and
--- every provider reads its own environment variable exactly as before.
---
--- The rules, each one a deliberate choice:
---
--- - **A chosen profile never falls back to the default variable.** If the
---   active profile's source is empty, the request fails (`missing_api_key`,
---   naming the profile) instead of quietly sending customer data with the
---   other account's key. That holds for the configured `active` too: one that
---   names no defined profile (a typo, a profile that is not a table) is still
---   a chosen profile, so it yields no key, not the default one.
--- - **The key is never shown.** `describe()`/`info` print the profile name
---   and the kind of source (`env NAME`, `file`), never the value -- and an
---   `env` that looks like a vendor's key instead of a variable name (the key
---   itself, pasted where the name belongs) is not echoed either. The test is
---   the shape of the known keys, not a guess at randomness, so a long name
---   with words in it (`Company_Anthropic_Key_Production_2`) is never mistaken
---   for one (see `env_name_ok`).
--- - **Sources are `env` (a variable name), `file` (first non-empty line) and
---   `command` (an argv list, first non-empty line of its stdout).** `env` and
---   `file` are read synchronously and are cheap. A `command` never runs on the
---   UI thread and never from `available()`: a configured command counts as
---   available, and `ai.ask`/`ai.stream` run `fetch()` first and continue with
---   the cached key (see "The command source" below). A file is re-read when its mtime or size changes, so
---   replacing the file takes effect without a restart. It may be UTF-8
---   (with or without BOM) or UTF-16 with a BOM, which is what Windows
---   PowerShell 5.1 writes.
--- - **The switch is session-only.** Nothing is written anywhere; the next
---   Neovim starts at `keys.<provider>.active` (or at the default variable).

--- The command source, each point a deliberate choice:
---
--- - **No shell.** `command = { "pass", "show", "anthropic" }` is spawned as an
---   argument vector (`vim.system`), never as a string through `sh -c`/`cmd`,
---   so nothing in the config or in a profile name is ever interpreted by a
---   shell. A string, an empty list or a list with a non-string is refused.
--- - **Asynchronous with a timeout.** `timeout_ms` (default 10000) kills a
---   command that hangs on a prompt; the UI thread is never blocked.
--- - **Cached in memory for the session.** Only the key, only in this module,
---   for `cache_ms` (default: the whole session; at least one second). A failed
---   run is not cached. Concurrent requests share one run.
--- - **Nothing but the key is kept.** stderr is dropped, stdout is reduced to
---   its first non-empty line, and errors and `describe()` carry the reason
---   ("timed out", "exited with code 3") and the executable's file name --
---   never an argument (it may be a secret), never any output.

local read = require("lib.nvim.fs.read")
local util = require("ai.providers.util")

local M = {}

---Profile chosen with `use()`, per provider id. Module state on purpose: it
---must die with the Neovim session.
---@type table<string, string>
local selected = {}

---@type table<string, { stamp: string, value: string|nil }>
local file_cache = {}

local DEFAULT_COMMAND_TIMEOUT_MS = 10000
local MIN_CACHE_MS = 1000

---Cached command keys by `<provider>\0<profile>`; `at` is `vim.uv.now()`.
---@type table<string, { value: string, at: integer }>
local command_cache = {}

---Why the last run of a command source failed (a short reason, no output).
---@type table<string, string>
local command_failure = {}

---Callbacks waiting for a command run that is already under way.
---@type table<string, fun(ok: boolean, err: LibErrorValue|nil)[]>
local inflight = {}

---@param id string provider id
---@return table|nil cfg `config.keys[id]` when it is a table
local function provider_cfg(id)
  local keys = require("ai.config").get().keys
  local entry = type(keys) == "table" and keys[id] or nil
  return type(entry) == "table" and entry or nil
end

---@param id string
---@param name string
---@return table|nil spec
local function profile_spec(id, name)
  local cfg = provider_cfg(id)
  local profiles = cfg and cfg.profiles
  local spec = type(profiles) == "table" and profiles[name] or nil
  return type(spec) == "table" and spec or nil
end

---The profile `config.keys[id].active` asks for. `nil` and `false` mean none;
---anything else is a request for that name, whether or not it is defined.
---@param id string
---@return string|nil
local function configured_active(id)
  local cfg = provider_cfg(id)
  local name = cfg and cfg.active
  if name == nil or name == false then
    return nil
  end
  return tostring(name)
end

---@param id string
---@param name string
---@return string
local function command_key(id, name)
  return id .. "\0" .. name
end

---@param spec table
---@return boolean
local function is_command(spec)
  return type(spec.command) == "table"
end

---The argument vector of a command source when it is usable: a non-empty list
---of strings without NUL. A shell string is refused on purpose.
---@param command any
---@return string[]|nil argv
local function valid_argv(command)
  if type(command) ~= "table" or #command == 0 then
    return nil
  end
  for i = 1, #command do
    local part = command[i]
    if type(part) ~= "string" or part == "" or part:find("\0", 1, true) then
      return nil
    end
  end
  for k in pairs(command) do
    if type(k) ~= "number" then
      return nil
    end
  end
  return command
end

---@param entry { value: string, at: integer }|nil
---@param spec table
---@return boolean
local function cache_fresh(entry, spec)
  if not entry then
    return false
  end
  if type(spec.cache_ms) ~= "number" then
    return true
  end
  return vim.uv.now() - entry.at < math.max(spec.cache_ms, MIN_CACHE_MS)
end

---The cached key of a command profile, `nil` when none was fetched or it expired.
---@param id string
---@param name string
---@param spec table
---@return string|nil
local function cached_command_key(id, name, spec)
  local entry = command_cache[command_key(id, name)]
  return cache_fresh(entry, spec) and entry.value or nil
end

---Profile names of `id`, sorted.
---@param id string
---@return string[]
function M.profiles(id)
  local cfg = provider_cfg(id)
  local names = {}
  if cfg and type(cfg.profiles) == "table" then
    for name, spec in pairs(cfg.profiles) do
      if type(name) == "string" and type(spec) == "table" then
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  return names
end

---Provider ids that have at least one profile configured, or an `active` that
---asks for one (so a broken `active` still shows in `:Ai info`), sorted.
---@return string[]
function M.providers()
  local keys = require("ai.config").get().keys
  local ids = {}
  for id in pairs(type(keys) == "table" and keys or {}) do
    if type(id) == "string" and (#M.profiles(id) > 0 or configured_active(id)) then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

---The profile in force for `id`: the session choice, else the configured
---`active`, else `nil` (= the provider's own environment variable). A session
---choice that is no longer defined is ignored; the configured `active` is not:
---it counts even when it names nothing defined, so `get()` fails closed.
---@param id string
---@return string|nil
function M.active(id)
  local chosen = selected[id]
  if chosen and profile_spec(id, chosen) then
    return chosen
  end
  return configured_active(id)
end

---UTF-16 text (BOM already removed) as ASCII, or `nil` when a unit is outside
---ASCII -- a key never is. By hand and not `vim.iconv`: that one decodes
---big-endian differently per platform.
---@param s string
---@param little_endian boolean
---@return string|nil
local function utf16_to_ascii(s, little_endian)
  local out = {}
  for i = 1, #s - 1, 2 do
    local lo, hi = s:byte(i, i + 1)
    if not little_endian then
      lo, hi = hi, lo
    end
    if hi ~= 0 or lo >= 128 then
      return nil
    end
    out[#out + 1] = string.char(lo)
  end
  return table.concat(out)
end

---The first non-empty line of a key file, trimmed. Windows tools write what a
---plain read would turn into a corrupt key that still looks present: a UTF-8
---BOM, or UTF-16 with a BOM (PowerShell 5.1's `>` and `Out-File`). Both are
---decoded first; a NUL left over means an encoding that was not recognised.
---@param content string
---@return string|nil value
local function first_line(content)
  local bom = content:sub(1, 2)
  if bom == "\255\254" or bom == "\254\255" then
    content = utf16_to_ascii(content:sub(3), bom == "\255\254") or ""
  elseif content:sub(1, 3) == "\239\187\191" then
    content = content:sub(4)
  end
  for line in content:gmatch("[^\r\n]+") do
    -- Not `^%s*(.-)%s*$`: quadratic on a long run of blanks inside the line.
    local trimmed = util.trim(line)
    if trimmed ~= "" then
      return not trimmed:find("\0", 1, true) and trimmed or nil
    end
  end
  return nil
end

---@param path string
---@return string|nil value
local function read_file(path)
  local real = vim.fn.expand(path)
  local stat = vim.uv.fs_stat(real)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local stamp = ("%d:%d"):format(
    stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1e6),
    stat.size
  )
  local cached = file_cache[real]
  if cached and cached.stamp == stamp then
    return cached.value
  end
  local content = read(real)
  if not content then
    -- Not cached: a sharing violation (an editor, antivirus or sync client
    -- holding the file) changes neither mtime nor size, so a cached nil would
    -- outlive the lock until the file is rewritten.
    return nil
  end
  local value = first_line(content)
  file_cache[real] = { stamp = stamp, value = value }
  return value
end

---@param spec table
---@return string|nil value
local function read_source(spec)
  if type(spec.env) == "string" then
    return util.env_value(spec.env)
  end
  if type(spec.file) == "string" then
    return read_file(spec.file)
  end
  return nil
end

---The profile in force for `id` and its spec, when it is a command source.
---@param id string
---@return string|nil name
---@return table|nil spec
local function active_command(id)
  local name = M.active(id)
  local spec = name and profile_spec(id, name)
  if spec and is_command(spec) then
    return name, spec
  end
  return nil, nil
end

---The key a provider should use, before a per-request `api_key`.
---
---With an active profile: that profile's key, or `nil` -- never the default
---variable. Without one: the provider's own variable `default_env`.
---@param id string provider id
---@param default_env string the provider's own variable
---@return string|nil
function M.get(id, default_env)
  local name = M.active(id)
  if not name then
    return util.env_value(default_env)
  end
  local spec = profile_spec(id, name)
  if not spec then
    return nil
  end
  if is_command(spec) then
    -- Never runs the command: only what `fetch()` cached.
    return cached_command_key(id, name, spec)
  end
  return read_source(spec)
end

---True when the profile in force for `id` is a command source. Such a profile
---counts as available without having run (`available()` must stay cheap and
---start nothing); the key is resolved by `fetch()` when a request is made.
---@param id string provider id
---@return boolean
function M.pending(id)
  return active_command(id) ~= nil
end

---True when a request through `id` must run `fetch()` first: a command source
---with no fresh cached key.
---@param id string provider id
---@return boolean
function M.needs_fetch(id)
  local name, spec = active_command(id)
  return name ~= nil and cached_command_key(id, name, spec) == nil
end

---@param id string
---@param name string
---@param reason string
---@return LibErrorValue
local function command_error(id, name, reason)
  return require("lib.lua.error").new(
    "missing_api_key",
    ("%s: key profile '%s': the key command failed (%s)"):format(id, name, reason),
    { profile = name, reason = reason }
  )
end

---Run the active command source of `id` (argument vector, no shell, with a
---timeout), cache the key and call `cb(true)`; on failure `cb(false, err)` with
---a `missing_api_key` error that names the profile and the reason, never the
---output. A fresh cached key calls `cb(true)` at once; a run already under way is
---shared. Without a command source this is `cb(true)` at once too.
---
---`cb` runs on the main loop. The returned function drops the callback (the
---command itself finishes or times out by itself).
---@param id string provider id
---@param cb fun(ok: boolean, err: LibErrorValue|nil)
---@return fun() cancel
function M.fetch(id, cb)
  local name, spec = active_command(id)
  if not name or not spec or cached_command_key(id, name, spec) then
    cb(true)
    return function() end
  end
  local key = command_key(id, name)
  local cancelled = false
  local function once(ok, err)
    if not cancelled then
      cb(ok, err)
    end
  end
  local function cancel()
    cancelled = true
  end
  local waiting = inflight[key]
  if waiting then
    waiting[#waiting + 1] = once
    return cancel
  end
  inflight[key] = { once }

  local function finish(value, reason)
    local waiters = inflight[key] or {}
    inflight[key] = nil
    if value then
      command_cache[key] = { value = value, at = vim.uv.now() }
      command_failure[key] = nil
      for _, waiter in ipairs(waiters) do
        waiter(true)
      end
    else
      command_cache[key] = nil
      command_failure[key] = reason
      for _, waiter in ipairs(waiters) do
        waiter(false, command_error(id, name, reason))
      end
    end
  end

  local function fail_later(reason)
    vim.schedule(function()
      finish(nil, reason)
    end)
    return cancel
  end

  local argv = valid_argv(spec.command)
  if not argv then
    return fail_later("`command` must be a list of strings")
  end
  local cmd = vim.deepcopy(argv)
  if cmd[1]:sub(1, 1) == "~" then
    cmd[1] = vim.fn.expand(cmd[1])
  end
  if vim.fn.executable(cmd[1]) == 0 then
    return fail_later("executable not found")
  end
  local timeout = type(spec.timeout_ms) == "number" and spec.timeout_ms > 0 and spec.timeout_ms
    or DEFAULT_COMMAND_TIMEOUT_MS
  local started = pcall(vim.system, cmd, { text = true, timeout = timeout }, function(res)
    vim.schedule(function()
      if res.code == 124 or res.signal == 15 then
        finish(nil, ("timed out after %d ms"):format(timeout))
      elseif res.code ~= 0 then
        finish(nil, ("exited with code %s"):format(tostring(res.code)))
      else
        local value = first_line(res.stdout or "")
        if value then
          finish(value)
        else
          finish(nil, "printed no key")
        end
      end
    end)
  end)
  if not started then
    return fail_later("could not be started")
  end
  return cancel
end

---Forget the cached keys of command sources (all, or only `only`'s provider).
---@param only? string provider id
---@return nil
function M.forget(only)
  for _, tbl in ipairs({ command_cache, command_failure }) do
    for key in pairs(tbl) do
      if not only or vim.startswith(key, only .. "\0") then
        tbl[key] = nil
      end
    end
  end
end

---True when a key profile is in force for `id` but yields no key -- the state
---in which the provider is unavailable *because of the profile*, and in which
---`ai.providers.resolve` must say so instead of skipping to another provider.
---@param id string provider id
---@return boolean
function M.blocked(id)
  return M.active(id) ~= nil and not M.pending(id) and M.get(id, "") == nil
end

---Whether `name`, which is made of identifier characters only, has the shape of a
---vendor's key: the keys that carry no hyphen. Groq's is `gsk_` and 40 or more
---letters and digits (52 today), Hugging Face's `hf_` and 34, Gemini's `AIza` and
---35, and a bare token of 32 or more letters and digits, mixed-case, with no
---underscore, is what a key looks like when it has no prefix at all. A name that
---is long but has an underscore between its words (`Company_Anthropic_Key_Production_2`)
---is none of these. The price is the same shape written as a name without
---underscores (`CompanyAnthropicKeyProductionAccount2`): it is not echoed either.
---Anthropic's and OpenAI's (`sk-`) have hyphens and never get this far.
---@param name string at most 64 bytes, `[%a_][%w_]*`
---@return boolean
local function key_shaped(name)
  local rest = name:match("^gsk_(%w+)$")
  if rest and #rest >= 40 then
    return true
  end
  rest = name:match("^hf_(%w+)$")
  if rest and #rest >= 34 then
    return true
  end
  if #name >= 39 and name:sub(1, 4) == "AIza" then
    return true
  end
  return #name >= 32
    and name:match("^%w+$") ~= nil
    and name:find("%l") ~= nil
    and name:find("%u") ~= nil
end

---An `env` value is a variable name, i.e. an identifier. Anything else is most
---likely the key itself, pasted where the name belongs. Vendor keys carry
---hyphens (Anthropic, OpenAI), which no identifier has; the ones that have none
---are told by their shape (`key_shaped`). Shape only, so a key that happens to
---look like a plain name still passes -- and so does every legitimate name with
---words in it: a rule written on length, case and digits alone would reject
---`Company_Anthropic_Key_Production_2`.
---@param name string
---@return boolean
local function env_name_ok(name)
  -- Bounded before any pattern runs: no variable name is longer.
  if #name > 64 or not name:match("^[%a_][%w_]*$") then
    return false
  end
  return not key_shaped(name)
end

---Where a profile's key comes from, as text -- the variable name or "file",
---never a path's content or the key.
---@param spec table
---@return string
local function source_kind(spec)
  if type(spec.env) == "string" then
    return env_name_ok(spec.env) and ("env " .. spec.env) or "env <not a variable name>"
  end
  if type(spec.file) == "string" then
    return "file"
  end
  if type(spec.command) == "table" then
    -- The executable's file name only: an argument may itself be a secret.
    local exe = type(spec.command[1]) == "string" and vim.fs.basename(spec.command[1]) or "?"
    return "command " .. exe
  end
  return "no source"
end

---One line about `id`'s key setup, safe to print.
---@param id string
---@return string
function M.describe(id)
  local name = M.active(id)
  if not name then
    return "default variable"
  end
  local spec = profile_spec(id, name)
  if not spec then
    return ("profile %s (not defined, KEY MISSING)"):format(name)
  end
  local state
  if is_command(spec) then
    local failure = command_failure[command_key(id, name)]
    if cached_command_key(id, name, spec) then
      state = "key present"
    elseif failure then
      state = "KEY MISSING: " .. failure
    else
      state = "key not fetched yet"
    end
  else
    state = read_source(spec) and "key present" or "KEY MISSING"
  end
  return ("profile %s (%s, %s)"):format(name, source_kind(spec), state)
end

---Select `name` for the session on every provider that defines it (or only on
---`only`). Returns the provider ids switched.
---@param name string
---@param only? string
---@return string[] switched
function M.use(name, only)
  local switched = {}
  for _, id in ipairs(M.providers()) do
    if (not only or only == id) and profile_spec(id, name) then
      selected[id] = name
      switched[#switched + 1] = id
    end
  end
  return switched
end

---Drop the session choice (all providers, or `only`); the configured `active`
---profile, or the default variable, applies again.
---@param only? string
---@return nil
function M.reset(only)
  if only then
    selected[only] = nil
  else
    selected = {}
  end
end

---What is wrong with a key file, as text without the path or the content, or
---`nil`. A missing or unreadable file is an error of its own (never a silent
---`nil` key); on a POSIX system a file other users can read is one too. Windows
---has no mode bits worth reading, so there only existence and readability count.
---@param path string
---@return string|nil
local function file_problem(path)
  local real = vim.fn.expand(path)
  local stat = vim.uv.fs_stat(real)
  if not stat or stat.type ~= "file" then
    return "does not exist (or is not a regular file)"
  end
  if not vim.uv.fs_access(real, "R") then
    return "is not readable"
  end
  if vim.fn.has("win32") == 0 and stat.mode % 64 ~= 0 then
    return "is readable by group or others -- chmod 600"
  end
  return nil
end

---Problems in `config.keys`, one string each, for `:checkhealth`.
---@return string[]
function M.issues()
  local issues = {}
  local keys = require("ai.config").get().keys
  if keys == nil then
    return issues
  end
  if type(keys) ~= "table" then
    return { "keys: must be a table of provider id -> { active?, profiles }" }
  end
  for id, cfg in pairs(keys) do
    if type(cfg) ~= "table" or type(cfg.profiles) ~= "table" then
      issues[#issues + 1] = ("keys.%s: needs a `profiles` table"):format(tostring(id))
    else
      for name, spec in pairs(cfg.profiles) do
        local path = ("keys.%s.profiles.%s"):format(tostring(id), tostring(name))
        local is_tbl = type(spec) == "table"
        local has_env, has_file, has_cmd =
          is_tbl and spec.env, is_tbl and spec.file, is_tbl and spec.command
        local count = (has_env and 1 or 0) + (has_file and 1 or 0) + (has_cmd and 1 or 0)
        if not is_tbl or count ~= 1 then
          issues[#issues + 1] = path
            .. ": needs exactly one of `env` (variable name), `file` (path) or `command` (argument list)"
        elseif has_cmd then
          local argv = valid_argv(has_cmd)
          if not argv then
            issues[#issues + 1] = path
              .. '.command: must be a list of strings, e.g. { "pass", "show", "name" } (no shell string)'
          elseif
            vim.fn.executable(argv[1]:sub(1, 1) == "~" and vim.fn.expand(argv[1]) or argv[1]) == 0
          then
            issues[#issues + 1] = path
              .. (".command: executable '%s' not found"):format(vim.fs.basename(argv[1]))
          end
          for _, field in ipairs({ "timeout_ms", "cache_ms" }) do
            if spec[field] ~= nil and (type(spec[field]) ~= "number" or spec[field] <= 0) then
              issues[#issues + 1] = ("%s.%s: must be a positive number of milliseconds"):format(
                path,
                field
              )
            end
          end
        elseif has_env and type(has_env) ~= "string" or has_file and type(has_file) ~= "string" then
          issues[#issues + 1] = path .. ": `env`/`file` must be a string"
        elseif has_env and not env_name_ok(has_env) then
          -- Never the value: it may well be a key.
          issues[#issues + 1] = path
            .. ".env: not a variable name -- the key goes into that variable (or a file), not here"
        elseif has_file then
          local problem = file_problem(has_file)
          if problem then
            issues[#issues + 1] = path .. ".file: " .. problem
          end
        end
      end
      if
        cfg.active ~= nil
        and cfg.active ~= false
        and not (type(cfg.active) == "string" and cfg.profiles[cfg.active])
      then
        issues[#issues + 1] = ("keys.%s.active: %q is not one of its profiles -- requests fail until it is fixed"):format(
          tostring(id),
          tostring(cfg.active)
        )
      end
    end
  end
  return issues
end

return M
