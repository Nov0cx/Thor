// Converts the JSON config older versions wrote to Lua, and the one-time card
// that says so.
package thor

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../atomicfile"
import "../luaconf"
import "../setting"
import "../theme"
import ui "../vendor/loom/loom"

// Config files that moved from <name>.json to <name>.lua.
@(private = "file")
LUA_CONFIG_NAMES := [?]string {
    "settings", "keybinds", "comments", "tips", "lsp", "tasks", "odin-analyzer", "odin-formatter",
}

// The only version that shows the card.
LUA_CONFIG_NOTICE_VERSION :: "2026.11.0"
// The record of notices the user closed.
NOTICES_FILE :: "sessions/notices.json"
@(private = "file")
LUA_CONFIG_NOTICE_ID :: "lua-config"

Notices_Record :: struct {
    seen: []string,
}

// Converts the JSON config in `dir` (user/ or a workspace's .thor/): the
// config files, themes/*.json and the plugin.json of each plugins/* folder.
// The paths it wrote are appended to `converted`, owned.
thor_migrate_json_config :: proc(dir: string, converted: ^[dynamic]string) {
    if dir == "" || !os.is_dir(dir) {
        return
    }
    for name in LUA_CONFIG_NAMES {
        json_path := strings.concatenate({dir, "/", name, ".json"}, context.temp_allocator)
        lua_path := strings.concatenate({dir, "/", name, ".lua"}, context.temp_allocator)
        if os.exists(json_path) && luaconf.convert_json(json_path, lua_path) {
            append(converted, strings.clone(lua_path))
        }
    }

    themes := strings.concatenate({dir, "/themes/*.json"}, context.temp_allocator)
    if matches, err := filepath.glob(themes, context.temp_allocator); err == nil {
        for json_path in matches {
            lua_path := strings.concatenate({strings.trim_suffix(json_path, ".json"), THEME_EXT}, context.temp_allocator)
            if os.exists(lua_path) {
                log.warnf("Not converting %q: %q already exists", json_path, lua_path)
                continue
            }
            loaded, ok := theme.load_json(json_path)
            text := theme.encode(loaded)
            theme.destroy(&loaded)
            if !ok {
                log.warnf("Not converting %q: it is not a theme", json_path)
                continue
            }
            if luaconf.write_converted(json_path, lua_path, text) {
                append(converted, strings.clone(lua_path))
            }
        }
    }

    thor_migrate_plugin_manifests(strings.concatenate({dir, "/plugins"}, context.temp_allocator), converted)
}

// Converts plugins/<id>/plugin.json to manifest.lua under `plugins_dir`.
thor_migrate_plugin_manifests :: proc(plugins_dir: string, converted: ^[dynamic]string) {
    pattern := strings.concatenate({plugins_dir, "/*/plugin.json"}, context.temp_allocator)
    matches, err := filepath.glob(pattern, context.temp_allocator)
    if err != nil {
        return
    }
    for json_path in matches {
        lua_path := strings.concatenate({filepath.dir(json_path), "/manifest.lua"}, context.temp_allocator)
        if luaconf.convert_json(json_path, lua_path) {
            append(converted, strings.clone(lua_path))
        }
    }
}

// Converts user/, the bundled plugins and the workspace's .thor/. Runs before
// the config loads.
thor_migrate_startup :: proc(thor: ^Thor, workspace_dir: string) {
    thor_migrate_json_config(setting.USER_DIR, &thor.lua_converted)
    thor_migrate_plugin_manifests("plugins", &thor.lua_converted)
    if workspace_dir != "" {
        thor_migrate_json_config(thor_workspace_config_dir(workspace_dir), &thor.lua_converted)
    }
    thor_lua_notice_check(thor, workspace_dir)
}

// Frees the list of converted paths.
thor_free_lua_converted :: proc(thor: ^Thor) {
    for path in thor.lua_converted {
        delete(path)
    }
    delete(thor.lua_converted)
    thor.lua_converted = nil
}

// Whether user/ or the workspace's .thor/ holds a <name>.json.bak a conversion left.
@(private = "file")
thor_has_converted_backup :: proc(dir: string) -> bool {
    if dir == "" {
        return false
    }
    for name in LUA_CONFIG_NAMES {
        if os.exists(strings.concatenate({dir, "/", name, ".json.bak"}, context.temp_allocator)) {
            return true
        }
    }
    return false
}

// Opens the card when this version is the notice version, something was
// converted (now or by an earlier start of it) and the user has not closed it.
thor_lua_notice_check :: proc(thor: ^Thor, workspace_dir: string) {
    if VERSION != LUA_CONFIG_NOTICE_VERSION {
        return
    }
    if len(thor.lua_converted) == 0 && !thor_has_converted_backup(setting.USER_DIR) &&
       (workspace_dir == "" || !thor_has_converted_backup(thor_workspace_config_dir(workspace_dir))) {
        return
    }
    record := thor_read_notices()
    if slice.contains(record.seen, LUA_CONFIG_NOTICE_ID) {
        return
    }
    thor.lua_notice_open = true
}

@(private = "file")
thor_read_notices :: proc() -> (record: Notices_Record) {
    data, err := os.read_entire_file(NOTICES_FILE, context.temp_allocator)
    if err != nil {
        return
    }
    if uerr := json.unmarshal(data, &record, allocator = context.temp_allocator); uerr != nil {
        log.warnf("Could not read %q: %v", NOTICES_FILE, uerr)
        return {}
    }
    return record
}

// Closes the card and records it, so it does not show again.
thor_lua_notice_dismiss :: proc(thor: ^Thor) {
    thor.lua_notice_open = false
    record := thor_read_notices()
    if slice.contains(record.seen, LUA_CONFIG_NOTICE_ID) {
        return
    }
    seen := make([dynamic]string, context.temp_allocator)
    append(&seen, ..record.seen)
    append(&seen, LUA_CONFIG_NOTICE_ID)
    record.seen = seen[:]
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }
    data, err := json.marshal(record, {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal the notices record: %v", err)
        return
    }
    if werr := atomicfile.write(NOTICES_FILE, data); werr != nil {
        log.errorf("Could not write %q: %v", NOTICES_FILE, werr)
    }
}

LUA_NOTICE_WIDTH :: f32(460)

// The floating card that says the config is Lua now.
thor_lua_notice_view :: proc(thor: ^Thor) {
    if !thor.lua_notice_open {
        return
    }
    ui.scope(
        {
            key = "lua-notice",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {r = 24, b = 24},
                w = ui.Px(LUA_NOTICE_WIDTH),
                max_w = ui.viewport().x - 48,
                h = ui.FIT,
                dir = .Column,
                pad = ui.all(14),
                gap = {0, 8},
                z = 310,
                bg = thor.theme.second_background,
                radius = ui.rad(8),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 6}, blur = 24, color = thor.theme.contrast},
            },
        },
    )
    {
        ui.scope({key = "head", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {8, 0}}})
        thor_icon_label(thor, "file-code", thor.theme.accent_color)
        ui.label("Settings are now Lua", {key = "title", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis}})
    }
    ui.label(
        "Thor reads its settings, key bindings, themes and plugin manifests from .lua files now. Your .json files were converted, and the old files were kept as .json.bak. A Lua config can hold comments and conditions, for example: if thor.os == \"windows\".",
        {key = "body", props = {w = ui.Grow(1), color = thor.theme.muted_color, text_wrap = .Words}},
    )
    for path, i in thor.lua_converted {
        if i == 6 {
            ui.label(
                "and more; see user/thor.log",
                {key = "more", props = {color = thor.theme.disabled, text_wrap = .None}},
            )
            break
        }
        ui.push_id_int(i64(i))
        ui.label(path, {key = "path", props = {w = ui.Grow(1), color = thor.theme.disabled, text_wrap = .Ellipsis}})
        ui.pop_id()
    }
    {
        ui.scope({key = "foot", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {8, 0}, margin = {t = 4}}})
        ui.spacer(ui.Grow(1), {key = "gap"})
        if lua_notice_button(thor, "open", "Open settings.lua", false) {
            thor_lua_notice_dismiss(thor)
            thor_cmd_open_settings(thor)
        }
        if lua_notice_button(thor, "ok", "OK", true) {
            thor_lua_notice_dismiss(thor)
        }
    }
}

@(private = "file")
lua_notice_button :: proc(thor: ^Thor, key, label: string, primary: bool) -> bool {
    bg := primary ? thor.theme.accent_color : thor.theme.buttons
    fg := primary ? theme.color_on(thor.theme.accent_color) : thor.theme.foreground
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {w = ui.FIT, h = ui.Px(28), dir = .Row, align = .Center, pad = ui.xy(12, 0), radius = ui.rad(6), bg = bg, cursor = .Pointer},
            hover = {bg = primary ? bg : thor.theme.active},
        },
    )
    ui.label(label, {key = "label", props = {color = fg, text_wrap = .None}})
    return it.clicked
}
