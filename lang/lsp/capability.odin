// What a server said it can do, read from the `initialize` reply. The value is
// written once, before the server becomes .Ready, and never again — that is what
// lets `supports` read it on the main thread with no lock.
package lsp

import "base:runtime"
import "core:encoding/json"
import "core:strings"

import lang ".."

// The `initialize` result key that advertises each request kind. Indexed by
// Request_Kind, so a new kind must name its key here as well. Package_Doc has no
// LSP equivalent of its own; it rides hoverProvider, the request it is actually
// sent as, so the two kinds are claimed together.
@(private)
PROVIDER_KEYS := [lang.Request_Kind]string {
    .Definition        = "definitionProvider",
    .Hover             = "hoverProvider",
    .Document_Symbols  = "documentSymbolProvider",
    .Workspace_Symbols = "workspaceSymbolProvider",
    .References        = "referencesProvider",
    .Signature_Help    = "signatureHelpProvider",
    .Completion        = "completionProvider",
    .Package_Doc       = "hoverProvider",
    .Rename            = "renameProvider",
    .Diagnostics       = "diagnosticProvider",
    .Code_Actions      = "codeActionProvider",
    .Semantic_Tokens   = "semanticTokensProvider",
    .Progress          = "", // unsolicited push; no capability gate, same as Package_Doc
    .Apply_Edit        = "", // unsolicited push; no capability gate, same as Package_Doc
}

// What one entry of a server's semantic-token legend means to Thor. `valid` is
// false for a token type that is dropped, so a server token can never overrule a
// grammar color with a worse one.
Token_Legend_Entry :: struct {
    kind:  lang.Token_Kind,
    valid: bool,
}

// One immutable answer per question the client asks of a server.
Capabilities :: struct {
    kinds:            bit_set[lang.Request_Kind],
    encoding:         Encoding, // how the server counts characters
    open_close:       bool,     // it wants didOpen and didClose
    changes:          bool,     // it wants didChange
    sync_incremental: bool,     // didChange may send a range instead of the whole buffer
    saves:            bool,     // it wants didSave
    prepare_rename:   bool,     // renameProvider.prepareProvider
    resolve_actions:  bool,     // codeActionProvider.resolveProvider
    token_legend:     []Token_Legend_Entry, // owned; indexed by the server's tokenTypes
    token_delta:      bool,     // semanticTokensProvider.full.delta: the /full/delta method may be asked for
    allocator:        runtime.Allocator,    // what built token_legend
}

// Reads the `initialize` result. A reply that is not an object leaves a server
// that claims nothing, which is what stops a request reaching one that would
// answer an error to every one of them.
capabilities_decode :: proc(result: json.Value, allocator := context.allocator) -> Capabilities {
    caps := Capabilities {
        encoding  = .Utf16,
        allocator = allocator,
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
    decode_legend(&caps, advertised["semanticTokensProvider"])
    if options, ok := advertised["renameProvider"].(json.Object); ok {
        if flag, fok := options["prepareProvider"].(json.Boolean); fok {
            caps.prepare_rename = bool(flag)
        }
    }
    if options, ok := advertised["codeActionProvider"].(json.Object); ok {
        if flag, fok := options["resolveProvider"].(json.Boolean); fok {
            caps.resolve_actions = bool(flag)
        }
    }
    return caps
}

// Frees the legend. Safe on a Capabilities no reply ever filled, which is what a
// server that never started leaves behind.
capabilities_destroy :: proc(caps: ^Capabilities) {
    if caps.token_legend == nil {
        return
    }
    delete(caps.token_legend, caps.allocator)
    caps.token_legend = nil
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

// The semantic-token legend: the server's own list of token type names, which is
// what the indices of a token stream point into. A server that sends no legend
// gets no tokens read, since an index into a missing list names nothing.
// `full` is a bare `true` (full only) or `{"delta": true}` (full and delta).
@(private)
decode_legend :: proc(caps: ^Capabilities, value: json.Value) {
    options, ook := value.(json.Object)
    if !ook {
        return
    }
    if full, fok := options["full"].(json.Object); fok {
        if flag, dok := full["delta"].(json.Boolean); dok {
            caps.token_delta = bool(flag)
        }
    }
    legend, lok := options["legend"].(json.Object)
    if !lok {
        return
    }
    names, nok := legend["tokenTypes"].(json.Array)
    if !nok || len(names) == 0 {
        return
    }
    entries := make([]Token_Legend_Entry, len(names), caps.allocator)
    for value, index in names {
        name, is_name := value.(json.String)
        if !is_name {
            continue
        }
        entries[index].kind, entries[index].valid = token_kind_of(string(name))
    }
    caps.token_legend = entries
}

// The Token_Kind a legend name means. A name Thor has no kind for is dropped:
// the seam is sparse by design, and `keyword`, `string`, `comment`, `number` and
// `operator` are already colored by the grammar. `Unresolved` is never produced —
// the absence of a token is not proof that a name is undeclared.
@(private)
token_kind_of :: proc(name: string) -> (lang.Token_Kind, bool) {
    switch name {
    case "parameter":
        return .Parameter, true
    case "variable":
        return .Local, true
    case "property", "member":
        return .Field, true
    case "function", "method":
        return .Procedure, true
    case "class", "struct", "interface", "enum", "type", "typeParameter", "typeAlias":
        return .Type, true
    case "enumMember":
        return .Enum_Member, true
    case "namespace", "module":
        return .Package, true
    }
    return .Local, false
}

// `textDocumentSync` is a TextDocumentSyncKind number or an options object. The
// number names the change kind alone, so open and close go with any kind but
// None. Kind 2 is Incremental; Thor sends a ranged didChange only when this is
// set, and falls back to the whole-buffer form otherwise — a content change
// with no range is the protocol's whole-document form and stays valid for any
// server, so the fallback is never wrong, only less efficient.
@(private)
decode_sync :: proc(caps: ^Capabilities, value: json.Value) {
    if kind, ok := number(value); ok {
        caps.open_close = kind != 0
        caps.changes = kind != 0
        caps.sync_incremental = kind == 2
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
        caps.sync_incremental = kind == 2
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
