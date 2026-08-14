# Keybindings

Bindings follow the active keyboard layout (QWERTZ, AZERTY etc.) on every
platform: a chord sits on the key that prints its character, not on the US
position. A key a layout prints something Thor has no name for keeps its
physical position.

A held key repeats, except for the shortcuts that open or toggle something —
those act once per press.

Every binding below is a default and can be changed in `keybinds.json`
— see [Configuration](configuration.md) for the chord format, including the
`cmd` token that reaches the Command key on macOS.

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
| ctrl + shift + u | code actions: the fixes available at the caret, in a picker (scoped to the selection instead, on a language-server-backed file) |
| ctrl + f | find |
| ctrl + r | rename the symbol under the caret across every file that uses it; falls back to find & replace when the caret is not on a renameable symbol |

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

## Find and replace

| Binding | Action |
| --- | --- |
| enter / shift + enter | next / previous match |
| tab | switch between the find and replace fields |
| alt + c | match case (the `Aa` button) |
| alt + w | whole word only (the `W` button) |
| alt + r | read the query as a regular expression (the `.*` button) |
| escape | close |

The three toggles also work as buttons on the bottom row of the box, and each
lights up while it is on. They stay set until Thor restarts. With `.*` on, a
pattern that does not compile reads "Invalid pattern" where the match count
sits; the replacement stays literal in every mode, so `$1` is not a capture
reference.

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

The line numbers in the gutter are relative to the caret's line, and `alt` + a
number jumps that far. Every digit typed while `alt` is held makes one number, so
a distance of 10 or more is reached by typing its digits: hold `alt`, type `2`
`3`, release `alt` to jump 23 lines down. The count is shown in the status bar
while it is typed, and the jump runs when `alt` is released. Add `shift` to jump
up instead.

Bracket motions match `()`, `[]`, `{}`; quote motions match `"`, `'` and `` ` ``
(paired left-to-right on the caret's line).

Add `shift` to any movement to extend the selection.

## Selection & multi-cursor

| Binding | Action |
| --- | --- |
| ctrl + a | select all |
| ctrl + d | select word; press again: add cursor at next whole-word occurrence |
| ctrl + shift + d | same, matching substrings instead of whole words |
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
| ctrl + alt + l | format document (needs language intelligence; Odin in-client, other languages need a server with a formatter) |
| ctrl + alt + shift + l | format selection (falls back to the whole document with no selection) |
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

Undo and Redo also sit at the top of the **Edit** menu and the editor's
right-click menu, greyed out when there is nothing to move. A rename or code
action that changed several files moves as one step, files that were never open
included; once any of them has moved on, undo and redo fall back to the focused
buffer alone.

## View

| Binding | Action |
| --- | --- |
| ctrl + scroll wheel | zoom editor font |
| ctrl + numpad + / numpad - | zoom editor font |
| ctrl + shift + j | recenter the view on the caret (repeat cycles center / top / bottom) |
| f4 | toggle the rendered markdown preview (markdown files only); links in it are clickable — a URL opens in the browser, a relative path opens as a tab |
| f12 | toggle borderless fullscreen |
| (unbound) | toggle the editor split — see below |

## Git

The Git UI ("Git" in the top bar; the palette actions "Git: Open Git UI",
"Git: History" and "Git: Branches" ship unbound — bindable as `open_git_gui`,
`open_git_history`, `open_git_branches`). Inside the modal:

| Binding | Action |
| --- | --- |
| tab | cycle files, diff, commit subject, description |
| up / down | move the file, commit or branch selection |
| space | stage / unstage the selected file |
| enter | show the diff; check out the selected branch; edit the selected config value |
| ctrl + enter | commit |
| escape | leave a text field, then close the modal |

See [Git](git.md) for the full tour.

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
| ctrl + shift + c | copy the selected scrollback text, or all of it with nothing selected (works whether or not a command is running) |
| ctrl + v | paste into the input line, at the caret |
| left / right | move the caret in the input line |
| home / end | jump to the start / end of the input line |
| delete | delete the character after the caret |
| click on the input line | place the caret there |
| click + drag | select scrollback text |
| ctrl + click | open the file a path in the output points at |

Right-click the console for the same actions as a menu: "Copy" (the
selection, when there is one), "Copy All", "Paste", plus Clear and the
terminal-tab actions.

`ctrl + c` sends an interrupt on Linux and macOS. Windows cannot signal a shell
that reads from a pipe, so Thor restarts it instead — the scrollback is kept, but
the shell's state (`cd`, environment) is not.

The five "Terminal:" palette actions — New Terminal, Close Terminal, Next
Terminal, Restart Shell, Select Default Shell — ship unbound; give them chords in
the `terminal` group of `keybinds.json`. Which shell new terminals open
with is the `default_shell` setting (Settings > Terminal > Default Shell);
empty means the best shell found on the machine.

## Autocompletion

Typing at least two word characters pops up a completion list of matching words
found elsewhere in the buffer. Up / down move the selection, tab or shift + enter
accepts the highlighted word, escape (or typing a non-word character) dismisses
it. A plain enter dismisses the popup and inserts a newline. There is no key to
summon it — it appears automatically while typing.

The popup also takes the mouse: hovering a candidate highlights it, clicking one
accepts it, and the wheel over the popup walks the list instead of scrolling the
text.

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
and can be given chords in `keybinds.json` — "Tasks: Run Selected Task"
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
modes. All bindings above live in `keybinds.json`; comment markers in
`comments.json`; tab width, font size and autosave delay in `settings.json` —
see [Configuration](configuration.md) for the three directories those are
layered from.

## Help

The **Help** menu opens this manual without leaving the editor:

| entry | what it does |
| --- | --- |
| Documentation | opens `docs/index.md` in the rendered Markdown preview |
| Documentation Page... | picks one page of the manual and opens it the same way |
| Documentation in Browser | opens `docs/html/` in the system browser, or the pages on GitHub when that HTML has not been generated |

The pages ship beside the binary, so they are readable offline. The same three
actions are in the command palette under "Help:" and take chords in
`keybinds.json` as `docs`, `docs_page` and `docs_browser`.
