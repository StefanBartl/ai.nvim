# Attachments

A request can carry binary payloads alongside its prompt — a rasterized page,
a whole PDF — through `Ai.Request.attachments`.

```lua
local attachments = require("ai.attachments")

local page, err = attachments.from_file("/tmp/invoice-page-1.png")
if not page then
  error(err)
end

require("ai").ask({
  prompt = "Extract every table on this page as Markdown. No preamble.",
  provider = "claude",
  attachments = { page },
}, function(ok, res)
  if ok then
    vim.print(res.text)
  end
end)
```

`ai.stream()` takes the same field.

## What an attachment is

```lua
---@class Ai.Attachment
---@field kind "image"|"document"
---@field media_type string   -- "image/png", "application/pdf", ...
---@field data string         -- base64, no `data:` prefix, no line breaks
---@field name? string        -- optional, used only in error messages
```

Three things: bytes, what they are, what they are for. Every provider's wire
format carries exactly those and differs only in how it spells them — so the
neutral shape is the request's, and the spelling is each backend's.

## Building one

| Function | Use |
| -------- | --- |
| `attachments.from_file(path, opts?)` | Read, size-check and base64 a file. `opts.media_type` overrides the extension guess; `opts.kind` overrides the media-type guess. |
| `attachments.from_bytes(data, media_type, opts?)` | Same, for bytes you already have (a rasterizer's stdout, say). |
| `attachments.media_type_for(path)` | The media type an extension implies, or `nil`. |
| `attachments.kind_for(media_type)` | `"document"` for `application/pdf`, `"image"` for any `image/*`, `nil` otherwise. |
| `attachments.validate(list)` | Structural check; returns an error message or `nil`. |

Both builders return `attachment, nil` or `nil, err_message` — they never
raise. Recognized extensions are `.png`, `.jpg`/`.jpeg`, `.gif`, `.webp` and
`.pdf`; anything else needs an explicit `opts.media_type`.

`attachments.MAX_BYTES` (32 MB by default) is a local ceiling, not a provider
limit — the file is read into a Lua string and grown by a third again by the
base64 encode, on the main loop, so an oversized input has to fail as a
message rather than as an editor that stops responding.

## What each provider can carry

| Provider | `image` | `document` | How it goes on the wire |
| -------- | ------- | ---------- | ----------------------- |
| `claude` | yes | yes | `image`/`document` content blocks with a base64 `source` |
| `gemini` | yes | yes | `inline_data` parts with a `mime_type` |
| `openai` | yes | no | `image_url` content part whose `url` is a `data:` URI |
| `ollama` | yes | no | bare `images` array of base64 strings on the message |
| `loomai` | no | no | — |

`:checkhealth ai` prints the same table for the providers available on this
machine.

**A provider that cannot carry an attachment fails the request** with
`err.kind == "invalid_request"`, before anything is sent. It is never dropped
silently: a prompt that says "extract the tables from this page", sent with
the page removed, does not fail — it answers confidently about nothing.

Two consequences worth knowing:

- **Only `claude` and `gemini` take a PDF whole.** For the others, the caller
  rasterizes the pages first (`pdftoppm`, say) and sends images. How many
  pages and at what DPI is a decision for whoever has the PDF, not for a
  transport backend guessing on their behalf.
- **A capability is about the API, not the model.** `capabilities.vision` on
  `ollama` says the chat endpoint has an `images` field. `llava` reads it;
  `llama3.2` accepts it and ignores it. Model choice stays the caller's.

## Large requests

A base64-encoded PDF is routinely megabytes, and `lib.nvim.net.curl` sends a
request body as an element of curl's argv — where Windows caps the whole
command line at 32 767 characters and Linux' `ARG_MAX` is commonly ~2 MB.

`ai.providers.transport` therefore writes any body over
`MAX_INLINE_BODY_BYTES` (8 KB) to a temp file created `0600` and has curl read
it back with `--data-binary @file`, deleting it once the request finishes.
Nothing about this is attachment-specific — a long enough
`context = { cwd = true }` sweep can reach the same ceiling — and nothing
about it needs configuring.

## Per-request credentials

`Ai.Request.api_key` and `Ai.Request.host` override a provider's own env-var
lookup for one request. They exist for an embedding plugin that already holds
the value in its own config (`pdfport.nvim`'s `claude_api_key`,
`ollama_host`) and must not have to write it into the user's environment to
reach ai.nvim.

`api_key` counts towards the provider's `available()` too — otherwise
resolution would reject the provider before `ask()` ever saw the key. **Set
`provider` explicitly alongside it**: a key belongs to one specific API, and
under `provider = "auto"` it would be offered to whichever provider resolves
first.

```lua
require("ai").ask({
  prompt = "...",
  provider = "ollama",
  host = "http://192.168.1.4:11434",
}, cb)
```

Neither changes how the value is transmitted: an `api_key` still goes through
curl's `-K` stdin config path, never argv.
