# Keybindings

Letter keys follow the active keyboard layout (QWERTZ etc.); punctuation
bindings are physical key positions, noted where they differ.

## Files & app

| Binding | Action |
| --- | --- |
| ctrl + o | open a file from anywhere (shell picker) |
| ctrl + alt + o | open a folder as the workspace (asks: this window or a new one) |
| ctrl + alt + shift + o | open a folder in a new window |
| ctrl + s | save file (autosave also runs 1.5s after the last edit) |
| ctrl + w | close tab |
| ctrl + page down / page up | next / previous tab |
| ctrl + b | toggle explorer panel |
| ctrl + t | toggle the console panel (a real shell — see Terminal below) |
| ctrl + shift + e | focus the editor |
| ctrl + shift + b | focus the explorer (opens it if collapsed) |
| ctrl + shift + t | focus the terminal / console (opens it if collapsed) |
| ctrl + . | open the command palette |
| ctrl + tab | quick open (jump straight to file search) |
| ctrl + e | flip to the previously active file (press again to flip back) |
| ctrl + g | go to line (opens the palette in line-number mode) |
| alt + enter (or ctrl + click) | go to definition of the symbol under the caret |
| ctrl + hover | show the declaration of the symbol under the mouse |
| ctrl + shift + u | code actions: the fixes available at the caret, in a picker |
| ctrl + f | find |
| ctrl + r | find & replace |

## Explorer

When the explorer has focus (e.g. via ctrl + shift + b) it can be driven from
the keyboard:

| Binding | Action |
| --- | --- |
| up / down | move the selection |
| right | expand a folder, or step into its first child |
| left | collapse a folder, or step out to its parent |
| enter | open the selected file / toggle the selected folder |
| delete | delete the selected file (after a confirmation dialog) |

In find/replace: enter / shift+enter jump to next / previous match, tab
switches between the find and replace fields, escape closes.

## Clipboard

| Binding | Action |
| --- | --- |
| ctrl + c | copy selection (no selection: copy whole line) |
| ctrl + x | cut selection (no selection: cut whole line) |
| ctrl + v | paste |

## Movement

| Binding | Action |
| --- | --- |
| ctrl + left / right | jump word left / right |
| alt + left / right | start / end of line |
| home / end | start / end of line |
| ctrl + home / end | start / end of file |
| ctrl + up / down | start / end of file |
| alt + number | jump n lines down |
| alt + shift + number | jump n lines up |
| page up / page down | move 8 lines |
| ctrl + p | jump to matching / enclosing bracket or quote (works from inside a pair) |
| ctrl + shift + p | select everything between the brackets / quotes (excludes them) |
| ctrl + shift + # (ctrl + shift + \ on US) | select to matching bracket / quote (includes them) |

Bracket motions match `()`, `[]`, `{}`; quote motions match `"`, `'` and `` ` ``
(paired left-to-right on the caret's line).

Add `shift` to any movement to extend the selection.

## Selection & multi-cursor

| Binding | Action |
| --- | --- |
| ctrl + a | select all |
| ctrl + d | select word; press again: add cursor at next occurrence |
| ctrl + l | select line; press again: extend one line |
| ctrl + alt + up / down | add cursor above / below |
| escape | collapse to one cursor, clear selection |

## Editing

| Binding | Action |
| --- | --- |
| ctrl + z / ctrl + shift + z | undo / redo |
| ctrl + y | redo |
| ctrl + backspace / delete | delete word left / right |
| ctrl + shift + k | delete line |
| ctrl + j | join the line below onto the current one (selection joins all covered lines) |
| alt + up / down | move line up / down |
| shift + alt + up / down | duplicate line up / down |
| ctrl + enter / ctrl + shift + enter | insert line below / above |
| tab / shift + tab (with selection) | indent / outdent lines |
| ctrl + k | toggle line comment (per-language marker) |
| alt + u / l / c | uppercase / lowercase / capitalize the selection (or the word under the caret) |
| ctrl + shift + w | trim trailing whitespace |
| ctrl + shift + a | align selected lines on a character (prompts for the char, e.g. `=`) |
| enter | new line, keeping indent (extra level after an opening bracket) |

Typing `{` at the end of a line opens a three-line block, placing the caret on
an indented middle line:

```
foo {
    <caret>
}
```

Typing `(`, `[`, `{`, `"`, `'` or `` ` `` auto-inserts the closing pair with the
cursor between them; typing over the closing character steps past it, and
backspace on an empty pair deletes both. Selecting text and typing a bracket or
quote wraps the selection.

## View

| Binding | Action |
| --- | --- |
| ctrl + scroll wheel | zoom editor font |
| ctrl + numpad + / numpad - | zoom editor font |
| ctrl + shift + j | recenter the view on the caret (repeat cycles center / top / bottom) |
| f4 | toggle the rendered markdown preview (markdown files only) |
| f12 | toggle borderless fullscreen |
| (unbound) | toggle the editor split — see below |

## Editor split

"View: Toggle Split Editor" (command palette, or the View menu) shows a second
editor pane beside the first. The two panes hold **independent files**: focus a
pane and pick a tab or open a file to change what it shows; the tabbar and
status bar follow whichever pane has focus. Drag the divider to resize, and each
pane scrolls and zooms (ctrl + scroll) on its own. Opening the split puts the
previously active file in the new pane when there is one.

## Terminal

The console panel is a live shell, one per tab. **+** on the tab strip lists the
shells found on this machine and opens a terminal on the one you pick; the dot on
a tab marks a running command, and turns red when the shell has ended.

| Binding | Action |
| --- | --- |
| ctrl + t | toggle the console panel |
| ctrl + shift + t | focus the terminal (opens the panel if collapsed) |
| enter | run the typed line (goes to the running command's stdin while one runs) |
| up / down | walk the commands run in this terminal |
| ctrl + c | interrupt the running command |
| ctrl + click | open the file a path in the output points at |

`ctrl + c` sends an interrupt on Linux and macOS. Windows cannot signal a shell
that reads from a pipe, so Thor restarts it instead — the scrollback is kept, but
the shell's state (`cd`, environment) is not.

The five "Terminal:" palette actions — New Terminal, Close Terminal, Next
Terminal, Restart Shell, Select Default Shell — ship unbound; give them chords in
the `terminal` group of `settings/keybinds.json`. Which shell new terminals open
with is the `default_shell` setting (Settings > Terminal > Default Shell);
empty means the best shell found on the machine.

## Autocompletion

Typing at least two word characters pops up a completion list of matching words
found elsewhere in the buffer. Up / down move the selection, tab or shift + enter
accepts the highlighted word, escape (or typing a non-word character) dismisses
it. A plain enter dismisses the popup and inserts a newline. There is no key to
summon it — it appears automatically while typing.

## Tasks

Left of the window controls sit three task buttons: **+** adds a task, the
**selector** names the active one, and **▶** runs it. Tasks are named shell
commands (build, test, run, ...) and run in the console panel, exactly like
typing them at the prompt.

| Control | Action |
| --- | --- |
| + | add a task: prompts for a name, then the command it runs |
| selector | drop down the workspace's tasks; picking one selects it |
| ▶ | run the selected task |

The dropdown also carries "Run Task...", "Add Task...", "Remove Task..." and
"Edit Tasks (JSON)", which opens the file the tasks live in,
`<workspace>/.thor/tasks.json`. That file is committable and reloads as soon as
it is saved. Which task is selected is personal, so it stays in the session
rather than the file. The same actions are in the command palette under "Tasks:"
and can be given chords in `settings/keybinds.json` — "Tasks: Run Selected Task"
is the one worth binding.

```json
{
    "tasks": [
        { "name": "build", "command": "odin run build.odin -file" },
        { "name": "test",  "command": "odin test thor" }
    ]
}
```

## Command palette

`ctrl + .` opens the command palette. Type to fuzzy-filter, arrows/enter to run,
escape to dismiss. Commands that have a keybinding show the chord right-aligned
in the list. "Go to File" and "Go to Line" switch it into file / line input
modes. All bindings above live in `settings/keybinds.json`; comment markers in
`settings/comments.json`; tab width, font size and autosave delay in
`settings/settings.json`.

`ctrl + alt + l` is intentionally left unbound — it is reserved for a future
code formatter.
