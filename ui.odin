package main

import rl "vendor:raylib"
import "core:hash"

UI_Context :: struct {
    clip:            rl.Rectangle,
    cursor:          rl.Vector2,
    line_height:     f32,
    hot_item:        u32,
    active_item:     u32,
    interaction_ok:  bool,
    id:              int,
    font:            rl.Font,
}

ui_ctx: UI_Context

ui_new_frame :: proc() {
    ui_ctx.hot_item = 0
    ui_ctx.interaction_ok = true
}

ui_begin :: proc(window_id: int, rect: rl.Rectangle) {
    ui_ctx.clip = rect
    ui_ctx.cursor = { rect.x + 4, rect.y + 4 }
    ui_ctx.line_height = 20
    ui_ctx.id = window_id
    rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
}

ui_end :: proc() {
    rl.EndScissorMode()
}

widget_id :: proc(label: string) -> u32 {
    h := hash.fnv32a(transmute([]u8)label)
    h ~= u32(ui_ctx.id)
    return h
}

ui_item :: proc(rect: rl.Rectangle, id: u32) -> bool {
    if !ui_ctx.interaction_ok do return false
    mouse := rl.GetMousePosition()
    inside := rl.CheckCollisionPointRec(mouse, rect)

    if inside {
        ui_ctx.hot_item = id
    }

    if ui_ctx.hot_item == 0 && rl.IsMouseButtonDown(.LEFT) {
        ui_ctx.active_item = 0
    }

    if inside && rl.IsMouseButtonPressed(.LEFT) {
        ui_ctx.active_item = id
    }

    if ui_ctx.active_item == id && rl.IsMouseButtonReleased(.LEFT) {
        if inside {
            ui_ctx.active_item = 0
            return true
        }
        ui_ctx.active_item = 0
    }
    return false
}