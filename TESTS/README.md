# ai.nvim tests

A busted-style suite (`describe`/`it`/`before_each`, busted assertions) run by
[testing.nvim](https://github.com/StefanBartl/testing.nvim) -- this repo's own
established convention (see `.github/workflows/ci.yml`'s `test` job,
`.testing.lua` and `TESTS/minimal_init.lua`), not the framework-free
`H.eq`/`H.ok` harness some sibling repos in this collection use instead.

## Running locally

`testing.nvim` and `lib.nvim` are required. Each is looked up in four places,
in this order (a missing one is a fatal error naming all four):
`$TESTING_NVIM_DIR` / `$LIB_NVIM_DIR`, `.deps/<name>`, a sibling checkout next
to this repo, `stdpath('data')/lazy/<name>`. Then:

```bash
scripts/test.sh                        # every spec under TESTS/ai
scripts/test.sh --file sse             # spec files whose name contains "sse"
scripts/test.sh --json ir.json         # also write the machine-readable result
```

which is exactly:

```bash
nvim -n -i NONE --headless -u NONE -l /path/to/testing.nvim/scripts/testing.lua run .
```

`data.nvim` and `gitsuite.nvim` are optional soft dependencies: when a
sibling or `.deps/` checkout exists, `TESTS/minimal_init.lua` puts it on the
runtimepath and the specs that need it run; without it they skip themselves.

Each spec file runs in its own `nvim --headless` subprocess (`isolated =
"file"` in `.testing.lua`), so `package.loaded` never leaks between files -- only between
`it()` blocks *within* the same file, which is why almost every spec here
resets the module(s) under test in `before_each`/`after_each` (see the module
doc at the top of `providers_claude_spec.lua`, the template every other
`providers_*_spec.lua` follows).

`ui.nvim` (`ui.kit`) is deliberately **not** added to the rtp here: no spec
touches `ai.ui.panel`/`ai.bindings.actions`/`ai.bindings.keymaps` end-to-end
through a real `ui.kit.popup`/`ui.kit.surface.open` call -- see "Skipped"
below for why, and `panel_spec.lua`'s own module doc for how its logic is
tested instead (stub the seam, not the whole dependency).

The two documentation specs are the odd ones out: they test the *documentation*
(REL-08), not the code. Both read the docs at run time and diff them against the
code, and both share their helpers (`docs/*.md` blocks and tables, running a
documented snippet, listing the real keymaps) in `TESTS/docs_support.lua`. Each
spec puts `TESTS/?.lua` on `package.path` itself (so it also runs when started
without `TESTS/minimal_init.lua`); the module is not a spec (only `*_spec.lua`
files are), so the runner never runs it. Its state fixture (`isolate_install()`, which
puts keymaps, autocmd groups and `:Ai` back after each case) has a spec of its own,
`docs_support_spec.lua`: a restored key must keep its `replace_keycodes`, or Nvim's
own insert `<Tab>` would insert the text "<Tab>".

`docs_examples_spec.lua` -- `docs/*.md`. It extracts code blocks and tables and
executes them or diffs them against the code. Covered: the `configuration.md`
`setup()` / completion / `register()` blocks (the full `setup()` block must
equal `DEFAULTS`), the `attachments.md` `from_file()` / `host` examples (run
through the real `ai.ask` with every built-in provider stubbed), the
`Ai.Attachment` `@field` list (name, optional flag, type) and the provider
capability table, the `installation.md` lazy.nvim spec and `dependencies` (both
directions), the `:Ai` subcommand names (both directions against `commands.md`
and the `BINDINGS.md` Usercmds table), the `BINDINGS.md` keymap tables (mode
and default lhs, both directions against the lib.nvim keymap registry, plus a
registry-independent scan that every global keymap mapped under the prefix,
and every key in `DEFAULTS.completion.keymap`, is documented -- by raw lhs in
any of the modes n/x/s/o/i/c/t/l) and the `architecture.md` curl extension.
**Not** cross-checked: prose, the other table columns (descriptions, the
autocmds table), the remaining docs' tables, the root `README.md`, and keymaps
the scan cannot see: buffer-local ones, and a key mapped outside the registry
that is neither under the prefix nor in `DEFAULTS.completion.keymap`.

`vimdoc_spec.lua` -- `doc/ai.txt`, the `:help ai` file, which is maintained by
hand and was found well behind `docs/*.md` once (2026-10-01). Sections are found
by their help tag, not their number, so adding or renumbering a section breaks
nothing. It runs a real `:helptags` on a scratch copy (a duplicate or malformed
tag fails) and checks that every `|link|` resolves (to this file, or to Neovim's
own help where that is installed); that CONTENTS matches the section headings;
that the config block equals `DEFAULTS`, its provider-id comment lists the
built-in providers and `provider_order` and the `idle_ms` default are the real
ones; that the `:Ai` subcommand tags, the keymap tables (mode, lhs and action id,
against the `BINDINGS.md` tables), the provider list, the attachment capability
list, the recognized extensions and the inline-body threshold match the code; that
the `ai.ask()` request fields, the stream handlers and the context flags (in the
section and in the `assemble()` entry) match `@types`/`DEFAULTS`; that the
documented error kinds are *exactly* the `lib_error.new("<kind>", ...)` calls in
real code (comment lines never count); that the minimum Neovim version agrees with
`requirements.md` and the tuple `health.lua` hands to `version_ok()`; and, per
provider, that the environment variables and the default base URL in its
requirements bullet are the ones its own source reads. Every UPPER_CASE_WITH_
UNDERSCORE token in the help must be an environment variable a provider reads
(Ollama's own `OLLAMA_HOST`, named as *not* read, is the one exception): a new
such token in the help needs a matching `util.env_value()` call or an entry in the
spec's exception.

**Not** checked: prose and descriptions -- anything that is not a name, a default
or a list. The extractors fail loudly instead of going vacuous when the layout
they read changes. The spec was verified by deliberately breaking the help and the
code (28 cases: 26 must turn red, and inserting a numbered section or switching the
file to CRLF must stay green); the first version missed an error kind that only a
*comment* still mentioned, per-provider swaps of keys and ports, and a
suffix-dependent environment-variable check, which an independent review found and
the cases above now pin. A load error in a spec or in `docs_support.lua` makes
`scripts/test.sh <file>` exit with 2 immediately instead of idling.

## Round 1 (2026-09-18): first full audit

This repo had never had a full coverage round in the cross-repo campaign --
only a rough file-count proxy (25 `lua/**` files vs. 11 spec files) marked it
"probably fine" without reading a single spec body. This round actually read
every `lua/ai/**` file against what its spec (if any) asserts.

**Before:** 132 tests, 11 spec files.
**After:** 225 tests, 18 spec files (+93 tests, +7 files).

What was already solid, confirmed by reading the spec bodies (not just their
names): `attachments.lua`, `config/init.lua`, `context/init.lua` +
`context/diagnostics.lua`, `completion/prompt.lua`, the provider registry
(`providers/init.lua`), `providers/transport.lua`, `providers/util.lua`,
`providers/sse.lua`, and two of the five built-in providers
(`providers/claude.lua`, `providers/gemini.lua`) -- all real,
assertion-based specs already, not load-time smoke tests.

Gaps closed:
- **`providers/ollama.lua`, `providers/openai.lua`, `providers/loomai.lua`
  had no spec file at all.** Three of the five built-in providers --
  `build_body()`'s per-API wire shape, `ask`/`stream` response parsing, error
  mapping (`api_error`/`invalid_response`/`missing_api_key`/`timeout`),
  attachment rejection, host resolution -- were completely untested, despite
  `claude.lua`/`gemini.lua` having thorough coverage of exactly this shape of
  logic. New `providers_ollama_spec.lua` (19 tests), `providers_openai_spec.lua`
  (15), `providers_loomai_spec.lua` (14), all following the existing
  `providers_claude_spec.lua` convention (`package.loaded["lib.nvim.net.curl"]`
  stubbed before each fresh `require`).
- **`ui/panel.lua` had zero coverage.** The streaming-answer panel's real
  state machine -- multi-line delta accumulation across `append()` calls,
  idempotent `cancel()`, snapshot-based `cancel_all()` (so cancelling one
  panel mid-iteration can't skip the next) -- none of it needs a live
  `ui.kit` surface to test, only the shape it hands back. New `panel_spec.lua`
  (13 tests) stubs `ui.kit.surface.open`/`lib.nvim.progress.create`/
  `lib.nvim.safe_api.safe_call` at the seam and exercises the real logic
  behind them.
- **`ui/ghost.lua` had zero coverage**, despite being pure `vim.api`
  extmarks (no `ui.kit` involved at all -- `completion_auto_trigger_spec.lua`'s
  own module doc already says as much). New `ghost_spec.lua` (8 tests):
  show/clear/current, multi-buffer replacement, and `clear()`'s safety when
  the shown suggestion's buffer was since deleted (`pcall`-guarded in the
  source; pinned here rather than assumed).
- **`completion/context.lua`'s `extract()` had zero coverage.** Cursor-relative
  prefix/suffix extraction, `max_lines` bounding, first/last-line edges,
  `opts.bufnr` vs. the current window's cursor. New `completion_context_spec.lua`
  (8 tests).
- **`completion/init.lua`'s `trigger()` success path and `accept()` had zero
  coverage.** `completion_auto_trigger_spec.lua` (pre-existing) only exercises
  the debounce/autocmd wiring around auto-trigger mode -- its own `ask` stub
  always fails, so `ghost.show()` never actually ran, and none of
  `trigger()`'s four stale-response guards (superseded generation, buffer
  deleted, changedtick mismatch, cursor moved) or `accept()`'s single-line
  vs. multi-line insertion math were exercised anywhere. New
  `completion_spec.lua` (16 tests).

No bugs found. Specifically checked for the four bug families this campaign
keeps finding elsewhere:
- **health.lua calling into a missing dependency inside its own "missing"
  branch.** Not present. Every `lib_health.check_require(...)` in
  `health.lua` only reports; the one real risk -- `require("ai.providers")`
  and `providers.load_builtin()` running unconditionally after the lib.nvim
  checks -- is safe because `load_builtin()` only builds lazy proxies
  (`providers/init.lua`'s `make_lazy`), and each proxy's own `pcall(require,
  entry.module)` already turns a missing backend module into "not available"
  rather than a raised error; `M.available()` is called through
  `type(p.available) == "function" and p.available()`, so a proxy whose
  module failed to load returns `nil`/`false` there too, never a crash. The
  module's own top-level `require("lib.nvim.health")` is an unconditional
  hard dependency, but that matches this repo's own documented stance
  (`ai/init.lua`'s module doc: "Depends on lib.nvim (deliberate hard
  dependency, like lsp.nvim/dap.nvim/documentation.nvim in this collection)")
  -- not the "warn, then crash into the same thing" pattern this check is
  for.
- **An augroup created without `clear = true`, doubling handlers on a second
  `setup()`.** Not present. Both augroups in this repo
  (`bindings/autocmds.lua`'s `autocmd.group("ai_nvim", true)` and
  `completion/init.lua`'s `vim.api.nvim_create_augroup("AiCompletion", {
  clear = true })`) pass it explicitly.
- **Byte-offset vs. display-column vs. character-index confusion.**
  Not found. `completion/context.lua`, `completion/init.lua`, and
  `ui/ghost.lua` all consistently use `nvim_win_get_cursor`'s byte column
  end-to-end -- verified concretely, not just by inspection, while writing
  `completion_spec.lua`'s `accept()` cursor-position tests: `accept()`'s
  `end_col` formula (`#lines > 1 and #lines[#lines] or (suggestion.col +
  #lines[1])`) is correct for both the single-line and multi-line insert
  cases (checked against `nvim_buf_set_text`'s actual result, not just read).
  One test-writing pitfall worth recording for future rounds: normal-mode
  `nvim_win_set_cursor`/`nvim_win_get_cursor` clamps to a line's last real
  character column, which makes reading the cursor back after `accept()`
  unreliable for the end-of-line case in a headless (normal-mode) test --
  `accept()`'s real caller is an insert-mode keymap (`ai.bindings.keymaps`,
  `mode = "i"`), where no such clamping applies. `completion_spec.lua` spies
  on `vim.api.nvim_win_set_cursor` instead of reading the position back, to
  test what `accept()` itself computed rather than Neovim's mode-dependent
  display of it.
- **Windows path/separator bugs** (`/` vs `\` string-equality, or a drive
  letter's colon breaking a naive `string:find(":", ...)` parse). Not
  applicable: this repo does no manual path-string parsing at all.
  `attachments.lua`'s `from_file()` goes through `vim.uv.fs_open`/`fs_fstat`/
  `fs_read` (paths pass straight to libuv, no separator logic of this repo's
  own) and `vim.fs.basename()` for the display name; `providers/transport.lua`'s
  temp-body-file path comes from `vim.fn.tempname()`. No `string:find(":",
  ...)`-style parsing anywhere in `lua/ai/**`. Verified empirically, not just
  by inspection: the full suite (including the new specs, which write/read
  real files via `vim.uv` in `attachments_spec.lua`) was run twice on this
  Windows machine, both runs 225/225 green.

Sibling-checkout assumptions: `lib.nvim` is genuinely available as a sibling
checkout on this machine (`E:\repos\lib.nvim`), and `TESTS/minimal_init.lua`
already finds it correctly via its sibling-checkout search path -- nothing
here needed adjusting.

## Writing a new spec

- One spec file per module (`ai/providers/ollama.lua` ->
  `TESTS/ai/providers_ollama_spec.lua`), following `providers_claude_spec.lua`
  as the reference for the stub-then-require dance.
- `lib.nvim.net.curl` (and anything else a module under test captures via
  `require(...)` at its own top level) must be stubbed via `package.loaded`
  **before** a fresh `require()` of the module under test -- Lua binds a
  `require()` result to a local upvalue at load time, so patching a table
  field on an already-loaded module does nothing. Drop
  `package.loaded["ai.providers.<name>"]` **and**
  `package.loaded["ai.providers.transport"]` in `before_each` (transport
  captures `curl` as its own upvalue too), and never call the same
  `ask`/`stream` twice within one `it()` against two different stubs -- the
  second call silently reuses the first's stub via that same stale-upvalue
  mechanism (hit and fixed once while writing `providers_ollama_spec.lua`
  this round).
- `vim.system`/`vim.fn.executable`/other Neovim globals (not `require()`
  results) can be monkeypatched directly, no `package.loaded` needed --
  `providers_ollama_spec.lua`'s `available` tests do this for
  `vim.fn.executable`, resetting `ai.providers.util` first so its own
  per-name executable cache doesn't leak a stale, unrelated real-PATH probe
  across tests.
- A module with no live-backend dependency (`ai.ui.ghost`,
  `ai.completion.context`) needs no stubbing at all -- a real scratch buffer
  and the real `vim.api` are enough, and faster/more honest than mocking.

## Coverage

Covered: `attachments.lua`, `completion/context.lua`, `completion/init.lua`,
`completion/prompt.lua`, `config/init.lua`, `context/init.lua`,
`context/diagnostics.lua`, `providers/init.lua` (registry), all five
built-in providers (`claude`, `gemini`, `loomai`, `ollama`, `openai`),
`providers/transport.lua`, `providers/util.lua`, `providers/sse.lua`,
`ui/panel.lua`, `ui/ghost.lua`.

Skipped, with reasons:
- `@types/init.lua` -- `---@meta` type annotations, no runtime code.
- `plugin/ai.lua` -- a single early-return guard (`vim.g.loaded_ai`), no
  branch worth a spec.
- `health.lua` -- `:checkhealth ai`'s own report is thin, mostly-linear
  formatting glue around `vim.health.*`/`lib.nvim.health` calls (already a
  hard dependency this repo assumes, see "No bugs found" above); carefully
  read for the "warn then crash into the missing thing" pattern (not
  present, see above) but not given its own spec file this round -- nothing
  in it is business logic in the sense the rest of this list is.
- `ui/badge.lua` -- one function that only shapes a `kit.popup({type="note",
  ...})` call (default `title`/`timeout_ms`, nothing else); testing it would
  mean either a live `ui.kit` popup or asserting on a stub that mirrors the
  function's own three lines back at it.
- `bindings/actions.lua`, `bindings/keymaps.lua`, `bindings/usrcmds.lua` --
  wiring code whose real behavior is "call `ui.kit.popup`/`ai.ui.panel`/
  `ai.ui.badge` with these arguments" or "register this route/keymap with
  `lib.nvim.bindings.usercmd.composer`/`lib.nvim.bindings.keymap`"; the interesting
  logic (does an empty prompt fall through to `prompt_for_text`, does
  `explain_badge` skip an empty context block) is a handful of one-line
  branches directly adjacent to a `ui.kit.popup` call that needs a live
  interactive backend (real typed/submitted input, the same category as
  telescope/fzf-lua/snacks actually rendering) to exercise end-to-end.
  Consistent with `TESTS/minimal_init.lua`'s own existing note on why
  `ui.nvim` isn't added to the rtp here.
- The real network call inside `curl.fetch_json`/`curl.fetch_stream` itself
  (an actual request to Anthropic/OpenAI/Google/a local Ollama or loomAI
  server) -- real external process, stubbed at the `lib.nvim.net.curl` seam
  in every provider spec instead, per this campaign's standing rule for
  "real network requests to an actual AI provider."
