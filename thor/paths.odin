// Path vocabulary for the editor: the one spelling-tolerant comparison every
// path check in `thor` goes through, plus the two name accessors. Pure string
// work, so it is testable without a window.
package thor

import "core:os"
import "core:path/filepath"
import "core:strings"

// `path` made absolute, on scratch. filepath.abs opens the file on POSIX, so it
// fails for one not created yet; a lexical join with the working directory then
// answers for a file the editor has not written. The input is returned when
// neither resolves.
thor_abs_path :: proc(path: string) -> string {
    if path == "" || filepath.is_abs(path) {
        return path
    }
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        return abs
    }
    wd, wd_err := os.get_working_directory(context.temp_allocator)
    if wd_err != nil {
        return path
    }
    joined, join_err := filepath.join({wd, path}, context.temp_allocator)
    return join_err == nil ? joined : path
}

// A comparison key for `path`: absolute, `\` folded to `/`, `.`/`..` resolved.
// filepath.clean only treats `\` as a separator on Windows, but a compiler or a
// language server can carry Windows-style paths on any host, so `\` is folded
// first. Falls back to the input when the scratch allocation fails — a compare
// against the raw spelling beats none. For comparing only; never store it.
@(private)
thor_canon_path :: proc(path: string) -> string {
    slashed, _ := strings.replace_all(thor_abs_path(path), "\\", "/", context.temp_allocator)
    cleaned, err := filepath.clean(slashed, context.temp_allocator)
    return err == nil ? cleaned : path
}

// Equality for two path spellings that are already canonical. Windows folds
// case, POSIX does not: there `/src/Main.odin` and `/src/main.odin` are two
// files. Matches plugin.is_within and lang/lsp's path_equal.
@(private)
thor_path_equal :: proc(a, b: string) -> bool {
    when ODIN_OS == .Windows {
        return strings.equal_fold(a, b)
    } else {
        return a == b
    }
}

// True when two paths name the same file, however each is spelled. The exact
// compare comes first: at runtime both sides are already canonical, so the
// canonicalization is only reached for a relative or oddly spelled input.
thor_same_path :: proc(a, b: string) -> bool {
    return thor_path_equal(a, b) || thor_path_equal(thor_canon_path(a), thor_canon_path(b))
}

// True when `path` is `ancestor` itself or sits somewhere beneath it.
thor_path_within :: proc(path, ancestor: string) -> bool {
    a, b := thor_canon_path(path), thor_canon_path(ancestor)
    if len(a) < len(b) || !thor_path_equal(a[:len(b)], b) {
        return false
    }
    return len(a) == len(b) || a[len(b)] == '/' || a[len(b)] == '\\'
}

// The parent of an absolute path, as a slice of it. A path already at its root
// answers itself, which is what stops a walk up the tree. Handles both
// separators and keeps the root's own one ("C:\" and "/", never "C:" or "").
thor_parent_dir :: proc(path: string) -> string {
    slash := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
    if slash < 0 {
        return path
    }
    if slash == 0 {
        return path[:1]
    }
    parent := path[:slash]
    if len(parent) == 2 && parent[1] == ':' {
        return path[:slash + 1]
    }
    return parent
}

// File extension including the dot (".odin"), or "" when the name has none.
thor_file_extension :: proc(name: string) -> string {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return ""
    }
    return name[dot:]
}

// The final path component ("Dockerfile" from "app/Dockerfile"), handling both
// path separators.
thor_file_base :: proc(path: string) -> string {
    slash := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
    return path[slash + 1:]
}
