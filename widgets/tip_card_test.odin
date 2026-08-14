package widgets

import "core:testing"
import rl "vendor:raylib"

// Run from the repository root: odin test widgets
// Geometry only — nothing here measures text, so no font is needed.

@(private = "file")
tip_close_noop :: proc(_: rawptr, _: bool) {}

// The close box is only on a card that can be closed, and the arrows step aside
// for it instead of drawing under it.
@(test)
test_tip_card_header_controls :: proc(t: ^testing.T) {
    card := tip_card_create("test-tip")
    defer tip_card_destroy(&card.widget)
    card.bounds = rl.Rectangle {0, 0, 380, 200}
    tip_card_set_tip(card, "Title", "Body", "ctrl + p", 0, 4)

    testing.expect_value(t, tip_card_close_rect(card).width, 0)
    plain_previous, plain_next := tip_card_arrow_rects(card)
    testing.expect(t, plain_next.x > plain_previous.x, "the next arrow is right of the previous one")

    tip_card_set_on_close(card, tip_close_noop, nil)
    close := tip_card_close_rect(card)
    testing.expect(t, close.width > 0, "a closable card has no close box")

    previous, next := tip_card_arrow_rects(card)
    testing.expect(t, next.x + next.width <= close.x, "the next arrow overlaps the close box")
    testing.expect(t, previous.x + previous.width <= next.x, "the arrows overlap")
}

// One tip of one is not worth stepping through, so the arrows go and the close
// box stays where it is.
@(test)
test_tip_card_single_tip_hides_arrows :: proc(t: ^testing.T) {
    card := tip_card_create("test-tip-single")
    defer tip_card_destroy(&card.widget)
    card.bounds = rl.Rectangle {0, 0, 380, 200}
    tip_card_set_on_close(card, tip_close_noop, nil)
    tip_card_set_tip(card, "Title", "Body", "", 0, 1)

    previous, next := tip_card_arrow_rects(card)
    testing.expect_value(t, previous.width, 0)
    testing.expect_value(t, next.width, 0)
    testing.expect(t, tip_card_close_rect(card).width > 0, "the close box went with the arrows")
}
