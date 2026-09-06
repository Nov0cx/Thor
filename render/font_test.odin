package render

import "core:testing"
import rl "vendor:raylib"

import "../font"
import ui "../vendor/loom/loom"

@(test)
test_the_metrics_add_up_to_the_line_height :: proc(t: ^testing.T) {
	// Loom derives its line height from the three metrics, so the split has to
	// come back to what the font package reports, or every row drifts.
	for size in ([]f32{12, 14, 16, 24, 32}) {
		m := font_metrics(DEFAULT_FONT, size, nil)
		got := m.ascent - m.descent + m.line_gap
		testing.expect_value(t, got, f32(font.line_height(i32(size))))
		testing.expect(t, m.descent < 0, "the descent hangs below the baseline")
	}
}

@(test)
test_a_zero_size_has_no_metrics :: proc(t: ^testing.T) {
	testing.expect_value(t, font_metrics(DEFAULT_FONT, 0, nil), ui.Font_Metrics{})
}

@(test)
test_a_family_handle_round_trips :: proc(t: ^testing.T) {
	b: Backend
	init(&b)
	defer destroy(&b)

	mono := register_family(&b, "mono")
	sans := register_family(&b, "sans")
	testing.expect(t, mono != sans, "two families get two handles")
	testing.expect_value(t, family_of(&b, mono), "mono")
	testing.expect_value(t, family_of(&b, sans), "sans")

	// A family registers once, however often it is asked for.
	testing.expect_value(t, register_family(&b, "mono"), mono)
	// An unregistered handle falls back to the default family.
	testing.expect_value(t, family_of(&b, DEFAULT_FONT), "")
	testing.expect_value(t, family_of(&b, ui.Font(99)), "")
}

@(test)
test_the_key_table_maps_both_ways :: proc(t: ^testing.T) {
	testing.expect_value(t, ui_key(.F5), ui.Key.F5)
	testing.expect_value(t, ui_key(.SEMICOLON), ui.Key.Semicolon)
	testing.expect_value(t, ui_key(.KP_ENTER), ui.Key.Enter)
	testing.expect_value(t, ui_key(.KP_5), ui.Key.Pad_5)
	// A key raylib knows and Loom does not is dropped, never mapped to a wrong
	// one, so a binding cannot fire by accident.
	testing.expect_value(t, ui_key(.KEY_NULL), ui.Key.None)

	testing.expect(t, is_modifier_key(.LEFT_CONTROL), "ctrl is a modifier")
	testing.expect(t, is_modifier_key(.RIGHT_ALT), "altgr is a modifier")
	testing.expect(t, !is_modifier_key(.A), "a letter is not")
}

@(test)
test_every_mapped_key_is_distinct :: proc(t: ^testing.T) {
	// Two raylib keys may share one Loom key on purpose, but a raylib key must
	// never appear twice, or its release fires against a stale mapping.
	for a, i in KEYS {
		for b, j in KEYS {
			if i >= j {
				continue
			}
			testing.expect(t, a.rk != b.rk, "a raylib key is listed once")
		}
	}
}

@(test)
test_a_colour_round_trips :: proc(t: ^testing.T) {
	testing.expect_value(t, raylib_color(ui.Color{12, 34, 56, 78}), rl.Color{12, 34, 56, 78})
	testing.expect_value(t, raylib_rect(ui.Rect{1, 2, 3, 4}), rl.Rectangle{1, 2, 3, 4})
}
