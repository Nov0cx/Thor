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
| ctrl + j | toggle console panel |

Reserved (not implemented yet): `ctrl + shift + p` command palette,
`ctrl + tab` quick open, `ctrl + f` find.

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
| ctrl + p | jump to matching bracket |
| ctrl + shift + # (ctrl + shift + \ on US) | select to matching bracket |

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

## View

| Binding | Action |
| --- | --- |
| ctrl + scroll wheel | zoom editor font |
| ctrl + numpad + / numpad - | zoom editor font |
