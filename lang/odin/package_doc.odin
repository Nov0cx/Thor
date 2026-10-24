// The documentation page of the package under the caret, or of the buffer's own package.
package odin

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import lang ".."
import odinsema "sema"

// One declaration on a package page. Strings are temp-allocated.
@(private = "file")
Doc_Entry :: struct {
    name:      string,
    signature: string,
    doc:       string,
}

@(private = "file")
DOC_FENCE_OPEN :: "```odin\n"
@(private = "file")
DOC_FENCE_CLOSE :: "\n```\n"
@(private = "file")
DOC_SECTION_RULE :: "\n---\n\n"

// Fills res.doc with the Markdown page of the package the caret names: an import, `alias.name` or a
// bare alias, else the package of the buffer.
@(private)
package_doc :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    dir := package_dir_under_caret(&ctx)
    if dir == "" {
        if req.path == "" {
            return
        }
        dir = live_dir(&ctx)
    }
    render_package_doc(&ctx, dir, res)
}

// The package directory the caret names; "" when it names none. Temp-allocated.
@(private = "file")
package_dir_under_caret :: proc(ctx: ^Request_Context) -> string {
    if dir, on_import := import_under_caret(ctx, ctx.req.offset); on_import {
        return dir
    }
    m, merr := odinsema.scope_map_range(ctx.parsed, ctx.req.offset, ctx.req.offset)
    if merr != nil {
        return ""
    }
    defer odinsema.scope_map_destroy(m)
    ref, found := odinsema.ref_at(m, ctx.req.offset)
    if !found {
        return ""
    }
    #partial switch ref.kind {
    case .Package_Qualified:
        dir, _ := import_alias_dir(ctx, ref.operand)
        return dir
    case .Free:
        dir, _ := import_alias_dir(ctx, ref.name)
        return dir
    }
    return ""
}

// Fills res.doc with the public declarations of the package at `dir` in the build, sorted by name.
// The buffer replaces its file on disk. Test files are left out.
@(private = "file")
render_package_doc :: proc(ctx: ^Request_Context, dir: string, res: ^lang.Result) {
    entries := make([dynamic]Doc_Entry, context.temp_allocator)
    pkg_name, pkg_doc := "", ""
    live := &ctx.live
    replace := live.path != "" && path_key(dir) == live.dir_key
    if replace && live.in_build && !is_test_file(live.path) {
        pkg_name = strings.clone(live.tree.package_name, context.temp_allocator)
        pkg_doc = strings.clone(live.tree.package_doc, context.temp_allocator)
        collect_entries(live.tree, ctx.target, &entries)
    }

    c := &ctx.e.packages
    sync.lock(&c.mutex)
    entry := package_cache_ensure(c, dir, ctx.target, ctx.req)
    if entry != nil {
        for &f in entry.files {
            if !f.in_build || f.items == nil || is_test_file(f.path) || (replace && f.key == live.key) {
                continue
            }
            if pkg_name == "" {
                pkg_name = strings.clone(f.items.package_name, context.temp_allocator)
            }
            if pkg_doc == "" {
                pkg_doc = strings.clone(f.items.package_doc, context.temp_allocator)
            }
            collect_entries(f.items, ctx.target, &entries)
        }
    }
    sync.unlock(&c.mutex)
    if lang.request_cancelled(ctx.req) || len(entries) == 0 {
        return
    }

    if pkg_name == "" {
        pkg_name = filepath.base(dir)
    }
    slice.sort_by(entries[:], proc(a, b: Doc_Entry) -> bool {
        return a.name < b.name
    })
    page := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&page, "# package %s\n\n", pkg_name)
    fmt.sbprintf(&page, "`%s` — %d symbol%s\n", dir, len(entries), len(entries) == 1 ? "" : "s")
    if pkg_doc != "" {
        fmt.sbprintf(&page, "\n%s\n", pkg_doc)
    }
    for d in entries {
        fmt.sbprintf(&page, "\n## %s\n\n", d.name)
        strings.write_string(&page, DOC_FENCE_OPEN)
        strings.write_string(&page, d.signature)
        strings.write_string(&page, DOC_FENCE_CLOSE)
        if d.doc != "" {
            strings.write_string(&page, DOC_SECTION_RULE)
            strings.write_string(&page, d.doc)
            strings.write_byte(&page, '\n')
        }
    }
    res.doc = lang.Doc_Info {
        title = strings.concatenate({"package ", pkg_name}),
        path  = strings.clone(dir),
        text  = strings.clone(strings.to_string(page)),
    }
    res.ok = true
}

// Appends the public declarations of `tree` whose `when` branch is not known false.
@(private = "file")
collect_entries :: proc(tree: ^odinsema.Item_Tree, target: odinsema.Target, out: ^[dynamic]Doc_Entry) {
    for &item in tree.items {
        if item.visibility != .Public || item.kind == .Import || item.kind == .Foreign_Import {
            continue
        }
        if !odinsema.guard_active(tree, item.guard, target) {
            continue
        }
        append(out, Doc_Entry {
            name      = strings.clone(item.name, context.temp_allocator),
            signature = strings.clone(item.signature, context.temp_allocator),
            doc       = strings.clone(item.doc, context.temp_allocator),
        })
    }
}

@(private = "file")
is_test_file :: proc(path: string) -> bool {
    return strings.has_suffix(filepath.base(path), "_test.odin")
}
