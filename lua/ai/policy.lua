---@module 'ai.policy'
--- Which providers this machine may use at all -- the allow-list behind
--- `config.policy.allowed`.
---
--- Why it lives here and not in a consumer: every call site that sends text
--- to a provider (`:Ai`, the quick-action keymaps, inline completion, and any
--- plugin that goes through `require("ai").ask()`/`.stream()`, such as
--- `pdfport.nvim`) ends up in `ai.providers.resolve`, which asks this module.
--- A list kept by one consumer only would protect that consumer's commands and
--- leave `<leader>as` on a file full of customer data wide open. The rule is
--- per machine (an employer's allow-list), so it is plain config: empty, the
--- default, means "no restriction" and the plugin behaves exactly as before.
--- A malformed list is not an empty one, and neither is a `policy` with a key
--- this plugin does not know (`alowed`), nor an option named almost like it at
--- the top level (`polcy`, `policies`): `ai.config` replaces it with a marker
--- no provider matches, so a typo refuses everything instead of lifting the rule.
---
--- Deliberately small: a list, a membership test, and an explicit way to step
--- outside it that has to be asked for (`Ai.Request.allow_unlisted` per
--- request, or `grant()` for the session after `:Ai provider <other>` was
--- confirmed -- for that provider named explicitly, never for `"auto"`).
--- Nothing here persists, and nothing here validates ids against the provider
--- registry -- an id may be listed before its provider exists.

local M = {}

---Ids that were confirmed for this session although they are not on the
---allow-list. Module state on purpose: it must die with the Neovim session.
---@type table<string, true>
local granted = {}

---Ids confirmed for this session to receive *document text* in bulk requests
---(`ai.bulk`), although they are not on the allow-list. A separate set on
---purpose: a `:Ai provider <id>` confirmation was about chat with a selection,
---not about a whole document going out in many unattended requests.
---@type table<string, true>
local bulk_granted = {}

---The allow-list, or `nil` when the machine is unrestricted.
---@return string[]|nil
function M.allowed()
  local cfg = require("ai.config").get()
  local list = cfg.policy and cfg.policy.allowed
  if type(list) ~= "table" or #list == 0 then
    return nil
  end
  return vim.deepcopy(list)
end

---@return boolean
function M.restricted()
  return M.allowed() ~= nil
end

---Whether `id` may answer a request.
---@param id string
---@param req? Ai.Request  a request carrying `allow_unlisted = true` passes
---@return boolean
function M.is_allowed(id, req)
  if req and req.allow_unlisted == true then
    return true
  end
  if granted[id] then
    return true
  end
  local list = M.allowed()
  if not list then
    return true
  end
  return vim.tbl_contains(list, id)
end

---Whether `id` is on the allow-list itself (a session grant or a per-request
---`allow_unlisted` does not count). `true` when the machine is unrestricted.
---@param id string
---@return boolean
function M.is_listed(id)
  local list = M.allowed()
  if not list then
    return true
  end
  return vim.tbl_contains(list, id)
end

---`order` reduced to the listed entries, in the same order -- what
---`provider = "auto"` may walk. A session grant does not widen it: it answers
---for the one provider that `:Ai provider <id>` named, not for `"auto"`. Only
---a request that says `allow_unlisted` passes every entry.
---@param order string[]
---@param req? Ai.Request
---@return string[]
function M.filter(order, req)
  local open = req ~= nil and req.allow_unlisted == true
  local out = {}
  for _, id in ipairs(order or {}) do
    if open or M.is_listed(id) then
      out[#out + 1] = id
    end
  end
  return out
end

---Allow `id` for the rest of this session although it is not listed. The
---caller is responsible for having asked the user.
---@param id string
---@return nil
function M.grant(id)
  granted[id] = true
end

---Forget every session grant.
---@return nil
function M.reset()
  granted = {}
  bulk_granted = {}
end

---Allow `id` for bulk requests (`req.bulk`) for the rest of this session
---although it is not listed. The caller is responsible for having asked the
---user, and for saying that document text leaves the machine.
---@param id string
---@return nil
function M.grant_bulk(id)
  bulk_granted[id] = true
end

---Whether `id` may receive a bulk request. Stricter than `is_allowed`: the
---plain `allow_unlisted` of a request and a `:Ai provider` session grant do
---not count -- only the allow-list itself, `grant_bulk(id)`, or the explicit
---`bulk.allow_unlisted = true` of this one request.
---@param id string
---@param bulk? Ai.BulkOptions
---@return boolean
function M.is_bulk_allowed(id, bulk)
  if bulk and bulk.allow_unlisted == true then
    return true
  end
  return bulk_granted[id] == true or M.is_listed(id)
end

---Ids confirmed for bulk requests this session that are not on the allow-list, sorted.
---@return string[]
function M.bulk_granted()
  local out = {}
  for id in pairs(bulk_granted) do
    if not M.is_listed(id) then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

---The error for a bulk request that named a provider outside the allow-list.
---@param id string
---@return LibErrorValue
function M.bulk_refusal(id)
  return require("lib.lua.error").new(
    "provider_resolution",
    string.format(
      "ai: bulk requests send document text unattended; provider '%s' is not on this "
        .. "machine's allow-list (%s). Confirm it once per session with "
        .. "require('ai.policy').grant_bulk('%s'), or set bulk.allow_unlisted = true "
        .. "after asking the user",
      id,
      M.describe(),
      id
    ),
    { id = id, reason = "policy", bulk = true, allowed = M.allowed() }
  )
end

---Ids granted for this session that are not on the allow-list, sorted.
---@return string[]
function M.granted()
  local out = {}
  for id in pairs(granted) do
    if not M.is_listed(id) then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

---One-line wording for an error or a notification.
---@return string
function M.describe()
  local list = M.allowed()
  if not list then
    return "no restriction"
  end
  return "allowed: " .. table.concat(list, ", ")
end

return M
