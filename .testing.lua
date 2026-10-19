-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "ai",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = "auto",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  deps = { "lib.nvim" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file
  -- (nothing leaks from one file into the next).
  isolated = "file",
  -- "c" = child started from a -c command (v:vim_did_enter is 0, <cword> works),
  -- "l" = `nvim -l`.
  host = "c",
  -- Environment variables the specs read; a child editor inherits an allowlist only (never secrets).
  env_allow = { "CLAUDE_CODE_DISABLE_ATTACHMENTS" },
  -- Guards (testing.nvim docs/GUARDS.md). The suite passes cleanly for these, so a new finding fails.
  guards = {
    fs = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    state = "error",
    -- The spawn/network net: every external process must be listed in guard_allow.
    process_net = "error",
  },
  guard_allow = {
    -- providers_claude_cli_spec and providers_copilot_cli_spec start a headless nvim as a fake CLI.
    -- "definitely-not-a-claude-binary-xyz" is a deliberate negative probe ("reports a command that cannot be started").
    spawn = { "nvim", "definitely-not-a-claude-binary-xyz", "definitely-not-a-copilot-binary-xyz" },
    fs = {},
    network = {},
  },
  -- The runner counts which commands, keymaps and autocommands the specs exercise (docs/SURFACE.md of testing.nvim);
  -- `scripts/test.sh surface` compares that with surface.baseline.json (a regression gate, not a percentage).
  surface = { track = true },
  -- gated: a failed conformance check makes `scripts/test.sh conformance` exit 1 (docs/CONFORMANCE.md of testing.nvim)
  conformance = {
    gate = true,
    waivers = {
      {
        check = "K6",
        level = "error",
        text = "ui.kit",
        reason = "ui.nvim is deliberately not on the suite's runtimepath (TESTS/README.md): :checkhealth reports ui.kit as missing there",
        expires = "2027-04-14",
      },
      {
        check = "K12",
        level = "warn",
        text = "Ai.quick",
        reason = "the command counterpart is `:Ai stream` (prompts for text, streams the answer); the <leader>as keymap only adds the configured context assembly around it, which has no command-line spelling",
        expires = "2027-04-14",
      },
      {
        check = "K12",
        level = "warn",
        text = "Ai/completion.",
        reason = "insert-mode inline-completion actions (accept, dismiss, trigger) act on the live ghost text of the current insert session; an ex command would leave insert mode and has no meaning there",
        expires = "2027-04-14",
      },
    },
  },
}
