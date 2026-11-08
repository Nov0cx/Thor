package thor

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

import "../luaconf"

// Writing lsp.lua. The package that parses that file (lang/lsp) never writes
// it, so the writer lives with the rest of the GUI's config writes.

// Asks for an id, then writes a skeleton entry and opens the file. The whole
// entry is not asked for a field at a time: a form for `command`, `args` and
// `env` would be a worse editor than the one Thor already is.
thor_lsp_prompt_new_server :: proc(thor: ^Thor) {
    thor_palette_prompt(
        thor,
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

// Appends `{ id = id, ... }` to the file's `servers` list, keeping the rest of
// the file as written. An id the file already names is left alone and reports
// true — the caller opens the file either way. A file that does not evaluate,
// or builds its list in code, reports false rather than being overwritten.
thor_lsp_append_server :: proc(path, id: string) -> bool {
    root, status, message := luaconf.eval_file(path)
    if status == .Failed {
        log.warnf("Cannot add a server: %s", message)
        return false
    }
    if servers, ok := luaconf.as_array(luaconf.lookup(root, {"servers"})); ok {
        for item in servers {
            entry, is_obj := item.(json.Object)
            if !is_obj {
                continue
            }
            if existing, has_id := entry["id"].(json.String); has_id && string(existing) == id {
                return true
            }
        }
    }

    markers := make(json.Array, 0, 1, context.temp_allocator)
    append(&markers, json.String(".git"))
    entry := make(json.Object, 5, context.temp_allocator)
    entry["id"] = json.String(id)
    entry["extensions"] = make(json.Array, context.temp_allocator)
    entry["command"] = make(json.Array, context.temp_allocator)
    entry["root_markers"] = markers
    entry["enabled"] = json.Boolean(true)
    if err := luaconf.append_entry(path, {"servers"}, entry); err != .None {
        log.warnf("Cannot add a server to %q: %v", path, err)
        return false
    }
    return true
}
