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
  symbols. Triggered by Alt+Enter or Ctrl+Click. When a name is declared at
  top-level in several workspace files (the flat cross-file match ignores
  package boundaries), the jump offers a picker of all candidates instead of
  silently taking the first; a single match jumps straight there.
- **Package-qualified go-to-definition & hover** (`pkg.Symbol`): the operand is
  matched against the file's imports and resolved in that package's directory.
  Relative imports (`import "../lib"`, `import "sub"`) resolve fully in-workspace;
  `core:`/`vendor:`/`base:` collections resolve against the standard library out
  of the box (the compiler's baked-in `ODIN_ROOT`; the `ODIN_ROOT` env var
  overrides it to point at another toolchain). So `fmt.println`, `strings.split`
  and friends go-to-def and hover into the stdlib sources. The
  caret on the package name itself jumps to the file named like the package
  (`foo/foo.odin`), falling back to the `.odin` file whose name is fuzzily closest
  to the package name when there is no entry file (a prefix match like
  `foo_windows.odin` beats an unrelated `zebra.odin`), so navigation still lands on
  the most package-like file. Alt+Enter
  with the caret on an `import` line (its alias or the quoted path, e.g.
  `import rl "vendor:raylib"`) opens that package the same way. Custom import
  collections declared in the workspace's `ols.json` (`import "shared:foo"`)
  resolve through the collection's path — the same config OLS reads.
- **Type-aware member access** (`value.field`): a selector on a struct-typed value
  resolves to the struct field — go-to-definition jumps to the field, hover shows
  its declaration (`x: int`). The operand's type is inferred from its declaration
  (a parameter, a typed `var`, or a `name := Type{...}` composite literal), a
  pointer is auto-dereferenced (`^Point`), and chained access (`a.b.c`) recurses
  through each field's struct type. The struct is found in the same file, an
  imported package, or the workspace index. Completion after `value.` lists the
  struct's fields, and an implicit enum selector (`a: Axis = .`) offers the
  expected enum's members. Only struct/enum types are understood — a proc result,
  map or slice member still falls through to the flat name scan (no general type
  system).
- **Hover popup:** a mouse dwell over a symbol (~0.45s) dispatches a Hover
  request; the engine's declaration text is drawn in a popup anchored to the
  symbol. Fires once per dwell, dismissed on move or when the cursor leaves. The
  popup shows the *complete* declaration: a struct/enum/union/bit_field (or any
  other multi-line decl) is shown across every line, a procedure keeps only its
  signature (the body is dropped), and any leading `@(...)` attribute is kept.
  The compact symbol-list rows stay a one-line `name :: type` with the attribute
  stripped.
- **"No definition found" feedback:** a failed go-to-definition flashes a
  transient statusline notice (3s).
- **Document symbols (outline):** Ctrl+Shift+O lists the active file's top-level
  declarations — procedures, types, enums, constants, package-level vars — in the
  fuzzy command-palette picker (`Document_Symbols` request → `collect_document_symbols`,
  which reuses the same `collect_defs` walk goto uses). Choosing a row jumps to
  the declaration. Parameters, struct fields and the package/import namespace are
  excluded; rows are sorted by position.
- **Workspace symbols:** Ctrl+T lists *every* top-level declaration across the
  whole workspace in the same picker (`Workspace_Symbols` request →
  `collect_workspace_symbols`, an on-demand scan of every `.odin` file, the live
  buffer's unsaved edits first). Rows are sorted by name; choosing one opens the
  owning file and jumps there.
- **Rich symbol picker:** both symbol lists render each row as the real Odin
  declaration (`add :: proc(a, b: int) -> int`), the identifier tinted by kind
  (proc/type/enum/const/var → theme syntax colors) and the rest dimmed, with a
  `path:line` preview line under the selected row.
- **Find references (find-usages):** F10 lists every usage of the symbol under
  the caret in the fuzzy picker (`References` request → `collect_references`). A
  name that binds to a local or parameter is confined to that declaration's
  scope in the one file; anything top-level (or a name that doesn't resolve
  locally) is matched across the whole workspace, mirroring the cross-file goto's
  flat name match — so it is textual-but-AST-aware, not type-aware. Each row is
  the source line the usage sits on (its code context) with a `path:line`
  preview; choosing one opens the owning file and jumps there.
- **Signature help:** Ctrl+Shift+Space resolves the call the caret is inside
  (`Signature_Help` request → `signature_help`) and shows the callee's signature in
  a popup above the caret, with the argument the caret is on bracketed. The callee
  is resolved the same three ways goto is — same file, package-qualified
  (`pkg.fn(...)`) and cross-file workspace scan — and the active parameter is the
  count of top-level commas before the caret in the call's parentheses. Only
  procedures answer; the popup dismisses on Escape, a caret jump, or when focus
  leaves the pane. **Auto-triggered while typing:** opening `(` or a `,` pops the
  signature up without the keybind, and once it is up every argument keystroke,
  Backspace/Delete and Left/Right re-resolves it so the bracketed active parameter
  tracks the caret; moving the caret out of the call (or closing it) dismisses the
  popup silently. The auto path never flashes "No signature found" — only the
  explicit keybind does.

---

## Missing — UI surface

- [x] **Hover popup.** Mouse dwell (`Mouse_Hover` tick → `on_hover`) drives it;
      `editor_show_hover` fills a popup drawn by `editor_draw_hover`.
- [x] **"No definition found" feedback.** `thor_flash_status` posts a transient
      `Status_Info.message`, shown accented in the statusbar.
- [x] **Multiple candidates.** The cross-file goto scan gathers *every*
      workspace file's top-level declaration of the name (not just the first);
      one hit jumps directly, two or more open the rich picker
      ("Multiple definitions...") so the user chooses. Same-file lexical and
      package-qualified resolutions are unambiguous and still jump straight.
      Engine: `resolve_definition_workspace`/`def_scan_dir`/`def_scan_file`
      collect into `res.symbols`, collapsing a lone hit back to `res.location`;
      host: `thor_show_definition_candidates` reuses the symbol picker + jump
      targets. Still flat/name-based — a picker can list an unrelated same-named
      symbol in another package until the type layer lands.
- [ ] **Loading / busy indicator** while a request is in flight
      (`manager_busy` is available).
- [ ] **Go-back / jump list.** After jumping to a definition there is no way to
      pop back to the previous location.

## Missing — engine depth (Odin native analysis)

- [~] **Type-aware member access** (`foo.bar`): a struct-typed operand's field
      resolves (goto + hover + `value.` field completion), inferring the operand's
      type from its declaration — parameter, typed `var`, or `name := Type{...}`
      composite literal — through a pointer and along a field chain (`a.b.c`).
      Enum selectors are inferred too: `x: Axis = .` completes the enum's members.
      Served by `resolve_member`/`infer_expr_type`/`binding_type_ref` + the
      `visit_type_decl` struct/enum locator (same file → imported package →
      workspace index). Still missing: types that aren't a struct or enum (proc
      results, maps, slices, `using` fields), and inference of a `:=` RHS that
      isn't a composite literal (a call result). Those fall through to the flat
      name scan.
- [~] **Package / import resolution.** `import "core:fmt"` then `fmt.println` is
      followed (package-qualified goto/hover/completion resolve into the package
      dir); custom collections resolve via `ols.json`. Still flat/name-based for
      bare cross-file identifiers, and `using` isn't followed.
- [ ] **Type inference.** No inference for `x := f()`; hover shows the
      declaration text, not a computed type.
- [ ] **Shadowing precision.** Scope is approximated by enclosing block /
      procedure ranges, not true lexical order (a use before a `:=` in the same
      block can still resolve to it). Good enough for goto, imprecise for
      correctness-sensitive features.
- [~] **Standard library / vendor symbols.** Package-qualified access
      (`fmt.println`, `strings.split`) resolves into `core:`/`vendor:`/`base:`
      via the baked-in `ODIN_ROOT`. Still missing: symbols brought in with
      `using import`, and bare identifiers that live in the stdlib.
- [x] **Document symbols / outline.** Ctrl+Shift+O; `Document_Symbols` request
      served by `collect_document_symbols` (reuses `collect_defs`), shown in the
      palette's fuzzy picker. Top-level only — no nested/`using` members yet.
- [x] **Workspace symbols.** Ctrl+T; `Workspace_Symbols` request served by
      `collect_workspace_symbols` (on-demand scan reusing `collect_defs`), shown in
      the palette's rich fuzzy picker. Top-level only, re-scanned each open.
- [x] **Code folding.** Grammar-agnostic, served outside this seam: `syntax.fold_ranges`
      derives foldable line ranges from the tree-sitter tree (any multi-line node,
      widest per start line, root excluded), so every compiled grammar folds — not
      just Odin. Recomputed with the highlights (`thor_update_highlights`), stored on
      the `Open_File`, consumed by the editor widget (fold-aware visual rows, gutter
      chevrons, collapsed "…" marker, gutter-click + Fold: commands). Folds are keyed
      by line, so edits above a fold can drop its collapsed state until re-folded.
- [x] **References / find-usages.** F10; `References` request served by
      `collect_references` (locals confined to their scope in-file, top-level
      names matched across the workspace via the symbol index's per-file
      identifier sets — only files that mention the name are re-parsed).
      Name-based, not
      type-aware: a top-level scan can list an unrelated same-named symbol in
      another package, and value member names (`v.field`) aren't distinguished.
      Type-aware precision waits on the inference layer.
- [x] **Signature help.** Ctrl+Shift+Space; `Signature_Help` request served by
      `signature_help`, which resolves the enclosing call's procedure (same-file,
      package-qualified and cross-file, reusing the goto resolution) and returns its
      signature line plus the byte range of the active parameter. Shown in a popup
      above the caret with the active argument bracketed. Auto-triggers on `(`/`,`
      and live-updates the active parameter as arguments are typed/edited (editor
      `on_signature` callback → `thor_editor_signature_help`, silent on miss).
      Missing: overload sets (the first matching procedure wins). Each keystroke
      spawns a fresh request — see request coalescing under scalability.
- [x] **Completion (semantic).** `Completion` request served by `complete`,
      driven from the editor as a word is typed (`on_completion` callback →
      `thor_editor_completion`, gated to Odin buffers by `completion_semantic`).
      Offers the identifiers in scope — locals/params visible at the caret, this
      file's and this package's top-level declarations — plus keywords and builtin
      types, all prefix-filtered (case-sensitive) and de-duplicated; after `pkg.`
      it lists the imported package's top-level symbols. Candidates fill the
      editor's existing autocomplete popup, tinted by kind. Name-based, like the
      rest of the engine: value member access (`v.field`) waits on type inference.
      Each keystroke spawns a fresh request — see request coalescing under scalability.
- [ ] **Other LSP features not started:** rename, formatting, code actions,
      semantic tokens. (Diagnostics land via `thor/diagnostics.odin`, outside
      this seam.)

## Missing — scalability / performance

- [~] **Persistent symbol index.** Every cross-file request re-reads *and
      re-parses* the whole workspace off-thread; the readdir is cheap, the
      per-file tree-sitter parse is the cost. Keep parsed top-level declarations
      resident on the `Odin_Engine`, re-parsing only files that changed. Touches
      `odin_engine.odin` almost entirely; the seam and host wiring are unchanged.

      **Data model** (engine-owned, self-owned strings cloned from source, freed
      in `odin_destroy`/on reindex — index rows must *not* slice transient source
      the way `Def` does):
      - `Index_Symbol{name, kind, signature: string, line, offset: int}` — a
        top-level decl.
      - `File_Entry{path: string, modtime, size: i64, decls: [dynamic]Index_Symbol,
        idents: map[string]bool}` — `idents` (Phase 2) is the unique identifier
        names in the file, the reference-scan filter.
      - `Symbol_Index{mutex: sync.Mutex, files: map[string]File_Entry, root: string,
        built: bool, alloc: runtime.Allocator}`.

      **Build & invalidation:**
      - *Lazy build* on the first cross-file request (or when `root != req.workspace`):
        reuse the bounded walk (`SCAN_FILE_LIMIT`/`SCAN_DEPTH_LIMIT`), parse each
        `.odin` once, extract top-level `decls`.
      - *Stat-based validation* per request: re-`read_dir` the tree (cheap) and
        re-parse only files whose `modtime`/`size` differ, plus new files; drop
        deleted files. Correct with zero host coupling — the win is skipping the
        parse for unchanged files.
      - *Reindex on save*: `odin_engine_notify_saved(e, path)` called from
        `thor_save_file` (files.odin:372) marks one path stale — a fast path over
        the stat-walk. No file watcher exists, so external edits rely on the
        stat-walk.
      - *Live-buffer overlay* (threaded through every consumer): query the index
        but exclude `req.path`, extract decls from `req.source` separately (already
        parsed for same-file resolution), merge — unsaved edits still win over
        stale disk.

      **Concurrency:** single `sync.Mutex` around index access, building under it
      (requests are infrequent, and were scanning anyway); refine to `RWMutex`
      later if contention shows.

      **Consumers to rewire** (parse-scan → index query, each keeping its
      live-file overlay and result-shaping). *Done* — the whole-workspace scanners
      now query the index: `resolve_definition_workspace` (cross-file goto),
      `scan_workspace` (hover — index locates the file, then one re-parse for the
      full declaration text), `collect_workspace_symbols` (Ctrl+T), and
      `resolve_call_target`'s workspace fallback (signature help). The dead walkers
      (`def_scan_*`, `scan_dir`, `collect_symbols_dir/file`, `find_proc_dir`) were
      removed. *Not yet* — `complete_dir_toplevel`: it is package-scoped (one flat
      dir, not the whole tree) and runs per keystroke, so syncing the index on
      every keystroke wants the debounce/coalescing work first; left on the disk
      scan for now.

      **Phasing:**
      - Phase 1 — index + lazy build + stat validation + rewire the whole-workspace
        declaration consumers (goto, hover, workspace symbols, signature help).
        **Landed** (`odin_engine.odin`; `test_index_reflects_file_change` covers
        stat invalidation). Follow-ups still open: completion (needs debounce
        first) and `odin_engine_notify_saved` on `thor_save_file` (stat-walk
        already catches saves via the mtime bump, so this is a robustness add for
        coarse-mtime filesystems, not a correctness gap).
      - Phase 2 — references acceleration. **Landed.** `index_reparse` now also
        records `File_Entry.idents` (every distinct identifier name in the file,
        engine-owned keys, gathered by `index_collect_idents`). The workspace
        reference scan (`collect_references`) syncs the index under the mutex, asks
        `index_ref_files` for just the files whose `idents` contains the name
        (paths cloned into scratch so they outlive the lock), then re-parses only
        those — the majority of files that never mention the name are skipped
        without a parse. The recursive `ref_scan_dir` walker is gone; `ref_scan_file`
        stays. Covered by `test_references_index_incremental` (decoy file excluded;
        a sibling created after the first request is picked up on the next via the
        stat-walk + rebuilt identifier set).
      - Phase 3 (optional) — drop the per-request readdir once save-hook + a real
        watcher cover all mutations; tie into incremental parsing.

      **Risks:** path canonicalization — the index keys on absolute paths, and the
      overlay's `exclude req.path` depends on those matching `os.read_dir` paths
      (already a flagged limitation below); normalize keys on insert. Memory:
      resident *decls* only (not trees), bounded and small.
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
