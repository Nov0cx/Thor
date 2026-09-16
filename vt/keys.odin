package vt

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// What the host sends up the pipe: keys, typed text, pastes, mouse reports and
// focus changes, each in the spelling the modes the shell set ask for.

// The keys that are not a character. Everything else reaches the terminal as
// typed text.
Key :: enum u8 {
    None,
    Enter,
    Tab,
    Backspace,
    Escape,
    Space,
    Up,
    Down,
    Right,
    Left,
    Home,
    End,
    Page_Up,
    Page_Down,
    Insert,
    Delete,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    Pad_0, Pad_1, Pad_2, Pad_3, Pad_4, Pad_5, Pad_6, Pad_7, Pad_8, Pad_9,
    Pad_Decimal,
    Pad_Divide,
    Pad_Multiply,
    Pad_Subtract,
    Pad_Add,
    Pad_Enter,
    Pad_Equal,
}

Mod :: enum u8 {
    Shift,
    Alt,
    Ctrl,
}

Mods :: bit_set[Mod;u8]

Mouse_Button :: enum u8 {
    Left,
    Middle,
    Right,
    Wheel_Up,
    Wheel_Down,
    Wheel_Left,
    Wheel_Right,
    None, // a move with no button down
}

Mouse_Action :: enum u8 {
    Press,
    Release,
    Move,
}

// The xterm modifier argument: one plus a bit a modifier.
@(private = "file")
mod_param :: proc(mods: Mods) -> int {
    value := 1
    if .Shift in mods {
        value += 1
    }
    if .Alt in mods {
        value += 2
    }
    if .Ctrl in mods {
        value += 4
    }
    return value
}

// The bytes `key` sends, or ok=false when this key sends nothing — a keypad
// digit outside application mode, which arrives as typed text instead.
encode_key :: proc(
    t: ^Term,
    key: Key,
    mods: Mods = {},
    allocator := context.temp_allocator,
) -> (string, bool) {
    m := mod_param(mods)

    switch key {
    case .None:
        return "", false

    case .Enter:
        text := t.newline_mode ? "\r\n" : "\r"
        return alt_prefixed(text, mods, allocator), true

    case .Tab:
        if .Shift in mods {
            return "\x1b[Z", true
        }
        if .Ctrl in mods {
            return "\x1b[27;5;9~", true
        }
        return alt_prefixed("\t", mods, allocator), true

    case .Backspace:
        // The DEL byte is what a terminal sends; Ctrl turns it into BS, which is
        // the pair readline binds delete-word to.
        text := .Ctrl in mods ? "\x08" : "\x7f"
        return alt_prefixed(text, mods, allocator), true

    case .Escape:
        return alt_prefixed("\x1b", mods, allocator), true

    case .Space:
        if .Ctrl in mods {
            return alt_prefixed("\x00", mods, allocator), true
        }
        return alt_prefixed(" ", mods, allocator), true

    case .Up:
        return cursor_key(t, 'A', m, allocator), true
    case .Down:
        return cursor_key(t, 'B', m, allocator), true
    case .Right:
        return cursor_key(t, 'C', m, allocator), true
    case .Left:
        return cursor_key(t, 'D', m, allocator), true
    case .Home:
        return cursor_key(t, 'H', m, allocator), true
    case .End:
        return cursor_key(t, 'F', m, allocator), true

    case .Insert:
        return tilde_key(2, m, allocator), true
    case .Delete:
        return tilde_key(3, m, allocator), true
    case .Page_Up:
        return tilde_key(5, m, allocator), true
    case .Page_Down:
        return tilde_key(6, m, allocator), true

    case .F1:
        return function_key(t, 'P', 11, m, allocator), true
    case .F2:
        return function_key(t, 'Q', 12, m, allocator), true
    case .F3:
        return function_key(t, 'R', 13, m, allocator), true
    case .F4:
        return function_key(t, 'S', 14, m, allocator), true
    case .F5:
        return tilde_key(15, m, allocator), true
    case .F6:
        return tilde_key(17, m, allocator), true
    case .F7:
        return tilde_key(18, m, allocator), true
    case .F8:
        return tilde_key(19, m, allocator), true
    case .F9:
        return tilde_key(20, m, allocator), true
    case .F10:
        return tilde_key(21, m, allocator), true
    case .F11:
        return tilde_key(23, m, allocator), true
    case .F12:
        return tilde_key(24, m, allocator), true

    case .Pad_Enter:
        if t.app_keypad {
            return "\x1bOM", true
        }
        return alt_prefixed(t.newline_mode ? "\r\n" : "\r", mods, allocator), true

    case .Pad_0, .Pad_1, .Pad_2, .Pad_3, .Pad_4, .Pad_5, .Pad_6, .Pad_7, .Pad_8,
         .Pad_9, .Pad_Decimal, .Pad_Divide, .Pad_Multiply, .Pad_Subtract,
         .Pad_Add, .Pad_Equal:
        if !t.app_keypad {
            return "", false
        }
        return keypad_key(key, allocator), true
    }
    return "", false
}

// Arrow and Home/End keys: three bytes while no modifier is held, and the long
// form with one. Application mode only changes the unmodified spelling.
@(private = "file")
cursor_key :: proc(t: ^Term, final: u8, m: int, allocator: runtime.Allocator) -> string {
    if m > 1 {
        return fmt.aprintf("\x1b[1;%d%c", m, rune(final), allocator = allocator)
    }
    if t.app_cursor {
        return fmt.aprintf("\x1bO%c", rune(final), allocator = allocator)
    }
    return fmt.aprintf("\x1b[%c", rune(final), allocator = allocator)
}

@(private = "file")
tilde_key :: proc(number: int, m: int, allocator: runtime.Allocator) -> string {
    if m > 1 {
        return fmt.aprintf("\x1b[%d;%d~", number, m, allocator = allocator)
    }
    return fmt.aprintf("\x1b[%d~", number, allocator = allocator)
}

// F1 to F4 keep the SS3 spelling until a modifier is held.
@(private = "file")
function_key :: proc(t: ^Term, final: u8, number: int, m: int, allocator: runtime.Allocator) -> string {
    if m > 1 {
        return fmt.aprintf("\x1b[1;%d%c", m, rune(final), allocator = allocator)
    }
    return fmt.aprintf("\x1bO%c", rune(final), allocator = allocator)
}

@(private = "file")
keypad_key :: proc(key: Key, allocator: runtime.Allocator) -> string {
    final: u8
    #partial switch key {
    case .Pad_0:
        final = 'p'
    case .Pad_1:
        final = 'q'
    case .Pad_2:
        final = 'r'
    case .Pad_3:
        final = 's'
    case .Pad_4:
        final = 't'
    case .Pad_5:
        final = 'u'
    case .Pad_6:
        final = 'v'
    case .Pad_7:
        final = 'w'
    case .Pad_8:
        final = 'x'
    case .Pad_9:
        final = 'y'
    case .Pad_Decimal:
        final = 'n'
    case .Pad_Divide:
        final = 'o'
    case .Pad_Multiply:
        final = 'j'
    case .Pad_Subtract:
        final = 'm'
    case .Pad_Add:
        final = 'k'
    case .Pad_Equal:
        final = 'X'
    case:
        return ""
    }
    return fmt.aprintf("\x1bO%c", rune(final), allocator = allocator)
}

// One typed character. Ctrl folds a letter into its control code, and Alt puts
// an escape in front, which is how a terminal spells a meta key.
encode_rune :: proc(
    t: ^Term,
    r: rune,
    mods: Mods = {},
    allocator := context.temp_allocator,
) -> (string, bool) {
    if .Ctrl in mods {
        if code, ok := control_code(r); ok {
            return alt_prefixed(string([]u8{code}), mods, allocator), true
        }
        // A chord this terminal has no code for sends nothing rather than the
        // bare letter, which would look like the user typed it.
        return "", false
    }
    buf, n := utf8.encode_rune(r)
    return alt_prefixed(string(buf[:n]), mods, allocator), true
}

// The control code a Ctrl chord produces, for the keys that have one.
@(private = "file")
control_code :: proc(r: rune) -> (u8, bool) {
    switch {
    case r >= 'a' && r <= 'z':
        return u8(r - 'a' + 1), true
    case r >= 'A' && r <= 'Z':
        return u8(r - 'A' + 1), true
    case r == ' ' || r == '@':
        return 0, true
    case r == '[':
        return 0x1b, true
    case r == '\\':
        return 0x1c, true
    case r == ']':
        return 0x1d, true
    case r == '^' || r == '6':
        return 0x1e, true
    case r == '_' || r == '-' || r == '/':
        return 0x1f, true
    case r == '?':
        return 0x7f, true
    }
    return 0, false
}

@(private = "file")
alt_prefixed :: proc(text: string, mods: Mods, allocator: runtime.Allocator) -> string {
    if .Alt not_in mods {
        return strings.clone(text, allocator)
    }
    return strings.concatenate({"\x1b", text}, allocator)
}

// Pasted text. With bracketed paste on it arrives fenced, so a shell can tell it
// from typing and refuse to run it on its own. The escape that would end the
// fence early is dropped.
encode_paste :: proc(t: ^Term, text: string, allocator := context.temp_allocator) -> string {
    builder := strings.builder_make(allocator)
    if t.bracketed_paste {
        strings.write_string(&builder, "\x1b[200~")
    }
    for i in 0 ..< len(text) {
        switch text[i] {
        case '\x1b':
        case '\n':
            // A newline in a paste submits a line; carriage return is what the
            // shell reads as one.
            strings.write_byte(&builder, '\r')
        case '\r':
            if i + 1 < len(text) && text[i + 1] == '\n' {
                continue
            }
            strings.write_byte(&builder, '\r')
        case:
            strings.write_byte(&builder, text[i])
        }
    }
    if t.bracketed_paste {
        strings.write_string(&builder, "\x1b[201~")
    }
    return strings.to_string(builder)
}

// A mouse report, or ok=false when the shell asked for none of this kind.
// `col` and `row` are 0-based cells of the screen, not of the scrollback.
encode_mouse :: proc(
    t: ^Term,
    button: Mouse_Button,
    action: Mouse_Action,
    col, row: int,
    mods: Mods = {},
    allocator := context.temp_allocator,
) -> (string, bool) {
    if t.mouse_track == .Off {
        return "", false
    }
    if action != .Press && t.mouse_track == .X10 {
        return "", false
    }
    if action == .Move {
        switch t.mouse_track {
        case .Off, .X10, .Normal:
            return "", false
        case .Button:
            if button == .None {
                return "", false
            }
        case .Any:
        }
    }

    code := button_code(button)
    if action == .Move {
        code += 32
    }
    if t.mouse_track != .X10 {
        if .Shift in mods {
            code += 4
        }
        if .Alt in mods {
            code += 8
        }
        if .Ctrl in mods {
            code += 16
        }
    }
    // Every encoding but SGR loses which button was let go, so a release is the
    // one code that means "some button".
    if action == .Release && t.mouse_encoding != .Sgr && !is_wheel(button) {
        code = code - button_code(button) + 3
    }

    x, y := col + 1, row + 1
    switch t.mouse_encoding {
    case .Sgr:
        final := action == .Release ? 'm' : 'M'
        return fmt.aprintf("\x1b[<%d;%d;%d%c", code, x, y, final, allocator = allocator), true
    case .Urxvt:
        return fmt.aprintf("\x1b[%d;%d;%dM", code + 32, x, y, allocator = allocator), true
    case .Utf8:
        builder := strings.builder_make(allocator)
        strings.write_string(&builder, "\x1b[M")
        strings.write_rune(&builder, rune(code + 32))
        strings.write_rune(&builder, rune(x + 32))
        strings.write_rune(&builder, rune(y + 32))
        return strings.to_string(builder), true
    case .X10:
        // The original report has one byte a coordinate, so a cell past 223
        // cannot be named at all.
        if x > 223 || y > 223 {
            return "", false
        }
        bytes := []u8{0x1b, '[', 'M', u8(code + 32), u8(x + 32), u8(y + 32)}
        return strings.clone(string(bytes), allocator), true
    }
    return "", false
}

@(private = "file")
is_wheel :: proc(button: Mouse_Button) -> bool {
    return button == .Wheel_Up || button == .Wheel_Down || button == .Wheel_Left ||
        button == .Wheel_Right
}

@(private = "file")
button_code :: proc(button: Mouse_Button) -> int {
    switch button {
    case .Left:
        return 0
    case .Middle:
        return 1
    case .Right:
        return 2
    case .Wheel_Up:
        return 64
    case .Wheel_Down:
        return 65
    case .Wheel_Left:
        return 66
    case .Wheel_Right:
        return 67
    case .None:
        return 3
    }
    return 3
}

// The report mode 1004 asks for when the window takes or loses the keyboard.
encode_focus :: proc(t: ^Term, focused: bool) -> (string, bool) {
    if !t.focus_events {
        return "", false
    }
    return focused ? "\x1b[I" : "\x1b[O", true
}
