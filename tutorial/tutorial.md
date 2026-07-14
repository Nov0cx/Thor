# Thor - Interactive Tutorial

Learn Thor by doing. Each challenge below asks you to press one of your
real shortcuts (read live from `settings/keybinds.json`). Do it and this
document ticks the challenge off and moves to the next - you can perform
the editor actions right here in this file. Below the challenges is a full
reference explaining every action.

## Challenges  [##########]  10/10

- [x] Open the command palette  (`Ctrl+.`)
- [x] Quick-open the file finder  (`Ctrl+Tab`)
- [x] Save the current file  (`Ctrl+S`)
- [x] Toggle the file explorer  (`Ctrl+B`)
- [x] Open find  (`Ctrl+F`)
- [x] Select the whole file  (`Ctrl+A`)
- [x] Select the word under the caret  (`Ctrl+D`)
- [x] Duplicate the current line  (`Shift+Alt+Down`)
- [x] Move the current line down  (`Alt+Down`)
- [x] Toggle a line comment  (`Ctrl+K`)

*** Complete! You performed all 10 shortcuts. Well done! ***

## Every action explained

Rebind anything in `settings/keybinds.json`, then reopen this tutorial
from **Help -> Tutorial** to see the shortcuts update.

### Files & app

| Shortcut | Action |
| --- | --- |
| `Ctrl+.` | Open the command palette to search and run any action |
| `Ctrl+Tab` | Quick-open: jump straight to fuzzy file search |
| `Ctrl+S` | Save the current file (autosave also runs shortly after edits) |
| `Ctrl+W` | Close the current tab |
| `Ctrl+PgDn` | Switch to the next tab |
| `Ctrl+PgUp` | Switch to the previous tab |
| `Ctrl+E` | Flip to the previously active file (press again to flip back) |
| `Ctrl+G` | Go to line (opens the palette in line-number mode) |
| `Ctrl+B` | Show or hide the file explorer panel |
| `Ctrl+T` | Show or hide the console panel |
| `Ctrl+Shift+E` | Move keyboard focus to the editor |
| `Ctrl+Shift+B` | Focus the explorer (opens it if collapsed) |
| `Ctrl+Shift+T` | Focus the console (opens it if collapsed) |

### Search

| Shortcut | Action |
| --- | --- |
| `Ctrl+F` | Find text in the current file |
| `Ctrl+R` | Find and replace text in the current file |

### Explorer

When the explorer has focus it can be driven from the keyboard.

| Shortcut | Action |
| --- | --- |
| `Up / Down` | Move the selection |
| `Right` | Expand a folder, or step into its first child |
| `Left` | Collapse a folder, or step out to its parent |
| `Enter` | Open the selected file / toggle the selected folder |
| `Del` | Delete the selected file (after a confirmation dialog) |

### Clipboard

| Shortcut | Action |
| --- | --- |
| `Ctrl+C` | Copy the selection (no selection: copy the whole line) |
| `Ctrl+X` | Cut the selection (no selection: cut the whole line) |
| `Ctrl+V` | Paste from the clipboard |

### Movement

Add Shift to any movement to extend the selection.

| Shortcut | Action |
| --- | --- |
| `Ctrl+Left` | Jump one word left |
| `Ctrl+Right` | Jump one word right |
| `Alt+Left` | Go to the start of the line |
| `Alt+Right` | Go to the end of the line |
| `Home` | Go to the start of the line |
| `End` | Go to the end of the line |
| `Ctrl+Home` | Go to the start of the file |
| `Ctrl+End` | Go to the end of the file |
| `Ctrl+Up` | Go to the start of the file |
| `Ctrl+Down` | Go to the end of the file |
| `PgUp` | Move up one page |
| `PgDn` | Move down one page |
| `Ctrl+P` | Jump to the matching / enclosing bracket or quote |
| `Ctrl+Shift+P` | Select everything between the brackets / quotes (excludes them) |
| `Ctrl+Shift+\` | Select to the matching bracket / quote (includes them) |

### Selection & multi-cursor

| Shortcut | Action |
| --- | --- |
| `Ctrl+A` | Select the whole file |
| `Ctrl+D` | Select the word; press again to add a cursor at the next occurrence |
| `Ctrl+L` | Select the line; press again to extend by a line |
| `Ctrl+Alt+Up` | Add a cursor on the line above |
| `Ctrl+Alt+Down` | Add a cursor on the line below |
| `Esc` | Collapse to a single cursor and clear the selection |

### Editing

| Shortcut | Action |
| --- | --- |
| `Ctrl+Z` | Undo the last change |
| `Ctrl+Shift+Z` | Redo the last undone change |
| `Ctrl+Y` | Redo the last undone change |
| `Ctrl+Backspace` | Delete the word to the left |
| `Ctrl+Del` | Delete the word to the right |
| `Ctrl+Shift+K` | Delete the current line |
| `Alt+Up` | Move the current line up |
| `Alt+Down` | Move the current line down |
| `Shift+Alt+Up` | Duplicate the current line upward |
| `Shift+Alt+Down` | Duplicate the current line downward |
| `Ctrl+Enter` | Insert a new line below |
| `Ctrl+Shift+Enter` | Insert a new line above |
| `Ctrl+J` | Join the line below onto the current one |
| `Tab` | Indent the selected lines |
| `Shift+Tab` | Outdent the selected lines |
| `Ctrl+K` | Toggle a line comment (uses the language's marker) |
| `Ctrl+Shift+W` | Trim trailing whitespace |
| `Alt+U` | Uppercase the selection (or the word under the caret) |
| `Alt+L` | Lowercase the selection (or the word under the caret) |
| `Alt+C` | Capitalize the selection (or the word under the caret) |

### View

| Shortcut | Action |
| --- | --- |
| `Ctrl++` | Zoom the editor font in |
| `Ctrl+-` | Zoom the editor font out |
| `Ctrl+Scroll` | Zoom the editor font with the scroll wheel |
| `Ctrl+Shift+J` | Recenter the view on the caret (repeat cycles center / top / bottom) |
| `F12` | Toggle borderless fullscreen |

---

Typing an opening bracket or quote auto-inserts its closing pair; selecting
text and typing a bracket wraps the selection. Two or more word characters
pop up an autocompletion list (Up/Down to choose, Tab or Enter to accept,
Esc to dismiss). Comment markers live in `settings/comments.json`; tab
width, font size and autosave delay in `settings/settings.json`.
