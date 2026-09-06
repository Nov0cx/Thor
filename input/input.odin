// How a chord's modifiers are spelled, read and written. The set itself is
// Loom's; this package owns only the names, so a spec round-trips through one
// spelling wherever it is parsed or shown.
package input

import "core:strings"

import ui "../vendor/loom/loom"

// Super is Command on macOS and the Windows key elsewhere. It is spelled "Cmd"
// on the way out, and every one of its aliases is read on the way in.
Modifier :: ui.Mod
Modifiers :: ui.Mod_Set

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
        return .Super, true
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
    if .Super in mods {
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
    if .Super in mods {
        strings.write_string(b, "Cmd+")
    }
}
