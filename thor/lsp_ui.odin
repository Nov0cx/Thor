package thor

import "core:fmt"
import "core:strings"

import "../lang"
import "../lang/lsp"
import "../plugin"
import "../ui"
import "../widgets"

// The "Language Servers" settings category: what every configured server is,
// what state it is in, and the actions that get it working. It replaces the
// seven bundled "*-setup" plugins — the PATH check is native here
// (lsp.executable_find, no process spawn) and an install runs in the console.

// The sidebar entry this file fills. Named so a command can open Settings on it.
LSP_CATEGORY :: "language_servers"

// Row id prefix for every action row here, so one handler tells them apart from
// the plugin, backend and feature rows settings_ui.odin owns.
@(private = "file")
LSP_ACTION_PREFIX :: "lsp_action:"

// What one action does, and to which server. `argument` is a server id for the
// per-server verbs and a file path for Open.
@(private = "file")
Lsp_Action :: enum {
    Restart,
    Add,
    Rescan,
    Install,
    Docs,
    Setup,
    Open,
}

@(private = "file")
LSP_ACTION_NAMES := [Lsp_Action]string {
    .Restart = "restart",
    .Add     = "add",
    .Rescan  = "rescan",
    .Install = "install",
    .Docs    = "docs",
    .Setup   = "setup",
    .Open    = "open",
}

// Whether a program was found on PATH, kept between populates. The lookup stats
// every PATH directory, and the catalog holds dozens of servers, so it is not
// repeated for a row that only changed its toggle.
Lsp_Probe :: struct {
    exe:       string, // owned
    installed: bool,
}

@(private = "file")
thor_lsp_action_id :: proc(action: Lsp_Action, argument: string) -> string {
    return strings.concatenate({LSP_ACTION_PREFIX, LSP_ACTION_NAMES[action], ":", argument}, context.temp_allocator)
}

// The action and argument a row id names, if it names one.
@(private = "file")
thor_lsp_action_name :: proc(id: string) -> (action: Lsp_Action, argument: string, ok: bool) {
    if !strings.has_prefix(id, LSP_ACTION_PREFIX) {
        return .Restart, "", false
    }
    rest := id[len(LSP_ACTION_PREFIX):]
    colon := strings.index_byte(rest, ':')
    if colon < 0 {
        return .Restart, "", false
    }
    for name, candidate in LSP_ACTION_NAMES {
        if name == rest[:colon] {
            return candidate, rest[colon + 1:], true
        }
    }
    return .Restart, "", false
}

// A server's own fold group. The feature group beside it keeps the id
// settings_ui.odin already gives it, so a fold the user set survives this.
@(private = "file")
thor_lsp_group :: proc(id: string) -> string {
    return strings.concatenate({"language_servers.", id}, context.temp_allocator)
}

// Opens Settings on this category, for the command and the menu row.
thor_cmd_open_language_servers :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_populate_settings_view(thor)
    widgets.settings_view_open_at(thor.settings_view, &thor.ui_context, LSP_CATEGORY)
}

// Builds the whole category. Called from thor_populate_settings_view, so it is
// rebuilt on open, on a scope switch and after every change.
thor_populate_lsp_category :: proc(thor: ^Thor) {
    view := thor.settings_view
    widgets.settings_view_begin_category(view, LSP_CATEGORY, "Language Servers", "server")

    thor_lsp_populate_problems(thor)

    widgets.settings_view_add_action(view, thor_lsp_action_id(.Restart, ""), "Restart Language Servers", "Restart")
    widgets.settings_view_add_action(view, thor_lsp_action_id(.Add, ""), "Add a Server...", "Add")
    widgets.settings_view_add_action(view, thor_lsp_action_id(.Rescan, ""), "Look for Installed Servers Again", "Scan")

    for id in lsp.client_server_ids(thor.lsp_client, context.temp_allocator) {
        thor_lsp_populate_server(thor, id)
    }
}

// The Problems group, present only when a config file has something wrong with
// it. Expanded, since a problem the user has to see must not start folded.
@(private = "file")
thor_lsp_populate_problems :: proc(thor: ^Thor) {
    problems := lsp.client_diagnostics(thor.lsp_client)
    if len(problems) == 0 {
        return
    }

    view := thor.settings_view
    widgets.settings_view_begin_group(
        view,
        "language_servers.problems",
        "Configuration Problems",
        value = fmt.tprintf("%d", len(problems)),
        tone = .Bad,
    )
    for problem, index in problems {
        label := problem.id != "" ? problem.id : "lsp.json"
        if problem.file != "" {
            label = fmt.tprintf("%s · %s", problem.file, label)
        }
        widgets.settings_view_add_info(view, fmt.tprintf("lsp_info:problem:%d", index), label, problem.message, .Bad)
    }
    for path in ([?]string{lsp.GLOBAL_CONFIG, lsp.USER_CONFIG}) {
        if !thor_lsp_problem_names(problems, path) {
            continue
        }
        widgets.settings_view_add_action(view, thor_lsp_action_id(.Open, path), fmt.tprintf("Open %s", path), "Open")
    }
    widgets.settings_view_end_group(view)
}

@(private = "file")
thor_lsp_problem_names :: proc(problems: []lsp.Config_Problem, path: string) -> bool {
    for problem in problems {
        if problem.file == path {
            return true
        }
    }
    return false
}

// One server: a fold group of what it is and what to do about it, then the
// feature group settings_ui.odin's own row ids drive.
@(private = "file")
thor_lsp_populate_server :: proc(thor: ^Thor, id: string) {
    view := thor.settings_view
    status, found := lsp.client_server_status(thor.lsp_client, id, context.temp_allocator, probe = false)
    if !found {
        return
    }
    probe := thor_lsp_probe(thor, id, status.command)
    status.exe = probe.exe
    status.installed = probe.installed

    on, features := thor_backend_gate(thor, &thor.config, id)
    summary, summary_tone := thor_lsp_summary(status, on)

    widgets.settings_view_begin_group(
        view, thor_lsp_group(id), status.name, collapsed = true, value = summary, tone = summary_tone,
    )

    info :: proc(view: ^widgets.Settings_View, id, field, label, value: string, tone := widgets.Settings_Tone.Normal) {
        // Ids stay distinct per server, so a row always names one thing even
        // though nothing clicks an info row.
        widgets.settings_view_add_info(view, fmt.tprintf("lsp_info:%s:%s", id, field), label, value, tone)
    }

    info(view, id, "state", "Status", lsp.server_state_name(status.state), thor_lsp_state_tone(status.state))
    info(view, id, "command", "Program", strings.join(status.command, " ", context.temp_allocator))
    if status.installed {
        info(view, id, "exe", "Installed At", status.exe)
    } else {
        info(view, id, "exe", "Installed At", "not found on PATH", .Warn)
    }
    if status.root != "" {
        info(view, id, "root", "Project Root", status.root)
    }

    extensions := strings.join(status.extensions, " ", context.temp_allocator)
    if status.claimed_by != "" {
        info(view, id, "ext", "File Types", fmt.tprintf("%s — answered by %s", extensions, status.claimed_by), .Warn)
    } else {
        info(view, id, "ext", "File Types", extensions)
    }
    if status.last_error != "" {
        info(view, id, "error", "Last Error", status.last_error, .Bad)
    }

    widgets.settings_view_add_choice(view, thor_language_backend_id(id), "Enabled", thor_on_off_label(on))
    if !status.installed && status.install_command != "" {
        widgets.settings_view_add_action(view, thor_lsp_action_id(.Install, id), "Install It", "Install")
    }
    if status.setup_command != "" {
        widgets.settings_view_add_action(view, thor_lsp_action_id(.Setup, id), "Set Up This Project", "Configure")
    }
    if status.docs_url != "" {
        widgets.settings_view_add_action(view, thor_lsp_action_id(.Docs, id), "Documentation", "Open")
    }
    widgets.settings_view_end_group(view)

    if !on {
        return
    }
    widgets.settings_view_begin_group(
        view, thor_language_backend_feature_group(id), fmt.tprintf("%s Features", status.name), collapsed = true,
        value = fmt.tprintf("%d of %d on", card(features), len(lang.Request_Kind)),
    )
    for kind in lang.Request_Kind {
        widgets.settings_view_add_choice(
            view,
            thor_language_backend_feature_id(id, kind),
            LANGUAGE_FEATURE_LABELS[kind],
            thor_on_off_label(kind in features),
        )
    }
    widgets.settings_view_end_group(view)
}

// The one line a folded group shows. Off and not-installed come before the
// running state: both mean the language has no server whatever the process did.
@(private = "file")
thor_lsp_summary :: proc(status: lsp.Server_Status, enabled: bool) -> (string, widgets.Settings_Tone) {
    switch {
    case !enabled:
        return "Off", .Normal
    case !status.installed:
        return "Not installed", .Warn
    case status.claimed_by != "":
        return "Not used", .Warn
    }
    return lsp.server_state_name(status.state), thor_lsp_state_tone(status.state)
}

@(private = "file")
thor_lsp_state_tone :: proc(state: lsp.Server_State) -> widgets.Settings_Tone {
    #partial switch state {
    case .Ready:
        return .Good
    case .Crashed:
        return .Warn
    case .Failed:
        return .Bad
    }
    return .Normal
}

// The cached PATH lookup for one server, refreshed when the command changed.
@(private = "file")
thor_lsp_probe :: proc(thor: ^Thor, id: string, command: []string) -> Lsp_Probe {
    if probe, cached := thor.lsp_probes[id]; cached {
        return probe
    }
    probe: Lsp_Probe
    if len(command) > 0 {
        probe.exe, probe.installed = lsp.executable_find(command[0])
    }
    thor.lsp_probes[strings.clone(id)] = probe
    return probe
}

// Drops the PATH lookups, so the next populate finds a server installed since.
thor_lsp_clear_probes :: proc(thor: ^Thor) {
    for id, probe in thor.lsp_probes {
        delete(probe.exe)
        delete(id)
    }
    clear(&thor.lsp_probes)
}

thor_lsp_probes_destroy :: proc(thor: ^Thor) {
    thor_lsp_clear_probes(thor)
    delete(thor.lsp_probes)
    thor.lsp_probes = nil
}

// An action row was pressed. Every verb here either changes nothing or defers
// its work: a reload destroys the widget tree this call stands on.
thor_on_setting_action :: proc(data: rawptr, id: string) {
    thor := cast(^Thor) data
    action, argument, ok := thor_lsp_action_name(id)
    if !ok {
        return
    }
    switch action {
    case .Restart:
        thor_cmd_restart_language_servers(thor)
    case .Add:
        thor_lsp_prompt_new_server(thor)
    case .Rescan:
        thor_lsp_clear_probes(thor)
        thor_populate_settings_view(thor)
        thor_flash_status(thor, "Looked for installed language servers again")
    case .Install:
        thor_lsp_install(thor, argument)
    case .Docs:
        thor_lsp_open_docs(thor, argument)
    case .Setup:
        thor_lsp_run_setup(thor, argument)
    case .Open:
        thor_open_file(thor, argument)
    }
}

// Asks first, then runs the install in the console: an installer runs well past
// any budget a callback may hold the frame for, and its output is what the user
// needs to see when it goes wrong.
@(private = "file")
thor_lsp_install :: proc(thor: ^Thor, id: string) {
    status, found := lsp.client_server_status(thor.lsp_client, id, context.temp_allocator, probe = false)
    if !found || status.install_command == "" {
        return
    }
    delete(thor.lsp_install_command)
    thor.lsp_install_command = strings.clone(status.install_command)
    delete(thor.lsp_install_prompt)
    thor.lsp_install_prompt = strings.clone(
        fmt.tprintf("Install %s with: %s", status.name, status.install_command),
    )
    widgets.command_palette_confirm(
        thor.command_palette,
        &thor.ui_context,
        thor.lsp_install_prompt,
        thor_lsp_confirm_install,
        thor,
    )
}

@(private = "file")
thor_lsp_confirm_install :: proc(data: rawptr) {
    thor := cast(^Thor) data
    command := thor.lsp_install_command
    if command == "" {
        return
    }
    if thor.console == nil {
        thor_flash_status(thor, "Open a terminal first", is_error = true)
        return
    }
    if !ui.signal_get(&thor.console_visible) {
        ui.signal_set(&thor.console_visible, true)
    }
    if !widgets.console_run_command(thor.console, command) {
        thor_flash_status(thor, "A command is already running", is_error = true)
        return
    }
    // The PATH lookup is stale the moment the install finishes, and nothing here
    // is told when that is.
    thor_lsp_clear_probes(thor)
}

@(private = "file")
thor_lsp_open_docs :: proc(thor: ^Thor, id: string) {
    status, found := lsp.client_server_status(thor.lsp_client, id, context.temp_allocator, probe = false)
    if !found || status.docs_url == "" {
        return
    }
    if !thor_open_in_browser(status.docs_url) {
        thor_flash_status(thor, "Could not open the documentation", is_error = true)
    }
}

// Runs the plugin command an entry names as its project setup — clangd's
// compile_commands.json helper is the one that ships.
@(private = "file")
thor_lsp_run_setup :: proc(thor: ^Thor, id: string) {
    status, found := lsp.client_server_status(thor.lsp_client, id, context.temp_allocator, probe = false)
    if !found || status.setup_command == "" {
        return
    }
    if !plugin.manager_run_command(&thor.plugins, status.setup_command) {
        // The plugin that answers it may be waiting for its permissions, which
        // Settings' own Plugins section is where the user grants.
        thor_flash_status(
            thor,
            fmt.tprintf("No plugin answers %q — check Settings > Plugins", status.setup_command),
            is_error = true,
        )
    }
}
