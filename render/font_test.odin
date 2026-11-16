package render

import "core:testing"

import "../font"
import ui "../vendor/loom/loom"

@(test)
test_the_metrics_add_up_to_the_line_height :: proc(t: ^testing.T) {
    // Loom derives its line height from the three metrics, so the split has to
    // come back to what the font package reports, or every row drifts.
    for size in ([]f32{12, 14, 16, 24, 32}) {
        m   := font_metrics(DEFAULT_FONT, size, nil)
        got := m.ascent - m.descent + m.line_gap
        testing.expect_value(t, got, f32(font.line_height(i32(size))))
        testing.expect(t, m.descent < 0, "the descent hangs below the baseline")
    }
}

// The leading is split, so the em the glyphs are drawn in sits centred in the
// line box. Everything the editor lays out in rows relies on that, from a tab
// name to a titlebar icon.
@(test)
test_the_leading_is_shared_above_and_below_the_em :: proc(t: ^testing.T) {
    for size in ([]f32{12, 14, 16, 24, 32}) {
        m     := font_metrics(DEFAULT_FONT, size, nil)
        over  := m.ascent - size * ASCENT_FRACTION
        under := (m.ascent - m.descent) - size - over
        testing.expect_value(t, over, half_leading(size))
        testing.expect_value(t, under, over)
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

    // A style is a handle of its own over the same family.
    bold := register_family(&b, "mono", {.Bold})
    testing.expect(t, bold != mono, "a bold handle is not the regular one")
    testing.expect_value(t, family_of(&b, bold), "mono")
    testing.expect_value(t, style_of(&b, bold), font.Style{.Bold})
    testing.expect_value(t, style_of(&b, mono), font.Style{})
    testing.expect_value(t, register_family(&b, "mono", {.Bold}), bold)
}

@(test)
test_right_alt_is_alt_unless_it_is_alt_gr :: proc(t: ^testing.T) {
    // Windows reports AltGr as left Ctrl + right Alt.
    alt_gr := Mod_Keys{left_ctrl = true, right_alt = true}
    testing.expect_value(t, mods_from_keys(alt_gr, true), ui.Mod_Set{})
    testing.expect_value(t, mods_from_keys(alt_gr, false), ui.Mod_Set{.Ctrl, .Alt})

    testing.expect_value(t, mods_from_keys({right_alt = true}, false), ui.Mod_Set{.Alt})
    testing.expect_value(t, mods_from_keys({right_alt = true, shift = true}, true), ui.Mod_Set{.Shift})
    testing.expect_value(t, mods_from_keys({left_alt = true, right_alt = true}, true), ui.Mod_Set{.Alt})
    testing.expect_value(t, mods_from_keys({right_ctrl = true, super = true}, false), ui.Mod_Set{.Ctrl, .Super})

    b: Backend
    b.opts.right_alt = .Alt_Gr
    testing.expect(t, right_alt_is_alt_gr(&b), "the setting forces AltGr")
    b.opts.right_alt = .Alt
    testing.expect(t, !right_alt_is_alt_gr(&b), "the setting forces Alt")
}
