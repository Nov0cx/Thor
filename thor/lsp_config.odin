package thor

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../lang/lsp"
import "../widgets"

// Writing lsp.json. The package that parses that file (lang/lsp) deliberately
// never writes it — it reads its config with core:encoding/json because
// `setting`, which owns every other write, imports `lang`. `thor` imports both,
// so the writer belongs here.

// Asks for an id, then writes a skeleton entry and opens the file. The whole
// entry is not asked for a field at a time: a form for `command`, `args` and
// `env` would be a worse JSON editor than the one Thor already is.
thor_lsp_prompt_new_server :: proc(thor: ^Thor) {
    widgets.command_palette_prompt(
        thor.command_palette,
        &thor.ui_context,
        "Server id (for example: ruff)",
        thor_lsp_new_server_submit,
        thor,
    )
}

@(private = "file")
thor_lsp_new_server_submit :: proc(data: rawptr, text: string) {
    thor := cast(^Thor) data
    id := strings.trim_space(text)
    if id == "" {
        return
    }
    path := thor_active_lsp_path(thor)
    if !thor_lsp_append_server(path, id) {
        thor_flash_status(thor, fmt.tprintf("Could not write %s", path), is_error = true)
        return
    }
    thor_open_file(thor, path)
    thor_flash_status(thor, "Fill in extensions and command, then save")
}

// Appends `{"id": id, ...}` to the file's "servers" array, keeping every entry
// already in it. An id the file already names is left alone and reports true —
// the caller opens the file either way, which is what the user asked for.
// A file that will not parse reports false rather than being overwritten.
thor_lsp_append_server :: proc(path, id: string) -> bool {
    // json.Object and json.Array are a map and a dynamic array, so every literal
    // here allocates. None of it outlives the write.
    context.allocator = context.temp_allocator

    root := json.Object{}
    servers := json.Array{}

    if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
        if strings.trim_space(string(data)) != "" {
            value, perr := json.parse(data, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
            if perr != .None {
                log.warnf("Cannot add a server to %q: it is not valid JSON (%v)", path, perr)
                return false
            }
            object, ok := value.(json.Object)
            if !ok {
                log.warnf("Cannot add a server to %q: it is not a JSON object", path)
                return false
            }
            root = object
            if list, has_list := root["servers"].(json.Array); has_list {
                servers = list
            } else if _, stated := root["servers"]; stated {
                log.warnf("Cannot add a server to %q: \"servers\" is not an array", path)
                return false
            }
        }
    }

    for item in servers {
        entry, ok := item.(json.Object)
        if !ok {
            continue
        }
        if existing, has_id := entry["id"].(json.String); has_id && string(existing) == id {
            return true
        }
    }

    markers := json.Array{}
    append(&markers, json.String(".git"))

    entry := json.Object{}
    entry["id"] = json.String(id)
    entry["extensions"] = json.Array{}
    entry["command"] = json.Array{}
    entry["root_markers"] = markers
    entry["enabled"] = json.Boolean(true)
    append(&servers, entry)
    root["servers"] = servers

    data, merr := json.marshal(root, {pretty = true, use_spaces = true, spaces = 4}, context.temp_allocator)
    if merr != nil {
        log.errorf("Cannot marshal %q: %v", path, merr)
        return false
    }
    // user/ and .thor/ may not exist until the first write to them.
    dir := filepath.dir(path) // borrowed substring of path
    if dir != "" && !os.is_dir(dir) {
        if err := os.make_directory(dir); err != nil && !os.is_dir(dir) {
            log.errorf("Cannot create %q: %v", dir, err)
            return false
        }
    }
    if err := os.write_entire_file(path, data); err != nil {
        log.errorf("Cannot write %q: %v", path, err)
        return false
    }
    return true
}
