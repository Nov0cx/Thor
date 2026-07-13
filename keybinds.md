# Keybindings

Letter keys follow the active keyboard layout (QWERTZ etc.); punctuation
bindings are physical key positions, noted where they differ.

## Files & app

| Binding | Action |
| --- | --- |
| ctrl + s | save file (autosave also runs 1.5s after the last edit) |
| ctrl + w | close tab |
| ctrl + page down / page up | next / previous tab |
| ctrl + b | toggle explorer panel |
| ctrl + t | toggle console panel (type a command, enter runs it) |
| ctrl + shift + e | focus the editor |
| ctrl + shift + b | focus the explorer (opens it if collapsed) |
| ctrl + shift + t | focus the terminal / console (opens it if collapsed) |
| ctrl + . | open the command palette |
| ctrl + tab | quick open (jump straight to file search) |
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
| ctrl + p | jump to matching / enclosing bracket (works from inside a pair) |
| ctrl + shift + p | select everything between the brackets (excludes them) |
| ctrl + shift + # (ctrl + shift + \ on US) | select to matching bracket (includes them) |

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
| alt + up / down | move line up / down |
| shift + alt + up / down | duplicate line up / down |
| ctrl + enter / ctrl + shift + enter | insert line below / above |
| tab / shift + tab (with selection) | indent / outdent lines |
| ctrl + k | toggle line comment (per-language marker) |
| ctrl + shift + w | trim trailing whitespace |
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
| f12 | toggle borderless fullscreen |

## Command palette

`ctrl + .` opens the command palette. Type to fuzzy-filter, arrows/enter to run,
escape to dismiss. "Go to File" and "Go to Line" switch it into file / line
input modes. All bindings above live in `settings/keybinds.json`; comment
markers in `settings/comments.json`; tab width, font size and autosave delay in
`settings/settings.json`.
