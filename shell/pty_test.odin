package shell

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
Pty_Flood :: struct {
    pty:  ^Pty,
    done: bool, // atomic
}

// pty_terminate makes a write to a shell that does not read return, so the
// thread that writes can be joined.
@(test)
test_pty_terminate_ends_a_blocked_write :: proc(t: ^testing.T) {
    when ODIN_OS == .Windows {
        profile := Profile{name = "test", exe = "cmd.exe", args = {"/c", "ping", "-n", "30", "127.0.0.1"}}
    } else {
        profile := Profile{name = "test", exe = "/bin/sh", args = {"-c", "sleep 30"}}
    }
    pty, ok := pty_start(profile, "", 80, 24)
    if !testing.expect(t, ok, "the shell did not start") {
        return
    }

    reader := thread.create_and_start_with_poly_data(pty, proc(pty: ^Pty) {
        buf: [4096]u8
        for pty_read(pty, buf[:]) > 0 {
        }
    })
    flood := Pty_Flood{pty = pty}
    writer := thread.create_and_start_with_poly_data(&flood, proc(f: ^Pty_Flood) {
        data := make([]u8, 32 * 1024 * 1024)
        defer delete(data)
        for &b in data {
            b = 'a'
        }
        pty_write(f.pty, string(data))
        sync.atomic_store(&f.done, true)
    })

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
