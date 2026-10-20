package odinsyntax

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
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
            text := green_text(tree.root, context.temp_allocator)
            if !testing.expectf(t, text == f.src, "%s: tree text differs from source", f.path) {
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

// Random byte edits on real files: the lexer must stay lossless and stop.
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
    for round in 0 ..< 300 {
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
        free_all(context.temp_allocator)
    }
}

// Every prefix of a file lexes losslessly: the path of typing a file from the top.
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
        if n % 256 == 0 {
            free_all(context.temp_allocator)
        }
    }
}
