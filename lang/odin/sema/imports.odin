package odinsema

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode"

import odinsyntax "../syntax"

// The collections the Odin root supplies, as `<odin root>/<name>`.
ROOT_COLLECTIONS :: [?]string{"base", "core", "vendor", "shared"}

// A named import root, as `-collection:name=root` gives it.
Collection :: struct {
    name: string,
    root: string,
}

// The roots an import path can name. The caller fills it; the strings are borrowed.
Collections :: struct {
    odin_root: string,       // "" when not known
    custom:    []Collection, // a root collection name here does not replace the root one
}

// Why an import has no package directory, or has one that is not there.
Import_Problem :: enum u8 {
    None,
    Empty_Path,
    Unknown_Collection,
    No_Odin_Root, // a root collection with no Odin root given
    Missing_Dir,  // the path resolves, but the directory does not exist
}

// One import of a file. `alias`, `path` and `collection` are borrowed from the item tree.
File_Import :: struct {
    alias:       string, // the explicit alias or the last path element; "_" binds nothing
    alias_valid: bool,   // false when the default alias is not an identifier
    explicit:    bool,   // the alias is written in the source
    path:        string, // unquoted
    collection:  string, // "" for a relative import
    dir:         string, // owned; the cleaned package directory; "" when not resolved
    exists:      bool,
    problem:     Import_Problem,
    is_foreign:  bool, // a foreign import names a library, not a package, and is not resolved
    item:        int,  // the index in the item tree
    name_offset: int,  // the alias, or the path when there is no alias
    path_offset: int,  // the opening quote of the path; -1 when not known
}

// The imports of a file in source order. Relative paths resolve against `file_dir`.
// Free the result with file_imports_destroy; the item tree must outlive it.
file_imports :: proc(tree: ^Item_Tree, file_dir: string, collections: ^Collections, allocator := context.allocator) -> (imports: []File_Import, err: mem.Allocator_Error) {
    if tree == nil {
        return nil, nil
    }
    out := make([dynamic]File_Import, allocator) or_return
    defer if err != nil {
        for imp in out {
            delete(imp.dir, allocator)
        }
        delete(out)
    }
    for &item, index in tree.items {
        if item.kind != .Import && item.kind != .Foreign_Import {
            continue
        }
        imp := File_Import {
            alias       = item.name,
            alias_valid = is_identifier(item.name),
            path        = item.path,
            item        = index,
            name_offset = item.name_offset,
            path_offset = -1,
        }
        if item.kind == .Foreign_Import {
            imp.is_foreign = true
            imp.explicit = true
            append(&out, imp) or_return
            continue
        }
        imp.explicit, imp.path_offset = import_offsets(&item)
        imp.alias_valid = imp.explicit || imp.alias_valid
        imp.dir, imp.collection, imp.problem = import_dir(item.path, file_dir, collections, allocator) or_return
        if imp.problem == .None {
            imp.exists = os.is_dir(imp.dir)
            if !imp.exists {
                imp.problem = .Missing_Dir
            }
        }
        if _, aerr := append(&out, imp); aerr != nil {
            delete(imp.dir, allocator)
            return nil, aerr
        }
    }
    return out[:], nil
}

file_imports_destroy :: proc(imports: []File_Import, allocator := context.allocator) {
    for imp in imports {
        delete(imp.dir, allocator)
    }
    delete(imports, allocator)
}

// The package import a name refers to in its file. Foreign imports and `_` do not match.
lookup_import :: proc(imports: []File_Import, alias: string) -> (^File_Import, bool) {
    if alias == "" || alias == "_" {
        return nil, false
    }
    for &imp in imports {
        if !imp.is_foreign && imp.alias_valid && imp.alias == alias {
            return &imp, true
        }
    }
    return nil, false
}

// The cleaned directory an import path names, with `/` or `\` as separator.
// `dir` is "" when `problem` is not .None.
import_dir :: proc(path, file_dir: string, collections: ^Collections, allocator := context.allocator) -> (dir, collection: string, problem: Import_Problem, err: mem.Allocator_Error) {
    if path == "" {
        return "", "", .Empty_Path, nil
    }
    base := file_dir
    rest := path
    if colon := strings.index_byte(path, ':'); colon >= 0 {
        collection = path[:colon]
        rest = path[colon + 1:]
        root, found, from_odin := collection_root(collections, collection)
        if !found {
            return "", collection, .Unknown_Collection, nil
        }
        if from_odin && root == "" {
            return "", collection, .No_Odin_Root, nil
        }
        base = root
        if from_odin {
            base = strings.concatenate({root, "/", collection}, context.temp_allocator) or_return
        }
        if rest == "" {
            return "", collection, .Empty_Path, nil
        }
    }
    joined := strings.concatenate({base, "/", rest}, context.temp_allocator) or_return
    slashed, _ := strings.replace_all(joined, "\\", "/", context.temp_allocator)
    dir = filepath.clean(slashed, allocator) or_return
    return dir, collection, .None, nil
}

// The root of a collection; `from_odin` when it is one of ROOT_COLLECTIONS under the Odin root.
collection_root :: proc(collections: ^Collections, name: string) -> (root: string, found, from_odin: bool) {
    for c in ROOT_COLLECTIONS {
        if c == name {
            if collections == nil {
                return "", true, true
            }
            return collections.odin_root, true, true
        }
    }
    if collections == nil {
        return "", false, false
    }
    for c in collections.custom {
        if c.name == name {
            return c.root, true, false
        }
    }
    return "", false, false
}

// The `.odin` files of a package directory as full paths, sorted, not recursive.
// Free the result with package_dir_files_destroy.
package_dir_files :: proc(dir: string, allocator := context.allocator) -> (files: []string, err: os.Error) {
    handle := os.open(dir) or_return
    defer os.close(handle)
    infos := os.read_dir(handle, -1, context.temp_allocator) or_return
    out := make([dynamic]string, allocator) or_return
    defer if err != nil {
        for f in out {
            delete(f, allocator)
        }
        delete(out)
    }
    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        path := strings.clone(info.fullpath, allocator) or_return
        if _, aerr := append(&out, path); aerr != nil {
            delete(path, allocator)
            return nil, aerr
        }
    }
    slice.sort(out[:])
    return out[:], nil
}

package_dir_files_destroy :: proc(files: []string, allocator := context.allocator) {
    for f in files {
        delete(f, allocator)
    }
    delete(files, allocator)
}

// True for a name the compiler takes as an identifier: a letter or `_`, then letters, digits or `_`.
is_identifier :: proc(name: string) -> bool {
    if name == "" || odinsyntax.keyword_kind(name) != .Ident {
        return false
    }
    for r, i in name {
        if r == '_' || unicode.is_letter(r) {
            continue
        }
        if i > 0 && unicode.is_digit(r) {
            continue
        }
        return false
    }
    return true
}

// Whether an import has an alias in the source, and the offset of its path.
// The item tree keeps no path offset, so it is read from the signature: the path is its last token.
@(private = "file")
import_offsets :: proc(item: ^Item) -> (explicit: bool, path_offset: int) {
    path_offset = -1
    sig := strings.trim_space(item.signature)
    after := strings.trim_left_space(strings.trim_prefix(sig, "import"))
    explicit = after != "" && after[0] != '"' && after[0] != '`'
    if !explicit {
        return false, item.name_offset
    }
    if len(sig) < 2 {
        return
    }
    quote := sig[len(sig) - 1]
    if quote != '"' && quote != '`' {
        return
    }
    open := strings.last_index_byte(sig[:len(sig) - 1], quote)
    if open < 0 {
        return
    }
    path_offset = item.end - (len(sig) - open)
    if path_offset < item.start {
        path_offset = -1
    }
    return
}
