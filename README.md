> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# ai.nvim

```
   █████╗ ██╗
  ██╔══██╗██║
  ███████║██║
  ██╔══██║██║
  ██║  ██║██║
  ╚═╝  ╚═╝╚═╝
                                               .nvim
```

> Pairs well with [pdfport.nvim](https://github.com/StefanBartl/pdfport.nvim) --
> its `claude`/`ollama` extraction backends are the two real bugs (broken JSON
> escaping, an API key visible in the process list) that this plugin exists to
> fix at the transport layer, once and for every future caller.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-beta-orange)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)
[![CI](https://github.com/StefanBartl/ai.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/StefanBartl/ai.nvim/actions/workflows/ci.yml)

A provider-agnostic ask/stream layer for talking to an AI from inside Neovim --
context assembly (buffer/selection/diagnostics), a streaming answer panel, and
one `:Ai` command, instead of every plugin hand-rolling its own curl calls.

---

## Documentation

Start at [docs/README.md](docs/README.md) -- what's where, and which question
each page answers.

**The Basics**

- [Requirements](docs/requirements.md) -- Neovim version, required plugins and CLI tools.
- [Installation](docs/installation.md) -- plugin managers and load-trigger variants.
- [Quickstart](docs/quickstart.md) -- the first thing to run after installing.

**Configuration**

- [All options](docs/configuration.md) -- every `setup()` option and its default.
- [Commands](docs/commands.md) / [Bindings cheatsheet](docs/BINDINGS.md)

**The Rest**

- [What it does and what not](docs/scope.md) -- the boundary with `loomAI`.
- [Why it does it that way](docs/architecture.md)
- [Health check](docs/health.md) -- what `:checkhealth ai` reports, line by line.
- [Feedback](https://github.com/StefanBartl/ai.nvim/issues)

`:help ai` is the same reference inside the editor.

---

## License

ai.nvim is released under the [MIT License](https://opensource.org/licenses/MIT) -- see [LICENSE](LICENSE).
