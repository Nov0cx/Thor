package thor

// Permission prompts for plugins. A plugin whose plugin.json asks for a
// capability (exec, read, write, ui, keys) does not run until the user allows
// it. The answer is remembered under <exe>/sessions/, so the question is asked
// once per machine, and every plugin still waiting is asked in one prompt.

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"

import "../plugin"
import "../widgets"

@(private = "file")
GRANTS_FILE :: "sessions/plugin-grants.json"

// One remembered answer. `permissions` is what was allowed, so a plugin that
// later asks for more is asked again.
@(private = "file")
Plugin_Grant :: struct {
    id:          string,
    permissions: []string,
}

@(private = "file")
Plugin_Grants :: struct {
    plugins: []Plugin_Grant,
}

// A plugin found on disk and held until the user answers.
Plugin_Request :: struct {
    id:    string, // owned
    dir:   string, // owned
    perms: plugin.Permissions,
}

// Loads the plugins. Anything asking for no permission (every language plugin)
// runs at once; the rest run only once allowed, either by a remembered answer or
// by the prompt this opens on the first frame.
thor_load_plugins :: proc(thor: ^Thor) {
    granted := thor_read_plugin_grants(context.temp_allocator)

    for p in plugin.manager_scan(&thor.plugins) {
        if p.perms == {} {
            plugin.manager_load_plugin(&thor.plugins, p.id, p.dir, {})
            continue
        }
        if allowed, known := granted[p.id]; known && p.perms - allowed == {} {
            plugin.manager_load_plugin(&thor.plugins, p.id, p.dir, p.perms)
            continue
        }
        append(&thor.plugin_requests, Plugin_Request {
            id    = strings.clone(p.id),
            dir   = strings.clone(p.dir),
            perms = p.perms,
        })
    }
}

// Opens the batched permission prompt, once, on the first frame that has a
// widget tree to show it in. No-op when nothing is waiting.
thor_prompt_plugin_permissions :: proc(thor: ^Thor) {
    if thor.plugin_prompt_shown || len(thor.plugin_requests) == 0 {
        return
    }
    thor.plugin_prompt_shown = true

    b := strings.builder_make()
    strings.write_string(&b, "Allow these plugins? ")
    for request, i in thor.plugin_requests {
        if i > 0 {
            strings.write_string(&b, "; ")
        }
        strings.write_string(&b, request.id)
        strings.write_string(&b, ": ")
        names := plugin.permission_names(request.perms, context.temp_allocator)
        strings.write_string(&b, strings.join(names, ", ", context.temp_allocator))
    }
    strings.write_string(&b, "  (change later in Settings)")
    thor.plugin_prompt_message = strings.to_string(b)

    widgets.command_palette_confirm(
        thor.command_palette,
        &thor.ui_context,
        thor.plugin_prompt_message,
        thor_grant_plugin_permissions,
        thor,
    )
}

// Confirming the prompt: run every waiting plugin with what it asked for, and
// remember the answer. Dismissing it leaves them unloaded and unrecorded, so the
// question comes back next start.
@(private = "file")
thor_grant_plugin_permissions :: proc(data: rawptr) {
    thor := cast(^Thor) data
    for request in thor.plugin_requests {
        plugin.manager_load_plugin(&thor.plugins, request.id, request.dir, request.perms)
    }
    thor_write_plugin_grants(thor)
    thor_clear_plugin_requests(thor)
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

// One plugin as the Settings modal shows it: what it wants, whether it may have
// it, and whether it is running in this session. Strings use `allocator`.
Plugin_Permission_State :: struct {
    id:      string,
    dir:     string,
    perms:   plugin.Permissions,
    allowed: bool,
    loaded:  bool,
}

// Every installed plugin that asks for a permission, in scan order. Re-reads
// disk, so the Settings modal always shows the current state.
thor_plugin_permission_states :: proc(thor: ^Thor, allocator := context.temp_allocator) -> []Plugin_Permission_State {
    granted := thor_read_plugin_grants(context.temp_allocator)
    out := make([dynamic]Plugin_Permission_State, allocator)
    for p in plugin.manager_scan(&thor.plugins) {
        if p.perms == {} {
            continue
        }
        allowed, known := granted[p.id]
        _, loaded := plugin.manager_permissions(&thor.plugins, p.id)
        append(&out, Plugin_Permission_State {
            id      = strings.clone(p.id, allocator),
            dir     = strings.clone(p.dir, allocator),
            perms   = p.perms,
            allowed = known && p.perms - allowed == {},
            loaded  = loaded,
        })
    }
    return out[:]
}

// Allows or denies `id`, remembering the answer. Allowing runs the plugin at
// once when it is not already running; denying only takes effect on restart,
// since a loaded plugin cannot be taken back out of the VM.
thor_set_plugin_allowed :: proc(thor: ^Thor, id: string, allow: bool) {
    known := thor_read_plugin_grants(context.temp_allocator)
    state: Plugin_Permission_State
    found := false
    for candidate in thor_plugin_permission_states(thor) {
        if candidate.id == id {
            state = candidate
            found = true
            break
        }
    }
    if !found {
        return
    }

    if allow {
        known[id] = state.perms
    } else if id in known {
        delete_key(&known, id)
    }
    thor_save_plugin_grants(known)

    if allow && !state.loaded {
        if plugin.manager_load_plugin(&thor.plugins, state.id, state.dir, state.perms) {
            thor_flash_status(thor, "Plugin loaded")
        }
        // The plugin is no longer waiting on the prompt.
        for request, i in thor.plugin_requests {
            if request.id == id {
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

// Reads the remembered answers as id -> permissions. Keys use `allocator`.
@(private = "file")
thor_read_plugin_grants :: proc(allocator := context.allocator) -> map[string]plugin.Permissions {
    out := make(map[string]plugin.Permissions, allocator = allocator)
    data, err := os.read_entire_file(GRANTS_FILE, context.temp_allocator)
    if err != nil {
        return out
    }
    grants: Plugin_Grants
    if uerr := json.unmarshal(data, &grants, allocator = context.temp_allocator); uerr != nil {
        log.warnf("Could not read %q: %v", GRANTS_FILE, uerr)
        return out
    }
    for entry in grants.plugins {
        out[strings.clone(entry.id, allocator)] = plugin.permissions_from_names(entry.permissions)
    }
    return out
}

// Records the prompt's answers, keeping the ones already on file for plugins
// that are not installed right now.
@(private = "file")
thor_write_plugin_grants :: proc(thor: ^Thor) {
    known := thor_read_plugin_grants(context.temp_allocator)
    for request in thor.plugin_requests {
        known[request.id] = request.perms
    }
    thor_save_plugin_grants(known)
}

// Writes the grant file from `known`.
@(private = "file")
thor_save_plugin_grants :: proc(known: map[string]plugin.Permissions) {
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }

    entries := make([dynamic]Plugin_Grant, 0, len(known), context.temp_allocator)
    for id, perms in known {
        append(&entries, Plugin_Grant {
            id          = id,
            permissions = plugin.permission_names(perms, context.temp_allocator),
        })
    }

    data, err := json.marshal(Plugin_Grants {entries[:]}, {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal plugin grants: %v", err)
        return
    }
    if werr := os.write_entire_file(GRANTS_FILE, data); werr != nil {
        log.errorf("Could not write %q: %v", GRANTS_FILE, werr)
    }
}
