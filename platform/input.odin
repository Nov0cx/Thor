package platform

import rl "vendor:raylib"

import ui "../vendor/loom/loom"

// A physical key as the backend names it, after no layout mapping.
Scancode :: distinct i32

// One key press: the physical key and the key the active layout prints on it.
Key_Press :: struct {
    physical: Scancode,
    key:      ui.Key,
}

// The next queued key press of this frame. Keys with no ui.Key are skipped.
next_key_press :: proc() -> (Key_Press, bool) {
    for {
        key := rl.GetKeyPressed()
        if key == rl.KeyboardKey(0) {
            return {}, false
        }
        mapped := ui_key(remap_key_to_layout(key))
        if mapped == .None {
            continue
        }
        return {physical = Scancode(key), key = mapped}, true
    }
}

// The next typed character of this frame, 0 when none is queued.
next_char :: proc() -> rune {
    return rl.GetCharPressed()
}

key_up :: proc(k: Scancode) -> bool {
    return rl.IsKeyUp(rl.KeyboardKey(k))
}

// True on the frames the OS repeats a held key.
key_repeated :: proc(k: Scancode) -> bool {
    return rl.IsKeyPressedRepeat(rl.KeyboardKey(k))
}

// True for Shift, Ctrl, Alt and Super.
key_is_modifier :: proc(k: Scancode) -> bool {
    return is_modifier_key(rl.KeyboardKey(k))
}

// The modifier keys held now, each side apart.
Modifier :: enum u8 {
    Left_Ctrl,
    Right_Ctrl,
    Left_Alt,
    Right_Alt,
    Left_Shift,
    Right_Shift,
    Left_Super,
    Right_Super,
}

modifiers_down :: proc() -> bit_set[Modifier] {
    KEYS :: [Modifier]rl.KeyboardKey{
        .Left_Ctrl = .LEFT_CONTROL,
        .Right_Ctrl = .RIGHT_CONTROL,
        .Left_Alt = .LEFT_ALT,
        .Right_Alt = .RIGHT_ALT,
        .Left_Shift = .LEFT_SHIFT,
        .Right_Shift = .RIGHT_SHIFT,
        .Left_Super = .LEFT_SUPER,
        .Right_Super = .RIGHT_SUPER,
    }
    out: bit_set[Modifier]
    for key, m in KEYS {
        if rl.IsKeyDown(key) {
            out += {m}
        }
    }
    return out
}

// The mouse in window coordinates.
mouse_position :: proc() -> [2]f32 {
    return rl.GetMousePosition()
}

// The wheel travel of this frame as the OS reports it: positive y is away from the hand.
mouse_wheel :: proc() -> [2]f32 {
    return rl.GetMouseWheelMoveV()
}

@(private = "file")
to_rl_button :: proc(b: ui.Mouse_Button) -> (rl.MouseButton, bool) {
    #partial switch b {
    case .Left:
        return .LEFT, true
    case .Right:
        return .RIGHT, true
    case .Middle:
        return .MIDDLE, true
    }
    return {}, false
}

mouse_down :: proc(b: ui.Mouse_Button) -> bool {
    rb, ok := to_rl_button(b)
    return ok && rl.IsMouseButtonDown(rb)
}

mouse_pressed :: proc(b: ui.Mouse_Button) -> bool {
    rb, ok := to_rl_button(b)
    return ok && rl.IsMouseButtonPressed(rb)
}

mouse_released :: proc(b: ui.Mouse_Button) -> bool {
    rb, ok := to_rl_button(b)
    return ok && rl.IsMouseButtonReleased(rb)
}
