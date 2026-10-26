package odinsema

import "core:mem"
import "core:mem/virtual"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import odinsyntax "../syntax"

// A file of the database, interned by path_key. An id is never reused.
File_Id :: distinct u32

// A package directory of the database, interned by path_key. An id is never reused.
Package_Id :: distinct u32

NO_FILE :: File_Id(max(u32))

// The request's buffer when it has no path.
ANON_FILE :: File_Id(max(u32) - 1)

NO_PACKAGE :: Package_Id(max(u32))

// Reads a whole file. The engine sets lang.source_read, which collapses CRLF to LF.
Read_Proc :: #type proc(path: string, allocator: mem.Allocator) -> (string, bool)

// Gives the current time in nanoseconds. Tests set Db.clock to step time by hand.
Clock_Proc :: #type proc() -> i64

// Longest time a file or directory under the Odin root goes without a stat or a listing.
STABLE_INTERVAL :: 5 * time.Second

// Number of live buffers whose last parse the database keeps.
LIVE_SLOTS :: 8

// Number of package memos the database keeps.
PACKAGE_SLOTS :: 64

// Number of files that are in no package memo and not in the workspace whose data the database keeps.
LOOSE_FILE_SLOTS :: 64

// Bytes of disk parses the database keeps.
BODY_BUDGET :: 64 * mem.Megabyte

// Most files and directory levels a workspace walk reads.
WORKSPACE_FILE_LIMIT :: 4000
WORKSPACE_DEPTH_LIMIT :: 12

// Counters for tests. Read them with sync.atomic_load.
Db_Stats :: struct {
    reads:        int, // files read from disk
    stats:        int, // file stamps read from disk
    listings:     int, // package directories listed
    cache_hits:   int, // item trees taken from the tree cache
    parses:       int, // full parses
    reparses:     int, // incremental parses
    trees:        int, // item trees built
    scopes:       int, // package scopes built for a memo
    local_scopes: int, // package scopes built for one snapshot
}

// The query database: memoized file data, parses, build selection, imports and package scopes,
// refreshed by stat and shared by every snapshot.
// Lock order: workspace slot, package slot, file slot, then Db.lock or Db.lru_mutex. Db.lock and
// Db.lru_mutex are leaves; a file slot never takes a package slot.
Db :: struct {
    allocator:       mem.Allocator, // must be safe to use from every worker thread
    read:            Read_Proc,
    body_budget:     int,
    workspace_limit: int,
    clock:           Clock_Proc,
    stable_interval: i64, // nanoseconds; see STABLE_INTERVAL
    cache:           Tree_Cache,
    lock:            sync.RW_Mutex, // guards the intern maps, the slot arrays and `configs`
    files:           [dynamic]^File_Slot,        // owned
    file_ids:        map[string]File_Id,         // owned; keys borrowed from the slots
    packages:        [dynamic]^Package_Slot,     // owned
    package_ids:     map[string]Package_Id,      // owned; keys borrowed from the slots
    configs:         map[string]u32,             // owned, keys included
    workspace:       Workspace_Slot,
    lru_mutex:       sync.Mutex,
    bodies:          Lru, // files with a disk parse, weighted by bytes
    lives:           Lru, // files with a live parse
    scopes:          Lru, // packages with a memo
    loose:           Lru, // files with disk data that nothing holds
    revision:        u64, // atomic; bumped by every input change
    epoch:           u64, // atomic; one per snapshot
    stats:           Db_Stats,
}

// The values a snapshot pins.
@(private)
Value_Kind :: enum u8 {
    File_Data,
    File_Body,
    Imports,
    Package_Memo,
}

// The header of an immutable, reference-counted value.
@(private)
Value :: struct {
    refs: int, // atomic
    kind: Value_Kind,
}

// The declarations of one file text. Immutable; valid while the snapshot that got it lasts.
File_Data :: struct {
    using value:      Value,
    tree:             ^Item_Tree, // owned
    lines:            []int,      // owned; byte offset of each line start
    shape:            u64,        // item_tree_shape_hash of tree
    shape_changed_at: u64,        // the revision at which the shape of the file last changed
    changed_at:       u64,        // the revision at which this text was read
}

// The parse of one file text. Immutable; valid while the snapshot that got it lasts.
@(private)
File_Body :: struct {
    using value: Value,
    parse:       odinsyntax.Parse, // owned
    bytes:       int,
}

// The imports of one File_Data for one configuration.
@(private)
Imports_Value :: struct {
    using value: Value,
    data:        ^File_Data, // one reference; `list` borrows its strings
    config:      u32,
    epoch:       u64, // the snapshot that last checked `exists`
    checked_at:  i64, // the time of that check
    list:        []File_Import, // owned
}

// The file set and scope of one package directory for one configuration.
@(private)
Package_Memo :: struct {
    using value: Value,
    files:       []File_Id, // owned; sorted by path
    built_from:  []u64,     // owned; the shape_changed_at of each file; 0 for a file that cannot be read
    config:      u32,
    scope:       Package_Scope, // owned
}

// A package of one snapshot. Every field is valid until snapshot_end.
Package_View :: struct {
    id:         Package_Id,
    dir:        string,          // the directory as first asked for
    files:      []File_Id,       // sorted by path; the live buffer joins when it is in the directory
    datas:      []^File_Data,    // nil for a file that cannot be read
    sema_files: []Package_File,  // what `scope` indexes
    scope:      ^Package_Scope,
    local:      bool,            // the scope was built for this snapshot only
}

// What one request reads: its configuration and its own buffer.
Snapshot_Input :: struct {
    target:      Target,       // borrowed until snapshot_end
    collections: ^Collections, // borrowed until snapshot_end; nil when none
    has_live:    bool,
    live_path:   string,       // "" for a buffer with no file
    live_text:   string,       // borrowed until snapshot_end
    cancel:      ^bool,        // read with sync.atomic_load; nil when none
}

// The view of the database of one request on one thread. Everything a query returns stays valid
// until snapshot_end.
Snapshot :: struct {
    db:          ^Db,
    epoch:       u64,
    config:      u32,
    now:         i64,    // the time the snapshot began
    stable_key:  string, // in the arena; path_key of the Odin root with a trailing "/"; "" when none
    target:      Target,
    collections: Collections,
    cancel:      ^bool,
    arena:       virtual.Arena,
    alloc:       mem.Allocator, // of `arena`
    pins:        [dynamic]^Value, // owned; one reference each
    views:       map[Package_Id]^Package_View, // in `arena`
    live:        Live_Overlay,
    open:        bool,
}

// The request's buffer in a snapshot.
@(private)
Live_Overlay :: struct {
    has:            bool,
    id:             File_Id, // ANON_FILE for a buffer with no file
    path:           string,  // borrowed
    text:           string,  // borrowed
    dir:            string,  // in the arena; "." for a buffer with no file
    dir_key:        string,  // in the arena
    ready:          bool,
    data:           ^File_Data, // pinned
    body:           ^File_Body, // pinned
    in_build:       bool,
    in_build_known: bool,
    imports:        []File_Import, // in the arena
    imports_known:  bool,
}

// One file path and its memos. A slot lives until db_destroy; eviction drops its values only.
@(private)
File_Slot :: struct {
    mutex:            sync.Mutex,
    id:               File_Id,
    path:             string, // owned; as first given
    key:              string, // owned; path_key of path
    dir_key:          string, // owned; path_key of the directory
    stat_epoch:       u64,    // the snapshot that last checked the stamp
    stat_time:        i64,    // the time of that check
    stamped:          bool,   // modtime, size and exists describe the disk
    exists:           bool,
    modtime:          i64,
    size:             i64,
    disk:             ^File_Data,    // one reference; nil when not read or not readable
    body:             ^File_Body,    // one reference; nil when evicted
    has_shape:        bool,
    shape:            u64,
    shape_changed_at: u64,
    in_build:         bool,
    in_build_known:   bool,
    in_build_at:      u64, // shape_changed_at of the answer
    in_build_config:  u32,
    imports:          ^Imports_Value, // one reference
    live_data:        ^File_Data,     // one reference; the last live buffer of the path
    live_body:        ^File_Body,     // one reference
    holders:          int,            // atomic; package memos and the workspace that list the file
}

// One package directory and its memo.
@(private)
Package_Slot :: struct {
    mutex:        sync.Mutex,
    id:           Package_Id,
    dir:          string, // owned; as first given
    key:          string, // owned; path_key of dir
    listed_epoch: u64,
    listed_time:  i64, // the time of that listing
    listing:      []File_Id, // owned; sorted by path; valid when listed_epoch != 0
    memo:         ^Package_Memo, // one reference
}

// The files of the workspace.
@(private)
Workspace_Slot :: struct {
    mutex: sync.Mutex,
    key:   string,    // owned; path_key of the root
    epoch: u64,       // the snapshot that walked it
    files: []File_Id, // owned; sorted by path; each holds its file
}

db_init :: proc(db: ^Db, read: Read_Proc, allocator := context.allocator) {
    db^ = {}
    db.allocator = allocator
    db.read = read
    db.body_budget = BODY_BUDGET
    db.workspace_limit = WORKSPACE_FILE_LIMIT
    db.stable_interval = i64(STABLE_INTERVAL)
    cache_init(db)
    db.file_ids = make(map[string]File_Id, allocator)
    db.package_ids = make(map[string]Package_Id, allocator)
    db.configs = make(map[string]u32, allocator)
    db.files = make([dynamic]^File_Slot, allocator)
    db.packages = make([dynamic]^Package_Slot, allocator)
    for l in ([]^Lru{&db.bodies, &db.lives, &db.scopes, &db.loose}) {
        lru_init(l, allocator)
    }
}

// Frees every memo. No snapshot may be open.
db_destroy :: proc(db: ^Db) {
    for slot in db.files {
        file_slot_drop_disk(db, slot)
        file_slot_drop_live(db, slot)
        delete(slot.path, db.allocator)
        delete(slot.key, db.allocator)
        delete(slot.dir_key, db.allocator)
        free(slot, db.allocator)
    }
    for slot in db.packages {
        if slot.memo != nil {
            value_release(db, slot.memo)
        }
        delete(slot.listing, db.allocator)
        delete(slot.dir, db.allocator)
        delete(slot.key, db.allocator)
        free(slot, db.allocator)
    }
    delete(db.workspace.files, db.allocator)
    delete(db.workspace.key, db.allocator)
    cache_destroy(db)
    for key in db.configs {
        delete(key, db.allocator)
    }
    delete(db.configs)
    delete(db.files)
    delete(db.packages)
    delete(db.file_ids)
    delete(db.package_ids)
    for l in ([]^Lru{&db.bodies, &db.lives, &db.scopes, &db.loose}) {
        lru_destroy(l)
    }
    db^ = {}
}

// Opens a snapshot for one request. On false nothing is held, and snapshot_end is still safe.
snapshot_begin :: proc(db: ^Db, snap: ^Snapshot, input: Snapshot_Input) -> bool {
    snap^ = {}
    snap.db = db
    snap.target = input.target
    snap.cancel = input.cancel
    if input.collections != nil {
        snap.collections = input.collections^
    }
    if virtual.arena_init_growing(&snap.arena, 64 * mem.Kilobyte) != nil {
        return false
    }
    snap.alloc = virtual.arena_allocator(&snap.arena)
    snap.open = true
    snap.epoch = sync.atomic_add(&db.epoch, 1) + 1
    snap.now = db_now(db)
    if root := snap.collections.odin_root; root != "" {
        key := path_key(root, snap.alloc)
        snap.stable_key = strings.has_suffix(key, "/") ? key : strings.concatenate({key, "/"}, snap.alloc)
    }
    snap.pins = make([dynamic]^Value, 0, 16, db.allocator)
    snap.views = make(map[Package_Id]^Package_View, snap.alloc)
    config, ok := config_intern(db, snap)
    if !ok {
        snapshot_end(snap)
        return false
    }
    snap.config = config
    if !input.has_live {
        return true
    }
    live := &snap.live
    live.has = true
    live.path = input.live_path
    live.text = input.live_text
    live.id = ANON_FILE
    live.dir = "."
    if input.live_path != "" {
        live.id = file_intern(db, input.live_path)
        if live.id == NO_FILE {
            snapshot_end(snap)
            return false
        }
        if dir := filepath.dir(input.live_path); dir != "" {
            live.dir = strings.clone(dir, snap.alloc)
        }
    }
    live.dir_key = path_key(live.dir, snap.alloc)
    return true
}

// Drops every pin of the snapshot and frees its memory.
snapshot_end :: proc(snap: ^Snapshot) {
    if !snap.open {
        return
    }
    db := snap.db
    for v in snap.pins {
        value_release(db, v)
    }
    delete(snap.pins)
    virtual.arena_destroy(&snap.arena)
    snap^ = {}
    db_trim(db)
}

snapshot_cancelled :: proc(snap: ^Snapshot) -> bool {
    return snap.cancel != nil && sync.atomic_load(snap.cancel)
}

// The file of the request's buffer: ANON_FILE for one with no path, NO_FILE when the snapshot has none.
snapshot_live_file :: proc(snap: ^Snapshot) -> File_Id {
    return snap.live.has ? snap.live.id : NO_FILE
}

// The id of the file at `path`; NO_FILE for "" or when memory runs out.
db_file_id :: proc(snap: ^Snapshot, path: string) -> File_Id {
    if path == "" {
        return NO_FILE
    }
    return file_intern(snap.db, path)
}

// The id of the package directory `dir`; NO_PACKAGE for "" or when memory runs out.
db_package_id :: proc(snap: ^Snapshot, dir: string) -> Package_Id {
    if dir == "" {
        return NO_PACKAGE
    }
    return package_intern(snap.db, dir)
}

// The path of a file as first given; the live path for ANON_FILE. Valid until db_destroy.
db_file_path :: proc(snap: ^Snapshot, id: File_Id) -> string {
    if id == ANON_FILE {
        return snap.live.path
    }
    slot := file_slot(snap.db, id)
    return slot != nil ? slot.path : ""
}

// The path_key of a file. Valid until db_destroy.
db_file_key :: proc(snap: ^Snapshot, id: File_Id) -> string {
    if id == ANON_FILE {
        return ""
    }
    slot := file_slot(snap.db, id)
    return slot != nil ? slot.key : ""
}

@(private)
file_slot :: proc(db: ^Db, id: File_Id) -> ^File_Slot {
    sync.shared_guard(&db.lock)
    if int(id) >= len(db.files) {
        return nil
    }
    return db.files[id]
}

@(private)
package_slot :: proc(db: ^Db, id: Package_Id) -> ^Package_Slot {
    sync.shared_guard(&db.lock)
    if int(id) >= len(db.packages) {
        return nil
    }
    return db.packages[id]
}

@(private)
file_intern :: proc(db: ^Db, path: string) -> File_Id {
    key := path_key(path)
    {
        sync.shared_guard(&db.lock)
        if id, ok := db.file_ids[key]; ok {
            return id
        }
    }
    dir := filepath.dir(path)
    dir_key := path_key(dir == "" ? "." : dir)
    sync.guard(&db.lock)
    if id, ok := db.file_ids[key]; ok {
        return id
    }
    slot, err := new(File_Slot, db.allocator)
    if err != nil {
        return NO_FILE
    }
    slot.id = File_Id(len(db.files))
    slot.path, _ = strings.clone(path, db.allocator)
    slot.key, _ = strings.clone(key, db.allocator)
    slot.dir_key, _ = strings.clone(dir_key, db.allocator)
    if slot.path == "" || slot.key == "" || slot.dir_key == "" {
        file_slot_free_strings(db, slot)
        return NO_FILE
    }
    if _, aerr := append(&db.files, slot); aerr != nil {
        file_slot_free_strings(db, slot)
        return NO_FILE
    }
    if _, _, _, merr := map_entry(&db.file_ids, slot.key); merr != nil {
        pop(&db.files)
        file_slot_free_strings(db, slot)
        return NO_FILE
    }
    db.file_ids[slot.key] = slot.id
    return slot.id
}

@(private = "file")
file_slot_free_strings :: proc(db: ^Db, slot: ^File_Slot) {
    delete(slot.path, db.allocator)
    delete(slot.key, db.allocator)
    delete(slot.dir_key, db.allocator)
    free(slot, db.allocator)
}

@(private)
package_intern :: proc(db: ^Db, dir: string) -> Package_Id {
    key := path_key(dir)
    {
        sync.shared_guard(&db.lock)
        if id, ok := db.package_ids[key]; ok {
            return id
        }
    }
    sync.guard(&db.lock)
    if id, ok := db.package_ids[key]; ok {
        return id
    }
    slot, err := new(Package_Slot, db.allocator)
    if err != nil {
        return NO_PACKAGE
    }
    slot.id = Package_Id(len(db.packages))
    slot.dir, _ = strings.clone(dir, db.allocator)
    slot.key, _ = strings.clone(key, db.allocator)
    ok := slot.dir != "" && slot.key != ""
    if ok {
        _, aerr := append(&db.packages, slot)
        ok = aerr == nil
    }
    if ok {
        if _, _, _, merr := map_entry(&db.package_ids, slot.key); merr != nil {
            pop(&db.packages)
            ok = false
        }
    }
    if !ok {
        delete(slot.dir, db.allocator)
        delete(slot.key, db.allocator)
        free(slot, db.allocator)
        return NO_PACKAGE
    }
    db.package_ids[slot.key] = slot.id
    return slot.id
}

// The number of the configuration of the snapshot; equal configurations get equal numbers.
@(private = "file")
config_intern :: proc(db: ^Db, snap: ^Snapshot) -> (u32, bool) {
    sb := strings.builder_make(db.allocator)
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, target_key(snap.target))
    strings.write_byte(&sb, 0)
    strings.write_string(&sb, snap.collections.odin_root)
    custom := slice.clone(snap.collections.custom, context.temp_allocator)
    slice.sort_by(custom, proc(a, b: Collection) -> bool {
        return a.name < b.name
    })
    for c in custom {
        strings.write_byte(&sb, 0)
        strings.write_string(&sb, c.name)
        strings.write_byte(&sb, '=')
        strings.write_string(&sb, c.root)
    }
    key := strings.to_string(sb)
    {
        sync.shared_guard(&db.lock)
        if n, ok := db.configs[key]; ok {
            return n, true
        }
    }
    sync.guard(&db.lock)
    if n, ok := db.configs[key]; ok {
        return n, true
    }
    owned, err := strings.clone(key, db.allocator)
    if err != nil {
        return 0, false
    }
    n := u32(len(db.configs) + 1)
    if _, _, _, merr := map_entry(&db.configs, owned); merr != nil {
        delete(owned, db.allocator)
        return 0, false
    }
    db.configs[owned] = n
    return n, true
}

@(private)
db_now :: proc(db: ^Db) -> i64 {
    if db.clock != nil {
        return db.clock()
    }
    return time.now()._nsec
}

// True when `key`, a path_key, is under the Odin root of the snapshot.
@(private)
key_stable :: proc(snap: ^Snapshot, key: string) -> bool {
    return snap.stable_key != "" && (strings.has_prefix(key, snap.stable_key) || key == snap.stable_key[:len(snap.stable_key) - 1])
}

// True when a stable check made at `at` is still fresh for the snapshot.
@(private)
check_fresh :: proc(snap: ^Snapshot, at: i64) -> bool {
    return at != 0 && snap.now - at < snap.db.stable_interval
}

@(private)
next_revision :: proc(db: ^Db) -> u64 {
    return sync.atomic_add(&db.revision, 1) + 1
}

@(private)
stat_add :: proc(counter: ^int) {
    sync.atomic_add(counter, 1)
}

@(private)
value_retain :: proc(v: ^Value) {
    sync.atomic_add(&v.refs, 1)
}

// Drops one reference; the last one frees the value.
@(private)
value_release :: proc(db: ^Db, v: ^Value) {
    if v == nil || sync.atomic_sub(&v.refs, 1) != 1 {
        return
    }
    switch v.kind {
    case .File_Data:
        d := (^File_Data)(v)
        item_tree_destroy(d.tree, db.allocator)
        delete(d.lines, db.allocator)
        free(d, db.allocator)
    case .File_Body:
        b := (^File_Body)(v)
        odinsyntax.parse_destroy(&b.parse, db.allocator)
        free(b, db.allocator)
    case .Imports:
        iv := (^Imports_Value)(v)
        file_imports_destroy(iv.list, db.allocator)
        value_release(db, iv.data)
        free(iv, db.allocator)
    case .Package_Memo:
        m := (^Package_Memo)(v)
        package_scope_destroy(&m.scope)
        delete(m.files, db.allocator)
        delete(m.built_from, db.allocator)
        free(m, db.allocator)
    }
}

// Adds a reference to `v` that snapshot_end drops. False when memory runs out; `v` is then not pinned.
@(private)
pin :: proc(snap: ^Snapshot, v: ^Value) -> bool {
    if v == nil {
        return true
    }
    if _, err := append(&snap.pins, v); err != nil {
        return false
    }
    value_retain(v)
    return true
}

// Hands a new value's only reference to the snapshot. On false the value is freed.
@(private)
pin_owned :: proc(snap: ^Snapshot, v: ^Value) -> bool {
    if _, err := append(&snap.pins, v); err != nil {
        value_release(snap.db, v)
        return false
    }
    return true
}

@(private)
file_data_new :: proc(db: ^Db, parsed: odinsyntax.Parse) -> ^File_Data {
    tree, terr := item_tree(parsed, db.allocator)
    if terr != nil {
        return nil
    }
    stat_add(&db.stats.trees)
    text := parsed.tree != nil ? parsed.tree.text : ""
    lines := line_starts(text, db.allocator)
    if lines == nil {
        item_tree_destroy(tree, db.allocator)
        return nil
    }
    return file_data_wrap(db, tree, lines)
}

// A File_Data that owns `tree` and `lines`. On nil both are freed.
@(private)
file_data_wrap :: proc(db: ^Db, tree: ^Item_Tree, lines: []int) -> ^File_Data {
    d, err := new(File_Data, db.allocator)
    if err != nil {
        item_tree_destroy(tree, db.allocator)
        delete(lines, db.allocator)
        return nil
    }
    d.kind = .File_Data
    d.refs = 1
    d.tree = tree
    d.lines = lines
    d.shape = item_tree_shape_hash(tree)
    return d
}

@(private)
file_body_new :: proc(db: ^Db, parsed: odinsyntax.Parse) -> ^File_Body {
    b, err := new(File_Body, db.allocator)
    if err != nil {
        return nil
    }
    b.kind = .File_Body
    b.refs = 1
    b.parse = parsed
    for t := parsed.tree; t != nil; t = t.base {
        b.bytes += int(t.arena.total_used)
    }
    return b
}

// Removes the least recently used memos past their budgets. The caller holds no slot.
@(private)
db_trim :: proc(db: ^Db) {
    for {
        Victim :: enum u8 {
            None,
            Body,
            Live,
            Scope,
            Loose,
        }
        victim := Victim.None
        id: u32
        {
            sync.guard(&db.lru_mutex)
            ok: bool
            switch {
            case db.bodies.total > db.body_budget && db.bodies.count > 0:
                id, ok = lru_pop(&db.bodies)
                victim = .Body
            case db.lives.count > LIVE_SLOTS:
                id, ok = lru_pop(&db.lives)
                victim = .Live
            case db.scopes.count > PACKAGE_SLOTS:
                id, ok = lru_pop(&db.scopes)
                victim = .Scope
            case db.loose.count > LOOSE_FILE_SLOTS:
                id, ok = lru_pop(&db.loose)
                victim = .Loose
            }
            if !ok {
                return
            }
        }
        switch victim {
        case .None:
            return
        case .Body:
            if slot := file_slot(db, File_Id(id)); slot != nil {
                sync.guard(&slot.mutex)
                if !lru_listed(db, &db.bodies, id) && slot.body != nil {
                    value_release(db, slot.body)
                    slot.body = nil
                }
            }
        case .Live:
            if slot := file_slot(db, File_Id(id)); slot != nil {
                sync.guard(&slot.mutex)
                if !lru_listed(db, &db.lives, id) {
                    file_slot_drop_live(db, slot)
                }
            }
        case .Scope:
            if slot := package_slot(db, Package_Id(id)); slot != nil {
                sync.guard(&slot.mutex)
                if !lru_listed(db, &db.scopes, id) {
                    package_slot_drop_memo(db, slot)
                }
            }
        case .Loose:
            if slot := file_slot(db, File_Id(id)); slot != nil {
                sync.guard(&slot.mutex)
                if !lru_listed(db, &db.loose, id) && sync.atomic_load(&slot.holders) == 0 {
                    file_slot_drop_disk(db, slot)
                }
            }
        }
    }
}

@(private)
lru_listed :: proc(db: ^Db, l: ^Lru, id: u32) -> bool {
    sync.guard(&db.lru_mutex)
    return lru_has(l, id)
}

@(private)
lru_touch_locked :: proc(db: ^Db, l: ^Lru, id: u32, weight := 1) {
    sync.guard(&db.lru_mutex)
    lru_touch(l, id, weight)
}

@(private)
lru_remove_locked :: proc(db: ^Db, l: ^Lru, id: u32) {
    sync.guard(&db.lru_mutex)
    lru_remove(l, id)
}

// Adds one holder to each file.
@(private)
files_hold :: proc(db: ^Db, ids: []File_Id) {
    for id in ids {
        slot := file_slot(db, id)
        if slot != nil && sync.atomic_add(&slot.holders, 1) == 0 {
            lru_remove_locked(db, &db.loose, u32(id))
        }
    }
}

// Drops one holder of each file; a file nothing holds joins the loose list.
@(private)
files_release :: proc(db: ^Db, ids: []File_Id) {
    for id in ids {
        slot := file_slot(db, id)
        if slot != nil && sync.atomic_sub(&slot.holders, 1) == 1 {
            lru_touch_locked(db, &db.loose, u32(id))
        }
    }
}

// Drops the disk memos of a file and keeps its path and shape history. The caller holds the slot.
@(private)
file_slot_drop_disk :: proc(db: ^Db, slot: ^File_Slot) {
    if slot.disk != nil {
        value_release(db, slot.disk)
        slot.disk = nil
    }
    if slot.body != nil {
        value_release(db, slot.body)
        slot.body = nil
        lru_remove_locked(db, &db.bodies, u32(slot.id))
    }
    if slot.imports != nil {
        value_release(db, slot.imports)
        slot.imports = nil
    }
    slot.stamped = false
    slot.stat_epoch = 0
    slot.in_build_known = false
}

// Drops the last live buffer of a file. The caller holds the slot.
@(private)
file_slot_drop_live :: proc(db: ^Db, slot: ^File_Slot) {
    if slot.live_data != nil {
        value_release(db, slot.live_data)
        slot.live_data = nil
    }
    if slot.live_body != nil {
        value_release(db, slot.live_body)
        slot.live_body = nil
    }
}

// Drops the memo of a package and releases its files. The caller holds the slot.
@(private)
package_slot_drop_memo :: proc(db: ^Db, slot: ^Package_Slot) {
    if slot.memo == nil {
        return
    }
    files_release(db, slot.memo.files)
    value_release(db, slot.memo)
    slot.memo = nil
}

// An intrusive list of ids, least recently used first, guarded by Db.lru_mutex.
@(private)
Lru :: struct {
    prev:   [dynamic]u32, // owned; by id
    next:   [dynamic]u32, // owned; by id
    weight: [dynamic]int, // owned; by id
    listed: [dynamic]bool, // owned; by id
    head:   u32,
    tail:   u32,
    count:  int,
    total:  int,
}

@(private = "file")
LRU_NIL :: max(u32)

@(private = "file")
lru_init :: proc(l: ^Lru, allocator: mem.Allocator) {
    l.prev = make([dynamic]u32, allocator)
    l.next = make([dynamic]u32, allocator)
    l.weight = make([dynamic]int, allocator)
    l.listed = make([dynamic]bool, allocator)
    l.head = LRU_NIL
    l.tail = LRU_NIL
}

@(private = "file")
lru_destroy :: proc(l: ^Lru) {
    delete(l.prev)
    delete(l.next)
    delete(l.weight)
    delete(l.listed)
}

@(private = "file")
lru_has :: proc(l: ^Lru, id: u32) -> bool {
    return int(id) < len(l.listed) && l.listed[id]
}

// Moves `id` to the most recent end with `weight`. An id that cannot be listed stays out.
@(private = "file")
lru_touch :: proc(l: ^Lru, id: u32, weight: int) {
    if int(id) >= len(l.listed) {
        n := int(id) + 1
        if resize(&l.prev, n) != nil || resize(&l.next, n) != nil || resize(&l.weight, n) != nil || resize(&l.listed, n) != nil {
            return
        }
    }
    lru_remove(l, id)
    l.listed[id] = true
    l.weight[id] = weight
    l.prev[id] = l.tail
    l.next[id] = LRU_NIL
    if l.tail != LRU_NIL {
        l.next[l.tail] = id
    } else {
        l.head = id
    }
    l.tail = id
    l.count += 1
    l.total += weight
}

@(private = "file")
lru_remove :: proc(l: ^Lru, id: u32) {
    if !lru_has(l, id) {
        return
    }
    p, n := l.prev[id], l.next[id]
    if p != LRU_NIL {
        l.next[p] = n
    } else {
        l.head = n
    }
    if n != LRU_NIL {
        l.prev[n] = p
    } else {
        l.tail = p
    }
    l.listed[id] = false
    l.count -= 1
    l.total -= l.weight[id]
}

@(private = "file")
lru_pop :: proc(l: ^Lru) -> (u32, bool) {
    if l.head == LRU_NIL {
        return 0, false
    }
    id := l.head
    lru_remove(l, id)
    return id, true
}
