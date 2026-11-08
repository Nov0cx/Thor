package odinsema

import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
Test_Package :: struct {
    files: [dynamic]Package_File,
}

@(private = "file")
add_file :: proc(t: ^testing.T, p: ^Test_Package, path, src: string) {
    parsed, err := odinsyntax.parse(src)
    testing.expect_value(t, err, nil)
    defer odinsyntax.parse_destroy(&parsed)
    tree, terr := item_tree(parsed)
    testing.expect_value(t, terr, nil)
    append(&p.files, Package_File{path, tree})
}

@(private = "file")
destroy_package :: proc(p: ^Test_Package) {
    for f in p.files {
        item_tree_destroy(f.items)
    }
    delete(p.files)
}

@(test)
test_package_scope_build_filter :: proc(t: ^testing.T) {
    p: Test_Package
    defer destroy_package(&p)
    add_file(t, &p, "pkg/main.odin", "package pkg\n\nimport \"core:fmt\"\n\nrun :: proc() {}\n")
    add_file(t, &p, "pkg/os_windows.odin", "package pkg\n\nopen :: proc() {}\n")
    add_file(t, &p, "pkg/os_linux.odin", "package pkg\n\nopen :: proc() {}\n")
    add_file(t, &p, "pkg/os_posix.odin", "#+build !windows\npackage pkg\n\nposix_only :: 1\n")

    win := Target{os = .Windows, arch = .amd64}
    scope, err := package_scope(p.files[:], win)
    testing.expect_value(t, err, nil)
    defer package_scope_destroy(&scope)

    testing.expect_value(t, scope.name, "pkg")
    testing.expect_value(t, len(scope.files), 2)
    testing.expect_value(t, len(scope.conflicts), 0)
    testing.expect_value(t, len(package_scope_lookup(&scope, "fmt")), 0)
    testing.expect_value(t, len(package_scope_lookup(&scope, "posix_only")), 0)
    opens := package_scope_lookup(&scope, "open")
    testing.expect_value(t, len(opens), 1)
    if len(opens) == 1 {
        testing.expect_value(t, opens[0].file, 1)
        testing.expect_value(t, package_item(p.files[:], opens[0]).name, "open")
    }

    lin := Target{os = .Linux, arch = .amd64}
    lscope, lerr := package_scope(p.files[:], lin)
    testing.expect_value(t, lerr, nil)
    defer package_scope_destroy(&lscope)
    testing.expect_value(t, len(lscope.files), 3)
    testing.expect_value(t, len(package_scope_lookup(&lscope, "posix_only")), 1)
}

@(test)
test_package_scope_conflicts :: proc(t: ^testing.T) {
    p: Test_Package
    defer destroy_package(&p)
    add_file(t, &p, "pkg/a.odin", `package pkg

dup :: 1
guarded :: 1
@(private = "file")
helper :: proc() {}
when ODIN_OS == .Linux {
    guarded :: 2
}
_ :: 3
`)
    add_file(t, &p, "pkg/b.odin", `package pkg

dup :: 2
@(private = "file")
helper :: proc() {}
_ :: 4
`)
    scope, err := package_scope(p.files[:], Target{os = .Windows, arch = .amd64})
    testing.expect_value(t, err, nil)
    defer package_scope_destroy(&scope)

    testing.expect_value(t, len(scope.conflicts), 1)
    if len(scope.conflicts) == 1 {
        c := scope.conflicts[0]
        testing.expect_value(t, c.name, "dup")
        testing.expect_value(t, len(c.refs), 2)
    }
    guarded := package_scope_lookup(&scope, "guarded")
    testing.expect_value(t, len(guarded), 2)
    for ref in guarded {
        testing.expect(t, package_ref_active(&scope, ref) == (package_item(p.files[:], ref).guard < 0))
    }
    testing.expect_value(t, len(package_scope_lookup(&scope, "helper")), 2)
    testing.expect_value(t, len(package_scope_lookup(&scope, "_")), 0)
}

@(test)
test_package_scope_when_conflicts :: proc(t: ^testing.T) {
    p: Test_Package
    defer destroy_package(&p)
    add_file(t, &p, "pkg/a.odin", `package pkg

when ODIN_OS == .Windows {
    open :: proc() {}
    @(private = "file")
    local :: 1
} else {
    open :: proc() {}
}
when MAYBE_FLAG {
    flag :: 1
} else {
    flag :: 2
}
`)
    add_file(t, &p, "pkg/b.odin", `package pkg

when ODIN_OS == .Windows {
    open :: proc() {}
    local :: 2
}
flag :: 3
`)
    win := Target{os = .Windows, arch = .amd64}
    scope, err := package_scope(p.files[:], win)
    testing.expect_value(t, err, nil)
    defer package_scope_destroy(&scope)

    testing.expect_value(t, len(scope.conflicts), 1)
    if len(scope.conflicts) == 1 {
        c := scope.conflicts[0]
        testing.expect_value(t, c.name, "open")
        testing.expect_value(t, len(c.refs), 2)
        for ref in c.refs {
            testing.expect(t, package_ref_active(&scope, ref))
        }
    }
    opens := package_scope_lookup(&scope, "open")
    testing.expect_value(t, len(opens), 3)
    inactive := 0
    for ref in opens {
        if !package_ref_active(&scope, ref) {
            inactive += 1
            testing.expect_value(t, ref.file, 0)
        }
    }
    testing.expect_value(t, inactive, 1)
    testing.expect_value(t, len(package_scope_lookup(&scope, "local")), 2)
    for ref in package_scope_lookup(&scope, "flag") {
        testing.expect(t, package_ref_active(&scope, ref), "an unknown guard is active")
    }

    lin := Target{os = .Linux, arch = .amd64}
    lscope, lerr := package_scope(p.files[:], lin)
    testing.expect_value(t, lerr, nil)
    defer package_scope_destroy(&lscope)
    testing.expect_value(t, len(lscope.conflicts), 0)
    active := 0
    for ref in package_scope_lookup(&lscope, "open") {
        if package_ref_active(&lscope, ref) {
            active += 1
        }
    }
    testing.expect_value(t, active, 1)
}

// The scope owns its names, so it outlives the item trees it was built from.
@(test)
test_package_scope_owns_names :: proc(t: ^testing.T) {
    p: Test_Package
    add_file(t, &p, "pkg/a.odin", "package pkg\n\nrun :: proc() {}\nrun :: proc() {}\n")
    scope, err := package_scope(p.files[:], Target{os = .Windows, arch = .amd64})
    destroy_package(&p)
    testing.expect_value(t, err, nil)
    defer package_scope_destroy(&scope)
    testing.expect_value(t, scope.name, "pkg")
    testing.expect_value(t, len(package_scope_lookup(&scope, "run")), 2)
    testing.expect_value(t, len(scope.conflicts), 1)
    if len(scope.conflicts) == 1 {
        testing.expect_value(t, scope.conflicts[0].name, "run")
    }
}
