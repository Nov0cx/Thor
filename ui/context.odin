package ui

import rl "vendor:raylib"

import "../input"

Global_Key_Proc :: #type proc(data: rawptr, event: ^Event) -> bool

// Max seconds and pixel drift between presses to count as a multi-click.
DOUBLE_CLICK_SECS :: 0.4
DOUBLE_CLICK_DIST :: 4

// A key held down. `physical` is what raylib polls, `mapped` what the layout
// prints on it: the press stores both, so a layout switch mid-hold cannot give
// the release a different key than the press.
Held_Key :: struct {
    physical: rl.KeyboardKey,
    mapped:   rl.KeyboardKey,
}

Context :: struct {
    root:      ^Widget, // owned, freed by context_destroy
    events:    Event_Queue,
    // Borrowed; context_forget drops them before their widgets go away.
    hot:       ^Widget,
    // The press target of each button, so a second button pressed during a drag
    // cannot take the first one's release. Only LEFT, RIGHT and MIDDLE are ever
    // filled; context_collect_input queues no other button.
    active:    [rl.MouseButton]^Widget,
    focused:   ^Widget,
    mouse_pos: rl.Vector2,
    prev_mouse_pos: rl.Vector2,
    // The modifiers of this frame, for a draw that has no event to read them
    // off. Holds the AltGr suppression the events get.
    mods:      input.Modifiers,
    // The keys held since their press. Drives the repeat and the release event,
    // which raylib reports per key instead of over a queue.
    held:      [dynamic]Held_Key,
    // The last hit test of the frame. Every mouse event of a frame carries the
    // same position, so the tree is walked once instead of once per event.
    // Dropped at the head of a frame, because layout runs before the events, and
    // when a widget goes away.
    hit_pos:    rl.Vector2,
    hit_widget: ^Widget, // borrowed
    hit_valid:  bool,
    // Double-click tracking for the left button.
    last_click_time: f64,
    last_click_pos:  rl.Vector2,
    click_count:     int,
    // Application-level shortcuts (tab switching, panel toggles): runs on
    // every Key_Press before focus dispatch; returning true consumes it.
    global_key:      Global_Key_Proc,
    global_key_data: rawptr,
    // Hover explanations; see tooltip.odin.
    tooltip:         Tooltip_State,
}

context_init :: proc(ctx: ^Context) {
    event_queue_init(&ctx.events)
    ctx.held = make([dynamic]Held_Key, 0, 8)
    tooltip_init(&ctx.tooltip)
}

context_destroy :: proc(ctx: ^Context) {
    widget_destroy_tree(ctx.root)
    ctx.root = nil
    ctx.hot = nil
    ctx.active = {}
    ctx.focused = nil
    ctx.hit_widget = nil
    ctx.hit_valid = false
    event_queue_destroy(&ctx.events)
    delete(ctx.held)
    ctx.held = nil
    tooltip_destroy(&ctx.tooltip)
}

// Drops every reference into `subtree`. Call before destroying it, or the hot,
// active and focused pointers outlive the widgets they name.
context_forget :: proc(ctx: ^Context, subtree: ^Widget) {
    if widget_contains(subtree, ctx.hot) {
        ctx.hot = nil
    }
    for button in rl.MouseButton {
        if widget_contains(subtree, ctx.active[button]) {
            ctx.active[button] = nil
        }
    }
    if widget_contains(subtree, ctx.focused) {
        ctx.focused = nil
    }
    ctx.hit_widget = nil
    ctx.hit_valid = false
    // The dwell can name a widget in the subtree, and its anchor is that
    // widget's bounds.
    tooltip_clear(&ctx.tooltip)
}

// The widget a drag belongs to: the press target of the first held button in
// button order, so the left button keeps the moves while another button is down.
context_active :: proc(ctx: ^Context) -> ^Widget {
    for widget in ctx.active {
        if widget != nil {
            return widget
        }
    }
    return nil
}

context_set_root :: proc(ctx: ^Context, root: ^Widget) {
    ctx.root = root
    ctx.hit_widget = nil
    ctx.hit_valid = false
}

// The widget under `position`, from the last hit test when it tested the same
// position in this frame.
context_hit_test :: proc(ctx: ^Context, position: rl.Vector2) -> ^Widget {
    if ctx.hit_valid && ctx.hit_pos == position {
        return ctx.hit_widget
    }
    ctx.hit_pos = position
    ctx.hit_widget = widget_hit_test(ctx.root, position)
    ctx.hit_valid = true
    return ctx.hit_widget
}

context_set_global_key :: proc(ctx: ^Context, global_key: Global_Key_Proc, data: rawptr) {
    ctx.global_key = global_key
    ctx.global_key_data = data
}

context_update :: proc(ctx: ^Context) {
    if ctx.root == nil {
        return
    }

    root_bounds := rl.Rectangle {
        x = 0,
        y = 0,
        width = cast(f32) rl.GetScreenWidth(),
        height = cast(f32) rl.GetScreenHeight(),
    }

    widget_layout_tree(ctx.root, root_bounds)
    context_collect_input(ctx)
    context_process_events(ctx)
}

context_draw :: proc(ctx: ^Context) {
    if ctx.root == nil {
        return
    }

    widget_draw_tree(ctx.root, ctx)
    // After the tree: the widgets just pushed their tooltip requests, and the
    // box must land over every one of them.
    tooltip_frame(ctx)
}

// Records a key as held. A key already in the list keeps the mapping its press
// gave it, so a repeat cannot rename it half way.
@(private = "file")
context_hold_key :: proc(ctx: ^Context, physical, mapped: rl.KeyboardKey) {
    for held in ctx.held {
        if held.physical == physical {
            return
        }
    }
    append(&ctx.held, Held_Key{physical = physical, mapped = mapped})
}

// True for a key that only modifies another one, so a widget can tell a chord
// being built from a key that ends it.
is_modifier_key :: proc(key: rl.KeyboardKey) -> bool {
    #partial switch key {
    case .LEFT_CONTROL, .RIGHT_CONTROL, .LEFT_SHIFT, .RIGHT_SHIFT,
         .LEFT_ALT, .RIGHT_ALT, .LEFT_SUPER, .RIGHT_SUPER:
        return true
    }
    return false
}

context_collect_input :: proc(ctx: ^Context) {
    event_queue_clear(&ctx.events)
    // Layout ran, so the bounds the last test read are gone.
    ctx.hit_valid = false

    ctx.prev_mouse_pos = ctx.mouse_pos
    ctx.mouse_pos = rl.GetMousePosition()
    mouse_delta := rl.Vector2 {
        ctx.mouse_pos[0] - ctx.prev_mouse_pos[0],
        ctx.mouse_pos[1] - ctx.prev_mouse_pos[1],
    }

    // AltGr (right Alt) types { } @ on non-US layouts and must never act as a
    // shortcut modifier; Windows also reports it as left Ctrl, so suppress Ctrl
    // while it is held. Computed before mouse events so clicks carry modifiers.
    alt_gr := rl.IsKeyDown(.RIGHT_ALT)
    mods: input.Modifiers
    if (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) && !alt_gr {
        mods += {.Ctrl}
    }
    if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
        mods += {.Shift}
    }
    if rl.IsKeyDown(.LEFT_ALT) {
        mods += {.Alt}
    }
    // Command on macOS, the Windows/Super key elsewhere.
    if rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) {
        mods += {.Cmd}
    }
    ctx.mods = mods

    event_queue_push(&ctx.events, Event {
        kind = .Mouse_Move,
        mouse_position = ctx.mouse_pos,
        mouse_delta = mouse_delta,
        mods = mods,
    })

    if rl.IsMouseButtonPressed(.LEFT) {
        now := rl.GetTime()
        near := abs(ctx.mouse_pos[0] - ctx.last_click_pos[0]) <= DOUBLE_CLICK_DIST &&
            abs(ctx.mouse_pos[1] - ctx.last_click_pos[1]) <= DOUBLE_CLICK_DIST
        if near && now - ctx.last_click_time <= DOUBLE_CLICK_SECS {
            ctx.click_count += 1
        } else {
            ctx.click_count = 1
        }
        ctx.last_click_time = now
        ctx.last_click_pos = ctx.mouse_pos

        event_queue_push(&ctx.events, Event {
            kind = .Mouse_Down,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            mouse_button = .LEFT,
            mods = mods,
            click_count = ctx.click_count,
        })
    }

    if rl.IsMouseButtonReleased(.LEFT) {
        event_queue_push(&ctx.events, Event {
            kind = .Mouse_Up,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            mouse_button = .LEFT,
            mods = mods,
        })
    }

    if rl.IsMouseButtonPressed(.RIGHT) {
        event_queue_push(&ctx.events, Event {
            kind = .Mouse_Down,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            mouse_button = .RIGHT,
            mods = mods,
        })
    }

    if rl.IsMouseButtonReleased(.RIGHT) {
        event_queue_push(&ctx.events, Event {
            kind = .Mouse_Up,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            mouse_button = .RIGHT,
            mods = mods,
        })
    }

    if rl.IsMouseButtonPressed(.MIDDLE) {
        event_queue_push(&ctx.events, Event {
            kind = .Mouse_Down,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            mouse_button = .MIDDLE,
            mods = mods,
        })
    }

    if rl.IsMouseButtonReleased(.MIDDLE) {
        event_queue_push(&ctx.events, Event {
            kind = .Mouse_Up,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            mouse_button = .MIDDLE,
            mods = mods,
        })
    }

    wheel := rl.GetMouseWheelMoveV()
    if wheel.x != 0 || wheel.y != 0 {
        event_queue_push(&ctx.events, Event {
            kind = .Scroll,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            wheel_delta = wheel.y,
            wheel_delta_x = wheel.x,
            mods = mods,
        })
    }

    for {
        key := rl.GetKeyPressed()
        if key == cast(rl.KeyboardKey) 0 {
            break
        }

        mapped := remap_key_to_layout(key)
        context_hold_key(ctx, key, mapped)
        event_queue_push(&ctx.events, Event {
            kind = .Key_Press,
            key = mapped,
            mods = mods,
        })
    }

    // GetKeyPressed reports the initial press only, and raylib has no queue of
    // repeats or releases: both are polled per held key.
    #reverse for held, index in ctx.held {
        if rl.IsKeyUp(held.physical) {
            event_queue_push(&ctx.events, Event {
                kind = .Key_Release,
                key = held.mapped,
                mods = mods,
            })
            unordered_remove(&ctx.held, index)
            continue
        }
        // A held modifier repeats on some platforms and means nothing on its
        // own, so only the key it modifies fires again.
        if !is_modifier_key(held.physical) && rl.IsKeyPressedRepeat(held.physical) {
            event_queue_push(&ctx.events, Event {
                kind = .Key_Press,
                key = held.mapped,
                mods = mods,
                repeat = true,
            })
        }
    }

    for {
        codepoint := rl.GetCharPressed()
        if codepoint == 0 {
            break
        }

        event_queue_push(&ctx.events, Event {
            kind = .Text_Input,
            codepoint = codepoint,
            mods = mods,
        })
    }
}

context_process_events :: proc(ctx: ^Context) {
    // Dispatched from a copy: a handler may push into the same queue, and the
    // append can move `items`. The length is re-read so a pushed event still
    // runs this frame instead of dying at the next clear.
    for i := 0; i < len(ctx.events.items); i += 1 {
        event := ctx.events.items[i]

        switch event.kind {
        case .Mouse_Move:
            hot := context_hit_test(ctx, event.mouse_position)
            if hot != ctx.hot && ctx.hot != nil {
                // Only the widget that held the hover hears this: an ancestor
                // of it still has the cursor inside itself.
                leave := event
                leave.kind = .Mouse_Leave
                leave.target = ctx.hot
                widget_send_event(ctx.hot, ctx, &leave)
            }
            ctx.hot = hot

            if dragged := context_active(ctx); dragged != nil {
                event.target = dragged
                widget_dispatch_event(dragged, ctx, &event)
            } else if ctx.hot != nil {
                // No button held: give the hovered widget a hover tick. Kept
                // separate from Mouse_Move so widgets that treat a move as a
                // drag-select don't fire on a passive hover.
                hover := event
                hover.kind = .Mouse_Hover
                hover.target = ctx.hot
                widget_dispatch_event(ctx.hot, ctx, &hover)
            }

        case .Mouse_Hover, .Mouse_Leave:
            // Synthesized above, never queued; nothing to do at the top level.

        case .Mouse_Down:
            event.target = context_hit_test(ctx, event.mouse_position)
            ctx.active[event.mouse_button] = event.target
            ctx.focused = event.target

            if event.target != nil {
                widget_dispatch_event(event.target, ctx, &event)
            }

        case .Mouse_Up:
            release_target := ctx.active[event.mouse_button]
            hit_target := context_hit_test(ctx, event.mouse_position)

            if release_target != nil {
                event.target = release_target
                widget_dispatch_event(release_target, ctx, &event)

                if release_target == hit_target || widget_contains_point(release_target, event.mouse_position) {
                    click_event := Event {
                        kind = .Click,
                        mouse_position = event.mouse_position,
                        mouse_button = event.mouse_button,
                        mods = event.mods,
                        target = release_target,
                    }

                    widget_dispatch_event(release_target, ctx, &click_event)
                }
            }

            ctx.active[event.mouse_button] = nil

        case .Click:
        case .Scroll:
            event.target = context_hit_test(ctx, event.mouse_position)
            if event.target != nil {
                widget_dispatch_event(event.target, ctx, &event)
            }

        case .Key_Press, .Key_Release, .Text_Input:
            if event.kind != .Text_Input && ctx.global_key != nil && ctx.global_key(ctx.global_key_data, &event) {
                break
            }
            if ctx.focused != nil {
                event.target = ctx.focused
                widget_dispatch_event(ctx.focused, ctx, &event)
            }

        case .None:
        }
    }
}
