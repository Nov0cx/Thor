package setting

// Loads Thor's config from settings/ (comments.json, keybinds.json,
// settings.json). Missing or malformed files degrade to empty lookups.

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// A parsed key chord, e.g. "ctrl+shift+k" -> {key = .K, ctrl, shift}.
Keybind :: struct {
    key:   rl.KeyboardKey,
    ctrl:  bool,
    shift: bool,
    alt:   bool,
}

// General editor preferences with sensible defaults, overridable via
// settings.json.
General :: struct {
    tab_width:         int,
    font_size:         int,
    autosave_delay_ms: int,
}

Settings :: struct {
    // File extension (".odin") -> line-comment marker ("//").
    comments: map[string]string,
    // Action name ("toggle_line_comment") -> bound chord.
    keybinds: map[string]Keybind,
    general:  General,
}

// Reads comments.json and keybinds.json from dir. Always returns an
// initialized Settings; parse failures just leave the maps sparse.
load :: proc(dir: string) -> Settings {
    s: Settings
    s.comments = make(map[string]string)
    s.keybinds = make(map[string]Keybind)
    s.general = General {tab_width = 4, font_size = 18, autosave_delay_ms = 1500}

    load_comments(&s, strings.concatenate({dir, "/comments.json"}, context.temp_allocator))
    load_keybinds(&s, strings.concatenate({dir, "/keybinds.json"}, context.temp_allocator))
    load_general(&s, strings.concatenate({dir, "/settings.json"}, context.temp_allocator))
    return s
}

destroy :: proc(s: ^Settings) {
    for key, value in s.comments {
        delete(key)
        delete(value)
    }
    delete(s.comments)

    for key in s.keybinds {
        delete(key)
    }
    delete(s.keybinds)
}

// Line-comment marker for a file, or "" when the language is unknown (which
// disables Ctrl+K commenting for that file).
comment_prefix :: proc(s: ^Settings, filename: string) -> string {
    dot := strings.last_index_byte(filename, '.')
    if dot < 0 {
        return ""
    }
    return s.comments[filename[dot:]]
}

keybind :: proc(s: ^Settings, action: string) -> (Keybind, bool) {
    kb, ok := s.keybinds[action]
    return kb, ok
}

tab_width :: proc(s: ^Settings) -> int {
    return s.general.tab_width
}

font_size :: proc(s: ^Settings) -> int {
    return s.general.font_size
}

autosave_delay_ms :: proc(s: ^Settings) -> int {
    return s.general.autosave_delay_ms
}

// True when an incoming key event exactly matches the chord (modifiers must
// match precisely so ctrl+k and ctrl+shift+k stay distinct).
keybind_matches :: proc(kb: Keybind, key: rl.KeyboardKey, ctrl, shift, alt: bool) -> bool {
    return kb.key == key && kb.ctrl == ctrl && kb.shift == shift && kb.alt == alt
}

// Formats a chord for display, e.g. {key = .K, ctrl, shift} -> "Ctrl+Shift+K".
// Returns "" for an unset key so callers can treat it as "no binding".
keybind_to_string :: proc(kb: Keybind, allocator := context.temp_allocator) -> string {
    if kb.key == .KEY_NULL {
        return ""
    }
    b := strings.builder_make(allocator)
    if kb.ctrl {
        strings.write_string(&b, "Ctrl+")
    }
    if kb.shift {
        strings.write_string(&b, "Shift+")
    }
    if kb.alt {
        strings.write_string(&b, "Alt+")
    }
    write_key_name(&b, kb.key)
    return strings.to_string(b)
}

@(private)
write_key_name :: proc(b: ^strings.Builder, key: rl.KeyboardKey) {
    #partial switch key {
    case .PAGE_UP:      strings.write_string(b, "PgUp");  return
    case .PAGE_DOWN:    strings.write_string(b, "PgDn");  return
    case .UP:           strings.write_string(b, "Up");    return
    case .DOWN:         strings.write_string(b, "Down");  return
    case .LEFT:         strings.write_string(b, "Left");  return
    case .RIGHT:        strings.write_string(b, "Right"); return
    case .HOME:         strings.write_string(b, "Home");  return
    case .END:          strings.write_string(b, "End");   return
    case .ENTER, .KP_ENTER: strings.write_string(b, "Enter"); return
    case .ESCAPE:       strings.write_string(b, "Esc");   return
    case .TAB:          strings.write_string(b, "Tab");   return
    case .SPACE:        strings.write_string(b, "Space"); return
    case .BACKSPACE:    strings.write_string(b, "Backspace"); return
    case .DELETE:       strings.write_string(b, "Del");   return
    case .BACKSLASH:    strings.write_string(b, "\\");    return
    case .PERIOD:       strings.write_string(b, ".");     return
    case .COMMA:        strings.write_string(b, ",");     return
    case .KP_ADD:       strings.write_string(b, "+");     return
    case .KP_SUBTRACT:  strings.write_string(b, "-");     return
    case .F1:  strings.write_string(b, "F1");  return
    case .F2:  strings.write_string(b, "F2");  return
    case .F3:  strings.write_string(b, "F3");  return
    case .F4:  strings.write_string(b, "F4");  return
    case .F5:  strings.write_string(b, "F5");  return
    case .F6:  strings.write_string(b, "F6");  return
    case .F7:  strings.write_string(b, "F7");  return
    case .F8:  strings.write_string(b, "F8");  return
    case .F9:  strings.write_string(b, "F9");  return
    case .F10: strings.write_string(b, "F10"); return
    case .F11: strings.write_string(b, "F11"); return
    case .F12: strings.write_string(b, "F12"); return
    }
    ki := int(key)
    if ki >= int(rl.KeyboardKey.A) && ki <= int(rl.KeyboardKey.Z) {
        strings.write_byte(b, u8('A' + (ki - int(rl.KeyboardKey.A))))
        return
    }
    if ki >= int(rl.KeyboardKey.ZERO) && ki <= int(rl.KeyboardKey.NINE) {
        strings.write_byte(b, u8('0' + (ki - int(rl.KeyboardKey.ZERO))))
        return
    }
    strings.write_string(b, "?")
}

// Parses "ctrl+shift+k" into a Keybind. Modifiers are order-insensitive; the
// single non-modifier token names the key (see key_from_name).
parse_keybind :: proc(spec: string) -> (Keybind, bool) {
    kb: Keybind
    key_set := false

    parts := strings.split(spec, "+", context.temp_allocator)
    for part in parts {
        token := strings.to_lower(strings.trim_space(part), context.temp_allocator)
        switch token {
        case "ctrl", "control":
            kb.ctrl = true
        case "shift":
            kb.shift = true
        case "alt":
            kb.alt = true
        case:
            key, ok := key_from_name(token)
            if !ok {
                return kb, false
            }
            kb.key = key
            key_set = true
        }
    }
    return kb, key_set
}

@(private)
key_from_name :: proc(name: string) -> (rl.KeyboardKey, bool) {
    if len(name) == 1 {
        c := name[0]
        switch {
        case c >= 'a' && c <= 'z':
            return rl.KeyboardKey(int(rl.KeyboardKey.A) + int(c - 'a')), true
        case c >= 'A' && c <= 'Z':
            return rl.KeyboardKey(int(rl.KeyboardKey.A) + int(c - 'A')), true
        case c >= '0' && c <= '9':
            return rl.KeyboardKey(int(rl.KeyboardKey.ZERO) + int(c - '0')), true
        }
    }

    switch name {
    case "page_up":   return .PAGE_UP, true
    case "page_down": return .PAGE_DOWN, true
    case "up":        return .UP, true
    case "down":      return .DOWN, true
    case "left":      return .LEFT, true
    case "right":     return .RIGHT, true
    case "home":      return .HOME, true
    case "end":       return .END, true
    case "enter":     return .ENTER, true
    case "escape":    return .ESCAPE, true
    case "tab":       return .TAB, true
    case "space":     return .SPACE, true
    case "backspace": return .BACKSPACE, true
    case "delete":    return .DELETE, true
    // Physical key right of the home row: \ on US, # on QWERTZ.
    case "backslash": return .BACKSLASH, true
    case ".", "period": return .PERIOD, true
    case ",", "comma":  return .COMMA, true
    case "kp_add":      return .KP_ADD, true
    case "kp_subtract": return .KP_SUBTRACT, true
    case "f1":  return .F1, true
    case "f2":  return .F2, true
    case "f3":  return .F3, true
    case "f4":  return .F4, true
    case "f5":  return .F5, true
    case "f6":  return .F6, true
    case "f7":  return .F7, true
    case "f8":  return .F8, true
    case "f9":  return .F9, true
    case "f10": return .F10, true
    case "f11": return .F11, true
    case "f12": return .F12, true
    }
    return .KEY_NULL, false
}

@(private)
parse_object :: proc(path: string) -> (json.Object, bool) {
    data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
    if read_err != nil {
        log.warnf("Cannot read settings %q: %v", path, read_err)
        return nil, false
    }

    root, parse_err := json.parse(data, allocator = context.temp_allocator)
    if parse_err != .None {
        log.warnf("Cannot parse settings %q: %v", path, parse_err)
        return nil, false
    }

    obj, ok := root.(json.Object)
    if !ok {
        log.warnf("Settings %q: root is not an object", path)
        return nil, false
    }
    return obj, true
}

@(private)
load_comments :: proc(s: ^Settings, path: string) {
    root, ok := parse_object(path)
    if !ok {
        return
    }

    for language, value in root {
        entry, entry_ok := value.(json.Object)
        if !entry_ok {
            continue
        }
        line, line_ok := entry["line"].(json.String)
        if !line_ok {
            continue
        }
        extensions, ext_ok := entry["extensions"].(json.Array)
        if !ext_ok {
            log.warnf("Settings %q: language %q has no \"extensions\" array", path, language)
            continue
        }
        for ext_value in extensions {
            ext, ext_str_ok := ext_value.(json.String)
            if !ext_str_ok {
                continue
            }
            s.comments[strings.clone(string(ext))] = strings.clone(string(line))
        }
    }
}

@(private)
load_general :: proc(s: ^Settings, path: string) {
    root, ok := parse_object(path)
    if !ok {
        return
    }
    read_int(root, "tab_width", &s.general.tab_width)
    read_int(root, "font_size", &s.general.font_size)
    read_int(root, "autosave_delay_ms", &s.general.autosave_delay_ms)
}

// Reads an integer field into dst, leaving the default in place if absent.
@(private)
read_int :: proc(obj: json.Object, key: string, dst: ^int) {
    #partial switch v in obj[key] {
    case json.Integer:
        dst^ = cast(int) v
    case json.Float:
        dst^ = cast(int) v
    }
}

@(private)
load_keybinds :: proc(s: ^Settings, path: string) {
    root, ok := parse_object(path)
    if !ok {
        return
    }

    // keybinds.json groups bindings (e.g. "editor", "global"); action names
    // share one flat namespace regardless of group.
    for group_name, group_value in root {
        group, group_ok := group_value.(json.Object)
        if !group_ok {
            continue
        }
        for action, spec_value in group {
            spec, spec_ok := spec_value.(json.String)
            if !spec_ok {
                continue
            }
            kb, parsed := parse_keybind(string(spec))
            if !parsed {
                log.warnf("Settings %q: %s.%s has invalid binding %q", path, group_name, action, spec)
                continue
            }
            s.keybinds[strings.clone(action)] = kb
        }
    }
}
