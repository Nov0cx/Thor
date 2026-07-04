package main

import rl "vendor:raylib"
import "core:fmt"

global_window_id : int = 4
editor_state: UITextState
editor_font: rl.Font

add_window :: proc(ds: ^DockingSystem) {
    title := fmt.tprintf("Window %d", global_window_id)
    append(
        &ds.windows,
        Window{
            id = global_window_id,
            title = title,
            rect = { 100 + f32(global_window_id * 30), 100 + f32(global_window_id * 20), 250, 180 },
            is_floating = true,
        },
    )
    global_window_id += 1
}


build_editor_layout :: proc(ds: ^DockingSystem) {
    explorer := Window{ id = 1, title = "Explorer", rect = {}, is_floating = false }
    editor   := Window{ id = 2, title = "Editor",   rect = {}, is_floating = false }
    console  := Window{ id = 3, title = "Console",  rect = {}, is_floating = false }
    append(&ds.windows, explorer, editor, console)

    left_leaf   := new_leaf(&ds.windows[0])
    editor_leaf := new_leaf(&ds.windows[1])
    console_leaf:= new_leaf(&ds.windows[2])

    right_split := new_split(.Vertical, 0.7, editor_leaf, console_leaf)
    ds.root = new_split(.Horizontal, 0.2, left_leaf, right_split)

    screen_w := f32(rl.GetScreenWidth())
    screen_h := f32(rl.GetScreenHeight())
    layout_container(ds.root, rl.Rectangle{0, 0, screen_w, screen_h})
}

draw_editor_uis :: proc(ds: ^DockingSystem, editor_state: ^UITextState) {
    if ds.drag_window != nil {
        ui_ctx.interaction_ok = false
    }

    docked: [dynamic]^Window
    defer delete(docked)
    collect_docked_windows_rec(ds.root, &docked)

    for w in docked {
        content := rl.Rectangle{
            w.rect.x, w.rect.y + TITLE_BAR_HEIGHT,
            w.rect.width, w.rect.height - TITLE_BAR_HEIGHT,
        }
        switch w.id {
        case 1:
            rl.DrawRectangleRec(content, ui_theme.background)
            rl.DrawText("Explorer (empty)", i32(content.x)+4, i32(content.y)+4, 14, ui_theme.text)
        case 2:
            ui_editor(editor_state, content)
        case 3:
            rl.DrawRectangleRec(content, ui_theme.background)
            rl.DrawText("Console (empty)", i32(content.x)+4, i32(content.y)+4, 14, ui_theme.text)
        case:
            rl.DrawRectangleRec(content, ui_theme.background)
            rl.DrawText("Unknown", i32(content.x)+4, i32(content.y)+4, 14, ui_theme.text)
        }
    }

    for &w in ds.windows {
        if w.is_floating {
            content := rl.Rectangle{
                w.rect.x, w.rect.y + TITLE_BAR_HEIGHT,
                w.rect.width, w.rect.height - TITLE_BAR_HEIGHT,
            }
            ui_begin(w.id, content)
            ui_label(fmt.tprintf("Floating %s", w.title))
            if ui_button("Click me") {
                fmt.println("Clicked", w.title)
            }
            ui_end()
        }
    }
}

main :: proc() {
    rl.InitWindow(1280, 720, "Text Editor Layout – Odin + Raylib")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)
    set_deep_ocean_theme()

    editor_state = init_text_state("// Welcome to the Odin Editor!\n\n", true)
    editor_font = rl.LoadFontEx("JetBrainsMono-Regular.ttf", 16, nil, 250)
    defer rl.UnloadFont(editor_font)
    ui_ctx.font = editor_font
    
    ds := DockingSystem{}
    build_editor_layout(&ds)
    
    for !rl.WindowShouldClose() {
        ui_new_frame()

        if rl.IsKeyPressed(.N) {
            add_window(&ds)
        }

        update_docking(&ds)

        rl.BeginDrawing()
        rl.ClearBackground(rl.BLACK)

        draw_container(ds.root)
        draw_floating_windows(&ds)

        if ds.highlight_show {
            color := rl.Fade(rl.SKYBLUE, 0.4)
            if ds.highlight_is_fill {
                color = rl.Fade(rl.LIME, 0.3)
            }
            rl.DrawRectangleRec(ds.highlight_rect, color)
        }

        draw_editor_uis(&ds, &editor_state)

        rl.DrawFPS(10, 10)
        rl.EndDrawing()
    }

    destroy_text_state(&editor_state)
}