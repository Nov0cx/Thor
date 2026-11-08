package thor

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_clipboard_history_order :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    defer thor_clipboard_history_destroy(thor)

    thor_clipboard_note(thor, "a")
    thor_clipboard_note(thor, "b")
    thor_clipboard_note(thor, "   ")
    thor_clipboard_note(thor, "a")
    testing.expect_value(t, len(thor.clipboard_history), 2)
    testing.expect_value(t, thor.clipboard_history[0].text, "a")
    testing.expect_value(t, thor.clipboard_history[1].text, "b")
}

@(test)
test_clipboard_label :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_clipboard_label("one"), "one")
    testing.expect_value(t, thor_clipboard_label("\n  foo :: 1\nbar\n"), "foo :: 1  (+2 lines)")
    testing.expect_value(t, thor_clipboard_label("a\nb"), "a  (+1 line)")
}

@(test)
test_clipboard_file_round_trip :: proc(t: ^testing.T) {
    entries := []Clipboard_Entry {
        {"one", false},
        {"two\nlines\n", false},
        {"hunter2-Secret!", true},
        {"--- 3\nfake header", false},
        {"", false},
    }
    want := []string{"one", "two\nlines\n", "--- 3\nfake header", ""}
    got := clipboard_history_parse(clipboard_history_format(entries))
    testing.expect_value(t, len(got), len(want))
    for entry, i in want {
        if i < len(got) {
            testing.expect_value(t, got[i], entry)
        }
    }

    // A cut-off file keeps the entries before the damage.
    damaged := clipboard_history_parse("--- 3\nabc\n--- 99\nshort\n")
    testing.expect_value(t, len(damaged), 1)
    // CRLF endings, as an editor on Windows might save it.
    crlf := clipboard_history_parse("--- 2\r\nhi\r\n")
    testing.expect_value(t, len(crlf), 1)
    if len(crlf) == 1 {
        testing.expect_value(t, crlf[0], "hi")
    }
}

@(test)
test_clipboard_history_cap :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    defer thor_clipboard_history_destroy(thor)

    texts: [CLIPBOARD_HISTORY_MAX + 3]string
    for &text, i in texts {
        text = fmt_entry(i)
        thor_clipboard_note(thor, text)
    }
    testing.expect_value(t, len(thor.clipboard_history), CLIPBOARD_HISTORY_MAX)
    testing.expect_value(t, thor.clipboard_history[0].text, texts[len(texts) - 1])
}

@(test)
test_clipboard_secret_detection :: proc(t: ^testing.T) {
    secrets := []string {
        "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n",
        "ghp_0123456789abcdefghijABCDEFGHIJ012345",
        "AKIAIOSFODNN7EXAMPLE",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc",
        "  Tr0ub4dor&3  ",
        "hunter2!",
    }
    for text in secrets {
        testing.expectf(t, clipboard_is_secret(text, ""), "not a secret: %q", text)
    }
    plain := []string {
        "thor_clipboard_note",
        "editor.on_clipboard(editor.clipboard_data, text)",
        "hello world",
        "x := 1",
        "README",
    }
    for text in plain {
        testing.expectf(t, !clipboard_is_secret(text, ""), "a secret: %q", text)
    }

    testing.expect(t, clipboard_is_secret("DB_HOST=localhost", "project/.env"))
    testing.expect(t, clipboard_is_secret("anything", "project/.env.local"))
    testing.expect(t, clipboard_is_secret("anything", "home\\.ssh\\id_ed25519"))
    testing.expect(t, clipboard_is_secret("anything", "certs/server.PEM"))
    testing.expect(t, !clipboard_is_secret("anything", "src/main.odin"))
}

@(test)
test_clipboard_private_entry_stays_private :: proc(t: ^testing.T) {
    history: [dynamic]Clipboard_Entry
    defer {
        for entry in history {
            delete(entry.text)
        }
        delete(history)
    }
    clipboard_history_add(&history, "value", true)
    clipboard_history_add(&history, "other", false)
    clipboard_history_add(&history, "value", false)
    testing.expect_value(t, len(history), 2)
    testing.expect_value(t, history[0].text, "value")
    testing.expect(t, history[0].private)
}

@(test)
test_clipboard_file_wipe_keeps_an_empty_file :: proc(t: ^testing.T) {
    dir := "bin/test/clipboard_wipe"
    if !os.is_dir(dir) {
        testing.expect_value(t, os.make_directory_all(dir), nil)
    }
    path := "bin/test/clipboard_wipe/clipboard.txt"
    defer os.remove(path)
    testing.expect_value(t, os.write_entire_file(path, transmute([]byte) string("--- 6\nsecret\n")), nil)

    clipboard_file_wipe(path)
    testing.expect(t, os.exists(path))
    data, err := os.read_entire_file(path, context.temp_allocator)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(data), 0)
}

@(test)
test_clipboard_seal_round_trip :: proc(t: ^testing.T) {
    key: Clipboard_Key
    for &b, i in key {
        b = u8(i)
    }
    plain := "--- 5\nhello\n"
    sealed := clipboard_seal(&key, transmute([]byte) plain)
    testing.expect(t, clipboard_is_encrypted(sealed))
    testing.expect(t, !strings.contains(string(sealed), "hello"))

    opened, ok := clipboard_open(&key, sealed)
    testing.expect(t, ok)
    testing.expect_value(t, string(opened), plain)

    // A changed byte or another key opens nothing.
    sealed[len(sealed) - 1] ~= 1
    _, ok = clipboard_open(&key, sealed)
    testing.expect(t, !ok)
    sealed[len(sealed) - 1] ~= 1
    other := key
    other[0] ~= 1
    _, ok = clipboard_open(&other, sealed)
    testing.expect(t, !ok)

    _, ok = clipboard_open(&key, sealed[:10])
    testing.expect(t, !ok)
    testing.expect(t, !clipboard_is_encrypted(transmute([]byte) plain))
}

@(private = "file")
fmt_entry :: proc(i: int) -> string {
    buf := make([]u8, 3, context.temp_allocator)
    buf[0] = 'e'
    buf[1] = u8('a' + i / 26)
    buf[2] = u8('a' + i % 26)
    return string(buf)
}
