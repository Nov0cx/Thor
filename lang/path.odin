package lang

// Whether two paths name the same file. Either separator reads as `/`, and on
// Windows case does not distinguish. The comparison is otherwise literal.
path_equal :: proc(a, b: string) -> bool {
    if len(a) != len(b) {
        return false
    }
    for i in 0 ..< len(a) {
        if path_byte(a[i]) != path_byte(b[i]) {
            return false
        }
    }
    return true
}

// One path byte normalized for comparison: either separator reads as `/`, and on
// Windows an upper-case letter reads as its lower-case.
path_byte :: proc(b: u8) -> u8 {
    if is_path_sep(b) {
        return '/'
    }
    when ODIN_OS == .Windows {
        if b >= 'A' && b <= 'Z' {
            return b + 32
        }
    }
    return b
}

is_path_sep :: proc(b: u8) -> bool {
    return b == '/' || b == '\\'
}
