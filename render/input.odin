package render

import "core:unicode/utf8"

import "../platform"
import "../prof"
import ui "../vendor/loom/loom"

// The modifier keys held in one frame.
Mod_Keys :: struct {
    left_ctrl:  bool,
    right_ctrl: bool,
    left_alt:   bool,
    right_alt:  bool,
    shift:      bool,
    super:      bool,
}

// The modifier set of a frame. `alt_gr` says the held Right Alt is AltGr: it
// types { } @ and is no shortcut modifier. Windows reports AltGr with a left
// Ctrl of its own, so Ctrl is dropped with it.
mods_from_keys :: proc(k: Mod_Keys, alt_gr: bool) -> ui.Mod_Set {
    mods: ui.Mod_Set
    if (k.left_ctrl || k.right_ctrl) && !alt_gr {
        mods += {.Ctrl}
    }
    if k.shift {
        mods += {.Shift}
    }
    if k.left_alt || (k.right_alt && !alt_gr) {
        mods += {.Alt}
    }
    if k.super {
        mods += {.Super}
    }
    return mods
}

@(private)
hold_key :: proc(b: ^Backend, physical: platform.Scancode, mapped: ui.Key) {
    for h in b.held {
        if h.physical == physical {
            return
        }
    }
    append(&b.held, Held_Key{physical = physical, mapped = mapped})
}

poll_input :: proc(b: ^Backend) -> ui.Input {
    prof.proc_scope()
    scale := platform.window_dpi_scale()
    b.dpi = b.opts.dpi > 0 ? b.opts.dpi : scale.x

    // Measured here, not by raylib, which counts a frame only when it is drawn.
    now := platform.time()
    dt  := b.last_poll > 0 ? f32(now - b.last_poll) : platform.frame_time()
    b.last_poll = now

    pos := platform.window_position()
    out := ui.Input{
        dt = dt,
        viewport = {f32(platform.window_size().x), f32(platform.window_size().y)},
        window_pos = {pos.x, pos.y},
        dpi = b.dpi,
        mouse = ui.Vec2(platform.mouse_position()),
        // raylib counts a wheel rolled away from the hand as positive; Loom
        // counts a scroll down as positive. They are opposite.
        wheel = -ui.Vec2(platform.mouse_wheel()),
    }

    // The modifiers come first, so every event carries them.
    down := platform.modifiers_down()
    keys := Mod_Keys{
        left_ctrl = .Left_Ctrl in down,
        right_ctrl = .Right_Ctrl in down,
        left_alt = .Left_Alt in down,
        right_alt = .Right_Alt in down,
        shift = .Left_Shift in down || .Right_Shift in down,
        super = .Left_Super in down || .Right_Super in down,
    }
    out.mods = mods_from_keys(keys, keys.right_alt && right_alt_is_alt_gr(b))

    for button in ui.Mouse_Button {
        if platform.mouse_down(button) {
            out.mouse_down += {button}
        }
        if platform.mouse_pressed(button) {
            out.mouse_pressed += {button}
        }
        if platform.mouse_released(button) {
            out.mouse_released += {button}
        }
    }

    clear(&b.key_evs)

    for {
        press, ok := platform.next_key_press()
        if !ok {
            break
        }
        hold_key(b, press.physical, press.key)
        append(&b.key_evs, ui.Key_Event{key = press.key, mods = out.mods, action = .Press})
    }

    // GetKeyPressed reports the first press only, and raylib keeps no queue of
    // repeats or releases, so both are polled per held key.
    #reverse for held, index in b.held {
        if platform.key_up(held.physical) {
            append(&b.key_evs, ui.Key_Event{key = held.mapped, mods = out.mods, action = .Release})
            unordered_remove(&b.held, index)
            continue
        }
        if !platform.key_is_modifier(held.physical) && platform.key_repeated(held.physical) {
            append(&b.key_evs, ui.Key_Event{key = held.mapped, mods = out.mods, action = .Repeat})
        }
        out.keys_down += {held.mapped}
    }
    out.key_events = b.key_evs[:]

    b.text_len = 0
    for {
        r := platform.next_char()
        if r == 0 {
            break
        }
        bytes, n := utf8.encode_rune(r)
        if b.text_len + n > len(b.text_buf) {
            break
        }
        copy(b.text_buf[b.text_len:], bytes[:n])
        b.text_len += n
    }
    out.text = string(b.text_buf[:b.text_len])

    return out
}
