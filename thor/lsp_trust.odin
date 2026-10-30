package thor

// Trust for `<workspace>/.thor/lsp.lua`. That file comes with the folder and
// names programs to start, so it joins the server table only once the user
// allows it. The answer keys on the workspace and on the digest of the file, so
// a changed file is asked about again — whoever changed it.

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"

import "../atomicfile"
import "../lang/lsp"

@(private = "file")
LSP_GRANTS_FILE :: "sessions/lsp-grants.json"

// One allowed workspace file.
@(private)
Lsp_Grant :: struct {
    workspace: string,
    digest:    string, // SHA-256 of the file, hex
}

@(private = "file")
Lsp_Grants :: struct {
    workspaces: []Lsp_Grant,
}

// Whether the workspace's lsp.lua may join the server table. A file that is
// absent or names no entry has nothing to gate. Else raises the prompt, unless
// this file was already declined.
thor_lsp_workspace_trusted :: proc(thor: ^Thor) -> bool {
    thor.lsp_trust_pending = false
    digest, has_entries := thor_lsp_workspace_digest(thor.workspace_dir)
    if !has_entries {
        return true
    }
    if thor_lsp_find_grant(thor_read_lsp_grants()[:], thor.workspace_dir, digest) {
        return true
    }
    key := strings.concatenate({thor.workspace_dir, "|", digest}, context.temp_allocator)
    if key != thor.lsp_trust_key {
        delete(thor.lsp_trust_key)
        thor.lsp_trust_key = strings.clone(key)
        thor.lsp_trust_declined = false
    }
    thor.lsp_trust_pending = !thor.lsp_trust_declined
    return false
}

// Run-loop tick: asks about the workspace's servers, one row per entry. Waits
// for the plugin prompts, which use the same dialog.
thor_prompt_lsp_trust :: proc(thor: ^Thor) {
    if !thor.lsp_trust_pending || thor.permission_open {
        return
    }
    if thor.plugin_prompt_shown || len(thor.plugin_requests) > 0 {
        return
    }
    thor.lsp_trust_pending = false

    ids := make([dynamic]string, context.temp_allocator)
    texts := make([dynamic]string, context.temp_allocator)
    for command in lsp.config_workspace_commands(thor.workspace_dir, context.temp_allocator) {
        append(&ids, command.id)
        append(&texts, command.text)
    }
    if len(ids) == 0 {
        return
    }
    thor_permission_open(
        thor,
        "Run this folder's language servers?",
        "From .thor/lsp.lua. Asked again when that file changes.",
        ids[:],
        texts[:],
        thor_grant_lsp_trust,
        thor_decline_lsp_trust,
        thor,
    )
}

// Allow: remembers the file as it was shown and rebuilds the client. A file
// that changed while the prompt was open is asked about again instead.
@(private = "file")
thor_grant_lsp_trust :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor.lang_reload_pending = true

    digest, has_entries := thor_lsp_workspace_digest(thor.workspace_dir)
    if !has_entries {
        return
    }
    key := strings.concatenate({thor.workspace_dir, "|", digest}, context.temp_allocator)
    if key != thor.lsp_trust_key {
        return
    }
    rows := thor_read_lsp_grants()
    thor_lsp_set_grant(&rows, thor.workspace_dir, digest)
    thor_write_lsp_grants(rows[:])
}

// Cancel: the file stays out until it changes or Thor restarts.
@(private = "file")
thor_decline_lsp_trust :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor.lsp_trust_declined = true
}

// Digest of the workspace's lsp.lua, temp-allocated. False when the file is
// absent, unreadable or names no entry.
@(private = "file")
thor_lsp_workspace_digest :: proc(workspace: string) -> (digest: string, has_entries: bool) {
    path, ok := lsp.config_workspace_path(workspace, context.temp_allocator)
    if !ok {
        return "", false
    }
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        return "", false
    }
    if len(lsp.config_workspace_commands(workspace, context.temp_allocator)) == 0 {
        return "", false
    }
    return thor_lsp_digest(data), true
}

// SHA-256 of `data` as hex, temp-allocated.
@(private)
thor_lsp_digest :: proc(data: []byte) -> string {
    sum := hash.hash(hash.Algorithm.SHA256, data, context.temp_allocator)
    return string(hex.encode(sum, context.temp_allocator))
}

// Whether `rows` allows this file in this workspace. The folder is matched
// without case, like a workspace plugin's grant.
@(private)
thor_lsp_find_grant :: proc(rows: []Lsp_Grant, workspace, digest: string) -> bool {
    if workspace == "" || digest == "" {
        return false
    }
    for row in rows {
        if row.digest == digest && thor_path_equal(row.workspace, workspace) {
            return true
        }
    }
    return false
}

// Records the allowed file of a workspace, replacing the one it allowed before.
@(private)
thor_lsp_set_grant :: proc(rows: ^[dynamic]Lsp_Grant, workspace, digest: string) {
    for &row in rows {
        if thor_path_equal(row.workspace, workspace) {
            row.digest = digest
            return
        }
    }
    append(rows, Lsp_Grant {workspace = workspace, digest = digest})
}

// The remembered answers, temp-owned. A missing or malformed file reads as none.
@(private = "file")
thor_read_lsp_grants :: proc() -> [dynamic]Lsp_Grant {
    rows := make([dynamic]Lsp_Grant, context.temp_allocator)
    data, err := os.read_entire_file(LSP_GRANTS_FILE, context.temp_allocator)
    if err != nil {
        return rows
    }
    grants: Lsp_Grants
    if uerr := json.unmarshal(data, &grants, allocator = context.temp_allocator); uerr != nil {
        log.warnf("Could not read %q: %v", LSP_GRANTS_FILE, uerr)
        return rows
    }
    append(&rows, ..grants.workspaces)
    return rows
}

@(private = "file")
thor_write_lsp_grants :: proc(rows: []Lsp_Grant) {
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }
    data, err := json.marshal(Lsp_Grants {rows}, {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal %q: %v", LSP_GRANTS_FILE, err)
        return
    }
    if werr := atomicfile.write(LSP_GRANTS_FILE, data); werr != nil {
        log.errorf("Could not write %q: %v", LSP_GRANTS_FILE, werr)
    }
}
