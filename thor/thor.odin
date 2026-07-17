package thor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import rl "vendor:raylib"

import "../plugin"
import "../setting"
import "../ui"
import "../widgets"

Thor :: struct {
    ui_context:               ui.Context,
    config:                   setting.Settings,
    plugins:                  plugin.Manager,
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
    // Second editor pane, shown side-by-side with the first when the split is
    // on. Both view the active file's buffer (shared state, independent scroll).
    editor2:                  ^widgets.Editor,
    // Overlays the editor panel when the active file is an image; the editor
    // rows are hidden while it shows.
    image_view:               ^widgets.Image_View,
    editor_split_row:         ^widgets.Stack,
    editor_split_splitter:    ^widgets.Splitter,
    console:                  ^widgets.Console,
    dialog:                   ^widgets.Dialog,
    dialog_stack:             ^widgets.Stack,
    command_palette:          ^widgets.Command_Palette,
    // Modal picker for Preferences (theme/font), with live preview.
    select_dialog:            ^widgets.Select_Dialog,
    find_replace:             ^widgets.Find_Replace,
    menu:                     ^widgets.Menu,
    command_palette_key:      setting.Keybind,
    quick_open_key:           setting.Keybind,
    fullscreen_key:           setting.Keybind,
    console_toggle_key:       setting.Keybind,
    find_key:                 setting.Keybind,
    replace_key:              setting.Keybind,
    focus_editor_key:         setting.Keybind,
    focus_explorer_key:       setting.Keybind,
    focus_terminal_key:       setting.Keybind,
    trim_whitespace_key:      setting.Keybind,
    align_char_key:           setting.Keybind,
    goto_line_key:            setting.Keybind,
    last_file_key:            setting.Keybind,
    // Toggles the editor split. Unbound by default (KEY_NULL), so it only fires
    // once the user sets a "toggle_split" chord in keybinds.json.
    split_key:                setting.Keybind,
    active_file:              ui.Signal(int),
    // Most-recently-active file before the current one, for the ctrl+e flip.
    // Cleared when that file is closed so the pointer never dangles.
    last_active_file:         ^Open_File,
    explorer_visible:         ui.Signal(bool),
    console_visible:          ui.Signal(bool),
    menu_file_button:         ^widgets.Button,
    menu_edit_button:         ^widgets.Button,
    menu_view_button:         ^widgets.Button,
    menu_help_button:         ^widgets.Button,
    // Titlebar/panel labels that carry a theme color, kept so a live theme
    // change can recolor them (most labels are theme-neutral and not stored).
    top_title_label:          ^widgets.Label,
    explorer_title_label:     ^widgets.Label,
    console_title_label:      ^widgets.Label,
    dialog_text_label:        ^widgets.Label,
    dialog_console_button:    ^widgets.Button,
    explorer_toggle_button:   ^widgets.Button,
    explorer_restore_button:  ^widgets.Button,
    console_toggle_button:    ^widgets.Button,
    console_restore_button:   ^widgets.Button,
    minimize_button:          ^widgets.Button,
    maximize_button:          ^widgets.Button,
    close_button:             ^widgets.Button,
    // Top-bar buttons added by plugins via thor.button, and the widget a new one
    // is linked in after (advances so buttons keep registration order).
    plugin_buttons:           [dynamic]^Plugin_Top_Button,
    top_bar_plugin_anchor:    ^ui.Widget,
    should_close:             bool,
    window_maximized:         bool,
    explorer_width:           f32,
    console_height:           f32,
    split_visible:            bool,
    split_ratio:              f32,
    // Each pane's open-files index (-1 = none); the two panes can show different
    // files. active_pane is the focused one, whose file the tabbar, status bar
    // and file commands act on (mirrored into the active_file signal).
    pane_file:                [2]int,
    active_pane:              int,
    // App/file/view commands that ship without a keybinding. Each carries its
    // config action name and resolved chord; unbound ones (KEY_NULL) never fire.
    // Dispatched globally, so only commands with no editor-local key belong here.
    app_binds:                [dynamic]App_Bind,
    workspace_dir:            string,
    workspace_prefix:         string, // workspace_dir + separator, for palette display
    // True when workspace_dir has a .thor/ directory: its config overlays the
    // global settings, and it is treated as an initialized workspace.
    workspace_initialized:    bool,
    // Directory a New File/Folder prompt creates into; set from the explorer
    // right-click target or the workspace root. Owned clone.
    menu_target_dir:          string,
    // Path awaiting a delete confirmation (set when Delete is pressed in the
    // explorer, consumed when the confirm dialog is accepted). Owned clone.
    pending_delete_path:      string,
    // Message shown in the delete confirmation dialog; borrowed by the palette
    // while it is open, so it must outlive the dialog. Owned clone.
    delete_prompt:            string,
    git_branch:               string,
    open_files:               [dynamic]^Open_File,
    zombie_files:             [dynamic]^Open_File,
    // Worker threads append finished jobs here under io_mutex; drained on the
    // main thread every frame.
    io_mutex:                 sync.Mutex,
    finished_loads:           [dynamic]^Load_Job,
    finished_saves:           [dynamic]^Save_Job,
    finished_console:         [dynamic]^Console_Job,
    finished_git:             [dynamic]^Git_Status_Job,
    inflight_jobs:            int,
    // Working-tree status keyed by absolute path (matches tree node paths),
    // recomputed off-thread; git_status_inflight guards against overlapping runs.
    git_status:               map[string]widgets.Git_Status,
    git_status_inflight:      bool,
    git_status_dirty:         bool, // a refresh was requested while one was running
}

init :: proc() -> ^Thor {
    start := time.tick_now()
    phase := start
    lap :: proc(phase: ^time.Tick, name: string) {
        log.infof("[startup] %-24s %.1f ms", name, time.duration_milliseconds(time.tick_since(phase^)))
        phase^ = time.tick_now()
    }

    // Resolve the workspace (owned, absolute) BEFORE moving the CWD: a path
    // argument wins, else the launch directory. Everything below loads relative
    // to the CWD, which we then repoint at the exe directory.
    workspace_dir: string
    if len(os.args) > 1 {
        abs, abs_err := filepath.abs(os.args[1], context.allocator)
        workspace_dir = abs_err == nil ? abs : strings.clone(os.args[1])
    } else {
        cwd, cwd_err := os.get_working_directory(context.allocator)
        workspace_dir = cwd_err == nil ? cwd : strings.clone(".")
    }
    if exe_path, exe_err := os.get_executable_path(context.temp_allocator); exe_err == nil {
        if set_err := os.set_working_directory(os.dir(exe_path)); set_err != nil {
            log.warnf("Could not set working directory to exe dir: %v", set_err)
        }
    } else {
        log.warnf("Could not resolve executable path: %v", exe_err)
    }

    // Rasterize fonts on worker threads while the main thread creates the
    // window and builds the widget tree.
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
    thor_load_config(thor, workspace_dir)
    plugin.manager_init(&thor.plugins)
    // Plugins are loaded later (after the console exists and the host services
    // are wired) so a plugin can print and read keybinds from its load body.
    thor_load_active_theme(thor)
    thor.active_file = ui.make_signal(-1)
    thor.explorer_visible = ui.make_signal(true)
    thor.console_visible = ui.make_signal(true)
    thor.explorer_width = 250
    thor.console_height = 190
    thor.split_ratio = 0.5
    thor.pane_file = {-1, -1}
    thor.workspace_dir = workspace_dir
    thor.workspace_prefix = strings.concatenate({workspace_dir, "\\"})
    thor.git_branch = thor_read_git_branch(workspace_dir)
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.finished_loads = make([dynamic]^Load_Job)
    thor.finished_saves = make([dynamic]^Save_Job)
    thor.finished_console = make([dynamic]^Console_Job)
    thor.finished_git = make([dynamic]^Git_Status_Job)

    log.infof("Loaded theme: %s", thor.theme.name)

    thor_build_ui(thor)
    thor.command_palette.return_focus = &thor.editor.widget
    thor.select_dialog.return_focus = &thor.editor.widget
    thor.find_replace.return_focus = &thor.editor.widget
    thor.menu.return_focus = &thor.editor.widget
    widgets.command_palette_set_navigation(
        thor.command_palette,
        thor_palette_list_files,
        thor_palette_open_file,
        thor_palette_goto_line,
        thor.workspace_prefix,
        thor,
    )
    thor_register_commands(thor)
    thor_wire_menus(thor)
    widgets.console_set_on_run(thor.console, thor_console_run, thor)
    thor_apply_settings(thor)

    // Now that the console and keybinds exist, expose the host services and load
    // plugins (their load body may print or query keybinds, e.g. the tutorial).
    // Plugin top-bar buttons link in just after the Help button.
    thor.top_bar_plugin_anchor = &thor.menu_help_button.widget
    plugin.manager_set_host(
        &thor.plugins,
        thor,
        thor_plugin_print,
        thor_plugin_keybind,
        thor_plugin_doc,
        thor_plugin_exec,
        thor_plugin_button,
    )
    plugin.manager_load(&thor.plugins)
    thor_set_active_file(thor, -1)
    thor_restore_session(thor)
    thor_apply_layout_state(thor)
    thor_apply_split(thor)
    if thor.split_visible {
        thor_bind_pane(thor, 1)
    }
    ui.context_set_root(&thor.ui_context, &thor.root_panel.widget)
    ui.context_set_global_key(&thor.ui_context, thor_global_key, thor)
    thor_refresh_git_status(thor)
    lap(&phase, "build widget tree")

    // Texture upload needs the GL context, so it happens here on the main
    // thread once the rasterizer threads are done.
    ui.text_finish_async_load()
    // The font families are only registered once loading finishes, so apply the
    // configured text font here rather than before the async load.
    if fam := setting.font_family(&thor.config); fam != "" {
        if !ui.text_set_default_family(fam) {
            log.warnf("Configured font %q is not available; using the default", fam)
        }
    }
    lap(&phase, "text_finish_async_load")

    log.infof("Startup took %.1f ms", time.duration_milliseconds(time.tick_since(start)))

    return thor
}

@(private = "file")
thor_read_git_branch :: proc(workspace_dir: string) -> string {
    head_path := strings.concatenate({workspace_dir, "/.git/HEAD"}, context.temp_allocator)
    data, read_err := os.read_entire_file(head_path, context.temp_allocator)
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
        thor_sync_active_pane(thor)

        rl.BeginDrawing()
        rl.ClearBackground(thor.theme.contrast)
        ui.context_draw(&thor.ui_context)
        rl.EndDrawing()

        free_all(context.temp_allocator)
    }
}

shutdown :: proc(thor: ^Thor) {
    thor_save_session(thor)
    thor_drain_io(thor)

    for file in thor.open_files {
        thor_free_open_file(file)
    }
    delete(thor.open_files)
    delete(thor.zombie_files)
    delete(thor.finished_loads)
    delete(thor.finished_saves)
    delete(thor.finished_console)
    delete(thor.finished_git)
    delete(thor.app_binds)
    thor_clear_git_status(thor)
    delete(thor.workspace_dir)
    delete(thor.workspace_prefix)
    delete(thor.menu_target_dir)
    delete(thor.pending_delete_path)
    delete(thor.delete_prompt)
    delete(thor.git_branch)
    for pb in thor.plugin_buttons {
        delete(pb.label)
        delete(pb.command)
        free(pb)
    }
    delete(thor.plugin_buttons)
    setting.destroy(&thor.config)
    plugin.manager_destroy(&thor.plugins)

    ui.theme_destroy(&thor.theme)
    ui.context_destroy(&thor.ui_context)
    ui.text_shutdown()
    rl.CloseWindow()
    free(thor)
}
