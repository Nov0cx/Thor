// The feature gate: the names a host's config uses to turn language
// intelligence off, whole or in part. The gate itself is enforced by the
// Manager (see manager_set_features), so no dispatch path can forget it.
package lang

// Every request kind, i.e. the gate that lets all of them through.
FEATURES_ALL :: ~bit_set[Request_Kind]{}

// The config-facing name of each request kind. Indexed by Request_Kind, so a new
// kind must name itself here as well.
@(private)
FEATURE_NAMES := [Request_Kind]string {
    .Definition        = "definition",
    .Hover             = "hover",
    .Document_Symbols  = "document_symbols",
    .Workspace_Symbols = "workspace_symbols",
    .References        = "references",
    .Signature_Help    = "signature_help",
    .Completion        = "completion",
    .Package_Doc       = "package_doc",
    .Rename            = "rename",
    .Diagnostics       = "diagnostics",
    .Code_Actions      = "code_actions",
    .Semantic_Tokens   = "semantic_tokens",
    .Format            = "formatting",
    .Format_Range      = "range_formatting",
    .Format_On_Type    = "on_type_formatting",
    .Execute_Command   = "execute_command",
    .Progress          = "progress",
    .Apply_Edit        = "apply_edit",
}

// The config-facing name of a request kind, e.g. "signature_help".
feature_name :: proc(kind: Request_Kind) -> string {
    return FEATURE_NAMES[kind]
}

// The request kind a config name identifies, or false when nothing does.
feature_from_name :: proc(name: string) -> (Request_Kind, bool) {
    for feature, kind in FEATURE_NAMES {
        if feature == name {
            return kind, true
        }
    }
    return .Definition, false
}
