package odinsema

import "core:mem"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"

import odinsyntax "../syntax"

// A package whose public declarations a bare name reaches with no import.
Universe_Package :: struct {
    dir: string, // borrowed
    all: bool,   // every public item; else only the items with a `builtin` attribute
}

// What a name denotes.
Resolved_Kind :: enum u8 {
    None,
    Local,   // a declaration in a procedure, a signature or a record
    Item,    // a package-level declaration of the file's package or of a universe package
    Import,  // an import alias
    Basic,   // a basic type name
    Builtin, // `true`, `false`, `nil` or an `ODIN_` constant
}

// The declaration a name denotes. Strings borrow the parse or the item tree.
Resolved :: struct {
    kind:     Resolved_Kind,
    name:     string,
    file:     File_Id, // Local: the file of the local
    local:    Local,   // Local
    symbol:   Symbol,  // Item; Local: local_symbol of the local
    universe: bool,    // Item: the item is in a universe package
    builtin:  bool,    // Item: the item is in a universe package that gives every item (base:builtin)
    dir:      string,  // Import: the package directory; "" when not resolved
    basic:    Basic_Kind,
}

// How an operand denotes something.
Operand_Mode :: enum u8 {
    Invalid,
    No_Value, // a call of a procedure with no result
    Value,
    Const,
    Type,
    Package, // an import alias
    Builtin, // a procedure of base:builtin
}

Operand :: struct {
    mode:   Operand_Mode,
    type:   Type_Id,
    value:  Const_Value, // Const: nil when the value is not known
    dir:    string,      // Package: the package directory
    symbol: Symbol,      // Builtin: the declaration; `item` is LOCAL_ITEM when there is none
}

// The `item` of the Symbol of a local; `child` is then the name offset of the local.
LOCAL_ITEM :: i32(-1)

// The symbol of the local declared at `name_offset` of `file`.
local_symbol :: proc(file: File_Id, name_offset: int) -> Symbol {
    return Symbol{file = file, item = LOCAL_ITEM, child = i32(name_offset)}
}

// The analysis of one snapshot: the types made and the declarations checked so far. It holds
// pointers into itself, so it must not be copied after checker_init. It must end before the snapshot.
Checker :: struct {
    snap:       ^Snapshot,
    table:      Type_Table,
    arena:      virtual.Arena,
    alloc:      mem.Allocator, // of `arena`; the table, the maps and the strings
    universe:   []Universe_Package, // borrowed
    home_key:   string, // path_key of the package whose types print with no qualifier; "" when none
    decls:      map[Symbol]Decl_Info,
    pending:    map[Symbol]struct{}, // the declarations whose type is in progress
    consts:     map[Symbol]Const_Info,
    evaluating: map[Symbol]struct{}, // the constants whose value is in progress
    files:      map[File_Id]^File_Cache,
    packages:   map[string]^Package_View, // by path_key of the directory; nil when it cannot be read
    scopes:     map[Scope_Key]^Scope_Map,
    scope_list: [dynamic]^Scope_Map, // owned
    path:       [dynamic]odinsyntax.Syntax_Node, // scratch of node_path
    enum_env:   []Enum_Member, // the members before the enum value being evaluated
    err:        mem.Allocator_Error,
}

@(private)
Decl_Info :: struct {
    type:    Type_Id,
    is_type: bool, // the declaration names a type; `type` is that type
}

@(private)
Const_Info :: struct {
    value: Const_Value,
    ok:    bool,
}

@(private)
Scope_Key :: struct {
    file:  File_Id,
    start: u32,
}

@(private)
File_Cache :: struct {
    data:        ^File_Data, // nil when the file cannot be read
    parse:       ^odinsyntax.Parse,
    imports:     []File_Import,
    dir:         string,
    dir_key:     string,
    in_build:    bool,
    has_parse:   bool,
    has_imports: bool,
}

@(private = "file")
CHECKER_ARENA_BLOCK :: 64 * mem.Kilobyte

// Starts a checker on `snap`. Types print unqualified in the package of `home`; the snapshot's
// buffer when NO_FILE. `universe` is borrowed. checker_destroy is safe after a failure.
checker_init :: proc(c: ^Checker, snap: ^Snapshot, universe: []Universe_Package = nil, home := NO_FILE) -> mem.Allocator_Error {
    c^ = {}
    virtual.arena_init_growing(&c.arena, CHECKER_ARENA_BLOCK) or_return
    c.snap = snap
    c.alloc = virtual.arena_allocator(&c.arena)
    c.universe = universe
    if err := type_table_init(&c.table, c.alloc); err != nil {
        virtual.arena_destroy(&c.arena)
        c^ = {}
        return err
    }
    c.decls = make(map[Symbol]Decl_Info, c.alloc)
    c.pending = make(map[Symbol]struct{}, c.alloc)
    c.consts = make(map[Symbol]Const_Info, c.alloc)
    c.evaluating = make(map[Symbol]struct{}, c.alloc)
    c.files = make(map[File_Id]^File_Cache, c.alloc)
    c.packages = make(map[string]^Package_View, c.alloc)
    c.scopes = make(map[Scope_Key]^Scope_Map, c.alloc)
    c.scope_list = make([dynamic]^Scope_Map, c.alloc)
    c.path = make([dynamic]odinsyntax.Syntax_Node, c.alloc)
    home := home
    if home == NO_FILE {
        home = snapshot_live_file(snap)
    }
    if home != NO_FILE {
        if fc := file_cache(c, home); fc != nil {
            c.home_key = fc.dir_key
        }
    }
    return c.err
}

checker_destroy :: proc(c: ^Checker) {
    for m in c.scope_list {
        scope_map_destroy(m, c.alloc)
    }
    virtual.arena_destroy(&c.arena)
    c^ = {}
}

@(private = "file")
note_alloc :: proc(c: ^Checker, err: mem.Allocator_Error) -> bool {
    if err != nil {
        if c.err == nil {
            c.err = err
        }
        return false
    }
    return true
}

// The declarations, directory and build state of a file, read once per checker. Nil when memory runs out.
@(private)
file_cache :: proc(c: ^Checker, id: File_Id) -> ^File_Cache {
    if fc, ok := c.files[id]; ok {
        return fc
    }
    fc, err := new(File_Cache, c.alloc)
    if !note_alloc(c, err) {
        return nil
    }
    fc.data = db_file(c.snap, id)
    if id == ANON_FILE {
        fc.dir = c.snap.live.dir
    } else {
        fc.dir = filepath.dir(db_file_path(c.snap, id))
    }
    fc.dir_key = path_key(fc.dir, c.alloc)
    fc.in_build = id != ANON_FILE && db_in_build(c.snap, id)
    _, value, _, merr := map_entry(&c.files, id)
    if !note_alloc(c, merr) {
        return nil
    }
    value^ = fc
    return fc
}

// The parse of a file, pinned by the snapshot. Nil when the file cannot be read.
checker_parse :: proc(c: ^Checker, id: File_Id) -> ^odinsyntax.Parse {
    fc := file_cache(c, id)
    if fc == nil {
        return nil
    }
    if !fc.has_parse {
        fc.has_parse = true
        fc.parse = db_parse(c.snap, id)
    }
    return fc.parse
}

@(private = "file")
checker_imports :: proc(c: ^Checker, id: File_Id) -> []File_Import {
    fc := file_cache(c, id)
    if fc == nil {
        return nil
    }
    if !fc.has_imports {
        fc.has_imports = true
        fc.imports = db_imports(c.snap, id)
    }
    return fc.imports
}

// The package at `dir`; nil when it cannot be read.
@(private = "file")
checker_package :: proc(c: ^Checker, dir: string) -> ^Package_View {
    if dir == "" {
        return nil
    }
    key := path_key(dir, c.alloc)
    if view, ok := c.packages[key]; ok {
        return view
    }
    view: ^Package_View
    if pkg := db_package_id(c.snap, dir); pkg != NO_PACKAGE {
        view = db_package(c.snap, pkg)
    }
    _, value, _, err := map_entry(&c.packages, key)
    if note_alloc(c, err) {
        value^ = view
    }
    return view
}

// The item a symbol names; for a child, the field or member. Nil for a local or a symbol out of range.
checker_item :: proc(c: ^Checker, sym: Symbol) -> ^Item {
    if sym.item < 0 {
        return nil
    }
    fc := file_cache(c, sym.file)
    if fc == nil || fc.data == nil || int(sym.item) >= len(fc.data.tree.items) {
        return nil
    }
    item := &fc.data.tree.items[sym.item]
    if sym.child < 0 {
        return item
    }
    if int(sym.child) >= len(item.children) {
        return nil
    }
    return &item.children[sym.child]
}

// The nodes from the root down to the innermost node that holds byte `offset`. The slice is reused
// by the next call; parent pointers are not set.
@(private = "file")
node_path :: proc(c: ^Checker, file: File_Id, offset: int) -> []odinsyntax.Syntax_Node {
    clear(&c.path)
    parsed := checker_parse(c, file)
    if parsed == nil || parsed.tree == nil || parsed.tree.root == nil || offset < 0 {
        return nil
    }
    cur := odinsyntax.node_root(parsed.tree)
    off := u32(offset)
    for {
        if _, err := append(&c.path, cur); !note_alloc(c, err) {
            return nil
        }
        pos := cur.offset
        next: ^odinsyntax.Green_Node
        next_pos: u32
        for child in odinsyntax.green_children(cur.green) {
            child_len := odinsyntax.element_len(child)
            if off >= pos && off < pos + child_len {
                if g, is_node := odinsyntax.element_node(child); is_node {
                    next, next_pos = g, pos
                }
                break
            }
            pos += child_len
        }
        if next == nil {
            return c.path[:]
        }
        cur = odinsyntax.Syntax_Node{next, next_pos, nil, cur.tree}
    }
}

// The outermost expression or type that starts at `offset` of `file`. Its parent is not set.
node_at :: proc(c: ^Checker, file: File_Id, offset: int) -> (odinsyntax.Syntax_Node, bool) {
    for n in node_path(c, file, offset) {
        if int(n.offset) == offset && n.green.kind in odinsyntax.KINDS_EXPR {
            return n, true
        }
    }
    return {}, false
}

// The scope map of the file-scope declaration that holds `offset`; nil when there is none.
@(private = "file")
scope_map_at :: proc(c: ^Checker, file: File_Id, offset: int) -> ^Scope_Map {
    parsed := checker_parse(c, file)
    if parsed == nil || parsed.tree == nil || parsed.tree.root == nil {
        return nil
    }
    root := odinsyntax.node_root(parsed.tree)
    start, end := -1, -1
    pos := root.offset
    for child in odinsyntax.green_children(root.green) {
        child_len := odinsyntax.element_len(child)
        if u32(offset) >= pos && u32(offset) < pos + child_len {
            if _, is_node := odinsyntax.element_node(child); is_node {
                start, end = int(pos), int(pos + child_len)
            }
            break
        }
        pos += child_len
    }
    if start < 0 {
        return nil
    }
    key := Scope_Key{file, u32(start)}
    if m, ok := c.scopes[key]; ok {
        return m
    }
    m, err := scope_map_range(parsed^, start, end - 1, c.alloc)
    if !note_alloc(c, err) {
        return nil
    }
    if _, aerr := append(&c.scope_list, m); !note_alloc(c, aerr) {
        scope_map_destroy(m, c.alloc)
        return nil
    }
    _, value, _, merr := map_entry(&c.scopes, key)
    if note_alloc(c, merr) {
        value^ = m
    }
    return m
}

// The local declared at `name_offset` of `file`.
local_at :: proc(c: ^Checker, file: File_Id, name_offset: int) -> (Local, bool) {
    m := scope_map_at(c, file, name_offset)
    if m == nil {
        return {}, false
    }
    for l in m.locals {
        if l.name_offset == name_offset {
            return l, true
        }
    }
    return {}, false
}

// The innermost local named `name` in reach at `offset`, for an offset that is not on an identifier.
@(private = "file")
visible_local :: proc(m: ^Scope_Map, name: string, offset: int) -> (Local, bool) {
    inner := -1
    for s, i in m.scopes {
        if s.start <= offset && offset < s.end && (inner < 0 || s.start >= m.scopes[inner].start) {
            inner = i
        }
    }
    if inner < 0 {
        return {}, false
    }
    depth := m.scopes[inner].proc_depth
    for s := inner; s >= 0; s = m.scopes[s].parent {
        found := -1
        for l, i in m.locals {
            if l.scope != s || l.name != name || l.kind == .Label {
                continue
            }
            if !hoisted(l.kind) && l.name_offset > offset {
                continue
            }
            if !hoisted(l.kind) && m.scopes[s].proc_depth < depth {
                continue
            }
            found = i
        }
        if found >= 0 {
            return m.locals[found], true
        }
    }
    return {}, false
}

@(private = "file")
hoisted :: proc(kind: Decl_Kind) -> bool {
    #partial switch kind {
    case .Const, .Type, .Proc, .Poly:
        return true
    }
    return false
}

// What `name` denotes at `offset` of `file`: a local, then a declaration of the file's package, then
// an import of the file, then the universe. An offset on an identifier uses what the scope walk found there.
lookup_name :: proc(c: ^Checker, file: File_Id, name: string, offset: int) -> Resolved {
    if name == "" || name == "_" {
        return {}
    }
    if m := scope_map_at(c, file, offset); m != nil {
        on_ident := false
        if ref, ok := ref_at(m, offset); ok && ref.start <= offset && offset < ref.end && ref.name == name {
            on_ident = true
            if ref.kind == .Local {
                for l in m.locals {
                    if l.name_offset == ref.decl {
                        return Resolved{kind = .Local, name = name, file = file, local = l, symbol = local_symbol(file, l.name_offset)}
                    }
                }
            }
        }
        if !on_ident {
            if l, ok := visible_local(m, name, offset); ok {
                return Resolved{kind = .Local, name = name, file = file, local = l, symbol = local_symbol(file, l.name_offset)}
            }
        }
    }
    if sym, ok := package_lookup(c, file, name); ok {
        return Resolved{kind = .Item, name = name, symbol = sym}
    }
    if imp, ok := lookup_import(checker_imports(c, file), name); ok {
        return Resolved{kind = .Import, name = name, dir = imp.dir}
    }
    return universe_lookup(c, name)
}

// The declaration of `name` in the package of `file`. A file that is not in the build sees its own declarations first.
@(private = "file")
package_lookup :: proc(c: ^Checker, file: File_Id, name: string) -> (Symbol, bool) {
    fc := file_cache(c, file)
    if fc == nil {
        return {}, false
    }
    if !fc.in_build {
        if sym, ok := own_lookup(c, file, name); ok {
            return sym, true
        }
        if file == ANON_FILE {
            return {}, false
        }
    }
    if sym, ok := member_lookup(c, fc.dir, name, file, false); ok {
        return sym, true
    }
    return own_lookup(c, file, name)
}

@(private = "file")
own_lookup :: proc(c: ^Checker, file: File_Id, name: string) -> (Symbol, bool) {
    fc := file_cache(c, file)
    if fc == nil || fc.data == nil {
        return {}, false
    }
    for item, i in fc.data.tree.items {
        if item.name == name && item.kind != .Import && item.kind != .Foreign_Import {
            return Symbol{file, i32(i), -1}, true
        }
    }
    return {}, false
}

// The declaration of `name` in the package at `dir`. From another package only public ones count.
// An active declaration, then one of `from`, is preferred. With `out_of_build` a file that is not in
// the build is the last resort: `posix.pid_t` seen on Windows.
@(private)
member_lookup :: proc(c: ^Checker, dir, name: string, from: File_Id, external: bool, out_of_build := false) -> (Symbol, bool) {
    view := checker_package(c, dir)
    if view == nil || view.scope == nil {
        return {}, false
    }
    best, best_rank := Symbol{}, -1
    for ref in package_scope_lookup(view.scope, name) {
        item := package_item(view.sema_files, ref)
        id := view.files[ref.file]
        if external && item.visibility != .Public {
            continue
        }
        if !external && item.visibility == .File && id != from {
            continue
        }
        rank := 0
        if package_ref_active(view.scope, ref) {
            rank += 2
        }
        if id == from {
            rank += 1
        }
        if rank > best_rank {
            best, best_rank = Symbol{id, i32(ref.item), -1}, rank
        }
    }
    if best_rank >= 0 || !out_of_build {
        return best, best_rank >= 0
    }
    for data, fi in view.datas {
        if data == nil {
            continue
        }
        for item, ii in data.tree.items {
            if item.name != name || item.kind == .Import || item.kind == .Foreign_Import {
                continue
            }
            if (external && item.visibility != .Public) || (!external && item.visibility == .File && view.files[fi] != from) {
                continue
            }
            return Symbol{view.files[fi], i32(ii), -1}, true
        }
    }
    return {}, false
}

// A name the compiler declares: a basic type, `byte`, `true`, `false`, `nil` or an `ODIN_` constant.
@(private = "file")
universe_name :: proc(c: ^Checker, name: string) -> Resolved {
    if kind, ok := basic_from_name(name); ok {
        return Resolved{kind = .Basic, name = name, basic = kind}
    }
    switch name {
    case "byte":
        return Resolved{kind = .Basic, name = name, basic = .U8}
    case "true", "false", "nil":
        return Resolved{kind = .Builtin, name = name}
    }
    if strings.has_prefix(name, "ODIN_") {
        return Resolved{kind = .Builtin, name = name}
    }
    return {}
}

@(private = "file")
universe_lookup :: proc(c: ^Checker, name: string) -> Resolved {
    if r := universe_name(c, name); r.kind != .None {
        return r
    }
    for u in c.universe {
        sym, ok := member_lookup(c, u.dir, name, NO_FILE, true)
        if !ok {
            continue
        }
        if !u.all && !has_attribute(checker_item(c, sym), "builtin") {
            continue
        }
        return Resolved{kind = .Item, name = name, symbol = sym, universe = true, builtin = u.all}
    }
    return {}
}

@(private = "file")
has_attribute :: proc(item: ^Item, name: string) -> bool {
    if item == nil {
        return false
    }
    for a in item.attributes {
        if a.name == name {
            return true
        }
    }
    return false
}

// A public type of a universe package that gives only its `builtin` items: base:runtime's `Context`.
@(private = "file")
runtime_type :: proc(c: ^Checker, name: string) -> Type_Id {
    for u in c.universe {
        if u.all {
            continue
        }
        if sym, ok := member_lookup(c, u.dir, name, NO_FILE, true); ok && decl_is_type(c, sym) {
            return decl_type(c, sym)
        }
    }
    return INVALID_TYPE
}

// The package qualifier a named type of `file` prints with: "" in the home package.
@(private = "file")
qualifier :: proc(c: ^Checker, file: File_Id) -> string {
    fc := file_cache(c, file)
    if c.home_key == "" || fc == nil || fc.data == nil || fc.dir_key == c.home_key {
        return ""
    }
    return fc.data.tree.package_name
}

// The type of a declaration: the type it names for a type declaration, else the type of its value.
// A declaration whose type is still in progress gives INVALID_TYPE.
decl_type :: proc(c: ^Checker, sym: Symbol) -> Type_Id {
    return decl_info(c, sym).type
}

// True when the declaration names a type.
decl_is_type :: proc(c: ^Checker, sym: Symbol) -> bool {
    return decl_info(c, sym).is_type
}

@(private)
decl_info :: proc(c: ^Checker, sym: Symbol) -> Decl_Info {
    if info, ok := c.decls[sym]; ok {
        return info
    }
    if sym in c.pending {
        return {}
    }
    _, _, _, perr := map_entry(&c.pending, sym)
    if !note_alloc(c, perr) {
        return {}
    }
    info := decl_info_uncached(c, sym)
    delete_key(&c.pending, sym)
    _, value, _, err := map_entry(&c.decls, sym)
    if note_alloc(c, err) {
        value^ = info
    }
    return info
}

@(private = "file")
decl_info_uncached :: proc(c: ^Checker, sym: Symbol) -> Decl_Info {
    if sym.item == LOCAL_ITEM {
        l, ok := local_at(c, sym.file, int(sym.child))
        if !ok {
            return {}
        }
        return local_info(c, sym, l)
    }
    item := checker_item(c, sym)
    if item == nil {
        return {}
    }
    if sym.child >= 0 {
        return {type = child_type(c, sym, item)}
    }
    #partial switch item.kind {
    case .Import, .Foreign_Import:
        return {}
    }
    return binding_info(c, sym, item.name, item.kind != .Var, item.type_offset, item.value_offset, item.value_index)
}

@(private = "file")
local_info :: proc(c: ^Checker, sym: Symbol, l: Local) -> Decl_Info {
    #partial switch l.kind {
    case .Poly:
        return poly_info(c, sym)
    case .Type, .Const, .Proc:
        return binding_info(c, sym, l.name, true, l.type_offset, l.value_offset, l.value_index)
    case .Var, .Param, .Result:
        if l.source != .Value {
            return {}
        }
        return binding_info(c, sym, l.name, false, l.type_offset, l.value_offset, l.value_index)
    }
    return {}
}

// The type of a field or an enum member, from the type of its parent.
@(private = "file")
child_type :: proc(c: ^Checker, sym: Symbol, child: ^Item) -> Type_Id {
    parent := decl_type(c, Symbol{sym.file, sym.item, -1})
    if child.kind == .Enum_Member {
        return parent
    }
    #partial switch v in type_get(&c.table, type_base(&c.table, parent)) {
    case Struct_Type:
        for f in v.fields {
            if f.name_offset == child.name_offset {
                return f.type
            }
        }
    case Bit_Field_Type:
        for f in v.fields {
            if f.name_offset == child.name_offset {
                return f.type
            }
        }
    }
    if n, ok := node_at(c, sym.file, child.type_offset); ok {
        return type_expr(c, sym.file, n)
    }
    return INVALID_TYPE
}

// The type a declaration gives one name, from its type expression or its value.
@(private = "file")
binding_info :: proc(c: ^Checker, sym: Symbol, name: string, constant: bool, type_offset, value_offset, value_index: int) -> Decl_Info {
    if type_offset >= 0 {
        n, ok := node_at(c, sym.file, type_offset)
        return {type = ok ? type_expr(c, sym.file, n) : INVALID_TYPE}
    }
    value, ok := node_at(c, sym.file, value_offset)
    if !ok {
        return {}
    }
    if constant && value_index < 0 && is_type_literal(value) {
        return {type = named_decl(c, sym, name, value), is_type = true}
    }
    op := expr_type(c, sym.file, value)
    if op.mode == .Type {
        if constant {
            return {type = op.type, is_type = true}
        }
        return {type = type_basic(.Typeid)}
    }
    t := op.type
    if value_index >= 0 {
        tuple, is_tuple := type_get(&c.table, t).(Tuple_Type)
        t = is_tuple && value_index < len(tuple.types) ? tuple.types[value_index] : INVALID_TYPE
    }
    if !constant {
        t = type_default(&c.table, t)
    }
    return {type = t}
}

// True when a constant declaration with this value declares a named type rather than an alias.
@(private = "file")
is_type_literal :: proc(n: odinsyntax.Syntax_Node) -> bool {
    n := n
    #partial switch n.green.kind {
    case .Struct_Type, .Union_Type, .Enum_Type, .Bit_Set_Type, .Bit_Field_Type, .Distinct_Type, .Proc_Type,
         .Map_Type, .Matrix_Type, .Array_Type, .Dynamic_Array_Type, .Pointer_Type, .Multi_Pointer_Type, .Helper_Type:
        return true
    case .Tag_Expr:
        t, _ := odinsyntax.as_tag_expr(n)
        inner, ok := odinsyntax.tag_expr_expr(&t)
        return ok && is_type_literal(inner)
    }
    return false
}

// Makes the named type of a type declaration. The named type is known before its underlying type
// is read, so the declaration can refer to itself through a pointer.
@(private = "file")
named_decl :: proc(c: ^Checker, sym: Symbol, name: string, value: odinsyntax.Syntax_Node) -> Type_Id {
    value := value
    qual := sym.item == LOCAL_ITEM ? "" : qualifier(c, sym.file)
    named := type_named(&c.table, sym, name, qual)
    if named == INVALID_TYPE {
        return INVALID_TYPE
    }
    _, entry, _, err := map_entry(&c.decls, sym)
    if !note_alloc(c, err) {
        return INVALID_TYPE
    }
    entry^ = Decl_Info{named, true}
    underlying := INVALID_TYPE
    if d, is_distinct := odinsyntax.as_distinct_type(value); is_distinct {
        if inner, ok := odinsyntax.distinct_type_type(&d); ok {
            underlying = type_distinct(&c.table, sym, type_expr(c, sym.file, inner))
        }
    } else {
        underlying = type_expr(c, sym.file, value)
    }
    type_set_underlying(&c.table, named, underlying)
    return named
}

// The type of `$T`, or the value type of `$N: int`.
@(private = "file")
poly_info :: proc(c: ^Checker, sym: Symbol) -> Decl_Info {
    offset := int(sym.child)
    path := node_path(c, sym.file, offset)
    poly: odinsyntax.Syntax_Node
    has_poly := false
    field: odinsyntax.Syntax_Node
    has_field, in_names := false, false
    for n in path {
        #partial switch n.green.kind {
        case .Field:
            field, has_field, in_names = n, true, false
        case .Name_List:
            in_names = has_field
        case .Poly_Type:
            if int(n.offset) + 1 == offset {
                poly, has_poly = n, true
            }
        }
    }
    if !has_poly {
        return {}
    }
    if has_field && in_names {
        f, _ := odinsyntax.as_field(field)
        if type, ok := odinsyntax.field_type(&f); ok && type.green.kind != .Typeid_Type {
            return {type = type_expr(c, sym.file, type)}
        }
    }
    pt, _ := odinsyntax.as_poly_type(poly)
    spec := INVALID_TYPE
    if s, ok := odinsyntax.poly_type_specialization(&pt); ok {
        spec = type_expr(c, sym.file, s)
    }
    name := ""
    if ident, ok := odinsyntax.poly_type_name(&pt); ok {
        name = odinsyntax.node_text(odinsyntax.Syntax_Node(ident))
    }
    return {type = type_poly_param(&c.table, name, spec), is_type = true}
}

// The type a type expression denotes; INVALID_TYPE when it denotes none.
type_expr :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    n := n
    t := &c.table
    #partial switch n.green.kind {
    case .Pointer_Type:
        p, _ := odinsyntax.as_pointer_type(n)
        return type_pointer(t, elem_type(c, file, odinsyntax.pointer_type_elem(&p)))
    case .Multi_Pointer_Type:
        p, _ := odinsyntax.as_multi_pointer_type(n)
        return type_multi_pointer(t, elem_type(c, file, odinsyntax.multi_pointer_type_elem(&p)))
    case .Array_Type:
        return array_type(c, file, n)
    case .Dynamic_Array_Type:
        d, _ := odinsyntax.as_dynamic_array_type(n)
        return type_dynamic_array(t, elem_type(c, file, odinsyntax.dynamic_array_type_elem(&d)))
    case .Map_Type:
        m, _ := odinsyntax.as_map_type(n)
        key := elem_type(c, file, odinsyntax.map_type_key(&m))
        return type_map(t, key, elem_type(c, file, odinsyntax.map_type_value(&m)))
    case .Matrix_Type:
        return matrix_type(c, file, n, false)
    case .Bit_Set_Type:
        return bit_set_type(c, file, n)
    case .Struct_Type:
        return struct_type(c, file, n)
    case .Union_Type:
        return union_type(c, file, n)
    case .Enum_Type:
        return enum_type(c, file, n)
    case .Bit_Field_Type:
        return bit_field_type(c, file, n)
    case .Proc_Type:
        return proc_type(c, file, n)
    case .Distinct_Type:
        d, _ := odinsyntax.as_distinct_type(n)
        base := elem_type(c, file, odinsyntax.distinct_type_type(&d))
        return type_distinct(t, Symbol{file, LOCAL_ITEM, i32(n.offset)}, base)
    case .Typeid_Type:
        return type_basic(.Typeid)
    case .Helper_Type:
        h, _ := odinsyntax.as_helper_type(n)
        return elem_type(c, file, odinsyntax.helper_type_type(&h))
    case .Ellipsis_Type:
        e, _ := odinsyntax.as_ellipsis_type(n)
        return type_slice(t, elem_type(c, file, odinsyntax.ellipsis_type_elem(&e)))
    case .Poly_Type:
        p, _ := odinsyntax.as_poly_type(n)
        ident, ok := odinsyntax.poly_type_name(&p)
        if !ok {
            return INVALID_TYPE
        }
        return decl_type(c, local_symbol(file, int(ident.offset)))
    case .Paren_Expr:
        p, _ := odinsyntax.as_paren_expr(n)
        return elem_type(c, file, odinsyntax.paren_expr_expr(&p))
    case .Tag_Expr:
        return tag_type(c, file, n)
    case .Binary_Expr:
        // `typeid/T`: a specialized typeid.
        b, _ := odinsyntax.as_binary_expr(n)
        if lhs, ok := odinsyntax.binary_expr_lhs(&b); ok && lhs.green.kind == .Typeid_Type {
            return type_basic(.Typeid)
        }
        return INVALID_TYPE
    }
    op := expr_type(c, file, n)
    return op.mode == .Type ? op.type : INVALID_TYPE
}

// The type of an optional child type expression.
@(private = "file")
elem_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, ok: bool) -> Type_Id {
    return ok ? type_expr(c, file, n) : INVALID_TYPE
}

// The value of a constant length; -1 when it is not known.
@(private = "file")
length_of :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, ok: bool) -> i64 {
    if !ok {
        return -1
    }
    v, vok := const_eval(c, file, n)
    if !vok {
        return -1
    }
    #partial switch x in v {
    case i64:
        return x >= 0 ? x : -1
    case rune:
        return i64(x)
    }
    return -1
}

// `[]T`, `[?]T`, `[N]T` or `[Enum]T`.
@(private = "file")
array_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    a, _ := odinsyntax.as_array_type(n)
    elem := elem_type(c, file, odinsyntax.array_type_elem(&a))
    len_node, has_len := odinsyntax.array_type_len(&a)
    if !has_len {
        if _, unknown := odinsyntax.find_child_token((^odinsyntax.Syntax_Node)(&a), {tokens = {.Question}}); unknown {
            return type_array(&c.table, -1, elem)
        }
        return type_slice(&c.table, elem)
    }
    if op := expr_type(c, file, len_node); op.mode == .Type {
        return type_enumerated_array(&c.table, op.type, elem)
    }
    return type_array(&c.table, length_of(c, file, len_node, true), elem)
}

@(private = "file")
matrix_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, row_major: bool) -> Type_Id {
    m, _ := odinsyntax.as_matrix_type(n)
    rows := length_of(c, file, odinsyntax.matrix_type_rows(&m))
    cols := length_of(c, file, odinsyntax.matrix_type_columns(&m))
    return type_matrix(&c.table, rows, cols, elem_type(c, file, odinsyntax.matrix_type_elem(&m)), row_major)
}

// A type under a directive: `#soa`, `#simd`, `#row_major`; another directive keeps the type.
@(private = "file")
tag_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    tag, _ := odinsyntax.as_tag_expr(n)
    inner, ok := odinsyntax.tag_expr_expr(&tag)
    if !ok {
        return INVALID_TYPE
    }
    name := ""
    if d, dok := odinsyntax.tag_expr_directive(&tag); dok {
        if dir, is_dir := odinsyntax.as_directive(d); is_dir {
            if tok, tok_ok := odinsyntax.directive_name(&dir); tok_ok {
                name = odinsyntax.syntax_token_text(tok)
            }
        }
    }
    switch name {
    case "soa":
        #partial switch inner.green.kind {
        case .Array_Type:
            a, _ := odinsyntax.as_array_type(inner)
            elem := elem_type(c, file, odinsyntax.array_type_elem(&a))
            if len_node, has_len := odinsyntax.array_type_len(&a); has_len {
                return type_soa(&c.table, .Array, elem, length_of(c, file, len_node, true))
            }
            if _, unknown := odinsyntax.find_child_token((^odinsyntax.Syntax_Node)(&a), {tokens = {.Question}}); unknown {
                return type_soa(&c.table, .Array, elem, -1)
            }
            return type_soa(&c.table, .Slice, elem)
        case .Dynamic_Array_Type:
            d, _ := odinsyntax.as_dynamic_array_type(inner)
            return type_soa(&c.table, .Dynamic, elem_type(c, file, odinsyntax.dynamic_array_type_elem(&d)))
        }
    case "simd":
        if a, is_array := odinsyntax.as_array_type(inner); is_array {
            elem := elem_type(c, file, odinsyntax.array_type_elem(&a))
            return type_simd(&c.table, length_of(c, file, odinsyntax.array_type_len(&a)), elem)
        }
    case "row_major", "column_major":
        if inner.green.kind == .Matrix_Type {
            return matrix_type(c, file, inner, name == "row_major")
        }
    }
    return type_expr(c, file, inner)
}

@(private = "file")
bit_set_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    b, _ := odinsyntax.as_bit_set_type(n)
    backing := elem_type(c, file, odinsyntax.bit_set_type_backing(&b))
    elem, ok := odinsyntax.bit_set_type_elem(&b)
    if !ok {
        return INVALID_TYPE
    }
    if r, is_binary := odinsyntax.as_binary_expr(elem); is_binary {
        op, _ := odinsyntax.binary_expr_op(&r)
        if op.green.kind == .Range_Full || op.green.kind == .Range_Half {
            lo_v, lo_ok := child_const(c, file, odinsyntax.binary_expr_lhs(&r))
            hi_v, hi_ok := child_const(c, file, odinsyntax.binary_expr_rhs(&r))
            lo, lo_int := const_to_i64(lo_v)
            hi, hi_int := const_to_i64(hi_v)
            if !lo_ok || !hi_ok || !lo_int || !hi_int {
                return INVALID_TYPE
            }
            if op.green.kind == .Range_Half {
                hi -= 1
            }
            _, lo_rune := lo_v.(rune)
            _, hi_rune := hi_v.(rune)
            bound := lo_rune || hi_rune ? type_basic(.Rune) : type_untyped(.Int)
            return type_bit_set_range(&c.table, bound, lo, hi, backing)
        }
    }
    return type_bit_set(&c.table, type_expr(c, file, elem), backing)
}

@(private = "file")
child_const :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, ok: bool) -> (Const_Value, bool) {
    if !ok {
        return nil, false
    }
    return const_eval(c, file, n)
}

// The parameters of a Param_List or Result_List, `$T` names included.
@(private = "file")
read_params :: proc(c: ^Checker, file: File_Id, list: odinsyntax.Syntax_Node) -> []Proc_Param {
    list := list
    out := make([dynamic]Proc_Param, c.alloc)
    it := odinsyntax.child_iter(&list, {kinds = {.Field}})
    for field in odinsyntax.child_iter_next(&it) {
        field := field
        f, _ := odinsyntax.as_field(field)
        p := Proc_Param{name_offset = -1}
        dirs := odinsyntax.child_iter(&field, {kinds = {.Directive}})
        for d in odinsyntax.child_iter_next(&dirs) {
            dir, _ := odinsyntax.as_directive(d)
            tok, ok := odinsyntax.directive_name(&dir)
            if !ok {
                continue
            }
            switch odinsyntax.syntax_token_text(tok) {
            case "any_int":  p.flags += {.Any_Int}
            case "c_vararg": p.flags += {.C_Vararg}
            case "by_ptr":   p.flags += {.By_Ptr}
            case "no_alias": p.flags += {.No_Alias}
            case "const":    p.flags += {.Const}
            }
        }
        if _, is_using := odinsyntax.field_using(&f); is_using {
            p.flags += {.Using}
        }
        if default, ok := odinsyntax.field_default(&f); ok {
            p.has_default = true
            p.default = strings.trim_space(odinsyntax.node_text(default))
            if _, has_type := odinsyntax.field_type(&f); !has_type {
                p.inferred = true
                p.type = type_default(&c.table, expr_type(c, file, default).type)
            }
        }
        if type, ok := odinsyntax.field_type(&f); ok {
            if e, is_ellipsis := odinsyntax.as_ellipsis_type(type); is_ellipsis {
                p.flags += {.Variadic}
                p.type = elem_type(c, file, odinsyntax.ellipsis_type_elem(&e))
            } else {
                p.type = type_expr(c, file, type)
            }
        }
        names, has_names := odinsyntax.field_names(&f)
        if !has_names {
            if _, err := append(&out, p); !note_alloc(c, err) {
                return nil
            }
            continue
        }
        nit := odinsyntax.name_list_names(&names)
        for name in odinsyntax.child_iter_next(&nit) {
            name := name
            q := p
            #partial switch name.green.kind {
            case .Ident:
                q.name = odinsyntax.node_text(name)
                q.name_offset = int(name.offset)
            case .Poly_Type:
                pt, _ := odinsyntax.as_poly_type(name)
                if ident, ok := odinsyntax.poly_type_name(&pt); ok {
                    q.name = strings.concatenate({"$", odinsyntax.node_text(odinsyntax.Syntax_Node(ident))}, c.alloc)
                    q.name_offset = int(ident.offset)
                }
            case:
                q.name = odinsyntax.node_text(name)
            }
            if _, err := append(&out, q); !note_alloc(c, err) {
                return nil
            }
        }
    }
    return out[:]
}

@(private = "file")
proc_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    pt, _ := odinsyntax.as_proc_type(n)
    p: Proc_Type
    if cc, ok := odinsyntax.proc_type_calling_convention(&pt); ok {
        p.convention = unquote(odinsyntax.syntax_token_text(cc))
    }
    if params, ok := odinsyntax.proc_type_params(&pt); ok {
        p.params = read_params(c, file, odinsyntax.Syntax_Node(params))
    }
    if results, ok := odinsyntax.proc_type_results(&pt); ok {
        p.results = read_params(c, file, odinsyntax.Syntax_Node(results))
        _, p.diverging = odinsyntax.result_list_diverging(&results)
    }
    return type_proc(&c.table, p)
}

// The directives of a struct or union: `#packed`, `#align(N)`, ... `align` is 0 when none.
@(private = "file")
record_directives :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (names: [dynamic]string, align: i64) {
    n := n
    names = make([dynamic]string, c.alloc)
    after_align := false
    it := odinsyntax.child_iter(&n, {kinds = {.Directive, .Paren_Expr}})
    for child in odinsyntax.child_iter_next(&it) {
        child := child
        if child.green.kind == .Paren_Expr {
            if after_align {
                p, _ := odinsyntax.as_paren_expr(child)
                align = max(length_of(c, file, odinsyntax.paren_expr_expr(&p)), 0)
            }
            after_align = false
            continue
        }
        d, _ := odinsyntax.as_directive(child)
        tok, ok := odinsyntax.directive_name(&d)
        if !ok {
            continue
        }
        name := odinsyntax.syntax_token_text(tok)
        after_align = name == "align"
        if _, err := append(&names, name); !note_alloc(c, err) {
            return
        }
    }
    return
}

@(private = "file")
struct_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    s, _ := odinsyntax.as_struct_type(n)
    st: Struct_Type
    if params, ok := odinsyntax.struct_type_params(&s); ok {
        st.params = read_params(c, file, odinsyntax.Syntax_Node(params))
    }
    names, align := record_directives(c, file, n)
    st.align = align
    for name in names {
        switch name {
        case "packed":    st.flags += {.Packed}
        case "raw_union": st.flags += {.Raw_Union}
        case "no_copy":   st.flags += {.No_Copy}
        }
    }
    fields := make([dynamic]Struct_Field, c.alloc)
    if list, ok := odinsyntax.struct_type_fields(&s); ok {
        it := odinsyntax.field_list_fields(&list)
        for field in odinsyntax.child_iter_next(&it) {
            field := field
            f, _ := odinsyntax.as_field(field)
            names_list, has_names := odinsyntax.field_names(&f)
            if !has_names {
                continue
            }
            sf := Struct_Field{name_offset = -1}
            if type, tok := odinsyntax.field_type(&f); tok {
                sf.type = type_expr(c, file, type)
            }
            if tag, tok := odinsyntax.field_tag(&f); tok {
                sf.tag = odinsyntax.syntax_token_text(tag)
            }
            _, sf.is_using = odinsyntax.field_using(&f)
            nit := odinsyntax.name_list_names(&names_list)
            for name in odinsyntax.child_iter_next(&nit) {
                entry := sf
                entry.name = odinsyntax.node_text(name)
                entry.name_offset = int(name.offset)
                if _, err := append(&fields, entry); !note_alloc(c, err) {
                    return INVALID_TYPE
                }
            }
        }
    }
    st.fields = fields[:]
    return type_struct(&c.table, st)
}

@(private = "file")
union_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    u, _ := odinsyntax.as_union_type(n)
    ut: Union_Type
    if params, ok := odinsyntax.union_type_params(&u); ok {
        ut.params = read_params(c, file, odinsyntax.Syntax_Node(params))
    }
    names, align := record_directives(c, file, n)
    ut.align = align
    for name in names {
        switch name {
        case "no_nil":     ut.flags += {.No_Nil}
        case "shared_nil": ut.flags += {.Shared_Nil}
        }
    }
    variants := make([dynamic]Type_Id, c.alloc)
    it := odinsyntax.union_type_variants(&u)
    for v in odinsyntax.child_iter_next(&it) {
        if _, err := append(&variants, type_expr(c, file, v)); !note_alloc(c, err) {
            return INVALID_TYPE
        }
    }
    ut.variants = variants[:]
    return type_union(&c.table, ut)
}

// An enum type. A member with no value is the one before plus one; a value may name earlier members.
@(private = "file")
enum_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    e, _ := odinsyntax.as_enum_type(n)
    et := Enum_Type{backing = elem_type(c, file, odinsyntax.enum_type_backing(&e))}
    members := make([dynamic]Enum_Member, c.alloc)
    saved := c.enum_env
    defer c.enum_env = saved
    next: i64 = 0
    it := odinsyntax.enum_type_members(&e)
    for m in odinsyntax.child_iter_next(&it) {
        m := m
        member := Enum_Member{name_offset = -1}
        if m.green.kind == .Ident {
            member.name = odinsyntax.node_text(m)
            member.name_offset = int(m.offset)
        } else if fv, ok := odinsyntax.as_field_value(m); ok {
            name, nok := odinsyntax.field_value_name(&fv)
            if !nok || name.green.kind != .Ident {
                continue
            }
            member.name = odinsyntax.node_text(name)
            member.name_offset = int(name.offset)
            c.enum_env = members[:]
            if value, vok := odinsyntax.field_value_value(&fv); vok {
                v, cok := const_eval(c, file, value)
                if x, iok := const_to_i64(v); cok && iok {
                    next = x
                }
            }
        } else {
            continue
        }
        member.value = next
        next += 1
        if _, err := append(&members, member); !note_alloc(c, err) {
            return INVALID_TYPE
        }
    }
    et.members = members[:]
    return type_enum(&c.table, et)
}

@(private = "file")
bit_field_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    b, _ := odinsyntax.as_bit_field_type(n)
    bt := Bit_Field_Type{backing = elem_type(c, file, odinsyntax.bit_field_type_backing(&b))}
    fields := make([dynamic]Bit_Field_Entry, c.alloc)
    it := odinsyntax.bit_field_type_fields(&b)
    for field in odinsyntax.child_iter_next(&it) {
        f, _ := odinsyntax.as_bit_field_field(field)
        name, ok := odinsyntax.bit_field_field_name(&f)
        if !ok {
            continue
        }
        entry := Bit_Field_Entry {
            name        = odinsyntax.node_text(odinsyntax.Syntax_Node(name)),
            name_offset = int(name.offset),
            type        = elem_type(c, file, odinsyntax.bit_field_field_type(&f)),
            bits        = length_of(c, file, odinsyntax.bit_field_field_bits(&f)),
        }
        if _, err := append(&fields, entry); !note_alloc(c, err) {
            return INVALID_TYPE
        }
    }
    bt.fields = fields[:]
    return type_bit_field(&c.table, bt)
}

// The operand an expression gives: its mode, its type and, for a constant, its value.
// This covers literals, names, `pkg.Name`, `Enum.Member`, conversions, casts, calls, composite
// literals and constant arithmetic; any other expression gives an Invalid operand.
expr_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, expected := INVALID_TYPE) -> Operand {
    n := n
    kind := n.green.kind
    if kind in odinsyntax.KINDS_TYPE && kind != .Ellipsis_Type {
        return {mode = .Type, type = type_expr(c, file, n)}
    }
    #partial switch kind {
    case .Ident:
        return ident_operand(c, file, n)
    case .Literal, .Unary_Expr, .Binary_Expr, .Ternary_Expr, .Ternary_If_Expr, .Ternary_When_Expr:
        return computed_operand(c, file, n)
    case .Paren_Expr:
        p, _ := odinsyntax.as_paren_expr(n)
        inner, ok := odinsyntax.paren_expr_expr(&p)
        return ok ? expr_type(c, file, inner, expected) : {}
    case .Selector_Expr:
        return selector_operand(c, file, n)
    case .Call_Expr:
        return call_operand(c, file, n)
    case .Comp_Lit:
        cl, _ := odinsyntax.as_comp_lit(n)
        if type, ok := odinsyntax.comp_lit_type(&cl); ok {
            return {mode = .Value, type = type_expr(c, file, type)}
        }
        return {mode = .Value, type = expected}
    case .Cast_Expr:
        ce, _ := odinsyntax.as_cast_expr(n)
        return {mode = .Value, type = elem_type(c, file, odinsyntax.cast_expr_type(&ce))}
    case .Proc_Lit:
        p, _ := odinsyntax.as_proc_lit(n)
        pt, ok := odinsyntax.proc_lit_type(&p)
        return {mode = .Value, type = ok ? proc_type(c, file, odinsyntax.Syntax_Node(pt)) : INVALID_TYPE}
    case .Proc_Group:
        return {mode = .Value, type = proc_group_type(c, file, n)}
    case .Tag_Expr:
        tag, _ := odinsyntax.as_tag_expr(n)
        inner, ok := odinsyntax.tag_expr_expr(&tag)
        if !ok {
            return {}
        }
        if inner.green.kind in odinsyntax.KINDS_TYPE {
            return {mode = .Type, type = tag_type(c, file, n)}
        }
        return expr_type(c, file, inner, expected)
    case .Undef_Expr:
        return {mode = .Value, type = type_untyped(.Uninit)}
    case .Context_Expr:
        return {mode = .Value, type = runtime_type(c, "Context")}
    case .Directive:
        d, _ := odinsyntax.as_directive(n)
        if tok, ok := odinsyntax.directive_name(&d); ok {
            switch odinsyntax.syntax_token_text(tok) {
            case "caller_location":
                return {mode = .Value, type = runtime_type(c, "Source_Code_Location")}
            case "file", "procedure", "directory":
                return {mode = .Const, type = type_untyped(.String)}
            case "line":
                return {mode = .Const, type = type_untyped(.Int)}
            }
        }
    }
    return {}
}

@(private = "file")
proc_group_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    g, _ := odinsyntax.as_proc_group(n)
    members := make([dynamic]Type_Id, c.alloc)
    it := odinsyntax.proc_group_members(&g)
    for m in odinsyntax.child_iter_next(&it) {
        if _, err := append(&members, expr_type(c, file, m).type); !note_alloc(c, err) {
            return INVALID_TYPE
        }
    }
    return type_proc_group(&c.table, members[:])
}

// The untyped type of a constant value.
@(private = "file")
untyped_of :: proc(v: Const_Value) -> Type_Id {
    switch _ in v {
    case i64:    return type_untyped(.Int)
    case f64:    return type_untyped(.Float)
    case string: return type_untyped(.String)
    case bool:   return type_untyped(.Bool)
    case rune:   return type_untyped(.Rune)
    }
    return INVALID_TYPE
}

// A literal, a unary, binary or ternary expression: a constant when const_eval knows it.
@(private = "file")
computed_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Operand {
    n := n
    v, ok := const_eval(c, file, n)
    #partial switch n.green.kind {
    case .Literal:
        if ok {
            return {mode = .Const, type = untyped_of(v), value = v}
        }
        lit, _ := odinsyntax.as_literal(n)
        if tok, tok_ok := odinsyntax.literal_token(&lit); tok_ok {
            #partial switch tok.green.kind {
            case .Integer: return {mode = .Const, type = type_untyped(.Int)}
            case .Float:   return {mode = .Const, type = type_untyped(.Float)}
            case .Imag:    return {mode = .Const, type = type_untyped(.Complex)}
            case .Rune:    return {mode = .Const, type = type_untyped(.Rune)}
            case .String:  return {mode = .Const, type = type_untyped(.String)}
            }
        }
        return {}
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        op, _ := odinsyntax.unary_expr_op(&u)
        operand, has_operand := odinsyntax.unary_expr_operand(&u)
        if !has_operand {
            return {}
        }
        inner := expr_type(c, file, operand)
        #partial switch op.green.kind {
        case .And:
            return {mode = .Value, type = type_pointer(&c.table, inner.type)}
        case .Not:
            if ok {
                return {mode = .Const, type = inner.type, value = v}
            }
            return {mode = .Value, type = inner.type}
        }
        if ok {
            return {mode = .Const, type = inner.type, value = v}
        }
        return {mode = inner.mode == .Const ? .Const : .Value, type = inner.type}
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(n)
        op, _ := odinsyntax.binary_expr_op(&b)
        lhs := elem_operand(c, file, odinsyntax.binary_expr_lhs(&b))
        rhs := elem_operand(c, file, odinsyntax.binary_expr_rhs(&b))
        mode: Operand_Mode = lhs.mode == .Const && rhs.mode == .Const ? .Const : .Value
        #partial switch op.green.kind {
        case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq, .Cmp_And, .Cmp_Or, .In, .Not_In:
            return {mode = ok ? .Const : mode, type = type_untyped(.Bool), value = v}
        }
        type := lhs.type
        if type_is_untyped(&c.table, type) && !type_is_untyped(&c.table, rhs.type) && rhs.type != INVALID_TYPE {
            type = rhs.type
        } else if type_is_untyped(&c.table, type) && type_is_untyped(&c.table, rhs.type) && ok {
            type = untyped_of(v)
        }
        return {mode = ok ? .Const : mode, type = type, value = v}
    case .Ternary_Expr:
        te, _ := odinsyntax.as_ternary_expr(n)
        return branch_operand(c, file, v, ok, odinsyntax.ternary_expr_then(&te))
    case .Ternary_If_Expr:
        te, _ := odinsyntax.as_ternary_if_expr(n)
        return branch_operand(c, file, v, ok, odinsyntax.ternary_if_expr_then(&te))
    case .Ternary_When_Expr:
        te, _ := odinsyntax.as_ternary_when_expr(n)
        return branch_operand(c, file, v, ok, odinsyntax.ternary_when_expr_then(&te))
    }
    return {}
}

// A ternary expression: a constant when const_eval knows it, else typed by its first branch.
@(private = "file")
branch_operand :: proc(c: ^Checker, file: File_Id, v: Const_Value, ok: bool, then: odinsyntax.Syntax_Node, has_then: bool) -> Operand {
    if !has_then {
        return {}
    }
    op := expr_type(c, file, then)
    if ok {
        op.mode = .Const
        op.value = v
        if type_is_untyped(&c.table, op.type) {
            op.type = untyped_of(v)
        }
        return op
    }
    if op.mode == .Const {
        op.value = nil
    }
    return op
}

@(private = "file")
elem_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, ok: bool) -> Operand {
    return ok ? expr_type(c, file, n) : {}
}

@(private = "file")
ident_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Operand {
    name := odinsyntax.node_text(n)
    r := lookup_name(c, file, name, int(n.offset))
    switch r.kind {
    case .None:
        if is_builtin_proc(name) {
            return {mode = .Builtin, symbol = {item = LOCAL_ITEM, child = -1}}
        }
        return {}
    case .Basic:
        return {mode = .Type, type = type_basic(r.basic)}
    case .Builtin:
        return builtin_operand(c, name)
    case .Import:
        return {mode = .Package, dir = r.dir}
    case .Item:
        if r.symbol in c.pending {
            // `i32 :: i32` in base:builtin: the declaration stands for the universe name.
            if u := universe_name(c, name); u.kind == .Basic || u.kind == .Builtin {
                return u.kind == .Basic ? {mode = .Type, type = type_basic(u.basic)} : builtin_operand(c, name)
            }
        }
        return item_operand(c, r.symbol, r.builtin)
    case .Local:
        return local_operand(c, r)
    }
    return {}
}

@(private = "file")
builtin_operand :: proc(c: ^Checker, name: string) -> Operand {
    switch name {
    case "true":
        return {mode = .Const, type = type_untyped(.Bool), value = true}
    case "false":
        return {mode = .Const, type = type_untyped(.Bool), value = false}
    case "nil":
        return {mode = .Value, type = type_untyped(.Nil)}
    }
    v := constant_value(name, c.snap.target)
    #partial switch v.kind {
    case .Bool:
        return {mode = .Const, type = type_untyped(.Bool), value = v.i != 0}
    case .Int:
        return {mode = .Const, type = type_untyped(.Int), value = v.i}
    case .String:
        return {mode = .Const, type = type_untyped(.String), value = v.s}
    }
    return {mode = .Const}
}

// The operand a package-level declaration gives.
item_operand :: proc(c: ^Checker, sym: Symbol, builtin := false) -> Operand {
    item := checker_item(c, sym)
    if item == nil {
        return {}
    }
    #partial switch item.kind {
    case .Import, .Foreign_Import:
        return {}
    case .Proc:
        if builtin {
            return {mode = .Builtin, type = decl_type(c, sym), symbol = sym}
        }
        return {mode = .Value, type = decl_type(c, sym)}
    case .Proc_Group, .Var:
        return {mode = .Value, type = decl_type(c, sym)}
    case .Field, .Enum_Member:
        return {mode = .Value, type = decl_type(c, sym)}
    }
    info := decl_info(c, sym)
    if info.is_type {
        return {mode = .Type, type = info.type}
    }
    v, _ := symbol_const(c, sym, sym.file, item.value_offset, item.value_index)
    return {mode = .Const, type = info.type, value = v}
}

@(private = "file")
local_operand :: proc(c: ^Checker, r: Resolved) -> Operand {
    l := r.local
    info := decl_info(c, r.symbol)
    #partial switch l.kind {
    case .Type:
        return {mode = .Type, type = info.type}
    case .Poly:
        if info.is_type {
            return {mode = .Type, type = info.type}
        }
        return {mode = .Const, type = info.type}
    case .Const:
        if info.is_type {
            return {mode = .Type, type = info.type}
        }
        v, _ := symbol_const(c, r.symbol, r.file, l.value_offset, l.value_index)
        return {mode = .Const, type = info.type, value = v}
    case .Proc, .Var, .Param, .Result, .Loop_Var, .Switch_Var:
        return {mode = .Value, type = info.type}
    }
    return {}
}

// The value of a constant declaration, read once per checker.
@(private = "file")
symbol_const :: proc(c: ^Checker, sym: Symbol, file: File_Id, value_offset, value_index: int) -> (Const_Value, bool) {
    if info, ok := c.consts[sym]; ok {
        return info.value, info.ok
    }
    if value_index >= 0 || sym in c.evaluating {
        return nil, false
    }
    value, ok := node_at(c, file, value_offset)
    if !ok {
        return nil, false
    }
    _, _, _, eerr := map_entry(&c.evaluating, sym)
    if !note_alloc(c, eerr) {
        return nil, false
    }
    saved := c.enum_env
    c.enum_env = nil
    v, vok := const_eval(c, file, value)
    c.enum_env = saved
    delete_key(&c.evaluating, sym)
    _, entry, _, err := map_entry(&c.consts, sym)
    if note_alloc(c, err) {
        entry^ = Const_Info{v, vok}
    }
    return v, vok
}

@(private = "file")
selector_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Operand {
    sel, _ := odinsyntax.as_selector_expr(n)
    if _, is_arrow := odinsyntax.selector_expr_arrow(&sel); is_arrow {
        return {}
    }
    operand, has_operand := odinsyntax.selector_expr_operand(&sel)
    field, has_field := odinsyntax.selector_expr_field(&sel)
    if !has_operand || !has_field {
        return {}
    }
    name := odinsyntax.node_text(odinsyntax.Syntax_Node(field))
    op := expr_type(c, file, operand)
    #partial switch op.mode {
    case .Package:
        sym, ok := member_lookup(c, op.dir, name, NO_FILE, true, true)
        if !ok {
            return {}
        }
        return item_operand(c, sym)
    case .Type:
        if e, is_enum := type_get(&c.table, type_base(&c.table, op.type)).(Enum_Type); is_enum {
            for m in e.members {
                if m.name == name {
                    return {mode = .Const, type = op.type, value = m.value}
                }
            }
        }
    case .Value, .Const:
        if t, ok := field_type(c, op.type, name, 0); ok {
            return {mode = .Value, type = t}
        }
    }
    return {}
}

@(private = "file")
USING_DEPTH :: 8

// The type of field `name` of a struct, bit_field or pointer to one, through `using` fields.
@(private = "file")
field_type :: proc(c: ^Checker, t: Type_Id, name: string, depth: int) -> (Type_Id, bool) {
    if depth > USING_DEPTH {
        return INVALID_TYPE, false
    }
    base := type_base(&c.table, t)
    if p, is_pointer := type_get(&c.table, base).(Pointer_Type); is_pointer {
        base = type_base(&c.table, p.elem)
    }
    #partial switch v in type_get(&c.table, base) {
    case Struct_Type:
        for f in v.fields {
            if f.name == name {
                return f.type, true
            }
        }
        for f in v.fields {
            if f.is_using {
                if ft, ok := field_type(c, f.type, name, depth + 1); ok {
                    return ft, true
                }
            }
        }
    case Bit_Field_Type:
        for f in v.fields {
            if f.name == name {
                return f.type, true
            }
        }
    }
    return INVALID_TYPE, false
}

@(private = "file")
call_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Operand {
    call, _ := odinsyntax.as_call_expr(n)
    callee, has_callee := odinsyntax.call_expr_callee(&call)
    if !has_callee {
        return {}
    }
    args := make([dynamic]odinsyntax.Syntax_Node, c.alloc)
    if list, ok := odinsyntax.call_expr_args(&call); ok {
        it := odinsyntax.arg_list_args(&list)
        for arg in odinsyntax.child_iter_next(&it) {
            if _, err := append(&args, arg); !note_alloc(c, err) {
                return {}
            }
        }
    }
    if d, is_directive := odinsyntax.as_directive(callee); is_directive {
        tok, _ := odinsyntax.directive_name(&d)
        return directive_call(c, file, odinsyntax.syntax_token_text(tok), args[:])
    }
    fn := expr_type(c, file, callee)
    #partial switch fn.mode {
    case .Type:
        base := type_base(&c.table, fn.type)
        #partial switch v in type_get(&c.table, base) {
        case Struct_Type:
            if len(v.params) > 0 {
                return {mode = .Type, type = fn.type}
            }
        case Union_Type:
            if len(v.params) > 0 {
                return {mode = .Type, type = fn.type}
            }
        }
        if len(args) != 1 {
            return {mode = .Value, type = fn.type}
        }
        if v, ok := const_eval(c, file, args[0]); ok {
            if converted, cok := const_convert(c, fn.type, v); cok {
                return {mode = .Const, type = fn.type, value = converted}
            }
        }
        return {mode = .Value, type = fn.type}
    case .Builtin:
        if item := checker_item(c, fn.symbol); item != nil {
            return builtin_call(c, file, item.name, fn.type, args[:])
        }
        return builtin_call(c, file, odinsyntax.node_text(callee), fn.type, args[:])
    case .Value:
        return call_result(c, fn.type)
    }
    return {}
}

// The result of calling a value of type `callee`: its one result, a tuple of several, or no value.
@(private = "file")
call_result :: proc(c: ^Checker, callee: Type_Id) -> Operand {
    #partial switch v in type_get(&c.table, type_base(&c.table, callee)) {
    case Proc_Type:
        return proc_result(c, v)
    case Proc_Group_Type:
        // Without overload choice the group gives a result only when its members agree.
        result := Operand{}
        for m, i in v.members {
            p, ok := type_get(&c.table, type_base(&c.table, m)).(Proc_Type)
            if !ok {
                return {}
            }
            r := proc_result(c, p)
            if i == 0 {
                result = r
            } else if r.mode != result.mode || r.type != result.type {
                return {}
            }
        }
        return result
    }
    return {}
}

@(private = "file")
proc_result :: proc(c: ^Checker, p: Proc_Type) -> Operand {
    switch len(p.results) {
    case 0:
        return {mode = .No_Value}
    case 1:
        return {mode = .Value, type = p.results[0].type}
    }
    types := make([]Type_Id, len(p.results), c.alloc)
    for r, i in p.results {
        types[i] = r.type
    }
    return {mode = .Value, type = type_tuple(&c.table, types)}
}

// True for the builtin procedures whose result builtin_call knows with no declaration from base:builtin.
@(private = "file")
is_builtin_proc :: proc(name: string) -> bool {
    switch name {
    case "len", "cap", "size_of", "align_of", "offset_of", "type_of", "typeid_of", "min", "max":
        return true
    }
    return false
}

// A call of a procedure of base:builtin. The constant ones give their value; the rest their declared result.
@(private = "file")
builtin_call :: proc(c: ^Checker, file: File_Id, name: string, callee: Type_Id, args: []odinsyntax.Syntax_Node) -> Operand {
    target := c.snap.target
    switch name {
    case "len", "cap":
        if len(args) == 1 {
            if v, ok := const_eval(c, file, args[0]); ok {
                if s, is_string := v.(string); is_string && name == "len" {
                    return {mode = .Const, type = type_untyped(.Int), value = i64(len(s))}
                }
            }
        }
        return {mode = .Value, type = type_basic(.Int)}
    case "size_of", "align_of":
        if len(args) == 1 {
            t := type_expr(c, file, args[0])
            if t == INVALID_TYPE {
                t = type_default(&c.table, expr_type(c, file, args[0]).type)
            }
            if size := type_layout(c, t, name == "align_of", target); size > 0 {
                return {mode = .Const, type = type_untyped(.Int), value = size}
            }
        }
        return {mode = .Const, type = type_untyped(.Int)}
    case "offset_of":
        return {mode = .Const, type = type_basic(.Uintptr)}
    case "type_of":
        if len(args) == 1 {
            return {mode = .Type, type = type_default(&c.table, expr_type(c, file, args[0]).type)}
        }
        return {}
    case "typeid_of":
        return {mode = .Value, type = type_basic(.Typeid)}
    case "min", "max":
        return min_max_call(c, file, name == "max", args)
    }
    return call_result(c, callee)
}

// `min(T)`, `max(T)` of an integer type, or the least or greatest of constant arguments.
@(private = "file")
min_max_call :: proc(c: ^Checker, file: File_Id, greatest: bool, args: []odinsyntax.Syntax_Node) -> Operand {
    if len(args) == 0 {
        return {}
    }
    first := expr_type(c, file, args[0])
    if first.mode == .Type {
        if len(args) != 1 {
            return {}
        }
        lo, hi, ok := integer_bounds(c, first.type)
        if !ok {
            return {mode = .Const, type = first.type}
        }
        return {mode = .Const, type = first.type, value = greatest ? hi : lo}
    }
    best := first
    for arg in args[1:] {
        op := expr_type(c, file, arg)
        if op.mode != .Const || best.mode != .Const || op.value == nil || best.value == nil {
            best.mode = .Value
            best.value = nil
            continue
        }
        cmp, cok := const_binary(c, .Lt, op.value, best.value)
        less, is_bool := cmp.(bool)
        if !cok || !is_bool {
            best.value = nil
            continue
        }
        if less != greatest {
            best = op
        }
    }
    return best
}

// The least and greatest value of an integer type; false when they do not fit i64.
@(private = "file")
integer_bounds :: proc(c: ^Checker, t: Type_Id) -> (lo, hi: i64, ok: bool) {
    b, is_basic := type_get(&c.table, type_base(&c.table, t)).(Basic_Type)
    if !is_basic || !type_is_integer(&c.table, t) {
        return 0, 0, false
    }
    bits := 8 * basic_size(b.kind, c.snap.target)
    if bits <= 0 || bits > 64 {
        return 0, 0, false
    }
    #partial switch b.kind {
    case .Uint, .U8, .U16, .U32, .U64, .U128, .Uintptr, .U16le, .U32le, .U64le, .U128le, .U16be, .U32be, .U64be, .U128be:
        if bits == 64 {
            return 0, 0, false
        }
        return 0, (i64(1) << u64(bits)) - 1, true
    }
    if bits == 64 {
        return min(i64), max(i64), true
    }
    return -(i64(1) << u64(bits - 1)), (i64(1) << u64(bits - 1)) - 1, true
}

// The size, or the alignment, of a type whose layout needs no record layout; 0 when not known.
@(private = "file")
type_layout :: proc(c: ^Checker, t: Type_Id, align: bool, target: Target) -> i64 {
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Basic_Type:
        return align ? basic_align(v.kind, target) : basic_size(v.kind, target)
    case Pointer_Type, Multi_Pointer_Type, Proc_Type:
        return type_size("rawptr", target)
    case Slice_Type:
        ptr := type_size("rawptr", target)
        return align ? ptr : 2 * ptr
    case Array_Type:
        if align {
            return type_layout(c, v.elem, true, target)
        }
        if v.len < 0 {
            return 0
        }
        return v.len * type_layout(c, v.elem, false, target)
    case Enum_Type:
        if v.backing == INVALID_TYPE {
            return type_size("int", target)
        }
        return type_layout(c, v.backing, align, target)
    }
    return 0
}

// `#config(NAME, default)`, `#defined(name)`, `#load(path)` and the other directive calls.
@(private = "file")
directive_call :: proc(c: ^Checker, file: File_Id, name: string, args: []odinsyntax.Syntax_Node) -> Operand {
    switch name {
    case "config":
        if len(args) != 2 {
            return {}
        }
        if d, ok := target_define(c.snap.target, odinsyntax.node_text(args[0])); ok {
            switch v in d {
            case bool:   return {mode = .Const, type = type_untyped(.Bool), value = v}
            case i64:    return {mode = .Const, type = type_untyped(.Int), value = v}
            case string: return {mode = .Const, type = type_untyped(.String), value = v}
            }
        }
        return expr_type(c, file, args[1])
    case "defined":
        return {mode = .Const, type = type_untyped(.Bool)}
    case "load":
        if len(args) == 2 {
            return {mode = .Value, type = type_expr(c, file, args[1])}
        }
        return {mode = .Value, type = type_slice(&c.table, type_basic(.U8))}
    case "location", "caller_location":
        return {mode = .Value, type = runtime_type(c, "Source_Code_Location")}
    case "file", "procedure", "directory":
        return {mode = .Const, type = type_untyped(.String)}
    case "line":
        return {mode = .Const, type = type_untyped(.Int)}
    }
    return {}
}
