package thor

// The tip of the day. The tips themselves come from the layered tips.json
// (setting.Settings.tips); this side only picks which one to show and when the
// pick moves on.
//
// Which day it last showed and where in the list it stopped go to
// sessions/tips.json — machine state, not a preference, so they sit beside the
// other session records instead of in settings.json.

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

import "../setting"
import "../widgets"

@(private = "file")
TIPS_FILE :: "sessions/tips.json"

// Seconds in a day. The record counts days, so a run inside the same day gets
// the same tip however often it starts.
@(private = "file")
SECONDS_PER_DAY :: i64(24 * 60 * 60)

// What a previous run left: the day it last moved the pick on (unix days),
// where in the tip list it stopped, and the day the card over the editor last
// opened by itself.
@(private = "file")
Tips_Record :: struct {
    last_day:  i64,
    index:     int,
    popup_day: i64,
}

// Today in the unix days the record counts.
@(private = "file")
thor_tip_today :: proc() -> i64 {
    return time.to_unix_seconds(time.now()) / SECONDS_PER_DAY
}

// The tip the cards show, and where it sits in the list. `ok` is false when no
// config layer holds a tip, which hides the card.
thor_tip_of_the_day :: proc(thor: ^Thor) -> (tip: setting.Tip, index: int, ok: bool) {
    count := len(thor.config.tips)
    if count == 0 {
        return {}, 0, false
    }

    record := thor_read_tips_record()
    day := thor_tip_today()
    if next, moved := thor_tip_index_for_day(record.last_day, day, record.index, count); moved {
        record.index = next
        record.last_day = day
        thor_write_tips_record(record)
    }

    index = thor_wrap_tip(record.index, count)
    return thor.config.tips[index], index, true
}

// The tip index for `day`: what the record holds while the day is the one it
// was written on, one further along on any other day. `moved` says the record
// has to be written back. A clock that moved backwards counts as another day
// too, so the pick can never park on one tip.
thor_tip_index_for_day :: proc(record_day, day: i64, index, count: int) -> (next: int, moved: bool) {
    if record_day == day {
        return thor_wrap_tip(index, count), false
    }
    return thor_wrap_tip(index + 1, count), true
}

// The arrows on the card. Moves the pick without touching the day, so browsing
// the list does not spend tomorrow's tip.
thor_tip_step :: proc(thor: ^Thor, delta: int) {
    count := len(thor.config.tips)
    if count == 0 {
        return
    }
    record := thor_read_tips_record()
    record.index = thor_wrap_tip(record.index + delta, count)
    thor_write_tips_record(record)
    thor_refresh_tip_cards(thor)
}

// Tip_Step_Proc: the card's previous and next arrows.
thor_tip_card_step :: proc(data: rawptr, delta: int) {
    thor_tip_step(cast(^Thor) data, delta)
}

// `index` inside [0, count), for a step off either end and for a record left by
// a longer tip list. Odin's % keeps the sign of the dividend, so a negative
// index needs the second fold.
thor_wrap_tip :: proc(index, count: int) -> int {
    if count <= 0 {
        return 0
    }
    wrapped := index % count
    if wrapped < 0 {
        wrapped += count
    }
    return wrapped
}

// Fills both cards from the current tip, with the chord of the action the tip
// names resolved against the keybinds in force — so a rebind shows the new
// chord. Hides them when tips are off or there is no tip to show; a hidden
// floating card is only ever shown again by thor_tip_open_startup.
thor_refresh_tip_cards :: proc(thor: ^Thor) {
    tip, index, ok := thor_tip_of_the_day(thor)
    ok = ok && setting.tip_of_the_day(&thor.config)

    if card := thor.welcome_tip_card; card != nil {
        card.visible = ok
    }
    if card := thor.startup_tip_card; card != nil && !ok {
        card.visible = false
    }
    if !ok {
        return
    }

    shortcut := thor_action_shortcut(thor, tip.action)
    for card in ([]^widgets.Tip_Card{thor.welcome_tip_card, thor.startup_tip_card}) {
        if card == nil {
            continue
        }
        widgets.tip_card_set_tip(card, tip.title, tip.body, shortcut, index, len(thor.config.tips))
    }
}

// Opens the floating card, once for each day the editor is started on with a
// workspace open — the welcome page, which carries its own card, is not shown
// then. The day it last opened on lives in the record beside the pick, so every
// window of that day stays quiet.
thor_tip_open_startup :: proc(thor: ^Thor) {
    card := thor.startup_tip_card
    if card == nil || thor.workspace_dir == "" || !setting.tip_of_the_day(&thor.config) {
        return
    }

    day := thor_tip_today()
    if !thor_tip_popup_due(thor_read_tips_record().popup_day, day) {
        return
    }
    if _, _, ok := thor_tip_of_the_day(thor); !ok {
        return
    }

    // Re-read: the pick above writes the record when the day moved on.
    record := thor_read_tips_record()
    record.popup_day = day
    thor_write_tips_record(record)

    thor_refresh_tip_cards(thor)
    card.visible = true
}

// Whether the floating card is due on `day`. Any day other than the one it last
// opened on, so a clock that moved backwards opens it too.
thor_tip_popup_due :: proc(popup_day, day: i64) -> bool {
    return popup_day != day
}

// Tip_Close_Proc: the card's close box, and the line that turns tips off for
// good. That answer is the user's own, not the workspace's, so it goes to
// user/settings.json and not to whichever file the Settings modal is on.
thor_tip_card_close :: proc(data: rawptr, never_again: bool) {
    thor := cast(^Thor) data
    thor.startup_tip_card.visible = false
    if !never_again {
        return
    }
    path := strings.concatenate({setting.USER_DIR, "/settings.json"}, context.temp_allocator)
    if !setting.persist_bool(path, "tip_of_the_day", false) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }
    thor_reload_settings(thor)
}

// Escape closes the floating card. The global key hook runs before focus
// dispatch, so this only acts while no overlay owns the keyboard — else it would
// take the Escape that closes the palette or the find bar.
thor_tip_close_on_escape :: proc(thor: ^Thor) -> bool {
    card := thor.startup_tip_card
    if card == nil || !card.visible {
        return false
    }
    if widgets.command_palette_is_open(thor.command_palette) ||
       widgets.find_replace_is_open(thor.find_replace) ||
       widgets.select_dialog_is_open(thor.select_dialog) ||
       widgets.menu_is_open(thor.menu) {
        return false
    }
    card.visible = false
    return true
}

@(private = "file")
thor_read_tips_record :: proc() -> (record: Tips_Record) {
    data, err := os.read_entire_file(TIPS_FILE, context.temp_allocator)
    if err != nil {
        return
    }
    if uerr := json.unmarshal(data, &record, allocator = context.temp_allocator); uerr != nil {
        log.warnf("Could not read %q: %v", TIPS_FILE, uerr)
        return {}
    }
    return record
}

@(private = "file")
thor_write_tips_record :: proc(record: Tips_Record) {
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }
    data, err := json.marshal(record, {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal the tips record: %v", err)
        return
    }
    if werr := os.write_entire_file(TIPS_FILE, data); werr != nil {
        log.errorf("Could not write %q: %v", TIPS_FILE, werr)
    }
}
