package render

import "core:unicode/utf8"
import rl "vendor:raylib"

import ui "../vendor/loom/loom"

// The layout-corrected key of a raylib key. `remap_key_to_layout` answers what
// the user's layout prints, so a binding follows the cap and not the position.
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

@(rodata)
BUTTONS := [?]struct {
	rb: rl.MouseButton,
	ub: ui.Mouse_Button,
}{{.LEFT, .Left}, {.RIGHT, .Right}, {.MIDDLE, .Middle}}

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

@(private)
hold_key :: proc(b: ^Backend, physical: rl.KeyboardKey, mapped: ui.Key) {
	for h in b.held {
		if h.physical == physical {
			return
		}
	}
	append(&b.held, Held_Key{physical = physical, mapped = mapped})
}

poll_input :: proc(b: ^Backend) -> ui.Input {
	scale := rl.GetWindowScaleDPI()
	b.dpi = b.opts.dpi > 0 ? b.opts.dpi : scale.x

	pos := rl.GetWindowPosition()
	out := ui.Input {
		dt         = rl.GetFrameTime(),
		viewport   = {f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
		window_pos = {pos.x, pos.y},
		dpi        = b.dpi,
		mouse      = ui.Vec2(rl.GetMousePosition()),
		wheel      = ui.Vec2(rl.GetMouseWheelMoveV()),
	}

	// AltGr types { } @ on a non-US layout and must never act as a shortcut
	// modifier. Windows also reports it as left Ctrl, so Ctrl is suppressed
	// while it is held. The modifiers come first, so every event carries them.
	alt_gr := rl.IsKeyDown(.RIGHT_ALT)
	if (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) && !alt_gr {
		out.mods += {.Ctrl}
	}
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
		out.mods += {.Shift}
	}
	if rl.IsKeyDown(.LEFT_ALT) {
		out.mods += {.Alt}
	}
	if rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) {
		out.mods += {.Super}
	}

	for pair in BUTTONS {
		if rl.IsMouseButtonDown(pair.rb) {
			out.mouse_down += {pair.ub}
		}
		if rl.IsMouseButtonPressed(pair.rb) {
			out.mouse_pressed += {pair.ub}
		}
		if rl.IsMouseButtonReleased(pair.rb) {
			out.mouse_released += {pair.ub}
		}
	}

	clear(&b.key_evs)

	for {
		key := rl.GetKeyPressed()
		if key == rl.KeyboardKey(0) {
			break
		}
		mapped := ui_key(remap_key_to_layout(key))
		if mapped == .None {
			continue
		}
		hold_key(b, key, mapped)
		append(&b.key_evs, ui.Key_Event{key = mapped, mods = out.mods, action = .Press})
	}

	// GetKeyPressed reports the first press only, and raylib keeps no queue of
	// repeats or releases, so both are polled per held key.
	#reverse for held, index in b.held {
		if rl.IsKeyUp(held.physical) {
			append(
				&b.key_evs,
				ui.Key_Event{key = held.mapped, mods = out.mods, action = .Release},
			)
			unordered_remove(&b.held, index)
			continue
		}
		if !is_modifier_key(held.physical) && rl.IsKeyPressedRepeat(held.physical) {
			append(
				&b.key_evs,
				ui.Key_Event{key = held.mapped, mods = out.mods, action = .Repeat},
			)
		}
		out.keys_down += {held.mapped}
	}
	out.key_events = b.key_evs[:]

	b.text_len = 0
	for {
		r := rl.GetCharPressed()
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
