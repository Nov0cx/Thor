package ui

import rl "vendor:raylib"

Global_Key_Proc :: #type proc(data: rawptr, event: ^Event) -> bool

// Max seconds and pixel drift between presses to count as a multi-click.
DOUBLE_CLICK_SECS :: 0.4
DOUBLE_CLICK_DIST :: 4

Context :: struct {
    root:      ^Widget,
    events:    Event_Queue,
    hot:       ^Widget,
    active:    ^Widget,
    focused:   ^Widget,
    mouse_pos: rl.Vector2,
    prev_mouse_pos: rl.Vector2,
    // Double-click tracking for the left button.
    last_click_time: f64,
    last_click_pos:  rl.Vector2,
    click_count:     int,
    // Application-level shortcuts (tab switching, panel toggles): runs on
    // every Key_Press before focus dispatch; returning true consumes it.
    global_key:      Global_Key_Proc,
    global_key_data: rawptr,
}

context_init :: proc(ctx: ^Context) {
    event_queue_init(&ctx.events)
}

context_destroy :: proc(ctx: ^Context) {
    widget_destroy_tree(ctx.root)
    ctx.root = nil
    ctx.hot = nil
    ctx.active = nil
    ctx.focused = nil
    event_queue_destroy(&ctx.events)
}

context_set_root :: proc(ctx: ^Context, root: ^Widget) {
    ctx.root = root
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
}

context_collect_input :: proc(ctx: ^Context) {
    event_queue_clear(&ctx.events)

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
    ctrl_down := (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) && !alt_gr
    shift_down := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
    alt_down := rl.IsKeyDown(.LEFT_ALT)

    event_queue_push(&ctx.events, Event {
        kind = .Mouse_Move,
        mouse_position = ctx.mouse_pos,
        mouse_delta = mouse_delta,
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
            ctrl = ctrl_down,
            shift = shift_down,
            alt = alt_down,
            click_count = ctx.click_count,
        })
    }

    if rl.IsMouseButtonReleased(.LEFT) {
        event_queue_push(&ctx.events, Event {
            kind = .Mouse_Up,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            mouse_button = .LEFT,
            ctrl = ctrl_down,
            shift = shift_down,
            alt = alt_down,
        })
    }

    if rl.IsMouseButtonPressed(.RIGHT) {
        event_queue_push(&ctx.events, Event {
            kind = .Mouse_Down,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            mouse_button = .RIGHT,
        })
    }

    if rl.IsMouseButtonReleased(.RIGHT) {
        event_queue_push(&ctx.events, Event {
            kind = .Mouse_Up,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            mouse_button = .RIGHT,
        })
    }

    wheel_delta := rl.GetMouseWheelMove()
    if wheel_delta != 0 {
        event_queue_push(&ctx.events, Event {
            kind = .Scroll,
            mouse_position = ctx.mouse_pos,
            mouse_delta = mouse_delta,
            wheel_delta = wheel_delta,
        })
    }

    for {
        key := rl.GetKeyPressed()
        if key == cast(rl.KeyboardKey) 0 {
            break
        }

        event_queue_push(&ctx.events, Event {
            kind = .Key_Press,
            key = remap_key_to_layout(key),
            ctrl = ctrl_down,
            shift = shift_down,
            alt = alt_down,
        })
    }

    // GetKeyPressed only reports the initial press; held keys need the
    // repeat flag so editing keys keep firing.
    repeatable_keys := [?]rl.KeyboardKey {
        .BACKSPACE, .DELETE, .ENTER, .KP_ENTER, .TAB,
        .LEFT, .RIGHT, .UP, .DOWN,
        .PAGE_UP, .PAGE_DOWN, .HOME, .END,
        .Z, .Y,
    }
    for key in repeatable_keys {
        if rl.IsKeyPressedRepeat(key) {
            event_queue_push(&ctx.events, Event {
                kind = .Key_Press,
                key = remap_key_to_layout(key),
                ctrl = ctrl_down,
                shift = shift_down,
                alt = alt_down,
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
            ctrl = ctrl_down,
            shift = shift_down,
            alt = alt_down,
        })
    }
}

context_process_events :: proc(ctx: ^Context) {
    for i in 0 ..< len(ctx.events.items) {
        event := &ctx.events.items[i]

        switch event.kind {
        case .Mouse_Move:
            ctx.hot = widget_hit_test(ctx.root, event.mouse_position)

            if ctx.active != nil {
                event.target = ctx.active
                widget_dispatch_event(ctx.active, ctx, event)
            } else if ctx.hot != nil {
                // No button held: give the hovered widget a hover tick. Kept
                // separate from Mouse_Move so widgets that treat a move as a
                // drag-select don't fire on a passive hover.
                hover := event^
                hover.kind = .Mouse_Hover
                hover.target = ctx.hot
                widget_dispatch_event(ctx.hot, ctx, &hover)
            }

        case .Mouse_Hover:
            // Synthesized above, never queued; nothing to do at the top level.

        case .Mouse_Down:
            event.target = widget_hit_test(ctx.root, event.mouse_position)
            ctx.active = event.target
            ctx.focused = event.target

            if event.target != nil {
                widget_dispatch_event(event.target, ctx, event)
            }

        case .Mouse_Up:
            release_target := ctx.active
            hit_target := widget_hit_test(ctx.root, event.mouse_position)

            if release_target != nil {
                event.target = release_target
                widget_dispatch_event(release_target, ctx, event)

                if release_target == hit_target || widget_contains_point(release_target, event.mouse_position) {
                    click_event := Event {
                        kind = .Click,
                        mouse_position = event.mouse_position,
                        mouse_button = event.mouse_button,
                        target = release_target,
                    }

                    widget_dispatch_event(release_target, ctx, &click_event)
                }
            }

            ctx.active = nil

        case .Click:
        case .Scroll:
            event.target = widget_hit_test(ctx.root, event.mouse_position)
            if event.target != nil {
                widget_dispatch_event(event.target, ctx, event)
            }

        case .Key_Press, .Text_Input:
            if event.kind == .Key_Press && ctx.global_key != nil && ctx.global_key(ctx.global_key_data, event) {
                break
            }
            if ctx.focused != nil {
                event.target = ctx.focused
                widget_dispatch_event(ctx.focused, ctx, event)
            }

        case .None:
        }
    }
}
