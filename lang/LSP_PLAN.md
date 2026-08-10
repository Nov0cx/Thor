# External LSP backend — implementation plan

The implementation plan for `lang/lsp`, the optional subprocess LSP client
`ROADMAP.md` scopes under **The optional LSP backend**. `ROADMAP.md` stays the
status document; this file is the design, and it is superseded section by section
as each milestone lands. M0 to M7 are built; M8 and M9 are not.

Every file:line reference was checked against the tree at the time of writing.
Where the code differs from an obvious assumption, the difference is stated
rather than smoothed over.

## The seam as it stands, and the one thing it cannot do

Three facts decide the whole design.

- **`lang/lang.odin:248-254`** is the entire contract a backend satisfies:
  ```odin
  Backend :: struct {
      data:    rawptr,
      name:    string,
      handles: proc(data: rawptr, ext: string) -> bool,
      resolve: proc(data: rawptr, req: ^Request, res: ^Result),
      destroy: proc(data: rawptr),
  }
  ```
  `handles` takes **no request kind**. `resolve` is **one-shot, synchronous and
  worker-thread**. There is **no channel from a backend to the editor that is
  not a reply to a request**.
- **`lang/odin/engine.odin:64-90`** is the only implementation. `handles` is
  `return ext == ".odin"`; the engine is a plain `^Engine` behind `data`;
  `destroy` is called by `manager_destroy` (`lang.odin:925-929`) *after*
  `pool_destroy`, so no worker can be inside `resolve` when a backend is torn
  down.
- **`ROADMAP.md:858-860`** already names the blocker: *"Push-model diagnostics
  (an LSP server volunteering them between requests) would need a notification
  channel on the seam — the pull shape here fits a one-shot checker, not a live
  server."* This plan adds exactly that channel and nothing more.

The vtable comment at `lang.odin:245-247` already licenses a blocking `resolve`
("may block (parse, disk scan, **pipe read**)"), so a request/response round trip
needs no seam change. Only the unsolicited direction does.

## Package layout and what `lang/lsp` may import

A new package `lang/lsp`, a sibling of `lang/odin` exactly as `ROADMAP.md:26`
predicts.

| `lang/lsp` may import | why |
|---|---|
| `core:*`, `base:runtime` | — |
| `lang` (as `lang ".."`) | the seam types; precedent `lang/odin/engine.odin:14` |
| `shell` | the child process; precedent `lang/odin/check.odin:15` |
| `treecache` (M9 only) | `treecache.source_edit` computes the one covering replaced span an incremental `didChange` needs, on rune boundaries and with no ordering assumption (`ROADMAP.md:1141-1156`); it depends on the tree-sitter binding alone |
| **not** `setting` | `setting/setting.odin:12` imports `../lang` — importing it back is a cycle. `lang/lsp` parses its own config with `core:encoding/json`. |
| **not** `msvc` | `msvc` only locates `VsDevCmd.bat`; a language server needs no developer prompt |
| **not** `ui`, `widgets`, `thor` | upward |

Files:

```
shell/child.odin              platform-free Child_Spec + the contract comment
shell/child_windows.odin      #+build windows
shell/child_posix.odin        #+build !windows

lang/lsp/lsp.odin             Client lifetime + the lang.Backend seam (mirrors odin/engine.odin)
lang/lsp/transport.odin       Transport vtable + the child-process transport
lang/lsp/framing.odin         Content-Length framing; pure
lang/lsp/jsonrpc.odin         message build/parse, id correlation, the reader thread
lang/lsp/position.odin        UTF-16/UTF-8 <-> byte offset; pure; the risky file
lang/lsp/capability.odin      initialize result -> which lang.Request_Kind a server answers
lang/lsp/document.odin        per-document sync state (open, version, last text, line index)
lang/lsp/config.odin          settings/lsp.json + <workspace>/.thor/lsp.json
lang/lsp/server.odin          one server: spawn, handshake, restart, shutdown
lang/lsp/requests.odin        Request_Kind -> LSP method, params
lang/lsp/decode.odin          LSP payload -> lang.Result, including a server push

lang/lsp/framing_test.odin
lang/lsp/position_test.odin
lang/lsp/decode_test.odin
lang/lsp/mock_test.odin       full lifecycle against an in-process Transport
lang/lsp/config_test.odin
```

## The child process: a sibling of `shell.Session`, not `shell.Session`

`shell.Session` cannot carry a language server. Three reasons, all read from the
code:

1. **`shell/session_windows.odin:51-57` sets `hStdOutput = stdout_w` and
   `hStdError = stdout_w`**, and `shell/session_posix.odin:60-62` does the same
   with two `dup2` calls onto one pipe. Both platform files merge stderr into
   stdout on purpose, so a terminal shows them interleaved. Every language server
   writes logs to stderr. Merged, that text lands **inside the `Content-Length`
   frame stream** and desynchronises the parser permanently. This alone rules
   `Session` out.
2. `session_start :: proc(profile: Profile, cwd: string)` takes a
   `shell.Profile`, which models `Profile_Kind`, quiet `init` commands and a tab
   id. A server needs `exe + args + cwd + env overlay`, none of which `Profile`
   carries.
3. The end-marker machinery (`scan_end_marker`, `partial_marker_len`,
   `trim_prompt_tail`, `shell/session.odin:41-83`) exists to guess where output
   ends. LSP states a byte length; every heuristic is a liability.

The new abstraction belongs in `shell` and not in `lang/lsp` because
`create_kill_on_close_job` (`shell/job_windows.odin:58-59`) is `@(private)` —
package-private — so a new file in `shell` gets the Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` for free, and the POSIX side reuses the same
`setpgid(0, 0)`-in-the-forked-child pattern as `session_posix.odin:56-58`.
Elsewhere both would be duplicated.

`shell/child.odin` is platform-free and states the contract as a comment, the way
`shell/session.odin:12-28` does, because Odin has no forward declarations:

```odin
// Each platform file supplies Child and these procedures:
//     Child           :: struct { ... }
//     child_start     :: proc(spec: Child_Spec) -> (^Child, bool)
//     child_write     :: proc(c: ^Child, bytes: []u8) -> bool
//     child_read_out  :: proc(c: ^Child, buf: []u8) -> int   // blocks; 0 at EOF
//     child_read_err  :: proc(c: ^Child, buf: []u8) -> int   // blocks; 0 at EOF
//     child_close_in  :: proc(c: ^Child)                     // ends input, not the process
//     child_alive     :: proc(c: ^Child) -> bool
//     child_terminate :: proc(c: ^Child)                     // safe while a reader blocks
//     child_destroy   :: proc(c: ^Child)                     // only after both readers join
Child_Spec :: struct {
    exe:  string,
    args: []string, // borrowed for the call
    cwd:  string,
    env:  []string, // "K=V" overlay on the parent environment; empty inherits
}
```

Two-phase teardown as `Session` has it: `child_terminate`, join both readers,
`child_destroy`. Two readers, because stdout and stderr are separate pipes.

### Transport indirection

`lang/lsp` never touches `shell.Child` directly. Everything goes through a
vtable:

```odin
Transport :: struct {
    data:      rawptr,
    write:     proc(data: rawptr, bytes: []u8) -> bool,
    read_out:  proc(data: rawptr, buf: []u8) -> int, // blocks; 0 at EOF
    read_err:  proc(data: rawptr, buf: []u8) -> int,
    close:     proc(data: rawptr),                   // ends input; safe while a reader blocks
    terminate: proc(data: rawptr),                   // the kill, for a server that will not exit
    destroy:   proc(data: rawptr),
}
transport_child :: proc(spec: shell.Child_Spec) -> (Transport, bool)
```

`terminate` is what keeps `server_stop` step 6 inside the seam; without it the
server code would have to reach past the transport to `shell.child_terminate`.

This is the single most important testing decision. `mock_test.odin` supplies an
in-process transport of two `[dynamic]u8` and a `sync.Sema`, so handshake,
correlation, cancellation, deadline, EOF-mid-request and pushed diagnostics all
run on the four CI platforms with no child process, no installed server and no
display.

## Framing

`lang/lsp/framing.odin`, pure, no imports beyond `core:strings` / `core:strconv`:

```odin
// Appends "Content-Length: N\r\n\r\n" + body to `out`. N is the byte length.
frame_write :: proc(out: ^[dynamic]u8, body: []u8)

// Takes the first complete frame off the head of `buf`, copying its body into
// `allocator` and removing the whole frame. ok=false with err=.None means the
// frame has not arrived whole yet and `buf` is untouched.
frame_take :: proc(buf: ^[dynamic]u8, allocator := context.allocator) -> (body: []u8, err: Frame_Error, ok: bool)

Frame_Error :: enum { None, Bad_Header, Missing_Length, Length_Too_Large }

MAX_HEADER :: 8 * 1024
```

*As built* — the body is a copy, so it carries no lifetime rule; `MAX_HEADER`
bounds an unterminated header block; a second `Content-Length` is `.Bad_Header`;
and the length is read by a strict decimal scan, since `strconv.parse_int` would
frame `12abc` as 12.

Rules the implementation holds, each a test case:

- Headers end at the first `\r\n\r\n`. Parse `Content-Length`
  **case-insensitively**, ignore `Content-Type` and every unknown header, reject
  a header line with no `:`.
- A `Content-Length` above `MAX_FRAME :: 64 * 1024 * 1024` gives
  `.Length_Too_Large`. Never allocate on a hostile number.
- One read is not one message and a message is not one read. The
  accumulate-and-take shape is the problem `thor_terminal_consume` solves with
  `carry` / `partial_marker_len`, but an explicit length replaces the heuristic,
  so no tail is ever held back.
- The body can contain `\r\n\r\n` and the literal text `Content-Length:`. The
  parser must never rescan the body.
- Byte length, not rune count. A body with a 4-byte emoji round-trips.

## JSON

`core:encoding/json` is what the repo already uses (`lang/odin/config.odin`,
`setting/setting.odin`). Two defaults are wrong here:

- `json.parse` defaults to `spec = .JSON5` and `parse_integers = false`, so every
  number comes back as `json.Float`. A JSON-RPC `id` and every `line` /
  `character` must be exact. **Every parse in this package is
  `json.parse(data, spec = .JSON, parse_integers = true, allocator = ...)`**, and
  a shared `jsonrpc.number(v) -> (i64, bool)` still accepts `Float` defensively —
  a server may legally send `1.0`.
- `json.marshal`'s zero `Marshal_Options` already has `spec = .JSON`. Pass it
  explicitly anyway.

**Outbound** messages are typed structs with `json:"name,omitempty"` tags — they
are fixed shapes (`initialize`, `textDocument/didChange`, the position params) —
and `json.Object` trees only where the shape is genuinely open
(`initializationOptions`, `settings`, both verbatim from the user's config file).
**Inbound is always `json.Value`**: an LSP response is a union of three or four
shapes per method, and `json.unmarshal` into a fixed struct would silently zero
the variants it does not match. `lang/odin/config.odin` is the in-repo precedent
for consuming a `json.Value` with `.(json.Object)` type asserts.

**Ownership.** A parsed frame's `json.Value` lives in a per-message arena, freed
after the message. Any string that must outlive it is `strings.clone`d into the
Manager allocator by the decoder, as `lang/odin` does. Debug builds run under
`mem.Tracking_Allocator`, so every `// owned` field on `Client`, `Server` and
`Document` gets its comment and a matching free in `client_destroy`.

## Reader thread, correlation, and the push channel

One reader thread per server, plus one stderr drain thread per server, started by
`server_start` and joined by `server_stop`. Same shape and same discipline as the
terminal reader in `thor/terminal.odin`: it appends under a mutex and never
touches widgets.

```odin
Pending :: struct {
    id:    i64,
    kind:  lang.Request_Kind,
    done:  sync.Sema,  // posted by the reader
    reply: json.Value, // owned by `arena`; valid once `done` is posted
    error: Rpc_Error,
    arena: mem.Arena,  // owned; the reply's backing store, freed by the waiter
}

Server :: struct {
    // ... config, transport, state ...
    write_mutex:   sync.Mutex,           // one writer; the reader writes too (server->client replies)
    pending_mutex: sync.Mutex,
    pending:       map[i64]^Pending,     // owned
    next_id:       i64,
    notifications: [dynamic]lang.Result, // owned; filled by the reader, drained on the main thread
    notify_mutex:  sync.Mutex,
    caps:          Capabilities,         // published once, read-only after the handshake
    state:         Server_State,         // atomic
}
```

Per frame taken:

1. `frame_take`, then parse to `json.Value` in the message arena.
2. **Response** (`id`, plus `result` or `error`): look up `pending[id]` under
   `pending_mutex`, move the value into the pending arena, `sema_post(&p.done)`.
   An unknown id is logged and dropped — a cancelled request whose waiter has
   already removed and freed its `Pending`, so "absent" is normal.
3. **Server-initiated request** (`id` *and* `method`): the reader answers it
   itself. A server blocks on these.

   | method | our reply |
   |---|---|
   | `client/registerCapability`, `client/unregisterCapability` | `result: null` — accepted and ignored; v1 has no dynamic registration, and the docs say so |
   | `window/workDoneProgress/create` | `result: null` |
   | `workspace/configuration` | one entry per requested item from the server's configured `settings`, `null` when unknown |
   | `workspace/workspaceFolders` | the one workspace folder, or `null` |
   | `workspace/applyEdit` | `result: {"applied": false}` — applying needs a main-thread hop and buffer verification; refusing is honest, and M9 can route it through the push channel |
   | anything else | `error: {code: -32601, message: "unhandled"}` |

4. **Notification** (`method`, no `id`):
   - `textDocument/publishDiagnostics` decodes into
     `lang.Result{kind = .Diagnostics, ok = true, revision = <the version last
     synced for that URI>, report = {scope = <the file path>, items = ...}}` and
     appends to `notifications` under `notify_mutex`. Owned strings use the
     Manager allocator, which the client stores at construction.
   - `window/logMessage`, `window/showMessage`, `$/logTrace` reach `core:log`
     only.
   - `$/progress` is dropped in v1. M9 can drive the statusline busy indicator
     with it.
   - Unknown is logged and dropped.
5. A read returning 0 is EOF, which is the server's death. Fail **every** pending
   with `.Transport_Closed`, post each `done`, set `state = .Crashed`. Without
   this a crash hangs a pool worker until its deadline.

### How a push reaches the editor

This is the one seam change with a user-visible consequence, and it is what
`ROADMAP.md:858-860` asks for.

- `job_free` (`lang.odin:828-883`) splits: the Result-freeing half becomes
  `result_free :: proc(m: ^Manager, res: ^Result)`, and `job_free` calls it and
  then frees the Request and the Job. No behaviour change.
- `Backend` gains one optional field:
  ```odin
  // Takes the next result the backend produced without being asked (an LSP
  // server pushing diagnostics). Called on the main thread once per frame until
  // it answers false. Owned strings use the Manager allocator.
  poll: proc(data: rawptr, res: ^Result) -> bool,
  ```
  `nil` for `odin.engine_backend`, so nothing on the Odin path changes.
- `manager_dispatch` (`lang.odin:809-826`), after draining `finished`, walks the
  backends and drains each `poll`. Each pushed result is gated by
  `manager_feature_enabled(m, res.kind)` — a user who turned diagnostics off must
  not get them anyway — then handed to `handler` and freed with `result_free`.
- `res.id` is 0 for a push, so every host consumer that matches on a
  `*_request_id` slot must tolerate 0. Today only `thor_apply_diagnostics`
  (`thor/diagnostics.odin:41`) needs to, and it does not read the id.

### Why `resolve` still blocks

`resolve` runs on a pool worker and waits for its correlated reply:

```
resolve(req) ->
  ensure the server for req.ext is started and past `initialized` (bounded wait)
  sync the document for req.path from req.source          (didOpen or didChange)
  build params, allocate id, register Pending, write frame under write_mutex
  loop:
      sema_wait_with_timeout(&p.done, POLL_SLICE = 25ms)
      if posted            -> decode into `res`, done
      if request_cancelled -> send "$/cancelRequest", abandon, return
      if past deadline     -> mark the server unhealthy, return (res.ok stays false)
```

The alternative — a fire-and-forget `resolve` delivering the answer over `poll` —
is rejected. `resolve` returning at once leaves `ok == false`, and `ok == false`
is contractually "the backend found nothing" (`lang.odin:216-218`), so the host
would flash *"No definition found"* (`thor/lang_host.odin:1078`) and then jump a
second later. The push channel is for genuinely unsolicited messages only.

**The cost, stated plainly.** A blocked `resolve` holds one of `pool_size()`
workers, which is `clamp(cores/2, 2, 4)` (`lang.odin:359-361`). A wedged server
can starve the Odin engine. Four mitigations, all required:

- Hard per-request deadlines. `DEADLINE_INTERACTIVE :: 3 * time.Second`
  (definition, hover, completion, signature), `DEADLINE_HEAVY :: 15 *
  time.Second` (workspace symbols, references, rename, semantic tokens).
- A `Server.unhealthy` latch. After two consecutive deadline expiries `handles`
  returns false for that server's extensions and further `resolve`s return at
  once, until a restart succeeds. Fail fast beats fail slow.
- A per-server in-flight cap of 2. `manager_request_latest` already keeps at most
  one live job per kind (`ROADMAP.md:1182-1191`), so this only bites pathological
  cases.
- Never register LSP for `.odin` by default, so the flagship language can never
  be starved by a third-party server.

## Server lifecycle

### Discovery and spawn

`Client` — the `Backend.data` — holds `servers: [dynamic]^Server`, built from the
merged config. A `Server` is `.Idle` until something needs it. Two triggers, both
needed:

- `resolve` on a worker: an `.Idle` server for `req.ext` is started under
  `Server.start_mutex` (so two workers cannot race), waited for, then used. This
  covers every request path with zero host coupling.
- The host telling the seam a file was opened, so a freshly opened file gets
  diagnostics without anyone asking. This is the only reason a host hook exists.

**Executable lookup.** `shell.which` (`shell/profile.odin:89-107`) joins
`dir + "/" + name` and `os.is_file`s it — **it does not consult `PATHEXT`**. On
Windows `clangd` is `clangd.exe` and `typescript-language-server` is a `.cmd`
shim, so `which("clangd")` finds nothing today. Both fixes live in `lang/lsp`, so
`shell.which`'s contract does not move under the profile detectors: try `name`,
`name.exe`, `name.cmd`, `name.bat` on Windows; and when the resolved file is
`.cmd` or `.bat`, spawn it as `cmd.exe /c <path> <args...>`, because
`CreateProcessW` cannot exec a batch file. Both are a comment in the code.

### Handshake

`initialize` params, a typed struct:

- `processId` — our pid, so an orphaned server exits on its own.
- `rootUri`, `workspaceFolders` and `rootPath` (for older servers) from
  `req.workspace`.
- `clientInfo: {name: "Thor", version: <build version>}`.
- `capabilities` — advertise **only what Thor can consume**, so servers do not
  send shapes we drop:
  - `general.positionEncodings: ["utf-8", "utf-16"]`, utf-8 first: a server that
    supports it (clangd, rust-analyzer) removes the whole risky conversion.
  - `textDocument.synchronization.dynamicRegistration: false`.
  - `textDocument.completion.completionItem: {snippetSupport: false,
    documentationFormat: ["plaintext"]}` — Thor's popup inserts a plain
    identifier (`lang.Symbol.name`, `lang.odin:93-100`), so a snippet placeholder
    would be inserted literally.
  - `textDocument.hover.contentFormat: ["plaintext", "markdown"]` — the hover
    popup draws plain text.
  - `textDocument.definition.linkSupport: true`; we handle `LocationLink`.
  - `textDocument.publishDiagnostics: {relatedInformation: false,
    versionSupport: true}`.
  - `textDocument.semanticTokens` with our token-type list and
    `requests: {full: true}`. No `delta`, no `range`, in v1.
  - `textDocument.rename.prepareSupport: true`;
    `workspace.workspaceEdit: {documentChanges: true, resourceOperations: []}` —
    declaring **no** resource operations is what stops a server handing us
    `CreateFile` / `RenameFile`, which the seam cannot express.
  - `workspace.configuration: true`, `workspace.workspaceFolders: true`,
    `window.workDoneProgress: true`.
- `initializationOptions` verbatim from the config.

The reply builds an immutable `Capabilities` in `capability.odin`, published
before `state` flips to `.Ready` with `sync.atomic_store`. Then the `initialized`
notification, then `workspace/didChangeConfiguration` with the configured
`settings` when there are any.

`DEADLINE_START :: 10 * time.Second`. Expiry means `.Failed`, one `log.warnf`,
and `handles` false for that server's extensions from then on. A failed server
must not make the editor feel broken; it must simply not exist.

### Capability negotiation must reach `handles`

`Backend.handles(data, ext)` takes no kind, so it cannot express "this server
does definition but not rename". One more optional entry:

```odin
// True when this backend can actually answer `kind` for `ext`. nil means "every
// kind it claims by extension". An LSP backend answers from the server's
// advertised capabilities, so `manager_allows` can tell a caller with a fallback
// (rename -> find and replace) that the fallback is the one to run.
supports: proc(data: rawptr, ext: string, kind: Request_Kind) -> bool,
```

Wired in three places in `lang/lang.odin`, one line each: `manager_allows`
(`:441-443`, the documented "per-kind question a caller with a fallback asks"),
`manager_request` (`:459-463`, return 0 rather than dispatch work that answers
nothing) and `manager_request_debounced` (`:647-651`).

While a server is `.Starting`, `supports` returns **true** for everything it is
configured for. Otherwise the first requests after startup are silently swallowed
while the handshake runs, and the user learns that goto works only on the second
try. `resolve` blocks on the handshake and answers properly.

**Thread safety.** `handles` and `supports` are called from `backend_for`
(`lang.odin:376-383`) on the main thread only, while a worker may be inside
`resolve` mutating server state. Both must therefore read only atomically
published, immutable data: an `atomic_load` of `Server.state`, and a
`Capabilities` value written once before `state` becomes `.Ready` and never
again. **No mutex in `handles`** — `thor/state.odin:86` calls `manager_allows`
from `thor_bind_pane`, whose frequency is not traced (see Open questions).

### Document sync, and the one host hook

`didOpen` / `didChange` / `didClose` must follow the editor's file lifecycle, not
only requests, or a freshly opened file gets no diagnostics until someone hovers
it. One optional vtable entry:

```odin
// Tells a backend a buffer changed state. Main thread, must not block: a
// subprocess backend enqueues a notification and returns. `source` is borrowed.
Doc_Event :: enum { Opened, Changed, Saved, Closed }
notify: proc(data: rawptr, event: Doc_Event, path, ext, source: string, revision: u64),
```

plus `lang.manager_notify(m, event, path, ext, source, revision)`, which routes
through `backend_for` and does nothing while the gate is off.

Host wiring, four call sites:

- The load-completion path → `.Opened`. Not `thor_open_file`: before the read
  lands there is no text to send.
- `thor_close_file` → `.Closed`.
- The save-completion path → `.Saved` (`didSave`, after the bytes are on disk;
  also what the Odin engine reindexes the file on).
- A new `thor_sync_lang_documents(thor)` in the run loop, beside
  `lang.manager_dispatch` (`thor/thor.odin:534`): one pass over `thor.open_files`
  comparing `file.state.revision` against a new `file.lang_revision`, emitting
  `.Changed` for each that moved. **At most one `didChange` per file per frame**,
  which costs one `textedit.text` borrow per changed file and no main-thread
  clone beyond what the notification serialises.

v1 uses `TextDocumentSyncKind.Full` — `contentChanges: [{text: <whole buffer>}]`.
Simple, always correct, and the LF-collapsed invariant below falls straight out
of it. Incremental sync is M9: `treecache.source_edit` already produces the
single covering replaced span, pulled onto rune boundaries
(`ROADMAP.md:1146-1156`), but its output is *byte* offsets, so it needs the
position layer proven first.

`Document` per open URI:
`{uri, path, version: i64, text: string /* owned; the exact bytes we sent */,
lines: Line_Index /* owned */, open: bool}`. Keeping `text` is not optional — it
is what converts a server's line/character into a byte offset for that document
without touching disk, and what an incremental diff would need.

### Shutdown, hangs and crashes

The ordering already suits us: `manager_destroy` (`lang.odin:915-934`) cancels
everything, drains until `!manager_busy`, calls `pool_destroy` — so **no worker
can be inside `resolve`** — and only then calls each `b.destroy`. `client_destroy`
therefore runs with no worker in flight.

`server_stop`:

1. `state = .Stopping` (atomic), so `handles` stops claiming and new `resolve`s
   bail.
2. Fail every remaining `Pending` and post it.
3. Send `shutdown`, wait at most `DEADLINE_EXIT :: 2 * time.Second`.
4. Send `exit`.
5. `transport.close`. The child's stdin closes; a well-behaved server exits and
   both readers see EOF.
6. Wait up to 1s for the readers; then `child_terminate` regardless. The Job
   Object on Windows and `killpg` on POSIX take any grandchildren with them.
7. Join both reader threads, `child_destroy`, free owned state.

A server that **hangs** never reaches step 3's reply; the deadline fires and step
6 kills it. A server that **crashes** gives EOF; the reader fails all pending and
latches `.Crashed`. Restart policy: up to `RESTART_LIMIT :: 3` restarts with
`1s, 4s, 16s` backoff in a window, then `.Failed` for the session with one
`log.warnf`, and `handles` false so the editor silently reverts to no language
intelligence for those extensions. On a successful restart every open document of
that server's extensions is re-`didOpen`ed from the live buffers, which the host
loop supplies.

## Mapping every `lang.Request_Kind`

Kinds are `lang.odin:16-29`; config names are `lang/feature.odin:11-24`.

| Kind | LSP method | Capability key | Notes and lossage |
|---|---|---|---|
| `Definition` | `textDocument/definition` | `definitionProvider` | Result is `Location \| Location[] \| LocationLink[]`. One hit fills `res.location` (`lang.odin:225`); several fill `res.symbols`, which is what `thor_show_definition_candidates` (`thor/lang_host.odin:1289`, called at `:1081`) expects. `Symbol.name` is the target basename, `signature` the source line at the target (one bounded read per candidate), `kind` `"reference"` so the picker colours it like find-usages. |
| `Hover` | `textDocument/hover` | `hoverProvider` | `contents` is `MarkupContent \| MarkedString \| MarkedString[]`; all three decode. Strip fences and backticks — the popup draws text, not markdown. `Hover_Info.start/end` from `hover.range`; when absent, compute the identifier span locally around `req.offset` over `req.source`, with the character class `diagnostic_token_end` (`thor/diagnostics.odin:107-124`) uses. |
| `Document_Symbols` | `textDocument/documentSymbol` | `documentSymbolProvider` | `DocumentSymbol[]` (tree, `range` + `selectionRange`) **or** `SymbolInformation[]` (flat, `location`). Both. Flatten the tree depth-first; `Symbol.offset` from `selectionRange.start`, `line` from `range.start.line + 1`. Map the integer `SymbolKind` onto Thor's vocabulary — `"function"`, `"type"`, `"enum"`, `"constant"`, `"var"` (`lang.odin:84-92`) — so the rich picker's tinting keeps working. |
| `Workspace_Symbols` | `workspace/symbol` | `workspaceSymbolProvider` | **Impedance mismatch.** Thor opens the picker and fuzzy-filters client-side over the whole list (`ROADMAP.md:760-762`), so we send `query: ""`, and clangd and gopls return little or nothing for an empty query. A real limitation, documented rather than papered over. Fixing it needs a query field on `Request`; `new_name` is documented as "the request's argument" (`lang.odin:201`) and could be overloaded, but a new field is cleaner. |
| `References` | `textDocument/references` | `referencesProvider` | `context.includeDeclaration = false`: Thor deliberately excludes the declaration (`ROADMAP.md:788-791`). `Symbol.signature` must be the source line the usage sits on, so each distinct target file is read once through the shared `source_read` and its `Line_Index` cached for the request. |
| `Signature_Help` | `textDocument/signatureHelp` | `signatureHelpProvider` | `SignatureInformation[]` → `Signature_Entry{label, active_start, active_end}` (`lang.odin:63-67`), `Signature_Info.active` from `activeSignature`. `parameters[i].label` is **either a substring or a `[start, end]` pair in UTF-16 code units over the label string, not over the document** — both forms decode, and the offset form needs the conversion machinery pointed at the label. `thor_signature_text` (`thor/lang_host.odin:1161`) then works unchanged: an LSP overload set is just several entries. |
| `Completion` | `textDocument/completion` | `completionProvider` | `CompletionList \| CompletionItem[]`. `Symbol.name` from `insertText` when plain, else `label`; `kind` from `CompletionItemKind`; `signature` from `detail`. **Dropped, and it must be said out loud:** `textEdit` / `additionalTextEdits` (the popup inserts a word at the caret), `command`, `isIncomplete` (Thor filters client-side) and snippets (we advertise `snippetSupport: false`). `completionItem/resolve` is not called — it defers `documentation`, which the row does not show. The lossiest mapping in this table. |
| `Package_Doc` | **none** | — | No LSP equivalent; an Odin/OLS-shaped idea (`ROADMAP.md:528-544`). `supports` answers false, `manager_request` returns 0, and F3 does nothing for non-Odin files rather than flashing an error. |
| `Rename` | `textDocument/rename`, plus `textDocument/prepareRename` when advertised | `renameProvider` | Returns `WorkspaceEdit`. Three hard rules. **(a)** `lang.Text_Edit.old_text` (`lang.odin:106-112`) has no LSP counterpart, and `thor_apply_edits` refuses the whole set on a mismatch (`thor/lang_host.odin:441`), so the backend reads the current bytes at each range itself — from `req.source` for the request's own file, from `source_read` for the rest — and fills it. Skipping it turns Thor's safety check into a no-op. **(b)** If `documentChanges` carries any `CreateFile` / `RenameFile` / `DeleteFile`, refuse the whole rename (`ok = false`): the seam cannot express it, and a half-applied rename breaks a build silently. We declare `resourceOperations: []`, so a conforming server never sends them. **(c)** Sort ascending by `(path, start)` — `lang.odin:230-231` makes that a contract and the applier walks each file back-to-front on the strength of it. |
| `Diagnostics` | **inverted** — normally `textDocument/publishDiagnostics` (push); `textDocument/diagnostic` (pull) when `diagnosticProvider` is advertised | — | Push is the primary path, over the channel above. Pull is implemented too where advertised, because it maps exactly onto the existing save-driven, `EXCLUSIVE_KINDS`-serialised trigger (`thor_request_diagnostics`, `thor/diagnostics.odin:21`) and needs no new host code. `Diagnostic_Severity` is only `{Error, Warning}` (`lang.odin:160-163`): LSP `Information` and `Hint` map to `Warning`, and that coarsening is the documented intent. |
| `Code_Actions` | `textDocument/codeAction`, plus `codeAction/resolve` | `codeActionProvider` | Thor computes edits up front by design (`lang.odin:115-118`). Any returned `CodeAction` with no `edit` gets `codeAction/resolve` called **eagerly, on the same worker** (we may block); an item that still has no `edit` — a pure `command` — is **dropped**, since Thor has no `workspace/executeCommand` path. Same `old_text` reconstruction as Rename. **Gap:** `Request` carries only `offset` (`lang.odin:198`), no selection end, so we send a zero-width range at the caret and selection-scoped actions ("extract function") are unreachable. Fixing it needs a new `Request` field; out of scope for v1, named in the ROADMAP. |
| `Semantic_Tokens` | `textDocument/semanticTokens/full` | `semanticTokensProvider` | Delta-encoded 5-tuples `(deltaLine, deltaStartChar, length, tokenType, tokenModifiers)` against a server-supplied `legend`. Map legend **names** onto `lang.Token_Kind` (`lang.odin:134-143`): `parameter`→`Parameter`; `variable`→`Local`; `property`/`member`→`Field`; `function`/`method`→`Procedure`; `class`/`struct`/`interface`/`enum`/`type`/`typeParameter`/`typeAlias`→`Type`; `enumMember`→`Enum_Member`; `namespace`/`module`→`Package`. Everything else (`keyword`, `string`, `comment`, `number`, `operator`, `macro`) is **dropped**: the seam is documented as sparse, and "a token can never overrule a correct colour with a worse one" (`ROADMAP.md:916-925`). `Unresolved` is never emitted by an LSP backend — absence of a token is not proof of an undeclared name, and dimming a valid name reads as a compiler error that does not exist. This finally makes `Field` and `Enum_Member` real; `ROADMAP.md:998-1000` records them as "kept for an LSP backend, which would". Output must be ascending and non-overlapping, because `thor_overlay_spans` walks it with one forward-only cursor (`ROADMAP.md:976-983`). LSP is ascending by construction; clamp and drop overlaps defensively anyway. |

**LSP methods with no Thor kind** — named, not implemented:
`textDocument/typeDefinition`, `implementation`, `declaration`,
`documentHighlight`, `formatting` / `rangeFormatting` / `onTypeFormatting`
(`ROADMAP.md:1037` already lists formatting as not started), `foldingRange`
(Thor derives folds from tree-sitter for *every* grammar, `ROADMAP.md:763-769`,
so an LSP provider would be a regression in reach), `inlayHint`, `codeLens`,
`callHierarchy`, `typeHierarchy`, `selectionRange`, `documentLink`,
`linkedEditingRange`, `workspace/executeCommand`.

## Position encoding

### Where it lives

Entirely inside `lang/lsp/position.odin`, at the backend's own edge, exactly as
`lang.odin:31-33` specifies: *"A subprocess LSP backend converts UTF-16 positions
to bytes at its own edge."* **No offset in a `lang.Result` is ever anything but a
byte offset over LF-collapsed source.** Nothing outside `lang/lsp` learns that a
server exists.

### The two spaces, and why they differ

Thor's buffers hold source with CRLF collapsed to LF. That is the whole point of
`source_read` (today `lang/odin/ast.odin:16-28`, `@(private)`; M0 promotes it to
`lang`) and of the seam's "counted over source with CRLF collapsed to LF".

- **For a document we `didOpen` / `didChange`**, we send `req.source`, which is
  already LF-collapsed. The server's line/character space runs over *the same
  bytes we hold*, and a position converts with that document's own `Line_Index`.
  No CRLF question arises. This is why sending the buffer text — never letting
  the server read that file from disk — is load-bearing rather than an
  optimisation.
- **For a file we never opened** — a definition target, a reference hit, a rename
  edit in a closed file — the server read it from **disk**, CRLF intact, and its
  `character` counts run over the raw bytes. Conversion must then:
  1. read the file **raw** (`os.read_entire_file`, *not* `source_read`),
  2. build the line index over the raw bytes and resolve `(line, character)` to a
     **raw** byte offset,
  3. subtract the number of `"\r\n"` pairs before that raw offset to get the
     **LF-space** offset the rest of `lang` uses.

  Step 3 is exact because `source_read` replaces only the two-byte sequence
  `"\r\n"` — a lone `\r` survives collapsing and must survive the count. Getting
  this backwards is silent, off-by-one-per-line corruption in exactly the feature
  (Rename) where corruption is worst.

### The API

```odin
// Byte offsets of each line start, over one particular byte view of a file.
// Built once per document per request; the open-document one is cached and
// rebuilt only when the document's text changes.
Line_Index :: struct {
    starts:   []int,  // owned
    crlf:     []int,  // owned; "\r\n" pairs before each line start (all zero for LF text)
    text:     string, // borrowed for the index's lifetime
    encoding: Encoding,
}

Encoding :: enum { Utf16, Utf8 } // what `initialize` negotiated

line_index_build   :: proc(text: string, encoding: Encoding, allocator := context.allocator) -> Line_Index
line_index_destroy :: proc(idx: ^Line_Index)

// LSP (line, character) -> byte offset in `idx.text`. Clamps: a character past
// the line end lands on the line end, a line past EOF lands on len(text).
offset_from_position :: proc(idx: ^Line_Index, line, character: int) -> int

// The inverse, for the params we send.
position_from_offset :: proc(idx: ^Line_Index, offset: int) -> (line, character: int)

// Raw-space byte offset -> LF-space byte offset for a file read from disk.
lf_offset :: proc(idx: ^Line_Index, raw_offset: int) -> int
```

`Utf16`: walk the line from its start with `utf8.decode_rune_in_string`; each
rune costs **1** UTF-16 unit below `0x10000` and **2** at or above. Stop when the
accumulated unit count reaches `character`. A `character` landing *inside* a
surrogate pair — some servers emit these at the midpoint of an astral character —
snaps to the **rune boundary**. Never return an offset that splits a UTF-8
sequence: the piece table and every `strings` call downstream assume valid UTF-8.
`Utf8`: `character` is a byte count within the line, so the answer is
`starts[line] + character`, still clamped to the line end and still pulled back to
a rune boundary.

### How it is unit tested

`lang/lsp/position_test.odin` is pure, needs no server and runs on all four
platforms. Table-driven, both encodings, each row asserting the round trip
`position_from_offset(offset_from_position(p)) == p` where it is defined:

- ASCII baseline; several lines; empty file; no trailing newline; a trailing
  newline, so `len(starts)` is right.
- **2-byte** UTF-8: `é` (U+00E9), 2 bytes, 1 unit.
- **3-byte**: `€` (U+20AC) and `漢`, 3 bytes, 1 unit.
- **4-byte / astral**: `😀` (U+1F600) and `𝄞` (U+1D11E), 4 bytes, **2** units. A
  line that is only an astral character. Two astral characters in a row. An
  astral character followed by ASCII, asserting the ASCII position — the case
  that catches a `+1` where `+2` belongs.
- A `character` at the midpoint of a surrogate pair snaps to the rune start, and
  the returned offset is a valid UTF-8 boundary.
- `character` past the line end clamps to the line end, not into the next line.
- `line` past EOF clamps to `len(text)`.
- **CRLF**: a `\r\n` file, converted in raw space, then `lf_offset` matching the
  offset `source_read` would produce for the same logical spot — asserted against
  a literal computed by actually collapsing the text in the test, so the test
  cannot inherit the implementation's bug.
- A **lone `\r`** not followed by `\n`: not collapsed, and not a new line in the
  LF-space count.
- Mixed CRLF and LF in one file.
- A UTF-8 BOM at the start. Some servers count it and some do not; pin whichever
  we choose and comment why.
- SignatureHelp's `[start, end]` label offsets through the same converter over a
  label containing an astral character.

Plus, in `decode_test.odin`, one end-to-end row per request kind whose fixture
payload has a multi-byte character before the position, so a regression in the
converter fails a *feature* test and not only a unit test.

## Configuration

### Files and layering

Mirrors the existing convention: global `settings/*.json` beside the binary,
overlaid by the workspace's `.thor/`, and follows `odin-analyzer.json`'s
precedent of being Thor's own file rather than the ecosystem's
(`ROADMAP.md:473-477`).

- **`settings/lsp.json`** — shipped beside the binary, staged by `build.odin`
  like the rest of `settings/`. The out-of-the-box server table.
- **`<workspace>/.thor/lsp.json`** — overlays it. A workspace entry with the same
  `id` replaces the shipped one field by field; a new `id` adds a server;
  `"enabled": false` removes one.

Read by `lang/lsp/config.odin` with `core:encoding/json`, stat-cached and
invalidated exactly like `config_ensure` (`lang/odin/config.odin:58-94`) —
`workspace` + `modtime` + `size`, a missing or malformed file still caching the
defaults so a miss is not re-parsed per request, unknown keys ignored so the file
can carry settings a later version acts on. It cannot use `setting`, which
imports `lang` (`setting/setting.odin:12`).

### Schema

```jsonc
{
  "servers": [
    {
      "id": "clangd",                                  // stable key; workspace entries match on it
      "extensions": [".c", ".h", ".cpp", ".hpp", ".cc", ".hh", ".cxx"],
      "command": ["clangd", "--background-index"],     // [0] resolved on PATH when not absolute
      "cwd": "",                                       // default: the workspace root
      "env": { "CLANGD_FLAGS": "..." },                // overlay on the parent environment
      "root_markers": ["compile_commands.json", ".clangd", ".git"],
      "initialization_options": { },                   // verbatim into `initialize`
      "settings": { },                                 // verbatim into didChangeConfiguration / workspace/configuration
      "features": { "rename": false },                 // per-kind opt-out, lang.feature_name spelling
      "enabled": true,
      "override": false                                // true = register ahead of the native Odin engine
    }
  ]
}
```

`features` reuses `lang.feature_from_name` (`lang/feature.odin:32-39`), so the
vocabulary is identical to `settings.json`'s `language_intelligence` object and
to `odin-analyzer.json`'s toggles. No third spelling.

### Shipped defaults

`settings/lsp.json` ships a table of well-known servers, each `"enabled": true`
but **only activated when its executable is found** by the PATHEXT-aware lookup.
Zero configuration when a server is installed; zero cost and zero noise when it
is not — one `log.debugf` per absent server at startup, never a dialog.

Proposed initial table: `clangd` (C/C++), `rust-analyzer`, `gopls`,
`pyright-langserver` or `ruff` (Python), `typescript-language-server` (JS/TS),
`lua-language-server`, `zls` (Zig). `jdtls` is omitted: it needs a workspace-data
directory, not a one-liner.

**`ols` is deliberately absent.** `.odin` is served in-client — that is the
project's thesis — and the in-client engine is both faster and better integrated.
A user who wants OLS adds it in `.thor/lsp.json` with `"override": true`.

### Interaction with the existing gates

Three layers, all AND-ed, none replacing another — the same rule as
`ROADMAP.md:507-511`:

1. **`settings.json` `language_intelligence`**, the master switch plus per-kind
   rows (`setting/setting.odin:641-664`), enforced on the `Manager` through
   `manager_set_enabled` / `manager_set_features`. It covers the LSP backend for
   free: `manager_request` refuses the kind, `manager_cancel_kind` stops
   in-flight work, and the new push channel is gated the same way inside
   `manager_dispatch`. No new code in the settings UI or in
   `thor_apply_language_settings`.
2. **`lsp.json` `features`** per server, enforced inside `supports`.
3. **The server's advertised capabilities**, also inside `supports`.

A kind runs only when all three allow it. `.thor/settings.json` can still carry
`language_intelligence` per workspace, which remains the per-folder way to gate a
kind a server offers no toggle for.

## Coexistence with the native Odin backend

`manager_register` documents registration order as priority, and `backend_for`
(`lang.odin:376-383`) returns the **first** backend whose `handles` answers true.
Precedence is therefore decided entirely at `thor/thor.odin:432-436`, which
already anticipates it:

```odin
// Language intelligence: register the in-client Odin engine first so it wins
// for .odin files; an optional LSP subprocess backend would register after it.
```

**Default:** `odin.engine_backend` first, `lsp.client_backend` second. The native
engine wins `.odin`; the LSP client covers everything else. The LSP client also
declines any extension the Odin engine claims — belt and braces, because
`backend_for` already prevents it, and because a `.odin` server left running
would consume memory for nothing.

**Override:** a workspace `lsp.json` entry with `"override": true` for `.odin`.
The decision is taken **once, in the host, at init**, by reading the merged config
before registering and swapping the order — both registrations are the same eight
lines. No seam change, no per-request branching, and precedence stays a property
of registration order exactly as documented. When two LSP servers claim one
extension the first in the merged list wins and the second logs one warning.

A consequence worth stating: because `backend_for` is all-or-nothing per
extension, a user who overrides `.odin` loses `Package_Doc` (F3) and the whole
`odin-analyzer.json` collection mechanism. That is the honest trade, and it
belongs in `docs/configuration.md` rather than buried here.

## Testing

**Constraint:** four CI platforms (`windows`, `ubuntu`, `arch`, `macos`), no
display, and **no installed language server**. Everything below is hermetic.

### `lang/lsp`

- `framing_test.odin` — every rule above. Notably: feed one known frame **one
  byte at a time** and assert `frame_take` yields it exactly once, at the right
  byte; three frames in one chunk; a body containing `\r\n\r\n` and the literal
  `Content-Length: 9`; an unknown extra header; a `Content-Length` of `0`, of
  `-1`, of `999999999999`; a UTF-8 body whose byte length exceeds its rune count.
  Plus a `json.marshal` / `json.parse` round trip over control characters,
  U+00A1..U+00FF, U+FFFD and an astral character, pinning the escaping the design
  assumes.
- `position_test.odin` — the whole table above. **The most important test file in
  this work.**
- `decode_test.odin` — fixture payloads as string literals in the test, so
  nothing depends on the working directory: `Location`, `Location[]`,
  `LocationLink[]`; hover `MarkupContent` / `MarkedString` / `MarkedString[]`;
  `DocumentSymbol` tree against `SymbolInformation[]`; `WorkspaceEdit.changes`
  against `.documentChanges`; a `WorkspaceEdit` carrying a `CreateFile`,
  asserting the whole rename is refused; semantic-token delta decoding including
  a line with no tokens; `publishDiagnostics`; `signatureHelp` with string and
  with `[start, end]` parameter labels; a `CompletionList` with `isIncomplete`.
  Plus a malformed variant of each — missing field, wrong type, `null` where an
  object was expected, an empty array, a negative line — each producing
  `ok = false` and leaking nothing.
- `config_test.odin` — parsing; workspace-over-global layering by `id`;
  `"enabled": false` removal; unknown keys ignored; a server whose command
  resolves to nothing being dropped; `features` names round-tripping through
  `lang.feature_from_name`.
- `mock_test.odin` — the payoff of the `Transport` vtable. An in-process
  transport of two `[dynamic]u8` and a `sync.Sema` plays a scripted server.
  Covers: the full `initialize` / `initialized` handshake and capability →
  `supports` mapping; a `Definition` round trip through the real `resolve` on a
  real `Manager` with a real pool; `$/cancelRequest` emitted when the request is
  cancelled mid-flight, reusing the parked-backend trick from
  `lang/lang_test.odin:26-38`; a server that never replies hitting the deadline
  and leaving `ok == false`; EOF mid-request failing the pending without hanging;
  a `workspace/configuration` server→client request being answered; a pushed
  `publishDiagnostics` landing in the notification queue and reaching a handler
  through `manager_dispatch`.

### `lang` — the seam changes

Extend `lang/lang_test.odin`'s `Probe` backend with `supports` and `poll`: a
pushed result reaches the handler and is freed cleanly under the tracking
allocator; a pushed result of a gated kind is dropped; `supports` returning false
makes `manager_request`, `manager_request_debounced` and `manager_allows` all
answer no.

### `thor` — host changes

`thor_apply_diagnostics` with a **file-path** `scope` (see M0);
`thor_sync_lang_documents` emitting exactly one `.Changed` per changed file per
pass and none for unchanged ones.

### `shell` — the child process

`shell/child_test.odin` spawns something guaranteed present: on Windows
`cmd.exe /c echo hi` and `cmd.exe /c echo err 1>&2`, on POSIX `/bin/sh -c`. It
asserts stdout and stderr arrive on **separate** pipes and never interleave —
the property the whole design rests on. This is lower risk than it looks:
`shell/run_test.odin` already spawns real processes (`ping -n 20 127.0.0.1` on
Windows, `sleep 20` elsewhere) on all four runners today.

### `run_tests`

`build.odin:135-149` — add `"lang/lsp"` to the `packages` list, or CI skips the
package entirely. The slash needs no extra work: `:158` flattens it to
`bin/test/lang_lsp`. `shell` is already in the list. Then run the `verify` skill:
per-package check, `odin check main -target:linux_amd64` and
`-target:darwin_arm64` expecting only the two documented noise panics, then
`build.odin -- test`.

## Documentation to update

- **`lang/ROADMAP.md`** — replace **Missing — the optional LSP backend**
  (`:1267-1282`) with an "Architecture (in place)" entry describing `lang/lsp`,
  split by concern the way the `lang/odin` entry is (`:24-41`), and keep a
  shortened list of what is genuinely still missing: the workspace-symbol query,
  selection-scoped code actions, incremental sync, `full/delta` semantic tokens,
  `workspace/applyEdit`, dynamic registration, formatting. Update the Diagnostics
  note at `:858-860` (the notification channel it asks for now exists), the
  semantic-tokens **Still open** at `:998-1000` (`Enum_Member` and `Field` are
  now emitted), and the known limitation at `:1295-1296` ("other languages have
  no backend at all until the LSP client lands"). Add the new limitations
  honestly: what `Completion` drops, the empty workspace-symbol query,
  `Package_Doc` having no LSP equivalent, code actions being caret-only, resource
  operations refused.
- **`CLAUDE.md`** — a `lang/lsp` bullet beside the `lang/odin` one, naming the
  split, the blocking-`resolve`-plus-push-channel rule and the byte-offset edge;
  `shell/child_*` added to the platform-split pairs; one line in Terminals on why
  the LSP client uses a sibling child abstraction rather than `shell.Session`;
  `settings/lsp.json` and `.thor/lsp.json` under runtime configuration; one line
  in Async work, since the push channel is the first exception to "worker
  appends, main thread drains".
- **`docs/configuration.md`** — a `.thor/lsp.json` bullet beside
  `odin-analyzer.json` (`:65-68`) with the schema and an example; a short section
  on the shipped defaults, on installing a server, and on `"override": true` for
  `.odin` and what it costs.
- **`docs/getting-started.md`** — one paragraph: install a server, restart, it
  works.
- **`README.md:13`** — "an in-client Odin language server" becomes "... and
  optional external LSP servers for other languages".
- **`.claude/agents/layering-reviewer.md`** — add `lang/lsp` with its permitted
  edges (`lang`, `shell`, later `treecache`) and the explicit **must not import
  `setting`** note, since that cycle is not obvious.

Then run the `update-docs` skill so `docs/html/` is regenerated.

## Milestones

Each is an independently verifiable checkpoint: it compiles on all four targets,
its tests pass, and nothing regresses.

- [x] **M0 — Seam preparation. No LSP code at all.** `source_read` promoted from
      `lang/odin/ast.odin:16-28` (where it is `@(private)`) to `lang`, with
      `odin.source_read` reduced to a one-line wrapper so the call sites in
      `lang/odin` do not move. `Backend.supports`, `Backend.poll` and
      `Backend.notify` added as optional fields. `result_free` extracted from
      `job_free`. `manager_dispatch` drains `poll` with the feature gate applied.
      `manager_notify` added. `thor_apply_diagnostics` taught that
      `Diagnostic_Report.scope` may be a **file** path — today `file_in_dir`
      (`thor/diagnostics.odin:131-136`) compares `filepath.dir(path)` against
      `dir` and would silently never clear a file-scoped report — and that a
      pushed report applies when `res.revision` matches the live buffer, where
      today `thor_apply_diagnostic` (`:71-78`) skips any file whose revision
      differs from `saved_revision`, which is right for `odin check` and wrong for
      a server checking the *unsaved* text we sent it. New `lang` tests for
      `supports` and `poll`.
      *Checkpoint: everything builds, every existing test passes, zero
      user-visible change.*

      **As built, three points differ from the text above.** (a) The revision rule
      is a *disjunction*, not a swap: a report applies when `res.revision` matches
      the live buffer **or** the buffer still matches disk. A straight swap would
      break the Odin path — a package check reports many files under the single
      revision of the file whose save triggered it, so the disk test is what keeps
      every other file's squiggles. (b) `manager_notify` landed with no host call
      site; the four in `thor/files.odin` and the per-frame sweep moved wholly to
      M4, where a backend acts on them. (c) `backend_for_kind` also gates
      `dispatch_owned`, so a debounce slot filled while a kind was supported
      cannot dispatch after the backend stops claiming it. The `poll` drain is
      capped at `POLL_MAX_PER_FRAME` per backend, so a backend whose queue never
      runs dry costs latency and not the frame.

      Open questions 1 and 3 are settled. **Q1:** `thor_bind_pane` is
      event-driven, not per-frame — its eleven call sites are pane switches, file
      open/close, workspace change and jump-to-definition — so `supports` is not
      on a hot path. The lock-free rule stands on thread safety, not frequency.
      **Q3:** `file_in_dir` had no second consumer, so the fix stayed inside
      `thor/diagnostics.odin`; it is now `scope_covers`.
- [x] **M1 — Process and transport, no LSP semantics.** `shell/child*.odin`;
      `lang/lsp/transport.odin` and `framing.odin`; the package added to
      `run_tests`.
      *Checkpoint: `odin test lang/lsp` passes the framing tests and a mock echo
      round trip; both cross-checks clean.*

      **As built, six points differ from the text above.** (a) `frame_take` takes
      an allocator and returns a **copy** of the body. The designed signature
      both returned a slice of `buf` and removed the frame from it, and the
      removal memmoves over the bytes the slice points at; the copy costs one
      memcpy of a body about to become a much larger JSON tree, on a reader
      thread, and in exchange the body carries no lifetime rule. In M2 the
      allocator is the per-message arena, so body and `json.Value` die together.
      (b) `MAX_HEADER :: 8 * 1024` added — the design bounds the body but not the
      header, so a server that never sends `\r\n\r\n` would grow the read buffer
      without end. (c) `frame_take` refuses a **second** `Content-Length` as
      `.Bad_Header`, and parses the value with its own strict decimal scan rather
      than `strconv.parse_int`, which stops at the first non-digit and would
      frame `12abc` as 12. On any error `buf` is left untouched and the stream
      cannot resynchronise, so the caller kills the server. (d) `Transport` gained
      `terminate` beside `close`: `close` ends the server's input, which is
      `server_stop` step 5, and `terminate` is the kill in step 6 — the design
      called `child_terminate` there directly, which would have broken its own
      rule that `lang/lsp` never touches `shell.Child`. `child_close_in` is the
      matching addition to the child contract. (e) `child_start` reports a program
      that could not be started on **both** platforms. A fork cannot fail, so the
      POSIX side carries the exec's errno back over a pipe of its own whose write
      end is `FD_CLOEXEC`; a successful exec closes it and the parent's read ends
      with nothing. Without it a missing server binary would read as a server that
      started and died at once. (f) `child_alive` uses
      `waitpid(pid, &status, {.NOHANG})` with a `reaped` latch on POSIX, not
      `kill(pid, .NONE)`: the kill reaches a zombie too, so it would call an exited
      server live. `thor/windows_posix.odin:25` can use `kill` because it probes a
      foreign pid.

      **Open question 2 is settled.** `json.marshal`'s strict-JSON escaping was
      pinned by a round trip in `framing_test.odin` over control characters,
      U+00A1..U+00FF, U+FFFD and astral characters: every one comes back
      unchanged, so `jsonrpc.odin` may send buffer text as-is.

      Because nothing imports `lang/lsp` yet, `odin check main -target:...` does
      not reach it. `lang/lsp` and `shell` are cross-checked directly instead, and
      neither pulls in `vendor/stb` or the HarfBuzz binding, so unlike the `main`
      cross-checks both come back with **no output at all** — there is no expected
      noise to filter here.
- [x] **M2 — JSON-RPC client core.** Reader thread, id correlation, `Pending` and
      deadlines, `$/cancelRequest`, the notification queue, the server→client
      request replies.
      *Checkpoint: `mock_test.odin` covers handshake, request/response,
      notification, timeout, EOF and cancel, with no process.*

      **As built, five points differ from the text above.** (a) The correlation
      state lives on a new `Conn`, not on `Server`, because `server.odin` is M4's
      file. A `Conn` is one JSON-RPC connection over a `Transport`: the two
      threads, the pending map, the notification queue, the write mutex and the
      state. M4's `Server` owns a `Conn` and adds the config, the capabilities and
      the restart policy. (b) `Pending` has no arena. A `virtual.Arena` commits
      1 MB per block and allocates outside the debug `mem.Tracking_Allocator`,
      which is where this repo finds its leaks; one parse into `conn.allocator`
      plus `json.destroy_value` costs the same one parse per message, stays inside
      the tracking allocator, and gives replies and notifications one free path.
      The `result` and the `params` are **detached** from the parsed tree — the
      member is set to nil before the rest is freed — so the value handed over
      needs no clone. (c) Envelopes are assembled from parts with `params` as JSON
      **text**, not marshalled from a struct: `json.marshal` has no `json.Value`
      case, so no envelope struct can carry an open `params`. Each caller
      marshals its own typed params and hands over the text, which also passes
      `initializationOptions` and `settings` through verbatim. (d) A `.Server_Error`
      hands the server's **error object** back in place of the result, rather than
      only its code, so the caller logs the message too. (e) `conn_call` takes the
      `cancel: ^bool` directly, so `jsonrpc.odin` imports no `lang` and the whole
      layer is protocol plus threads; M5's `resolve` re-attaches it to the seam.

      `workspace/configuration` answers `null` per requested item and
      `workspace/workspaceFolders` answers `null`: both need the server config M2
      does not have, and M4 fills them in. The stderr drain keeps a bounded 8 KB
      tail instead of logging per line — `lang/` logs nowhere today, and the
      logger's thread safety is not this milestone's question; M4 reads the tail
      when a handshake fails, which is when a server's log is wanted.

      **M1's `Mock` needed one fix.** Its single `ready` semaphore loses a wakeup
      once two reader threads wait on it: the thread that takes the post can be
      the one whose stream did not grow, and the other never wakes. It now has one
      semaphore per readable stream.
- [x] **M3 — Position conversion. THE RISKIEST MILESTONE.** `position.odin` and
      the full `position_test.odin` table.
      *Checkpoint: green on Windows, Ubuntu, Arch and macOS.*

      **As built, one point differs.** `Line_Index` carries the allocator it was
      built with, so `line_index_destroy` frees `starts` and `crlf` with the one
      that made them; the fixed API above has no way to pass it back in. Every
      other rule of the section holds, and the table is covered by 13 tests: the
      CRLF rows compute their expectation with their own `strings.replace_all`,
      so the test cannot inherit the implementation's bug.

      **Why it is the riskiest:** it is the only part where a bug is *silent and
      destructive*. A framing bug hangs, a capability bug disables a feature, a
      lifecycle bug logs — all visible. An off-by-one in UTF-16 accounting
      produces a `Text_Edit` off by one byte in a file the user never opened, and
      `Rename` and `Code_Actions` write it. The `old_text` check in
      `thor_apply_edits` (`thor/lang_host.odin:441`) is the backstop and it is a
      good one, but it turns silent corruption into a silently *refused* rename,
      which is its own failure. Hence: pure, table-driven, both encodings, tested
      before a single feature is wired, and asserted again end-to-end in
      `decode_test.odin`. Second-riskiest is M4's blocking `resolve` on a pool of
      2–4 workers; the deadline, the unhealthy latch and never claiming `.odin`
      are the three things that keep a bad server from taking the editor with it.
- [x] **M4 — Lifecycle and configuration.** `config.odin`; discovery with the
      PATHEXT-aware lookup; spawn; `initialize` / `initialized`; `Capabilities` →
      `supports`; full-text document sync driven by `manager_notify` and
      `thor_sync_lang_documents`; `shutdown` / `exit` / kill; crash restart with
      backoff; `client_backend` registered in `thor/thor.odin` after the Odin
      engine, or before it on `"override"`.
      *Checkpoint: with clangd installed on the dev machine, opening a `.c` file
      completes the handshake and the log shows the capabilities. No feature is
      wired yet, and the editor behaves exactly as before for every other file.*

      **As built, six points differ.** (a) There is **no `Config_Cache`**. The
      stat-keyed cache the text asks for cannot be read from `handles`/`supports`,
      which run on the main thread and must not lock, so the merged table is read
      once in `client_create` and the servers are built from it there. The cost is
      that a workspace change does not re-read `lsp.json` or restart a server;
      M6's reload does that. (b) **One pump thread per server** does spawn,
      handshake, outbox drain and restart. The plan left the owner of the outgoing
      notifications unnamed, and this is the answer: `notify` on the main thread
      only queues, worker `conn_call`s still write directly under
      `Conn.write_mutex`. (c) **`poll` stays nil.** Nothing above consumes a push
      until M6, but `Conn.notifications` still has to be emptied or a server that
      publishes diagnostics on every keystroke grows it without bound — so the
      pump drains and drops them. A main-thread drain would read `conn` while a
      restart replaces it. (d) `conn_start` gained a `Conn_Answers` parameter, two
      borrowed JSON texts the reader thread answers `workspace/configuration` and
      `workspace/workspaceFolders` from. (e) `Server` carries an `open` procedure
      and `open_data`, which a test replaces with a scripted in-process server —
      that is what makes the whole lifetime testable with no language server
      installed on any of the four runners. (f) The server's **root is found on
      the pump**, not in `server_start`: it stats every configured marker up every
      ancestor directory, which the main thread must not wait for.

      Three faults the ownership review found were fixed here, not deferred: the
      pump frees its own temp arena (`core:thread` frees one only for a thread it
      gave the default context to); `caps` is decoded from the first handshake
      only, so a restart cannot write what `supports` reads unlocked; and
      `server_ensure_started` gives up on a cancelled request instead of holding
      the pool open for the whole start deadline.
- [x] **M5 — Read-only features.** `Definition`, `Hover`, `Document_Symbols`,
      `References`, `Signature_Help`, `Completion`, `Semantic_Tokens`.
      *Checkpoint: Alt+Enter, Ctrl+hover, Ctrl+Shift+O, F10, Ctrl+Shift+Space,
      typing-completion and semantic colours all work in a C or Rust file. This
      is the milestone where the goal is met.*

      `lang/lsp/requests.odin` is the mapping and the round trip — `METHODS`,
      the three param shapes, `DEADLINE_INTERACTIVE :: 3s` for the kinds drawn
      while the user types and `DEADLINE_HEAVY :: 15s` for the whole-file ones.
      `lang/lsp/decode.odin` is one decoder per kind, exactly as the table above
      specifies. No change to `lang/lang.odin`: the seam already had everything.

      **As built, four points differ from the text above.** (a) **A request syncs
      its own document first.** Document sync is push-only and drained by the
      pump on its own schedule, so a worker had no guarantee the server held
      `req.source` — a position against the previous revision is silent
      corruption of exactly the kind the position layer exists to prevent.
      `server_sync_document` publishes the request's text on the worker thread
      before any params are built. `Document` gained `revision`, the editor
      revision its text came from; it is monotonic per file, so
      `server_publish` drops an older event and the pump can never put stale
      text back after a request overtook it. (b) **Two locks landed on
      `Server`.** `docs_mutex` is the one the `docs` comment already anticipated.
      `conn_lock`, an `RW_Mutex`, is new and load-bearing: before M5 no worker
      touched `conn`, and a restart frees it, so a request now holds it shared
      for the whole round trip and the pump takes it outright to swap. A worker
      takes `conn_lock` first and `docs_mutex` second, and nothing takes them the
      other way round. (c) **The semantic-token legend is decoded into
      `Capabilities`** as `token_legend`, an owned array indexed by the server's
      own `tokenTypes`, with `valid = false` for every name Thor drops.
      `capabilities_decode` therefore takes an allocator and
      `capabilities_destroy` frees it. (d) A position in a file the editor never
      opened is resolved three ways in order of exactness — the request's own
      buffer, a document this server already holds, then the raw disk bytes with
      the CRLF step. The raw index and the LF-collapsed text of each file are
      cached per request on `Ask`, so a hundred references in one file cost one
      read of it.
- [x] **M6 — Diagnostics.** Push through `publishDiagnostics` over the M0
      channel; pull through `textDocument/diagnostic` where advertised. Plus
      `Workspace_Symbols` with its documented empty-query caveat.
      *Checkpoint: squiggles and gutter markers appear in a non-Odin file as it is
      edited, and the existing explained-diagnostic hover (`ROADMAP.md:279-289`)
      works on them unchanged.*
      **As built**, five deviations. (a) **No `notify.odin`.** Notification
      handling stayed where M0 put it: `jsonrpc.odin` queues the raw
      `Notification`, `server_drain_pushes` decodes it, `decode.odin` holds the
      decoder. (b) **The push queue is per-`Server`, not per-`Client`.**
      `push_mutex` + `pushes` sit beside `docs`, and `Client.poll` walks the
      servers. `push_mutex` is independent of the other two locks and is never
      held with either, so the M5 lock order is untouched. It also means
      `server_destroy` frees the results nobody took, with the server's allocator
      — which must be the Manager's, since `lang.result_free` frees the delivered
      ones with that. (c) **`Workspace_Symbols` reuses
      `decode_document_symbols` verbatim.** `workspace/symbol` answers the flat
      `SymbolInformation[]` shape that decoder's flat branch already reads; a
      range-less `WorkspaceSymbol` is dropped by the existing check, which is
      right because Thor never declares `resolveSupport`. No `Request` field was
      added for the query (open question 5). (d) **No host change for either
      kind.** `thor_apply_diagnostics` already ignored `Result.id` and already
      gated on the right disjunction, so getting `Result.revision` from
      `Document.revision` was the whole of it (open question 4). (e) **One host
      bug fixed.** `thor_request_diagnostics` sent an empty `source`, which was
      right for a compiler reading the package off disk and wrong for a server:
      `server_sync_document` would have published the empty buffer whenever the
      request overtook the pump's queued `didChange`, and the pull decoder would
      have counted every position over an empty line index. It now sends the
      buffer, like every other kind.
- [x] **M7 — Mutating features.** `Rename` with `old_text` reconstruction and the
      resource-operation refusal; `Code_Actions` with eager `codeAction/resolve`
      and command-only items dropped.
      *Checkpoint: Ctrl+R renames across files in a Rust workspace as one undo
      entry per open buffer, and refuses cleanly when anything does not verify.*

      **As built, four points differ from the text above.** (a) **No
      `json.marshal` round trip.** The spec needs a `CodeAction` echoed back
      verbatim to `codeAction/resolve`, and `core:encoding/json`'s `marshal` has
      no `json.Value` case (`jsonrpc_test.odin:9`), so the already-existing
      `json_text` helper (`config.odin`, built for `initializationOptions`) does
      the re-serialization instead — it wraps `json.unparse`, which does accept a
      `json.Value`. (b) **`ask_source` gained a third source.** It answered only
      the request's own buffer or disk, while `resolve_range` already checked a
      server-held open document first. A rename or code action touching a second
      open file failed `old_text` verification against a stale (or, in a test, a
      nonexistent) copy on disk; `server_document_text` (`server.odin`) clones a
      held document's text under `docs_mutex`, and `ask_source` now tries it
      before falling back to disk. This is a correctness fix the milestone's own
      checkpoint requires — "one undo entry per open buffer" only holds if the
      buffer's real text is what gets verified. (c) **Two host bugs fixed
      alongside, not deferred.** `thor_code_actions` (`thor/codeactions.odin`)
      gated Ctrl+. on `manager_supports` instead of `manager_allows(ext,
      .Code_Actions)`, unlike `thor_rename_symbol`'s existing gate — a backend
      that declined code actions specifically went silently unnoticed instead of
      doing nothing. `thor_edit_target` (`thor/lang_host.odin`) matched an open
      buffer with an exact string compare instead of `thor_same_path`, so a
      case- or separator-different path from a server's URI missed the open tab
      and fell through to a disk overwrite of possibly-unsaved content. (d)
      **`isPreferred` ordering** builds two `context.temp_allocator` lists
      (preferred, rest) and appends them in order, exactly the alternative the
      plan named as equally acceptable to a shift-based `inject_at`.
- [x] **M8 — Documentation.** `ROADMAP.md`'s optional-LSP-backend section
      brought current with M7 (Rename/Code Actions moved out of "still
      missing"); `CLAUDE.md` gained the `shell/child_*` rationale in
      Terminals and the `Backend.poll` exception in Async work;
      `.claude/agents/layering-reviewer.md` gained `lang/lsp` in the layering
      diagram, the must-not-import-`setting` note and `shell/child_*` in the
      platform pairs; `docs/getting-started.md` gained a paragraph on
      installing a server; `docs/configuration.md` gained the cost of
      `"override": true` for `.odin`; `CHANGELOG.md`'s LSP bullet gained
      rename and code actions. `update-docs` regenerated `docs/html/`.
- [ ] **M9 — Optional follow-ups, each independent.**
      - [ ] Re-read `settings/lsp.json` + `.thor/lsp.json` and restart the
            servers when the workspace changes — today read once, in
            `client_create`.
      - [ ] Incremental `didChange` through `treecache.source_edit`.
      - [ ] A real `workspace/symbol` query, via a `query` field on `Request`.
      - [ ] `semanticTokens/full/delta`.
      - [ ] `$/progress` into the existing statusline busy indicator.
      - [ ] `workspace/applyEdit` routed through the push channel.
      - [ ] A selection range on `Request`, unlocking selection-scoped code
            actions.

## Open questions

1. **How often `thor_bind_pane` runs.** It calls `manager_allows`
   (`thor/state.odin:86`), which will now call `supports`. Its frequency is not
   traced. If it is per-frame, `supports` must stay lock-free — the
   atomic-snapshot design above assumes it must. Verify before anyone adds a
   mutex there.
2. **`json.marshal`'s strict-JSON safety for arbitrary buffer text.**
   `io.write_escaped_rune`'s `for_json` path reads correct — control characters
   as `\u00XX`, astral as surrogate pairs, U+00A1..U+00FF as raw UTF-8 — but that
   is inference from reading, not from running. Pin it with the round-trip test
   in M1.
3. **`Diagnostic_Report.scope` as a file path.** The doc comment
   (`lang.odin:184-187`) says "absolute directory or file path", but
   `thor_apply_diagnostics`'s helper implements only the directory case. This
   looks like a real gap; M0 fixes it, and it is worth confirming there is no
   second consumer.
4. ~~**Whether pushed diagnostics should apply against an unsaved buffer.**~~
   Settled in M6: no change was needed. The gate is already the disjunction
   `revision != file.state.revision && file.state.revision !=
   file.saved_revision`, which passes when the report's revision matches the live
   buffer (a server checking the text we sent) *or* when the buffer still matches
   disk (a compiler checking the file). The backend only has to stamp
   `Result.revision` from `Document.revision`.
5. ~~**Whether `workspace/symbol` is usable at all with an empty query.**~~
   Settled in M6 as planned: `query: ""` ships, and the ROADMAP names the
   limitation rather than listing the feature as working. Still open in practice
   — no measurement of what the major servers answer an empty query with. A real
   query needs a prompt above the seam and a field on `Request`.
