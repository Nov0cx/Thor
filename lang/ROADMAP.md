# Language intelligence — status & what's missing

Thor's "LSP alternative": full LSP-style features served **in-client** by native
analyzers running on worker threads, with a subprocess LSP client kept as an
*optional* fallback behind the same seam. In-client is the primary path because
it shares the buffer and tree-sitter tree by pointer — zero JSON, zero IPC,
lowest latency.

## Architecture (in place)

- `lang.odin` — the seam. `Backend` vtable (`handles`/`resolve`/`destroy`),
  `Manager` routes a `Request` by file extension to a backend on a worker
  thread, reaps `Result`s on the main thread via `manager_dispatch` (same
  mutex-guarded queue pattern as the file loader). Byte offsets are the position
  currency.
- `odin_engine.odin` — first backend, in-client Odin analyzer. Parses with the
  vendored tree-sitter grammar; resolves identifiers via the LOCALS query +
  `:=` short-decl handling; cross-file via a workspace scan.
- Editor wiring — Alt+Enter (`goto_definition` keybind) and Ctrl+Click both
  dispatch go-to-definition; results jump the caret (opening the target file if
  needed, deferring the jump until it loads).

## What works today

- **Go to definition** (Odin): local variables, `:=` short declarations,
  parameters (with correct shadowing over file scope), and cross-file top-level
  symbols. Triggered by Alt+Enter or Ctrl+Click.
- **Hover** resolution exists in the engine (returns a declaration's signature
  line) but is **not surfaced in the UI yet** — no request is dispatched and no
  popup is drawn.

---

## Missing — UI surface

- [ ] **Hover popup.** Engine returns `Hover_Info`; needs a request trigger
      (mouse dwell and/or a keybind) and a popup widget to draw the signature.
- [ ] **"No definition found" feedback.** A failed resolve is currently silent;
      should flash a status-bar / statusline message.
- [ ] **Multiple candidates.** Cross-file scan returns the *first* match; when a
      name is defined in several packages/files, offer a picker instead.
- [ ] **Loading / busy indicator** while a request is in flight
      (`manager_busy` is available).
- [ ] **Go-back / jump list.** After jumping to a definition there is no way to
      pop back to the previous location.

## Missing — engine depth (Odin native analysis)

- [ ] **Type-aware member access** (`foo.bar`, `pkg.Symbol`): resolving a
      selector requires knowing the type of `foo`. Not implemented — only bare
      identifiers resolve.
- [ ] **Package / import resolution.** `import "core:fmt"` then `fmt.println`
      isn't followed; cross-file scan is a flat name match within the workspace,
      ignoring package boundaries and `using`.
- [ ] **Type inference.** No inference for `x := f()`; hover shows the
      declaration text, not a computed type.
- [ ] **Shadowing precision.** Scope is approximated by enclosing block /
      procedure ranges, not true lexical order (a use before a `:=` in the same
      block can still resolve to it). Good enough for goto, imprecise for
      correctness-sensitive features.
- [ ] **Standard library / vendor symbols.** Only the open workspace is scanned;
      definitions in Odin's `core:`/`vendor:` collections aren't found.
- [ ] **Other LSP features not started:** references / find-usages, rename,
      document symbols / outline, workspace symbols, signature help, completion
      (semantic), diagnostics, formatting, code actions, folding, semantic
      tokens.

## Missing — scalability / performance

- [ ] **Persistent symbol index.** Every cross-file goto re-walks and re-parses
      the workspace. Replace with an index built once and updated incrementally
      on file change (invalidate by path + revision).
- [ ] **Incremental parsing.** Each request re-parses from scratch; keep a
      per-buffer tree and feed edits to tree-sitter (`ts_tree_edit`) for reuse.
- [ ] **Request coalescing / cancellation.** Rapid triggers (e.g. hover on mouse
      move) should supersede in-flight requests; there is no `$/cancel`
      equivalent yet. Debounce hover.
- [ ] **Bounded worker pool.** Each request spawns a thread; a persistent pool
      would cap concurrency and thread churn.

## Missing — the optional LSP backend

The seam supports it, but no subprocess backend exists yet. To add one:

- [ ] Long-lived child process with async stdio (a reader thread), `Content-Length`
      framing, JSON-RPC request/response id matching. (Note: `run_command` in
      `console.odin` is one-shot/blocking — a different lifecycle is needed.)
- [ ] LSP handshake (`initialize`/`initialized`, capabilities) and document sync
      (`didOpen`/`didChange` incremental, keyed off the piece-table revision).
- [ ] UTF-16 position ↔ byte offset conversion at the backend edge.
- [ ] Server lifecycle: discovery/config (reuse `ols.json`), spawn on first
      relevant file, restart on crash, shut down on exit.
- [ ] Register it *after* the Odin engine so in-client wins for `.odin` and the
      LSP covers everything else (clangd, rust-analyzer, gopls, …).

## Known limitations / cleanups

- Cross-file path matching assumes the engine's `os.read_dir` paths canonicalize
  the same way as `filepath.abs`; verify on odd path spellings.
- The vendored Odin `LOCALS` query models `:=` as `variable_declaration`, which
  this grammar does not produce — handled in `collect_short_decls`; revisit if
  the grammar is regenerated.
- Only `.odin` is handled in-client; other languages have no backend at all
  until the LSP client lands.
