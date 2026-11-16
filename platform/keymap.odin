package platform

import "core:unicode/utf8"
import rl "vendor:raylib"

import ui "../vendor/loom/loom"

// raylib reports physical keys named after the US layout, so on QWERTZ the
// labeled Z arrives as .Y. GetKeyName gives the character the active layout
// prints on that key, which is what a shortcut must follow.
remap_key_to_layout :: proc(key: rl.KeyboardKey) -> rl.KeyboardKey {
    if !layout_remaps(key) {
        return key
    }
    name := rl.GetKeyName(key)
    if name == nil {
        return key
    }
    return key_from_layout_name(string(name), key)
}

// True for a main-block key the layout can relabel. A numpad key is not one:
// its layout name ("1", "/") would make it the main-block key.
layout_remaps :: proc(key: rl.KeyboardKey) -> bool {
    return key >= .APOSTROPHE && key <= .GRAVE
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
        return cast(rl.KeyboardKey)(r - 'a' + 'A')
    case 'A' ..= 'Z', '0' ..= '9':
        return cast(rl.KeyboardKey)r
    case '\'', ',', '-', '.', '/', ';', '=', '[', '\\', ']', '`':
        return cast(rl.KeyboardKey)r
    }
    return fallback
}

// The Loom key of each raylib key. `remap_key_to_layout` answers what the
// user's layout prints, so a binding follows the cap and not the position.
@(rodata)
KEYS := [?]struct {
    rk: rl.KeyboardKey,
    uk: ui.Key,
}{
    {.A, .A},
    {.B, .B},
    {.C, .C},
    {.D, .D},
    {.E, .E},
    {.F, .F},
    {.G, .G},
    {.H, .H},
    {.I, .I},
    {.J, .J},
    {.K, .K},
    {.L, .L},
    {.M, .M},
    {.N, .N},
    {.O, .O},
    {.P, .P},
    {.Q, .Q},
    {.R, .R},
    {.S, .S},
    {.T, .T},
    {.U, .U},
    {.V, .V},
    {.W, .W},
    {.X, .X},
    {.Y, .Y},
    {.Z, .Z},
    {.ZERO, .Num_0},
    {.ONE, .Num_1},
    {.TWO, .Num_2},
    {.THREE, .Num_3},
    {.FOUR, .Num_4},
    {.FIVE, .Num_5},
    {.SIX, .Num_6},
    {.SEVEN, .Num_7},
    {.EIGHT, .Num_8},
    {.NINE, .Num_9},
    {.F1, .F1},
    {.F2, .F2},
    {.F3, .F3},
    {.F4, .F4},
    {.F5, .F5},
    {.F6, .F6},
    {.F7, .F7},
    {.F8, .F8},
    {.F9, .F9},
    {.F10, .F10},
    {.F11, .F11},
    {.F12, .F12},
    {.MINUS, .Minus},
    {.EQUAL, .Equal},
    {.LEFT_BRACKET, .Left_Bracket},
    {.RIGHT_BRACKET, .Right_Bracket},
    {.BACKSLASH, .Backslash},
    {.SEMICOLON, .Semicolon},
    {.APOSTROPHE, .Apostrophe},
    {.GRAVE, .Grave},
    {.COMMA, .Comma},
    {.PERIOD, .Period},
    {.SLASH, .Slash},
    {.TAB, .Tab},
    {.LEFT, .Left},
    {.RIGHT, .Right},
    {.UP, .Up},
    {.DOWN, .Down},
    {.HOME, .Home},
    {.END, .End},
    {.PAGE_UP, .Page_Up},
    {.PAGE_DOWN, .Page_Down},
    {.INSERT, .Insert},
    {.BACKSPACE, .Backspace},
    {.DELETE, .Delete},
    {.ENTER, .Enter},
    {.KP_ENTER, .Enter},
    {.ESCAPE, .Escape},
    {.SPACE, .Space},
    {.CAPS_LOCK, .Caps_Lock},
    {.NUM_LOCK, .Num_Lock},
    {.SCROLL_LOCK, .Scroll_Lock},
    {.PRINT_SCREEN, .Print_Screen},
    {.PAUSE, .Pause},
    {.KB_MENU, .Menu},
    {.LEFT_SHIFT, .Left_Shift},
    {.RIGHT_SHIFT, .Right_Shift},
    {.LEFT_CONTROL, .Left_Ctrl},
    {.RIGHT_CONTROL, .Right_Ctrl},
    {.LEFT_ALT, .Left_Alt},
    {.RIGHT_ALT, .Right_Alt},
    {.LEFT_SUPER, .Left_Super},
    {.RIGHT_SUPER, .Right_Super},
    {.KP_0, .Pad_0},
    {.KP_1, .Pad_1},
    {.KP_2, .Pad_2},
    {.KP_3, .Pad_3},
    {.KP_4, .Pad_4},
    {.KP_5, .Pad_5},
    {.KP_6, .Pad_6},
    {.KP_7, .Pad_7},
    {.KP_8, .Pad_8},
    {.KP_9, .Pad_9},
    {.KP_DECIMAL, .Pad_Decimal},
    {.KP_DIVIDE, .Pad_Divide},
    {.KP_MULTIPLY, .Pad_Multiply},
    {.KP_SUBTRACT, .Pad_Subtract},
    {.KP_ADD, .Pad_Add},
    {.KP_EQUAL, .Pad_Equal},
}

@(private)
ui_key :: proc(k: rl.KeyboardKey) -> ui.Key {
    for pair in KEYS {
        if pair.rk == k {
            return pair.uk
        }
    }
    return .None
}

// A modifier means nothing on its own, so it never repeats.
@(private)
is_modifier_key :: proc(k: rl.KeyboardKey) -> bool {
    #partial switch k {
    case .LEFT_SHIFT, .RIGHT_SHIFT, .LEFT_CONTROL, .RIGHT_CONTROL:
        return true
    case .LEFT_ALT, .RIGHT_ALT, .LEFT_SUPER, .RIGHT_SUPER:
        return true
    }
    return false
}
