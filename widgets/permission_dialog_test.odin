package widgets

import "core:testing"
import rl "vendor:raylib"

import "../ui"

@(private = "file")
Counters :: struct {
    allowed:   int,
    cancelled: int,
}

@(private = "file")
count_allow :: proc(data: rawptr) {
    (cast(^Counters) data).allowed += 1
}

@(private = "file")
count_cancel :: proc(data: rawptr) {
    (cast(^Counters) data).cancelled += 1
}

@(private = "file")
press :: proc(dialog: ^Permission_Dialog, ctx: ^ui.Context, key: rl.KeyboardKey) {
    event := ui.Event {kind = .Key_Press, key = key}
    permission_dialog_handle_event(&dialog.widget, ctx, &event)
}

// A window big enough that the row count is what limits the box.
@(private = "file")
TALL_WINDOW :: rl.Rectangle {0, 0, 1280, 800}

@(private = "file")
open_ids :: proc(dialog: ^Permission_Dialog, ctx: ^ui.Context, count: int, counters: ^Counters) {
    ids := make([dynamic]string, context.temp_allocator)
    perms := make([dynamic]string, context.temp_allocator)
    for i in 0 ..< count {
        append(&ids, "plugin")
        append(&perms, "exec, read, write, ui")
    }
    permission_dialog_open(
        dialog, ctx, "Allow these plugins?", "Change later in Settings.",
        ids[:], perms[:], count_allow, count_cancel, counters,
    )
}

// The requests the rows come from are freed inside the answer callbacks, so the
// dialog has to hold copies, and reopening has to free the previous set rather
// than leak or keep stale rows.
@(test)
test_permission_dialog_owns_its_rows :: proc(t: ^testing.T) {
    dialog := permission_dialog_create("permissions")
    defer permission_dialog_destroy(&dialog.widget)

    ctx: ui.Context
    counters: Counters

    ids := [?]string {"git", "tutorial"}
    perms := [?]string {"exec, ui", "read, write, ui, keys, tick"}
    permission_dialog_open(
        dialog, &ctx, "Allow these plugins?", "Change later in Settings.",
        ids[:], perms[:], count_allow, count_cancel, &counters,
    )

    testing.expect(t, permission_dialog_is_open(dialog), "the prompt is up")
    testing.expectf(t, len(dialog.items) == 2, "expected 2 rows, got %d", len(dialog.items))
    testing.expectf(t, dialog.items[0].id == "git", "expected \"git\", got %q", dialog.items[0].id)
    testing.expectf(
        t, dialog.items[1].perms == "read, write, ui, keys, tick",
        "expected the full permission set, got %q", dialog.items[1].perms,
    )
    // Copies, not the caller's memory.
    testing.expect(t, raw_data(dialog.items[0].id) != raw_data(ids[0]), "the id is copied")

    // Reopening replaces the previous rows.
    shorter := [?]string {"git"}
    shorter_perms := [?]string {"exec, ui"}
    permission_dialog_open(
        dialog, &ctx, "Allow these plugins?", "Change later in Settings.",
        shorter[:], shorter_perms[:], count_allow, count_cancel, &counters,
    )
    testing.expectf(t, len(dialog.items) == 1, "expected the rows replaced, got %d", len(dialog.items))
}

// A plugin with no permissions still needs a row, and a perms slice shorter than
// the ids must not read past its end.
@(test)
test_permission_dialog_tolerates_short_perms :: proc(t: ^testing.T) {
    dialog := permission_dialog_create("permissions")
    defer permission_dialog_destroy(&dialog.widget)

    ctx: ui.Context
    counters: Counters

    ids := [?]string {"a", "b", "c"}
    perms := [?]string {"exec"}
    permission_dialog_open(
        dialog, &ctx, "Allow these plugins?", "", ids[:], perms[:], count_allow, count_cancel, &counters,
    )

    testing.expectf(t, len(dialog.items) == 3, "every id gets a row, got %d", len(dialog.items))
    testing.expectf(t, dialog.items[2].perms == "", "a missing entry reads empty, got %q", dialog.items[2].perms)
}

// The reported bug was a box that never grew or scrolled. The row count caps the
// box, and a short window takes rows away rather than growing past the screen.
@(test)
test_permission_dialog_row_count_fits_the_window :: proc(t: ^testing.T) {
    dialog := permission_dialog_create("permissions")
    defer permission_dialog_destroy(&dialog.widget)

    ctx: ui.Context
    counters: Counters
    open_ids(dialog, &ctx, 20, &counters)

    permission_dialog_layout(&dialog.widget, TALL_WINDOW)
    testing.expectf(
        t, dialog.visible_rows == dialog.max_rows,
        "20 rows fill the cap of %d, got %d", dialog.max_rows, dialog.visible_rows,
    )
    testing.expect(
        t, dialog.box.height <= TALL_WINDOW.height, "the box stays inside the window",
    )

    // Fewer rows than the cap shrink the box instead of leaving it padded out.
    open_ids(dialog, &ctx, 3, &counters)
    permission_dialog_layout(&dialog.widget, TALL_WINDOW)
    testing.expectf(t, dialog.visible_rows == 3, "expected 3 rows, got %d", dialog.visible_rows)

    // A window with no room for the full list keeps at least one row and still
    // fits, which is what the old fixed 54 px box could not do.
    short := rl.Rectangle {0, 0, 1280, 260}
    open_ids(dialog, &ctx, 20, &counters)
    permission_dialog_layout(&dialog.widget, short)
    testing.expectf(t, dialog.visible_rows >= 1, "always at least one row, got %d", dialog.visible_rows)
    testing.expectf(
        t, dialog.visible_rows < dialog.max_rows,
        "a short window drops rows, got %d", dialog.visible_rows,
    )
}

@(test)
test_permission_dialog_scroll_clamps :: proc(t: ^testing.T) {
    dialog := permission_dialog_create("permissions")
    defer permission_dialog_destroy(&dialog.widget)

    ctx: ui.Context
    counters: Counters
    open_ids(dialog, &ctx, 20, &counters)
    permission_dialog_layout(&dialog.widget, TALL_WINDOW)

    testing.expectf(t, dialog.scroll == 0, "a fresh prompt starts at the top, got %d", dialog.scroll)

    press(dialog, &ctx, .UP)
    testing.expectf(t, dialog.scroll == 0, "the top does not go negative, got %d", dialog.scroll)

    press(dialog, &ctx, .END)
    expected := 20 - dialog.visible_rows
    testing.expectf(
        t, dialog.scroll == expected, "the end stops at %d, got %d", expected, dialog.scroll,
    )

    press(dialog, &ctx, .DOWN)
    testing.expectf(t, dialog.scroll == expected, "the end does not overrun, got %d", dialog.scroll)

    press(dialog, &ctx, .HOME)
    testing.expectf(t, dialog.scroll == 0, "home returns to the top, got %d", dialog.scroll)

    // A list that fits has nowhere to scroll.
    open_ids(dialog, &ctx, 3, &counters)
    permission_dialog_layout(&dialog.widget, TALL_WINDOW)
    press(dialog, &ctx, .END)
    testing.expectf(t, dialog.scroll == 0, "a list that fits never scrolls, got %d", dialog.scroll)
}

// Confirming must not also fire the dismissal hook: that one leaves the plugins
// unloaded, so firing both would unload what was just granted.
@(test)
test_permission_dialog_allow_does_not_cancel :: proc(t: ^testing.T) {
    dialog := permission_dialog_create("permissions")
    defer permission_dialog_destroy(&dialog.widget)

    ctx: ui.Context
    counters: Counters
    open_ids(dialog, &ctx, 2, &counters)

    press(dialog, &ctx, .ENTER)
    testing.expectf(t, counters.allowed == 1, "allow fires once, got %d", counters.allowed)
    testing.expectf(t, counters.cancelled == 0, "allow does not cancel, got %d", counters.cancelled)
    testing.expect(t, !permission_dialog_is_open(dialog), "answering closes the prompt")

    // A closed prompt ignores further keys, so the answer cannot be doubled.
    press(dialog, &ctx, .ENTER)
    press(dialog, &ctx, .ESCAPE)
    testing.expectf(t, counters.allowed == 1, "a closed prompt stays answered, got %d", counters.allowed)
    testing.expectf(t, counters.cancelled == 0, "a closed prompt does not cancel, got %d", counters.cancelled)
}

@(test)
test_permission_dialog_escape_cancels :: proc(t: ^testing.T) {
    dialog := permission_dialog_create("permissions")
    defer permission_dialog_destroy(&dialog.widget)

    ctx: ui.Context
    counters: Counters
    open_ids(dialog, &ctx, 2, &counters)

    press(dialog, &ctx, .ESCAPE)
    testing.expectf(t, counters.cancelled == 1, "escape cancels once, got %d", counters.cancelled)
    testing.expectf(t, counters.allowed == 0, "escape does not allow, got %d", counters.allowed)
    testing.expect(t, !permission_dialog_is_open(dialog), "escape closes the prompt")
}

// The prompt is modal: nothing underneath may act on an event while it is up.
@(test)
test_permission_dialog_blocks_input_underneath :: proc(t: ^testing.T) {
    dialog := permission_dialog_create("permissions")
    defer permission_dialog_destroy(&dialog.widget)

    ctx: ui.Context
    counters: Counters

    event := ui.Event {kind = .Key_Press, key = .A}
    testing.expect(
        t, !permission_dialog_handle_event(&dialog.widget, &ctx, &event),
        "a closed prompt lets events through",
    )

    open_ids(dialog, &ctx, 1, &counters)
    testing.expect(
        t, permission_dialog_handle_event(&dialog.widget, &ctx, &event),
        "an open prompt swallows the event",
    )
}
