package ui

import "core:unicode/utf8"

import rl "vendor:raylib"

// raylib reports physical keys named after the US layout, so on QWERTZ the
// labeled Z arrives as .Y. GetKeyName gives the character the active layout
// prints on that key, which is what a shortcut must follow.
remap_key_to_layout :: proc(key: rl.KeyboardKey) -> rl.KeyboardKey {
    name := rl.GetKeyName(key)
    if name == nil {
        return key
    }
    return key_from_layout_name(string(name), key)
}

// The raylib key `name` prints, or `fallback` when it names none: a layout can
// print a character raylib has no key for (the German ü on [), and a name is
// not one rune for every key.
key_from_layout_name :: proc(name: string, fallback: rl.KeyboardKey) -> rl.KeyboardKey {
    if name == "" {
        return fallback
    }
    r, size := utf8.decode_rune_in_string(name)
    if size != len(name) {
        return fallback
    }

    // The letter, digit and punctuation keys hold their ASCII value.
    switch r {
    case 'a' ..= 'z':
        return cast(rl.KeyboardKey) (r - 'a' + 'A')
    case 'A' ..= 'Z', '0' ..= '9':
        return cast(rl.KeyboardKey) r
    case '\'', ',', '-', '.', '/', ';', '=', '[', '\\', ']', '`':
        return cast(rl.KeyboardKey) r
    }
    return fallback
}
