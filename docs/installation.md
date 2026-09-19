# Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "StefanBartl/ai.nvim",
  dependencies = { "StefanBartl/lib.nvim", "StefanBartl/ui.nvim" },
  cmd = "Ai",
  keys = { { "<leader>a", mode = { "n", "v" } } },
  config = function()
    require("ai").setup()
  end,
},
```

`cmd`/`keys` are lazy-load triggers -- `ai.nvim` does nothing until `:Ai` is
run or one of the default `<leader>a*` keymaps is pressed. Pass options to
`setup()` to change any default (see [configuration.md](configuration.md)).
