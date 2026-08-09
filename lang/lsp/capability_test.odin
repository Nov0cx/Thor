package lsp

import "core:encoding/json"
import "core:testing"

import lang ".."

// Run from the repository root: odin test lang/lsp

@(private = "file")
decode :: proc(text: string) -> Capabilities {
    value, err := json.parse(transmute([]u8)text, allocator = context.temp_allocator)
    if err != .None {
        return {}
    }
    return capabilities_decode(value)
}

// A provider is `true` or an options object, and both mean the method exists.
// Anything else — false, null, a key that is not there — means it does not.
@(test)
test_capabilities_providers :: proc(t: ^testing.T) {
    caps := decode(
        `{"capabilities": {
            "definitionProvider": true,
            "hoverProvider": {"workDoneProgress": true},
            "renameProvider": false,
            "referencesProvider": null,
            "completionProvider": {"triggerCharacters": ["."]},
            "semanticTokensProvider": {"legend": {"tokenTypes": []}, "full": true}
        }}`,
    )

    testing.expect_value(t, caps.kinds, bit_set[lang.Request_Kind]{.Definition, .Hover, .Completion, .Semantic_Tokens})
}

// A reply that is not a capabilities object leaves a server that claims nothing,
// so no request is ever sent to it.
@(test)
test_capabilities_empty :: proc(t: ^testing.T) {
    cases := []string{"null", "{}", `{"capabilities": null}`, `{"capabilities": []}`, `{"serverInfo": {"name": "x"}}`}
    for text in cases {
        caps := decode(text)
        testing.expectf(t, caps.kinds == {}, "%q claimed %v", text, caps.kinds)
        testing.expectf(t, caps.encoding == .Utf16, "%q negotiated %v", text, caps.encoding)
        testing.expectf(t, !caps.open_close && !caps.changes && !caps.saves, "%q wants documents", text)
    }
}

// Package_Doc is Thor's own idea with no LSP method behind it, so no reply can
// make a server claim it.
@(test)
test_capabilities_never_claims_package_doc :: proc(t: ^testing.T) {
    caps := decode(`{"capabilities": {"packageDocProvider": true, "": true, "definitionProvider": true}}`)
    testing.expect(t, .Package_Doc not_in caps.kinds)
    testing.expect(t, .Definition in caps.kinds)
}

// utf-16 is the protocol default and the fallback for anything Thor cannot
// count in.
@(test)
test_capabilities_encoding :: proc(t: ^testing.T) {
    Case :: struct {
        text: string,
        want: Encoding,
    }
    cases := []Case {
        {`{"capabilities": {}}`, .Utf16},
        {`{"capabilities": {"positionEncoding": "utf-16"}}`, .Utf16},
        {`{"capabilities": {"positionEncoding": "utf-8"}}`, .Utf8},
        {`{"capabilities": {"positionEncoding": "UTF-8"}}`, .Utf8},
        {`{"capabilities": {"positionEncoding": "utf-32"}}`, .Utf16},
        {`{"capabilities": {"positionEncoding": 8}}`, .Utf16},
    }
    for entry in cases {
        got := decode(entry.text).encoding
        testing.expectf(t, got == entry.want, "%q gave %v, wanted %v", entry.text, got, entry.want)
    }
}

// textDocumentSync is a number or an options object. The number names the change
// kind alone, and every kind but None takes open and close with it.
@(test)
test_capabilities_sync_number :: proc(t: ^testing.T) {
    none := decode(`{"capabilities": {"textDocumentSync": 0}}`)
    testing.expect(t, !none.open_close)
    testing.expect(t, !none.changes)

    full := decode(`{"capabilities": {"textDocumentSync": 1}}`)
    testing.expect(t, full.open_close)
    testing.expect(t, full.changes)

    incremental := decode(`{"capabilities": {"textDocumentSync": 2}}`)
    testing.expect(t, incremental.open_close)
    testing.expect(t, incremental.changes)
}

// The options form states each half on its own, and `save` counts as wanted
// whether it is a boolean or the options object.
@(test)
test_capabilities_sync_options :: proc(t: ^testing.T) {
    both := decode(`{"capabilities": {"textDocumentSync": {"openClose": true, "change": 1, "save": true}}}`)
    testing.expect(t, both.open_close)
    testing.expect(t, both.changes)
    testing.expect(t, both.saves)

    save_options := decode(`{"capabilities": {"textDocumentSync": {"openClose": true, "save": {"includeText": true}}}}`)
    testing.expect(t, save_options.open_close)
    testing.expect(t, !save_options.changes)
    testing.expect(t, save_options.saves)

    quiet := decode(`{"capabilities": {"textDocumentSync": {"openClose": true, "change": 0, "save": false}}}`)
    testing.expect(t, quiet.open_close)
    testing.expect(t, !quiet.changes)
    testing.expect(t, !quiet.saves)
}

// A whole reply of the shape clangd sends, since the pieces are only correct
// together.
@(test)
test_capabilities_real_reply :: proc(t: ^testing.T) {
    caps := decode(
        `{"capabilities": {
            "positionEncoding": "utf-8",
            "textDocumentSync": {"openClose": true, "change": 2, "save": true},
            "definitionProvider": true,
            "hoverProvider": true,
            "documentSymbolProvider": true,
            "workspaceSymbolProvider": true,
            "referencesProvider": true,
            "signatureHelpProvider": {"triggerCharacters": ["(", ","]},
            "completionProvider": {"resolveProvider": false},
            "renameProvider": {"prepareProvider": true},
            "codeActionProvider": {"codeActionKinds": ["quickfix"]},
            "semanticTokensProvider": {"full": true}
        }, "serverInfo": {"name": "clangd", "version": "18"}}`,
    )

    testing.expect_value(t, caps.encoding, Encoding.Utf8)
    testing.expect(t, caps.open_close && caps.changes && caps.saves)
    testing.expect_value(
        t,
        caps.kinds,
        lang.FEATURES_ALL - {.Package_Doc, .Diagnostics},
    )
}
