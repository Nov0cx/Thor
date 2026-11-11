// Prints a summary of a spall trace that the profile build wrote.
//
//     odin run tools/profreport -- <trace.spall> [-list:<zone>] [-min:<ms>] [-thread:<name>]
//
// The summary has one row for each thread and zone name: count, total, self, mean and max time.
// `-list` prints each instance of one zone with its start, duration and args.
// `-min` hides rows (or instances) with a max (or duration) below that many milliseconds.
package profreport

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Stream_Header :: struct #packed {
    magic:           u64le,
    version:         u64le,
    timestamp_scale: f64le,
    reserved:        u64le,
}

Buffer_Header :: struct #packed {
    size:     u32le,
    tid:      u32le,
    pid:      u32le,
    first_ts: u64le,
}

MAGIC :: 0x0BADF00D

EV_BEGIN        :: 3
EV_END          :: 4
EV_INSTANT      :: 5
EV_PAD_SKIP     :: 7
EV_NAME_PROCESS :: 8
EV_NAME_THREAD  :: 9

Open :: struct {
    name:  string,
    args:  string,
    start: f64,
    child: f64,
}

Thread :: struct {
    name:  string,
    stack: [dynamic]Open,
}

Row_Key :: struct {
    thread: string,
    zone:   string,
}

Row :: struct {
    count: int,
    total: f64,
    self:  f64,
    max:   f64,
}

Instance :: struct {
    thread: string,
    start:  f64,
    dur:    f64,
    args:   string,
}

main :: proc() {
    path, list, thread_filter: string
    min_ms: f64
    for arg in os.args[1:] {
        switch {
        case strings.has_prefix(arg, "-list:"):
            list = arg[len("-list:"):]
        case strings.has_prefix(arg, "-thread:"):
            thread_filter = arg[len("-thread:"):]
        case strings.has_prefix(arg, "-min:"):
            value, ok := strconv.parse_f64(arg[len("-min:"):])
            if !ok {
                fmt.eprintfln("bad -min value %q", arg)
                os.exit(2)
            }
            min_ms = value
        case:
            path = arg
        }
    }
    if path == "" {
        fmt.eprintln("usage: profreport <trace.spall> [-list:<zone>] [-min:<ms>] [-thread:<name>]")
        os.exit(2)
    }

    data, err := os.read_entire_file(path, context.allocator)
    if err != nil {
        fmt.eprintfln("could not read %s: %v", path, err)
        os.exit(1)
    }
    if len(data) < size_of(Stream_Header) {
        fmt.eprintln("the file is too short for a spall trace")
        os.exit(1)
    }
    header := (^Stream_Header)(raw_data(data))^
    if header.magic != MAGIC {
        fmt.eprintln("the file is not a manual spall trace")
        os.exit(1)
    }
    // Event timestamps times the scale are nanoseconds.
    to_ms := f64(header.timestamp_scale) / 1e6

    threads     := make(map[u32]^Thread)
    rows        := make(map[Row_Key]Row)
    instances   := make([dynamic]Instance)
    trace_start := max(f64)
    unclosed    := 0

    offset := size_of(Stream_Header)
    for offset + size_of(Buffer_Header) <= len(data) {
        buf := (^Buffer_Header)(raw_data(data[offset:]))^
        offset += size_of(Buffer_Header)
        end := min(offset + int(buf.size), len(data))
        th  := threads[u32(buf.tid)]
        if th == nil {
            th = new(Thread)
            th.name = fmt.aprintf("tid %d", buf.tid)
            threads[u32(buf.tid)] = th
        }
        pos := offset
        events: for pos < end {
            switch data[pos] {
            case EV_BEGIN:
                if pos + 11 > end {
                    break events
                }
                ts       := f64((^u64le)(raw_data(data[pos + 1:]))^) * to_ms
                name_len := int(data[pos + 9])
                args_len := int(data[pos + 10])
                body     := pos + 11
                if body + name_len + args_len > end {
                    break events
                }
                name := string(data[body:body + name_len])
                args := string(data[body + name_len:body + name_len + args_len])
                append(&th.stack, Open{name = name, args = args, start = ts})
                trace_start = min(trace_start, ts)
                pos = body + name_len + args_len
            case EV_END:
                if pos + 9 > end {
                    break events
                }
                ts := f64((^u64le)(raw_data(data[pos + 1:]))^) * to_ms
                pos += 9
                if len(th.stack) == 0 {
                    continue
                }
                open := pop(&th.stack)
                dur  := ts - open.start
                if len(th.stack) > 0 {
                    th.stack[len(th.stack) - 1].child += dur
                }
                key := Row_Key{th.name, open.name}
                row := rows[key]
                row.count += 1
                row.total += dur
                row.self += dur - open.child
                row.max = max(row.max, dur)
                rows[key] = row
                if list != "" && open.name == list {
                    append(&instances, Instance{thread = th.name, start = open.start, dur = dur, args = open.args})
                }
            case EV_INSTANT:
                // Not written by prof; skip the fixed part and the name.
                if pos + 10 > end {
                    break events
                }
                pos += 10 + int(data[pos + 9])
            case EV_PAD_SKIP:
                if pos + 5 > end {
                    break events
                }
                pos += 5 + int((^u32le)(raw_data(data[pos + 1:]))^)
            case EV_NAME_PROCESS, EV_NAME_THREAD:
                if pos + 2 > end {
                    break events
                }
                name_len := int(data[pos + 1])
                if pos + 2 + name_len > end {
                    break events
                }
                if data[pos] == EV_NAME_THREAD {
                    // A pool thread can be named before its first zone; rows keep the name they had.
                    th.name = strings.clone(string(data[pos + 2:pos + 2 + name_len]))
                }
                pos += 2 + name_len
            case:
                fmt.eprintfln("unknown event %d at byte %d; the rest of the buffer is skipped", data[pos], pos)
                break events
            }
        }
        offset = end
    }
    for _, th in threads {
        unclosed += len(th.stack)
    }

    if list != "" {
        slice.sort_by(instances[:], proc(a, b: Instance) -> bool {
            return a.start < b.start
        })
        fmt.printfln("%-14s %10s %10s  %s", "thread", "start ms", "ms", "args")
        for inst in instances {
            if inst.dur < min_ms || (thread_filter != "" && inst.thread != thread_filter) {
                continue
            }
            fmt.printfln("%-14s %10.1f %10.2f  %s", inst.thread, inst.start - trace_start, inst.dur, inst.args)
        }
        return
    }

    Entry :: struct {
        key: Row_Key,
        row: Row,
    }
    entries := make([dynamic]Entry)
    for key, row in rows {
        if row.max >= min_ms && (thread_filter == "" || key.thread == thread_filter) {
            append(&entries, Entry{key, row})
        }
    }
    slice.sort_by(entries[:], proc(a, b: Entry) -> bool {
        if a.key.thread != b.key.thread {
            return a.key.thread < b.key.thread
        }
        return a.row.total > b.row.total
    })
    fmt.printfln("%-14s %-36s %8s %11s %11s %9s %9s", "thread", "zone", "count", "total ms", "self ms", "mean ms", "max ms")
    for e in entries {
        fmt.printfln(
            "%-14s %-36s %8d %11.1f %11.1f %9.3f %9.2f",
            e.key.thread,
            e.key.zone,
            e.row.count,
            e.row.total,
            e.row.self,
            e.row.total / f64(e.row.count),
            e.row.max,
        )
    }
    if unclosed > 0 {
        fmt.printfln("%d zones were open at the end of the trace", unclosed)
    }
}
