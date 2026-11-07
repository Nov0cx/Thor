# Getting Started

## Install

Two ways to get Thor:

- **Download a release** — grab the archive for your platform from the
  [Releases](https://github.com/Nov0cx/Thor/releases) page and unpack it
  anywhere. `thor` (or `thor.exe`) is ready to run; `assets/`, `plugins/` and
  `settings/` beside it are loaded at startup, so keep the whole folder
  together. What you change in Settings lands in a `user/` directory beside
  them, which no update replaces.
- **Build from source** — see [Building from Source](building.md). Needed if
  no release matches your platform, or you want a development build.

### First start

A release is not code-signed, so both desktops stop it once:

- **Windows** — SmartScreen says "Windows protected your PC". Choose **More
  info**, then **Run anyway**. It asks only for the file you downloaded.
- **macOS** — the download is in quarantine:
  `xattr -dr com.apple.quarantine thor-*-macos-arm64`.

Compare the archive against the `SHA256SUMS` the release publishes if you want
to know it arrived whole. An update Thor installs itself is checked against that
file already, and starts with no warning.

## Updating

Thor asks GitHub for a newer release shortly after it starts, at most once a
day. When it finds one it offers to install it; **Help > Check for Updates**
asks at any time and ignores the daily limit.

Answering **no** is remembered: that version is never offered again. The update
does not go away, though — a button appears in the title bar showing the new
version, and clicking it brings the offer back whenever you want it. Turn the
background check off entirely with `check_for_updates` in
[Configuration](configuration.md), or from **Settings > Updates**.

Installing downloads the archive for your platform, checks it against the
`SHA256SUMS` the release publishes, replaces the files beside the binary and
restarts into the same folder. Two things are left alone: `user/`, which holds
everything you changed in Settings, and `sessions/`, which holds your open tabs
and layout. An install made before those two directories were split gets its
`settings/` carried over into `user/` on the first update.

The first start of a new version shows a short summary of what changed.
**All changes** in it lists the full changelog of the version, and
**Help > What's New** opens it again at any time.

Thor updates itself only when it is a release build unpacked from an archive.
A build from source, or one in a directory it cannot write (`/opt`,
`C:\Program Files`), reports the new version and opens the
[Releases](https://github.com/Nov0cx/Thor/releases) page instead. It also needs
`curl` and `tar`, which Windows 10 1803 and later, macOS and most Linux
distributions already ship.

A bundled plugin or shipped theme takes the new copy with the update, unless
you hold it in **Settings > Plugin & Theme Updates**. A held item keeps your
local copy. Other plugins and themes have their own update check. See
[Plugins](plugins.md#updates).

If an update is interrupted part-way, the next start puts the old files back —
they are kept beside the new ones with an `.old` suffix until then. In the one
case it cannot repair, the binary itself is missing and `thor.exe.old` (or
`thor.old`) is beside it: rename it back.

## Opening a project

```bash
thor                    # reopen the last session's folder, or the welcome page if there is none
thor .                  # open the folder Thor was called from
thor src/               # open that folder
thor main.odin          # open the file, with its folder as the workspace
thor a.odin b.odin      # open both as tabs, with b.odin active
thor src/ main.odin     # open the folder as the workspace and the file as a tab
```

Several files open as several tabs, in the order given, and the last one is
active. The first folder becomes the workspace; a second folder argument is
ignored, because one window holds one workspace. Use `File > Open Folder...`
with `open_folder_in` set to `new` to get a second folder in its own window.

A bare `thor` with no past session opens a welcome page instead: a tip of the
day, `Open Folder`, `Open File` and a list of recently opened workspaces. `File
> Close Workspace` returns to it from an open workspace, and a later bare launch
comes back to the welcome page too.

The tip card carries one tip a day, with the chord it is about read from your
own keybindings. The arrows on it step through the rest, and `tips.lua` holds
them (see [Configuration](configuration.md)).

With a folder open there is no welcome page, so the same card floats in the
corner of the editor on the first start of each day. `✕` closes it for now, the
line under it turns tips off for good, and so does the `tip_of_the_day` setting.

Inside the editor, `File > Open Folder...` switches the workspace and
`File > Open File...` opens a file from anywhere; dropping a folder or files on
the window does the same. Each folder keeps its own session (open tabs, and the
panel layout — which panel sits in which slot, how wide each is, and where a
panel you toggled off goes back to), restored when you come back to it.

Opening a second folder while one is already open asks whether to replace the
current window's workspace or launch a new window — configurable via the
`open_folder_in` setting (see [Configuration](configuration.md)).

On Windows, "Settings: Toggle File Manager Menu Entry" (or Settings > Windows >
Explorer Menu Entry) adds "Open with Thor" to the right-click menu of files,
folders and the background of an open folder. It is written for your account only
(`HKCU`) and needs no admin right. Run the command again to remove it. Moving
Thor to another folder needs the entry added again.

A folder that is already open in another window is never opened twice; that
window is brought to the front instead. On Linux and macOS this needs a desktop
helper — `xdotool` or `wmctrl` on X11, `osascript` on macOS — and the status bar
says so when none is available (Wayland has no equivalent).

The same holds at launch. Starting Thor on a folder another window holds brings
that window forward and the new process exits. With files on the command line,
or when the window cannot be raised, Thor starts with no folder open.

## A first tour

- **Title bar** — drag it to move the window, double-click it to maximize the
  window or to restore it; the buttons on its right minimize, maximize and close.
- **Explorer** (`ctrl + b` to toggle) — the file tree for the open folder. A
  changed file shows its git status letter at the right edge of its row.
- **Editor** — tabs across the top; `ctrl + tab` for fuzzy file search,
  `ctrl + w` to close a tab.
- **Console** (`ctrl + t` to toggle) — a real shell, one per tab; **+** on its
  tab strip lists the shells found on the machine.
- **Status bar** — while the explorer or the console is closed, a button at its
  left end brings the panel back.
- **Command palette** (`ctrl + .`) — fuzzy-search and run any action Thor
  exposes; every keybinding below is also a command here.

Not every file is text. An image opens in a view that fits it to the pane, with
a checkerboard behind its transparent pixels; a 3D model opens on a ground grid,
orbited and zoomed with the mouse; and `f4` renders a markdown file beside its source.
Each is an ordinary tab, so the explorer and the terminal stay where they are.
See [Previews](keybindings.md#previews).

A `#RRGGBB` colour literal shows its colour as a small square in front of it,
wherever it appears — a theme file, CSS, a shader.

Rest the cursor on a control to see what it does: the title bar buttons, a tab,
a status bar segment and an explorer row all explain themselves, with the chord
they are bound to under the text. The `tooltips` setting turns this off.

For Odin, the built-in support formats code and shows `odin check` diagnostics
when you save. While you type, it marks syntax errors and, in a file that
parses, name errors: a redeclared name, an undeclared name, a private or
missing `pkg.name` and an import path that names no directory. When the names
resolve, it also marks a call with a missing parameter, too many arguments or a
wrong named argument (`call/arity`, `call/named`), a field or enum member that
does not exist (`type/no-member`), a switch that leaves out enum members or
union variants without `#partial` (`switch/non-exhaustive`), a `#assert`
that fails (`assert/static`), a value of the wrong type in an argument, an
assignment, a variable declaration or a `return` (`type/mismatch`), a call of a
procedure group that no member takes (`call/overload`), an integer constant its
type cannot hold (`const/overflow`), a procedure that can end with no `return`
(`flow/missing-return`), an `or_return` that does not fit its procedure
(`or_return/mismatch`), a `where` clause a call breaks (`poly/where`), an
assignment with more or fewer values than places (`assign/count`) and an
import that leads back to its own package (`import/cycle`). It marks
statements after a `return`, `break`, `continue` or a call that does not
return (`flow/unreachable`) and a `defer` that a diverging call at the end of
its scope skips (`flow/unreachable-defer`). After a save, the compiler's
diagnostics replace them. Other code that can never run, such as code after
`for {}`, gets a warning the compiler does not give (`flow/unreachable`); it
stays after a save. So does the warning for a value stored in a variable that
nothing reads (`flow/dead-store`). Two hints, drawn faint, stay too: a format
string of a `fmt.printf`-style call that `core:fmt` would print as `%!(...)`,
such as a verb the argument type does not take, a missing or extra argument, or
a bare `{` that should be `{{` (`api/fmt-verbs`), and a call statement that
drops an error result, such as `os.remove(path)` instead of
`_ = os.remove(path)` (`api/ignored-error`). Two more hints mark a value that is
gone when the procedure returns: the address or slice of a local that is returned or
stored in a global or through a pointer parameter (`mem/dangling-slice`), and a
value from `context.temp_allocator` or `tprintf` that is stored there
(`mem/temp-escape`). A `defer` in a loop that frees a variable declared before the
loop, such as `defer delete(buf)`, is marked too, since it runs on every iteration
(`defer/in-loop`). A use of a declaration marked `@(deprecated)` is marked too
(`api/deprecated`). A `for x in items` loop that copies a large element (512
bytes or more) on every iteration and only reads it is marked too, since
`for &x` avoids the copy (`perf/range-copy`). The checks of `odin check -vet` are warnings
while typing: a variable that nothing uses (`vet/unused-variable`), an import
that nothing uses (`vet/unused-import`), a variable that shadows an earlier one
of the same type (`vet/shadowing`) and a declaration in a file-scope `when`
that shadows a builtin (`vet/when-shadowing`). A `#+vet` file tag turns them on
or off for its file as it does for the compiler. A save runs `odin check` with
the matching `-vet-*` flags, and its vet lines show as warnings with the same
ids. The hover over a mark shows its id
(`[name/undeclared]`); a `// thor:ignore name/undeclared` comment hides that id
on the next line (or on its own line after code), and
`// thor:ignore-file <id>` hides it in the whole file. `"diagnostics"` in
`.thor/odin-analyzer.lua` turns an id off or sets its severity for the whole
workspace (see [Configuration](configuration.md)). The `syntax_diagnostics` feature of
`language_intelligence` turns the live marks off.
It also serves navigation, hover, completion and signature help. Hover a
symbol with `ctrl` held to see its declaration and doc comment (`//` or
`/* */`) — for a type also its size, alignment, field offsets and the fields
`using` brings in — and `alt + enter` (or `ctrl + click`) to jump to
its definition; on a call to a procedure group, the jump goes to the member the
arguments pick. `alt + shift + enter` jumps to the declaration of the type of
the name or expression under the caret instead: from `p: ^Player` to `Player`,
from a call to its result type. A `map` gives its key and value types to pick
from. `alt + f12` peeks the definition instead: an editor opens under
the caret's line on the definition's file, where an edit or `ctrl + s` goes to
that file. `escape` closes it, and **Open** (or `alt + enter` in it) jumps
there. Inlay hints show the type of a declaration with no written type between
its colons (`count : int = 3`), the type of a `for` variable after its name, and
the parameter name before each argument of a call. When the caret stops on a
name, every use of it in the file is marked; a declaration or an assignment is
underlined. `ctrl + d` then selects these uses one by one. The `document_highlight` feature of `language_intelligence` turns
this off. Completion offers the members after `x.`, the union variants
after `x.(`, the procedure members after `x->`, and packages the file does not
import yet, with the import line added. Signature help also covers a
polymorphic record (`List(`) and a conversion (`int(`). A file you save in
Thor counts at once; a file changed by another program counts within a second.
`ctrl + shift + u` shows the quick fixes at the caret: the missing cases of a
`switch` (or `#partial`), the removal of an unused import (one, or all of
them), an unused variable made `_`, the import of a package a qualifier names
(`fmt.` with no `import "core:fmt"`), the fields a struct literal leaves out,
`or_return` on a call, a declaration for a name nothing declares, and a
`thor:ignore` comment for each id on the caret's line, for the line or for the
file. The same picker holds the refactorings: inline variable, `if` chain to
`switch` and back, extract variable and extract procedure (select first),
change signature (a new parameter list, with every call rewritten) and move
declaration (to another file of the package, or to another package). Those
that need a name, a parameter list or a file ask for it in the palette first.

Every other language gets these features from a language server.
**Settings > Language Servers** (or **Help > Language Servers**) lists the ones
Thor knows: whether each is installed, what state it is in, and a button that
installs a missing one in the console. `clangd`, `rust-analyzer`, `gopls`,
`basedpyright`, `typescript-language-server`, `lua-language-server` and `zls`
are on out of the box; another two dozen — `slangd`, `ruff`, `jdtls`,
`intelephense`, `taplo` and more — are one switch away. Thor starts a server the
first time you open a file it claims. See [Configuration](configuration.md) for
the server table and how to add one of your own. A language server also scopes
`ctrl + shift + u` to the current selection instead of only the caret, and can
apply its own edits directly in the editor.

**Help > Tutorial** (or **Take the tour** on the welcome page) opens the
guided tutorial. It has eleven chapters, from the basics to git, settings and
plugins. Each step shows on a card beside the part of the window it is about,
and it is done when you do the action — by key, from the command palette, from
a menu or with a button. Back, Skip and Next move by hand, and **Chapters**
lists every chapter with its state. Progress is kept in
`sessions/tutorial.json`, so a chapter resumes where you stopped.

The last chapter, the code intelligence lab, opens a broken Odin file,
`user/tutorial/playground.odin` beside the binary, and takes you through eight
repairs with Thor's own tools. A repair counts as soon as the buffer is right,
before you save. **Show me** selects the defect, and the card shows the
analyzer's message on it. An edited playground is reset only after you
confirm.

**Help > Documentation** opens this manual in Thor's
Markdown preview, and **Help > Documentation in Browser** opens it outside the
editor.

## Next steps

- [Keybindings](keybindings.md) — the full shortcut reference.
- [Configuration](configuration.md) — themes, fonts, per-project settings.
- [Plugins](plugins.md) — how syntax highlighting and workspace plugins work.
