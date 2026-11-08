// Encryption of the clipboard history file: XChaCha20-Poly1305 under a per-user key.
//
// Each platform file supplies:
//     clipboard_key :: proc(create: bool) -> (key: Clipboard_Key, ok: bool)
// It reads the key, or makes and stores a new one when `create` is set and none
// exists. Windows seals the key with DPAPI; POSIX keeps it owner-only in the user
// config directory. The caller zeros the key after use.
package thor

import "core:crypto"
import "core:crypto/chacha20"
import "core:crypto/chacha20poly1305"
import "core:mem"
import "core:strings"

Clipboard_Key :: [chacha20poly1305.KEY_SIZE]byte

// First bytes of an encrypted history file. A file without them is the old plain text.
CLIPBOARD_CRYPT_MAGIC :: "THORCLP1"
// The Simd256 cipher faults at -o:none on Windows.
@(private = "file")
CLIPBOARD_CHACHA_IMPL :: chacha20.Implementation.Simd128
@(private = "file")
CLIPBOARD_CRYPT_HEADER :: len(CLIPBOARD_CRYPT_MAGIC) + chacha20poly1305.XIV_SIZE + chacha20poly1305.TAG_SIZE

clipboard_is_encrypted :: proc(data: []byte) -> bool {
    return strings.has_prefix(string(data), CLIPBOARD_CRYPT_MAGIC)
}

// Encrypts `plain` as magic | nonce | tag | ciphertext, with a random nonce.
clipboard_seal :: proc(key: ^Clipboard_Key, plain: []byte, allocator := context.temp_allocator) -> []byte {
    out := make([]byte, CLIPBOARD_CRYPT_HEADER + len(plain), allocator)
    copy(out, CLIPBOARD_CRYPT_MAGIC)
    nonce := out[len(CLIPBOARD_CRYPT_MAGIC):][:chacha20poly1305.XIV_SIZE]
    tag := out[len(CLIPBOARD_CRYPT_MAGIC) + chacha20poly1305.XIV_SIZE:][:chacha20poly1305.TAG_SIZE]
    crypto.rand_bytes(nonce)

    ctx: chacha20poly1305.Context
    chacha20poly1305.init_xchacha(&ctx, key[:], CLIPBOARD_CHACHA_IMPL)
    defer chacha20poly1305.reset(&ctx)
    chacha20poly1305.seal(&ctx, out[CLIPBOARD_CRYPT_HEADER:], tag, nonce, transmute([]byte) string(CLIPBOARD_CRYPT_MAGIC), plain)
    return out
}

// Decrypts what clipboard_seal wrote. ok=false for a short, damaged or foreign file.
clipboard_open :: proc(key: ^Clipboard_Key, sealed: []byte, allocator := context.temp_allocator) -> (plain: []byte, ok: bool) {
    if len(sealed) < CLIPBOARD_CRYPT_HEADER || !clipboard_is_encrypted(sealed) {
        return nil, false
    }
    nonce := sealed[len(CLIPBOARD_CRYPT_MAGIC):][:chacha20poly1305.XIV_SIZE]
    tag := sealed[len(CLIPBOARD_CRYPT_MAGIC) + chacha20poly1305.XIV_SIZE:][:chacha20poly1305.TAG_SIZE]
    body := sealed[CLIPBOARD_CRYPT_HEADER:]
    plain = make([]byte, len(body), allocator)

    ctx: chacha20poly1305.Context
    chacha20poly1305.init_xchacha(&ctx, key[:], CLIPBOARD_CHACHA_IMPL)
    defer chacha20poly1305.reset(&ctx)
    if !chacha20poly1305.open(&ctx, plain, nonce, transmute([]byte) string(CLIPBOARD_CRYPT_MAGIC), body, tag) {
        mem.zero_explicit(raw_data(plain), len(plain))
        delete(plain, allocator)
        return nil, false
    }
    return plain, true
}
