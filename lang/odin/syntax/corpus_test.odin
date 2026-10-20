package odinsyntax

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

// Directories under the repository root the corpus skips.
@(private = "file")
SKIP_DIRS :: []string{"vendor", "bin", ".git", "user", "node_modules"}

@(private = "file")
Corpus_File :: struct {
    path: string,
    src:  string,
}

@(private = "file")
odin_root :: proc() -> string {
    if v, found := os.lookup_env("ODIN_ROOT", context.temp_allocator); found && v != "" {
        return v
    }
    return ODIN_ROOT
}

// Reads a file with CRLF collapsed to LF, the form the analyzer sees.
@(private = "file")
read_source :: proc(path: string, allocator := context.temp_allocator) -> (string, bool) {
    data, err := os.read_entire_file(path, allocator)
    if err != nil {
        return "", false
    }
    src := string(data)
    if !strings.contains(src, "\r\n") {
        return src, true
    }
    out, _ := strings.replace_all(src, "\r\n", "\n", allocator)
    return out, true
}

@(private = "file")
collect :: proc(dir: string, out: ^[dynamic]Corpus_File, allocator: mem.Allocator, skip: []string = nil) {
    handle, oerr := os.open(dir)
    if oerr != nil {
        return
    }
    defer os.close(handle)
    infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if rerr != nil {
        return
    }
    outer: for info in infos {
        if info.type == .Directory {
            for s in skip {
                if info.name == s {
                    continue outer
                }
            }
            collect(info.fullpath, out, allocator)
        } else if strings.has_suffix(info.name, ".odin") {
            if src, ok := read_source(info.fullpath, allocator); ok {
                append(out, Corpus_File{strings.clone(info.fullpath, allocator), src})
            }
        }
    }
}

// Thor's own sources and the toolchain's base, core and vendor packages.
@(private = "file")
corpus :: proc(allocator: mem.Allocator) -> []Corpus_File {
    files := make([dynamic]Corpus_File, 0, 4096, allocator)
    collect(".", &files, allocator, SKIP_DIRS)
    root := odin_root()
    for sub in ([]string{"base", "core", "vendor"}) {
        dir, jerr := filepath.join({root, sub}, context.temp_allocator)
        if jerr == nil {
            collect(dir, &files, allocator)
        }
    }
    return files[:]
}

// Loads the corpus into `arena`.
@(private = "file")
load_corpus :: proc(t: ^testing.T, arena: ^virtual.Arena) -> ([]Corpus_File, bool) {
    if err := virtual.arena_init_growing(arena); err != nil {
        testing.expectf(t, false, "arena: %v", err)
        return nil, false
    }
    return corpus(virtual.arena_allocator(arena)), true
}

// A failure message when the tokens do not cover `src` exactly, "" otherwise.
@(private = "file")
lossless_error :: proc(src: string, toks: []Token) -> string {
    pos: u32
    for tok in toks {
        if tok.offset != pos {
            return fmt.tprintf("gap at offset %d", pos)
        }
        pos = token_end(tok)
    }
    if int(pos) != len(src) {
        return fmt.tprintf("tokens end at %d of %d", pos, len(src))
    }
    if len(toks) == 0 || toks[len(toks) - 1].kind != .EOF {
        return "no EOF token"
    }
    return ""
}

// One significant token as both lexers see it.
@(private = "file")
Sig :: struct {
    kind:   Token_Kind,
    offset: int,
}

// Our kind for each reference kind of the same name; Invalid maps to Error.
@(private = "file")
Kind_Map :: [tokenizer.Token_Kind]Maybe(Token_Kind)

@(private = "file")
kind_map :: proc() -> (m: Kind_Map) {
    for rk in tokenizer.Token_Kind {
        name := fmt.tprint(rk)
        if rk == .Invalid {
            m[rk] = Token_Kind.Error
            continue
        }
        for k in Token_Kind {
            if fmt.tprint(k) == name {
                m[rk] = k
                break
            }
        }
    }
    return
}

@(private = "file")
our_sigs :: proc(toks: []Token) -> []Sig {
    out := make([dynamic]Sig, 0, len(toks) / 2, context.temp_allocator)
    for tok in toks {
        if .Implicit_Semi in tok.flags {
            append(&out, Sig{.Semicolon, int(tok.offset)})
        } else if !token_is_trivia(tok.kind) && tok.kind != .EOF {
            append(&out, Sig{tok.kind, int(tok.offset)})
        }
    }
    return out[:]
}

// The reference tokens, or false when one has no kind of ours.
@(private = "file")
reference_sigs :: proc(src: string, m: ^Kind_Map) -> ([]Sig, bool) {
    tz: tokenizer.Tokenizer
    tokenizer.init(&tz, src, "", nil)
    tz.flags = {.Insert_Semicolon}
    out := make([dynamic]Sig, 0, len(src) / 4, context.temp_allocator)
    for {
        tok := tokenizer.scan(&tz)
        #partial switch tok.kind {
        case .EOF:
            return out[:], true
        case .Comment:
            continue
        }
        kind, mapped := m[tok.kind].?
        if !mapped {
            return out[:], false
        }
        append(&out, Sig{kind, tok.pos.offset})
    }
}

@(test)
test_corpus_lossless_and_matches_reference :: proc(t: ^testing.T) {
    arena: virtual.Arena
    files, loaded := load_corpus(t, &arena)
    if !loaded {
        return
    }
    defer virtual.arena_destroy(&arena)
    if !testing.expectf(t, len(files) > 500, "corpus has only %d files", len(files)) {
        return
    }
    kinds := kind_map()
    total_bytes, total_tokens: int
    lex_time: time.Duration
    failures := 0
    for f in files {
        if failures > 20 {
            break
        }
        start := time.tick_now()
        toks := lex_all(f.src, context.temp_allocator)
        lex_time += time.tick_since(start)
        total_bytes += len(f.src)
        total_tokens += len(toks)

        if msg := lossless_error(f.src, toks); msg != "" {
            testing.expectf(t, false, "%s: %s", f.path, msg)
            failures += 1
            continue
        }
        tree, err := build_flat(f.src, toks)
        if testing.expectf(t, err == nil, "%s: tree build failed: %v", f.path, err) {
            if msg := tree_token_error(tree, toks); msg != "" {
                testing.expectf(t, false, "%s: %s", f.path, msg)
                failures += 1
            }
            tree_destroy(tree)
        }

        ours := our_sigs(toks)
        theirs, mapped := reference_sigs(f.src, &kinds)
        if !testing.expectf(t, mapped, "%s: reference token kind with no counterpart", f.path) {
            failures += 1
            continue
        }
        n := min(len(ours), len(theirs))
        for i in 0 ..< n {
            if ours[i] != theirs[i] {
                testing.expectf(t, false, "%s: token %d is %v, reference has %v", f.path, i, ours[i], theirs[i])
                failures += 1
                break
            }
        }
        if len(ours) != len(theirs) {
            testing.expectf(t, false, "%s: %d significant tokens, reference has %d", f.path, len(ours), len(theirs))
            failures += 1
        }
        free_all(context.temp_allocator)
    }
    secs := time.duration_seconds(lex_time)
    log.infof(
        "corpus: %d files, %d bytes, %d tokens, %.2f bytes/token, lexed in %.0f ms (%.1f MB/s)",
        len(files), total_bytes, total_tokens, f64(total_bytes) / f64(max(total_tokens, 1)),
        secs * 1000, f64(total_bytes) / max(secs, 1e-9) / 1e6,
    )
}

// A top-level declaration as both parsers see it: a declared name, or the keyword of an
// import, foreign or when.
@(private = "file")
Top_Decl :: struct {
    kind:   Token_Kind,
    offset: int,
}

// An expression node as both parsers see it.
@(private = "file")
Shape :: struct {
    kind:   Syntax_Kind,
    offset: int,
}

@(private = "file")
reference_shapes :: proc(file: ^ast.File) -> []Shape {
    out := make([dynamic]Shape, 0, 1024, context.temp_allocator)
    visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
        if node == nil {
            return nil
        }
        out := (^[dynamic]Shape)(v.data)
        kind := Syntax_Kind.None
        #partial switch n in node.derived {
        case ^ast.Selector_Call_Expr:
            ast.walk(v, n.call)
            return nil
        case ^ast.Struct_Type:
            ast.walk(v, n.min_field_align)
            ast.walk(v, n.max_field_align)
        case ^ast.Call_Expr:       kind = .Call_Expr
        case ^ast.Selector_Expr:   kind = .Selector_Expr
        case ^ast.Comp_Lit:        kind = .Comp_Lit
        case ^ast.Proc_Lit:        kind = .Proc_Lit
        case ^ast.Binary_Expr:     kind = .Binary_Expr
        case ^ast.Index_Expr:      kind = .Index_Expr
        case ^ast.Slice_Expr:      kind = .Slice_Expr
        case ^ast.Field_Value:     kind = .Field_Value
        case ^ast.Paren_Expr:      kind = .Paren_Expr
        case ^ast.Ternary_If_Expr: kind = .Ternary_If_Expr
        }
        if kind != .None {
            append(out, Shape{kind, node.pos.offset})
        }
        return v
    }
    v := ast.Visitor{visit = visit, data = &out}
    for decl in file.decls {
        ast.walk(&v, decl)
    }
    slice.sort_by(out[:], shape_less)
    return out[:]
}

@(private = "file")
shape_less :: proc(a, b: Shape) -> bool {
    return a.offset < b.offset || (a.offset == b.offset && a.kind < b.kind)
}

// Where a node starts when the directives of a leading Tag_Expr are left out, as core:odin/parser places it.
@(private = "file")
after_tags :: proc(node: ^Green_Node, offset: u32) -> u32 {
    kids := green_children(node)
    if len(kids) == 0 {
        return offset
    }
    tag, is_tag := element_node(kids[0])
    if !is_tag || tag.kind != .Tag_Expr {
        return offset
    }
    pos := offset
    for child in green_children(tag) {
        if c, is_node := element_node(child); is_node {
            if c.kind != .Directive {
                return after_tags(c, pos)
            }
        } else if tok, _ := element_token(child); !token_is_trivia(tok.kind) {
            return pos
        }
        pos += element_len(child)
    }
    return offset
}

@(private = "file")
our_shapes :: proc(root: ^Green_Node) -> []Shape {
    out := make([dynamic]Shape, 0, 1024, context.temp_allocator)
    walk :: proc(node: ^Green_Node, offset: u32, out: ^[dynamic]Shape) {
        #partial switch node.kind {
        case .Call_Expr, .Selector_Expr, .Comp_Lit, .Proc_Lit, .Binary_Expr, .Index_Expr,
             .Slice_Expr, .Field_Value, .Paren_Expr, .Ternary_If_Expr:
            append(out, Shape{node.kind, int(after_tags(node, offset))})
        case .Ternary_Expr:
            append(out, Shape{.Ternary_If_Expr, int(after_tags(node, offset))})
        }
        pos := offset
        for child in green_children(node) {
            if n, ok := element_node(child); ok {
                walk(n, pos, out)
            }
            pos += element_len(child)
        }
    }
    walk(root, 0, &out)
    slice.sort_by(out[:], shape_less)
    return out[:]
}

@(private = "file")
reference_parse :: proc(path, src: string) -> (decls: []Top_Decl, shapes: []Shape, errors: int) {
    context.allocator = context.temp_allocator
    file := ast.File {
        src      = src,
        fullpath = path,
    }
    p := parser.default_parser({.Optional_Semicolons})
    p.err = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
    p.warn = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
    parser.parse_file(&p, &file)
    out := make([dynamic]Top_Decl, 0, len(file.decls))
    for decl in file.decls {
        #partial switch d in decl.derived_stmt {
        case ^ast.Value_Decl:
            for name in d.names {
                append(&out, Top_Decl{.Ident, name.pos.offset})
            }
        case ^ast.Import_Decl:
            append(&out, Top_Decl{.Import, d.import_tok.pos.offset})
        case ^ast.Foreign_Import_Decl:
            append(&out, Top_Decl{.Foreign, d.foreign_tok.pos.offset})
        case ^ast.Foreign_Block_Decl:
            append(&out, Top_Decl{.Foreign, d.tok.pos.offset})
        case ^ast.When_Stmt:
            append(&out, Top_Decl{.When, d.when_pos.offset})
        }
    }
    if file.syntax_error_count > 0 {
        return out[:], nil, file.syntax_error_count
    }
    return out[:], reference_shapes(&file), 0
}

@(private = "file")
our_decls :: proc(root: ^Green_Node) -> []Top_Decl {
    out := make([dynamic]Top_Decl, 0, len(green_children(root)), context.temp_allocator)
    pos: u32
    for child in green_children(root) {
        defer pos += element_len(child)
        node, is_node := element_node(child)
        if !is_node {
            continue
        }
        #partial switch node.kind {
        case .Value_Decl:
            off := pos
            for c in green_children(node) {
                if n, ok := element_node(c); ok && n.kind == .Name_List {
                    noff := off
                    for nc in green_children(n) {
                        if nn, nok := element_node(nc); nok && (nn.kind == .Ident || nn.kind == .Poly_Type) {
                            append(&out, Top_Decl{.Ident, int(noff)})
                        }
                        noff += element_len(nc)
                    }
                    break
                }
                off += element_len(c)
            }
        case .Import_Decl, .Foreign_Import_Decl, .Foreign_Block, .When_Stmt:
            want := Token_Kind.Import
            #partial switch node.kind {
            case .Foreign_Import_Decl, .Foreign_Block: want = .Foreign
            case .When_Stmt:                           want = .When
            }
            off := pos
            for c in green_children(node) {
                if tok, ok := element_token(c); ok && tok.kind == want {
                    append(&out, Top_Decl{want, int(off)})
                    break
                }
                off += element_len(c)
            }
        }
    }
    return out[:]
}

// Every corpus file parses into a tree that holds it exactly and whose views read only children;
// a file core:odin/parser accepts gives no syntax error, the same top-level declarations and
// every required child of each view.
@(test)
test_corpus_parse :: proc(t: ^testing.T) {
    arena: virtual.Arena
    files, loaded := load_corpus(t, &arena)
    if !loaded {
        return
    }
    defer virtual.arena_destroy(&arena)
    failures := 0
    total_bytes, accepted, rejected_by_reference: int
    parse_time: time.Duration
    for f in files {
        if failures > 20 {
            break
        }
        defer free_all(context.temp_allocator)
        start := time.tick_now()
        result, err := parse(f.src)
        parse_time += time.tick_since(start)
        total_bytes += len(f.src)
        if !testing.expectf(t, err == nil, "%s: parse failed: %v", f.path, err) {
            failures += 1
            continue
        }
        defer parse_destroy(&result)
        if msg := tree_token_error(result.tree, lex_all(f.src, context.temp_allocator)); msg != "" {
            testing.expectf(t, false, "%s: %s", f.path, msg)
            failures += 1
            continue
        }
        theirs, their_shapes, ref_errors := reference_parse(f.path, f.src)
        if msg := view_error(result.tree, ref_errors == 0 && len(result.errors) == 0); msg != "" {
            testing.expectf(t, false, "%s: %s", f.path, msg)
            failures += 1
        }
        if ref_errors > 0 {
            rejected_by_reference += 1
            continue
        }
        accepted += 1
        if len(result.errors) > 0 {
            e := result.errors[0]
            testing.expectf(t, false, "%s: %d syntax errors, first at %d: %s", f.path, len(result.errors), e.offset, error_message(e, context.temp_allocator))
            failures += 1
            continue
        }
        ours := our_decls(result.tree.root)
        n := min(len(ours), len(theirs))
        for i in 0 ..< n {
            if ours[i] != theirs[i] {
                testing.expectf(t, false, "%s: declaration %d is %v, reference has %v", f.path, i, ours[i], theirs[i])
                failures += 1
                break
            }
        }
        if len(ours) != len(theirs) {
            testing.expectf(t, false, "%s: %d top-level declarations, reference has %d", f.path, len(ours), len(theirs))
            failures += 1
            continue
        }
        shapes := our_shapes(result.tree.root)
        for i in 0 ..< min(len(shapes), len(their_shapes)) {
            if shapes[i] != their_shapes[i] {
                testing.expectf(t, false, "%s: expression %d is %v, reference has %v", f.path, i, shapes[i], their_shapes[i])
                failures += 1
                break
            }
        }
        if len(shapes) != len(their_shapes) {
            testing.expectf(t, false, "%s: %d expressions, reference has %d", f.path, len(shapes), len(their_shapes))
            failures += 1
        }
    }
    secs := time.duration_seconds(parse_time)
    log.infof(
        "corpus: %d files accepted by core:odin/parser, %d rejected; parsed %d bytes in %.0f ms (%.1f MB/s)",
        accepted, rejected_by_reference, total_bytes, secs * 1000, f64(total_bytes) / max(secs, 1e-9) / 1e6,
    )
    largest, largest_own: Corpus_File
    for f in files {
        if len(f.src) > len(largest.src) {
            largest = f
        }
        if !strings.has_prefix(f.path, odin_root()) && len(f.src) > len(largest_own.src) {
            largest_own = f
        }
    }
    log_parse_speed(largest)
    log_parse_speed(largest_own)
}

// Logs the best of ten parses of one file and the size of its tree.
@(private = "file")
log_parse_speed :: proc(f: Corpus_File) {
    if f.src == "" {
        return
    }
    best := max(time.Duration)
    tree_bytes: uint
    for _ in 0 ..< 10 {
        start := time.tick_now()
        result, err := parse(f.src)
        best = min(best, time.tick_since(start))
        if err == nil {
            tree_bytes = result.tree.arena.total_used
            parse_destroy(&result)
        }
        free_all(context.temp_allocator)
    }
    log.infof(
        "%s: %d lines, %d bytes, parsed in %.2f ms (best of 10), tree %.1f bytes per source byte",
        f.path, strings.count(f.src, "\n"), len(f.src), time.duration_milliseconds(best), f64(tree_bytes) / f64(len(f.src)),
    )
}

// Parses `src` and reports whether the tree holds it exactly.
@(private = "file")
parses_losslessly :: proc(t: ^testing.T, src: string) -> bool {
    result, err := parse(src)
    if err != nil {
        return false
    }
    defer parse_destroy(&result)
    return tree_token_error(result.tree, lex_all(src, context.temp_allocator)) == ""
}

// Rounds of `test_fuzz_edits`; raise it with -define:SYNTAX_FUZZ_ROUNDS=n for a long run.
@(private = "file")
FUZZ_ROUNDS :: #config(SYNTAX_FUZZ_ROUNDS, 300)

// Random byte edits on real files: the lexer and the parser must stay lossless and stop.
@(test)
test_fuzz_edits :: proc(t: ^testing.T) {
    state := rand.create(0x7468_6f72)
    context.random_generator = rand.default_random_generator(&state)
    arena: virtual.Arena
    files, loaded := load_corpus(t, &arena)
    if !loaded {
        return
    }
    defer virtual.arena_destroy(&arena)
    if len(files) == 0 {
        return
    }
    alphabet := "\"'`/*\\\n {}()[].:;#+-=xyz019\xef\xbb\xbf\xff\x00"
    for round in 0 ..< FUZZ_ROUNDS {
        f := files[rand.int_max(len(files))]
        if len(f.src) == 0 {
            continue
        }
        buf := make([dynamic]u8, 0, len(f.src) + 64, context.temp_allocator)
        append(&buf, f.src)
        for _ in 0 ..< 1 + rand.int_max(16) {
            at := rand.int_max(len(buf) + 1)
            switch rand.int_max(3) {
            case 0:
                if at < len(buf) {
                    ordered_remove(&buf, at)
                }
            case 1:
                inject_at(&buf, at, alphabet[rand.int_max(len(alphabet))])
            case 2:
                if at < len(buf) {
                    n := min(1 + rand.int_max(32), len(buf) - at)
                    chunk := make([]u8, n, context.temp_allocator)
                    copy(chunk, buf[at:][:n])
                    inject_at(&buf, rand.int_max(len(buf) + 1), ..chunk)
                }
            }
        }
        src := string(buf[:])
        toks := lex_all(src, context.temp_allocator)
        if msg := lossless_error(src, toks); msg != "" {
            testing.expectf(t, false, "round %d (%s): %s", round, f.path, msg)
            return
        }
        if !parses_losslessly(t, src) {
            testing.expectf(t, false, "round %d (%s): parse is not lossless", round, f.path)
            return
        }
        free_all(context.temp_allocator)
    }
}

// Every prefix of a file lexes and parses losslessly: the path of typing a file from the top.
@(test)
test_every_prefix :: proc(t: ^testing.T) {
    src, ok := read_source("lang/odin/syntax/lexer.odin")
    if !testing.expect(t, ok, "lexer.odin not readable") {
        return
    }
    src = src[:min(len(src), 4000)]
    for n in 0 ..= len(src) {
        toks := lex_all(src[:n], context.temp_allocator)
        if msg := lossless_error(src[:n], toks); msg != "" {
            testing.expectf(t, false, "prefix %d: %s", n, msg)
            return
        }
        if !parses_losslessly(t, src[:n]) {
            testing.expectf(t, false, "prefix %d: parse is not lossless", n)
            return
        }
        if n % 256 == 0 {
            free_all(context.temp_allocator)
        }
    }
}
