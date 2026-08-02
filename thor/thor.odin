package thor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import rl "vendor:raylib"

import "../lang"
import "../lang/odin"
import "../plugin"
import "../setting"
import "../ui"
import "../watch"
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
    // Rendered markdown preview, shown in place of whichever pane is not
    // focused (pane 0's slot / pane 1's slot respectively) while preview is on
    // and the active file is markdown. Toggled by "View: Toggle Markdown Preview".
    markdown_view:            ^widgets.Markdown_View,
    markdown_view2:           ^widgets.Markdown_View,
    markdown_preview:         bool,
    editor_split_row:         ^widgets.Stack,
    editor_split_splitter:    ^widgets.Splitter,
    console:                  ^widgets.Console,
    dialog:                   ^widgets.Dialog,
    dialog_stack:             ^widgets.Stack,
    command_palette:          ^widgets.Command_Palette,
    // Modal picker for Preferences (theme/font), with live preview.
    select_dialog:            ^widgets.Select_Dialog,
    // Modal GUI editor for every setting (editor prefs, theme/font, keybinds).
    settings_view:            ^widgets.Settings_View,
    // Auto-reload of the config files: a signature of their modification times,
    // refreshed after each load; the poll loop reloads when it changes on disk.
    settings_sig:             i64,
    settings_poll_time:       f64,
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
    // Titlebar hammer mark and its borrowed texture (unloaded at shutdown).
    top_logo:                 ^widgets.Logo,
    top_logo_texture:         rl.Texture2D,
    // Titlebar/panel labels that carry a theme color, kept so a live theme
    // change can recolor them (most labels are theme-neutral and not stored).
    explorer_title_label:     ^widgets.Label,
    console_title_label:      ^widgets.Label,
    dialog_text_label:        ^widgets.Label,
    dialog_console_button:    ^widgets.Button,
    explorer_toggle_button:   ^widgets.Button,
    explorer_restore_button:  ^widgets.Button,
    console_toggle_button:    ^widgets.Button,
    console_restore_button:   ^widgets.Button,
    // Titlebar task controls, left of the window controls: add, the selector
    // naming the active task (opens the dropdown), and run (see tasks.odin).
    tasks_add_button:         ^widgets.Button,
    tasks_select_button:      ^widgets.Button,
    tasks_run_button:         ^widgets.Button,
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
    // Paths awaiting a delete confirmation (set when Delete is pressed in the
    // explorer, consumed when the confirm dialog is accepted). Owned clones; more
    // than one when the explorer selection spans several rows.
    pending_delete_paths:     [dynamic]string,
    // Message shown in the delete confirmation dialog; borrowed by the palette
    // while it is open, so it must outlive the dialog. Owned clone.
    delete_prompt:            string,
    // Path awaiting a rename (set when a rename is started in the explorer or
    // the File menu, consumed when the name prompt is accepted). Owned clone.
    pending_rename_path:      string,
    git_branch:               string,
    // Named shell commands from <workspace>/.thor/tasks.json, reloaded on a
    // workspace switch. active_task_name is what the selector shows and the run
    // button runs, held by name so a reload can re-resolve it and the session
    // can restore it; pending_task_name carries the name between the two prompts
    // of Add Task. Both owned clones.
    tasks:                    [dynamic]^Task,
    active_task_name:         string,
    pending_task_name:        string,
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
    // Language intelligence: in-client analyzers (and, later, an LSP subprocess)
    // behind one seam. Requests run on worker threads and are reaped each frame.
    lang_manager:             lang.Manager,
    odin_engine:              ^odin.Engine,
    // Recursive async watch of the workspace tree. Its changes feed the explorer
    // (tree + git refresh) and the open buffers (reload on external edits) via
    // subscribers wired in thor_init_watcher. The two flags coalesce a burst of
    // events into a single explorer refresh per poll.
    watcher:                  watch.Watcher,
    watch_tree_dirty:         bool,
    watch_git_dirty:          bool,
    goto_def_key:             setting.Keybind,
    goto_symbol_key:          setting.Keybind,
    goto_workspace_symbol_key: setting.Keybind,
    find_references_key:      setting.Keybind,
    signature_help_key:       setting.Keybind,
    package_doc_key:          setting.Keybind,
    code_actions_key:         setting.Keybind,
    // Go-to-symbol picker state: the jump targets (file + byte offset) for the
    // rows currently shown, in picker order. Rebuilt each time the picker opens;
    // the pick callback indexes into them on a later frame. Owned.
    doc_symbols:              [dynamic]Doc_Symbol,
    // A go-to-definition whose target file is still loading; applied by
    // thor_update_files once the buffer lands. Path is an owned clone.
    pending_goto_active:      bool,
    pending_goto_path:        string,
    pending_goto_offset:      int,
    // When >0 the deferred jump targets this 1-based line/column (console error
    // output) and the offset is resolved once the buffer loads.
    pending_goto_line:        int,
    pending_goto_col:         int,
    // Where jumps came from, and where Go Back walked out of. Both owned, both
    // capped at JUMP_LIST_MAX; jump_navigating suppresses recording while those
    // two commands are the ones moving the caret.
    jump_back_key:            setting.Keybind,
    jump_forward_key:         setting.Keybind,
    jump_back:                [dynamic]Jump_Point,
    jump_forward:             [dynamic]Jump_Point,
    jump_navigating:          bool,
    // In-flight hover request: the editor pane that asked and the request id, so
    // a result can be routed back to the right pane and stale ones dropped.
    hover_editor:             ^widgets.Editor,
    hover_request_id:         u64,
    // In-flight workspace-symbols scan: its request id. The picker opens
    // immediately in a loading state; the matching result fills it in, and a
    // superseded (or already-replaced) result is dropped.
    workspace_symbols_request_id: u64,
    // In-flight find-references scan: its request id. Like the workspace-symbols
    // picker, the results picker opens immediately (loading) and is filled when
    // the matching scan lands; a superseded result is dropped.
    references_request_id:    u64,
    // In-flight signature-help request: its request id, so a superseded result
    // (the caret moved on to another call) is dropped rather than flashed.
    signature_request_id:     u64,
    // Whether the in-flight signature request was auto-triggered (typing in a
    // call) rather than the explicit keybind. An auto request that resolves to no
    // call silently dismisses the popup; the explicit one flashes "No signature".
    signature_auto:           bool,
    // In-flight completion request: the pane it came from and its request id, so a
    // superseded result (a later keystroke fired a newer request) is dropped and
    // the candidates route back to the right editor.
    completion_editor:        ^widgets.Editor,
    completion_request_id:    u64,
    // In-flight package-doc request: its request id, so a superseded result (a
    // newer F3 for another package) is dropped instead of overwriting the newer one.
    package_doc_request_id:   u64,
    // In-flight rename: its request id and the path of the buffer it was computed
    // against (owned), so its edits can be told apart from the ones landing in
    // other files — that buffer is validated against the snapshotted revision,
    // the others must be unmodified since the engine read them off disk.
    rename_request_id:        u64,
    rename_path:              string,
    // In-flight code-action request, and the fixes the last one offered. The
    // Result they came from is freed as soon as the handler returns, so the edits
    // are cloned here for the pick callback to apply on a later frame; the path
    // and revision are the buffer they were computed against, which the applier
    // validates them against exactly as it does a rename's.
    code_action_request_id:   u64,
    code_action_path:         string,
    code_action_revision:     u64,
    code_actions:             [dynamic]Pending_Action,
    // How to reverse the last edit set applied across files (a rename, a code
    // action), so ctrl+z takes all of it back — the files that were not open
    // were rewritten on disk and have no buffer undo history of their own.
    edit_undo:                [dynamic]Edit_Undo_File,
    // Transient statusline notice (e.g. "No definition found") and the time it
    // was posted; thor_status_info hides it once STATUS_MESSAGE_SECS elapse.
    status_message:           string,
    status_message_time:      f64,
    status_message_error:     bool,
}

init :: proc() -> ^Thor {
    start := time.tick_now()
    phase := start
    lap :: proc(phase: ^time.Tick, name: string) {
        log.infof("[startup] %-24s %.1f ms", name, time.duration_milliseconds(time.tick_since(phase^)))
        phase^ = time.tick_now()
    }
    
    // Resolve the launch path (owned, absolute) BEFORE moving the CWD: a path
    // argument wins — a folder becomes the workspace, a file opens in a tab with
    // its folder as the workspace, "." is the directory Thor was called from.
    // Everything below loads relative to the CWD, which we then repoint at the
    // exe directory.
    workspace_dir: string
    startup_file: string // owned; opened once the UI and the session are up
    if len(os.args) > 1 {
        workspace_dir, startup_file = thor_startup_target(os.args[1])
    }
    launch_dir: string
    if cwd, cwd_err := os.get_working_directory(context.allocator); cwd_err == nil {
        launch_dir = cwd
    } else {
        launch_dir = strings.clone(".")
    }

    if exe_path, exe_err := os.get_executable_path(context.temp_allocator); exe_err == nil {
        if set_err := os.set_working_directory(os.dir(exe_path)); set_err != nil {
            log.warnf("Could not set working directory to exe dir: %v", set_err)
        }
    } else {
        log.warnf("Could not resolve executable path: %v", exe_err)
    }

    // No path argument: pick up the last session's workspace, falling back to
    // the launch directory (first run, or that folder is gone). The record sits
    // in the exe-relative sessions/ dir, so this runs after the CWD move.
    if workspace_dir == "" {
        workspace_dir = thor_last_workspace()
    }
    if workspace_dir == "" {
        workspace_dir = launch_dir
    } else {
        delete(launch_dir)
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

    // Window/taskbar icon; freed once raylib has copied it.
    icon := rl.LoadImage("assets/branding/thor.png")
    if icon.data != nil {
        rl.SetWindowIcon(icon)
        rl.UnloadImage(icon)
    }
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
    thor_load_tasks(thor)
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.finished_loads = make([dynamic]^Load_Job)
    thor.finished_saves = make([dynamic]^Save_Job)
    thor.finished_console = make([dynamic]^Console_Job)
    thor.finished_git = make([dynamic]^Git_Status_Job)

    // Language intelligence: register the in-client Odin engine first so it wins
    // for .odin files; an optional LSP subprocess backend would register after it.
    lang.manager_init(&thor.lang_manager)
    thor.odin_engine = odin.engine_create()
    lang.manager_register(&thor.lang_manager, odin.engine_backend(thor.odin_engine))

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
    thor_settings_mark_clean(thor)

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
        thor_plugin_workspace,
        thor_plugin_active_path,
        thor_plugin_read,
        thor_plugin_write,
        thor_plugin_refresh_git,
        thor_plugin_menu,
        thor_plugin_prompt,
        thor_plugin_pick,
        thor_plugin_confirm,
    )
    plugin.manager_load(&thor.plugins)
    thor_set_active_file(thor, -1)
    thor_restore_session(thor)
    // A file passed on the command line opens last, so it is the active tab.
    if startup_file != "" {
        thor_open_file(thor, startup_file)
        delete(startup_file)
    }
    thor_apply_layout_state(thor)
    thor_apply_split(thor)
    if thor.split_visible {
        thor_bind_pane(thor, 1)
    }
    ui.context_set_root(&thor.ui_context, &thor.root_panel.widget)
    ui.context_set_global_key(&thor.ui_context, thor_global_key, thor)
    thor_refresh_git_status(thor)
    thor_init_watcher(thor)
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
    // Icon families are only registered once loading finishes, same as fonts
    // above. Every family in a group shares one flat set of icon names, so one
    // of them must win explicitly rather than by map iteration order.
    thor_activate_icon_pack(PRIMARY_ICON_PACK_GROUP, setting.icon_pack_name(&thor.config), DEFAULT_ICON_PACK)
    thor_activate_icon_pack(FILE_ICON_PACK_GROUP, setting.file_icon_pack_name(&thor.config), DEFAULT_FILE_ICON_PACK)
    lap(&phase, "text_finish_async_load")

    log.infof("Startup took %.1f ms", time.duration_milliseconds(time.tick_since(start)))

    return thor
}

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
        thor_poll_dropped_files(thor)
        thor_poll_watcher(thor)
        thor_poll_settings(thor)
        thor_update_files(thor)
        lang.manager_dispatch(&thor.lang_manager, thor, thor_on_lang_result)
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
    // Stop the watcher first so no new reload jobs are queued while we drain.
    thor_shutdown_watcher(thor)
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
    thor_clear_pending_deletes(thor)
    delete(thor.pending_delete_paths)
    delete(thor.delete_prompt)
    delete(thor.pending_rename_path)
    delete(thor.git_branch)
    thor_clear_tasks(thor)
    delete(thor.active_task_name)
    delete(thor.pending_task_name)
    lang.manager_destroy(&thor.lang_manager)
    delete(thor.pending_goto_path)
    thor_clear_jump_list(thor)
    delete(thor.jump_back)
    delete(thor.jump_forward)
    delete(thor.rename_path)
    delete(thor.code_action_path)
    thor_clear_edit_undo(thor)
    thor_clear_code_actions(thor)
    delete(thor.code_actions)
    delete(thor.status_message)
    thor_clear_doc_symbols(thor)
    delete(thor.doc_symbols)
    for pb in thor.plugin_buttons {
        for entry in pb.entries {
            delete(entry.label)
            delete(entry.command)
        }
        delete(pb.entries)
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
    rl.UnloadTexture(thor.top_logo_texture)
    rl.CloseWindow()
    free(thor)
}
