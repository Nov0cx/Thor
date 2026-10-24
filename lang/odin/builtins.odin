// The universe scope: the names a bare identifier reaches with no import. They are read from
// base:builtin and from the declarations of base:runtime with a `builtin` attribute.
package odin

import "core:path/filepath"

import odinsema "sema"

// A package of the Odin root whose names join the universe scope.
@(private = "file")
Builtin_Package :: struct {
    name: string, // the directory under `base` of the Odin root
    all:  bool,   // every public item; else only the items with a `builtin` attribute
}

@(private = "file")
BUILTIN_PACKAGES :: [?]Builtin_Package{{"builtin", true}, {"runtime", false}}

// Appends the universe-scope declarations of `name` from the first builtin package that declares
// it, and gives that package directory. "" when no builtin package declares it. Temp-allocated.
@(private)
builtin_candidates :: proc(ctx: ^Request_Context, name: string, out: ^[dynamic]Def_Candidate) -> (dir: string) {
    root := odin_root(&ctx.e.root)
    if root == "" {
        return ""
    }
    for pkg in BUILTIN_PACKAGES {
        pkg_dir, jerr := filepath.join({root, "base", pkg.name}, context.temp_allocator)
        if jerr != nil {
            return ""
        }
        if builtin_package_candidates(ctx, pkg_dir, name, pkg.all, out) {
            return pkg_dir
        }
    }
    return ""
}

// Appends the public declarations of `name` in the package at `dir`, with `all` false only the ones
// with a `builtin` attribute. True when one was appended.
@(private = "file")
builtin_package_candidates :: proc(ctx: ^Request_Context, dir, name: string, all: bool, out: ^[dynamic]Def_Candidate) -> bool {
    view := request_package(ctx, dir)
    if view == nil {
        return false
    }
    start := len(out)
    for ref in odinsema.package_scope_lookup(view.scope, name) {
        item := odinsema.package_item(view.sema_files, ref)
        if item.visibility != .Public || (!all && !has_builtin_attribute(item)) {
            continue
        }
        data := view.datas[ref.file]
        inactive := !odinsema.package_ref_active(view.scope, ref)
        emit_candidate(ctx, out, item, view.sema_files[ref.file].path, data.tree, data.lines, inactive, "")
    }
    return len(out) > start
}

// True when the item has a `builtin` attribute: `@builtin` or `@(builtin, ...)`.
@(private = "file")
has_builtin_attribute :: proc(item: ^odinsema.Item) -> bool {
    for a in item.attributes {
        if a.name == "builtin" {
            return true
        }
    }
    return false
}
