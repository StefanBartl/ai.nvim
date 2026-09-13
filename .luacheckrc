-- luacheck configuration for ai.nvim
std = "lua51"
cache = true

-- Neovim injects `vim` as a read-only global.
read_globals = { "vim" }

-- Line length is handled by stylua, not luacheck.
max_line_length = false

ignore = {
  "212/_.*", -- unused argument whose name starts with underscore
  "212/self", -- unused self
  "122", -- setting a read-only field of a global (e.g. vim.*): common in Neovim
}

-- plenary.nvim's busted-style harness (describe/it/...) and luassert's
-- runtime-extended `assert` (assert.is_true, assert.are.same, ...) are only
-- present under TESTS/, so scope them there rather than loosening checks
-- plugin-wide.
files["TESTS/"] = {
  globals = {
    "vim",
    "assert",
    "describe",
    "it",
    "before_each",
    "after_each",
    "pending",
  },
}
