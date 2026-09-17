-- `ai.attachments` is pure apart from `from_file`'s single filesystem read,
-- so most of this exercises the module directly. `from_file` gets a real
-- temp file rather than a stubbed `vim.uv`: the thing worth testing there is
-- that the bytes survive the round trip through `vim.base64.encode`, and a
-- stub that hands back a canned string would test nothing but the stub.
describe("ai.attachments", function()
  local attachments = require("ai.attachments")

  describe("media_type_for", function()
    it("maps the extensions the built-in providers accept", function()
      assert.are.equal("image/png", attachments.media_type_for("/tmp/page.png"))
      assert.are.equal("image/jpeg", attachments.media_type_for("/tmp/scan.jpg"))
      assert.are.equal("image/jpeg", attachments.media_type_for("/tmp/scan.jpeg"))
      assert.are.equal("application/pdf", attachments.media_type_for("C:\\docs\\report.pdf"))
    end)

    it("is case-insensitive about the extension", function()
      assert.are.equal("application/pdf", attachments.media_type_for("/tmp/REPORT.PDF"))
    end)

    it("returns nil for an extension no provider has a slot for", function()
      assert.is_nil(attachments.media_type_for("/tmp/notes.txt"))
      assert.is_nil(attachments.media_type_for("/tmp/no-extension"))
    end)
  end)

  describe("kind_for", function()
    it("calls a PDF a document and any image/* an image", function()
      assert.are.equal("document", attachments.kind_for("application/pdf"))
      assert.are.equal("image", attachments.kind_for("image/png"))
      assert.are.equal("image", attachments.kind_for("image/heic"))
    end)

    it("returns nil for anything else", function()
      assert.is_nil(attachments.kind_for("text/plain"))
    end)
  end)

  describe("from_bytes", function()
    it("base64-encodes and infers the kind", function()
      local att = attachments.from_bytes("hello", "image/png")
      assert.are.equal("image", att.kind)
      assert.are.equal("image/png", att.media_type)
      assert.are.equal(vim.base64.encode("hello"), att.data)
    end)

    it("honours an explicit kind over the inferred one", function()
      local att = attachments.from_bytes("x", "application/pdf", { kind = "image" })
      assert.are.equal("image", att.kind)
    end)

    it("rejects a media type nothing can carry", function()
      local att, err = attachments.from_bytes("x", "text/plain")
      assert.is_nil(att)
      assert.is_true(err:find("text/plain", 1, true) ~= nil)
    end)

    it("rejects bytes over MAX_BYTES rather than encoding them", function()
      local original = attachments.MAX_BYTES
      attachments.MAX_BYTES = 4
      local att, err = attachments.from_bytes("too long", "image/png")
      attachments.MAX_BYTES = original
      assert.is_nil(att)
      assert.is_true(err:find("limit", 1, true) ~= nil)
    end)
  end)

  describe("from_file", function()
    local path

    before_each(function()
      path = vim.fn.tempname() .. ".png"
      local f = assert(io.open(path, "wb"))
      -- Deliberately includes a NUL and a byte above 0x7f: a base64 helper
      -- that went through a text-mode read or a C-string would lose both.
      f:write("\137PNG\r\n\26\n\0\255binary")
      f:close()
    end)

    after_each(function()
      os.remove(path)
    end)

    it("reads, encodes and names the file", function()
      local att = attachments.from_file(path)
      assert.are.equal("image", att.kind)
      assert.are.equal("image/png", att.media_type)
      assert.are.equal(vim.base64.encode("\137PNG\r\n\26\n\0\255binary"), att.data)
      assert.are.equal(vim.fs.basename(path), att.name)
    end)

    it("fails with a message, not an error, for a missing file", function()
      local att, err = attachments.from_file(path .. "-gone.png")
      assert.is_nil(att)
      assert.is_true(err:find("cannot open", 1, true) ~= nil)
    end)

    it("needs an explicit media type when the extension does not imply one", function()
      local unknown = vim.fn.tempname() .. ".bin"
      local f = assert(io.open(unknown, "wb"))
      f:write("data")
      f:close()

      local att, err = attachments.from_file(unknown)
      assert.is_nil(att)
      assert.is_true(err:find("opts.media_type", 1, true) ~= nil)

      local explicit = attachments.from_file(unknown, { media_type = "image/png" })
      assert.are.equal("image", explicit.kind)
      os.remove(unknown)
    end)

    it("rejects an oversized file without reading it", function()
      local original = attachments.MAX_BYTES
      attachments.MAX_BYTES = 2
      local att, err = attachments.from_file(path)
      attachments.MAX_BYTES = original
      assert.is_nil(att)
      assert.is_true(err:find("limit", 1, true) ~= nil)
    end)
  end)

  describe("validate", function()
    it("accepts an absent or empty list", function()
      assert.is_nil(attachments.validate(nil))
      assert.is_nil(attachments.validate({}))
    end)

    it("rejects an unknown kind", function()
      local err = attachments.validate({ { kind = "audio", media_type = "audio/wav", data = "x" } })
      assert.is_true(err:find("unknown kind", 1, true) ~= nil)
    end)

    it("rejects an entry with no data", function()
      local err = attachments.validate({ { kind = "image", media_type = "image/png", data = "" } })
      assert.is_true(err:find("no data", 1, true) ~= nil)
    end)
  end)

  describe("unsupported", function()
    local image = { kind = "image", media_type = "image/png", data = "x" }
    local document =
      { kind = "document", media_type = "application/pdf", data = "x", name = "r.pdf" }

    it("returns nil when there is nothing to send", function()
      assert.is_nil(attachments.unsupported("loomai", { vision = false }, nil))
      assert.is_nil(attachments.unsupported("loomai", { vision = false }, {}))
    end)

    it("passes an image through to a vision-capable provider", function()
      assert.is_nil(attachments.unsupported("ollama", { vision = true }, { image }))
    end)

    it("refuses a document the provider's API has no slot for", function()
      local err = attachments.unsupported(
        "ollama",
        { vision = true, documents = false },
        { document }
      )
      assert.are.equal("invalid_request", err.kind)
      assert.is_true(err.message:find("document", 1, true) ~= nil)
      assert.are.equal("ollama", err.data.provider)
    end)

    it("names the attachment by file name when it has one", function()
      local err = attachments.unsupported("loomai", {}, { document })
      assert.is_true(err.message:find("r.pdf", 1, true) ~= nil)
    end)

    it("falls back to the index when the attachment has no name", function()
      local err = attachments.unsupported("loomai", {}, { image })
      assert.is_true(err.message:find("#1", 1, true) ~= nil)
    end)

    it("reports a malformed entry as invalid_request too", function()
      local err = attachments.unsupported("claude", { vision = true }, { { kind = "image" } })
      assert.are.equal("invalid_request", err.kind)
      assert.is_true(err.message:find("media type", 1, true) ~= nil)
    end)

    it("treats a missing capabilities table as no support at all", function()
      local err = attachments.unsupported("custom", nil, { image })
      assert.are.equal("invalid_request", err.kind)
    end)
  end)
end)
