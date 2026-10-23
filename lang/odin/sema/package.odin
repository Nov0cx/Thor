package odinsema

import "core:mem"

// One file of a package and its item tree. The scope borrows both.
Package_File :: struct {
    path:  string,
    items: ^Item_Tree,
}

// An item of a package: `file` indexes the files given to package_scope, `item` that file's items.
Item_Ref :: struct {
    file: int,
    item: int,
}

// Declarations of one name that the compiler rejects as a redeclaration.
Conflict :: struct {
    name: string,
    refs: []Item_Ref, // owned
}

// The package-level names of the files in the build. Imports are file scoped and are not in it.
// A declaration under a `when` stays in `names` but never conflicts, as guards are not evaluated.
Package_Scope :: struct {
    name:      string,                      // the package name of the first file in the build
    files:     [dynamic]int,                // owned; the files in the build
    names:     map[string][dynamic]Item_Ref, // owned; keys borrowed from the item trees
    conflicts: [dynamic]Conflict,            // owned
    allocator: mem.Allocator,
}

// The scope of the package that `files` make up for `target`. The item trees must outlive it.
package_scope :: proc(files: []Package_File, target: Target, allocator := context.allocator) -> (scope: Package_Scope, err: mem.Allocator_Error) {
    scope.allocator = allocator
    scope.files = make([dynamic]int, allocator) or_return
    scope.names = make(map[string][dynamic]Item_Ref, allocator)
    scope.conflicts = make([dynamic]Conflict, allocator) or_return
    defer if err != nil {
        package_scope_destroy(&scope)
    }

    for file, fi in files {
        if file.items == nil || !file_in_build(file.path, file.items.tags, target) {
            continue
        }
        append(&scope.files, fi) or_return
        if scope.name == "" {
            scope.name = file.items.package_name
        }
        for item, ii in file.items.items {
            if item.kind == .Import || item.kind == .Foreign_Import || item.name == "_" {
                continue
            }
            refs, found := &scope.names[item.name]
            if !found {
                scope.names[item.name] = make([dynamic]Item_Ref, scope.allocator) or_return
                refs = &scope.names[item.name]
            }
            append(refs, Item_Ref{fi, ii}) or_return
        }
    }

    for name, refs in scope.names {
        if len(refs) < 2 {
            continue
        }
        clash := make([dynamic]Item_Ref, allocator) or_return
        for a, i in refs {
            for b in refs[i + 1:] {
                if !refs_conflict(files, a, b) {
                    continue
                }
                add_unique(&clash, a) or_return
                add_unique(&clash, b) or_return
            }
        }
        if len(clash) == 0 {
            delete(clash)
            continue
        }
        if _, aerr := append(&scope.conflicts, Conflict{name, clash[:]}); aerr != nil {
            delete(clash)
            return scope, aerr
        }
    }
    return scope, nil
}

package_scope_destroy :: proc(scope: ^Package_Scope) {
    for _, refs in scope.names {
        delete(refs)
    }
    delete(scope.names)
    for c in scope.conflicts {
        delete(c.refs, scope.allocator)
    }
    delete(scope.conflicts)
    delete(scope.files)
    scope^ = {}
}

// The items of the package named `name`; empty when none.
package_scope_lookup :: proc(scope: ^Package_Scope, name: string) -> []Item_Ref {
    if refs, ok := scope.names[name]; ok {
        return refs[:]
    }
    return nil
}

// The item a reference names.
package_item :: proc(files: []Package_File, ref: Item_Ref) -> ^Item {
    return &files[ref.file].items.items[ref.item]
}

// True when two declarations of one name are both active and both seen from one file.
@(private = "file")
refs_conflict :: proc(files: []Package_File, a, b: Item_Ref) -> bool {
    ia := package_item(files, a)
    ib := package_item(files, b)
    if ia.guard >= 0 || ib.guard >= 0 {
        return false
    }
    if a.file != b.file && (ia.visibility == .File || ib.visibility == .File) {
        return false
    }
    return true
}

@(private = "file")
add_unique :: proc(list: ^[dynamic]Item_Ref, ref: Item_Ref) -> mem.Allocator_Error {
    for r in list {
        if r == ref {
            return nil
        }
    }
    _, err := append(list, ref)
    return err
}
