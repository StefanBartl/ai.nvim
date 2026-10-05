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
---   other account's key.
--- - **The key is never shown.** `describe()`/`info` print the profile name
---   and the kind of source (`env NAME`, `file`), never the value.
--- - **Sources are `env` (a variable name) and `file` (first non-empty line).**
---   Both are read synchronously and are cheap, so `available()` stays cheap;
---   a command or a password manager is a later, asynchronous source and is
---   not offered here. A file is re-read when its mtime or size changes, so
---   replacing the file takes effect without a restart.
--- - **The switch is session-only.** Nothing is written anywhere; the next
---   Neovim starts at `keys.<provider>.active` (or at the default variable).

local util = require("ai.providers.util")

local M = {}

---Profile chosen with `use()`, per provider id. Module state on purpose: it
---must die with the Neovim session.
---@type table<string, string>
local selected = {}

---@type table<string, { stamp: string, value: string|nil }>
local file_cache = {}

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

---Provider ids that have at least one profile configured, sorted.
---@return string[]
function M.providers()
  local keys = require("ai.config").get().keys
  local ids = {}
  for id in pairs(type(keys) == "table" and keys or {}) do
    if type(id) == "string" and #M.profiles(id) > 0 then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

---The profile in force for `id`: the session choice, else the configured
---`active`, else `nil` (= the provider's own environment variable). A name
---that is no longer defined is ignored.
---@param id string
---@return string|nil
function M.active(id)
  local chosen = selected[id]
  if chosen and profile_spec(id, chosen) then
    return chosen
  end
  local cfg = provider_cfg(id)
  local name = cfg and cfg.active
  if type(name) == "string" and profile_spec(id, name) then
    return name
  end
  return nil
end

---@param path string
---@return string|nil value
local function read_file(path)
  local real = vim.fn.expand(path)
  local stat = vim.uv.fs_stat(real)
  if not stat then
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
  local value
  local fh = io.open(real, "rb")
  if fh then
    for line in fh:lines() do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        value = trimmed
        break
      end
    end
    fh:close()
  end
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
  return read_source(profile_spec(id, name) --[[@as table]])
end

---Where a profile's key comes from, as text -- the variable name or "file",
---never a path's content or the key.
---@param spec table
---@return string
local function source_kind(spec)
  if type(spec.env) == "string" then
    return "env " .. spec.env
  end
  if type(spec.file) == "string" then
    return "file"
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
  local spec = profile_spec(id, name) --[[@as table]]
  local state = read_source(spec) and "key present" or "KEY MISSING"
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
        local has_env, has_file =
          type(spec) == "table" and spec.env, type(spec) == "table" and spec.file
        if type(spec) ~= "table" or (has_env and has_file) or not (has_env or has_file) then
          issues[#issues + 1] = path
            .. ": needs exactly one of `env` (variable name) or `file` (path)"
        elseif has_env and type(has_env) ~= "string" or has_file and type(has_file) ~= "string" then
          issues[#issues + 1] = path .. ": `env`/`file` must be a string"
        end
      end
      if cfg.active ~= nil and not (type(cfg.active) == "string" and cfg.profiles[cfg.active]) then
        issues[#issues + 1] = ("keys.%s.active: %q is not one of its profiles"):format(
          tostring(id),
          tostring(cfg.active)
        )
      end
    end
  end
  return issues
end

return M
