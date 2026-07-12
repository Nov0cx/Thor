package thor

import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import rl "vendor:raylib"

import "../setting"
import "../syntax"
import "../ui"
import "../widgets"

Thor :: struct {
    ui_context:               ui.Context,
    config:                   setting.Settings,
    highlighter:              syntax.Highlighter,
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
    editor_panel:             ^widgets.Panel,
    console_splitter:         ^widgets.Splitter,
    console_panel:            ^widgets.Panel,
    console_stack:            ^widgets.Stack,
    console_header:           ^widgets.Stack,
    console_stub_panel:       ^widgets.Panel,
    console_stub_stack:       ^widgets.Stack,
    tree:                     ^widgets.Tree,
    tabbar:                   ^widgets.Tabbar,
    statusbar:                ^widgets.Statusbar,
    editor:                   ^widgets.Editor,
    console:                  ^widgets.Console,
    dialog:                   ^widgets.Dialog,
    dialog_stack:             ^widgets.Stack,
    command_palette:          ^widgets.Command_Palette,
    find_replace:             ^widgets.Find_Replace,
    command_palette_key:      setting.Keybind,
    fullscreen_key:           setting.Keybind,
    console_toggle_key:       setting.Keybind,
    find_key:                 setting.Keybind,
    replace_key:              setting.Keybind,
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
    minimize_button:          ^widgets.Button,
    maximize_button:          ^widgets.Button,
    close_button:             ^widgets.Button,
    should_close:             bool,
    explorer_width:           f32,
    console_height:           f32,
    workspace_dir:            string,
    workspace_prefix:         string, // workspace_dir + separator, for palette display
    git_branch:               string,
    open_files:               [dynamic]^Open_File,
    zombie_files:             [dynamic]^Open_File,
    // Worker threads append finished jobs here; the queues are created on
    // the main thread so appends go through the stored (mutex-guarded)
    // allocator, and are drained on the main thread every frame.
    io_mutex:                 sync.Mutex,
    finished_loads:           [dynamic]^Load_Job,
    finished_saves:           [dynamic]^Save_Job,
    finished_console:         [dynamic]^Console_Job,
    inflight_jobs:            int,
}

init :: proc() -> ^Thor {
    start := time.tick_now()
    phase := start
    lap :: proc(phase: ^time.Tick, name: string) {
        log.infof("[startup] %-24s %.1f ms", name, time.duration_milliseconds(time.tick_since(phase^)))
        phase^ = time.tick_now()
    }

    // Parse the font/icon manifests and rasterize every preload size on
    // worker threads while the main thread creates the window and builds
    // the widget tree.
    ui.text_begin_async_load("assets/fonts/fonts.json", "assets/icons/icons.json")
    lap(&phase, "text_begin_async_load")

    when !ODIN_DEBUG {
        rl.SetTraceLogLevel(.WARNING)
    }
    rl.SetConfigFlags({.WINDOW_UNDECORATED, .WINDOW_RESIZABLE})
    rl.InitWindow(1280, 800, "Thor")
    lap(&phase, "InitWindow")
    rl.SetTargetFPS(60)
    rl.SetExitKey(.KEY_NULL)

    thor := new(Thor)
    ui.context_init(&thor.ui_context)
    thor.config = setting.load("settings")
    thor.highlighter = syntax.highlighter_create()
    thor.theme, _ = ui.theme_load("assets/themes/material-deep-ocean.json")
    thor.active_file = ui.make_signal(-1)
    thor.explorer_visible = ui.make_signal(true)
    thor.console_visible = ui.make_signal(true)
    thor.explorer_width = 250
    thor.console_height = 190
    workspace_dir, workspace_err := os.get_working_directory(context.allocator)
    if workspace_err != nil {
        workspace_dir = strings.clone(".")
    }
    thor.workspace_dir = workspace_dir
    thor.workspace_prefix = strings.concatenate({workspace_dir, "\\"})
    thor.git_branch = thor_read_git_branch()
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.finished_loads = make([dynamic]^Load_Job)
    thor.finished_saves = make([dynamic]^Save_Job)
    thor.finished_console = make([dynamic]^Console_Job)

    log.infof("Loaded theme: %s", thor.theme.name)

    thor_build_ui(thor)
    thor.command_palette.return_focus = &thor.editor.widget
    thor.find_replace.return_focus = &thor.editor.widget
    widgets.command_palette_set_navigation(
        thor.command_palette,
        thor_palette_list_files,
        thor_palette_open_file,
        thor_palette_goto_line,
        thor.workspace_prefix,
        thor,
    )
    thor_register_commands(thor)
    widgets.console_set_on_run(thor.console, thor_console_run, thor)
    thor_apply_settings(thor)
    thor_set_active_file(thor, -1)
    thor_apply_layout_state(thor)
    ui.context_set_root(&thor.ui_context, &thor.root_panel.widget)
    ui.context_set_global_key(&thor.ui_context, thor_global_key, thor)
    lap(&phase, "build widget tree")

    // Texture upload needs the GL context, so it happens here on the main
    // thread once the rasterizer threads are done.
    ui.text_finish_async_load()
    lap(&phase, "text_finish_async_load")

    log.infof("Startup took %.1f ms", time.duration_milliseconds(time.tick_since(start)))

    return thor
}

@(private = "file")
thor_read_git_branch :: proc() -> string {
    data, read_err := os.read_entire_file(".git/HEAD", context.temp_allocator)
    if read_err != nil {
        return ""
    }

    head := strings.trim_space(string(data))
    REF_PREFIX :: "ref: refs/heads/"
    if strings.has_prefix(head, REF_PREFIX) {
        return strings.clone(head[len(REF_PREFIX):])
    }
    if len(head) >= 8 {
        // Detached head: show the short commit hash.
        return strings.clone(head[:8])
    }
    return ""
}

run :: proc(thor: ^Thor) {
    for !rl.WindowShouldClose() && !thor.should_close {
        thor_update_files(thor)
        ui.context_update(&thor.ui_context)

        rl.BeginDrawing()
        rl.ClearBackground(thor.theme.contrast)
        ui.context_draw(&thor.ui_context)
        rl.EndDrawing()

        free_all(context.temp_allocator)
    }
}

shutdown :: proc(thor: ^Thor) {
    thor_drain_io(thor)

    for file in thor.open_files {
        thor_free_open_file(file)
    }
    delete(thor.open_files)
    delete(thor.zombie_files)
    delete(thor.finished_loads)
    delete(thor.finished_saves)
    delete(thor.finished_console)
    delete(thor.workspace_dir)
    delete(thor.workspace_prefix)
    delete(thor.git_branch)
    setting.destroy(&thor.config)
    syntax.highlighter_destroy(&thor.highlighter)

    ui.theme_destroy(&thor.theme)
    ui.context_destroy(&thor.ui_context)
    ui.text_shutdown()
    rl.CloseWindow()
    free(thor)
}
