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
  currency, counted over source with CRLF collapsed to LF — the form the editor
  holds a buffer in, so one offset means the same thing in a buffer and on disk.
  A backend reads files through `source_read`, never `os.read_entire_file`. A
  backend that wants the buffer *changed* answers with
  `Text_Edit`s the editor applies rather than writing files itself. In-flight requests are cancellable by id or by kind, and a superseded
  one is dropped without reaching the editor; the triggers that fire while typing
  are debounced into a per-kind slot so a burst of keystrokes dispatches once
  (see **Request coalescing / cancellation**).
- `lang/odin` — first backend, in-client Odin analyzer, a subpackage of its own
  so the analysis internals stay out of the seam's namespace (a subprocess LSP
  client would sit beside it as `lang/lsp`). Parses with the vendored
  tree-sitter grammar (incrementally — a resident per-buffer tree is re-parsed
  off a diff-recovered edit span, see **Incremental parsing**); resolves
  identifiers via the LOCALS query + `:=` short-decl handling; cross-file via a
  workspace scan. Split by concern:
  `engine.odin` (lifetime + the `lang.Backend` seam), `resolve.odin` (the
  request entry point and lexical scope), `index.odin` (the resident symbol
  index), `config.odin` (`.thor/odin-analyzer.json`), `symbols.odin` (outlines,
  references, rename), `signature.odin`, `completion.odin`, `infer.odin` /
  `typeref.odin` / `decl.odin` (member-access type inference),
  `packagedoc.odin`, `builtins.odin` (the implicit scope, read off the toolchain),
  `check.odin` (compiler diagnostics — the one request that
  analyzes nothing itself), `actions.odin` (code actions — the one request that
  answers with fixes rather than with what the caret names), `semantic.odin`
  (semantic tokens — the one request that answers about the whole buffer rather
  than about a caret) and `ast.odin` (shared tree/text helpers).
- Editor wiring — Alt+Enter (`goto_definition` keybind) and Ctrl+Click both
  dispatch go-to-definition; results jump the caret (opening the target file if
  needed, deferring the jump until it loads).

## What works today

- **Go to definition** (Odin): local variables, `:=` short declarations,
  parameters, loop variables and cross-file top-level symbols, with lexical
  shadowing over file scope (a use above a local names what the local shadows).
  Triggered by Alt+Enter or Ctrl+Click. When a name is declared at
  top-level in several files of the package, the jump offers a picker of all
  candidates instead of silently taking the first; a single match jumps straight
  there. A **procedure group** answers with its members rather than the list
  itself (see **Overload sets** below).
- **Package-scoped bare names:** an unqualified identifier is looked up in the
  file's own package before the workspace is consulted at all, which is what Odin
  itself does — a bare name reaches its scope, its file, its package and the
  builtins, and *nothing* in another directory, which is reachable only through
  an import and a qualifier. The cross-file lookup used to be a flat match over
  every indexed file, so two packages each declaring `init` turned every goto on
  one into a picker over both, and hover, signature help and the type locator
  (which all take the lexicographically first hit) answered from whichever
  package sorted first. All four now filter the symbol index to the requesting
  file's directory first (`index_package_dir` → `index_scoped`, threaded through
  `index_find_defs`/`index_first_path`) and widen to the whole workspace only
  when the package declares nothing of the name. Widening is a *guess* by then
  rather than a wrong answer — no correct definition exists to be shadowed — and
  it keeps the reach the engine has for what it cannot yet model, so the scoping
  can cost precision but never candidates. `actions.odin`'s `declared_in_package`
  gets the same treatment and a fix with it: it took the workspace-wide first hit
  and *then* asked whether it sat in this directory, so a name declared both here
  and in an earlier-sorting package read as undeclared and offered a `:=` for an
  assignment that was already legal. Path spellings are the fiddly part — the
  request carries the path its file was opened with, the index the one
  `os.read_dir` produced — so `path_in_dir` now folds separators *and* (on
  Windows) case, and `index_package_dir` retries the absolute form when the
  literal directory holds no indexed file, since a package that fails to match
  would silently widen straight back to the flat scan. Covered by
  `lang/odin/package_test.odin`, whose decoy package deliberately sorts before
  the requesting one so a passing test means the scoping ran (goto takes the
  direct jump instead of a two-candidate picker; hover, signature help and the
  member-access type locator each read the requesting package's declaration; and
  one test pins the widening fallback).
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
- **The implicit scope (`len`, `append`, `make`):** the names the compiler puts in
  every file with no import at all. They are the *only* standard-library names a
  bare identifier can reach — everything else needs an import and a qualifier — so
  they close the bare-name path: go-to-definition jumps into the toolchain's own
  sources, hover shows the declaration there, completion offers them, and a call
  of one is signed, a group once per member (`append(` lists its eight). Resolved
  last, after the file, the package and the workspace, so a program declaring a
  `len` of its own shadows the builtin exactly as the compiler has it.

  Read off the compiler on disk rather than hardcoded (`lang/odin/builtins.odin`):
  the set moves with the toolchain, and a list baked into this repo would rot the
  next time the language gains a builtin. One resident `Builtin_Cache` per process
  — it is a property of the installed compiler, not of the workspace — built the
  first time anything asks, holding for each name the file that declares it, its
  kind, its one-line signature and where in the file it sits. That is what keeps
  the cost off the request: completion answers from the cache alone, and
  goto/hover/signature help each read the *one* file the cache names rather than
  walking the standard library. The cache was already there for undeclared-name
  dimming, which is where the parse of `base:builtin` + `base:runtime` was already
  being paid.

  A builtin **procedure group** takes its members from the cache too
  (`builtin_member_sites`, tried by `overload_sites` before its directory scan),
  which is what makes `append(` affordable: expanding it by re-reading
  `base:runtime` cost ~70ms *per request* on the per-keystroke signature path, and
  `append` is the most-typed group in the language. Gated on the group's file
  being one the cache was built from, behind a cheap ODIN_ROOT prefix test — every
  workspace group reaches that call, and none of them should build this cache to
  learn they are not in it.

  **Which names are actually in scope** is the one thing worth stating precisely:
  all of `base:builtin` (which is documentation of the universal scope and nothing
  else), plus the `base:runtime` declarations marked `@(builtin)` — the rest of
  `base:runtime` is an ordinary package that must be imported, so `Allocator` and
  `Raw_Dynamic_Array` are deliberately *not* offered bare. The marker is read off
  the attribute text between a declaration's start and its name, which covers both
  spellings (`@builtin` and `@(builtin, require_results)`) and a declaration
  carrying several attribute lines. Dimming keeps the wider set it always had — a
  name `base:runtime` exports without the marker still counts as declared there —
  because over-permitting only costs a missed dim where under-permitting flags
  correct code.

  Covered by `lang/odin/builtin_test.odin`: goto into `base:builtin`, hover, a
  group offering its members, a workspace `len` shadowing the builtin one,
  signature help, completion, and one test each pinning that an unmarked
  `base:runtime` export resolves and completes to nothing.
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
  recurses through each field's struct type. A **proc-typed value** carries its
  signature instead of a type name — a proc type declares nothing to look up — so
  calling one yields its declared result: a struct's callback field (`h.on(1).x`),
  that field bound to a local (`cb := h.on; cb(1).x`) and a proc-typed variable
  (`global().x`) all resolve, while the uncalled value stays the proc it is. A call
  under a selector is spelled exactly like `pkg.fn(...)`, so the operand decides
  which it is: a name the file imports is the package, anything else is a value.
  The struct is found in the same file,
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
- **Conversions and assertions (`cast(T)x`, `T(x)`, `x.(T)`)**: the value carries
  the members of the type named on the left of the operand, not of the operand
  itself. `cast(T)x` and `transmute(T)x` name their target outright (the grammar
  spells both as one `cast_expression` with a `type` child; `auto_cast x` has no
  such child and takes its type from where it sits, so it is left alone). The
  call-shaped `T(x)` is indistinguishable from a call by shape, so it is read as a
  conversion only once no procedure of that name is found — a package qualifier
  (`lib.Point(h)`) sits on the member expression the call hangs under, where
  `resolve_call_target` reads it from too. `x.(T)` is not a cast but a type
  assertion — it narrows a union or an `any` to a variant it already holds — and it
  arrives as a member expression whose "name" is a parenthesized type; the `ok` of
  `v, ok := x.(T)` is a bool, so only the first slot narrows.
- **Type switches (`switch v in u`)**: each case narrows the switch variable to the
  type it names, so the same `v` carries different members from one case to the
  next — `case Circle:` gives it Circle's, `case ^Square:` Square's (the pointer is
  transparent), `case lib.Circle:` reaches across packages (a qualified case arrives
  as a member expression, an unqualified or pointer one as a type). The union is
  never consulted: the case says what the value is there. A case listing several
  types leaves the variable as the union and the default case narrows nothing, so
  neither binds — one condition is the requirement. The variable is also a
  declaration in its own right, which the vendored LOCALS query captures nowhere, so
  goto and find-usages on it are collected alongside the `:=` and loop-variable ones
  and scoped to the switch.
- **Embedded fields (`using`)**: a struct that embeds another (`using base: Base`)
  answers for the embedded struct's fields as if they were its own — goto, hover
  and `value.` completion all reach them, through several levels of embedding and
  across files (the embedded type is resolved like any other type reference, and
  the embedding file's imports qualify it). The outer struct's own field wins over
  an embedded one of the same name, and a cycle between two structs embedding each
  other is depth-capped. Statement-level `using` (`using foo` inside a procedure,
  `using import`) is *not* followed.
- **Containers** (`[]T`, `[N]T`, `[dynamic]T`, `map[K]V`, `bit_set[E]`): a container
  is tracked as its element type plus the **stack** of containers holding it, so it
  is never mistaken *for* that type — `xs.field` resolves nothing, while
  `xs[i].field`, `xs[1:3][i].field` and `for p in xs { p.field }` all resolve to the
  element's field. Each index, slice or range strips exactly one level, so nesting
  works and stops where it should: `grid[0][1].field` resolves and `grid[0].field`
  does not. `CONTAINER_DEPTH_LIMIT` (4) bounds the nesting that is modelled at all.
  A map indexes and ranges to its **value** type and its `for k, v in m` key to the
  **key** type (a plain, optionally qualified key name — `map[[2]int]V` records
  none), which is also what `m[.Member]` selects from. A bit_set holds its element
  the same way: ranging over one binds the enum, and a literal of any container
  (`bit_set[Axis] = {.}`, `[]Axis{.}`) offers the *element's* members to a bare `.`,
  since a positional literal entry carries no field name to look up and the walk
  climbs on to what pins the literal's own type down. Containers flow through the
  whole inference layer: a declared type, a composite literal (`[]Point{...}`), a
  call's declared result (`-> map[string][]Point`, read out of the signature text)
  and an element bound to a `:=` local.
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
- **Semantic highlighting:** identifiers are coloured by what the analyzer
  resolved them to, not only by what the parse shape suggests — a parameter, a
  local, a package operand, a procedure and a type each take their own colour
  where the highlights query paints every *use* of them alike, and a name
  nothing in the file, its imports or the workspace declares is dimmed. The
  classification is layered over the grammar's spans by the highlight pass and
  is deliberately sparse: wherever the analyzer knows no more than the grammar,
  the grammar's colour stands. Undeclared-name dimming gives up on the whole
  file at the first sign it cannot see far enough (see the semantic-tokens entry
  below), because a name dimmed in error reads as a compiler error that does not
  exist.
- **"No definition found" feedback:** a failed go-to-definition flashes a
  transient statusline notice (3s).
- **Explained diagnostics:** the compiler messages `odin check` produces (see
  **Diagnostics** below) are readable in place rather than only implied by a
  squiggle. A mouse dwell over the squiggle — or over the gutter
  marker, which stands for the whole line — pops the message up in the hover popup,
  its border tinted by severity. That hover is *not* Ctrl-gated: the modifier picks
  which of the two hovers a dwell is, held asking the engine about the symbol and
  released letting a flagged span explain itself, so resting on unflagged code
  still pops nothing up. Resolved from the editor's own borrowed `[]Diagnostic`,
  so it costs no request and no thread. A long message wraps to a width budget
  (`hover_wrapped`) instead of running off the pane, and the popup is now sized by
  the line count it will draw — which also fixes a multi-line *declaration*
  overflowing its one-line box. Any edit dismisses it: the compiler measured the
  text before it, so both the message and the range it points at go stale
  (`hover_revision`). Independently, the caret's line shows its message in the
  statusbar whenever no transient notice is up (`thor_status_info`), so the same
  text is reachable without the mouse.
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
  the caret in the fuzzy picker (`References` request → `collect_references`).
  The name is resolved first and every occurrence is then bound-checked against
  what it resolved to: a local or parameter to its own declaration (a shadowing
  redeclaration is a different variable), a top-level symbol to the package
  declaring it (bare inside that package, only behind a qualifier naming it
  outside), a struct field to the struct declaring it (so `a.x` and `b.x` are
  two different fields). The declaration itself is not listed — it is a use of
  the symbol only to rename. Each row is the source line the usage sits on (its
  code context) with a `path:line` preview; choosing one opens the owning file
  and jumps there.
- **Signature help:** Ctrl+Shift+Space resolves the call the caret is inside
  (`Signature_Help` request → `signature_help`) and shows the callee's signature in
  a popup above the caret, with the argument the caret is on bracketed. The callee
  is resolved the same four ways goto is — same file, package-qualified
  (`pkg.fn(...)`), cross-file workspace scan and the implicit scope (`append(`,
  `make(`) — and the active parameter is the
  count of top-level commas before the caret in the call's parentheses. Only
  procedures answer; the popup dismisses on Escape, a caret jump, or when focus
  leaves the pane. A call of a **procedure group** signs every member (see
  **Overload sets** below). **Auto-triggered while typing:** opening `(` or a `,` pops the
  signature up without the keybind, and once it is up every argument keystroke,
  Backspace/Delete and Left/Right re-resolves it so the bracketed active parameter
  tracks the caret; moving the caret out of the call (or closing it) dismisses the
  popup silently. The auto path never flashes "No signature found" — only the
  explicit keybind does. The auto path is also debounced (~50ms), so holding a
  key down resolves the call once instead of once per repeat; the keybind
  dispatches immediately.
- **Overload sets (`sizes :: proc{sized_one, sized_two}`):** Odin's one form of
  overloading. A group declares no parameters and has no body — it names other
  procedures — so a feature pointed at one has to reach through to the members;
  signature help and go-to-definition both do, over the shared lookup in
  `lang/odin/overload.odin`.

  Signing the group itself would show a call's arguments against an empty list, so
  a call of one is signed **once per
  member** instead, drawn one per line in the popup with the member the arguments
  match marked `>`; only that line brackets its active parameter, since the caret
  is in one argument slot and bracketing the same slot on a candidate that has no
  such parameter would claim a match that was never made. The seam carries a list
  for this: `Signature_Entry{label, active_start, active_end}` and
  `Signature_Info{entries, active}`, an ordinary call answering with exactly one
  entry and rendering exactly as it did before — the marker column appears only
  when there is something to choose between.

  **Which member is active** is decided by *arity*: the first entry whose
  parameter count equals the number of arguments **written** (`param_arity` /
  `call_arg_count`), a variadic tail absorbing any surplus. Counting what is
  written rather than where the caret is means a trailing empty argument counts —
  `sizes(1,|)` is two slots — so the highlighted member tracks the call as it is
  typed rather than only once it is complete. When nothing matches exactly (a
  call still in progress, or a group whose members differ by parameter *type*
  rather than count, which this does not read) the first entry with a parameter
  in the caret's slot wins, and failing that the first entry: a call in progress
  must still show something.

  **Members are resolved package-locally** (`overload_sites` in
  `lang/odin/overload.odin`, one lookup shared by signature help and goto —
  each member comes back as a `Member_Site{name, label, path, line, offset}`,
  the label for signing and the rest for jumping). Package-locally is where a
  group's unqualified members are declared: the live buffer first when it belongs
  to the group's package (its on-disk copy may be stale, and a member being edited
  must still answer), then the package directory. That directory pass matches
  *every* outstanding member against each file it parses rather than restarting
  per member — signature help runs this per keystroke, and one parse per member
  per file would be quadratic in a large package — and it polls cancellation per
  file. The
  member names come from a re-parse of the group's declaration text
  (`overload_members`) rather than a textual split of the braces: the member list
  may carry comments and line breaks the grammar already models, and a cross-file
  callee's own tree is freed by `first_proc_in_file` before this runs, so only its
  source survives. Expansion is capped at `OVERLOAD_LIMIT` (32) — the popup is one
  line per entry, so a pathological group would otherwise cover the buffer it
  annotates.

  **A member written qualified** (`proc{foo, other.bar}`) is outside the
  package-local lookup and is left out. A group *none* of whose members resolve
  falls back to signing the group declaration itself, which — see the fix below —
  now reads as its member list.

  **Go-to-definition reaches through the group** the same way
  (`overload_definitions`): the group's declaration is a list of names, so landing
  on it leaves the caller one hop short of the code they asked for. A single
  reachable member is an unambiguous definition and is jumped to directly; several
  become picker candidates, because what would choose between them are a call's
  arguments and goto has no call to read. This holds on all three paths goto
  resolves by — same-file (`resolve`), package-qualified `pkg.sizes` (`scan_file`)
  and the cross-file index (`expand_index_group`) — so the answer doesn't depend on
  where the group happens to live. The index case needs `Index_Symbol.overload`:
  the index records *that* a declaration is a group but not what it gathers, so
  the file it points at is re-parsed for the member list. As with signature help,
  a group with no reachable member leaves the group declaration itself as the
  answer rather than reporting nothing.

  The live buffer's package membership is decided by comparing directories
  (`same_dir`), and the two spellings arrive from different places — the request
  carries the path its file was opened with, a cross-file group the one the
  workspace walk produced — so an unequal pair is retried absolute. A false
  negative there costs only the unsaved edits in that one file, never a wrong
  answer.

  **Fixed alongside:** `signature_text` and `declaration_text` both cut a
  procedure's text at the first `{` to keep its body out, and a group's brace
  opens its *member list*, not a body. Every procedure group in the workspace was
  therefore rendering as a bare `sizes :: proc` — in the hover popup, the document
  outline, workspace symbols and the symbol index alike. `Def.overload` (set by
  `collect_defs`'s `overloaded_procedure_declaration` case) exempts them: hover
  shows the group across every line it was written on, like any other multi-line
  declaration, and the one-line symbol rows keep the list with its whitespace
  flattened (`flatten_lines`).

  Covered by `test_signature_help_overload_set` (one entry per member, arity
  picking the active one), `_tracks_arity` (the active entry moving as the comma
  is typed), `_cross_file` (group and members reached through the package scan),
  `_falls_back_to_group` (every member qualified), `test_param_arity` (empty,
  nested-type commas, a result tuple, variadic) and
  `test_hover_procedure_group_keeps_members`; goto by
  `test_definition_overload_offers_members` (one candidate per member, with its
  own jump target and line), `_single_member` (a jump, not a picker),
  `_falls_back_to_group`, `_cross_file` (index-resolved group, one member on disk
  beside it and one only in the unsaved buffer) and `_package_qualified`.

  **Still open:** which member a *goto* means is left to the user whenever there
  is more than one, even though a call sits right there — `pick_overload` already
  reads its arity, and feeding that through would turn the common two-member case
  into a direct jump, with the picker kept for a genuine tie. Type-based overload
  selection is not attempted at all — it waits on the inference layer, like the
  rest of the precision work.
- **Rename (Ctrl+R):** prompts for a new name in the palette (prefilled with
  the symbol under the caret), then rewrites every usage find-references would
  list, plus the declaration it leaves out (`Rename` request → `rename`, the same
  scan with the declaration kept). The backend returns *edits*
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
  `config_allows` in `lang/odin/config.odin`.
- **Go back / go forward (Ctrl+Alt+Left / Ctrl+Alt+Right):** every jump records
  where it left, so chasing a definition across files is reversible. Two trails
  in the host only (`thor/jumplist.odin`); the engine is not involved. The record
  is taken inside `thor_goto_location` / `thor_goto_file_line_col` rather than by
  their callers, so *every* way into a jump is covered without each remembering
  to: go-to-definition (Alt+Enter and Ctrl+Click), the candidates picker, both
  symbol pickers, find-references, a console error line, and Go to Line. Points
  are `path` + 1-based line/column, not a byte offset — the buffer is edited
  between leaving a spot and coming back to it, and typing above an offset slides
  it by every character where a line only moves by the newlines. Going back and
  forward routes through the same jump proc, so a target whose tab was closed
  since is reopened and one still loading is deferred, exactly like any other
  jump. Browser semantics: arriving somewhere new drops the forward trail, and
  repeated jumps off one line collapse into a single entry. Each trail is capped
  at 64 and cleared when the workspace is swapped (the paths name the old tree).
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
      top-level declaration of the name in scope (not just the first); one hit
      jumps directly, two or more open the rich picker
      ("Multiple definitions...") so the user chooses. Same-file lexical and
      package-qualified resolutions are unambiguous and still jump straight —
      except on a procedure group, whose members are candidates on every path
      (see **Overload sets**).
      Engine: `resolve_definition_workspace` collects into `res.symbols`,
      collapsing a lone hit back to `res.location`; host:
      `thor_show_definition_candidates` reuses the symbol picker + jump targets.
      The scope is the requesting file's package (see **Package-scoped bare
      names**), so a picker no longer lists a same-named symbol from an unrelated
      package — only the widened fallback, reached when the package declares
      nothing of the name, can still do that.
- [x] **Loading / busy indicator** while a request is in flight. A pulsing
      `loader-2` segment in the statusbar, labelled after the work
      ("Scanning workspace...", "Checking...", "Analyzing..."). Engine:
      `manager_busy_kinds` reports the kinds dispatched and not yet reaped,
      leaving out the cancelled ones; host: `thor_poll_lang_busy` folds that into
      `Thor.lang_busy_*` once a frame and `thor_lang_busy_label` names the most
      user-visible kind. The flag only goes up after `LANG_BUSY_DELAY_SECS`
      (0.25 s) of unbroken work, so the passes that fire while typing
      (completion, semantic tokens) never flash a spinner.
- [x] **Go-back / jump list.** Ctrl+Alt+Left returns to where a jump left,
      Ctrl+Alt+Right replays it ("Go Back"/"Go Forward" in the palette, both
      rebindable). Recorded inside the jump procs themselves, so every caller —
      definition, either symbol picker, references, console errors, Go to Line —
      is covered. See **Go back / go forward** above.

## Missing — engine depth (Odin native analysis)
- [x] **awarness of implicit casting.** Split four ways, all landed: implicit
      selectors in every expected-type position (`expected_type_at` walks up to a
      literal field, call argument, comparison, `switch` case or result slot,
      re-parsing with a filler identifier when the bare `.` broke the tree;
      parameter types read by `proc_param_type`); `X :: Y` / `X :: distinct Y`
      aliases followed to the declaration they stand for (`visit_type_decl` loops
      over `find_type_decl`, re-resolving each hop from the top); conversion
      expressions typed by their target (`cast(T)x`, `transmute(T)x`, and the
      call-shaped `T(x)` once no procedure answers to the name); and union variants
      narrowed by both the `x.(T)` assertion and each case of a `switch v in u`.
- [x] **explain error indicator.** Both indicators a diagnostic already had — the
      squiggle and the gutter marker — now say what they mean on a plain mouse
      dwell (`editor_handle_hover` → `editor_hover_diagnostic`, an error outranking
      a warning on a shared line), and the caret's line shows its message in the
      statusbar. Nothing new is analyzed: the engine never sees these requests, the
      messages come from the `odin check` run the save kicked off.
- [x] **dont show definiton when just hovering over a thing.** The hover popup is
      gated behind Ctrl (`editor_handle_hover` polls the key, as the Scroll case
      already did for zoom); a passive dwell resolves nothing.
- [x] **Type-aware member access** (`foo.bar`): a struct-typed operand's field
      resolves (goto + hover + `value.` field completion), inferring the operand's
      type from its declaration — parameter or typed `var` — or from a `:=`
      initializer (composite literal, aliased value, `new(T)`, or a call's
      declared result), through a pointer and along a field chain (`a.b.c`).
      Enum selectors are inferred too: `x: Axis = .` completes the enum's members.
      Fields reached through `using` embedding answer as the outer struct's own
      (`member_visitor`/`fields_visitor` → `visit_embedded`, depth-capped by
      `EMBED_DEPTH_LIMIT`), and a container's element resolves once it is indexed,
      sliced or ranged over — one level per step, so nested containers resolve at
      the depth they are written to (`Type_Ref.containers`, a stack of
      `Container_Layer` bounded by `CONTAINER_DEPTH_LIMIT`). A map's key is tracked
      beside its value, so `for k, v in m` binds both and `m[.]` selects from the
      key; `bit_set[E]` is a container of its enum, and a literal of any container
      offers the element's members to a bare `.`. A **proc type** names no
      declaration, so it carries its signature text (`Type_Ref.proc_sig`) and a call
      of such a value reads the result out of it (`signature_result_type`) — which
      is what makes a struct's callback field (`h.on(1).x`) resolve.
      Served by `resolve_member`/`infer_expr_type`/`binding_type_ref` + the
      `visit_type_decl` struct/enum locator (same file → imported package →
      workspace index → the origin file's imports for a qualified name), which
      follows `X :: Y` and `X :: distinct Y` aliases to what they stand for. A
      conversion (`cast(T)x`, `transmute(T)x`, `T(x)`) types its value by what it
      converts to, and a union narrows to a variant through `x.(T)` or a
      `switch v in u` case.

      **Still open:** an un-narrowed union has no members to offer and is left
      alone; a container's own builtin members (a fixed array's `v.x` swizzle, an
      `#soa` array's per-field slice) are not modelled; nesting past
      `CONTAINER_DEPTH_LIMIT` is not inferred; and statement-level `using` is not
      followed — the compiler disallows it without `#+feature using-stmt`, so
      struct embedding is the only `using` that reaches ordinary code (see the
      `using` note under **Package / import resolution**). Those all fall through
      to the flat name scan.

      Member *completion* takes the same
      operands goto and hover do — `a.b.`, `xs[0].` and `f().` all offer the
      struct they read as — by reading the operand off the tree
      (`complete_selector` → `operand_type_at`, the largest expression ending at
      the dot) instead of scanning back for a word. A dangling dot derails the
      parse, so that case is answered off the same filler-identifier repair the
      implicit selector uses; a *second* dangling dot earlier in the same block
      still swallows the line under the caret, which a live edit doesn't produce.

      Covered by `lang/odin/member_test.odin` (declared types, aliases,
      conversions, type switches, call results, and
      `test_member_proc_value_result` / `test_completion_proc_value_result` for
      proc-typed fields, locals and variables) and `lang/odin/embed_test.odin`
      (`using` embedding and containers: `test_member_nested_container` — both
      levels of `[][]T`, `map[string][]T` and a `-> [][]T` result, plus one index
      short offering nothing — `test_member_map_key`,
      `test_completion_map_key_selector`,
      `test_completion_container_literal_selector` and
      `test_member_bit_set_element`).
- [x] **Package / import resolution.** `import "core:fmt"` then `fmt.println` is
      followed (package-qualified goto/hover/completion resolve into the package
      dir); custom collections resolve via `.thor/odin-analyzer.json`. A type
      qualified in another file (`-> other.Point`) resolves against *that* file's
      imports (`visit_qualified_in_origin`, one extra parse, paid only when the
      requesting file's own imports come up empty). A **bare** name now resolves
      package-scoped rather than workspace-flat — see **Package-scoped bare
      names** above.

      **`using` needs nothing.** The two forms this entry used to list as missing
      are gone from the language, not from the engine — checked against the
      compiler (dev-2026-07) rather than assumed:
      `using import "core:fmt"` is *"Syntax Error: 'using import' is not allowed,
      please use the import name explicitly"*, a file-scope `using fmt` is
      *"Only declarations are allowed at file scope"*, and a statement-level
      `using` (or a `using` parameter) is *"'using' has been disallowed as it is
      considered bad practice ... it can be enabled on a per-file basis with
      `#+feature using-stmt`"*. So the only `using` that injects names into
      ordinary code is struct embedding, which the engine already follows
      (**Embedded fields** above). `semantic.odin`'s `has_using` kill switch stays
      as it is: a file that does opt in with `#+feature using-stmt` is still a
      file this engine cannot see far enough into to dim names in.

      **Still open:** visibility attributes are not modelled — `@(private)` hides
      a declaration from other packages and `@(private="file")` from the rest of
      its own, and neither the index nor `collect_defs` records them, so both are
      offered as if public (package docs are the one consumer that filters
      `@(private)`, textually). References and rename do bind a top-level name to
      the package declaring it (see **References** below), which is the reach part
      of the same question; what is still missing is the *visibility* part, where
      an attribute narrows a declaration below its package.
- [~] **Type inference.** `x := f()` infers the callee's declared result type
      (`call_result_type` → `resolve_call_target` + `proc_result_type`, which reads
      the type after `->` out of the signature text — the callee's tree is already
      freed by then, only its source survives), as do `x := new(T)`, `x := T{}` and
      `x := y`. Multi-value returns bind per slot. Containers are modelled as a
      stack (`Type_Ref.containers`), so `-> []T`, `-> map[K]V` and
      `-> map[string][]T` results are no longer rejected: indexing, slicing or
      ranging over the value strips one level and yields what is left
      (`range_var_type`, and the `index_expression`/`slice_expression` cases of
      `infer_expr_result`), and a map's key type is tracked beside its value. A
      proc type carries its signature, so calling a proc-typed value yields its
      declared result. It is otherwise *declared*-type inference only: no
      expression typing (arithmetic, casts, `or_else`), no generics (`$T`). Hover
      still shows the declaration text, not a computed type.
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
- [x] **Standard library / vendor symbols.** Package-qualified access
      (`fmt.println`, `strings.split`) resolves into `core:`/`vendor:`/`base:`
      via the baked-in `ODIN_ROOT`. **Bare** stdlib names resolve too, which is
      exactly the implicit scope: a bare identifier reaches its scope, its file,
      its package and what the toolchain declares into every file, and nothing
      else. See **The implicit scope** above. The other thing this entry used to
      list as missing — `using import` — is not a language feature; see the
      `using` note under **Package / import resolution**.
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
      `collect_references` (`references.odin`), which resolves the caret's name to
      a `Ref_Target` and then bound-checks every occurrence against it rather than
      matching the spelling:
      - a **local or parameter** by re-running goto's own lexical resolution at
        each occurrence, so a redeclaration in an inner block is a different
        variable and a `v.total` field access is not the local `total`;
      - a **top-level symbol** by the package that declares it — bare only inside
        that package (and only where nothing nearer shadows it), elsewhere only
        behind an import alias that resolves to that same directory, so the rival
        `shared` of another package is no longer listed;
      - a **struct field** by the site the field is declared at, reached by
        inferring each operand's type (`infer_expr_type` → `member_visitor`,
        through aliases and `using` embedding), so `p.x` and `r.x` separate, and
        `T{x = 1}` counts as the field it names.
      The declaration is deliberately not one of the results — rename asks for the
      same scan with `req.kind == .Rename` and keeps it. Exclusion needs proof and
      inclusion does not: a file with a `using` in reach, an operand whose type
      does not infer, a name that resolves nowhere, or a scan past
      `REF_INFER_LIMIT` all fall back to the flat name match, since a usage
      dropped is a rename that leaves code broken. Still name-based where the type
      layer cannot see: an interface-free `v.field` on an uninferable operand.
      Workspace files come from the symbol index's per-file identifier sets — only
      files that mention the name are re-parsed.
- [x] **Signature help.** Ctrl+Shift+Space; `Signature_Help` request served by
      `signature_help`, which resolves the enclosing call's procedure (same-file,
      package-qualified and cross-file, reusing the goto resolution) and returns its
      signature line plus the byte range of the active parameter. Shown in a popup
      above the caret with the active argument bracketed. Auto-triggers on `(`/`,`
      and live-updates the active parameter as arguments are typed/edited (editor
      `on_signature` callback → `thor_editor_signature_help`, silent on miss).
      Overload sets landed: a call of a procedure group is signed once per
      member, the member matching the written arity marked, and go-to-definition
      on one offers the members rather than the list — see **Overload sets**
      above, whose "still open" note covers arity-picking a goto and type-based
      selection. The auto
      trigger is debounced, so a burst of keystrokes dispatches once — see
      request coalescing under scalability.
- [x] **Completion (semantic).** `Completion` request served by `complete`,
      driven from the editor as a word is typed (`on_completion` callback →
      `thor_editor_completion`, gated to Odin buffers by `completion_semantic`).
      Offers the identifiers in scope — locals/params visible at the caret, this
      file's and this package's top-level declarations — plus keywords, builtin
      types and the implicit scope the toolchain declares (`len`, `append`,
      served from the resident `Builtin_Cache`, so a keystroke costs no disk),
      all prefix-filtered (case-sensitive) and de-duplicated; after `pkg.`
      it lists the imported package's top-level symbols. Candidates fill the
      editor's existing autocomplete popup, tinted by kind. Name-based, like the
      rest of the engine: value member access (`v.field`) waits on type inference.
      Requests are debounced (~50ms), so a burst of keystrokes queues one request
      instead of a thread and a buffer clone per key — see request coalescing
      under scalability — and the sibling-package candidates come from the resident
      symbol index rather than a re-read and re-parse of every file in the package.
- [x] **Rename.** Ctrl+R, which falls back to find/replace when the caret is not
      on a renameable symbol (F2 already renames the *file*); `Rename` request
      served by `rename`, which runs the reference scan and turns each occurrence
      into a `Text_Edit`. The engine writes nothing — it returns `res.edits` and
      the host applies them, so an open buffer's change is one undo entry. Reach
      and precision are exactly references' — a local to its own scope, a
      top-level name to its package (bare there, qualified elsewhere), a field to
      the struct declaring it — plus the declaration, which find-usages leaves out
      and a rename must obviously rewrite. Where the scan cannot prove a binding
      it keeps the occurrence, so a rename is still wide before it is wrong. The
      new name must be a legal Odin identifier and not a keyword/builtin
      (`valid_identifier`); gated by `enable_rename`.
- [x] **Diagnostics.** A save queues a `Diagnostics` request for the saved file's
      package; `check.odin` runs `odin check` on a pool worker and answers a
      `Diagnostic_Report` — the checked `scope` plus every diagnostic in it, each
      a path with a 1-based line:col and a severity. The compiler is the source of
      truth, so the errors are exactly the build's, with no type checker to
      reimplement. Positions stay line:col across the seam because only the editor
      holds the buffers that map them onto byte offsets; `thor/diagnostics.odin`
      does that and retires the squiggles of files the new report dropped (which is
      what `scope` is for — a fixed file simply stops appearing). Debounced at
      `DEBOUNCE_CHECK` (400ms) so a save-all costs one compiler run rather than one
      per file, and serialized on the engine (`check_mutex`) so two checks never
      contend; a superseded one is cancelled and never spawns a process.
      Push-model diagnostics (an LSP server volunteering them between requests)
      would need a notification channel on the seam — the pull shape here fits a
      one-shot checker, not a live server.
- [~] **Code actions.** Ctrl+Shift+U (Ctrl+. is the command palette); a
      `Code_Actions` request served by `actions.odin`, whose producers each append
      a `lang.Code_Action` — a title, a kind, and the `Text_Edit`s that apply it.
      Unlike LSP there is no offer-then-resolve round trip: that split exists to
      keep IPC off the offer path, and an in-client backend has none, so computing
      the edits up front is both cheaper and free of the window where the buffer
      moves between offering a fix and applying it. Four producers, each reusing
      machinery that already existed:
      *add missing import* (an unresolved `pkg.member` — searches `core:`/`vendor:`/
      `base:` under `ODIN_ROOT` two levels deep, the config's collections, then the
      workspace for a relative import), *remove unused import* (the caret's, plus a
      bulk action; a `_` alias is never reported), *fill switch cases* (an enum
      switch missing arms, via the `visit_type_decl` enum locator behind implicit
      selectors; covered cases are read as the text after the last `.`, so
      `.Vertical` and `Axis.Vertical` both count), and *declare variable*
      (`count = 1` with nothing declaring `count` becomes `:=`).
      Host: `thor/codeactions.odin` clones the offers into Thor-owned storage (the
      Result is freed before the pick lands, as with the symbol picker's jump
      targets) and applies the chosen one through `thor_apply_edits` — the rename
      applier, generalized: every edit is verified against the content it will land
      in and the whole set is refused on any mismatch, so a fix never half-lands,
      and an open buffer takes it as one undo entry.
      Missing: the general "declare with an inferred type" form — inserting a
      declaration would have to name a type, and until the inference layer can
      compute one there is no correct text to insert, so only the `=` → `:=` shape
      is offered. Actions are also single-file and caret-driven; nothing is
      anchored on a diagnostic's range yet, and no producer spans files.
- [x] **Semantic highlighting (semantic tokens).** The point is the gap between
      what the grammar can prove and what the engine already knows: the
      highlights query paints a *use* of a parameter, a local, a package and an
      undeclared typo all `@variable` (`highlights.scm:80`), because
      `@parameter` is only attached at the declaration site (`:94`, `:96`).
      Resolution is the only thing that separates them, and this engine resolves.

      **The seam and the engine:**
      - `lang/lang.odin` — `Request_Kind.Semantic_Tokens`, a `Token_Kind` enum
        (`Parameter`/`Local`/`Field`/`Procedure`/`Type`/`Enum_Member`/`Package`/
        `Unresolved`), `Semantic_Token{start, end, kind}`, `Result.tokens`, freed
        in `job_free`. The token carries **no owned strings** — a file is
        thousands of tokens and a `string` kind would make this the heaviest
        allocator traffic in the seam by far, so the kind is an enum and the
        editor maps it to a colour itself.
      - `lang/odin/semantic.odin` (new) — `semantic_tokens` walks the cached tree
        and classifies each identifier through `resolve_local`/`collect_defs`,
        *the same resolution go-to-definition uses*, so a name's colour and the
        declaration Alt+Enter jumps to can never disagree. Pre-order over ordered
        children reaches identifiers in ascending byte order, which satisfies the
        seam's ordering contract with no sort.
      - `lang/odin/index.odin` — `index_declared_names` (every top-level name in
        the workspace, cloned, asked **once per request** so the walk needs no
        lock).
      - `lang/odin/builtins.odin` — the implicit scope (`Builtin_Cache`, guarded
        by `engine.odin`'s `builtin_mutex`); `resolve.odin` routes the kind
        beside `Document_Symbols`.

      **Deliberately sparse.** A token is emitted only where the analyzer knows
      more than the grammar. The positions the grammar already decides — struct
      fields, enum members, attributes, labels, the package clause, import
      aliases, and the whole right-hand side of a selector — are skipped by
      `semantic_skip` rather than re-derived, so a token can never overrule a
      correct colour with a worse one. A `::` constant and a package-level `var`
      are left alone for the same reason. The `enum_declaration` skip is narrowed
      to the members: the enum's *own* name reads like any other type
      declaration, and skipping the whole node had it come out classified where
      the sibling `struct_declaration`'s name did.

      **The unresolved check fails open.** Dimming a name the compiler is happy
      with reads as an error that does not exist, so `dimming_allowed` gives up
      the right to dim the *whole file* on any doubt: no workspace, a `using`
      statement anywhere (the one construct that injects names from a scope this
      engine does not follow — struct embedding is a `field`, not a
      `using_statement`, so it costs nothing), an import that `package_dir` cannot
      locate, an unreadable toolchain, or an index holding no file at all.

      **Builtins are read off the toolchain, not hardcoded.** The grammar has no
      builtin list, so `len`, `make`, `append`, `panic` and friends are plain
      `@variable` and would every one of them have dimmed. `builtin_names`
      (`lang/odin/builtins.odin`) takes the top-level declarations of
      `base:builtin` and `base:runtime` under `ODIN_ROOT` (once per process — it
      is a property of the compiler, not the workspace) and treats them all as in
      scope. Over-permissive on purpose, and the one consumer that stays that way:
      the cache marks which of those names a *bare* identifier actually reaches
      (see **The implicit scope**) and resolution and completion respect the mark,
      while dimming keeps the wider set. Over-permitting costs a missed dim where
      under-permitting flags correct code, and a list baked into this repo would
      rot the next time the language gains a builtin.

      **Host wiring — driven by the highlight pass, not by the caret.**
      `thor_update_highlights` (`thor/highlight.odin`) builds the grammar's
      spans as before, merges the file's classification over them, and then asks
      for the current revision's. The result handler
      (`thor_update_semantic`, `thor/lang_host.odin`) stores the tokens on the
      `Open_File` and marks the highlights stale, so the merge re-runs on the
      next frame — no second path into the editor, and a file catches up on its
      own after a burst of typing. `Open_File` carries `semantic` +
      `semantic_revision` + `semantic_ready` (revision 0 is a real revision, so
      "a result landed" needs its own flag); `Thor` carries
      `semantic_request_id` + `semantic_path` (owned — the tab may be closed and
      the record freed before the result lands, so the file is looked up by path
      rather than held by pointer).

      **One request at a time**, on top of the 50ms debounce. Nothing is waiting
      on the colours, and holding the slot until the last result lands paces a
      whole-file walk to its own round trip instead of firing one per keystroke.
      With a split view the two panes take turns across frames.

      **A stale overlay is applied, not dropped.** A result is merged even when
      the buffer has moved past the revision it was computed at: the offsets are
      then a keystroke or two behind, which is a far smaller lie than flashing
      the file back to plain syntax colours on every keystroke. The merge clamps
      them to the source and to the token before them, so a stale pair can never
      come out overlapping. Shifting the overlay past the edit instead (the
      `treecache.source_edit` diff already computes exactly that span) is still
      open; at this cadence it has not looked worth it.

      **The merge.** `thor_overlay_spans` interleaves two ascending,
      non-overlapping lists into one with the overlay winning — it replaces the
      colour across exactly its own range and the base spans around it are
      emitted clipped to what it left. That the output stays ascending and
      non-overlapping is load-bearing: the editor draws it with a single cursor
      that only ever moves forward. Covered by `thor/highlight_test.odin`
      (replace-and-clip, a token spanning several base spans, sparse-vs-sparse,
      either side empty, exact and adjacent).

      **Colours stay in the plugin.** `thor_token_capture` maps each `Token_Kind`
      to the tree-sitter capture name it stands in for and `plugin.role_for`
      resolves it through the language's own colour table, so a name the engine
      proved is a parameter takes exactly the colour the grammar gives a
      parameter it could prove itself. `Unresolved` is the one kind with no
      grammar counterpart and names a capture of its own (`unresolved`, mapped to
      `t.gray` by `plugins/odin/plugin.lua`); a language that leaves a capture
      unmapped has that kind dropped rather than repainted, keeping the grammar's
      answer. Fixed alongside: the Odin plugin mapped `parameter` to
      `t.variables` where every other plugin in the tree maps it to
      `t.parameters`.

      **Still open:**
      - The `Enum_Member` and `Field` kinds sit in the seam's vocabulary but the
        Odin backend never emits them — both positions are grammar-decided and
        skipped. They are kept for an LSP backend, which would.
      - Classifying a whole file has never been timed: `resolve_local` is a
        linear scan of `collect_defs` per identifier, so the walk is O(idents ×
        defs). The one-in-flight rule bounds how often it runs, not what it costs.
      - Tests are `lang/odin/semantic_test.odin` (param vs local vs package vs
        procedure vs type, the skip positions, ascending order, dimming an
        undeclared name, nothing reachable being dimmed, and one per kill switch
        asserting dimming stops while classification continues) plus the
        host-side merge tests above.

      **What the first real files broke.** Run over the repo itself, dimming lit
      up 44 of 353 identifiers in `lang/odin/semantic.odin` alone — every one of
      them reachable. None of it was a missing package: the causes were grammar
      shapes and scope rules the engine had not met, found by dumping each dimmed
      token's parent chain rather than by guessing.
      - A called, indexed or braced selector member sits *inside* the wrapper,
        not beside the operand: `pkg.run(x)` is
        `(member_expression pkg (call_expression run …))`, `pkg.Rect{}` is
        `(member_expression pkg (struct Rect …))`. A rule reading the
        identifier's direct parent never sees the selector at all, so
        `selector_subject` climbs out of those wrappers first.
      - An implicit enum selector `.Vertical` is a `member_expression` whose
        member *is* its first named child — the operand test claimed it. An
        operand starts where the selector starts; a dotted member starts past the
        dot, which separates them.
      - A named argument `run(whole_line = true)` is laid out flat inside the
        call: identifier, `=`, value.
      - `make :: proc{…}` is an `overloaded_procedure_declaration`, which
        `locals.scm` has no rule for, and `@(builtin)` puts an `attributes` node
        in front of the name. Named results (`-> (head, tail: string, ok: bool)`)
        are `named_type` nodes, uncaptured as well. `for &x in xs` wraps the loop
        variable in the `&`. All three now come out of `collect_value_decls`, so
        go-to-definition, completion and the symbol list gain them too.
      - A file-scope `when` is not a scope. `base:runtime` keeps `delete_key`,
        `make_map` and the rest of the map builtins inside `when MAP_ENABLED`,
        and treating that block as a scope dropped them from both the builtin
        cache and the workspace index.
- [ ] **Other LSP features not started:** formatting.

## Missing — scalability / performance

- [x] **Persistent symbol index.** Cross-file requests used to re-read *and
      re-parse* the whole workspace off-thread; the readdir is cheap, the
      per-file tree-sitter parse is the cost. Parsed top-level declarations are now
      resident on the `odin.Engine`, re-parsed only for files that changed, and
      every cross-file consumer queries them. Touched `lang/odin` almost
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
      - *Reindex on save*: `odin.engine_notify_saved(e, path)` called from
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
        **Landed** (`lang/odin`; `test_index_reflects_file_change` covers
        stat invalidation). Completion followed once the debounce was in place.
        Follow-up still open: `odin.engine_notify_saved` on `thor_save_file` (the
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
      scratch. `odin.Engine.trees` (a `treecache.Cache`) keeps a resident tree
      per buffer, and `treecache.for_source` — the single parse path for
      `req.source` in `odin.resolve` — reuses it: the cached source is diffed to
      one changed span, `ts.tree_edit` applies it, and the old tree seeds
      `parser_parse_string`, so tree-sitter rebuilds only the invalidated
      subtrees. An identical source (a hover landing on the same keystroke as a
      completion) skips the parse entirely.

      **Shared with the highlighter.** The cache lives in its own `treecache`
      package rather than here, because `syntax` parses the very same buffers for
      highlighting and folding and used to re-parse each of them whole on every
      keystroke — two strategies against one set of trees. Both now go through
      `treecache.for_source`; the entry records the grammar it was parsed under,
      so a path re-typed as another language drops its tree instead of seeding a
      parse the new grammar can't use. The package depends on the tree-sitter
      binding alone and on no grammar, so linking it costs neither caller
      anything it does not already link.

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

      **Cache shape.** `treecache.SLOTS` (8) entries, each a `{path, grammar,
      source, tree, used}`, retired least-recently-used — enough that alternating
      between open tabs doesn't thrash. Nothing invalidates explicitly: the diff
      absorbs every content change, and a closed or renamed file simply ages out.
      `for_source` returns `ts.tree_copy` of the entry (cheap, and what makes a
      tree safe to read on one worker while another re-parses the same buffer);
      the mutex spans the parse, so concurrent requests on one buffer serialize
      and the waiter gets the fresh tree.

      **Scope:** the request buffer only. The workspace files the cross-file
      scans visit (`index_reparse`, `ref_scan_file`, `scan_file`, …) are
      stat-gated by the symbol index and still parse whole — caching them would
      thrash the slots for no win.

      Covered here by `test_incremental_tree_matches_cold_parse` (nine successive
      edits, each comparing the incremental tree's s-expression against a cold
      parse of the same text), `test_incremental_reparse_tracks_edits` (goto stays
      correct across a sequence of edits), `test_tree_cache_is_per_path` and
      `test_tree_cache_evicts_and_reparses`; in `treecache` by
      `test_source_edit_spans` (insert/delete/replace/append/prepend/whole-buffer/
      UTF-8 spans) and `test_source_edit_points`; and in `syntax` by
      `test_incremental_highlight_matches_cold_parse`,
      `test_highlight_cache_is_per_path` (which also covers the grammar change)
      and `test_highlight_cache_evicts_and_reparses`.
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
      expensive loop — `odin.resolve`'s entry (the common case, where the worker is
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
      `DEBOUNCE_TYPING` (50ms, completion + auto signature help),
      `DEBOUNCE_HOVER` (150ms, unused so far — hover is already dwell-gated) and
      `DEBOUNCE_CHECK` (400ms, save-driven diagnostics — far longer because the
      work behind it is a whole compiler run).
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
      framing, JSON-RPC request/response id matching. (Note: `shell.run` — what
      `check.odin` drives the compiler with — is one-shot/blocking; a server needs
      a different lifecycle.)
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
  the same way as `filepath.abs`; verify on odd path spellings. `path_in_dir`
  folds separators and (on Windows) case, and `index_package_dir` retries a
  package directory absolute when the literal spelling matches nothing indexed,
  but neither resolves symlinks or 8.3 short names. A mismatch degrades to the
  old workspace-flat reach rather than to no answer.
- The vendored Odin `LOCALS` query models `:=` as `variable_declaration`, which
  this grammar does not produce — handled in `collect_short_decls`; revisit if
  the grammar is regenerated.
- Only `.odin` is handled in-client; other languages have no backend at all
  until the LSP client lands.
