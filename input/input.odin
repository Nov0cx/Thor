// The modifier keys a chord can hold. A leaf both `ui` (which reads the live
// state off raylib and stamps it on an event) and `setting` (which parses and
// writes a chord) import, so the set of modifiers and their spelling exist once.
package input

import "core:strings"

// Cmd is the Command key on macOS and the Windows/Super key elsewhere; raylib
// reports both as LEFT_SUPER / RIGHT_SUPER.
Modifier :: enum u8 {
    Ctrl,
    Shift,
    Alt,
    Cmd,
}

Modifiers :: bit_set[Modifier; u8]

// The modifier a spec token names, e.g. "ctrl" or "super". The token must be
// lowercase and trimmed; anything else is a key name, not a modifier.
modifier_from_token :: proc(token: string) -> (Modifier, bool) {
    switch token {
    case "ctrl", "control":
        return .Ctrl, true
    case "shift":
        return .Shift, true
    case "alt", "option":
        return .Alt, true
    case "cmd", "command", "super", "meta", "win":
        return .Cmd, true
    }
    return .Ctrl, false
}

// The canonical lowercase tokens of `mods`, each with its trailing "+", e.g.
// "ctrl+shift+". Written in the order parse reads back, so a spec round-trips.
write_tokens :: proc(b: ^strings.Builder, mods: Modifiers) {
    if .Ctrl in mods {
        strings.write_string(b, "ctrl+")
    }
    if .Shift in mods {
        strings.write_string(b, "shift+")
    }
    if .Alt in mods {
        strings.write_string(b, "alt+")
    }
    if .Cmd in mods {
        strings.write_string(b, "cmd+")
    }
}

// The display names of `mods`, each with its trailing "+", e.g. "Ctrl+Shift+".
write_names :: proc(b: ^strings.Builder, mods: Modifiers) {
    if .Ctrl in mods {
        strings.write_string(b, "Ctrl+")
    }
    if .Shift in mods {
        strings.write_string(b, "Shift+")
    }
    if .Alt in mods {
        strings.write_string(b, "Alt+")
    }
    if .Cmd in mods {
        strings.write_string(b, "Cmd+")
    }
}
