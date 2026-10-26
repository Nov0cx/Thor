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
| ctrl + n | new file: prompts for a name, beside the explorer's selection when the explorer has focus, else in the workspace root |
| ctrl + s | save file (autosave also runs 1.5s after the last edit) |
| ctrl + w | close tab; an unsaved buffer is written first |
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
| ctrl + alt + left / right | jump back / forward through the places a jump left |
| f10 | find all references to the symbol under the caret |
| ctrl + shift + o | go to a symbol of the file |
| ctrl + q | go to a symbol of the workspace |
| ctrl + shift + space | show the signature of the call around the caret |
| f2 | rename the file of the active tab |
| f9 | run the selected task |
| ctrl + hover | show the declaration of the symbol under the mouse |
| ctrl + shift + u | code actions: the fixes available at the caret, in a picker (scoped to the selection instead, on a language-server-backed file) |
| ctrl + f | find |
| ctrl + shift + f | find in files |
| ctrl + r | rename the symbol under the caret across every file that uses it; falls back to find & replace when the caret is not on a renameable symbol |

## Explorer

When the explorer has focus (a click on a row, or ctrl + shift + b) it can be
driven from the keyboard:

| Binding | Action |
| --- | --- |
| up / down | move the selection |
| right | expand a folder, or step into its first child |
| left | collapse a folder, or step out to its parent |
| enter | open the selected file / toggle the selected folder |
| delete | delete the selection, files and folders (after a confirmation dialog) |

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
pattern that does not compile reads "bad pattern" where the match count sits.

With `.*` on, the replacement can name what the pattern captured: `$1` to `$9`
are the groups, `$0` and `$&` the whole match, `$$` a dollar sign, and `\n` and
`\t` a newline and a tab. `^` and `$` match at every line, and a pattern that
matches no text is a match too, so `^` replaced by `// ` puts a marker in front
of every line. With `.*` off the replacement is the text as typed.

## Find in files

`ctrl + shift + f` opens a picker over the files of the folder. Type the text
to find; the rows are the matching lines, and the line under the list names the
file and the line of the selected row. `enter` opens the file at the match.

The search uses the case, word and regular-expression toggles of the find bar.
In a git work tree the files are the tracked and the untracked ones, so what
`.gitignore` names is left out. A file with a NUL byte or over 4 MB is not
read, and the list stops at 1000 matches.

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
| page up / page down | move by the rows in view, less one |
| shift + wheel | scroll sideways (word wrap off) |
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
| ctrl + k | toggle line comment (per-language marker); a language with block comments only gets those |
| shift + alt + a | toggle block comment around the selection, or around the text of the line |
| alt + u / l / c | uppercase / lowercase / capitalize the selection (or the word under the caret) |
| ctrl + shift + w | trim trailing whitespace |
| ctrl + alt + l | format document (needs language intelligence; Odin in-client, other languages need a server with a formatter) |
| ctrl + alt + shift + l | format selection (falls back to the whole document with no selection) |
| ctrl + shift + a | align selected lines on a character (prompts for the char, e.g. `=`) |
| ctrl + shift + comma | fold or unfold the block at the caret |
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

The editor's right-click menu starts with the language features — go to
definition, find references, rename, code actions, signature help, format
document and selection, go to symbol and package documentation — greyed out
when the file's language does not serve them. A right-click outside the
selection first moves the caret to the click, so the menu acts on the word
under the mouse.

Undo and Redo also sit at the top of the **Edit** menu and below the language
items in the editor's right-click menu, greyed out when there is nothing to move. A rename or code
action that changed several files moves as one step, files that were never open
included; once any of them has moved on, undo and redo fall back to the focused
buffer alone.

## View

| Binding | Action |
| --- | --- |
| ctrl + scroll wheel | zoom editor font |
| ctrl + numpad + / numpad - | zoom editor font |
| ctrl + shift + j | recenter the view on the caret (repeat cycles center / top / bottom) |
| f4 | toggle the rendered markdown preview (markdown files only) — see [Previews](#previews) |
| f12 | toggle borderless fullscreen |
| f1 | toggle the editor split — see below |

## Previews

Three file kinds open in a view of their own instead of the text editor. Each is
a tab like any other, in the pane its tab owns, so the explorer, the terminal and
the tab strip stay where they are, and a split can show two at once.

**Markdown** (`f4`, markdown files only) renders the file beside its source: the
focused pane keeps the text, the other shows the page, and the split opens if it
was closed. A link in it is clickable — a URL opens in the browser, a relative
path opens as a tab.

The page shows headings (`#` and the underlined form), paragraphs with hard line
breaks, strong and emphasised text, `~~strikethrough~~`, code spans, fenced code
blocks, quotes, rules, nested bullet and numbered lists, tables with column
alignment, and links — inline, by reference and `<url>`. An image that is a file
beside the document is drawn in the page, scaled to the column; a click opens it
as a tab. An image on the web is not fetched: its text shows as a link.

**Images** (`.png .jpg .jpeg .bmp .gif .tga .psd .hdr .qoi`) open fit to the
pane, never scaled past 1:1. A checkerboard behind them shows the transparent
pixels; the name, pixel size and zoom sit in the bottom-left corner.

**3D models** (`.obj .gltf .glb .iqm .vox .m3d`) open on a ground grid, framed to
the model. The mesh, vertex and triangle counts sit in the bottom-left corner,
and the button in the top-right corner spins the model.

| Binding | Action |
| --- | --- |
| wheel | image: zoom toward the cursor; model: zoom the camera |
| click + drag | image: pan; model: orbit |
| shift + drag, or right button + drag | model: pan |

The zoom, pan and camera reset when the tab changes file, and a file edited
outside Thor is reloaded into its view.

## Git

The Git UI ("Git" in the top bar; the palette actions "Git: Open Git UI",
"Git: History" and "Git: Branches" ship unbound — bindable as `open_git_gui`,
`open_git_history`, `open_git_branches`). Inside the modal:

| Binding | Action |
| --- | --- |
| enter | save the config value being edited |
| escape | close the modal |

Everything else in the modal works with the mouse.

See [Git](git.md) for the full tour.

## Editor split

"View: Toggle Split Editor" (command palette, or the View menu) shows a second
editor pane beside the first. The two panes hold **independent files**: focus a
pane and pick a tab or open a file to change what it shows; the tabbar and
status bar follow whichever pane has focus. Drag the divider to resize, and each
pane scrolls and zooms (ctrl + scroll) on its own. Opening the split puts the
previously active file in the new pane when there is one.

## Terminal

The console panel is a terminal emulator, one shell per tab on a pseudo-terminal
of its own, so a full-screen program, colours and a shell's own line editing all
work as they do in any other terminal. **+** on the tab strip lists the shells
found on this machine and opens a terminal on the one you pick; a tab turns red
when its shell has ended.

Keys go to the shell, which draws its own prompt and keeps its own history, so
up / down, tab completion and ctrl + r are the shell's, not the editor's.

| Binding | Action |
| --- | --- |
| ctrl + t | toggle the console panel |
| ctrl + shift + t | focus the terminal (opens the panel if collapsed, and raises its tab when another panel is in front) |
| ctrl + c | interrupt the running command, or copy when text is selected |
| ctrl + shift + c | copy the selection, or the whole scrollback with nothing selected |
| ctrl + v | paste, fenced when the program asked for bracketed paste |
| shift + page up / page down | scroll the scrollback by a screen |
| wheel | scroll the scrollback, or move a full-screen program that reads no mouse |
| click + drag | select text; shift + drag selects even while a program reads the mouse |
| click on a path | open the file an error line points at |
| click on a link | open a hyperlink the program marked |

Right-click the console for the same actions as a menu: "Copy" (the
selection, when there is one), "Copy All", "Paste", plus Clear and the
terminal-tab actions.

While the terminal holds the keyboard the editor's chords stay out of its way:
only the command palette, quick open, and the binds that toggle or focus a panel
still reach the editor. Everything else is the shell's.

The grid follows the panel: resize it and the shell re-wraps, and a full-screen
program redraws.

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

In a language served by a language server, a candidate may bring more than its
own name: the import line it needs is added at the top of the file, and a
function may arrive as a snippet with its arguments already in place.

The built-in Odin support does the same: a procedure arrives as a call snippet
(`enable_snippets` in `.thor/odin-analyzer.json` turns this off, see
[Configuration](configuration.md)), and a package the file does not import yet
brings its `import` line. After `x.(` the list holds the variants of the union
`x`, and after `x->` the procedure members of `x`.

### Snippets

When an accepted candidate is a snippet, its first placeholder is selected and
typing replaces it. Every placeholder of the session is boxed: the one the caret
is on in the accent colour, the ones tab still reaches dimmed. A placeholder used
twice is one destination: both boxes light up together, and what is typed in the
first goes into the others. A placeholder with a set of choices opens them as a
list — up and down pick one, tab or enter takes it.

| Key | Action |
| --- | --- |
| tab | jump to the next placeholder |
| shift + tab | jump back to the previous one |
| escape | leave the snippet and keep the text |

The last stop puts the caret where the snippet ends and closes it. Clicking
outside the snippet, or undoing, also ends it.

A snippet of more than one line takes the indent of the line it lands on, and a
tab in it becomes one indent level of the file.

The template is the language-server snippet syntax:

| Form | Meaning |
| --- | --- |
| `$1`, `${1}` | a placeholder; `$0` is where the caret ends |
| `${1:text}` | a placeholder with a default |
| `${1\|one,two\|}` | a placeholder with choices |
| `${1/regex/format/flags}` | the text of placeholder 1, changed by the transform |
| `$NAME`, `${NAME:text}` | a variable, with a default for when it is empty |
| `${NAME/regex/format/flags}` | a variable, changed by the transform |

The flags of a transform are `g` (every match), `i` (ignore case) and `m` (`^`
and `$` at every line). Its format takes `$1` for a capture group,
`${1:/upcase}`, `/downcase`, `/capitalize`, `/camelcase` and `/pascalcase`,
and `${1:+text}`, `${1:?text:other}` and `${1:-other}` for a group that did or
did not match.

The variables: `TM_SELECTED_TEXT`, `TM_CURRENT_LINE`, `TM_LINE_NUMBER`,
`TM_LINE_INDEX`, `TM_FILENAME`, `TM_FILENAME_BASE`, `TM_FILEPATH`,
`TM_DIRECTORY`, `RELATIVE_FILEPATH`, `WORKSPACE_NAME`, `WORKSPACE_FOLDER`,
`CLIPBOARD`, and for the local date and time `CURRENT_YEAR`,
`CURRENT_YEAR_SHORT`, `CURRENT_MONTH`, `CURRENT_MONTH_NAME`,
`CURRENT_MONTH_NAME_SHORT`, `CURRENT_DATE`, `CURRENT_DAY_NAME`,
`CURRENT_DAY_NAME_SHORT`, `CURRENT_HOUR`, `CURRENT_MINUTE`, `CURRENT_SECOND`,
`CURRENT_SECONDS_UNIX` and `CURRENT_TIMEZONE_OFFSET`.

## Tasks

Left of the window controls sit three task buttons: **+** adds a task, the
**selector** names the active one, and **▶** runs it. Tasks are named shell
commands (build, test, run, ...). Each runs in its own console tab, named
after the task; running it again restarts that tab and stops a run that is
still going. Keyboard focus stays in the editor.

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
modes. Three "Language:" actions ship unbound and take chords in `keybinds.json`
as `open_language_servers` (Settings' Language Servers page),
`restart_language_servers` and `restart_one_language_server` (pick one server
from a list). All bindings above live in `keybinds.json`; comment markers in
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
