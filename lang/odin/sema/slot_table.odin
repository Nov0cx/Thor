package odinsema

import "base:intrinsics"
import "core:mem"
import "core:sync"

// Entries in the first chunk of a Slot_Table. Chunk k holds SLOT_CHUNK_BASE << k entries.
@(private)
SLOT_CHUNK_BASE :: 64

// Chunks of a Slot_Table; enough for every u32 id.
@(private)
SLOT_CHUNKS :: 26

// An append-only table of slot pointers indexed by id. A read takes no lock, and an entry
// never moves. One writer at a time appends.
@(private)
Slot_Table :: struct($T: typeid) {
    chunks: [SLOT_CHUNKS]rawptr, // atomic; each a [^]^T, nil until its first entry
    count:  u32,                 // atomic
}

// The chunk and the offset in it of entry `index`.
@(private = "file")
slot_locate :: proc "contextless"(index: u32) -> (chunk: int, offset: int) {
    n := u64(index) / SLOT_CHUNK_BASE + 1
    chunk = 63 - int(intrinsics.count_leading_zeros(n))
    offset = int(u64(index) - SLOT_CHUNK_BASE * ((u64(1) << uint(chunk)) - 1))
    return
}

@(private = "file")
slot_chunk_len :: proc "contextless"(chunk: int) -> int {
    return SLOT_CHUNK_BASE << uint(chunk)
}

@(private)
slot_count :: proc "contextless"(t: ^Slot_Table($T)) -> u32 {
    return sync.atomic_load_explicit(&t.count, .Acquire)
}

// The entry `index`; nil when it is past the end. Any thread.
@(private)
slot_get :: proc "contextless"(t: ^Slot_Table($T), index: u32) -> ^T {
    if index >= sync.atomic_load_explicit(&t.count, .Acquire) {
        return nil
    }
    chunk, offset := slot_locate(index)
    entries       := cast([^]^T)sync.atomic_load_explicit(&t.chunks[chunk], .Acquire)
    return entries[offset]
}

// Appends `entry` and returns its index. One writer at a time.
@(private)
slot_append :: proc(t: ^Slot_Table($T), entry: ^T, allocator: mem.Allocator) -> (u32, bool) {
    index := sync.atomic_load_explicit(&t.count, .Relaxed)
    if index == max(u32) - 1 {
        return 0, false
    }
    chunk, offset := slot_locate(index)
    if chunk >= SLOT_CHUNKS {
        return 0, false
    }
    entries := cast([^]^T)t.chunks[chunk]
    if entries == nil {
        memory, err := make([]^T, slot_chunk_len(chunk), allocator)
        if err != nil {
            return 0, false
        }
        entries = raw_data(memory)
        sync.atomic_store_explicit(&t.chunks[chunk], rawptr(entries), .Release)
    }
    entries[offset] = entry
    sync.atomic_store_explicit(&t.count, index + 1, .Release)
    return index, true
}

// Frees the chunks, not the entries. No other thread may use the table.
@(private)
slot_table_destroy :: proc(t: ^Slot_Table($T), allocator: mem.Allocator) {
    for chunk in 0 ..< SLOT_CHUNKS {
        if t.chunks[chunk] != nil {
            delete((cast([^]^T)t.chunks[chunk])[:slot_chunk_len(chunk)], allocator)
        }
    }
    t^ = {}
}
