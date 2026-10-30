package luaconf

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"

// Writes the JSON file at `json_path` as the Lua config `lua_path`, checks the
// Lua reads back equal, then renames the JSON to `<json_path>.bak`. Never writes
// over an existing `lua_path`.
convert_json :: proc(json_path, lua_path: string) -> bool {
    if os.exists(lua_path) {
        log.warnf("Not converting %q: %q already exists", json_path, lua_path)
        return false
    }
    data, err := os.read_entire_file_from_path(json_path, context.temp_allocator)
    if err != nil {
        log.warnf("Cannot read %q: %v", json_path, err)
        return false
    }
    value, perr := json.parse(data, allocator = context.temp_allocator)
    if perr != .None {
        log.warnf("Cannot convert %q: it is not valid JSON (%v)", json_path, perr)
        return false
    }
    if _, is_obj := value.(json.Object); !is_obj {
        log.warnf("Cannot convert %q: its root is not an object", json_path)
        return false
    }
    return write_converted(json_path, lua_path, encode(value, context.temp_allocator), value)
}

// Writes `text` (the Lua form of `json_path`) to `lua_path`, checks it reads
// back as `expect` when one is given, and moves the JSON aside.
write_converted :: proc(json_path, lua_path, text: string, expect: json.Value = nil) -> bool {
    if os.exists(lua_path) {
        log.warnf("Not converting %q: %q already exists", json_path, lua_path)
        return false
    }
    back, status, message := eval_text(text, lua_path, context.temp_allocator)
    if status != .Ok {
        log.errorf("Converting %q made Lua that does not evaluate: %s", json_path, message)
        return false
    }
    if expect != nil && !values_equal(expect, back) {
        log.errorf("Converting %q changed its values; the JSON is kept", json_path)
        return false
    }
    if !write_file(lua_path, text) {
        return false
    }
    bak := strings.concatenate({json_path, ".bak"}, context.temp_allocator)
    if os.exists(bak) {
        _ = os.remove(bak)
    }
    if rerr := os.rename(json_path, bak); rerr != nil {
        log.warnf("Converted %q, but cannot move it aside: %v", json_path, rerr)
    }
    log.infof("Converted %q to %q", json_path, lua_path)
    return true
}
