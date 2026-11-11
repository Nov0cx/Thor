// Clipboard history: the texts the editor copied, cut or pasted, newest first,
// and the picker that pastes one of them again.
package thor

import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import "../atomicfile"
import "../editview"
import "../prof"
import "../setting"
import ui "../vendor/loom/loom"

CLIPBOARD_HISTORY_MAX  :: 30
// Longest entry kept, in bytes. A bigger copy is not recorded.
CLIPBOARD_ENTRY_MAX    :: 1 << 20
CLIPBOARD_LABEL_RUNES  :: 60
// The history between sessions, encrypted (clipboard_crypt.odin). Inside, each entry is a
// "--- <byte count>" line, the text and a newline.
CLIPBOARD_FILE         :: "sessions/clipboard.txt"
CLIPBOARD_ENTRY_HEADER :: "--- "
// Shortest single word that counts as a password when it mixes three character classes.
CLIPBOARD_PASSWORD_MIN :: 8

Clipboard_Entry :: struct {
    text:    string, // owned
    // Looks like a secret: kept for this session, never written to CLIPBOARD_FILE.
    private: bool,
}

// Records `text` as the newest entry. A text already in the list moves to the front.
thor_clipboard_note :: proc(data: rawptr, text: string) {
    thor   := cast(^Thor)data
    source := ""
    if file := thor_active_open_file(thor); file != nil {
        source = file.path
    }
    clipboard_history_add(&thor.clipboard_history, text, clipboard_is_secret(text, source))
}

@(private)
clipboard_history_add :: proc(history: ^[dynamic]Clipboard_Entry, text: string, private: bool) {
    if len(text) == 0 || len(text) > CLIPBOARD_ENTRY_MAX || strings.trim_space(text) == "" {
        return
    }
    for entry, i in history {
        if entry.text == text {
            moved := entry
            moved.private ||= private
            ordered_remove(history, i)
            inject_at(history, 0, moved)
            return
        }
    }
    for len(history) >= CLIPBOARD_HISTORY_MAX {
        clipboard_entry_wipe(pop(history))
    }
    inject_at(history, 0, Clipboard_Entry{strings.clone(text), private})
}

// Reports whether `text` looks like a secret, by its content or by the file it came from.
@(private)
clipboard_is_secret :: proc(text: string, source_path: string) -> bool {
    if source_path != "" && clipboard_is_secret_file(source_path) {
        return true
    }
    if strings.contains(text, "-----BEGIN") && strings.contains(text, "PRIVATE KEY") {
        return true
    }
    word := strings.trim_space(text)
    if strings.index_any(word, " \t\r\n") >= 0 {
        return false
    }
    TOKEN_PREFIXES :: [?]string{
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "github_pat_",
        "glpat-",
        "sk-",
        "xoxb-",
        "xoxp-",
        "xoxa-",
        "AKIA",
        "ASIA",
        "AIza",
        "npm_",
        "pypi-",
    }
    for prefix in TOKEN_PREFIXES {
        if strings.has_prefix(word, prefix) && len(word) > len(prefix) + 8 {
            return true
        }
    }
    // A JSON web token: three base64url parts, the first a JSON header.
    if strings.has_prefix(word, "eyJ") && strings.count(word, ".") == 2 {
        return true
    }
    if len(word) < CLIPBOARD_PASSWORD_MIN {
        return false
    }
    lower, upper, digit, symbol: bool
    for r in word {
        switch r {
        case 'a' ..= 'z':
            lower = true
        case 'A' ..= 'Z':
            upper = true
        case '0' ..= '9':
            digit = true
        case:
            symbol = true
        }
    }
    return int(lower) + int(upper) + int(digit) + int(symbol) >= 3
}

// Reports whether a file at `path` usually holds secrets: .env files, keys, credential stores.
@(private = "file")
clipboard_is_secret_file :: proc(path: string) -> bool {
    base := path[strings.last_index_any(path, "/\\") + 1:]
    name := strings.to_lower(base, context.temp_allocator)
    if name == ".env" || strings.has_prefix(name, ".env.") || strings.has_suffix(name, ".env") {
        return true
    }
    SECRET_NAMES :: [?]string{"credentials", ".netrc", "_netrc", ".npmrc", ".pypirc", ".pgpass", ".htpasswd"}
    for secret in SECRET_NAMES {
        if name == secret {
            return true
        }
    }
    SECRET_PREFIXES :: [?]string{"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"}
    for prefix in SECRET_PREFIXES {
        if strings.has_prefix(name, prefix) {
            return true
        }
    }
    SECRET_EXTENSIONS :: [?]string{".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".kdbx", ".gpg", ".asc"}
    for secret in SECRET_EXTENSIONS {
        if strings.has_suffix(name, secret) {
            return true
        }
    }
    return false
}

// Reads the history CLIPBOARD_FILE holds. A missing file is an empty history;
// a damaged one keeps the entries before the damage.
thor_clipboard_history_load :: proc(thor: ^Thor) {
    if !setting.clipboard_history_save(&thor.config) || !os.exists(CLIPBOARD_FILE) {
        return
    }
    data, err := os.read_entire_file(CLIPBOARD_FILE, context.temp_allocator)
    if err != nil {
        log.warnf("Could not read %q: %v", CLIPBOARD_FILE, err)
        return
    }
    defer mem.zero_explicit(raw_data(data), len(data))
    plain := data
    if clipboard_is_encrypted(data) {
        key, kok := clipboard_key(false)
        if !kok {
            log.warnf("No key opens %q; the saved history is lost", CLIPBOARD_FILE)
            return
        }
        opened, ook := clipboard_open(&key, data)
        mem.zero_explicit(&key, len(key))
        if !ook {
            log.warnf("Could not decrypt %q; the saved history is lost", CLIPBOARD_FILE)
            return
        }
        plain = opened
    }
    defer mem.zero_explicit(raw_data(plain), len(plain))
    entries := clipboard_history_parse(string(plain))
    // Oldest first, so the newest ends at the front.
    #reverse for entry in entries {
        clipboard_history_add(&thor.clipboard_history, entry, clipboard_is_secret(entry, ""))
    }
}

// Writes the entries that are not private, encrypted. With the setting off, wipes the file instead.
thor_clipboard_history_save :: proc(thor: ^Thor) {
    prof.proc_scope()
    // The old bytes are zeroed first: the replace only unlinks them.
    clipboard_file_wipe(CLIPBOARD_FILE)
    if !setting.clipboard_history_save(&thor.config) {
        return
    }
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }
    key, kok := clipboard_key(true)
    if !kok {
        log.errorf("No clipboard key; %q is not written", CLIPBOARD_FILE)
        return
    }
    clipboard_file_restrict()
    data   := clipboard_history_format(thor.clipboard_history[:])
    sealed := clipboard_seal(&key, transmute([]byte)data)
    mem.zero_explicit(&key, len(key))
    mem.zero_explicit(raw_data(data), len(data))
    if err := atomicfile.write(CLIPBOARD_FILE, sealed); err != nil {
        log.errorf("Could not write %q: %v", CLIPBOARD_FILE, err)
    }
}

// Empties the history, in memory and on disk.
thor_cmd_clear_clipboard_history :: proc(data: rawptr) {
    thor := cast(^Thor)data
    for entry in thor.clipboard_history {
        clipboard_entry_wipe(entry)
    }
    clear(&thor.clipboard_history)
    clipboard_file_wipe(CLIPBOARD_FILE)
    thor_flash_status(thor, "Clipboard history cleared")
}

// Overwrites the file at `path` with zeros in place, then truncates it. The file is
// not deleted, so no copy of it goes to a trash bin.
@(private)
clipboard_file_wipe :: proc(path: string) {
    if !os.exists(path) {
        return
    }
    f, err := os.open(path, {.Read, .Write})
    if err != nil {
        log.errorf("Could not open %q to wipe it: %v", path, err)
        return
    }
    defer os.close(f)
    size, serr := os.file_size(f)
    if serr != nil {
        log.errorf("Could not size %q: %v", path, serr)
        return
    }
    zeros: [4096]byte
    for at := i64(0); at < size; at += len(zeros) {
        chunk := min(i64(len(zeros)), size - at)
        if _, werr := os.write_at(f, zeros[:chunk], at); werr != nil {
            log.errorf("Could not wipe %q: %v", path, werr)
            return
        }
    }
    if yerr := os.sync(f); yerr != nil {
        log.warnf("Could not sync %q: %v", path, yerr)
    }
    if terr := os.truncate(f, 0); terr != nil {
        log.errorf("Could not truncate %q: %v", path, terr)
    }
}

// Gives CLIPBOARD_FILE owner-only access before it is written; the replace keeps that mode.
@(private = "file")
clipboard_file_restrict :: proc() {
    when ODIN_OS != .Windows {
        if !os.exists(CLIPBOARD_FILE) {
            f, err := os.open(CLIPBOARD_FILE, {.Write, .Create}, os.perm_number(0o600))
            if err != nil {
                log.warnf("Could not create %q: %v", CLIPBOARD_FILE, err)
                return
            }
            _ = os.close(f)
        }
        if err := os.change_mode(CLIPBOARD_FILE, os.perm_number(0o600)); err != nil {
            log.warnf("Could not restrict %q: %v", CLIPBOARD_FILE, err)
        }
    }
}

@(private)
clipboard_history_format :: proc(entries: []Clipboard_Entry, allocator := context.temp_allocator) -> string {
    b := strings.builder_make(allocator)
    for entry in entries {
        if entry.private {
            continue
        }
        strings.write_string(&b, CLIPBOARD_ENTRY_HEADER)
        strings.write_int(&b, len(entry.text))
        strings.write_byte(&b, '\n')
        strings.write_string(&b, entry.text)
        strings.write_byte(&b, '\n')
    }
    return strings.to_string(b)
}

// Entries of a CLIPBOARD_FILE body, borrowed from `data`, newest first.
@(private)
clipboard_history_parse :: proc(data: string, allocator := context.temp_allocator) -> [dynamic]string {
    entries := make([dynamic]string, allocator)
    rest    := data
    for len(rest) > 0 && strings.has_prefix(rest, CLIPBOARD_ENTRY_HEADER) {
        eol := strings.index_byte(rest, '\n')
        if eol < 0 {
            break
        }
        size, ok := strconv.parse_int(strings.trim_right(rest[len(CLIPBOARD_ENTRY_HEADER):eol], "\r"), 10)
        body     := rest[eol + 1:]
        if !ok || size < 0 || size > len(body) {
            break
        }
        append(&entries, body[:size])
        rest = strings.trim_prefix(body[size:], "\n")
    }
    return entries
}

// Zeros an entry's text, then frees it.
@(private = "file")
clipboard_entry_wipe :: proc(entry: Clipboard_Entry) {
    mem.zero_explicit(raw_data(entry.text), len(entry.text))
    delete(entry.text)
}

thor_clipboard_history_destroy :: proc(thor: ^Thor) {
    for entry in thor.clipboard_history {
        clipboard_entry_wipe(entry)
    }
    delete(thor.clipboard_history)
    thor.clipboard_history = nil
}

// One-line label of an entry: its first non-blank line, cut to CLIPBOARD_LABEL_RUNES,
// with the count of the other lines.
thor_clipboard_label :: proc(text: string, allocator := context.temp_allocator) -> string {
    first := ""
    lines := 0
    rest  := text
    for line in strings.split_lines_iterator(&rest) {
        lines += 1
        if first == "" {
            first = strings.trim_space(line)
        }
    }

    b     := strings.builder_make(allocator)
    runes := 0
    for r in first {
        if runes == CLIPBOARD_LABEL_RUNES {
            strings.write_string(&b, "…")
            break
        }
        strings.write_rune(&b, r == '\t' ? ' ' : r)
        runes += 1
    }
    if lines > 1 {
        strings.write_string(&b, "  (+")
        strings.write_int(&b, lines - 1)
        strings.write_string(&b, lines == 2 ? " line)" : " lines)")
    }
    return strings.to_string(b)
}

thor_cmd_clipboard_history :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if thor_active_editor(thor) == nil || thor_active_editor(thor).state == nil {
        thor_flash_status(thor, "Clipboard history: no file to paste into")
        return
    }
    if len(thor.clipboard_history) == 0 {
        thor_flash_status(thor, "Clipboard history is empty")
        return
    }
    labels := make([]string, len(thor.clipboard_history), context.temp_allocator)
    values := make([]string, len(thor.clipboard_history), context.temp_allocator)
    for entry, i in thor.clipboard_history {
        labels[i] = thor_clipboard_label(entry.text)
        values[i] = entry.text
    }
    thor_select_open(thor, "Clipboard History", labels, values[0], nil, thor_clipboard_history_commit, thor, values)
}

// Puts the chosen entry on the clipboard and pastes it into the active pane.
@(private = "file")
thor_clipboard_history_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor)data
    ui.set_clipboard_text(choice)
    editview.editor_paste(thor_active_editor(thor))
}
