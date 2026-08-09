// What a server said it can do, read from the `initialize` reply. The value is
// written once, before the server becomes .Ready, and never again — that is what
// lets `supports` read it on the main thread with no lock.
package lsp

import "core:encoding/json"
import "core:strings"

import lang ".."

// The `initialize` result key that advertises each request kind. Indexed by
// Request_Kind, so a new kind must name its key here as well. Package_Doc has no
// LSP equivalent and keeps an empty key: a server never claims it.
@(private)
PROVIDER_KEYS := [lang.Request_Kind]string {
    .Definition        = "definitionProvider",
    .Hover             = "hoverProvider",
    .Document_Symbols  = "documentSymbolProvider",
    .Workspace_Symbols = "workspaceSymbolProvider",
    .References        = "referencesProvider",
    .Signature_Help    = "signatureHelpProvider",
    .Completion        = "completionProvider",
    .Package_Doc       = "",
    .Rename            = "renameProvider",
    .Diagnostics       = "diagnosticProvider",
    .Code_Actions      = "codeActionProvider",
    .Semantic_Tokens   = "semanticTokensProvider",
}

// One immutable answer per question the client asks of a server.
Capabilities :: struct {
    kinds:      bit_set[lang.Request_Kind],
    encoding:   Encoding, // how the server counts characters
    open_close: bool,     // it wants didOpen and didClose
    changes:    bool,     // it wants didChange
    saves:      bool,     // it wants didSave
}

// Reads the `initialize` result. A reply that is not an object leaves a server
// that claims nothing, which is what stops a request reaching one that would
// answer an error to every one of them.
capabilities_decode :: proc(result: json.Value) -> Capabilities {
    caps := Capabilities {
        encoding = .Utf16,
    }
    root, rok := result.(json.Object)
    if !rok {
        return caps
    }
    advertised, aok := root["capabilities"].(json.Object)
    if !aok {
        return caps
    }

    for key, kind in PROVIDER_KEYS {
        if key != "" && provider(advertised, key) {
            caps.kinds += {kind}
        }
    }
    caps.encoding = encoding_of(advertised)
    decode_sync(&caps, advertised["textDocumentSync"])
    return caps
}

// True when a provider key is advertised. A provider is `true` or an options
// object, and both mean the same thing here: the options describe how the method
// behaves, not whether it exists.
@(private)
provider :: proc(advertised: json.Object, key: string) -> bool {
    value, ok := advertised[key]
    if !ok {
        return false
    }
    if flag, is_bool := value.(json.Boolean); is_bool {
        return bool(flag)
    }
    if _, is_object := value.(json.Object); is_object {
        return true
    }
    return false
}

// The negotiated encoding. utf-16 is the protocol's default and its fallback: a
// server that names an encoding Thor did not offer is answered in the one every
// server must support.
@(private)
encoding_of :: proc(advertised: json.Object) -> Encoding {
    name, ok := advertised["positionEncoding"].(json.String)
    if !ok {
        return .Utf16
    }
    if strings.equal_fold(string(name), "utf-8") {
        return .Utf8
    }
    return .Utf16
}

// `textDocumentSync` is a TextDocumentSyncKind number or an options object. The
// number names the change kind alone, so open and close go with any kind but
// None. Thor sends the whole buffer even where Incremental is asked for: a
// content change with no range is the protocol's whole-document form and stays
// valid.
@(private)
decode_sync :: proc(caps: ^Capabilities, value: json.Value) {
    if kind, ok := number(value); ok {
        caps.open_close = kind != 0
        caps.changes = kind != 0
        return
    }
    options, ook := value.(json.Object)
    if !ook {
        return
    }
    if flag, fok := options["openClose"].(json.Boolean); fok {
        caps.open_close = bool(flag)
    }
    if kind, kok := number(options["change"]); kok {
        caps.changes = kind != 0
    }
    // `save` is a boolean or a SaveOptions object; either way its presence is the
    // answer, since Thor sends no text with didSave.
    if save, sok := options["save"]; sok {
        if flag, fok := save.(json.Boolean); fok {
            caps.saves = bool(flag)
        } else if _, sobj := save.(json.Object); sobj {
            caps.saves = true
        }
    }
}
