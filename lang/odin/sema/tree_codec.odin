package odinsema

import "base:runtime"
import "core:hash"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"

// Layout version of the tree cache blob. Change it when the blob layout changes; a change of
// Item_Tree changes tree_schema_hash by itself.
TREE_CACHE_FORMAT :: 1

@(private = "file")
TREE_CACHE_MAGIC :: "THORITC\x00"

// Item trees of files under the Odin root, kept across sessions. Mutex is a leaf lock.
@(private)
Tree_Cache :: struct {
    mutex:   sync.Mutex,
    entries: map[string]Cache_Entry, // owned, keys included
    added:   int, // entries stored since the last db_cache_encode
}

// One cached file: its stamp and its tree_encode bytes.
@(private)
Cache_Entry :: struct {
    modtime: i64,
    size:    i64,
    data:    []byte, // owned
}

@(private = "file")
Writer :: struct {
    buf: ^[dynamic]byte,
    ok:  bool,
}

@(private = "file")
Reader :: struct {
    data:  []byte,
    pos:   int,
    alloc: mem.Allocator,
    ok:    bool,
}

// Encodes `tree` and `lines` onto `out`. False when the tree holds a type the codec cannot write.
tree_encode :: proc(tree: ^Item_Tree, lines: []int, out: ^[dynamic]byte) -> bool {
    w := Writer{buf = out, ok = true}
    if !encode_value(&w, tree, type_info_of(Item_Tree)) {
        return false
    }
    w_u32(&w, len(lines))
    for l in lines {
        w_i64(&w, i64(l))
    }
    return w.ok
}

// Decodes what tree_encode wrote into a new tree and lines from `allocator`. False on any
// malformed input; nothing is then held.
tree_decode :: proc(data: []byte, allocator := context.allocator) -> (tree: ^Item_Tree, lines: []int, ok: bool) {
    err: mem.Allocator_Error
    if tree, err = new(Item_Tree, allocator); err != nil {
        return nil, nil, false
    }
    if virtual.arena_init_growing(&tree.arena, 8 * mem.Kilobyte) != nil {
        free(tree, allocator)
        return nil, nil, false
    }
    r := Reader{data = data, alloc = virtual.arena_allocator(&tree.arena), ok = true}
    ok = decode_value(&r, tree, type_info_of(Item_Tree))
    n := 0
    if ok {
        n, ok = r_len(&r, 8)
    }
    if ok {
        if lines, err = make([]int, n, allocator); err != nil {
            ok = false
        }
    }
    for i := 0; ok && i < n; i += 1 {
        v: i64
        ok = r_bytes(&r, &v, 8)
        lines[i] = int(v)
    }
    if !ok || r.pos != len(data) || n == 0 {
        delete(lines, allocator)
        item_tree_destroy(tree, allocator)
        return nil, nil, false
    }
    return tree, lines, true
}

// A hash of the layout of Item_Tree: field names, kinds and sizes.
tree_schema_hash :: proc() -> u64 {
    h := hash.fnv64a(nil)
    stack: [16]typeid
    depth := 0
    return schema_walk(h, type_info_of(Item_Tree), stack[:], &depth)
}

@(private = "file")
schema_walk :: proc(h: u64, ti: ^runtime.Type_Info, stack: []typeid, depth: ^int) -> u64 {
    h := h
    for i in 0 ..< depth^ {
        if stack[i] == ti.id {
            return schema_string(h, "@")
        }
    }
    if named, is_named := ti.variant.(runtime.Type_Info_Named); is_named {
        h = schema_string(h, named.name)
        if depth^ >= len(stack) {
            return h
        }
        stack[depth^] = ti.id
        depth^ += 1
        defer depth^ -= 1
        return schema_walk(h, named.base, stack, depth)
    }
    h = schema_int(h, ti.size)
    #partial switch v in ti.variant {
    case runtime.Type_Info_Integer:
        h = schema_string(h, v.signed ? "i" : "u")
    case runtime.Type_Info_Float:
        h = schema_string(h, "f")
    case runtime.Type_Info_Boolean:
        h = schema_string(h, "b")
    case runtime.Type_Info_Rune:
        h = schema_string(h, "r")
    case runtime.Type_Info_String:
        h = schema_string(h, "s")
    case runtime.Type_Info_Enum:
        h = schema_string(h, "e")
        for name in v.names {
            h = schema_string(h, name)
        }
        h = schema_walk(h, v.base, stack, depth)
    case runtime.Type_Info_Slice:
        h = schema_string(h, "[]")
        h = schema_walk(h, v.elem, stack, depth)
    case runtime.Type_Info_Array:
        h = schema_string(h, "[N]")
        h = schema_int(h, v.count)
        h = schema_walk(h, v.elem, stack, depth)
    case runtime.Type_Info_Struct:
        h = schema_string(h, "{")
        for i in 0 ..< int(v.field_count) {
            if field_skipped(v.types[i]) {
                continue
            }
            h = schema_string(h, v.names[i])
            h = schema_walk(h, v.types[i], stack, depth)
        }
    case:
        h = schema_string(h, "?")
    }
    return h
}

@(private = "file")
schema_string :: proc(h: u64, s: string) -> u64 {
    return hash.fnv64a({0}, hash.fnv64a(transmute([]byte)s, h))
}

@(private = "file")
schema_int :: proc(h: u64, n: int) -> u64 {
    n := n
    return hash.fnv64a(([^]byte)(&n)[:size_of(int)], h)
}

// The arena of an Item_Tree is rebuilt by the decoder.
@(private = "file")
field_skipped :: proc(ti: ^runtime.Type_Info) -> bool {
    return ti.id == typeid_of(virtual.Arena)
}

@(private = "file")
encode_value :: proc(w: ^Writer, p: rawptr, ti: ^runtime.Type_Info) -> bool {
    base := runtime.type_info_base(ti)
    #partial switch v in base.variant {
    case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Boolean, runtime.Type_Info_Rune, runtime.Type_Info_Enum:
        w_bytes(w, p, base.size)
    case runtime.Type_Info_String:
        if v.is_cstring || v.encoding != .UTF_8 {
            return false
        }
        s := (^string)(p)^
        w_u32(w, len(s))
        w_bytes(w, raw_data(s), len(s))
    case runtime.Type_Info_Slice:
        raw := (^runtime.Raw_Slice)(p)^
        w_u32(w, raw.len)
        for i in 0 ..< raw.len {
            if !encode_value(w, rawptr(uintptr(raw.data) + uintptr(i * v.elem_size)), v.elem) {
                return false
            }
        }
    case runtime.Type_Info_Array:
        for i in 0 ..< v.count {
            if !encode_value(w, rawptr(uintptr(p) + uintptr(i * v.elem_size)), v.elem) {
                return false
            }
        }
    case runtime.Type_Info_Struct:
        for i in 0 ..< int(v.field_count) {
            if field_skipped(v.types[i]) {
                continue
            }
            if !encode_value(w, rawptr(uintptr(p) + v.offsets[i]), v.types[i]) {
                return false
            }
        }
    case:
        return false
    }
    return w.ok
}

@(private = "file")
decode_value :: proc(r: ^Reader, p: rawptr, ti: ^runtime.Type_Info) -> bool {
    base := runtime.type_info_base(ti)
    #partial switch v in base.variant {
    case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Rune:
        return r_bytes(r, p, base.size)
    case runtime.Type_Info_Boolean:
        if !r_bytes(r, p, base.size) {
            return false
        }
        b := ([^]byte)(p)
        for i in 1 ..< base.size {
            if b[i] != 0 {
                return false
            }
        }
        return b[0] <= 1
    case runtime.Type_Info_Enum:
        if !r_bytes(r, p, base.size) {
            return false
        }
        value := enum_value(p, v.base)
        for known in v.values {
            if i64(known) == value {
                return true
            }
        }
        return false
    case runtime.Type_Info_String:
        if v.is_cstring || v.encoding != .UTF_8 {
            return false
        }
        n, ok := r_len(r, 1)
        if !ok {
            return false
        }
        if n > 0 {
            s, err := strings.clone(string(r.data[r.pos:][:n]), r.alloc)
            if err != nil {
                return false
            }
            (^string)(p)^ = s
            r.pos += n
        }
        return true
    case runtime.Type_Info_Slice:
        n, ok := r_len(r, max(min_size(v.elem), 1))
        if !ok {
            return false
        }
        if n == 0 {
            return true
        }
        data, err := mem.alloc(n * v.elem_size, v.elem.align, r.alloc)
        if err != nil {
            return false
        }
        (^runtime.Raw_Slice)(p)^ = {data = data, len = n}
        for i in 0 ..< n {
            if !decode_value(r, rawptr(uintptr(data) + uintptr(i * v.elem_size)), v.elem) {
                return false
            }
        }
        return true
    case runtime.Type_Info_Array:
        for i in 0 ..< v.count {
            if !decode_value(r, rawptr(uintptr(p) + uintptr(i * v.elem_size)), v.elem) {
                return false
            }
        }
        return true
    case runtime.Type_Info_Struct:
        for i in 0 ..< int(v.field_count) {
            if field_skipped(v.types[i]) {
                continue
            }
            if !decode_value(r, rawptr(uintptr(p) + v.offsets[i]), v.types[i]) {
                return false
            }
        }
        return true
    }
    return false
}

// The fewest bytes a value of `ti` encodes to.
@(private = "file")
min_size :: proc(ti: ^runtime.Type_Info) -> int {
    base := runtime.type_info_base(ti)
    #partial switch v in base.variant {
    case runtime.Type_Info_String, runtime.Type_Info_Slice:
        return 4
    case runtime.Type_Info_Array:
        return v.count * min_size(v.elem)
    case runtime.Type_Info_Struct:
        n := 0
        for i in 0 ..< int(v.field_count) {
            if !field_skipped(v.types[i]) {
                n += min_size(v.types[i])
            }
        }
        return n
    }
    return base.size
}

@(private = "file")
enum_value :: proc(p: rawptr, base: ^runtime.Type_Info) -> i64 {
    ti := runtime.type_info_base(base)
    signed := false
    if v, ok := ti.variant.(runtime.Type_Info_Integer); ok {
        signed = v.signed
    }
    switch ti.size {
    case 1:
        return signed ? i64((^i8)(p)^) : i64((^u8)(p)^)
    case 2:
        return signed ? i64((^i16)(p)^) : i64((^u16)(p)^)
    case 4:
        return signed ? i64((^i32)(p)^) : i64((^u32)(p)^)
    case 8:
        return (^i64)(p)^
    }
    return min(i64)
}

@(private = "file")
w_bytes :: proc(w: ^Writer, p: rawptr, n: int) {
    if n == 0 || !w.ok {
        return
    }
    if _, err := append(w.buf, ..([^]byte)(p)[:n]); err != nil {
        w.ok = false
    }
}

@(private = "file")
w_u32 :: proc(w: ^Writer, n: int) {
    if n < 0 || n > int(max(u32)) {
        w.ok = false
        return
    }
    v := u32le(n)
    w_bytes(w, &v, 4)
}

@(private = "file")
w_i64 :: proc(w: ^Writer, n: i64) {
    v := i64le(n)
    w_bytes(w, &v, 8)
}

@(private = "file")
w_string :: proc(w: ^Writer, s: string) {
    w_u32(w, len(s))
    w_bytes(w, raw_data(s), len(s))
}

@(private = "file")
r_bytes :: proc(r: ^Reader, p: rawptr, n: int) -> bool {
    if !r.ok || n > len(r.data) - r.pos {
        r.ok = false
        return false
    }
    if n > 0 {
        mem.copy(p, &r.data[r.pos], n)
    }
    r.pos += n
    return true
}

// A u32 count whose `unit`-byte elements fit in what is left.
@(private = "file")
r_len :: proc(r: ^Reader, unit: int) -> (int, bool) {
    v: u32le
    if !r_bytes(r, &v, 4) {
        return 0, false
    }
    n := int(v)
    if n > (len(r.data) - r.pos) / unit {
        r.ok = false
        return 0, false
    }
    return n, true
}

@(private = "file")
r_i64 :: proc(r: ^Reader) -> (i64, bool) {
    v: i64le
    ok := r_bytes(r, &v, 8)
    return i64(v), ok
}

@(private = "file")
r_string :: proc(r: ^Reader) -> (string, bool) {
    n, ok := r_len(r, 1)
    if !ok {
        return "", false
    }
    s := string(r.data[r.pos:][:n])
    r.pos += n
    return s, true
}

@(private)
cache_init :: proc(db: ^Db) {
    db.cache.entries = make(map[string]Cache_Entry, db.allocator)
}

@(private)
cache_destroy :: proc(db: ^Db) {
    cache_clear(db)
    delete(db.cache.entries)
}

@(private = "file")
cache_clear :: proc(db: ^Db) {
    for key, e in db.cache.entries {
        delete(key, db.allocator)
        delete(e.data, db.allocator)
    }
    clear(&db.cache.entries)
    db.cache.added = 0
}

// Replaces the tree cache with the entries of `blob`, which db_cache_encode wrote for `key`. The blob
// is borrowed. False when the blob is malformed or for another key or layout; the cache is then empty.
db_cache_load :: proc(db: ^Db, blob: []byte, key: string) -> bool {
    c := &db.cache
    sync.guard(&c.mutex)
    cache_clear(db)
    r := Reader{data = blob, ok = true}
    magic: [len(TREE_CACHE_MAGIC)]byte
    format: u32le
    schema: u64le
    if !r_bytes(&r, &magic, len(magic)) || string(magic[:]) != TREE_CACHE_MAGIC {
        return false
    }
    if !r_bytes(&r, &format, 4) || format != TREE_CACHE_FORMAT {
        return false
    }
    if !r_bytes(&r, &schema, 8) || u64(schema) != tree_schema_hash() {
        return false
    }
    if blob_key, ok := r_string(&r); !ok || blob_key != key {
        return false
    }
    count, cok := r_len(&r, 4 + 8 + 8 + 8 + 4)
    if !cok {
        return false
    }
    for _ in 0 ..< count {
        path, pok := r_string(&r)
        modtime, mok := r_i64(&r)
        size, sok := r_i64(&r)
        sum, hok := r_i64(&r)
        data, dok := r_string(&r)
        if !pok || !mok || !sok || !hok || !dok || hash.fnv64a(transmute([]byte)data) != u64(sum) {
            cache_clear(db)
            return false
        }
        if !cache_insert(db, path, modtime, size, transmute([]byte)data) {
            cache_clear(db)
            return false
        }
    }
    if r.pos != len(blob) {
        cache_clear(db)
        return false
    }
    c.added = 0
    return true
}

// The number of trees stored since the cache was loaded or last encoded.
db_cache_added :: proc(db: ^Db) -> int {
    sync.guard(&db.cache.mutex)
    return db.cache.added
}

// The tree cache as a blob for db_cache_load under `key`, from `allocator`. The added count
// starts again from zero.
db_cache_encode :: proc(db: ^Db, key: string, allocator := context.allocator) -> ([]byte, bool) {
    c := &db.cache
    sync.guard(&c.mutex)
    buf := make([dynamic]byte, 0, 64 * mem.Kilobyte, allocator)
    w := Writer{buf = &buf, ok = true}
    w_bytes(&w, raw_data(string(TREE_CACHE_MAGIC)), len(TREE_CACHE_MAGIC))
    format := u32le(TREE_CACHE_FORMAT)
    w_bytes(&w, &format, 4)
    schema := u64le(tree_schema_hash())
    w_bytes(&w, &schema, 8)
    w_string(&w, key)
    w_u32(&w, len(c.entries))
    for path, e in c.entries {
        w_string(&w, path)
        w_i64(&w, e.modtime)
        w_i64(&w, e.size)
        w_i64(&w, i64(hash.fnv64a(e.data)))
        w_string(&w, string(e.data))
    }
    if !w.ok {
        delete(buf)
        return nil, false
    }
    c.added = 0
    return buf[:], true
}

// Adds or replaces one entry with a copy of `data`. The caller holds the cache.
@(private = "file")
cache_insert :: proc(db: ^Db, path: string, modtime, size: i64, data: []byte) -> bool {
    c := &db.cache
    owned, err := make([]byte, len(data), db.allocator)
    if err != nil {
        return false
    }
    copy(owned, data)
    if old, found := &c.entries[path]; found {
        delete(old.data, db.allocator)
        old^ = {modtime = modtime, size = size, data = owned}
        return true
    }
    key, kerr := strings.clone(path, db.allocator)
    if kerr != nil {
        delete(owned, db.allocator)
        return false
    }
    if _, _, _, merr := map_entry(&c.entries, key); merr != nil {
        delete(key, db.allocator)
        delete(owned, db.allocator)
        return false
    }
    c.entries[key] = {modtime = modtime, size = size, data = owned}
    return true
}

// Removes the entry of the file at `key`, so the next encode leaves it out.
@(private)
cache_drop :: proc(db: ^Db, key: string) {
    c := &db.cache
    sync.guard(&c.mutex)
    cache_remove(db, key)
}

// Removes the entries of the files directly in the directory `dir_key` whose keys `present` does not hold.
@(private)
cache_prune_dir :: proc(db: ^Db, dir_key: string, present: []string) {
    c := &db.cache
    sync.guard(&c.mutex)
    gone := make([dynamic]string, context.temp_allocator)
    next: for key in c.entries {
        if len(key) <= len(dir_key) || !strings.has_prefix(key, dir_key) || key[len(dir_key)] != '/' {
            continue
        }
        if strings.index_byte(key[len(dir_key) + 1:], '/') >= 0 {
            continue
        }
        for p in present {
            if p == key {
                continue next
            }
        }
        if _, err := append(&gone, key); err != nil {
            return
        }
    }
    for key in gone {
        cache_remove(db, key)
    }
}

// Removes one entry. The caller holds the cache.
@(private = "file")
cache_remove :: proc(db: ^Db, key: string) {
    c := &db.cache
    if key not_in c.entries {
        return
    }
    stored, e := delete_key(&c.entries, key)
    delete(e.data, db.allocator)
    delete(stored, db.allocator)
    c.added += 1
}

// The cached tree and lines of the file at `key` when its stamp matches.
@(private)
cache_take :: proc(db: ^Db, key: string, modtime, size: i64) -> (tree: ^Item_Tree, lines: []int, ok: bool) {
    c := &db.cache
    sync.guard(&c.mutex)
    e, found := c.entries[key]
    if !found || e.modtime != modtime || e.size != size {
        return nil, nil, false
    }
    return tree_decode(e.data, db.allocator)
}

// Stores the tree and lines of the file at `key` under its stamp.
@(private)
cache_put :: proc(db: ^Db, key: string, modtime, size: i64, tree: ^Item_Tree, lines: []int) {
    buf := make([dynamic]byte, 0, 4 * mem.Kilobyte, db.allocator)
    defer delete(buf)
    if !tree_encode(tree, lines, &buf) {
        return
    }
    c := &db.cache
    sync.guard(&c.mutex)
    if cache_insert(db, key, modtime, size, buf[:]) {
        c.added += 1
    }
}
