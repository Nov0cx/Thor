# Thor - Interactive Tutorial

Two parts, both live. **Part 1** drills the shortcuts you have bound, read
straight from `settings/keybinds.json`. **Part 2** repairs a broken Odin file
in the tab next door. This page rewrites itself while you work, so put it
beside the playground (`F1` splits the editor) and
watch the boxes tick.

## Part 1 - Shortcuts  [..........]  0/10

Press the chord. The document notices and moves to the next one - the key
still does its real job while it does.

- [ ] **>> Open the command palette -- press `Ctrl+.` now**
- [ ] Quick-open the file finder  (`Ctrl+Tab`)
- [ ] Save the current file  (`Ctrl+S`)
- [ ] Toggle the file explorer  (`Ctrl+B`)
- [ ] Open find  (`Ctrl+F`)
- [ ] Select the whole file  (`Ctrl+A`)
- [ ] Select the word under the caret  (`Ctrl+D`)
- [ ] Duplicate the current line  (`Shift+Alt+Down`)
- [ ] Move the current line down  (`Alt+Down`)
- [ ] Toggle a line comment  (`Ctrl+K`)

## Part 2 - Repair `playground.odin`  [........]  0/8

The other tab holds a small Odin file that does not parse, does not compile
and was indented in the dark. Every defect below is one editor action away.
The list re-reads the buffer several times a second, so a fix ticks off as
you make it - no save needed, and the explanation below moves on.

Saving the file runs `odin check` over its package: errors come back as a
red underline and a dot in the gutter, and hovering one shows what the
compiler said.

1. [ ] **Close the call, so the file parses at all**  <- you are here
2. [ ] Import the package `fmt` comes from
3. [ ] Remove the import nothing uses
4. [ ] Declare `total` before assigning to it
5. [ ] Handle every `Shape` in the switch
6. [ ] Put the body of `report` at the right depth
7. [ ] Strip the trailing whitespace
8. [ ] Line the three constants up

### Now: Close the call, so the file parses at all

tree-sitter gives up at line 40 -- a `)` is missing here:

```odin

    fmt.printfln("%s x%d", it.name, it.count

```

The cause is line 40: the `(` after `printfln` is never closed, so every line after it is swallowed by an expression that never ends.

Nothing else works until this is fixed. The analyzer reads the same tree the highlighter does, so hover, go-to-definition and code actions all stay silent on a file that does not parse -- and `odin check` reports only the syntax error.

Type the missing `)`. Thor closes a bracket for you as you type the opening one, and `Ctrl+P` jumps between a pair when you want to see which one is unbalanced.

## Every action explained

Rebind anything in `settings/keybinds.json` (or in the settings window), then
reopen this tutorial from **Help -> Tutorial** to see the shortcuts update.
Anything listed as `unbound` has no chord yet and is still reachable by name
from the command palette.

### Files & app

| Shortcut | Action |
| --- | --- |
| `Ctrl+.` | Open the command palette to search and run any action |
| `Ctrl+Tab` | Quick-open: jump straight to fuzzy file search |
| `Ctrl+O` | Open a file with the system dialog |
| `Ctrl+Alt+O` | Open a folder as the workspace |
| `Ctrl+Shift+Alt+O` | Open a folder in a second window (a second process) |
| `unbound` | Create a file beside the selection |
| `unbound` | Create a folder beside the selection |
| `Ctrl+S` | Save the current file (autosave also runs shortly after edits) |
| `unbound` | Save every modified file |
| `F2` | Rename the current file |
| `Ctrl+W` | Close the current tab |
| `unbound` | Close every tab |
| `Ctrl+PgDn` | Switch to the next tab |
| `Ctrl+PgUp` | Switch to the previous tab |
| `Ctrl+E` | Flip to the previously active file (press again to flip back) |
| `unbound` | Copy the current file's path to the clipboard |
| `unbound` | Show the current file in the system file manager |
| `unbound` | Write this file with LF line endings |
| `unbound` | Write this file with CRLF line endings |
| `Ctrl+G` | Go to line (opens the palette in line-number mode) |
| `Ctrl+B` | Show or hide the file explorer panel |
| `Ctrl+T` | Show or hide the console panel |
| `Ctrl+Shift+E` | Move keyboard focus to the editor |
| `Ctrl+Shift+B` | Focus the explorer (opens it if collapsed) |
| `Ctrl+Shift+T` | Focus the console (opens it if collapsed) |

### Code intelligence

Served in-client by Thor's own analyzer, not by a language server.

| Shortcut | Action |
| --- | --- |
| `Alt+Enter` | Go to the definition of the symbol at the caret (Ctrl+Click does the same) |
| `Ctrl+Alt+Left` | Go back to where the last jump started |
| `Ctrl+Alt+Right` | Go forward again after jumping back |
| `F10` | List every use of the symbol at the caret |
| `Ctrl+Shift+Space` | Show the signature of the call the caret sits in |
| `Ctrl+Shift+U` | Offer the fixes that apply at the caret (missing import, unused import, declare a name, fill switch cases) |
| `Ctrl+R` | Rename the symbol under the caret, or find and replace when there is none |
| `Ctrl+Shift+O` | Jump to a symbol declared in this file |
| `Ctrl+Q` | Jump to a symbol declared anywhere in the workspace |
| `F3` | Show the documentation of the package at the caret |

### Search

| Shortcut | Action |
| --- | --- |
| `Ctrl+F` | Find text in the current file |
| `Ctrl+R` | Rename the symbol under the caret, or find and replace when there is none |

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
| `Ctrl+Shift+W` | Trim trailing whitespace on every line |
| `Ctrl+Shift+A` | Align the selected lines on a character you pick (`:`, `=`, ...) |
| `Alt+U` | Uppercase the selection (or the word under the caret) |
| `Alt+L` | Lowercase the selection (or the word under the caret) |
| `Alt+C` | Capitalize the selection (or the word under the caret) |

### Folding

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+,` | Fold or unfold the block at the caret |
| `unbound` | Fold every foldable block |
| `unbound` | Unfold everything |

### View

| Shortcut | Action |
| --- | --- |
| `Ctrl++` | Zoom the editor font in |
| `Ctrl+-` | Zoom the editor font out |
| `unbound` | Reset the zoom |
| `Ctrl+Scroll` | Zoom the editor font with the scroll wheel |
| `F1` | Split the editor in two panes (and back) |
| `unbound` | Wrap long lines instead of scrolling sideways |
| `F4` | Render the active Markdown file instead of its source |
| `Ctrl+Shift+J` | Recenter the view on the caret (repeat cycles center / top / bottom) |
| `unbound` | Maximize or restore the window |
| `F12` | Toggle borderless fullscreen |

### Tasks

Named shell commands from the workspace's `.thor/tasks.json`, run in the console.

| Shortcut | Action |
| --- | --- |
| `F9` | Run the task picked in the titlebar |
| `unbound` | Pick a task and run it |
| `unbound` | Add a task |
| `unbound` | Remove a task |
| `unbound` | Edit `.thor/tasks.json` directly |

### Settings & preferences

| Shortcut | Action |
| --- | --- |
| `Ctrl+,` | Open the settings window |
| `unbound` | Edit `settings/settings.json` as text |
| `unbound` | Edit `settings/keybinds.json` as text |
| `unbound` | Edit `settings/comments.json` (the comment marker per language) |
| `unbound` | Reload every settings file from disk |
| `unbound` | Switch to another theme |
| `unbound` | Create a theme to edit |
| `unbound` | Switch the editor font |
| `unbound` | Register a font file with Thor |
| `unbound` | Switch the UI icon pack |
| `unbound` | Switch the file-type icon pack |
| `unbound` | Create a `.thor/` directory in the workspace |
| `unbound` | Reopen this tutorial (also Help -> Tutorial) |

---

Typing an opening bracket or quote auto-inserts its closing pair; selecting
text and typing a bracket wraps the selection. Two or more word characters
pop up an autocompletion list (Up/Down to choose, Tab or Enter to accept,
Esc to dismiss). Comment markers live in `settings/comments.json`; tab
width, font size and autosave delay in `settings/settings.json`.
