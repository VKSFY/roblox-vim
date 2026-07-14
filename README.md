# roblox-vim

Modal Vim editor for Roblox Lua.

## Features

- Normal, insert, visual, and visual-line modes
- Motions: hjkl, w/b (word forward/back), 0/$ (line start/end), gg/G (file start/end)
- Operators: d (delete), y (yank), p (paste)
- Undo/redo (Ctrl+Z, Ctrl+R)
- Search (/ for forward, n/N to jump)
- Command mode (:w, :q, :wq, :q!)

## Architecture

Character input uses a transparent TextBox character stream (not KeyCodes) to handle shift-dependent keys correctly. Cursor placement measures actual text width, not column count, so tabs render at the correct position.

## Usage

```lua
local vim = Vim.new(parent)
vim:open("filename.lua", content, function(text)
    -- Save callback: return (success, message)
    return saveFile(text)
end)
```

## License

MIT
