# readtrail.nvim

Leave numbered notes while reading code. Export them across files, in order, for an agent to review.

```ts
// @trace[001] Does this just build the parser?
// Where does execution happen?
const parser = compile(grammar)
```

With [vim.pack](https://neovim.io/doc/user/pack/) (Neovim 0.12+):

```lua
vim.pack.add({ 'https://github.com/saiashirwad/readtrail.nvim' })

-- Suggested mapping (none are set by default)
vim.keymap.set('n', '<leader>ta', '<cmd>TraceAdd<cr>', { desc = 'Add reading trace' })

-- Optional configuration
local readtrail = require('readtrail')
readtrail.context_lines = 4
readtrail.prompt = [[Read my notes in order and check them against the code.
Focus on questions I have not answered myself.]]
```

- `:TraceAdd`: add a note. Enter continues it.
- `:TraceExport`: view notes with file paths, line numbers, and code excerpts.
- `:TraceCopy`: copy the export.
- `:TraceClear`: remove notes and reset numbering. Save the affected buffers afterward.

Keep a blank line between your notes and existing source comments.
