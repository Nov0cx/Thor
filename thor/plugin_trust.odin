package thor

// Permission prompts for plugins. A plugin whose plugin.json asks for a
// capability (exec, read, write, ui, keys) does not run until the user allows
// it. The answer is remembered under <exe>/sessions/, so the question is asked
// once per machine, and every plugin still waiting is asked in one prompt.
//
// Plugins come from two places: the folder beside the executable, and the open
// workspace's own `.thor/plugins/`. A workspace plugin is code carried by the
// folder that was opened, so it is asked about even when it wants no permission
// at all — loading one runs its Lua. Its answer is remembered per workspace, and
// the two sources are asked about apart, so allowing what Thor ships is not also
// a yes to what a cloned repository brought with it.

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../plugin"
import "../widgets"

@(private = "file")
GRANTS_FILE :: "sessions/plugin-grants.json"

// Where a plugin was found. A workspace plugin is untrusted until allowed.
Plugin_Source :: enum {
    Bundled,
    Workspace,
}

// The workspace folder plugins are read from, relative to the workspace root.
WORKSPACE_PLUGIN_DIR :: ".thor/plugins"

// One remembered answer for a bundled plugin. `permissions` is what was allowed,
// so a plugin that later asks for more is asked again.
@(private = "file")
Plugin_Grant :: struct {
    id:          string,
    permissions: []string,
}

// A workspace plugin's answer, tied to the folder it was allowed in: the same
// plugin id in another workspace is different code and is asked about again.
@(private)
Workspace_Grant :: struct {
    workspace:   string,
    id:          string,
    permissions: []string,
}

@(private = "file")
Plugin_Grants :: struct {
    plugins:    []Plugin_Grant,
    workspaces: []Workspace_Grant,
}

// A plugin found on disk and held until the user answers.
Plugin_Request :: struct {
    id:     string, // owned
    dir:    string, // owned
    perms:  plugin.Permissions,
    source: Plugin_Source,
}

// Loads the plugins of both sources. The workspace's own are settled first: an
// allowed one replaces the bundled plugin of the same id, which is how a project
// pins its own language or tooling. A bundled plugin asking for no permission
// runs at once; everything else runs only once allowed, either by a remembered
// answer or by the prompt this opens on the first frame.
thor_load_plugins :: proc(thor: ^Thor) {
    bundled, workspaces := thor_read_grant_file()

    // A workspace plugin still waiting on the prompt shadows nothing, so the
    // bundled plugin of that id keeps working until the answer comes in.
    shadowed := make(map[string]bool, context.temp_allocator)
    for p in thor_scan_workspace_plugins(thor) {
        allowed, known := thor_find_workspace_grant(workspaces[:], thor.workspace_dir, p.id)
        if known && p.perms - allowed == {} {
            // Shadowed even when the load fails: an override that errors must
            // report itself, not silently hand the id back to the bundled one.
            shadowed[p.id] = true
            plugin.manager_load_plugin(&thor.plugins, p.id, p.dir, p.perms)
            continue
        }
        thor_hold_plugin(thor, p, .Workspace)
    }

    for p in plugin.manager_scan(&thor.plugins) {
        if p.id in shadowed {
            log.infof("Plugin %s comes from %s in this workspace", p.id, WORKSPACE_PLUGIN_DIR)
            continue
        }
        if p.perms == {} {
            plugin.manager_load_plugin(&thor.plugins, p.id, p.dir, {})
            continue
        }
        if allowed, known := thor_find_grant(bundled[:], p.id); known && p.perms - allowed == {} {
            plugin.manager_load_plugin(&thor.plugins, p.id, p.dir, p.perms)
            continue
        }
        thor_hold_plugin(thor, p, .Bundled)
    }
}

// Tears the plugin VM down and loads both sources again. The VM cannot take a
// single plugin back out — a plugin's registrations are spread over the language
// table, the command table and the widget tree — so the whole set is rebuilt
// wherever it changes at once: a workspace swap, and an answer that makes a
// workspace plugin replace (or stop replacing) a bundled one.
thor_reload_plugins :: proc(thor: ^Thor) {
    thor.plugin_reload_pending = false
    thor_clear_plugin_buttons(thor, true)
    thor_clear_plugin_panels(thor, true)
    thor_clear_plugin_requests(thor)
    thor.plugin_prompt_shown = false

    plugin.manager_destroy(&thor.plugins)
    plugin.manager_init(&thor.plugins)
    thor_set_plugin_host(thor)
    thor_load_plugins(thor)

    // The languages the new set registers decide how every open buffer colours.
    for file in thor.open_files {
        file.highlighted = false
    }
}

// Run-loop tick: rebuilds the plugins when an answer asked for it. Deferred to
// the frame rather than done inside the dialog callback, since the rebuild
// destroys widgets the dialog was dispatched from.
thor_poll_plugin_reload :: proc(thor: ^Thor) {
    if thor.plugin_reload_pending {
        thor_reload_plugins(thor)
    }
}

// The plugins the open workspace carries, or nothing when it has none.
@(private = "file")
thor_scan_workspace_plugins :: proc(thor: ^Thor, allocator := context.temp_allocator) -> []plugin.Pending_Plugin {
    if thor.workspace_dir == "" {
        return nil
    }
    root, err := filepath.join({thor.workspace_dir, ".thor", "plugins"}, context.temp_allocator)
    if err != nil {
        return nil
    }
    return plugin.manager_scan_dir(&thor.plugins, root, allocator)
}

// Holds a scanned plugin until the prompt is answered.
@(private = "file")
thor_hold_plugin :: proc(thor: ^Thor, p: plugin.Pending_Plugin, source: Plugin_Source) {
    append(&thor.plugin_requests, Plugin_Request {
        id     = strings.clone(p.id),
        dir    = strings.clone(p.dir),
        perms  = p.perms,
        source = source,
    })
}

// Opens the batched permission prompt for one source, bundled first. No-op when
// nothing is waiting or a prompt is already up.
thor_prompt_plugin_permissions :: proc(thor: ^Thor) {
    if thor.plugin_prompt_shown || len(thor.plugin_requests) == 0 {
        return
    }
    source := Plugin_Source.Bundled
    if !thor_has_plugin_requests(thor, .Bundled) {
        source = .Workspace
    }
    thor.plugin_prompt_shown = true
    thor.plugin_prompt_source = source

    b := strings.builder_make()
    if source == .Workspace {
        strings.write_string(&b, "Run this folder's own plugins? ")
    } else {
        strings.write_string(&b, "Allow these plugins? ")
    }
    first := true
    for request in thor.plugin_requests {
        if request.source != source {
            continue
        }
        if !first {
            strings.write_string(&b, "; ")
        }
        first = false
        strings.write_string(&b, request.id)
        strings.write_string(&b, ": ")
        strings.write_string(&b, thor_plugin_permission_text(request.perms))
    }
    if source == .Workspace {
        strings.write_string(&b, fmt.tprintf("  (from %s — change later in Settings)", WORKSPACE_PLUGIN_DIR))
    } else {
        strings.write_string(&b, "  (change later in Settings)")
    }
    thor.plugin_prompt_message = strings.to_string(b)

    widgets.command_palette_confirm(
        thor.command_palette,
        &thor.ui_context,
        thor.plugin_prompt_message,
        thor_grant_plugin_permissions,
        thor,
    )
}

// What a plugin asks for, as the prompt and the settings row spell it. A
// workspace plugin can ask for nothing and still need an answer, so the empty
// set says so rather than coming out blank.
@(private = "file")
thor_plugin_permission_text :: proc(perms: plugin.Permissions) -> string {
    if perms == {} {
        return "no permissions"
    }
    names := plugin.permission_names(perms, context.temp_allocator)
    return strings.join(names, ", ", context.temp_allocator)
}

// Confirming the prompt: run every waiting plugin of the source that was asked
// about, and remember the answer. Dismissing it leaves them unloaded and
// unrecorded, so the question comes back next start.
@(private = "file")
thor_grant_plugin_permissions :: proc(data: rawptr) {
    thor := cast(^Thor) data
    source := thor.plugin_prompt_source

    bundled, workspaces := thor_read_grant_file()
    for request in thor.plugin_requests {
        if request.source != source {
            continue
        }
        switch source {
        case .Bundled:
            thor_set_grant(&bundled, request.id, request.perms)
        case .Workspace:
            thor_set_workspace_grant(&workspaces, thor.workspace_dir, request.id, request.perms)
        }
    }
    thor_write_grant_file(bundled[:], workspaces[:])

    switch source {
    case .Bundled:
        for request in thor.plugin_requests {
            if request.source == .Bundled {
                plugin.manager_load_plugin(&thor.plugins, request.id, request.dir, request.perms)
            }
        }
        thor_drop_plugin_requests(thor, .Bundled)
        // Let the next frame ask about the workspace group, if there is one.
        thor.plugin_prompt_shown = false
        delete(thor.plugin_prompt_message)
        thor.plugin_prompt_message = ""
    case .Workspace:
        // An allowed workspace plugin may replace a bundled one already running,
        // which only a rebuild settles.
        thor.plugin_reload_pending = true
    }
}

// Whether any plugin of `source` is still waiting.
@(private = "file")
thor_has_plugin_requests :: proc(thor: ^Thor, source: Plugin_Source) -> bool {
    for request in thor.plugin_requests {
        if request.source == source {
            return true
        }
    }
    return false
}

// Frees and drops the waiting plugins of one source.
@(private = "file")
thor_drop_plugin_requests :: proc(thor: ^Thor, source: Plugin_Source) {
    for i := len(thor.plugin_requests) - 1; i >= 0; i -= 1 {
        if thor.plugin_requests[i].source != source {
            continue
        }
        delete(thor.plugin_requests[i].id)
        delete(thor.plugin_requests[i].dir)
        ordered_remove(&thor.plugin_requests, i)
    }
}

// Frees the pending requests and the prompt text.
thor_clear_plugin_requests :: proc(thor: ^Thor) {
    for request in thor.plugin_requests {
        delete(request.id)
        delete(request.dir)
    }
    clear(&thor.plugin_requests)
    delete(thor.plugin_prompt_message)
    thor.plugin_prompt_message = ""
}

// One plugin as the Settings modal shows it: where it came from, what it wants,
// whether it may have it, and whether it is running in this session. Strings use
// `allocator`.
Plugin_Permission_State :: struct {
    id:      string,
    dir:     string,
    perms:   plugin.Permissions,
    source:  Plugin_Source,
    allowed: bool,
    loaded:  bool,
}

// Every plugin the Settings modal has something to ask about: the bundled ones
// that want a permission, and all of the workspace's, which need an answer even
// with none. Re-reads disk, so the modal always shows the current state.
thor_plugin_permission_states :: proc(thor: ^Thor, allocator := context.temp_allocator) -> []Plugin_Permission_State {
    bundled, workspaces := thor_read_grant_file()
    out := make([dynamic]Plugin_Permission_State, allocator)

    shadowed := make(map[string]bool, context.temp_allocator)
    for p in thor_scan_workspace_plugins(thor) {
        allowed, known := thor_find_workspace_grant(workspaces[:], thor.workspace_dir, p.id)
        satisfied := known && p.perms - allowed == {}
        shadowed[p.id] = satisfied
        _, loaded := plugin.manager_permissions(&thor.plugins, p.id)
        append(&out, Plugin_Permission_State {
            id      = strings.clone(p.id, allocator),
            dir     = strings.clone(p.dir, allocator),
            perms   = p.perms,
            source  = .Workspace,
            allowed = satisfied,
            loaded  = loaded && satisfied,
        })
    }

    for p in plugin.manager_scan(&thor.plugins) {
        if p.perms == {} || shadowed[p.id] {
            continue
        }
        allowed, known := thor_find_grant(bundled[:], p.id)
        _, loaded := plugin.manager_permissions(&thor.plugins, p.id)
        append(&out, Plugin_Permission_State {
            id      = strings.clone(p.id, allocator),
            dir     = strings.clone(p.dir, allocator),
            perms   = p.perms,
            source  = .Bundled,
            allowed = known && p.perms - allowed == {},
            loaded  = loaded,
        })
    }
    return out[:]
}

// Allows or denies one plugin, remembering the answer. A bundled plugin runs at
// once when allowed, and a running one stays until Thor restarts when blocked.
// Either answer on a workspace plugin rebuilds the VM instead: it may start or
// stop replacing a bundled plugin, and revoked repository code must really stop.
thor_set_plugin_allowed :: proc(thor: ^Thor, source: Plugin_Source, id: string, allow: bool) {
    state: Plugin_Permission_State
    found := false
    for candidate in thor_plugin_permission_states(thor) {
        if candidate.source == source && candidate.id == id {
            state = candidate
            found = true
            break
        }
    }
    if !found {
        return
    }

    bundled, workspaces := thor_read_grant_file()
    switch source {
    case .Bundled:
        if allow {
            thor_set_grant(&bundled, id, state.perms)
        } else {
            thor_remove_grant(&bundled, id)
        }
    case .Workspace:
        if allow {
            thor_set_workspace_grant(&workspaces, thor.workspace_dir, id, state.perms)
        } else {
            thor_remove_workspace_grant(&workspaces, thor.workspace_dir, id)
        }
    }
    thor_write_grant_file(bundled[:], workspaces[:])

    if source == .Workspace {
        thor.plugin_reload_pending = true
        thor_flash_status(thor, allow ? "Plugin loaded" : "Plugin unloaded")
        return
    }
    if allow && !state.loaded {
        if plugin.manager_load_plugin(&thor.plugins, state.id, state.dir, state.perms) {
            thor_flash_status(thor, "Plugin loaded")
        }
        // The plugin is no longer waiting on the prompt.
        for request, i in thor.plugin_requests {
            if request.source == .Bundled && request.id == id {
                delete(request.id)
                delete(request.dir)
                ordered_remove(&thor.plugin_requests, i)
                break
            }
        }
    } else if !allow && state.loaded {
        thor_flash_status(thor, "Plugin stays active until Thor restarts")
    }
}

// Reads the grant file into its two lists, both temp-owned. A missing or
// malformed file reads as no answers at all, so nothing that wants a permission
// runs until it is asked about again.
@(private)
thor_read_grant_file :: proc() -> (bundled: [dynamic]Plugin_Grant, workspaces: [dynamic]Workspace_Grant) {
    bundled = make([dynamic]Plugin_Grant, context.temp_allocator)
    workspaces = make([dynamic]Workspace_Grant, context.temp_allocator)

    data, err := os.read_entire_file(GRANTS_FILE, context.temp_allocator)
    if err != nil {
        return
    }
    grants: Plugin_Grants
    if uerr := json.unmarshal(data, &grants, allocator = context.temp_allocator); uerr != nil {
        log.warnf("Could not read %q: %v", GRANTS_FILE, uerr)
        return
    }
    append(&bundled, ..grants.plugins)
    append(&workspaces, ..grants.workspaces)
    return
}

// Writes both lists back. Rows for workspaces that are not open right now ride
// along untouched, so answering here never forgets another folder's.
@(private = "file")
thor_write_grant_file :: proc(bundled: []Plugin_Grant, workspaces: []Workspace_Grant) {
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }
    data, err := json.marshal(Plugin_Grants {bundled, workspaces}, {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal plugin grants: %v", err)
        return
    }
    if werr := os.write_entire_file(GRANTS_FILE, data); werr != nil {
        log.errorf("Could not write %q: %v", GRANTS_FILE, werr)
    }
}

// The permissions remembered for a bundled plugin.
@(private)
thor_find_grant :: proc(rows: []Plugin_Grant, id: string) -> (perms: plugin.Permissions, known: bool) {
    for row in rows {
        if row.id == id {
            return plugin.permissions_from_names(row.permissions), true
        }
    }
    return {}, false
}

// The permissions remembered for a workspace plugin. The folder is matched
// case-insensitively: one workspace path can be spelled two ways on Windows, and
// a case-sensitive test would ask about the same plugin twice.
@(private)
thor_find_workspace_grant :: proc(rows: []Workspace_Grant, workspace, id: string) -> (perms: plugin.Permissions, known: bool) {
    if workspace == "" {
        return {}, false
    }
    for row in rows {
        if row.id == id && strings.equal_fold(row.workspace, workspace) {
            return plugin.permissions_from_names(row.permissions), true
        }
    }
    return {}, false
}

@(private)
thor_set_grant :: proc(rows: ^[dynamic]Plugin_Grant, id: string, perms: plugin.Permissions) {
    names := plugin.permission_names(perms, context.temp_allocator)
    for &row in rows {
        if row.id == id {
            row.permissions = names
            return
        }
    }
    append(rows, Plugin_Grant {id = id, permissions = names})
}

@(private)
thor_remove_grant :: proc(rows: ^[dynamic]Plugin_Grant, id: string) {
    for row, i in rows {
        if row.id == id {
            ordered_remove(rows, i)
            return
        }
    }
}

@(private)
thor_set_workspace_grant :: proc(rows: ^[dynamic]Workspace_Grant, workspace, id: string, perms: plugin.Permissions) {
    names := plugin.permission_names(perms, context.temp_allocator)
    for &row in rows {
        if row.id == id && strings.equal_fold(row.workspace, workspace) {
            row.permissions = names
            return
        }
    }
    append(rows, Workspace_Grant {workspace = workspace, id = id, permissions = names})
}

@(private)
thor_remove_workspace_grant :: proc(rows: ^[dynamic]Workspace_Grant, workspace, id: string) {
    for row, i in rows {
        if row.id == id && strings.equal_fold(row.workspace, workspace) {
            ordered_remove(rows, i)
            return
        }
    }
}
