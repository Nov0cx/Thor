package update

// The SHA256SUMS file the release workflow publishes, and the digest of a
// downloaded archive.

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:io"
import "core:os"
import "core:strings"

// How much of the archive is hashed at a time. The archives run to tens of
// megabytes and the worker holds them nowhere else.
@(private = "file")
HASH_CHUNK :: 1 * 1024 * 1024

// The hex digest SHA256SUMS names for `asset`. Written by `sha256sum`, so a
// line is `<hex>  <name>`; the `*<name>` form a binary-mode writer produces and
// a `./` on the name are accepted as well. The digest is returned as it stands
// and compared case-insensitively.
checksums_find :: proc(sums: string, asset: string) -> (digest: string, ok: bool) {
    lines := sums
    for line in strings.split_lines_iterator(&lines) {
        trimmed := strings.trim_space(line)
        cut := strings.index_byte(trimmed, ' ')
        if cut <= 0 {
            continue
        }
        hex_field := trimmed[:cut]
        if len(hex_field) != sha2.DIGEST_SIZE_256 * 2 {
            continue
        }
        name := strings.trim_left_space(trimmed[cut:])
        name = strings.trim_prefix(name, "*")
        name = strings.trim_prefix(name, "./")
        if name == asset {
            return hex_field, true
        }
    }
    return "", false
}

// Whether a hex digest names these bytes. Both sides are compared after a case
// fold, since the two common writers disagree on it.
digest_matches :: proc(digest: [sha2.DIGEST_SIZE_256]byte, expected: string) -> bool {
    bytes := digest
    text := hex.encode(bytes[:], context.temp_allocator)
    return strings.equal_fold(string(text), strings.trim_space(expected))
}

// The SHA-256 of a byte slice.
sha256_bytes :: proc(data: []byte) -> (digest: [sha2.DIGEST_SIZE_256]byte) {
    ctx: sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx, data)
    sha2.final(&ctx, digest[:])
    return digest
}

// The SHA-256 of a file, read a chunk at a time so an archive is never held
// whole in memory.
sha256_file :: proc(path: string) -> (digest: [sha2.DIGEST_SIZE_256]byte, ok: bool) {
    handle, open_err := os.open(path)
    if open_err != nil {
        return {}, false
    }
    defer os.close(handle)

    buffer := make([]byte, HASH_CHUNK, context.temp_allocator)
    ctx: sha2.Context_256
    sha2.init_256(&ctx)
    // os.read reports the end of the file as io.EOF, possibly with final bytes.
    for {
        read, read_err := os.read(handle, buffer)
        if read > 0 {
            sha2.update(&ctx, buffer[:read])
        }
        if read_err == io.Error.EOF {
            break
        }
        if read_err != nil {
            return {}, false
        }
        if read == 0 {
            break
        }
    }
    sha2.final(&ctx, digest[:])
    return digest, true
}
