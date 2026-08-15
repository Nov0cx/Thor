package thor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import rl "vendor:raylib"

import "../lang"
import "../lang/lsp"
import "../lang/odin"
import "../plugin"
import "../setting"
import "../shell"
import "../ui"
import "../update"
import "../watch"
import "../widgets"

Thor :: struct {
    ui_context: ui.Context,
    config: setting.Settings,
    plugins: plugin.Manager,
    theme: ui.Theme,
    // The theme picker's rows, cached so opening it does not re-parse every
    // palette. Parallel and aligned by index; see thor_available_theme_choices.
    theme_labels: []string, // owned
    theme_files: []string, // owned
    theme_stamp: i64, // newest modification time the cache was built from
    // The color role the picker is editing and the value it had when it opened,
    // so a cancel puts it back. Owned; "" when no picker is up.
    theme_edit_key: string, // owned
    theme_edit_original: rl.Color,
    // Generator seeds, kept between the rows that set them and the Generate row.
    theme_seed_background: rl.Color,
    theme_seed_accent: rl.Color,
    theme_seed_dark: bool,
    // True while thor.theme holds a generated preview rather than the configured
    // palette, so an edit cannot write the preview over a saved theme.
    theme_preview_generated: bool,
    root_panel: ^widgets.Panel,
    root_stack: ^widgets.Stack,
    top_bar: ^widgets.Titlebar,
    workspace_row: ^widgets.Stack,
    explorer_stub_panel: ^widgets.Panel,
    explorer_stub_stack: ^widgets.Stack,
    explorer_panel: ^widgets.Panel,
    explorer_stack: ^widgets.Stack,
    explorer_header: ^widgets.Stack,
    explorer_splitter: ^widgets.Splitter,
    editor_column: ^widgets.Stack,
    editor_panel: ^widgets.Panel,
    console_splitter: ^widgets.Splitter,
    console_panel: ^widgets.Panel,
    console_stack: ^widgets.Stack,
    console_header: ^widgets.Stack,
    console_stub_panel: ^widgets.Panel,
    console_stub_stack: ^widgets.Stack,
    tree: ^widgets.Tree,
    tabbar: ^widgets.Tabbar,
    statusbar: ^widgets.Statusbar,
    editor: ^widgets.Editor,
    // Second editor pane, shown side-by-side with the first when the split is
    // on. Both view the active file's buffer (shared state, independent scroll).
    editor2: ^widgets.Editor,
    // Overlays the editor panel when the active file is an image; the editor
    // rows are hidden while it shows.
    image_view: ^widgets.Image_View,
    // The same overlay for 3D model files: an orbit camera over the loaded meshes.
    model_view: ^widgets.Model_View,
    // Rendered markdown preview, shown in place of whichever pane is not
    // focused (pane 0's slot / pane 1's slot respectively) while preview is on
    // and the active file is markdown. Toggled by "View: Toggle Markdown Preview".
    markdown_view: ^widgets.Markdown_View,
    markdown_view2: ^widgets.Markdown_View,
    markdown_preview: bool,
    editor_split_row: ^widgets.Stack,
    editor_split_splitter: ^widgets.Splitter,
    // Shown in place of the editor while workspace_dir is "" (startup with no
    // path/session, or after Close Workspace). welcome_recent_stack is rebuilt
    // on every show; welcome_recent_entries are its buttons' owned click data.
    welcome_panel: ^widgets.Panel,
    welcome_title_label: ^widgets.Label,
    welcome_subtitle_label: ^widgets.Label,
    welcome_recent_label: ^widgets.Label,
    welcome_recent_stack: ^widgets.Stack,
    welcome_recent_entries: [dynamic]^Welcome_Recent_Entry,
    welcome_open_folder_button: ^widgets.Button,
    welcome_open_file_button: ^widgets.Button,
    // Tip of the day; hidden while no config layer holds a tip.
    welcome_tip_card: ^widgets.Tip_Card,
    // The same tip, floating over the editor. Opened on the first start of a
    // day with a workspace open, where the welcome page is not shown.
    startup_tip_card: ^widgets.Tip_Card,
    // The active terminal's console; nil when the last terminal is closed.
    console: ^widgets.Console,
    terminal_tabs: ^widgets.Tabstrip,
    command_palette: ^widgets.Command_Palette,
    // Modal picker for Preferences (theme/font), with live preview.
    select_dialog: ^widgets.Select_Dialog,
    // Modal prompt listing the plugins waiting on a permission answer.
    permission_dialog: ^widgets.Permission_Dialog,
    // Modal GUI editor for every setting (editor prefs, theme/font, keybinds).
    settings_view: ^widgets.Settings_View,
    // Modal theme window (every color role of the active theme), opened by the
    // Theme Colors row of Settings. See theme_ui.odin.
    theme_editor: ^widgets.Theme_Editor,
    // Modal color picker the theme window's rows open.
    color_picker: ^widgets.Color_Picker,
    // Modal git UI (changes, commit; more views to come). See git_ui.odin.
    git_view: ^widgets.Git_View,
    // Auto-reload of the config files: a signature of their modification times,
    // refreshed after each load; the poll loop reloads when it changes on disk.
    settings_sig: i64,
    settings_poll_time: f64,
    find_replace: ^widgets.Find_Replace,
    menu: ^widgets.Menu,
    command_palette_key: setting.Keybind,
    quick_open_key: setting.Keybind,
    fullscreen_key: setting.Keybind,
    console_toggle_key: setting.Keybind,
    find_key: setting.Keybind,
    replace_key: setting.Keybind,
    focus_editor_key: setting.Keybind,
    focus_explorer_key: setting.Keybind,
    focus_terminal_key: setting.Keybind,
    trim_whitespace_key: setting.Keybind,
    format_key: setting.Keybind,
    format_selection_key: setting.Keybind,
    align_char_key: setting.Keybind,
    goto_line_key: setting.Keybind,
    last_file_key: setting.Keybind,
    close_tab_key: setting.Keybind,
    next_tab_key: setting.Keybind,
    previous_tab_key: setting.Keybind,
    toggle_explorer_key: setting.Keybind,
    // Toggles the editor split. Unbound by default (KEY_NULL), so it only fires
    // once the user sets a "toggle_split" chord in keybinds.json.
    split_key: setting.Keybind,
    active_file: ui.Signal(int),
    // Most-recently-active file before the current one, for the ctrl+e flip.
    // Cleared when that file is closed so the pointer never dangles.
    last_active_file: ^Open_File,
    explorer_visible: ui.Signal(bool),
    console_visible: ui.Signal(bool),
    menu_file_button: ^widgets.Button,
    menu_edit_button: ^widgets.Button,
    menu_view_button: ^widgets.Button,
    menu_git_button: ^widgets.Button,
    menu_help_button: ^widgets.Button,
    // Titlebar hammer mark and its borrowed texture (unloaded at shutdown).
    top_logo: ^widgets.Logo,
    top_logo_texture: rl.Texture2D,
    // Titlebar/panel labels that carry a theme color, kept so a live theme
    // change can recolor them (most labels are theme-neutral and not stored).
    explorer_title_label: ^widgets.Label,
    explorer_toggle_button: ^widgets.Button,
    explorer_restore_button: ^widgets.Button,
    console_toggle_button: ^widgets.Button,
    console_restore_button: ^widgets.Button,
    // Titlebar task controls, left of the window controls: add, the selector
    // naming the active task (opens the dropdown), and run (see tasks.odin).
    tasks_add_button: ^widgets.Button,
    tasks_select_button: ^widgets.Button,
    tasks_run_button: ^widgets.Button,
    minimize_button: ^widgets.Button,
    maximize_button: ^widgets.Button,
    close_button: ^widgets.Button,
    // Top-bar buttons added by plugins via thor.button, and the widget a new one
    // is linked in after (advances so buttons keep registration order).
    plugin_buttons: [dynamic]^Plugin_Top_Button,
    // Panels plugins built (thor.panel) and the two docks holding them. A dock
    // shows only while one of its panels does (see plugin_panel.odin).
    plugin_panels: [dynamic]^Plugin_Panel,
    // Plugins held until the user allows the permissions they ask for, and the
    // prompt that asks for one source of them (see plugin_trust.odin).
    plugin_requests: [dynamic]Plugin_Request,
    plugin_prompt_shown: bool,
    plugin_prompt_source: Plugin_Source,
    // An answer asked for the plugin VM to be rebuilt; done on the next frame.
    plugin_reload_pending: bool,
    // The release a check found (see update.odin). The titlebar button borrows
    // update_version as its label and the palette borrows update_prompt, so both
    // outlive the widgets. All owned; empty until a check finds something.
    update_version: string,
    update_notes: string,
    update_url: string,
    update_sums_url: string,
    update_asset: string,
    update_prompt: string,
    update_size: i64,
    update_state: Update_State,
    update_button: ^widgets.Button,
    update_installable: bool,
    // The prompt is asked once per found version: a dismissal is remembered in
    // sessions/update.json and the button becomes the only way back to it.
    update_prompt_shown: bool,
    update_started: bool,
    update_inflight: bool,
    // The running install job, borrowed, so a quit can ask it to stop.
    update_job: ^Update_Job,
    // A staged update waiting to be swapped in. Owned; the swap runs from
    // thor_poll_update and never from the io drain, which shutdown also calls.
    update_swap_root: string,
    // Plugin whose permission row opened the picker (see settings_ui.odin).
    plugin_setting_target: string,  // owned
    plugin_setting_source: Plugin_Source,
    // Backend id ("odin", or an lsp.json server id) whose on/off picker is open;
    // see thor_cmd_change_language_backend. Shared with
    // thor_cmd_change_language_backend_feature, which additionally sets
    // language_backend_feature_kind — the two never have a picker open at once.
    language_backend_target: string,  // owned
    language_backend_feature_kind: lang.Request_Kind,
    plugin_dock_right: ^widgets.Panel,
    plugin_dock_right_stack: ^widgets.Stack,
    plugin_dock_bottom: ^widgets.Panel,
    plugin_dock_bottom_stack: ^widgets.Stack,
    top_bar_plugin_anchor: ^ui.Widget,
    should_close: bool,
    window_maximized: bool,
    explorer_width: f32,
    console_height: f32,
    split_visible: bool,
    split_ratio: f32,
    // Each pane's open-files index (-1 = none); the two panes can show different
    // files. active_pane is the focused one, whose file the tabbar, status bar
    // and file commands act on (mirrored into the active_file signal).
    pane_file: [2]int,
    active_pane: int,
    // App/file/view commands that ship without a keybinding. Each carries its
    // config action name and resolved chord; unbound ones (KEY_NULL) never fire.
    // Dispatched globally, so only commands with no editor-local key belong here.
    app_binds: [dynamic]App_Bind,
    workspace_dir: string,
    workspace_prefix: string,  // workspace_dir + separator, for palette display
    // True when workspace_dir has a .thor/ directory: its config overlays the
    // global settings, and it is treated as an initialized workspace.
    workspace_initialized: bool,
    // Directory a New File/Folder prompt creates into; set from the explorer
    // right-click target or the workspace root. Owned clone.
    menu_target_dir: string,
    // Tab index a right-click context menu was opened on (editor tabs, terminal
    // tabs), consumed by the menu's own row callbacks.
    menu_target_tab: int,
    menu_target_terminal: int,
    // Paths awaiting a delete confirmation (set when Delete is pressed in the
    // explorer, consumed when the confirm dialog is accepted). Owned clones; more
    // than one when the explorer selection spans several rows.
    pending_delete_paths: [dynamic]string,
    // Message shown in the delete confirmation dialog; borrowed by the palette
    // while it is open, so it must outlive the dialog. Owned clone.
    delete_prompt: string,
    // File the open conflict prompt asks about (borrowed, nil when none is open),
    // and that prompt's message. The message is borrowed by the palette while the
    // prompt is open, so it must outlive it. Owned clone.
    conflict_file: ^Open_File,
    conflict_prompt: string,
    // Path awaiting a rename (set when a rename is started in the explorer or
    // the File menu, consumed when the name prompt is accepted). Owned clone.
    pending_rename_path: string,
    // Folder awaiting a this-window/new-window choice, and the prompt title the
    // picker shows. The title is borrowed by the palette while it is open, so
    // both must outlive the pick. Owned clones, cleared once the pick lands.
    pending_open_folder: string,
    open_folder_prompt: string,
    git_branch: string,
    // Repo root + separator, the prefix every git status/diff key is built from.
    // Git prints paths relative to the repo root, which is not the workspace when
    // a subdirectory is opened. Owned; "" when the workspace is not in a repo.
    git_prefix: string,
    // Named shell commands from <workspace>/.thor/tasks.json, reloaded on a
    // workspace switch. active_task_name is what the selector shows and the run
    // button runs, held by name so a reload can re-resolve it and the session
    // can restore it; pending_task_name carries the name between the two prompts
    // of Add Task. Both owned clones.
    tasks: [dynamic]^Task,
    active_task_name: string,
    pending_task_name: string,
    open_files: [dynamic]^Open_File,
    zombie_files: [dynamic]^Open_File,
    // Worker threads append finished jobs here under io_mutex; drained on the
    // main thread every frame.
    io_mutex: sync.Mutex,
    finished_loads: [dynamic]^Load_Job,
    finished_saves: [dynamic]^Save_Job,
    finished_git: [dynamic]^Git_Status_Job,
    finished_git_ops: [dynamic]^Git_Op_Job,
    finished_file_ops: [dynamic]^File_Op_Job,
    finished_shells: [dynamic]^Shell_Detect_Job,
    finished_file_index: [dynamic]^File_Index_Job,
    finished_updates: [dynamic]^Update_Job,
    inflight_jobs: int,
    // Quick-open's cached file list, warmed off-thread at workspace open and
    // refreshed on watcher activity; thor_palette_list_files falls back to a
    // synchronous walk while !file_index_ready. Owned, with the strings in it.
    // file_index_inflight/dirty coalesce a burst the same way git status does.
    file_index: [dynamic]string,
    file_index_ready: bool,
    file_index_inflight: bool,
    file_index_dirty: bool,
    file_index_at: time.Tick,
    // Plugin output printed while no terminal exists — shell detection is async,
    // so a plugin load body prints before the first one opens. Flushed into that
    // terminal when it opens. owned
    console_backlog: strings.Builder,
    // One terminal per console tab, each on its own shell. owned
    terminals: [dynamic]^Terminal,
    // True between thor_terminals_init and thor_terminals_shutdown. An empty
    // terminal list and a shut-down one are the same value, so the state is
    // held apart from it.
    terminals_live: bool,
    active_terminal: int,
    // The shells installed on this machine, best first. owned
    shell_profiles: []shell.Profile,
    shell_choices: []Shell_Choice,  // owned, one per profile
    // Working-tree status keyed by absolute path (matches tree node paths),
    // recomputed off-thread; git_status_inflight guards against overlapping runs.
    git_status: map[string]widgets.Git_Status,
    git_status_inflight: bool,
    git_status_dirty: bool,  // a refresh was requested while one was running
    // Git view op state (see git_ops.odin): the generation stamps every job so
    // results from a closed view or an earlier workspace are dropped; the
    // serial does the same for a superseded file diff; the snapshot flags
    // coalesce like git_status_inflight/dirty; one mutation runs at a time.
    git_ui_generation: int,
    git_diff_serial: int,
    git_ui_snapshot_inflight: bool,
    git_ui_snapshot_dirty: bool,
    git_mutation_inflight: bool,
    // Commits the history view has asked for; "Load more" raises it.
    git_log_count: int,
    // What origin points at (owned strings; kind None while unknown), whether
    // the gh/glab CLIs answered a probe, and whether the open hosting view
    // already asked for its PR list.
    git_host: Git_Host_Info,
    git_has_gh: bool,
    git_has_glab: bool,
    git_cli_probed: bool,
    git_prs_requested: bool,
    // Discard confirmation state: the path awaiting the answer and the prompt
    // the palette borrows while it is open. Owned clones.
    git_discard_path: string,
    git_discard_prompt: string,
    // Language intelligence: in-client analyzers (and, later, an LSP subprocess)
    // behind one seam. Requests run on worker threads and are reaped each frame.
    lang_manager: lang.Manager,
    odin_engine: ^odin.Engine,
    // The optional subprocess LSP backend. Owned by the manager, which destroys
    // every backend it holds, so shutdown frees nothing here.
    lsp_client: ^lsp.Client,
    // Whether each configured server's program answers on PATH, kept between
    // Settings populates: the lookup stats every PATH directory and the table
    // holds dozens of servers. Keys and Lsp_Probe.exe owned; see thor/lsp_ui.odin.
    lsp_probes: map[string]Lsp_Probe,
    // The install command the Language Servers panel is asking about and the
    // prompt the palette borrows while it is open; owned.
    lsp_install_command: string,
    lsp_install_prompt: string,
    // Set when an lsp.json layer changed or the user asked for a restart. Acted
    // on at the head of the run loop, never inside an event: thor_reload_lang
    // destroys the backend a dispatch may be standing on.
    lang_reload_pending: bool,
    // Signature of the three lsp.json layers, and the per-server states the
    // health poll last saw. Both owned; see thor/settings_watch.odin.
    lsp_sig: i64,
    lsp_health: [dynamic]Lsp_Health,
    lsp_health_poll_time: f64,
    // Recursive async watch of the workspace tree. Its changes feed the explorer
    // (tree + git refresh) and the open buffers (reload on external edits) via
    // subscribers wired in thor_init_watcher. The two flags coalesce a burst of
    // events into a single explorer refresh per poll.
    watcher: watch.Watcher,
    watch_tree_dirty: bool,
    watch_git_dirty: bool,
    goto_def_key: setting.Keybind,
    goto_symbol_key: setting.Keybind,
    goto_workspace_symbol_key: setting.Keybind,
    find_references_key: setting.Keybind,
    signature_help_key: setting.Keybind,
    package_doc_key: setting.Keybind,
    code_actions_key: setting.Keybind,
    // Go-to-symbol picker state: the jump targets (file + byte offset) for the
    // rows currently shown, in picker order. Rebuilt each time the picker opens;
    // the pick callback indexes into them on a later frame. Owned.
    doc_symbols: [dynamic]Doc_Symbol,
    // A go-to-definition whose target file is still loading; applied by
    // thor_update_files once the buffer lands. Path is an owned clone.
    pending_goto_active: bool,
    pending_goto_path: string,
    pending_goto_offset: int,
    // When >0 the deferred jump targets this 1-based line/column (console error
    // output) and the offset is resolved once the buffer loads.
    pending_goto_line: int,
    pending_goto_col: int,
    // Where jumps came from, and where Go Back walked out of. Both owned, both
    // capped at JUMP_LIST_MAX; jump_navigating suppresses recording while those
    // two commands are the ones moving the caret.
    jump_back_key: setting.Keybind,
    jump_forward_key: setting.Keybind,
    jump_back: [dynamic]Jump_Point,
    jump_forward: [dynamic]Jump_Point,
    jump_navigating: bool,
    // In-flight hover request: the editor pane that asked and the request id, so
    // a result can be routed back to the right pane and stale ones dropped.
    hover_editor: ^widgets.Editor,
    hover_request_id: u64,
    // In-flight workspace-symbols scan: its request id. The picker opens
    // immediately in a loading state; the matching result fills it in, and a
    // superseded (or already-replaced) result is dropped.
    workspace_symbols_request_id: u64,
    // True while that in-flight scan was re-dispatched by typing in the open
    // picker rather than by opening it: an empty result then means "no
    // matches for this text", not "nothing to show", so it must not close
    // the picker the way the initial empty-workspace case does.
    workspace_symbols_typing: bool,
    // True when the dispatched scan targets a server-backed extension rather
    // than the native Odin engine: a server may answer an unfiltered (empty
    // query) scan with nothing until the user types (workspace/symbol on
    // clangd, gopls, ...), so an empty *initial* result there means "type to
    // search", not "no symbols in workspace" — it must not close the picker.
    workspace_symbols_needs_query: bool,
    // In-flight find-references scan: its request id. Like the workspace-symbols
    // picker, the results picker opens immediately (loading) and is filled when
    // the matching scan lands; a superseded result is dropped.
    references_request_id: u64,
    // In-flight signature-help request: the pane it came from and its request id,
    // so a superseded result (the caret moved on to another call, or a plain tab
    // switch with no new request) is dropped rather than routed to a stale pane.
    signature_editor: ^widgets.Editor,
    signature_request_id: u64,
    // Whether the in-flight signature request was auto-triggered (typing in a
    // call) rather than the explicit keybind. An auto request that resolves to no
    // call silently dismisses the popup; the explicit one flashes "No signature".
    signature_auto: bool,
    // In-flight completion request: the pane it came from and its request id, so a
    // superseded result (a later keystroke fired a newer request) is dropped and
    // the candidates route back to the right editor.
    completion_editor: ^widgets.Editor,
    completion_request_id: u64,
    // In-flight package-doc request: its request id, so a superseded result (a
    // newer F3 for another package) is dropped instead of overwriting the newer one.
    package_doc_request_id: u64,
    // In-flight semantic-tokens request: its id and the classified buffer's path
    // (owned — the file may be closed and freed before the result lands, so it is
    // looked up by path, not held by pointer). One at a time, which throttles a
    // whole-file classification to its own round trip.
    semantic_request_id: u64,
    semantic_path: string,
    // In-flight rename: its request id and the path of the buffer it was computed
    // against (owned), so its edits can be told apart from the ones landing in
    // other files — that buffer is validated against the snapshotted revision,
    // the others must be unmodified since the engine read them off disk.
    rename_request_id: u64,
    rename_path: string,
    // In-flight code-action request, and the fixes the last one offered. The
    // Result they came from is freed as soon as the handler returns, so the edits
    // are cloned here for the pick callback to apply on a later frame; the path
    // and revision are the buffer they were computed against, which the applier
    // validates them against exactly as it does a rename's.
    code_action_request_id: u64,
    code_action_path: string,
    code_action_revision: u64,
    code_actions: [dynamic]Pending_Action,
    // In-flight Execute_Command, and the title to report when it answers: a
    // command-only fix runs on the server, so the pick only reports whether it
    // was accepted — the changes arrive later as a pushed Apply_Edit.
    execute_command_request_id: u64,
    execute_command_title: string, // owned
    // In-flight format request: its id and the path of the buffer it was computed
    // against (owned). format_save_pending marks a save waiting on the result,
    // which thor_apply_format runs on every terminal outcome so a save is never
    // held hostage by formatting. format_save_queue is Save All's remaining files
    // (owned paths), taken one at a time since .Format has one consumer slot.
    format_request_id: u64,
    format_path: string,
    format_save_pending: bool,
    format_save_queue: [dynamic]string,
    // In-flight Format_Range request (Format Selection): its id and the path of
    // the buffer it was computed against (owned). Its own slot rather than
    // sharing format_path — a document format and a selection format can be
    // dispatched moments apart and must not clobber each other's routing.
    format_range_request_id: u64,
    format_range_path: string,
    // In-flight Format_On_Type request: its id and the buffer path (owned). No
    // save-pending bookkeeping — on-type formatting never blocks a save.
    on_type_request_id: u64,
    on_type_path: string,
    // How to move the last cross-file edit set (a rename, a code action), so
    // ctrl+z takes all of it back — files that were not open were rewritten on
    // disk and have no buffer history. Exactly one set is live in each direction:
    // undo hands its record to edit_redo and redo hands it back, so every string
    // is allocated once and freed once. owned
    edit_undo: [dynamic]Edit_Undo_File,
    edit_redo: [dynamic]Edit_Undo_File,
    // Statusline analyzer indicator: the request kinds in flight, when the
    // current busy stretch began, and whether it has lasted long enough to be
    // worth showing (see thor_lang_busy_update).
    lang_busy_kinds: bit_set[lang.Request_Kind],
    lang_busy_since: f64,
    lang_busy_shown: bool,
    // The current $/progress message an LSP server is reporting (e.g.
    // "Indexing... (40%)"), owned and cloned; "" when nothing is in progress.
    // Shown in place of lang_busy_kinds' generic label when set.
    lsp_progress_message: string,
    // Transient statusline notice (e.g. "No definition found") and the time it
    // was posted; thor_status_info hides it once STATUS_MESSAGE_SECS elapse.
    status_message: string,
    status_message_time: f64,
    status_message_error: bool,
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
    startup_files: [dynamic]string  // owned; opened once the UI and the session are up
    if len(os.args) > 1 {
        workspace_dir, startup_files = thor_startup_targets(thor_cli_paths(os.args, context.temp_allocator))
    }
    defer delete(startup_files)

    if exe_path, exe_err := os.get_executable_path(context.temp_allocator); exe_err == nil {
        if set_err := os.set_working_directory(os.dir(exe_path)); set_err != nil {
            log.warnf("Could not set working directory to exe dir: %v", set_err)
        }
    } else {
        log.warnf("Could not resolve executable path: %v", exe_err)
    }

    // No path argument: pick up the last session's workspace. If there is
    // none (first run, or that folder is gone), workspace_dir stays empty
    // and the welcome page opens instead of a folder. The record sits in
    // the exe-relative sessions/ dir, so this runs after the CWD move.
    if workspace_dir == "" {
        workspace_dir = thor_last_workspace()
    }

    // Settle an interrupted update before anything reads assets/ or plugins/:
    // a swap that died leaves the old copy under its .old name, and this is
    // what puts it back.
    update.install_cleanup_leftovers()

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
    thor_reset_theme_seeds(thor)
    thor.active_file = ui.make_signal(-1)
    thor.explorer_visible = ui.make_signal(true)
    thor.console_visible = ui.make_signal(true)
    ui.signal_set_listener(&thor.explorer_visible, thor_on_visibility_changed, thor)
    ui.signal_set_listener(&thor.console_visible, thor_on_visibility_changed, thor)
    thor.explorer_width = 250
    thor.console_height = 190
    thor.split_ratio = 0.5
    thor.pane_file = {-1, -1}
    thor.workspace_dir = workspace_dir
    if workspace_dir != "" {
        thor.workspace_prefix = strings.concatenate({workspace_dir, filepath.SEPARATOR_STRING})
        thor_apply_git_repo(thor, workspace_dir)
        thor_record_recent_workspace(workspace_dir)
    }
    thor_load_tasks(thor)
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.lsp_probes = make(map[string]Lsp_Probe)
    thor.lsp_health = make([dynamic]Lsp_Health)
    thor.finished_loads = make([dynamic]^Load_Job)
    thor.finished_saves = make([dynamic]^Save_Job)
    thor.finished_git = make([dynamic]^Git_Status_Job)
    thor.finished_git_ops = make([dynamic]^Git_Op_Job)
    thor.finished_file_ops = make([dynamic]^File_Op_Job)
    thor.finished_shells = make([dynamic]^Shell_Detect_Job)
    thor.finished_file_index = make([dynamic]^File_Index_Job)
    thor.finished_updates = make([dynamic]^Update_Job)
    thor.file_index = make([dynamic]string)
    strings.builder_init(&thor.console_backlog)

    // Language intelligence: registration order is precedence. The in-client Odin
    // engine goes first, so it wins for .odin files and the LSP backend serves
    // the languages it configures; a server that sets "override" for .odin takes
    // the front instead. The decision is made once, here, so no request path
    // branches on it. No server process starts until a file it claims opens.
    lang.manager_init(&thor.lang_manager)
    thor.odin_engine = odin.engine_create()
    thor.lsp_client = lsp.client_create(thor.workspace_dir)
    if lsp.client_overrides(thor.lsp_client, ".odin") {
        lang.manager_register(&thor.lang_manager, lsp.client_backend(thor.lsp_client))
        lang.manager_register(&thor.lang_manager, odin.engine_backend(thor.odin_engine))
    } else {
        lang.manager_register(&thor.lang_manager, odin.engine_backend(thor.odin_engine))
        lang.manager_register(&thor.lang_manager, lsp.client_backend(thor.lsp_client))
    }

    log.infof("Loaded theme: %s", thor.theme.name)

    thor_build_ui(thor)
    thor.select_dialog.return_focus = &thor.editor.widget
    widgets.command_palette_set_navigation(thor.command_palette, thor_palette_list_files, thor_palette_open_file, thor_palette_goto_line, thor.workspace_prefix, thor)
    thor_register_commands(thor)
    thor_wire_menus(thor)
    // After the tree is built: a terminal adds its console to the console stack.
    thor_terminals_init(thor)
    thor_apply_settings(thor)
    thor_settings_mark_clean(thor)
    thor_lsp_mark_clean(thor)

    // Now that the console and keybinds exist, expose the host services and load
    // plugins (their load body may print or query keybinds, e.g. the tutorial).
    // Plugin top-bar buttons link in just after the Help button.
    thor.top_bar_plugin_anchor = &thor.menu_help_button.widget
    thor_set_plugin_host(thor)
    thor_load_plugins(thor)
    thor_set_active_file(thor, -1)
    thor_restore_session(thor)
    // Files passed on the command line open last and in order, so the final one
    // is the active tab. thor_open_file de-dupes, so a path the session already
    // restored is activated rather than opened twice.
    for path in startup_files {
        thor_open_file(thor, path)
        delete(path)
    }
    thor_apply_layout_state(thor)
    thor_apply_split(thor)
    if thor.split_visible {
        thor_bind_pane(thor, 1)
    }
    ui.context_set_root(&thor.ui_context, &thor.root_panel.widget)
    ui.context_set_global_key(&thor.ui_context, thor_global_key, thor)
    thor_refresh_git_status(thor)
    thor_refresh_file_index(thor)
    thor_init_watcher(thor)
    // Claim the workspace now that the window handle exists, so another window
    // opening this folder raises us instead of starting a duplicate.
    thor_register_window(thor)
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

    // After the session: the card measures its own text, and the fonts it
    // measures with are only loaded above.
    thor_tip_open_startup(thor)

    log.infof("Startup took %.1f ms", time.duration_milliseconds(time.tick_since(start)))

    return thor
}

// Records the repo `workspace_dir` sits in: the key prefix git output is joined
// onto, and the branch name for the status bar. Both stay "" outside a repo.
thor_apply_git_repo :: proc(thor: ^Thor, workspace_dir: string) {
    root, git_dir, ok := thor_find_git_repo(workspace_dir)
    if !ok {
        return
    }
    thor.git_prefix = strings.concatenate({root, filepath.SEPARATOR_STRING})
    thor.git_branch = thor_read_git_branch(git_dir)
}

// The repo root at or above `dir`, and the directory that holds HEAD. `.git` is a
// directory in a normal checkout and a file naming a `gitdir:` in a worktree or a
// submodule, where HEAD lives at that target instead. Both results are scratch.
thor_find_git_repo :: proc(dir: string) -> (root, git_dir: string, ok: bool) {
    if dir == "" {
        return
    }
    current := thor_abs_path(dir)
    for {
        dot_git, join_err := filepath.join({current, ".git"}, context.temp_allocator)
        if join_err != nil {
            return
        }
        if os.is_dir(dot_git) {
            return current, dot_git, true
        }
        if target, has := thor_read_gitdir_pointer(current, dot_git); has {
            return current, target, true
        }
        parent := thor_parent_dir(current)
        if parent == current {
            return
        }
        current = parent
    }
}

// The `gitdir: <path>` a `.git` file names, made absolute against the directory
// holding it. A worktree writes an absolute path, a submodule a relative one.
@(private = "file")
thor_read_gitdir_pointer :: proc(dir, pointer_path: string) -> (git_dir: string, ok: bool) {
    data, read_err := os.read_entire_file(pointer_path, context.temp_allocator)
    if read_err != nil {
        return
    }
    PREFIX :: "gitdir:"
    text := strings.trim_space(string(data))
    if !strings.has_prefix(text, PREFIX) {
        return
    }
    target := strings.trim_space(text[len(PREFIX):])
    if target == "" {
        return
    }
    if filepath.is_abs(target) {
        return target, true
    }
    joined, join_err := filepath.join({dir, target}, context.temp_allocator)
    if join_err != nil {
        return
    }
    return joined, true
}

// Branch name out of `<git_dir>/HEAD`, or the short commit hash when detached.
thor_read_git_branch :: proc(git_dir: string) -> string {
    head_path, join_err := filepath.join({git_dir, "HEAD"}, context.temp_allocator)
    if join_err != nil {
        return ""
    }
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
        // Before anything dispatches: the rebuild drains the manager and
        // destroys the LSP backend, which no in-flight request may be inside.
        thor_poll_lang_reload(thor)
        thor_update_files(thor)
        thor_sync_lang_documents(thor)
        lang.manager_dispatch(&thor.lang_manager, thor, thor_on_lang_result)
        thor_poll_lang_busy(thor)
        thor_poll_lsp_health(thor)
        // Asked here, not during init: the prompt takes focus, and init still
        // opens files and restores the session after the plugins load. The
        // rebuild an answer asks for is done here too, not in the dialog
        // callback, which dispatches from widgets the rebuild destroys.
        thor_poll_plugin_reload(thor)
        thor_prompt_plugin_permissions(thor)
        // Here for the same reason: the update prompt takes focus, and the swap
        // it can start replaces the files the frame below would draw from.
        thor_poll_update(thor)
        plugin.manager_dispatch_tick(&thor.plugins)
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
    thor_unregister_window(thor.workspace_dir)
    thor_save_session(thor)
    // Stop the watcher first so no new reload jobs are queued while we drain.
    thor_shutdown_watcher(thor)
    thor_terminals_shutdown(thor)
    // A download in flight would otherwise hold the drain for the rest of the
    // archive; asked to stop, it gives up after the current slice.
    thor_cancel_update(thor)
    thor_drain_io(thor)

    for file in thor.open_files {
        thor_free_open_file(file)
    }
    delete(thor.open_files)
    delete(thor.zombie_files)
    delete(thor.finished_loads)
    delete(thor.finished_saves)
    delete(thor.finished_git)
    delete(thor.finished_git_ops)
    delete(thor.finished_file_ops)
    delete(thor.finished_shells)
    delete(thor.finished_file_index)
    delete(thor.finished_updates)
    thor_clear_update(thor)
    thor_clear_file_index(thor)
    thor_free_theme_choices(thor)
    strings.builder_destroy(&thor.console_backlog)
    delete(thor.app_binds)
    thor_clear_git_status(thor)
    delete(thor.workspace_dir)
    delete(thor.workspace_prefix)
    delete(thor.menu_target_dir)
    thor_clear_pending_deletes(thor)
    delete(thor.pending_delete_paths)
    delete(thor.delete_prompt)
    delete(thor.conflict_prompt)
    delete(thor.pending_rename_path)
    thor_clear_pending_open_folder(thor)
    delete(thor.git_branch)
    delete(thor.git_prefix)
    delete(thor.git_discard_path)
    delete(thor.git_discard_prompt)
    git_host_info_destroy(&thor.git_host)
    thor_clear_tasks(thor)
    delete(thor.active_task_name)
    delete(thor.pending_task_name)
    lang.manager_destroy(&thor.lang_manager)
    thor_lsp_probes_destroy(thor)
    thor_lsp_health_destroy(thor)
    delete(thor.lsp_install_command)
    delete(thor.lsp_install_prompt)
    delete(thor.pending_goto_path)
    thor_clear_jump_list(thor)
    delete(thor.jump_back)
    delete(thor.jump_forward)
    delete(thor.rename_path)
    delete(thor.code_action_path)
    delete(thor.execute_command_title)
    delete(thor.semantic_path)
    delete(thor.format_path)
    delete(thor.format_range_path)
    delete(thor.on_type_path)
    for p in thor.format_save_queue {
        delete(p)
    }
    delete(thor.format_save_queue)
    thor_clear_edit_undo(thor)
    thor_clear_edit_redo(thor)
    thor_clear_code_actions(thor)
    delete(thor.code_actions)
    delete(thor.status_message)
    delete(thor.lsp_progress_message)
    thor_clear_doc_symbols(thor)
    delete(thor.doc_symbols)
    thor_clear_plugin_buttons(thor, false)
    delete(thor.plugin_buttons)
    thor_clear_plugin_panels(thor, false)
    delete(thor.plugin_panels)
    thor_clear_plugin_requests(thor)
    delete(thor.plugin_requests)
    delete(thor.plugin_setting_target)
    delete(thor.theme_edit_key)
    delete(thor.language_backend_target)
    thor_welcome_clear_recent_entries(thor)
    delete(thor.welcome_recent_entries)
    setting.destroy(&thor.config)
    plugin.manager_destroy(&thor.plugins)

    ui.theme_destroy(&thor.theme)
    ui.context_destroy(&thor.ui_context)
    ui.text_shutdown()
    rl.UnloadTexture(thor.top_logo_texture)
    rl.CloseWindow()
    free(thor)
}
