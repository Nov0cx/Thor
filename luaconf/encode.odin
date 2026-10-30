package luaconf

import "core:encoding/json"
import "core:slice"
import "core:strconv"
import "core:strings"

// Lua words that cannot be a bare table key.
@(private)
KEYWORDS := []string {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}

// Writes `value` as a whole config file: `return { ... }`.
encode :: proc(value: json.Value, allocator := context.temp_allocator) -> string {
    b := strings.builder_make(allocator)
    strings.write_string(&b, "return ")
    write_value(&b, value, 0)
    strings.write_byte(&b, '\n')
    return strings.to_string(b)
}

// Writes `value` as one Lua expression, its nested lines indented past `indent`.
encode_value :: proc(value: json.Value, indent: int, allocator := context.temp_allocator) -> string {
    b := strings.builder_make(allocator)
    write_value(&b, value, indent)
    return strings.to_string(b)
}

// A Lua string literal for `s`.
quote :: proc(s: string, allocator := context.temp_allocator) -> string {
    b := strings.builder_make(allocator)
    write_quoted(&b, s)
    return strings.to_string(b)
}

// A table key: bare when it is an identifier, else `["key"]`.
key_text :: proc(key: string, allocator := context.temp_allocator) -> string {
    if is_identifier(key) {
        return strings.clone(key, allocator)
    }
    return strings.concatenate({"[", quote(key, context.temp_allocator), "]"}, allocator)
}

is_identifier :: proc(s: string) -> bool {
    if s == "" {
        return false
    }
    for i in 0 ..< len(s) {
        switch c := s[i]; c {
        case 'a' ..= 'z', 'A' ..= 'Z', '_':
        case '0' ..= '9':
            if i == 0 {
                return false
            }
        case:
            return false
        }
    }
    return !slice.contains(KEYWORDS, s)
}

@(private)
write_quoted :: proc(b: ^strings.Builder, s: string) {
    strings.write_byte(b, '"')
    for i in 0 ..< len(s) {
        switch c := s[i]; c {
        case '"':
            strings.write_string(b, "\\\"")
        case '\\':
            strings.write_string(b, "\\\\")
        case '\n':
            strings.write_string(b, "\\n")
        case '\r':
            strings.write_string(b, "\\r")
        case '\t':
            strings.write_string(b, "\\t")
        case 0 ..< 0x20, 0x7F:
            // Three digits, so a following digit cannot join the escape.
            buf: [4]u8
            strings.write_byte(b, '\\')
            digits := strconv.write_uint(buf[:], u64(c), 10)
            for _ in len(digits) ..< 3 {
                strings.write_byte(b, '0')
            }
            strings.write_string(b, digits)
        case:
            strings.write_byte(b, c)
        }
    }
    strings.write_byte(b, '"')
}

@(private)
write_indent :: proc(b: ^strings.Builder, indent: int) {
    for _ in 0 ..< indent {
        strings.write_string(b, "    ")
    }
}

// True when every entry is a scalar, so the list fits on one line.
@(private)
flat_array :: proc(arr: json.Array) -> bool {
    if len(arr) > 8 {
        return false
    }
    for elem in arr {
        #partial switch _ in elem {
        case json.Array, json.Object:
            return false
        }
    }
    return true
}

@(private)
write_value :: proc(b: ^strings.Builder, value: json.Value, indent: int) {
    switch v in value {
    case json.Null:
        strings.write_string(b, "nil")
    case json.Boolean:
        strings.write_string(b, v ? "true" : "false")
    case json.Integer:
        buf: [32]u8
        strings.write_string(b, strconv.write_int(buf[:], v, 10))
    case json.Float:
        write_float(b, v)
    case json.String:
        write_quoted(b, v)
    case json.Array:
        if len(v) == 0 {
            strings.write_string(b, "{}")
            return
        }
        if flat_array(v) {
            strings.write_string(b, "{ ")
            for elem, i in v {
                if i > 0 {
                    strings.write_string(b, ", ")
                }
                write_value(b, elem, indent)
            }
            strings.write_string(b, " }")
            return
        }
        strings.write_string(b, "{\n")
        for elem in v {
            write_indent(b, indent + 1)
            write_value(b, elem, indent + 1)
            strings.write_string(b, ",\n")
        }
        write_indent(b, indent)
        strings.write_byte(b, '}')
    case json.Object:
        if len(v) == 0 {
            strings.write_string(b, "{}")
            return
        }
        keys := make([dynamic]string, 0, len(v), context.temp_allocator)
        for key, elem in v {
            if _, is_null := elem.(json.Null); is_null {
                continue
            }
            append(&keys, key)
        }
        slice.sort(keys[:])
        strings.write_string(b, "{\n")
        for key in keys {
            write_indent(b, indent + 1)
            strings.write_string(b, key_text(key, context.temp_allocator))
            strings.write_string(b, " = ")
            write_value(b, v[key], indent + 1)
            strings.write_string(b, ",\n")
        }
        write_indent(b, indent)
        strings.write_byte(b, '}')
    case:
        strings.write_string(b, "nil")
    }
}

// A float that reads back as a float: "1.0", not "1".
@(private)
write_float :: proc(b: ^strings.Builder, f: f64) {
    if f != f {
        strings.write_string(b, "(0/0)")
        return
    }
    if f > max(f64) {
        strings.write_string(b, "math.huge")
        return
    }
    if f < -max(f64) {
        strings.write_string(b, "-math.huge")
        return
    }
    buf: [64]u8
    text := strconv.write_float(buf[:], f, 'g', -1, 64)
    text = strings.trim_prefix(text, "+")
    strings.write_string(b, text)
    if !strings.contains_any(text, ".eE") {
        strings.write_string(b, ".0")
    }
}
