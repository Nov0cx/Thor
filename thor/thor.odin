package thor

import "core:log"
import rl "vendor:raylib"

import "../ui"
import "../widgets"

Thor :: struct {
    ui_context:               ui.Context,
    theme:                    ui.Theme,
    root_panel:               ^widgets.Panel,
    root_stack:               ^widgets.Stack,
    top_bar:                  ^widgets.Titlebar,
    workspace_row:            ^widgets.Stack,
    explorer_stub_panel:      ^widgets.Panel,
    explorer_stub_stack:      ^widgets.Stack,
    explorer_panel:           ^widgets.Panel,
    explorer_stack:           ^widgets.Stack,
    explorer_header:          ^widgets.Stack,
    explorer_splitter:        ^widgets.Splitter,
    editor_column:            ^widgets.Stack,
    tabs_row:                 ^widgets.Stack,
    editor_panel:             ^widgets.Panel,
    console_splitter:         ^widgets.Splitter,
    console_panel:            ^widgets.Panel,
    console_stack:            ^widgets.Stack,
    console_header:           ^widgets.Stack,
    console_stub_panel:       ^widgets.Panel,
    console_stub_stack:       ^widgets.Stack,
    status_label:             ^widgets.Label,
    editor:                   ^widgets.Editor,
    console_label:            ^widgets.Label,
    dialog:                   ^widgets.Dialog,
    dialog_stack:             ^widgets.Stack,
    active_file:              ui.Signal(int),
    explorer_visible:         ui.Signal(bool),
    console_visible:          ui.Signal(bool),
    menu_file_button:         ^widgets.Button,
    menu_edit_button:         ^widgets.Button,
    menu_view_button:         ^widgets.Button,
    menu_help_button:         ^widgets.Button,
    explorer_toggle_button:   ^widgets.Button,
    explorer_restore_button:  ^widgets.Button,
    console_toggle_button:    ^widgets.Button,
    console_restore_button:   ^widgets.Button,
    file_a_button:            ^widgets.Button,
    file_b_button:            ^widgets.Button,
    file_c_button:            ^widgets.Button,
    explorer_width:           f32,
    console_height:           f32,
}

init :: proc() -> ^Thor {
    rl.SetConfigFlags({.WINDOW_UNDECORATED, .WINDOW_RESIZABLE})
    rl.InitWindow(1280, 800, "Thor")
    rl.SetTargetFPS(60)
    ui.text_init("fonts\\JetBrainsMono-Regular.ttf", 18)

    thor := new(Thor)
    ui.context_init(&thor.ui_context)
    thor.theme = ui.theme_material_deep_ocean()
    thor.active_file = ui.make_signal(0)
    thor.explorer_visible = ui.make_signal(true)
    thor.console_visible = ui.make_signal(true)
    thor.explorer_width = 250
    thor.console_height = 190

    log.infof("Loaded theme: %s", thor.theme.name)

    thor_build_ui(thor)
    thor_set_active_file(thor, 0)
    thor_apply_layout_state(thor)
    ui.context_set_root(&thor.ui_context, &thor.root_panel.widget)

    return thor
}

run :: proc(thor: ^Thor) {
    for !rl.WindowShouldClose() {
        ui.context_update(&thor.ui_context)

        rl.BeginDrawing()
        rl.ClearBackground(thor.theme.contrast)
        ui.context_draw(&thor.ui_context)
        rl.EndDrawing()

        free_all(context.temp_allocator)
    }
}

shutdown :: proc(thor: ^Thor) {
    ui.context_destroy(&thor.ui_context)
    ui.text_shutdown()
    rl.CloseWindow()
    free(thor)
}
