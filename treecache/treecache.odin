// Resident tree-sitter trees, one per buffer, so re-parsing a buffer costs only
// what the last edit touched. The seam callers work against hands them a full
// source snapshot rather than an edit delta, so the edit is recovered by diffing
// against the source the cached tree came from.
//
// Shared by every consumer of the vendored grammars — the highlighter and the
// language engine parse the same buffers, and one strategy for both keeps their
// trees from drifting apart. Depends on the tree-sitter binding alone, never on
// a grammar, so linking it costs a caller nothing it does not already link.
package treecache

import "base:runtime"
import "core:strings"
import "core:sync"

import ts "../vendor/odin-tree-sitter"

// Buffers resident at once, retired least-recently-used — enough that
// alternating between open tabs doesn't thrash.
SLOTS :: 8

// One buffer's last parse: the tree, the grammar it was parsed with, the source
// it came from (the diff base — tree-sitter keeps no text of its own), and the
// LRU stamp.
@(private)
Entry :: struct {
    path:    string, // cache-owned
    grammar: string, // cache-owned
    source:  string, // cache-owned
    tree:    ts.Tree,
    used:    u64,
}

// Owned strings use `alloc`, never a caller's per-request allocator.
Cache :: struct {
    mutex:   sync.Mutex,
    entries: [dynamic]Entry,
    clock:   u64,
    alloc:   runtime.Allocator,
}

init :: proc(c: ^Cache, allocator := context.allocator) {
    c.alloc = allocator
    c.entries = make([dynamic]Entry, allocator)
}

// Frees every resident tree.
destroy :: proc(c: ^Cache) {
    for entry in c.entries {
        free_entry(c, entry)
    }
    delete(c.entries)
    c.entries = nil
}

// The parse tree for `source`, reusing this path's resident tree: the cached
// source is diffed down to one changed span, `ts.tree_edit` applies it, and the
// old tree seeds the re-parse so tree-sitter rebuilds only the subtrees the edit
// invalidated. An identical source re-parses nothing at all. A path with no
// resident tree, or one whose tree came from another grammar, is parsed whole.
//
// `parser` must already have `grammar`'s language set — the cache names grammars
// but does not own them.
//
// Returns a shallow copy the caller must `tree_delete` — the entry keeps the
// original, and copies are what make a tree safe to read on one thread while
// another re-parses the same buffer. The lock spans the parse, so concurrent
// requests on one buffer serialize; the waiter gets the fresh tree.
for_source :: proc(c: ^Cache, parser: ts.Parser, path, grammar, source: string) -> ts.Tree {
    sync.lock(&c.mutex)
    defer sync.unlock(&c.mutex)

    c.clock += 1
    if i := slot(c, path); i >= 0 {
        entry := &c.entries[i]
        if entry.grammar != grammar {
            evict(c, i) // a tree from another grammar can't seed this parse
        } else {
            entry.used = c.clock
            if entry.source == source {
                return ts.tree_copy(entry.tree)
            }
            edit := source_edit(entry.source, source)
            ts.tree_edit(entry.tree, &edit)
            fresh := ts.parser_parse_string(parser, source, entry.tree)
            if fresh == nil {
                evict(c, i) // the tree carries the edit but no text to match it
                return nil
            }
            ts.tree_delete(entry.tree)
            delete(entry.source, c.alloc)
            entry.tree = fresh
            entry.source = strings.clone(source, c.alloc)
            return ts.tree_copy(fresh)
        }
    }

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return nil
    }
    store(c, path, grammar, source, tree)
    return ts.tree_copy(tree)
}

// Index of `path`'s slot, or -1.
@(private)
slot :: proc(c: ^Cache, path: string) -> int {
    for entry, i in c.entries {
        if entry.path == path {
            return i
        }
    }
    return -1
}

// Adds `path`'s tree to the cache, retiring the least recently used slot when
// full. Takes ownership of `tree`.
@(private)
store :: proc(c: ^Cache, path, grammar, source: string, tree: ts.Tree) {
    entry := Entry {
        path    = strings.clone(path, c.alloc),
        grammar = strings.clone(grammar, c.alloc),
        source  = strings.clone(source, c.alloc),
        tree    = tree,
        used    = c.clock,
    }
    if len(c.entries) < SLOTS {
        append(&c.entries, entry)
        return
    }
    lru := 0
    for slot, i in c.entries {
        if slot.used < c.entries[lru].used {
            lru = i
        }
    }
    free_entry(c, c.entries[lru])
    c.entries[lru] = entry
}

@(private)
free_entry :: proc(c: ^Cache, entry: Entry) {
    if entry.tree != nil {
        ts.tree_delete(entry.tree)
    }
    delete(entry.path, c.alloc)
    delete(entry.grammar, c.alloc)
    delete(entry.source, c.alloc)
}

@(private)
evict :: proc(c: ^Cache, i: int) {
    free_entry(c, c.entries[i])
    unordered_remove(&c.entries, i)
}

// The one byte span that turns `old` into `new`, found by trimming the common
// prefix and suffix. A keystroke is a contiguous run, so this recovers it
// exactly; a wider change (multi-cursor, a reload) collapses into one span
// covering them all — still truthful, tree-sitter reuses whatever falls outside
// it. Being diff-based it assumes no ordering: sources arriving out of revision
// order still describe a correct old->new edit. Both ends are pulled onto UTF-8
// rune boundaries.
source_edit :: proc(old, new: string) -> ts.Input_Edit {
    limit := min(len(old), len(new))

    prefix := 0
    for prefix < limit && old[prefix] == new[prefix] {
        prefix += 1
    }
    for prefix > 0 && prefix < len(new) && is_utf8_tail(new[prefix]) {
        prefix -= 1
    }

    // The suffix stops at the prefix in both strings, or the two would cross and
    // describe a negative-length edit.
    suffix := 0
    for suffix < limit - prefix && old[len(old) - 1 - suffix] == new[len(new) - 1 - suffix] {
        suffix += 1
    }
    old_end, new_end := len(old) - suffix, len(new) - suffix
    for old_end < len(old) && is_utf8_tail(old[old_end]) {
        old_end += 1
        new_end += 1
    }

    return ts.Input_Edit {
        start_byte    = u32(prefix),
        old_end_byte  = u32(old_end),
        new_end_byte  = u32(new_end),
        start_point   = byte_point(new, prefix), // a common prefix: the same in both
        old_end_point = byte_point(old, old_end),
        new_end_point = byte_point(new, new_end),
    }
}

// True for a UTF-8 continuation byte (10xxxxxx) — the middle of a rune.
@(private)
is_utf8_tail :: proc(b: byte) -> bool {
    return b & 0xC0 == 0x80
}

// The tree-sitter Point (0-based row, byte column) at `offset`. Only the edit
// description needs these — callers here work in raw byte offsets — but
// tree-sitter stores them on the nodes it shifts, so they have to be right.
@(private)
byte_point :: proc(s: string, offset: int) -> ts.Point {
    row, line_start := 0, 0
    for i in 0 ..< offset {
        if s[i] == '\n' {
            row += 1
            line_start = i + 1
        }
    }
    return ts.Point{row = u32(row), col = u32(offset - line_start)}
}
