package shell

import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
Pty_Flood :: struct {
    pty:   ^Pty,
    size:  int,
    ready: bool, // atomic
    done:  bool, // atomic
}

// pty_terminate makes a write to a shell that does not read return, so the
// thread that writes can be joined.
@(test)
test_pty_terminate_ends_a_blocked_write :: proc(t: ^testing.T) {
    // POSIX puts the slave in raw mode first: in canonical mode the line
    // discipline drops the overflow instead of blocking, and on macOS that work
    // holds up every fork and kill in the process for seconds.
    when ODIN_OS == .Windows {
        profile := Profile{name = "test", exe = "cmd.exe", args = {"/c", "ping", "-n", "30", "127.0.0.1"}}
        flood_size :: 32 * 1024 * 1024
    } else {
        profile := Profile{name = "test", exe = "/bin/sh", args = {"-c", "stty raw -echo && echo ready && exec sleep 30"}}
        flood_size :: 1024 * 1024
    }
    pty, ok := pty_start(profile, "", 80, 24)
    if !testing.expect(t, ok, "the shell did not start") {
        return
    }

    flood := Pty_Flood{pty = pty, size = flood_size}
    when ODIN_OS == .Windows {
        flood.ready = true
    }
    reader := thread.create_and_start_with_poly_data(&flood, proc(f: ^Pty_Flood) {
        buf: [4096]u8
        for {
            n := pty_read(f.pty, buf[:])
            if n <= 0 {
                break
            }
            if strings.contains(string(buf[:n]), "ready") {
                sync.atomic_store(&f.ready, true)
            }
        }
    })
    writer := thread.create_and_start_with_poly_data(&flood, proc(f: ^Pty_Flood) {
        start := time.tick_now()
        for !sync.atomic_load(&f.ready) && time.tick_since(start) < 10 * time.Second {
            time.sleep(10 * time.Millisecond)
        }
        data := make([]u8, f.size)
        defer delete(data)
        for &b in data {
            b = 'a'
        }
        pty_write(f.pty, string(data))
        sync.atomic_store(&f.done, true)
    })
    waited := time.tick_now()
    for !sync.atomic_load(&flood.ready) && time.tick_since(waited) < 10 * time.Second {
        time.sleep(10 * time.Millisecond)
    }
    testing.expect(t, sync.atomic_load(&flood.ready), "the shell did not reach raw mode")

    time.sleep(200 * time.Millisecond)
    testing.expect(t, !sync.atomic_load(&flood.done), "the shell read the whole flood, so no write blocked")
    pty_terminate(pty)
    start := time.tick_now()
    for !sync.atomic_load(&flood.done) && time.tick_since(start) < 10 * time.Second {
        time.sleep(10 * time.Millisecond)
    }
    if !testing.expect(t, sync.atomic_load(&flood.done), "the write did not return after pty_terminate") {
        return // the writer still holds the pty, so nothing can be freed
    }
    thread.join(writer)
    thread.destroy(writer)
    thread.join(reader)
    thread.destroy(reader)
    pty_destroy(pty)
}
