package thor

// The tip of the day. The tips themselves come from the layered tips.json
// (setting.Settings.tips); this side only picks which one to show and when the
// pick moves on.
//
// Which day it last showed and where in the list it stopped go to
// sessions/tips.json — machine state, not a preference, so they sit beside the
// other session records instead of in settings.json.

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

import "../setting"

import ui "../vendor/loom/loom"

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

// The tip both cards show: the pick, its position in the list, and the chord of
// the action it names resolved against the keybinds in force. `ok` is false when
// tips are off or no config layer holds one, which hides the cards.
thor_tip_current :: proc(
    thor: ^Thor,
) -> (
    tip: setting.Tip,
    index, count: int,
    shortcut: string,
    ok: bool,
) {
    tip, index, ok = thor_tip_of_the_day(thor)
    ok = ok && setting.tip_of_the_day(&thor.config)
    if !ok {
        return {}, 0, 0, "", false
    }
    return tip, index, len(thor.config.tips), thor_action_shortcut(thor, tip.action), true
}

// Closes the floating card when the tip it shows went away.
thor_refresh_tip_cards :: proc(thor: ^Thor) {
    if _, _, _, _, ok := thor_tip_current(thor); !ok {
        thor.tip_open = false
    }
}

// Opens the floating card, once for each day the editor is started on with a
// workspace open — the welcome page, which carries its own card, is not shown
// then. The day it last opened on lives in the record beside the pick, so every
// window of that day stays quiet.
thor_tip_open_startup :: proc(thor: ^Thor) {
    if thor.workspace_dir == "" || !setting.tip_of_the_day(&thor.config) {
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

    thor.tip_open = true
}

// Whether the floating card is due on `day`. Any day other than the one it last
// opened on, so a clock that moved backwards opens it too.
thor_tip_popup_due :: proc(popup_day, day: i64) -> bool {
    return popup_day != day
}

// The card's close box, and the line that turns tips off for good. That answer
// is the user's own, not the workspace's, so it goes to user/settings.json and
// not to whichever file the Settings modal is on.
thor_tip_card_close :: proc(thor: ^Thor, never_again: bool) {
    thor.tip_open = false
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
    if !thor.tip_open {
        return false
    }
    if thor_palette_is_open(thor) ||
       thor.find_open ||
       thor_select_is_open(thor) ||
       thor_menu_is_open(thor) {
        return false
    }
    thor.tip_open = false
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

// ---- the view ---------------------------------------------------------------------

TIP_CARD_WIDTH :: f32(420)

// The floating card over the editor. The welcome page shows the same tip inline
// through thor_tip_card_body.
thor_tip_card_view :: proc(thor: ^Thor) {
    if !thor.tip_open {
        return
    }
    tip, index, count, shortcut, ok := thor_tip_current(thor)
    if !ok {
        thor.tip_open = false
        return
    }

    ui.scope(
        {
            key = "tip-card",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {r = 24, b = 24},
                w = ui.Px(TIP_CARD_WIDTH),
                max_w = ui.viewport().x - 48,
                h = ui.FIT,
                dir = .Column,
                pad = ui.all(14),
                gap = {0, 8},
                z = 300,
                bg = thor.theme.second_background,
                radius = ui.rad(8),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 6}, blur = 24, color = thor.theme.contrast},
            },
        },
    )

    thor_tip_card_body(thor, tip, index, count, shortcut, closable = true)
}

// Title, body, chord and the footer, shared by the floating card and the welcome
// page. `closable` adds the close box and the "never show again" line.
thor_tip_card_body :: proc(
    thor: ^Thor,
    tip: setting.Tip,
    index, count: int,
    shortcut: string,
    closable: bool,
) {
    {
        ui.scope(
            {
                key = "head",
                props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {8, 0}},
            },
        )
        thor_icon_label(thor, "bulb", thor.theme.accent_color)
        ui.label(
            tip.title,
            {key = "title", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis}},
        )
        if closable {
            close := ui.scope(
                {
                    key = "close",
                    flags = {.Clickable},
                    props = {
                        w = ui.Px(22),
                        h = ui.Px(22),
                        dir = .Row,
                        justify = .Center,
                        align = .Center,
                        radius = ui.rad(4),
                        cursor = .Pointer,
                    },
                    hover = {bg = thor.theme.buttons},
                },
            )
            thor_icon_label(thor, "x", thor.theme.muted_color, 14)
            if close.clicked {
                thor_tip_card_close(thor, false)
                return
            }
        }
    }

    ui.label(
        tip.body,
        {key = "body", props = {w = ui.Grow(1), color = thor.theme.muted_color, text_wrap = .Words}},
    )
    if shortcut != "" {
        ui.label(
            shortcut,
            {
                key = "chord",
                props = {
                    pad = ui.xy(8, 3),
                    radius = ui.rad(4),
                    bg = thor.theme.buttons,
                    color = thor.theme.accent_color,
                    text_wrap = .None,
                },
            },
        )
    }

    {
        ui.scope(
            {
                key = "foot",
                props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {6, 0}},
            },
        )
        if closable {
            never := ui.scope(
                {
                    key = "never",
                    flags = {.Clickable},
                    props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, cursor = .Pointer},
                },
            )
            ui.label(
                "Do not show tips again",
                {key = "text", props = {color = thor.theme.disabled, text_wrap = .None}},
            )
            if never.clicked {
                thor_tip_card_close(thor, true)
                return
            }
        } else {
            ui.leaf({key = "gap", props = {w = ui.Grow(1)}})
        }

        if count > 1 {
            if thor_tip_arrow(thor, "prev", "chevron-left") {
                thor_tip_step(thor, -1)
            }
            ui.label(
                fmt.tprintf("%d / %d", index + 1, count),
                {key = "pos", props = {color = thor.theme.disabled, text_wrap = .None}},
            )
            if thor_tip_arrow(thor, "next", "chevron-right") {
                thor_tip_step(thor, 1)
            }
        }
    }
}

@(private = "file")
thor_tip_arrow :: proc(thor: ^Thor, key, icon: string) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                w = ui.Px(22),
                h = ui.Px(22),
                dir = .Row,
                justify = .Center,
                align = .Center,
                radius = ui.rad(4),
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.buttons},
        },
    )
    thor_icon_label(thor, icon, thor.theme.muted_color, 14)
    return it.clicked
}
