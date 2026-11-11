package lockfree

// Run from the repository root: odin test lockfree

import "core:sync"
import "core:testing"
import "core:thread"

@(private = "file")
Item :: struct {
    queue_next: ^Item,
    producer:   int,
    seq:        int,
}

@(private = "file")
PRODUCERS :: 8

@(private = "file")
PER_PRODUCER :: 5000

@(private = "file")
Stack_Run :: struct {
    stack:    Stack(Item),
    items:    []Item,
    producer: int,
}

@(private = "file")
stack_producer :: proc(run: ^Stack_Run, producer: int) {
    base := producer * PER_PRODUCER
    for i in 0 ..< PER_PRODUCER {
        item := &run.items[base + i]
        item.producer = producer
        item.seq = i
        stack_push(&run.stack, item)
    }
}

@(private = "file")
Stack_Worker :: struct {
    run:      ^Stack_Run,
    producer: int,
}

@(test)
test_stack_many_producers :: proc(t: ^testing.T) {
    run: Stack_Run
    run.items = make([]Item, PRODUCERS * PER_PRODUCER)
    defer delete(run.items)

    workers: [PRODUCERS]Stack_Worker
    threads: [PRODUCERS]^thread.Thread
    for i in 0 ..< PRODUCERS {
        workers[i] = {&run, i}
        threads[i] = thread.create_and_start_with_poly_data(&workers[i], proc(w: ^Stack_Worker) {
            stack_producer(w.run, w.producer)
        })
    }

    next: [PRODUCERS]int
    seen     := 0
    in_order := true
    for seen < PRODUCERS * PER_PRODUCER {
        for item := stack_take(&run.stack); item != nil; item = item.queue_next {
            if item.seq != next[item.producer] {
                in_order = false
            }
            next[item.producer] = item.seq + 1
            seen += 1
        }
        thread.yield()
    }
    for th in threads {
        thread.join(th)
        thread.destroy(th)
    }
    testing.expect_value(t, seen, PRODUCERS * PER_PRODUCER)
    testing.expect(t, in_order, "each producer's nodes must come out in push order")
    testing.expect(t, stack_empty(&run.stack), "the stack must be empty after the last take")
}

@(test)
test_stack_take_is_fifo :: proc(t: ^testing.T) {
    s: Stack(Item)
    items: [4]Item
    for &item, i in items {
        item.seq = i
        stack_push(&s, &item)
    }
    i := 0
    for item := stack_take(&s); item != nil; item = item.queue_next {
        testing.expect_value(t, item.seq, i)
        i += 1
    }
    testing.expect_value(t, i, 4)
    testing.expect(t, stack_take(&s) == nil, "a second take finds nothing")
}

@(private = "file")
RING_TOTAL :: 1_000_003

@(private = "file")
Ring_Run :: struct {
    ring: Byte_Ring,
}

@(test)
test_ring_spsc_stream :: proc(t: ^testing.T) {
    run: Ring_Run
    if !testing.expect(t, ring_init(&run.ring, 1000), "ring_init") {
        return
    }
    defer ring_destroy(&run.ring)
    testing.expect_value(t, len(run.ring.data), 1024)

    producer := thread.create_and_start_with_poly_data(&run, proc(run: ^Ring_Run) {
        buf: [333]u8
        sent := 0
        for sent < RING_TOTAL {
            n := min(len(buf), RING_TOTAL - sent)
            for i in 0 ..< n {
                buf[i] = u8((sent + i) % 251)
            }
            rest := buf[:n]
            for len(rest) > 0 {
                gen   := ring_space_gen(&run.ring)
                wrote := ring_write(&run.ring, rest)
                rest = rest[wrote:]
                if wrote == 0 {
                    ring_wait_space(&run.ring, gen)
                }
            }
            sent += n
        }
    })

    out: [517]u8
    got    := 0
    intact := true
    for got < RING_TOTAL {
        n := ring_read(&run.ring, out[:])
        for i in 0 ..< n {
            if out[i] != u8((got + i) % 251) {
                intact = false
            }
        }
        got += n
        if n == 0 {
            thread.yield()
        }
    }
    thread.join(producer)
    thread.destroy(producer)
    testing.expect_value(t, got, RING_TOTAL)
    testing.expect(t, intact, "the bytes must arrive in order and unchanged")
    testing.expect_value(t, ring_len(&run.ring), 0)
}

@(test)
test_ring_full_refuses :: proc(t: ^testing.T) {
    r: Byte_Ring
    if !testing.expect(t, ring_init(&r, 8), "ring_init") {
        return
    }
    defer ring_destroy(&r)
    data := [12]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}
    testing.expect_value(t, ring_write(&r, data[:]), 8)
    testing.expect_value(t, ring_write(&r, data[:]), 0)
    out: [5]u8
    testing.expect_value(t, ring_read(&r, out[:]), 5)
    testing.expect_value(t, ring_write(&r, data[8:]), 4)
    rest: [16]u8
    testing.expect_value(t, ring_read(&r, rest[:]), 7)
    testing.expect(t, rest[3] == 8 && rest[6] == 11, "a write that wraps keeps its order")
}

@(private = "file")
MPMC_TOTAL :: 200_000

@(private = "file")
CONSUMERS :: 4

@(private = "file")
Mpmc_Run :: struct {
    queue: Mpmc(int, 256),
    seen:  []u8,
    done:  bool, // atomic
    taken: int,  // atomic
}

@(test)
test_mpmc_one_producer_many_consumers :: proc(t: ^testing.T) {
    run := new(Mpmc_Run)
    defer free(run)
    mpmc_init(&run.queue)
    run.seen = make([]u8, MPMC_TOTAL)
    defer delete(run.seen)

    threads: [CONSUMERS]^thread.Thread
    for i in 0 ..< CONSUMERS {
        threads[i] = thread.create_and_start_with_poly_data(run, proc(run: ^Mpmc_Run) {
            for {
                value, ok := mpmc_pop(&run.queue)
                if ok {
                    sync.atomic_add(&run.seen[value], 1)
                    sync.atomic_add(&run.taken, 1)
                    continue
                }
                if sync.atomic_load(&run.done) {
                    return
                }
                thread.yield()
            }
        })
    }

    for i in 0 ..< MPMC_TOTAL {
        for !mpmc_push(&run.queue, i) {
            thread.yield()
        }
    }
    for sync.atomic_load(&run.taken) < MPMC_TOTAL {
        thread.yield()
    }
    sync.atomic_store(&run.done, true)
    for th in threads {
        thread.join(th)
        thread.destroy(th)
    }

    once := true
    for count in run.seen {
        if count != 1 {
            once = false
        }
    }
    testing.expect(t, once, "every value must be taken exactly once")
}

@(test)
test_mpmc_full_and_empty :: proc(t: ^testing.T) {
    q: Mpmc(int, 4)
    mpmc_init(&q)
    _, ok := mpmc_pop(&q)
    testing.expect(t, !ok, "an empty ring gives nothing")
    for i in 0 ..< 4 {
        testing.expect(t, mpmc_push(&q, i), "a push with room succeeds")
    }
    testing.expect(t, !mpmc_push(&q, 9), "a full ring refuses")
    for i in 0 ..< 4 {
        v, got := mpmc_pop(&q)
        testing.expect(t, got && v == i, "values come out in order")
    }
}
