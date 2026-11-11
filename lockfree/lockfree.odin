// Lock-free hand-off between threads: an intrusive multi-producer stack, a
// single-producer byte ring and a bounded multi-consumer ring.
package lockfree

import "base:runtime"
import "core:sync"

// An intrusive multi-producer, single-consumer stack. `T` holds `queue_next: ^T`.
// The consumer takes every node at once, so no node is popped alone.
Stack :: struct($T: typeid) {
    head: ^T, // atomic
}

// Pushes `node`. Any thread.
stack_push :: proc "contextless"(s: ^Stack($T), node: ^T) {
    old := sync.atomic_load_explicit(&s.head, .Relaxed)
    for {
        node.queue_next = old
        prev, ok := sync.atomic_compare_exchange_weak_explicit(&s.head, old, node, .Release, .Relaxed)
        if ok {
            return
        }
        old = prev
    }
}

// Takes every pushed node as a list linked by `queue_next`, oldest first. One consumer only.
stack_take :: proc "contextless"(s: ^Stack($T)) -> ^T {
    node := sync.atomic_exchange_explicit(&s.head, nil, .Acquire)
    list: ^T
    for node != nil {
        next := node.queue_next
        node.queue_next = list
        list = node
        node = next
    }
    return list
}

stack_empty :: proc "contextless"(s: ^Stack($T)) -> bool {
    return sync.atomic_load_explicit(&s.head, .Relaxed) == nil
}

// A single-producer, single-consumer byte ring of fixed capacity.
Byte_Ring :: struct {
    data:      []u8, // owned
    mask:      uint,
    head:      uint,       // atomic; the producer's count of bytes written
    tail:      uint,       // atomic; the consumer's count of bytes read
    space:     sync.Futex, // bumped by every read that frees space, and by ring_wake
    allocator: runtime.Allocator,
}

// Makes a ring of at least `capacity` bytes, rounded up to a power of two.
ring_init :: proc(r: ^Byte_Ring, capacity: int, allocator := context.allocator) -> bool {
    size := 1
    for size < capacity {
        size <<= 1
    }
    data, err := make([]u8, size, allocator)
    if err != nil {
        return false
    }
    r^ = {}
    r.data = data
    r.mask = uint(size - 1)
    r.allocator = allocator
    return true
}

ring_destroy :: proc(r: ^Byte_Ring) {
    delete(r.data, r.allocator)
    r^ = {}
}

// Writes as much of `bytes` as fits. Producer only. Returns the bytes written.
ring_write :: proc "contextless"(r: ^Byte_Ring, bytes: []u8) -> int {
    head := sync.atomic_load_explicit(&r.head, .Relaxed)
    tail := sync.atomic_load_explicit(&r.tail, .Acquire)
    n    := min(len(r.data) - int(head - tail), len(bytes))
    if n <= 0 {
        return 0
    }
    at    := int(head & r.mask)
    first := min(n, len(r.data) - at)
    copy(r.data[at:], bytes[:first])
    copy(r.data, bytes[first:n])
    sync.atomic_store_explicit(&r.head, head + uint(n), .Release)
    return n
}

// Reads up to len(out) bytes. Consumer only. Returns the bytes read.
ring_read :: proc "contextless"(r: ^Byte_Ring, out: []u8) -> int {
    tail := sync.atomic_load_explicit(&r.tail, .Relaxed)
    head := sync.atomic_load_explicit(&r.head, .Acquire)
    n    := min(int(head - tail), len(out))
    if n <= 0 {
        return 0
    }
    at    := int(tail & r.mask)
    first := min(n, len(r.data) - at)
    copy(out, r.data[at:][:first])
    copy(out[first:n], r.data)
    sync.atomic_store_explicit(&r.tail, tail + uint(n), .Release)
    ring_wake(r)
    return n
}

// Bytes written and not yet read.
ring_len :: proc "contextless"(r: ^Byte_Ring) -> int {
    tail := sync.atomic_load_explicit(&r.tail, .Acquire)
    head := sync.atomic_load_explicit(&r.head, .Acquire)
    return int(head - tail)
}

// The value a producer passes to ring_wait_space. Load it before the write that found the ring full.
ring_space_gen :: proc "contextless"(r: ^Byte_Ring) -> u32 {
    return u32(sync.atomic_load_explicit(&r.space, .Acquire))
}

// Blocks the producer until a read or a ring_wake after `gen` was loaded.
ring_wait_space :: proc "contextless"(r: ^Byte_Ring, gen: u32) {
    sync.futex_wait(&r.space, gen)
}

// Wakes a producer blocked in ring_wait_space.
ring_wake :: proc "contextless"(r: ^Byte_Ring) {
    sync.atomic_add_explicit(&r.space, 1, .Release)
    sync.futex_broadcast(&r.space)
}

// Empties the ring. Only while no other thread uses it.
ring_reset :: proc "contextless"(r: ^Byte_Ring) {
    sync.atomic_store(&r.head, 0)
    sync.atomic_store(&r.tail, 0)
}

Mpmc_Cell :: struct($T: typeid) {
    seq:   uint, // atomic
    value: T,
}

// A bounded multi-producer, multi-consumer ring of `N` slots, `N` a power of two.
Mpmc :: struct($T: typeid, $N: int) where N > 0 && N & (N - 1) == 0 {
    cells:   [N]Mpmc_Cell(T),
    enqueue: uint, // atomic
    dequeue: uint, // atomic
}

// Call before the first push.
mpmc_init :: proc "contextless"(q: ^Mpmc($T, $N)) {
    for &cell, i in q.cells {
        cell.seq = uint(i)
    }
    q.enqueue = 0
    q.dequeue = 0
}

// Queues `value`. False when the ring is full.
mpmc_push :: proc "contextless"(q: ^Mpmc($T, $N), value: T) -> bool {
    pos := sync.atomic_load_explicit(&q.enqueue, .Relaxed)
    cell: ^Mpmc_Cell(T)
    for {
        cell = &q.cells[pos & uint(N - 1)]
        seq := sync.atomic_load_explicit(&cell.seq, .Acquire)
        dif := int(seq) - int(pos)
        if dif == 0 {
            prev, ok := sync.atomic_compare_exchange_weak_explicit(&q.enqueue, pos, pos + 1, .Relaxed, .Relaxed)
            if ok {
                break
            }
            pos = prev
        } else if dif < 0 {
            return false
        } else {
            pos = sync.atomic_load_explicit(&q.enqueue, .Relaxed)
        }
    }
    cell.value = value
    sync.atomic_store_explicit(&cell.seq, pos + 1, .Release)
    return true
}

// Takes the oldest value. False when the ring is empty.
mpmc_pop :: proc "contextless"(q: ^Mpmc($T, $N)) -> (value: T, ok: bool) {
    pos := sync.atomic_load_explicit(&q.dequeue, .Relaxed)
    cell: ^Mpmc_Cell(T)
    for {
        cell = &q.cells[pos & uint(N - 1)]
        seq := sync.atomic_load_explicit(&cell.seq, .Acquire)
        dif := int(seq) - int(pos + 1)
        if dif == 0 {
            prev, won := sync.atomic_compare_exchange_weak_explicit(&q.dequeue, pos, pos + 1, .Relaxed, .Relaxed)
            if won {
                break
            }
            pos = prev
        } else if dif < 0 {
            return {}, false
        } else {
            pos = sync.atomic_load_explicit(&q.dequeue, .Relaxed)
        }
    }
    value = cell.value
    sync.atomic_store_explicit(&cell.seq, pos + uint(N), .Release)
    return value, true
}
