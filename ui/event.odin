package ui

import rl "vendor:raylib"

Event_Type :: enum {
    None,
    Mouse_Move,
    // Cursor resting over a widget with no button held. Synthesized each frame
    // for the hovered widget so it can drive dwell-based UI (e.g. hover popups)
    // without stealing the drag-only Mouse_Move path.
    Mouse_Hover,
    Mouse_Down,
    Mouse_Up,
    Click,
    Key_Press,
    Text_Input,
    Scroll,
}

Event :: struct {
    kind:           Event_Type,
    mouse_position: rl.Vector2,
    mouse_delta:    rl.Vector2,
    wheel_delta:    f32,
    mouse_button:   rl.MouseButton,
    key:            rl.KeyboardKey,
    codepoint:      rune,
    ctrl:           bool,
    shift:          bool,
    alt:            bool,
    // Consecutive clicks at the same spot: 1 = single, 2 = double, ...
    click_count:    int,
    target:         ^Widget,
}

Event_Queue :: struct {
    items: [dynamic]Event,
}

event_queue_init :: proc(queue: ^Event_Queue) {
    queue.items = make([dynamic]Event, 0, 8)
}

event_queue_destroy :: proc(queue: ^Event_Queue) {
    clear(&queue.items)
    delete(queue.items)
}

event_queue_clear :: proc(queue: ^Event_Queue) {
    clear(&queue.items)
}

event_queue_push :: proc(queue: ^Event_Queue, event: Event) {
    append(&queue.items, event)
}
