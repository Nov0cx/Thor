#+build windows
package thor

import "core:crypto"
import "core:log"
import "core:mem"
import "core:os"
import win "core:sys/windows"

import "../atomicfile"

foreign import crypt32 "system:Crypt32.lib"

@(default_calling_convention = "system", private = "file")
foreign crypt32 {
    CryptProtectData   :: proc(
        data_in: ^win.DATA_BLOB,
        description: win.LPCWSTR,
        entropy: ^win.DATA_BLOB,
        reserved: rawptr,
        prompt: rawptr,
        flags: win.DWORD,
        data_out: ^win.DATA_BLOB,
    ) -> win.BOOL ---
    CryptUnprotectData :: proc(
        data_in: ^win.DATA_BLOB,
        description: ^win.LPWSTR,
        entropy: ^win.DATA_BLOB,
        reserved: rawptr,
        prompt: rawptr,
        flags: win.DWORD,
        data_out: ^win.DATA_BLOB,
    ) -> win.BOOL ---
}

@(private = "file")
CRYPTPROTECT_UI_FORBIDDEN :: 0x1
// The key, sealed with DPAPI: only this Windows user on this machine can open it.
@(private = "file")
CLIPBOARD_KEY_FILE :: "sessions/clipboard.key"

clipboard_key :: proc(create: bool) -> (key: Clipboard_Key, ok: bool) {
    if os.exists(CLIPBOARD_KEY_FILE) {
        sealed, err := os.read_entire_file(CLIPBOARD_KEY_FILE, context.temp_allocator)
        if err != nil {
            log.errorf("Could not read %q: %v", CLIPBOARD_KEY_FILE, err)
            return
        }
        blob_in := win.DATA_BLOB{cbData = win.DWORD(len(sealed)), pbData = raw_data(sealed)}
        blob_out: win.DATA_BLOB
        if !CryptUnprotectData(&blob_in, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &blob_out) {
            log.errorf("Could not unseal %q: error %d", CLIPBOARD_KEY_FILE, win.GetLastError())
            return
        }
        defer win.LocalFree(blob_out.pbData)
        defer mem.zero_explicit(blob_out.pbData, int(blob_out.cbData))
        if int(blob_out.cbData) != len(key) {
            log.errorf("%q holds a key of the wrong size", CLIPBOARD_KEY_FILE)
            return
        }
        copy(key[:], blob_out.pbData[:blob_out.cbData])
        return key, true
    }
    if !create {
        return
    }

    crypto.rand_bytes(key[:])
    blob_in := win.DATA_BLOB{cbData = win.DWORD(len(key)), pbData = &key[0]}
    blob_out: win.DATA_BLOB
    if !CryptProtectData(&blob_in, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &blob_out) {
        log.errorf("Could not seal the clipboard key: error %d", win.GetLastError())
        mem.zero_explicit(&key, len(key))
        return
    }
    defer win.LocalFree(blob_out.pbData)
    if err := atomicfile.write(CLIPBOARD_KEY_FILE, blob_out.pbData[:blob_out.cbData]); err != nil {
        log.errorf("Could not write %q: %v", CLIPBOARD_KEY_FILE, err)
        mem.zero_explicit(&key, len(key))
        return
    }
    return key, true
}
