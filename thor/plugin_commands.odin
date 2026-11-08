// The commands plugins register with thor.on_command, mirrored into the command
// palette and the bindable keys.
package thor

import "core:fmt"
import "core:strings"

import "../plugin"
import "../setting"

// Prefix of a plugin command's keybinds.lua action.
PLUGIN_ACTION_PREFIX :: "plugin."

Plugin_Command :: struct {
    thor:   ^Thor,
    name:   string, // owned; the thor.on_command name
    title:  string, // owned; the palette title
    action: string, // owned; PLUGIN_ACTION_PREFIX + name
}

// Mirrors the registered plugin commands into the palette and the app binds
// when their count moved since the last sync. A name a built-in action already
// has is left out, so "tutorial" stays "Help: Tutorial" alone.
thor_sync_plugin_commands :: proc(thor: ^Thor) {
    count := plugin.manager_command_count(&thor.plugins)
    if count == thor.plugin_commands_synced {
        return
    }
    // The palette indexes its commands while open.
    if thor.palette_open {
        return
    }
    thor_clear_plugin_commands(thor)
    for info in plugin.manager_commands(&thor.plugins) {
        if thor_is_builtin_action(thor, info.name) {
            continue
        }
        pc := new(Plugin_Command)
        pc.thor = thor
        pc.name = strings.clone(info.name)
        pc.title = info.plugin_id != "" && info.plugin_id != info.name ? fmt.aprintf("Plugin: %s (%s)", info.name, info.plugin_id) : fmt.aprintf("Plugin: %s", info.name)
        pc.action = strings.concatenate({PLUGIN_ACTION_PREFIX, info.name})
        append(&thor.plugin_commands, pc)

        thor_palette_add(thor, pc.title, thor_run_plugin_command, pc, action = pc.action)
        kb, _ := setting.keybind(&thor.config, pc.action)
        append(&thor.app_binds, App_Bind {action = pc.action, key = kb, run = thor_run_plugin_command, data = pc})
    }
    thor.plugin_commands_synced = count
}

// Whether a built-in palette command has `action`.
@(private = "file")
thor_is_builtin_action :: proc(thor: ^Thor, action: string) -> bool {
    for command in thor.palette.commands {
        if command.action == action && command.run != thor_run_plugin_command {
            return true
        }
    }
    return false
}

// Removes the plugin commands from the palette and the app binds and frees them.
// The next sync builds them again.
thor_clear_plugin_commands :: proc(thor: ^Thor) {
    for i := len(thor.palette.commands) - 1; i >= 0; i -= 1 {
        if thor.palette.commands[i].run == thor_run_plugin_command {
            delete(thor.palette.commands[i].shortcut)
            ordered_remove(&thor.palette.commands, i)
        }
    }
    for i := len(thor.app_binds) - 1; i >= 0; i -= 1 {
        if thor.app_binds[i].run == thor_run_plugin_command {
            ordered_remove(&thor.app_binds, i)
        }
    }
    for pc in thor.plugin_commands {
        delete(pc.name)
        delete(pc.title)
        delete(pc.action)
        free(pc)
    }
    clear(&thor.plugin_commands)
    thor.plugin_commands_synced = -1
}

thor_run_plugin_command :: proc(data: rawptr) {
    pc := cast(^Plugin_Command) data
    if !plugin.manager_run_command(&pc.thor.plugins, pc.name) {
        thor_flash_status(pc.thor, strings.concatenate({"Plugin command ", pc.name, " failed"}, context.temp_allocator), is_error = true)
    }
}

// The keybinds.lua actions of the plugin commands, for the Settings list.
thor_plugin_command_actions :: proc(thor: ^Thor, allocator := context.temp_allocator) -> []string {
    out := make([dynamic]string, 0, len(thor.plugin_commands), allocator)
    for pc in thor.plugin_commands {
        append(&out, pc.action)
    }
    return out[:]
}
