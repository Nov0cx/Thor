package lsp

import "core:strings"
import "core:unicode/utf8"

// True when `path` matches an LSP glob: `*` and `?` stay inside one segment, `**` spans
// segments, `{a,b}` is a choice and `[a-z]` / `[!a]` a class. Both sides use `/`; case
// folds on Windows.
@(private)
glob_match :: proc(pattern, path: string) -> bool {
    return glob_at(pattern, 0, path, 0, 0)
}

@(private = "file")
GLOB_DEPTH :: 64

@(private = "file")
glob_at :: proc(pattern: string, p: int, path: string, s: int, depth: int) -> bool {
    if depth > GLOB_DEPTH {
        return false
    }
    p, s := p, s
    for p < len(pattern) {
        char := pattern[p]
        switch char {
        case '*':
            if p + 1 < len(pattern) && pattern[p + 1] == '*' {
                rest := p + 2
                // "**/" also matches no segment at all.
                if rest < len(pattern) && pattern[rest] == '/' {
                    if glob_at(pattern, rest + 1, path, s, depth + 1) {
                        return true
                    }
                }
                for at := s; at <= len(path); at += 1 {
                    if glob_at(pattern, rest, path, at, depth + 1) {
                        return true
                    }
                }
                return false
            }
            for at := s; at <= len(path); at += 1 {
                if glob_at(pattern, p + 1, path, at, depth + 1) {
                    return true
                }
                if at < len(path) && path[at] == '/' {
                    break
                }
            }
            return false
        case '?':
            if s >= len(path) || path[s] == '/' {
                return false
            }
            _, size := utf8.decode_rune_in_string(path[s:])
            p += 1
            s += size
        case '{':
            close := glob_brace_end(pattern, p)
            if close < 0 {
                if s >= len(path) || path[s] != '{' {
                    return false
                }
                p += 1
                s += 1
                continue
            }
            rest  := pattern[close + 1:]
            start := p + 1
            for at := start; at <= close; at += 1 {
                if at < close && pattern[at] != ',' {
                    continue
                }
                choice := strings.concatenate({pattern[start:at], rest}, context.temp_allocator)
                if glob_at(choice, 0, path, s, depth + 1) {
                    return true
                }
                start = at + 1
            }
            return false
        case '[':
            close := strings.index_byte(pattern[p + 1:], ']')
            if close < 0 {
                if s >= len(path) || path[s] != '[' {
                    return false
                }
                p += 1
                s += 1
                continue
            }
            if s >= len(path) || path[s] == '/' {
                return false
            }
            class   := pattern[p + 1:p + 1 + close]
            r, size := utf8.decode_rune_in_string(path[s:])
            if !glob_class(class, r) {
                return false
            }
            p += close + 2
            s += size
        case:
            if s >= len(path) || !glob_same(char, path[s]) {
                return false
            }
            p += 1
            s += 1
        }
    }
    return s == len(path)
}

// The index of the `}` that closes the `{` at `open`, or -1.
@(private = "file")
glob_brace_end :: proc(pattern: string, open: int) -> int {
    level := 0
    for at := open; at < len(pattern); at += 1 {
        switch pattern[at] {
        case '{':
            level += 1
        case '}':
            level -= 1
            if level == 0 {
                return at
            }
        }
    }
    return -1
}

@(private = "file")
glob_class :: proc(class: string, r: rune) -> bool {
    class  := class
    negate := false
    if len(class) > 0 && (class[0] == '!' || class[0] == '^') {
        negate = true
        class = class[1:]
    }
    runes := utf8.string_to_runes(class, context.temp_allocator)
    found := false
    for i := 0; i < len(runes); i += 1 {
        if i + 2 < len(runes) && runes[i + 1] == '-' {
            if glob_rune_fold(r) >= glob_rune_fold(runes[i]) && glob_rune_fold(r) <= glob_rune_fold(runes[i + 2]) {
                found = true
            }
            i += 2
        } else if glob_rune_fold(runes[i]) == glob_rune_fold(r) {
            found = true
        }
    }
    return found != negate
}

@(private = "file")
glob_same :: proc(a, b: u8) -> bool {
    when ODIN_OS == .Windows {
        return glob_byte_fold(a) == glob_byte_fold(b)
    } else {
        return a == b
    }
}

@(private = "file")
glob_byte_fold :: proc(c: u8) -> u8 {
    return c >= 'A' && c <= 'Z' ? c + 32 : c
}

@(private = "file")
glob_rune_fold :: proc(r: rune) -> rune {
    when ODIN_OS == .Windows {
        return r >= 'A' && r <= 'Z' ? r + 32 : r
    } else {
        return r
    }
}

// `path` with every `\` turned into `/`, on the temp allocator.
@(private)
glob_path :: proc(path: string) -> string {
    out, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
    return out
}
