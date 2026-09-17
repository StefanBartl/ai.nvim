---@module 'ai.attachments'
--- Builds and validates `Ai.Attachment` values -- the binary payloads that
--- ride along with a prompt (a page image, a PDF sent whole).
---
--- This exists so that "read a file, base64 it, name what it is" is written
--- once. Every caller that wanted an image in a prompt otherwise reimplements
--- the same four steps, and gets the same four things subtly wrong:
--- shelling out to a `base64` binary that is GNU-only and absent on Windows,
--- reading the whole file onto the main loop with no size ceiling, guessing
--- the media type from the extension in a fifth slightly different way, and
--- discovering only from the API's own 400 that the provider never supported
--- that payload in the first place.
---
--- Usage: >lua
---   local attachments = require("ai.attachments")
---
---   local att, err = attachments.from_file("/tmp/page-1.png")
---   if not att then error(err) end
---
---   require("ai").ask({
---     prompt = "Extract every table on this page as Markdown.",
---     provider = "claude",
---     attachments = { att },
---   }, function(ok, res) ... end)
--- <

require("ai.@types")

local lib_error = require("lib.lua.error")

local M = {}

local uv = vim.uv or vim.loop

---Refuse to base64 anything larger than this. Not a provider limit (each has
---its own, lower one) but a local one: the file is read into a Lua string and
---then grown by a third again by the encode, on the main loop, before any
---provider gets a say. A 300 MB PDF must fail as a message, not as an editor
---that stops responding and then an API rejection minutes later.
---@type integer
M.MAX_BYTES = 32 * 1024 * 1024

---@internal
---Extension -> IANA media type for the formats the built-in providers
---actually accept. Deliberately a short allow-list rather than a general
---mime-type table: an extension missing from here is a *question*
---("does any provider take this?"), and a caller that knows the answer can
---still pass `opts.media_type` explicitly.
---@type table<string, string>
local MEDIA_TYPES = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  pdf = "application/pdf",
}

---The media type `path`'s extension implies, or `nil` if it implies none.
---@param path string
---@return string|nil
function M.media_type_for(path)
  local ext = path:match("%.([%a%d]+)$")
  return ext and MEDIA_TYPES[ext:lower()] or nil
end

---The `Ai.Attachment` kind `media_type` belongs to, or `nil` for a media
---type no provider has a slot for.
---@param media_type string
---@return "image"|"document"|nil
function M.kind_for(media_type)
  if media_type == "application/pdf" then
    return "document"
  end
  if media_type:match("^image/") then
    return "image"
  end
  return nil
end

---Build an attachment from bytes already in memory.
---@param data string raw (not base64) bytes
---@param media_type string IANA media type, e.g. `"image/png"`
---@param opts? { kind?: "image"|"document", name?: string }
---@return Ai.Attachment|nil attachment
---@return string|nil err
function M.from_bytes(data, media_type, opts)
  opts = opts or {}
  if type(data) ~= "string" then
    return nil, "attachment data must be a string of bytes"
  end
  if type(media_type) ~= "string" or media_type == "" then
    return nil, "attachment needs a media type"
  end
  if #data > M.MAX_BYTES then
    return nil, string.format("attachment is %d bytes, over the %d byte limit", #data, M.MAX_BYTES)
  end

  local kind = opts.kind or M.kind_for(media_type)
  if not kind then
    return nil, string.format("no attachment kind for media type %q", media_type)
  end

  -- `vim.base64.encode` is Neovim 0.10+, already this plugin's minimum.
  local ok, encoded = pcall(vim.base64.encode, data)
  if not ok then
    return nil, "base64 encoding failed: " .. tostring(encoded)
  end

  return { kind = kind, media_type = media_type, data = encoded, name = opts.name }, nil
end

---Build an attachment by reading `path`.
---
---The read is one blocking `vim.uv` call on a local file rather than an
---async chain: the encode that follows it has to happen on the main loop
---anyway, so going async here would move the pause rather than remove it.
---`MAX_BYTES` is checked against the `stat` *before* the read, so an
---oversized file is rejected without ever being loaded.
---@param path string
---@param opts? { kind?: "image"|"document", media_type?: string, name?: string }
---@return Ai.Attachment|nil attachment
---@return string|nil err
function M.from_file(path, opts)
  opts = opts or {}
  local media_type = opts.media_type or M.media_type_for(path)
  if not media_type then
    return nil, string.format("cannot tell the media type of %q -- pass opts.media_type", path)
  end

  local fd, open_err = uv.fs_open(path, "r", 438) -- 0666, subject to umask
  if not fd then
    return nil, "cannot open " .. path .. ": " .. tostring(open_err)
  end

  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, "cannot stat " .. path
  end
  if stat.size > M.MAX_BYTES then
    uv.fs_close(fd)
    return nil,
      string.format("%s is %d bytes, over the %d byte limit", path, stat.size, M.MAX_BYTES)
  end

  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then
    return nil, "cannot read " .. path
  end

  return M.from_bytes(data, media_type, {
    kind = opts.kind,
    name = opts.name or vim.fs.basename(path),
  })
end

---Structural check on a request's attachment list.
---@param list Ai.Attachment[]|nil
---@return string|nil err `nil` when every entry is well-formed (an absent or empty list included)
function M.validate(list)
  if list == nil then
    return nil
  end
  if type(list) ~= "table" then
    return "attachments must be a list"
  end
  for i, att in ipairs(list) do
    if type(att) ~= "table" then
      return string.format("attachment #%d is not a table", i)
    end
    if att.kind ~= "image" and att.kind ~= "document" then
      return string.format("attachment #%d has an unknown kind %q", i, tostring(att.kind))
    end
    if type(att.media_type) ~= "string" or att.media_type == "" then
      return string.format("attachment #%d has no media type", i)
    end
    if type(att.data) ~= "string" or att.data == "" then
      return string.format("attachment #%d has no data", i)
    end
  end
  return nil
end

---@internal
---@param att Ai.Attachment
---@param index integer
---@return string
local function describe(att, index)
  return att.name and string.format("%q", att.name) or ("#" .. tostring(index))
end

---The error a provider must fail a request with before sending it, or `nil`
---if it can carry every attachment in `list`.
---
---Refusing here rather than dropping the block is the whole point: a prompt
---that says "extract the tables from this page" with the page silently
---removed does not fail, it answers confidently about nothing. A provider
---that cannot carry the payload has to say so.
---@param id string provider id, e.g. `"ollama"`
---@param capabilities Ai.ProviderCapabilities|nil
---@param list Ai.Attachment[]|nil
---@return LibErrorValue|nil
function M.unsupported(id, capabilities, list)
  local invalid = M.validate(list)
  if invalid then
    return lib_error.new("invalid_request", id .. ": " .. invalid, { attachments = list })
  end
  if list == nil or #list == 0 then
    return nil
  end

  capabilities = capabilities or {}
  for i, att in ipairs(list) do
    local supported = (att.kind == "image" and capabilities.vision)
      or (att.kind == "document" and capabilities.documents)
    if not supported then
      return lib_error.new(
        "invalid_request",
        string.format(
          "%s: cannot send attachment %s -- this provider's API takes no %s payload",
          id,
          describe(att, i),
          att.kind
        ),
        { provider = id, kind = att.kind, media_type = att.media_type }
      )
    end
  end
  return nil
end

return M
