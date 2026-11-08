package odinsema

import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"

// Number of frozen checker states the database keeps.
TYPE_STATE_SLOTS :: 4

// A state is not extended past twice the type count of the first state of its line plus this
// many: the next checker starts afresh and drops the types no entry reaches.
TYPE_STATE_SLACK :: 4096

// The files and shapes of a package view a checker read.
@(private)
Package_Stamp :: struct {
    files:   []File_Id,
    shapes:  []u64, // item_tree_shape_hash per file; 0 for one that cannot be read
    missing: bool,  // the view was nil
}

// The memo tables of a checker, frozen for the checkers of later snapshots with the same
// configuration, home package and buffer. It holds no entry that depends on the text of
// `exclude`. It is valid while each file of `stamps` has the same changed_at and each package of
// `package_stamps` the same files and shapes. Immutable after publish except `used`; every slice
// and string is in `arena`.
@(private)
Type_State :: struct {
    refs:           int, // atomic
    used:           u64, // guarded by Db.type_mutex
    arena:          virtual.Arena,
    config:         u32,
    home_key:       string,
    exclude:        File_Id,
    first_len:      int, // the type count of the first state of the line this one extends
    table:          Type_Table,
    decls:          map[Symbol]Decl_Info,
    consts:         map[Symbol]Const_Info,
    instances:      map[Type_Id]Instance,
    inst_cache:     map[string]Memo_Type,
    results:        map[Type_Id]Type_Id,
    pairs:          map[Type_Id]Type_Id,
    odin_types:     map[string]Memo_Type,
    layouts:        map[Type_Id]Layout,
    stamps:         map[File_Id]u64,
    package_stamps: map[Package_Id]Package_Stamp,
}

// Adds a dependency node used by the current one and makes it current. Gives the node and the
// frame dep_leave restores.
@(private)
dep_enter :: proc(c: ^Checker) -> (node, saved: i32) {
    saved = c.frame
    if _, err := append(&c.nodes, false); !note_alloc(c, err) {
        return NO_NODE, saved
    }
    node = i32(len(c.nodes) - 1)
    dep_use(c, node)
    c.frame = node
    return
}

@(private)
dep_leave :: proc(c: ^Checker, saved: i32) {
    c.frame = saved
}

// Records that the current node reads `node`.
@(private)
dep_use :: proc(c: ^Checker, node: i32) {
    if c.frame < 0 || node < 0 || node == c.frame {
        return
    }
    _, err := append(&c.edges, [2]i32{c.frame, node})
    note_alloc(c, err)
}

// Records that the current node reads the request's buffer.
@(private)
dep_taint :: proc(c: ^Checker) {
    if c.frame >= 0 {
        c.nodes[c.frame] = true
    }
}

// Records the files and shapes of a package view the first time the checker reads it.
@(private)
package_stamp_note :: proc(c: ^Checker, pkg: Package_Id, view: ^Package_View) {
    if pkg in c.package_stamps {
        return
    }
    stamp := Package_Stamp{missing = view == nil}
    if view != nil {
        files, ferr := slice.clone(view.files, c.alloc)
        shapes, serr := make([]u64, len(view.datas), c.alloc)
        if !note_alloc(c, ferr) || !note_alloc(c, serr) {
            return
        }
        for d, i in view.datas {
            if d != nil {
                shapes[i] = d.shape
            }
        }
        stamp.files = files
        stamp.shapes = shapes
    }
    if _, entry, _, err := map_entry(&c.package_stamps, pkg); note_alloc(c, err) {
        entry^ = stamp
    }
}

// Adds every entry of `src` to `dst`.
@(private)
map_copy :: proc(dst: ^$M/map[$K]$V, src: M) -> mem.Allocator_Error {
    reserve(dst, len(dst) + len(src)) or_return
    for k, v in src {
        _, value, _, err := map_entry(dst, k)
        if err != nil {
            return err
        }
        value^ = v
    }
    return nil
}

// Starts the tables of `c` from the frozen state of its key when the snapshot still agrees with
// it. A state the snapshot disagrees with is dropped.
@(private)
type_state_adopt :: proc(c: ^Checker) {
    db := c.snap.db
    s: ^Type_State
    {
        sync.guard(&db.type_mutex)
        for slot in db.type_states {
            if slot != nil && type_state_matches(slot, c.snap.config, c.exclude, c.home_key) {
                s = slot
                sync.atomic_add(&s.refs, 1)
                db.type_clock += 1
                s.used = db.type_clock
                break
            }
        }
    }
    if s == nil {
        return
    }
    if !type_state_valid(c.snap, s) {
        if !snapshot_cancelled(c.snap) {
            type_state_drop(db, s)
        }
        type_state_release(db, s)
        return
    }
    c.base = s
    if type_state_clone(c, s) {
        stat_add(&db.stats.type_hits)
    }
}

@(private = "file")
type_state_matches :: proc(s: ^Type_State, config: u32, exclude: File_Id, home_key: string) -> bool {
    return s.config == config && s.exclude == exclude && s.home_key == home_key
}

// True when every file and package the state read is as it was.
@(private = "file")
type_state_valid :: proc(snap: ^Snapshot, s: ^Type_State) -> bool {
    for id, stamp in s.stamps {
        if snapshot_cancelled(snap) {
            return false
        }
        data := db_file(snap, id)
        if (data != nil ? data.changed_at : 0) != stamp {
            return false
        }
    }
    for pkg, ps in s.package_stamps {
        if snapshot_cancelled(snap) {
            return false
        }
        view := db_package(snap, pkg)
        if (view == nil) != ps.missing {
            return false
        }
        if view == nil {
            continue
        }
        if !slice.equal(view.files, ps.files) || len(view.datas) != len(ps.shapes) {
            return false
        }
        for d, i in view.datas {
            if (d != nil ? d.shape : 0) != ps.shapes[i] {
                return false
            }
        }
    }
    return true
}

// Copies the tables of `s` into `c`. The copies share the slices and strings of `s`.
@(private = "file")
type_state_clone :: proc(c: ^Checker, s: ^Type_State) -> bool {
    if !note_alloc(c, type_table_copy(&c.table, &s.table, c.alloc, false)) {
        return false
    }
    errs := [?]mem.Allocator_Error {
        map_copy(&c.decls, s.decls),
        map_copy(&c.consts, s.consts),
        map_copy(&c.instances, s.instances),
        map_copy(&c.inst_cache, s.inst_cache),
        map_copy(&c.results, s.results),
        map_copy(&c.pairs, s.pairs),
        map_copy(&c.odin_types, s.odin_types),
        map_copy(&c.layouts, s.layouts),
        map_copy(&c.stamps, s.stamps),
        map_copy(&c.package_stamps, s.package_stamps),
    }
    for err in errs {
        if !note_alloc(c, err) {
            return false
        }
    }
    return true
}

// Freezes the entries of `c` that do not depend on the request's buffer as the state of its key.
// Nothing is frozen when it added no such entry, failed or was cancelled.
@(private)
type_state_publish :: proc(c: ^Checker) {
    if c.err != nil || c.table.err != nil || snapshot_cancelled(c.snap) {
        return
    }
    db := c.snap.db
    temp := scratch_begin(c)
    defer scratch_end(temp)
    dirty, ok := dirty_nodes(c)
    if !ok || !has_new_entries(c, dirty) {
        return
    }
    first_len := len(c.table.types)
    if c.base != nil {
        first_len = c.base.first_len
        if len(c.table.types) > 2 * first_len + TYPE_STATE_SLACK {
            type_state_drop(db, c.base)
            return
        }
    }
    s, nerr := new(Type_State, db.allocator)
    if nerr != nil {
        return
    }
    if virtual.arena_init_growing(&s.arena, CHECKER_ARENA_BLOCK) != nil {
        free(s, db.allocator)
        return
    }
    s.refs = 1
    s.config = c.snap.config
    s.exclude = c.exclude
    s.first_len = first_len
    if type_state_freeze(c, s, dirty) != nil {
        virtual.arena_destroy(&s.arena)
        free(s, db.allocator)
        return
    }
    stat_add(&db.stats.type_states)
    type_state_put(db, s)
}

// Per dependency node: it reads the request's buffer, itself or through a node it uses.
@(private = "file")
dirty_nodes :: proc(c: ^Checker) -> ([]bool, bool) {
    n := len(c.nodes)
    dirty, derr := make([]bool, n, c.tmp)
    start, serr := make([]i32, n + 1, c.tmp)
    next, nerr := make([]i32, n, c.tmp)
    users, uerr := make([]i32, len(c.edges), c.tmp)
    stack, kerr := make([dynamic]i32, 0, n, c.tmp)
    if derr != nil || serr != nil || nerr != nil || uerr != nil || kerr != nil {
        return nil, false
    }
    copy(dirty, c.nodes[:])
    for e in c.edges {
        start[e[1] + 1] += 1
    }
    for i in 0 ..< n {
        start[i + 1] += start[i]
    }
    copy(next, start[:n])
    for e in c.edges {
        users[next[e[1]]] = e[0]
        next[e[1]] += 1
    }
    for d, i in dirty {
        if d {
            append(&stack, i32(i))
        }
    }
    for len(stack) > 0 {
        used := pop(&stack)
        for u in users[start[used]:start[used + 1]] {
            if !dirty[u] {
                dirty[u] = true
                append(&stack, u)
            }
        }
    }
    return dirty, true
}

@(private = "file")
clean :: proc(dirty: []bool, node: i32) -> bool {
    return node < 0 || !dirty[node]
}

// True when the checker made an entry a later checker can use.
@(private = "file")
has_new_entries :: proc(c: ^Checker, dirty: []bool) -> bool {
    for _, info in c.decls {
        if info.node >= 0 && !dirty[info.node] {
            return true
        }
    }
    for _, info in c.consts {
        if info.node >= 0 && !dirty[info.node] {
            return true
        }
    }
    for _, memo in c.inst_cache {
        if memo.node >= 0 && !dirty[memo.node] {
            return true
        }
    }
    for _, memo in c.odin_types {
        if memo.node >= 0 && !dirty[memo.node] {
            return true
        }
    }
    return false
}

// Copies the clean entries of `c` into `s`, every slice and string included.
@(private = "file")
type_state_freeze :: proc(c: ^Checker, s: ^Type_State, dirty: []bool) -> mem.Allocator_Error {
    a := virtual.arena_allocator(&s.arena)
    s.home_key = strings.clone(c.home_key, a) or_return
    type_table_copy(&s.table, &c.table, a, true) or_return
    for sym in c.table.named {
        if !named_kept(c, dirty, sym) {
            delete_key(&s.table.named, sym)
        }
    }
    for sym in c.table.distincts {
        if !distinct_kept(c, dirty, sym) {
            delete_key(&s.table.distincts, sym)
        }
    }
    s.decls = make(map[Symbol]Decl_Info, a)
    for sym, info in c.decls {
        if clean(dirty, info.node) {
            _, entry, _, err := map_entry(&s.decls, sym)
            if err != nil {
                return err
            }
            entry^ = Decl_Info{info.type, info.is_type, NO_NODE}
        }
    }
    s.consts = make(map[Symbol]Const_Info, a)
    for sym, info in c.consts {
        if clean(dirty, info.node) {
            value := clone_const(info.value, a) or_return
            _, entry, _, err := map_entry(&s.consts, sym)
            if err != nil {
                return err
            }
            entry^ = Const_Info{value, info.ok, NO_NODE}
        }
    }
    s.instances = make(map[Type_Id]Instance, a)
    for id, inst in c.instances {
        args := make([]Operand, len(inst.args), a) or_return
        for op, i in inst.args {
            args[i] = op
            args[i].dir = strings.clone(op.dir, a) or_return
            args[i].value = clone_const(op.value, a) or_return
        }
        _, entry, _, err := map_entry(&s.instances, id)
        if err != nil {
            return err
        }
        entry^ = Instance{inst.generic, args}
    }
    s.inst_cache = make(map[string]Memo_Type, a)
    for key, memo in c.inst_cache {
        if clean(dirty, memo.node) {
            stored := strings.clone(key, a) or_return
            _, entry, _, err := map_entry(&s.inst_cache, stored)
            if err != nil {
                return err
            }
            entry^ = Memo_Type{memo.type, NO_NODE}
        }
    }
    s.odin_types = make(map[string]Memo_Type, a)
    for key, memo in c.odin_types {
        if clean(dirty, memo.node) {
            stored := strings.clone(key, a) or_return
            _, entry, _, err := map_entry(&s.odin_types, stored)
            if err != nil {
                return err
            }
            entry^ = Memo_Type{memo.type, NO_NODE}
        }
    }
    s.results = make(map[Type_Id]Type_Id, a)
    s.pairs = make(map[Type_Id]Type_Id, a)
    s.layouts = make(map[Type_Id]Layout, a)
    s.stamps = make(map[File_Id]u64, a)
    map_copy(&s.results, c.results) or_return
    map_copy(&s.pairs, c.pairs) or_return
    map_copy(&s.layouts, c.layouts) or_return
    map_copy(&s.stamps, c.stamps) or_return
    s.package_stamps = make(map[Package_Id]Package_Stamp, a)
    for pkg, ps in c.package_stamps {
        stamp := Package_Stamp{missing = ps.missing}
        stamp.files = slice.clone(ps.files, a) or_return
        stamp.shapes = slice.clone(ps.shapes, a) or_return
        _, entry, _, err := map_entry(&s.package_stamps, pkg)
        if err != nil {
            return err
        }
        entry^ = stamp
    }
    return nil
}

// True when the named type of `sym` does not depend on the request's buffer.
@(private = "file")
named_kept :: proc(c: ^Checker, dirty: []bool, sym: Symbol) -> bool {
    if sym.file == c.exclude {
        return false
    }
    if info, ok := c.decls[sym]; ok {
        return clean(dirty, info.node)
    }
    return true
}

// True when the distinct type of `sym` does not depend on the request's buffer.
@(private = "file")
distinct_kept :: proc(c: ^Checker, dirty: []bool, sym: Symbol) -> bool {
    if sym.file == c.exclude {
        return false
    }
    if node, ok := c.distinct_nodes[sym]; ok {
        return clean(dirty, node)
    }
    if info, ok := c.decls[sym]; ok {
        return clean(dirty, info.node)
    }
    return true
}

@(private = "file")
clone_const :: proc(v: Const_Value, a: mem.Allocator) -> (Const_Value, mem.Allocator_Error) {
    if s, is_string := v.(string); is_string {
        out, err := strings.clone(s, a)
        return out, err
    }
    return v, nil
}

// Makes `s` the state of its key, in place of the one it replaces or of the least recently used.
@(private = "file")
type_state_put :: proc(db: ^Db, s: ^Type_State) {
    old: ^Type_State
    {
        sync.guard(&db.type_mutex)
        db.type_clock += 1
        s.used = db.type_clock
        at := -1
        for slot, i in db.type_states {
            if slot != nil && type_state_matches(slot, s.config, s.exclude, s.home_key) {
                at = i
                break
            }
        }
        if at < 0 {
            for slot, i in db.type_states {
                if slot == nil {
                    at = i
                    break
                }
            }
        }
        if at < 0 {
            at = 0
            for slot, i in db.type_states {
                if slot.used < db.type_states[at].used {
                    at = i
                }
            }
        }
        old = db.type_states[at]
        db.type_states[at] = s
    }
    type_state_release(db, old)
}

// Removes `s` from the slots, so no later checker starts from it.
@(private = "file")
type_state_drop :: proc(db: ^Db, s: ^Type_State) {
    found := false
    {
        sync.guard(&db.type_mutex)
        for &slot in db.type_states {
            if slot == s {
                slot = nil
                found = true
            }
        }
    }
    if found {
        type_state_release(db, s)
    }
}

// Drops one reference; the last one frees the state.
@(private)
type_state_release :: proc(db: ^Db, s: ^Type_State) {
    if s == nil || sync.atomic_sub(&s.refs, 1) != 1 {
        return
    }
    virtual.arena_destroy(&s.arena)
    free(s, db.allocator)
}
