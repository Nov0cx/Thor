package render

// What Right Alt is. Auto asks the keyboard layout.
Right_Alt :: enum {
    Auto,
    Alt_Gr,
    Alt,
}

// Each platform file supplies:
//
//   layout_has_alt_gr :: proc() -> bool
//
// Whether the active keyboard layout types characters with AltGr. True when the
// platform cannot tell.

// Whether Right Alt is AltGr and not a shortcut modifier.
right_alt_is_alt_gr :: proc(b: ^Backend) -> bool {
    switch b.opts.right_alt {
    case .Alt_Gr:
        return true
    case .Alt:
        return false
    case .Auto:
        return layout_has_alt_gr()
    }
    return true
}
