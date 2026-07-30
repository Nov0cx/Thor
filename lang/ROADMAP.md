# Language intelligence — status & what's missing

Thor's "LSP alternative": full LSP-style features served **in-client** by native
analyzers running on worker threads, with a subprocess LSP client kept as an
*optional* fallback behind the same seam. In-client is the primary path because
it shares the buffer and tree-sitter tree by pointer — zero JSON, zero IPC,
lowest latency.

## Architecture (in place)

- `lang.odin` — the seam. `Backend` vtable (`handles`/`resolve`/`destroy`),
  `Manager` routes a `Request` by file extension to a backend on a bounded
  pool of worker threads (see **Bounded worker pool**), reaps `Result`s on the
  main thread via `manager_dispatch` (same
  mutex-guarded queue pattern as the file loader). Byte offsets are the position
  currency, and a backend that wants the buffer *changed* answers with
  `Text_Edit`s the editor applies rather than writing files itself. In-flight requests are cancellable by id or by kind, and a superseded
  one is dropped without reaching the editor; the triggers that fire while typing
  are debounced into a per-kind slot so a burst of keystrokes dispatches once
  (see **Request coalescing / cancellation**).
- `odin_engine.odin` — first backend, in-client Odin analyzer. Parses with the
  vendored tree-sitter grammar (incrementally — a resident per-buffer tree is
  re-parsed off a diff-recovered edit span, see **Incremental parsing**);
  resolves identifiers via the LOCALS query + `:=` short-decl handling;
  cross-file via a workspace scan.
- Editor wiring — Alt+Enter (`goto_definition` keybind) and Ctrl+Click both
  dispatch go-to-definition; results jump the caret (opening the target file if
  needed, deferring the jump until it loads).

## What works today

- **Go to definition** (Odin): local variables, `:=` short declarations,
  parameters, loop variables and cross-file top-level symbols, with lexical
  shadowing over file scope (a use above a local names what the local shadows).
  Triggered by Alt+Enter or Ctrl+Click. When a name is declared at
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
  collections declared in the workspace's `.thor/odin-analyzer.json` (`import
  "shared:foo"`) resolve through the collection's path (see **Workspace config**).
- **Type-aware member access** (`value.field`): a selector on a struct-typed value
  resolves to the struct field — go-to-definition jumps to the field, hover shows
  its declaration (`x: int`). The operand's type is inferred from its declaration
  (a parameter or a typed `var`) or, for a `:=` binding, from its initializer: a
  composite literal (`p := Point{}`), another value it aliases (`q := p`), a
  `new(Point)`/`new_clone(...)` allocation, or **the declared result type of the
  procedure it calls** (`p := make_point()`) — the callee resolved the same three
  ways signature help resolves it (same file, `pkg.fn(...)`, workspace index), and
  a multi-value return (`p, ok := find()`) taking the result slot the name binds
  to. A pointer is auto-dereferenced (`^Point`), and chained access (`a.b.c`)
  recurses through each field's struct type. The struct is found in the same file,
  an imported package, or the workspace index. Completion after `value.` lists the
  struct's fields, and an implicit enum selector offers the expected enum's
  members wherever the expected type is pinned down (see below). Inference
  recursion is depth-capped so a self-referential declaration can't loop.
- **Implicit selectors (`.Member`)**: the enum a bare `.` selects from is found
  from whichever construct encloses it — a typed declaration (`a: Axis = .`) or
  assignment, a composite literal's named field (`Config{axis = .}`), the
  parameter a call argument fills (`f(1, .)`, counting commas, following grouped
  and variadic parameters), the other side of a comparison (`a == .`), the value
  a `switch` is over (`case .`), or the enclosing procedure's result slot
  (`return 0, .`). A lone `.` is not an expression, so it derails the parse in
  exactly the spot that matters; when the walk over the request's tree comes up
  empty the file is re-parsed with a filler identifier spliced in after the dot,
  which puts the selector back into a well-formed expression. The splice only
  adds bytes after the dot and every name the walk reads lies before it, so both
  parses agree where it counts.
- **Type aliases (`Vec :: Point`)**: a name that only stands for a type carries
  that type's members. The alias is followed to what it names and looked up again
  from the top — the underlying declaration can live in another file or package
  than the alias, and a qualifier written in the alias (`Vec :: other.Point`) is
  resolved against *its* file's imports. `distinct` types come along, being a
  separate type to the compiler but the same members here, as do chains of
  aliases, capped by `ALIAS_DEPTH_LIMIT` so a cycle can't loop. An alias is a
  constant rather than a type declaration, so the workspace index is asked for
  both kinds. Everything downstream of the locator inherits this: goto, hover,
  `value.` completion and implicit enum selectors all see through an alias. An
  alias is also *coloured* as a definition — `syntax`'s `ODIN_ALIASES` patterns,
  appended to the vendored highlights query, cover the right-hand sides it left
  as plain variables (a bare or qualified name, `map`, `matrix`, `#type proc`).
- **Embedded fields (`using`)**: a struct that embeds another (`using base: Base`)
  answers for the embedded struct's fields as if they were its own — goto, hover
  and `value.` completion all reach them, through several levels of embedding and
  across files (the embedded type is resolved like any other type reference, and
  the embedding file's imports qualify it). The outer struct's own field wins over
  an embedded one of the same name, and a cycle between two structs embedding each
  other is depth-capped. Statement-level `using` (`using foo` inside a procedure,
  `using import`) is *not* followed.
- **Containers** (`[]T`, `[N]T`, `[dynamic]T`, `map[K]V`): a container is tracked
  as its element type plus the container holding it, so it is never mistaken *for*
  that type — `xs.field` resolves nothing, while `xs[i].field`, `xs[1:3][i].field`
  and `for p in xs { p.field }` all resolve to the element's field. A map indexes
  and ranges to its **value** type (its key type isn't tracked, so the `k` in
  `for k, v in m` doesn't resolve). Containers flow through the whole inference
  layer: a declared type, a composite literal (`[]Point{...}`), a call's declared
  result (`-> []Point`, read out of the signature text) and an element bound to a
  `:=` local. Only one level is modelled — `[][]Point` is not inferred.
- **Types qualified by another file's imports:** a type named in a file other than
  the requesting one (a callee's `-> other.Point`, an embedded `using base:
  other.Base`) carries the file it was written in, so its `pkg.` qualifier is
  resolved against *that* file's imports when the requesting file doesn't import
  the package, or imports it under a different alias.
- **Hover popup:** a mouse dwell over a symbol (~0.45s) **with Ctrl held**
  dispatches a Hover request; the engine's declaration text is drawn in a popup
  anchored to the symbol. Requiring the modifier — the same one Ctrl+Click uses to
  jump to a symbol — means passively resting the mouse over code never pops a
  declaration up. Pressing Ctrl over an already-still cursor restarts the dwell,
  so the popup never appears the instant the key goes down. Fires once per dwell,
  dismissed on move, on releasing Ctrl, on scroll, or when the cursor leaves. The
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
  explicit keybind does. The auto path is also debounced (~50ms), so holding a
  key down resolves the call once instead of once per repeat; the keybind
  dispatches immediately.
- **Rename (Shift+F2):** prompts for a new name in the palette (prefilled with
  the symbol under the caret), then rewrites every usage find-references would
  list (`Rename` request → `rename`). The backend returns *edits*
  (`Result.edits: []Text_Edit`), never touching a file itself; the host
  (`thor_apply_rename`) validates each edit's `old_text` against the current
  content and applies the whole set or none — a rename that lands in some files
  and not others breaks a build silently. Open buffers are edited through
  `textedit.replace_ranges` (one undo entry per file, saved by the user); closed
  files are rewritten in place. It refuses when another affected file has unsaved
  changes (the engine measured its on-disk copy) or when the requesting buffer
  has moved past the snapshotted revision.
- **Workspace config (`.thor/odin-analyzer.json`):** the engine reads a
  per-workspace config file from `<workspace>/.thor/` (the same folder Thor keeps
  its `settings.json` in) — Thor's own file (not `ols.json`), though its shape is
  deliberately familiar. It carries **import collections** (a
  `collections` array of `{name, path}`; a relative path resolves against the
  workspace, an absolute one is used as-is) so `import "shared:foo"` resolves, and
  **feature toggles** (`enable_hover`, `enable_document_symbols`,
  `enable_references`, `enable_rename`) that gate those request kinds — a disabled feature answers
  nothing. Absent keys take the defaults (no collections, every feature on), so a
  project with no config behaves exactly as before. The parsed view is cached on
  the engine and stat-invalidated like the symbol index (re-read only when the
  file's modtime/size moves), so the common request pays a single `stat`, not a
  parse. Unknown keys are ignored, so the file can hold settings the engine
  doesn't act on yet. Served by `config_ensure`/`config_collection_dir`/
  `config_allows` in `odin_engine.odin`.
- **Package documentation (F3):** with the caret on a package reference — an
  `import` line, a `pkg.Symbol` operand, or a bare package alias — F3 renders the
  whole package as a documentation page (`Package_Doc` request → `package_doc` /
  `render_package_doc`), the way OLS shows documentation: a Markdown page whose
  every public top-level declaration (sorted by name, across the package's `.odin`
  files) is a ```` ```odin ````-fenced signature followed by a `---` rule and the
  declaration's doc-comment prose — the `//` markers stripped and the lines joined,
  matching OLS's `get_comment`/`build_markup_content` (see
  `ols/src/server/documentation.odin`). The package's own doc comment (above
  `package X`) heads the page. `@(private)` declarations are omitted and
  `_test.odin` files skipped. With no package under the caret it falls back to the
  file's own package, so F3 always shows something. The page is written to a
  per-package temp `.md` file (outside the workspace, so the analyzer never indexes
  it) that renders as Markdown rather than an Odin source tab, and shown in the
  *other* editor pane (the split opens if it was closed) so the source stays
  visible beside it — repeat presses reuse the tab and refresh it in place. Host:
  `thor_package_doc` / `thor_show_package_doc` / `thor_render_doc_in_pane` in
  `lang_host.odin`.

---

## Missing — UI surface

- [x] **Hover popup.** Ctrl + mouse dwell (`Mouse_Hover` tick → `on_hover`) drives
      it; `editor_show_hover` fills a popup drawn by `editor_draw_hover`.
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
- [~] **awarness of implicit casting.** Split four ways. Done: implicit selectors
      in every expected-type position (`expected_type_at` walks up to a literal
      field, call argument, comparison, `switch` case or result slot, re-parsing
      with a filler identifier when the bare `.` broke the tree; parameter types
      read by `proc_param_type`), and `X :: Y` / `X :: distinct Y` aliases
      followed to the declaration they stand for (`visit_type_decl` loops over
      `find_type_decl`, re-resolving each hop from the top). Still open: typing
      conversion expressions (`cast(T)x`, `T(x)`, `transmute(T)x`, `x.(T)`), and
      union variants (`switch v in u`).
- [ ] explain error indicator
- [x] **dont show definiton when just hovering over a thing.** The hover popup is
      gated behind Ctrl (`editor_handle_hover` polls the key, as the Scroll case
      already did for zoom); a passive dwell resolves nothing.
- [~] **Type-aware member access** (`foo.bar`): a struct-typed operand's field
      resolves (goto + hover + `value.` field completion), inferring the operand's
      type from its declaration — parameter or typed `var` — or from a `:=`
      initializer (composite literal, aliased value, `new(T)`, or a call's
      declared result), through a pointer and along a field chain (`a.b.c`).
      Enum selectors are inferred too: `x: Axis = .` completes the enum's members.
      Fields reached through `using` embedding answer as the outer struct's own
      (`member_visitor`/`fields_visitor` → `visit_embedded`, depth-capped by
      `EMBED_DEPTH_LIMIT`), and a container's element resolves once it is indexed,
      sliced or ranged over.
      Served by `resolve_member`/`infer_expr_type`/`binding_type_ref` + the
      `visit_type_decl` struct/enum locator (same file → imported package →
      workspace index → the origin file's imports for a qualified name), which
      follows `X :: Y` and `X :: distinct Y` aliases to what they stand for. Still
      missing: types that are neither a struct, an enum nor a container of one
      (unions, bit_sets, proc fields), a container's own builtin members, a map's
      key type, nested containers (`[][]T`), and statement-level `using`. Those
      fall through to the flat name scan. Member *completion* also needs a bare
      word operand: `xs[0].` and `a.b.` offer nothing, though goto and hover
      resolve them.
- [~] **Package / import resolution.** `import "core:fmt"` then `fmt.println` is
      followed (package-qualified goto/hover/completion resolve into the package
      dir); custom collections resolve via `.thor/odin-analyzer.json`. A type
      qualified in another file (`-> other.Point`) resolves against *that* file's
      imports (`visit_qualified_in_origin`, one extra parse, paid only when the
      requesting file's own imports come up empty). Still flat/name-based for bare
      cross-file identifiers; `using` is followed for struct embedding only, not
      for `using import` or a statement-level `using`.
- [~] **Type inference.** `x := f()` infers the callee's declared result type
      (`call_result_type` → `resolve_call_target` + `proc_result_type`, which reads
      the type after `->` out of the signature text — the callee's tree is already
      freed by then, only its source survives), as do `x := new(T)`, `x := T{}` and
      `x := y`. Multi-value returns bind per slot. Containers are modelled one
      level deep (`Type_Ref.container`), so `-> []T` and `-> map[K]V` results are
      no longer rejected: indexing, slicing or ranging over the value yields its
      element (`range_var_type`, and the `index_expression`/`slice_expression`
      cases of `infer_expr_result`). It is otherwise *declared*-type inference
      only: no expression typing (arithmetic, casts, `or_else`), no generics
      (`$T`), no map keys. Hover still shows the declaration text, not a computed
      type.
- [x] **Shadowing precision.** Resolution is lexical: a value declaration
      (`x := v`, `x: T = v`) is visible only past the declaration it sits in
      (`Def.visible_from` / `Binding.visible_from`), so a use above it names
      whatever it shadows and `x := x` reads the outer `x`. `::` constants,
      types and procedures stay order-independent inside their scope, as Odin
      has them. A control-flow clause declares into its statement rather than
      the block around it (`if v, ok := m[k]; ok`, `for i := 0; ...`), and typed
      `var` locals and `for … in` loop variables — neither of which the vendored
      LOCALS query captures — are collected so they shadow at all. Goto, hover,
      completion, references and rename share the one visibility test
      (`def_visible_at`).
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
      Missing: overload sets (the first matching procedure wins). The auto
      trigger is debounced, so a burst of keystrokes dispatches once — see
      request coalescing under scalability.
- [x] **Completion (semantic).** `Completion` request served by `complete`,
      driven from the editor as a word is typed (`on_completion` callback →
      `thor_editor_completion`, gated to Odin buffers by `completion_semantic`).
      Offers the identifiers in scope — locals/params visible at the caret, this
      file's and this package's top-level declarations — plus keywords and builtin
      types, all prefix-filtered (case-sensitive) and de-duplicated; after `pkg.`
      it lists the imported package's top-level symbols. Candidates fill the
      editor's existing autocomplete popup, tinted by kind. Name-based, like the
      rest of the engine: value member access (`v.field`) waits on type inference.
      Requests are debounced (~50ms), so a burst of keystrokes queues one request
      instead of a thread and a buffer clone per key — see request coalescing
      under scalability — and the sibling-package candidates come from the resident
      symbol index rather than a re-read and re-parse of every file in the package.
- [x] **Rename.** Shift+F2 (F2 already renames the *file*); `Rename` request
      served by `rename`, which runs the reference scan and turns each occurrence
      into a `Text_Edit`. The engine writes nothing — it returns `res.edits` and
      the host applies them, so an open buffer's change is one undo entry. Reach
      and precision are exactly references': a local or parameter stays inside its
      declaration's scope in one file, a top-level name is matched workspace-wide,
      so an unrelated same-named symbol in another package is renamed with it
      until the type layer lands. The new name must be a legal Odin identifier
      and not a keyword/builtin (`valid_identifier`); gated by `enable_rename`.
- [ ] **Other LSP features not started:** formatting, code actions,
      semantic tokens. (Diagnostics land via `thor/diagnostics.odin`, outside
      this seam.)

## Missing — scalability / performance

- [x] **Persistent symbol index.** Cross-file requests used to re-read *and
      re-parse* the whole workspace off-thread; the readdir is cheap, the
      per-file tree-sitter parse is the cost. Parsed top-level declarations are now
      resident on the `Odin_Engine`, re-parsed only for files that changed, and
      every cross-file consumer queries them. Touched `odin_engine.odin` almost
      entirely; the seam and host wiring are unchanged. Phases 1 and 2 landed;
      Phase 3 (dropping the per-request readdir) stays optional.

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
      removed. `complete_dir_toplevel` (completion's sibling-package scan, the last
      per-keystroke disk reader) now queries the index too — it is package-scoped,
      so `index_dir_completions` filters the workspace-wide index down to the files
      sitting *directly* in one directory (`path_in_dir`; a package is a flat dir,
      so another package's declarations must not leak in). It keeps the disk scan
      (`complete_dir_scan`) as a fallback for a directory the index doesn't
      cover — a `core:`/`vendor:`/collection package outside the workspace, or a
      path spelling that doesn't line up with the index keys — so a miss costs
      speed, never candidates. Covered by `test_completion_siblings_from_index`
      (absolute workspace, so the index really answers; asserts the other
      package's decl is excluded and that an edited sibling is re-parsed).

      **Phasing:**
      - Phase 1 — index + lazy build + stat validation + rewire the whole-workspace
        declaration consumers (goto, hover, workspace symbols, signature help).
        **Landed** (`odin_engine.odin`; `test_index_reflects_file_change` covers
        stat invalidation). Completion followed once the debounce was in place.
        Follow-up still open: `odin_engine_notify_saved` on `thor_save_file` (the
        stat-walk already catches saves via the mtime bump, so this is a robustness
        add for coarse-mtime filesystems, not a correctness gap).
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
- [x] **Incremental parsing.** The request buffer no longer re-parses from
      scratch. `Odin_Engine.trees` (a `Tree_Cache`) keeps a resident tree per
      buffer, and `tree_for_source` — the single parse path for `req.source` in
      `odin_resolve` — reuses it: the cached source is diffed to one changed
      span, `ts.tree_edit` applies it, and the old tree seeds
      `parser_parse_string`, so tree-sitter rebuilds only the invalidated
      subtrees. An identical source (a hover landing on the same keystroke as a
      completion) skips the parse entirely.

      **No host coupling.** The seam hands backends a full `source` snapshot,
      never an edit delta, so the edit is *recovered* rather than reported:
      `source_edit` trims the common prefix and suffix and calls everything
      between them replaced. A keystroke is one contiguous run, so that is exact;
      a wider change (multi-cursor, a file reload) collapses into a single
      covering span, which is still a truthful description — tree-sitter reuses
      whatever falls outside it. Both ends are pulled onto UTF-8 rune boundaries
      so no span ever splits a rune. Points (`byte_point`) are computed for the
      edit even though every resolution here works in raw byte offsets, because
      tree-sitter stores them on the nodes it shifts. Being diff-based, it makes
      no ordering assumption: requests that arrive out of revision order still
      describe a correct old→new edit.

      **Cache shape.** `TREE_CACHE_SLOTS` (8) entries, each a `{path, source,
      tree, used}`, retired least-recently-used — enough that alternating between
      open tabs doesn't thrash. Nothing invalidates explicitly: the diff absorbs
      every content change, and a closed or renamed file simply ages out.
      `tree_for_source` returns `ts.tree_copy` of the entry (cheap, and what
      makes a tree safe to read on one worker while another re-parses the same
      buffer); the mutex spans the parse, so concurrent requests on one buffer
      serialize and the waiter gets the fresh tree.

      **Scope:** the request buffer only. The workspace files the cross-file
      scans visit (`index_reparse`, `ref_scan_file`, `scan_file`, …) are
      stat-gated by the symbol index and still parse whole — caching them would
      thrash the slots for no win.

      Covered by `test_source_edit_spans` (insert/delete/replace/append/prepend/
      whole-buffer/UTF-8 spans), `test_incremental_tree_matches_cold_parse` (nine
      successive edits, each comparing the incremental tree's s-expression
      against a cold parse of the same text), `test_incremental_reparse_tracks_edits`
      (goto stays correct across a sequence of edits), `test_tree_cache_is_per_path`
      and `test_tree_cache_evicts_and_reparses`.
- [x] **Request coalescing / cancellation.** Each dispatched job carries a cancellation flag reachable from
      the `Request` (`cancel: ^bool`, polled through `request_cancelled`), and the
      Manager keeps an `active: map[u64]^Job` so a request can be abandoned by id
      (`manager_cancel`) or by kind (`manager_cancel_kind`).
      `manager_request_latest` cancels the in-flight requests of a kind and
      dispatches a replacement — every host dispatch in `thor/lang_host.odin` uses
      it, since each kind has exactly one consumer slot on `Thor` and an older
      request of the same kind can never be wanted again. `manager_cancel_all`
      cancels regardless of kind; `manager_destroy` calls it before draining, so a
      workspace scan started just before quit can't hold shutdown open.

      Cancellation is *cooperative*: the backend polls at the head of every
      expensive loop — `odin_resolve`'s entry (the common case, where the worker is
      scheduled after the next keystroke has already superseded it), the recursive
      index walk (`index_sync`/`index_sync_dir`), the reference scan's per-file
      loop, `complete_dir_toplevel`'s per-file parse (the per-keystroke hot path)
      and `render_package_doc`'s. An abandoned index walk leaves the index merely
      *stale*, never wrong: the entries it refreshed are correct and the next sync
      re-stats everything, but the prune is skipped because `seen` is incomplete
      and pruning against it would drop live files.
      `Result.cancelled` is latched after `resolve` returns, and
      `manager_dispatch` frees such a result without calling the handler — so
      `ok == false` always means "the backend found nothing", never "the work was
      abandoned half-done". Covered by `test_cancel_drops_result`,
      `test_request_latest_supersedes`, `test_cancel_kind_leaves_others` (a fake
      `Probe` backend that parks inside `resolve` so a cancel is observed
      mid-flight) and `test_cancelled_request_answers_nothing`.

      **Debouncing** sits in front of that: `manager_request_debounced` queues a
      request in a per-kind slot (`Manager.pending[Request_Kind]`, main-thread
      only) instead of dispatching it, and `manager_flush_debounced` — called at
      the head of the once-per-frame `manager_dispatch` — starts the ones whose
      delay has run out. A newer request of the same kind overwrites the slot, so
      a burst of keystrokes costs **one** thread and one buffer clone rather than
      one per key (cancellation stops a superseded request's *work*, but the
      thread and the clone are already spent by then). The id is reserved when
      the slot is filled, so the host can key its `*_request_id` slot on it
      immediately; the slot's snapshot *moves* into the job at flush time rather
      than being cloned again. `manager_cancel`/`_kind`/`_all` drop a queued
      request too, so an explicit trigger (the Ctrl+Shift+Space keybind, which
      dispatches immediately — the user is waiting on it) can't be overtaken by
      the auto request it replaced, and `manager_destroy`'s `cancel_all` empties
      the slots so its drain loop can't dispatch fresh work. Delays:
      `DEBOUNCE_TYPING` (50ms, completion + auto signature help) and
      `DEBOUNCE_HOVER` (150ms, unused so far — hover is already dwell-gated).
      Covered by `test_debounce_collapses_burst`, `_delay_elapses`,
      `_cancelled_never_dispatches` and `_slots_are_per_kind`.

      That unblocked the last per-keystroke disk reader: `complete_dir_toplevel`
      now queries the symbol index (see the persistent symbol index above).
- [x] **Bounded worker pool.** Dispatch no longer spawns a thread per request.
      `manager_init` starts a fixed pool (`pool_size` — half the machine's cores,
      clamped to `[WORKERS_MIN, WORKERS_MAX]` = `[2, 4]`) and `dispatch_owned`
      appends the job to `Manager.queue`, posting `Manager.work` once; a
      `pool_worker` wakes, pops the head (FIFO) and runs it. `Job` no longer
      carries a thread, so `manager_dispatch` reaps a result without a join —
      the per-request thread create/join/destroy is gone from the hot path.

      **Why the cap is small:** requests are latency-bound (a parse, a stat
      walk), not throughput-bound, and cancellation already keeps at most one
      live job per kind, so a handful of workers covers the useful concurrency.
      The floor of 2 is load-bearing: with a single worker a workspace scan
      would wedge a hover queued behind it.

      **Queued jobs stay cancellable.** A job in the queue is already in
      `active`, so `manager_cancel`/`_kind`/`_all` reach it; `job_run` checks the
      flag *before* calling `resolve`, so a superseded request that never got a
      worker costs nothing at all — the backend never sees it. That is strictly
      cheaper than the old path, where the thread and the buffer clone were both
      spent before the backend's entry poll could bail.

      **Shutdown:** `pool_destroy` (called by `manager_destroy` after the drain,
      before the backends are torn down, so no worker can touch freed backend
      state) sets `shutdown` under the mutex and posts `work` once per worker.
      The semaphore is counting and every enqueue posts exactly once, so a wake
      that finds the queue empty can only be one of those posts — that is the
      exit. Then each worker is joined and destroyed.

      Covered by `test_pool_caps_concurrency` (n+3 parked requests; exactly `n`
      run at once, all `n+3` deliver once released) and
      `test_queued_job_cancelled_before_it_starts` (a job cancelled while queued
      never reaches the backend). `manager_worker_count` exposes the pool size.

## Missing — the optional LSP backend

The seam supports it, but no subprocess backend exists yet. To add one:

- [ ] Long-lived child process with async stdio (a reader thread), `Content-Length`
      framing, JSON-RPC request/response id matching. (Note: `run_command` in
      `console.odin` is one-shot/blocking — a different lifecycle is needed.)
- [ ] LSP handshake (`initialize`/`initialized`, capabilities) and document sync
      (`didOpen`/`didChange` incremental, keyed off the piece-table revision).
- [ ] UTF-16 position ↔ byte offset conversion at the backend edge.
- [ ] Server lifecycle: discovery/config (a subprocess server reads its own
      config — e.g. `ols.json` for OLS itself), spawn on first relevant file,
      restart on crash, shut down on exit.
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
