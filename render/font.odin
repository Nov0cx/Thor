package render

import "core:unicode/utf8"
import rl "vendor:raylib"

import "../font"
import ui "../vendor/loom/loom"

// Loom names a font by handle; the font package names one by family, so a
// handle is an index into the families this backend has registered. Handle 0
// and any handle out of range mean the default family.
DEFAULT_FONT :: ui.Font(0)

// The font package reports one line height and no vertical metrics, so the
// split below is the convention the whole editor draws by: the baseline sits
// four fifths down the em, and the leading the line height carries over the em
// is shared evenly above and below it. Splitting the leading is what centres a
// line of text in its own box, so a label in a row needs no alignment of its own.
ASCENT_FRACTION :: f32(0.8)

// Half the leading of one line: the gap between the top of a row and the top of
// the em its glyphs are drawn in. Anything painted against the glyphs rather
// than against the row adds it.
half_leading :: proc(size: f32) -> f32 {
	if size <= 0 {
		return 0
	}
	return (f32(font.line_height(i32(size))) - size) * 0.5
}

// Registers `name` and reports the handle that addresses it.
register_family :: proc(b: ^Backend, name: string) -> ui.Font {
	for f, i in b.families {
		if f == name {
			return ui.Font(i + 1)
		}
	}
	append(&b.families, name)
	return ui.Font(len(b.families))
}

@(private)
family_of :: proc(b: ^Backend, h: ui.Font) -> string {
	i := int(h) - 1
	if i < 0 || i >= len(b.families) {
		return ""
	}
	return b.families[i]
}

font_metrics :: proc(f: ui.Font, size: f32, user: rawptr) -> ui.Font_Metrics {
	if size <= 0 {
		return {}
	}
	leading := half_leading(size)
	ascent := size * ASCENT_FRACTION + leading
	return {
		ascent = ascent,
		// Negative, as Loom expects. The ink spans the whole line height, half
		// the leading over the em and half under it, so ascent - descent is what
		// the font package reports and no gap is left to place.
		descent = ascent - size - leading * 2,
		line_gap = 0,
	}
}

measure_run :: proc(f: ui.Font, size: f32, text: string, spacing: f32, user: rawptr) -> f32 {
	if text == "" || size <= 0 {
		return 0
	}
	b := (^Backend)(user)
	return f32(font.measure(text, i32(size), family_of(b, f)))
}

// A prefix width from the shaped-line cache, which is both cheaper and right
// across a ligature, where measuring the prefix on its own is not.
offset_x :: proc(
	f: ui.Font,
	size: f32,
	text: string,
	spacing, tab_origin: f32,
	at: int,
	user: rawptr,
) -> f32 {
	if at <= 0 || size <= 0 {
		return 0
	}
	b := (^Backend)(user)
	i := min(at, len(text))
	return f32(font.measure(text[:i], i32(size), family_of(b, f), i32(tab_origin)))
}

// The rune boundary nearest `x`, rounded to whichever side the pointer is
// closer to, so a click past the middle of a glyph lands after it.
index_at :: proc(
	f: ui.Font,
	size: f32,
	text: string,
	spacing, tab_origin, x: f32,
	user: rawptr,
) -> int {
	if len(text) == 0 || x <= 0 || size <= 0 {
		return 0
	}

	b := (^Backend)(user)
	family := family_of(b, f)
	px := i32(size)
	org := i32(tab_origin)

	prev, prev_w := 0, f32(0)
	i := 0
	for i < len(text) {
		_, n := utf8.decode_rune_in_string(text[i:])
		if n <= 0 {
			n = 1
		}
		i += n
		w := f32(font.measure(text[:i], px, family, org))
		if w >= x {
			return x - prev_w > w - x ? i : prev
		}
		prev, prev_w = i, w
	}
	return len(text)
}

set_cursor :: proc(c: ui.Cursor, user: rawptr) {
	b := (^Backend)(user)
	if b.cursor == c {
		return
	}
	b.cursor = c

	shape: rl.MouseCursor
	switch c {
	case .Default:
		shape = .DEFAULT
	case .Pointer:
		shape = .POINTING_HAND
	case .Text:
		shape = .IBEAM
	case .Resize_H:
		shape = .RESIZE_EW
	case .Resize_V:
		shape = .RESIZE_NS
	case .Grab:
		shape = .POINTING_HAND
	case .Grabbing:
		shape = .RESIZE_ALL
	case .Not_Allowed:
		shape = .NOT_ALLOWED
	}
	rl.SetMouseCursor(shape)
}

clipboard_get :: proc(user: rawptr) -> string {
	return string(rl.GetClipboardText())
}

clipboard_set :: proc(text: string, user: rawptr) {
	b := (^Backend)(user)
	rl.SetClipboardText(cstr(b, text))
}
