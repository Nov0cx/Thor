package luaconf

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"

import "../atomicfile"

// What a new config file holds before the first patch.
EMPTY_FILE :: "return {\n}\n"

Patch_Error :: enum {
    None,
    Unreadable, // the file is there but cannot be read
    Invalid,    // the file, or the patched text, does not evaluate
    Computed,   // the key sits behind code the patcher cannot follow
    Write_Failed,
}

@(private)
Token_Kind :: enum {
    Name,
    String,
    Number,
    Symbol,
    EOF,
}

@(private)
Token :: struct {
    kind:  Token_Kind,
    start: int,
    end:   int,
}

@(private)
token_text :: proc(src: string, t: Token) -> string {
    return src[t.start:t.end]
}

// The bytes after a `[` that open a long bracket ("[[", "[==["), and its level.
@(private)
long_bracket :: proc(src: string, i: int) -> (level: int, ok: bool) {
    if i >= len(src) || src[i] != '[' {
        return 0, false
    }
    j := i + 1
    for j < len(src) && src[j] == '=' {
        j += 1
    }
    if j < len(src) && src[j] == '[' {
        return j - i - 1, true
    }
    return 0, false
}

// The end of the long bracket of `level` that opens at `i`.
@(private)
long_bracket_end :: proc(src: string, i, level: int) -> int {
    j := i + level + 2
    for j < len(src) {
        if src[j] == ']' {
            k := j + 1
            n := 0
            for k < len(src) && src[k] == '=' {
                k += 1
                n += 1
            }
            if n == level && k < len(src) && src[k] == ']' {
                return k + 1
            }
        }
        j += 1
    }
    return len(src)
}

// Splits Lua source into tokens, with comments and whitespace dropped.
@(private)
tokenize :: proc(src: string) -> [dynamic]Token {
    tokens := make([dynamic]Token, context.temp_allocator)
    i := 0
    for i < len(src) {
        c := src[i]
        switch {
        case c == ' ' || c == '\t' || c == '\r' || c == '\n':
            i += 1
        case c == '-' && i + 1 < len(src) && src[i + 1] == '-':
            if level, ok := long_bracket(src, i + 2); ok {
                i = long_bracket_end(src, i + 2, level)
            } else {
                for i < len(src) && src[i] != '\n' {
                    i += 1
                }
            }
        case c == '"' || c == '\'':
            start := i
            i += 1
            for i < len(src) && src[i] != c && src[i] != '\n' {
                if src[i] == '\\' {
                    i += 1
                }
                i += 1
            }
            i = min(i + 1, len(src))
            append(&tokens, Token{.String, start, i})
        case c == '[':
            if level, ok := long_bracket(src, i); ok {
                start := i
                i = long_bracket_end(src, i, level)
                append(&tokens, Token{.String, start, i})
            } else {
                append(&tokens, Token{.Symbol, i, i + 1})
                i += 1
            }
        case is_name_start(c):
            start := i
            for i < len(src) && (is_name_start(src[i]) || (src[i] >= '0' && src[i] <= '9')) {
                i += 1
            }
            append(&tokens, Token{.Name, start, i})
        case c >= '0' && c <= '9' || (c == '.' && i + 1 < len(src) && src[i + 1] >= '0' && src[i + 1] <= '9'):
            start := i
            for i < len(src) {
                d := src[i]
                if (d == '+' || d == '-') && (src[i - 1] == 'e' || src[i - 1] == 'E' || src[i - 1] == 'p' || src[i - 1] == 'P') {
                    i += 1
                    continue
                }
                if !(is_name_start(d) || (d >= '0' && d <= '9') || d == '.') {
                    break
                }
                i += 1
            }
            append(&tokens, Token{.Number, start, i})
        case:
            // Two- and three-byte operators matter only as one token, not by kind.
            n := 1
            if i + 2 < len(src) && src[i:i + 3] == "..." {
                n = 3
            } else if i + 1 < len(src) {
                switch src[i:i + 2] {
                case "==", "~=", "<=", ">=", "//", "::", "<<", ">>", "..":
                    n = 2
                }
            }
            append(&tokens, Token{.Symbol, i, i + n})
            i += n
        }
    }
    append(&tokens, Token{.EOF, len(src), len(src)})
    return tokens
}

@(private)
is_name_start :: proc(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

// How a token moves the nesting depth: brackets and the block words.
@(private)
depth_step :: proc(src: string, t: Token) -> int {
    text := token_text(src, t)
    #partial switch t.kind {
    case .Symbol:
        switch text {
        case "{", "(", "[":
            return 1
        case "}", ")", "]":
            return -1
        }
    case .Name:
        switch text {
        case "function", "if", "do", "repeat":
            return 1
        case "end", "until":
            return -1
        }
    }
    return 0
}

// The index of the token that closes the bracket opened at `open`.
@(private)
matching :: proc(src: string, tokens: []Token, open: int) -> int {
    depth := 0
    for i in open ..< len(tokens) {
        depth += depth_step(src, tokens[i])
        if depth == 0 {
            return i
        }
    }
    return len(tokens) - 1
}

// One field of a table constructor. The value is tokens[value_start..value_end].
@(private)
Field :: struct {
    key:         string, // "" for a list entry or a computed key
    first:       int,    // first token of the field
    value_start: int,
    value_end:   int,    // last token of the value, inclusive
    sep:         int,    // the ',' or ';' after it, -1 when none
}

// The fields of the constructor between tokens[open] ("{") and tokens[close] ("}").
@(private)
fields_of :: proc(src: string, tokens: []Token, open, close: int) -> [dynamic]Field {
    fields := make([dynamic]Field, context.temp_allocator)
    i := open + 1
    for i < close {
        f := Field{first = i, sep = -1}
        t := tokens[i]
        if t.kind == .Name && tokens[i + 1].kind == .Symbol && token_text(src, tokens[i + 1]) == "=" {
            f.key = token_text(src, t)
            i += 2
        } else if t.kind == .Symbol && token_text(src, t) == "[" {
            end := matching(src, tokens, i)
            if end == i + 2 && tokens[i + 1].kind == .String {
                f.key = unquote(token_text(src, tokens[i + 1]))
            }
            i = end + 2 // past "]" and "="
        }
        f.value_start = i
        depth := 0
        for i < close {
            if depth == 0 && tokens[i].kind == .Symbol {
                text := token_text(src, tokens[i])
                if text == "," || text == ";" {
                    break
                }
            }
            depth += depth_step(src, tokens[i])
            i += 1
        }
        f.value_end = i - 1
        if i < close {
            f.sep = i
            i += 1
        }
        if f.value_end >= f.value_start {
            append(&fields, f)
        }
    }
    return fields
}

// The text of a short or long string literal token. Escapes other than the
// simple ones are kept as written, which is enough to match a key.
@(private)
unquote :: proc(lit: string) -> string {
    if len(lit) < 2 {
        return ""
    }
    if lit[0] == '[' {
        level, _ := long_bracket(lit, 0)
        body := lit[level + 2:max(level + 2, len(lit) - level - 2)]
        return strings.trim_prefix(body, "\n")
    }
    body := lit[1:len(lit) - 1]
    if !strings.contains_rune(body, '\\') {
        return body
    }
    b := strings.builder_make(context.temp_allocator)
    for i := 0; i < len(body); i += 1 {
        if body[i] == '\\' && i + 1 < len(body) {
            i += 1
            switch body[i] {
            case 'n':
                strings.write_byte(&b, '\n')
            case 't':
                strings.write_byte(&b, '\t')
            case:
                strings.write_byte(&b, body[i])
            }
            continue
        }
        strings.write_byte(&b, body[i])
    }
    return strings.to_string(b)
}

// The `{` of the table the chunk returns at top level, or -1.
@(private)
root_table :: proc(src: string, tokens: []Token) -> int {
    found := -1
    depth := 0
    for t, i in tokens {
        if depth == 0 && t.kind == .Name && token_text(src, t) == "return" {
            next := tokens[i + 1]
            if next.kind == .Symbol && token_text(src, next) == "{" {
                found = i + 1
            } else {
                found = -1
            }
        }
        depth += depth_step(src, t)
    }
    return found
}

// The start of the line that holds byte `at`, and its leading whitespace.
@(private)
line_indent :: proc(src: string, at: int) -> string {
    start := at
    for start > 0 && src[start - 1] != '\n' {
        start -= 1
    }
    end := start
    for end < len(src) && (src[end] == ' ' || src[end] == '\t') {
        end += 1
    }
    return src[start:end]
}

// Text to insert before tokens[close] that adds `entry` as the last field.
// `fields` are the fields already there.
@(private)
insertion :: proc(src: string, tokens: []Token, fields: []Field, close: int, entry: string) -> (at: int, text: string) {
    closing_indent := line_indent(src, tokens[close].start)
    b := strings.builder_make(context.temp_allocator)
    if len(fields) == 0 {
        // The constructor is empty: "{}" or "{\n}".
        at = tokens[close - 1].end
        strings.write_byte(&b, '\n')
        strings.write_string(&b, closing_indent)
        strings.write_string(&b, "    ")
        strings.write_string(&b, entry)
        strings.write_byte(&b, ',')
        // A brace on the same line as "{" gets a line of its own.
        if !line_starts_at(src, tokens[close].start) {
            strings.write_byte(&b, '\n')
            strings.write_string(&b, closing_indent)
        }
        return at, strings.to_string(b)
    }
    last := fields[len(fields) - 1]
    indent := line_indent(src, tokens[last.first].start)
    if line_indent_is_shared(src, tokens[last.first].start, tokens[close].start) {
        // One-line table: "{ a = 1 }".
        if last.sep < 0 {
            at = tokens[last.value_end].end
            return at, strings.concatenate({", ", entry}, context.temp_allocator)
        }
        at = tokens[last.sep].end
        return at, strings.concatenate({" ", entry, ","}, context.temp_allocator)
    }
    if last.sep < 0 {
        strings.write_byte(&b, ',')
        at = tokens[last.value_end].end
    } else {
        at = tokens[last.sep].end
    }
    strings.write_byte(&b, '\n')
    strings.write_string(&b, indent)
    strings.write_string(&b, entry)
    strings.write_byte(&b, ',')
    return at, strings.to_string(b)
}

// True when only whitespace stands between the line start and `at`.
@(private)
line_starts_at :: proc(src: string, at: int) -> bool {
    i := at
    for i > 0 && (src[i - 1] == ' ' || src[i - 1] == '\t') {
        i -= 1
    }
    return i == 0 || src[i - 1] == '\n'
}

// True when bytes `a` and `b` are on one line.
@(private)
line_indent_is_shared :: proc(src: string, a, b: int) -> bool {
    return !strings.contains_rune(src[a:b], '\n')
}

// The indent depth (in four-space steps) of the line holding byte `at`.
@(private)
indent_level :: proc(src: string, at: int) -> int {
    n := 0
    for c in line_indent(src, at) {
        n += c == '\t' ? 4 : 1
    }
    return n / 4
}

@(private)
Edit_Mode :: enum {
    Set,
    Append,
}

// Sets `root[keys...] = value` in the file, or appends `value` to the list there.
// The rest of the file stays as written.
patch :: proc(path: string, keys: []string, value: json.Value) -> Patch_Error {
    return edit_file(path, keys, value, .Set)
}

// Appends `value` to the list at `root[keys...]`, creating the list when absent.
append_entry :: proc(path: string, keys: []string, value: json.Value) -> Patch_Error {
    return edit_file(path, keys, value, .Append)
}

// Like patch, on text: returns the new source.
patch_text :: proc(src: string, keys: []string, value: json.Value, allocator := context.temp_allocator) -> (string, Patch_Error) {
    return edit_text(src, keys, value, .Set, allocator)
}

// Like append_entry, on text: returns the new source.
append_text :: proc(src: string, keys: []string, value: json.Value, allocator := context.temp_allocator) -> (string, Patch_Error) {
    return edit_text(src, keys, value, .Append, allocator)
}

@(private)
edit_file :: proc(path: string, keys: []string, value: json.Value, mode: Edit_Mode) -> Patch_Error {
    src := EMPTY_FILE
    if os.exists(path) {
        data, err := os.read_entire_file_from_path(path, context.temp_allocator)
        if err != nil {
            log.warnf("Cannot read config %q: %v", path, err)
            return .Unreadable
        }
        src = string(data)
    }
    out, perr := edit_text(src, keys, value, mode, context.temp_allocator)
    if perr != .None {
        log.warnf("Cannot change %q in %q: %v", strings.join(keys, ".", context.temp_allocator), path, perr)
        return perr
    }
    if !make_parent(path) {
        return .Write_Failed
    }
    if werr := atomicfile.write(path, transmute([]byte) out); werr != nil {
        log.errorf("Cannot write config %q: %v", path, werr)
        return .Write_Failed
    }
    return .None
}

// Writes a fresh config file holding `return {}` when none exists.
ensure_file :: proc(path: string) -> bool {
    if os.exists(path) {
        return true
    }
    if !make_parent(path) {
        return false
    }
    if err := atomicfile.write(path, transmute([]byte) string(EMPTY_FILE)); err != nil {
        log.errorf("Cannot write config %q: %v", path, err)
        return false
    }
    return true
}

// Writes `text` as the whole file, creating its directory.
write_file :: proc(path, text: string) -> bool {
    if !make_parent(path) {
        return false
    }
    if err := atomicfile.write(path, transmute([]byte) text); err != nil {
        log.errorf("Cannot write config %q: %v", path, err)
        return false
    }
    return true
}

@(private)
make_parent :: proc(path: string) -> bool {
    cut := strings.last_index_any(path, "/\\")
    if cut <= 0 {
        return true
    }
    dir := path[:cut]
    if os.is_dir(dir) {
        return true
    }
    if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
        log.errorf("Cannot create directory %q: %v", dir, err)
        return false
    }
    return true
}

@(private)
edit_text :: proc(src: string, keys: []string, value: json.Value, mode: Edit_Mode, allocator := context.temp_allocator) -> (string, Patch_Error) {
    assert(len(keys) > 0)
    before, status, _ := eval_text(src, "config", context.temp_allocator)
    if status != .Ok {
        return "", .Invalid
    }

    tokens := tokenize(src)
    open := root_table(src, tokens[:])
    if open < 0 {
        return "", .Computed
    }
    close := matching(src, tokens[:], open)

    // Walk down the keys that already exist as table constructors.
    level := 0
    replace_start, replace_end := -1, -1
    for level < len(keys) {
        fields := fields_of(src, tokens[:], open, close)
        found := -1
        for f, i in fields {
            if f.key == keys[level] {
                found = i
            }
        }
        if found < 0 {
            break
        }
        f := fields[found]
        is_table := token_text(src, tokens[f.value_start]) == "{" && matching(src, tokens[:], f.value_start) == f.value_end
        if level == len(keys) - 1 && mode == .Set {
            replace_start, replace_end = f.value_start, f.value_end
            level += 1
            break
        }
        if !is_table {
            if level == len(keys) - 1 {
                // Append onto a value that is not a literal list.
                return "", .Computed
            }
            // A deeper key under a value that is not a literal table.
            return "", .Computed
        }
        open, close = f.value_start, f.value_end
        level += 1
    }

    b := strings.builder_make(allocator)
    if replace_start >= 0 {
        depth := indent_level(src, tokens[replace_start].start)
        strings.write_string(&b, src[:tokens[replace_start].start])
        strings.write_string(&b, encode_value(value, depth, context.temp_allocator))
        strings.write_string(&b, src[tokens[replace_end].end:])
    } else {
        // Build what is missing from keys[level:] inward, then insert it into
        // the constructor at open/close.
        fields := fields_of(src, tokens[:], open, close)
        depth := indent_level(src, tokens[close].start) + 1
        if len(fields) > 0 {
            depth = indent_level(src, tokens[fields[len(fields) - 1].first].start)
        }
        inner := value
        if mode == .Append && level == len(keys) {
            // The list exists: insert the entry itself.
        } else {
            if mode == .Append {
                arr := make(json.Array, 0, 1, context.temp_allocator)
                append(&arr, value)
                inner = arr
            }
            for i := len(keys) - 1; i > level; i -= 1 {
                obj := make(json.Object, 1, context.temp_allocator)
                obj[keys[i]] = inner
                inner = obj
            }
        }
        entry: string
        if mode == .Append && level == len(keys) {
            entry = encode_value(inner, depth, context.temp_allocator)
        } else {
            entry = strings.concatenate(
                {key_text(keys[level], context.temp_allocator), " = ", encode_value(inner, depth, context.temp_allocator)},
                context.temp_allocator,
            )
        }
        at, text := insertion(src, tokens[:], fields[:], close, entry)
        strings.write_string(&b, src[:at])
        strings.write_string(&b, text)
        strings.write_string(&b, src[at:])
    }
    out := strings.to_string(b)

    // The patched file must still evaluate, and must now say what we wrote: a
    // key that code overrides, or a second return that wins, is not ours to set.
    after, after_status, _ := eval_text(out, "config", context.temp_allocator)
    if after_status != .Ok {
        return "", .Invalid
    }
    want := lookup(after, keys)
    if mode == .Set {
        if !values_equal(want, value) {
            return "", .Computed
        }
    } else {
        arr, is_arr := want.(json.Array)
        prev_len := 0
        if prev, prev_ok := lookup(before, keys).(json.Array); prev_ok {
            prev_len = len(prev)
        }
        if !is_arr || len(arr) != prev_len + 1 || !values_equal(arr[len(arr) - 1], value) {
            return "", .Computed
        }
    }
    return out, .None
}

// The value at root[keys...], nil when a level is missing.
lookup :: proc(root: json.Value, keys: []string) -> json.Value {
    v := root
    for key in keys {
        obj, ok := v.(json.Object)
        if !ok {
            return nil
        }
        v = obj[key] or_else nil
    }
    return v
}

// Deep equality. An integer equals a float of the same value.
values_equal :: proc(a, b: json.Value) -> bool {
    switch x in a {
    case json.Null:
        _, ok := b.(json.Null)
        return ok || b == nil
    case json.Boolean:
        y, ok := b.(json.Boolean)
        return ok && x == y
    case json.Integer:
        #partial switch y in b {
        case json.Integer:
            return x == y
        case json.Float:
            return f64(x) == y
        }
        return false
    case json.Float:
        #partial switch y in b {
        case json.Integer:
            return x == f64(y)
        case json.Float:
            return x == y
        }
        return false
    case json.String:
        y, ok := b.(json.String)
        return ok && x == y
    case json.Array:
        y, ok := b.(json.Array)
        if !ok || len(x) != len(y) {
            // An empty list reads back as an empty object.
            if yo, is_obj := b.(json.Object); is_obj && len(x) == 0 && len(yo) == 0 {
                return true
            }
            return false
        }
        for elem, i in x {
            if !values_equal(elem, y[i]) {
                return false
            }
        }
        return true
    case json.Object:
        y, ok := b.(json.Object)
        if !ok {
            if ya, is_arr := b.(json.Array); is_arr && len(x) == 0 && len(ya) == 0 {
                return true
            }
            return false
        }
        n := 0
        for key, elem in x {
            if _, is_null := elem.(json.Null); is_null {
                continue
            }
            n += 1
            other, has := y[key]
            if !has || !values_equal(elem, other) {
                return false
            }
        }
        return n == len(y)
    }
    return b == nil
}
