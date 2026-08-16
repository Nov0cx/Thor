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
  does not. `CONTAINER_DEPTH_LIMIT` (24) bounds the nesting that is modelled at
  all; hitting it is logged (`log.debugf`) rather than silent.
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
  the grammar's colour stands. The analyzer still answers for the whole buffer,
  but that pass colours only the window a pane shows, so the overlay is clipped
  to it and follows the view. Undeclared-name dimming gives up on the whole
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
- **Workspace symbols:** Ctrl+Q lists *every* top-level declaration across the
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
  parameter list takes the number of arguments **written** (`arity_takes` over
  `param_arity` / `call_arg_count`) — every required parameter present and no
  more than the list holds, a variadic tail absorbing any surplus and a
  defaulted parameter left out at will. Counting what is
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
  reachable member is an unambiguous definition and is jumped to directly.

  **Several members are narrowed by the call at the caret** (`caret_call_site`
  reports the call the name heads, if it heads one — the caret on the group's own
  declaration heads none, and every member then stands). Two passes run over the
  resolved members, each only narrowing what the one before left:

  1. **Arity**, the same signal signature help picks its active entry with
     (`arity_takes`): every required parameter written and no more than the list
     takes, a variadic tail absorbing any surplus and a defaulted parameter
     (`loc := #caller_location`) counting as optional — without which
     `append(xs, 1)` reaches none of `append`'s members.
  2. **Argument types** (`types_fit`), each argument against the parameter in its
     own slot. An untyped literal fits by *class* rather than by one name, since
     it converts (`1` fits every numeric parameter, `"s"` every string one);
     anything else is inferred by `infer_expr_type` and compared by name and
     containers. Only a positive mismatch rejects: an argument that does not
     infer, a parameter that is polymorphic (`$T`) or `any`, and a call written
     with named arguments (`f(x = 1)`, whose slots are not the written order) all
     say nothing about any member.

  **A pass that leaves nothing standing is ignored** — a filter is evidence,
  never the last word, so an argument the engine reads wrongly costs a picker
  rather than the member the user asked for. One member left is the jump; the
  rest go to the picker, listing what survived. This holds on all three paths goto
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
  nested-type commas, a result tuple, variadic, a defaulted tail) and
  `test_hover_procedure_group_keeps_members`; goto by
  `test_definition_overload_offers_members` (members a slice argument cannot tell
  apart, one candidate each with its own jump target and line), `_picks_by_arity`
  (the call reaching one member is a jump), `_picks_by_literal_type` and
  `_picks_by_inferred_type` (members of one arity, separated by the argument),
  `_without_call_offers_members` (the caret on the declaration, so every member),
  `_single_member` (a jump, not a picker), `_falls_back_to_group`, `_cross_file`
  (index-resolved group, one member on disk beside it and one only in the unsaved
  buffer) and `_package_qualified` (narrowing through the package path).
  `test_definition_builtin_group` pins the toolchain's own `append`.

  **Still open:** the type pass reads what `infer_expr_type` reads and no more —
  a member taken by a distinct type, an alias, or a polymorphic parameter is
  neither chosen nor rejected, and an argument the inference layer cannot type
  leaves the picker. Widening that is the same precision work the rest of the
  type layer waits on.
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
  doesn't act on yet. The collections also reach the compiler: a `Diagnostics`
  run passes each as `-collection:<name>=<dir>`, since `odin check` reads no
  config of Thor's and would otherwise reject the import as a syntax error.
  Served by `config_ensure`/`config_collection_dir`/`config_collections`/
  `config_allows` in `lang/odin/config.odin`.
- **Feature gate (`language_intelligence` in `settings.json`):** the editor-level
  switch, one layer above the workspace analyzer file and independent of which
  backend serves a language. `true`/`false` is the master switch on its own;
  an object carries `"enabled"` plus one key per request kind
  (`lang.feature_name`: `definition`, `hover`, `document_symbols`,
  `workspace_symbols`, `references`, `signature_help`, `completion`,
  `package_doc`, `rename`, `diagnostics`, `code_actions`, `semantic_tokens`,
  `formatting`, `range_formatting`, `on_type_formatting`), each
  defaulting to on, so a file that never mentions the key runs everything. The
  gate lives on the `Manager` (`manager_set_enabled`/`manager_set_features`) and
  is enforced at the seam: a gated kind is refused by `manager_request` and
  `manager_request_debounced`, and turning one off cancels what it already has in
  flight, so no dispatch path can forget the check. `manager_supports` answers
  false for everything while the master switch is off, and `manager_allows(ext,
  kind)` is the per-kind question a caller with a fallback asks (rename falling
  back to find and replace). `thor_apply_language_settings` pushes the settings
  onto the manager on load and reload and retires what a disabled feature left on
  screen (diagnostics, semantic colors); the Settings modal shows the switch. It
  layers *with* the workspace analyzer file rather than replacing it: a feature
  runs only if both allow it — and a workspace `.thor/settings.json` can carry
  the same key, which is the per-folder way to gate a kind the analyzer file has
  no toggle for.
- **Per-backend gate (`language_backends` in `settings.json`):** the same
  enabled/per-kind shape as `language_intelligence`, one level down — an object
  keyed by backend id (`"odin"` for the in-client engine, an `lsp.json` server's
  own `id` otherwise) whose value is either a bare bool (that backend's master
  switch alone) or an object of `"enabled"` plus one key per request kind,
  layered the same way (only the keys a file names overlay what's already
  there). Read by `setting.backend_state`, backed by
  `General.language_backends: map[string]Backend_Setting`, whose `enabled_set` /
  `features_set` fields say which keys a layer actually stated.
  `thor_backend_gate` resolves the answer: a key the settings state wins, a key
  none of them state falls back to the backend's own default — an `lsp.json`
  entry's `enabled`/`features` for a server (`lsp.client_server_defaults`),
  everything on for the Odin engine. `thor_apply_language_settings` pushes the
  result onto both backends: `lsp.Server` gets `admin_enabled`/`admin_features`
  (atomic — `resolve` reads them off a worker thread through
  `client_server_for`), which `server_create` seeded from the config, so the
  settings own the gate the file only started; `odin.Engine` gets the same pair,
  read from its `handles`/`supports`. A disabled server is left running idle
  rather than stopped — the same "administratively blocked, not torn down"
  precedent the plugin-permission gate already sets — until the workspace reloads
  or the app exits. The Settings modal's "Language Servers" group lists every
  configured id (`lsp.client_server_ids` plus the fixed `"odin"`) as its own
  on/off row, including a server `lsp.json` turned off, so it can be turned back
  on; each enabled backend gets its own foldable "*id* Features" group of
  per-kind rows below it — the precise, per-backend version of the coarse
  `language_intelligence` gate above.
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
      unless the call at the caret reaches one of them by its arguments (see
      **Overload sets**).
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
      `switch v in u` case. An un-narrowed union offers no members at all,
      matching Odin's own rule — only `v.(` reaches it, completing the union's
      variants; the members reached that way come from the narrowed variant.

      A container answers for the members it has itself before the struct lookup
      runs (`lang/odin/container.odin`): a fixed array of up to four components
      swizzles over the `xyzw` and `rgba` sets (`v: [4]f32` reads `v.x` as `f32`
      and `v.xy` as `[2]f32`), and an `#soa` array holds one array per field of
      its element, so `s: #soa[]Point` reads `s.x` as `[]f32` and jumps to
      `Point`'s own `x`. A swizzle declares nothing, so it hovers but has no
      definition to jump to. Both spellings of the tag are read — the grammar puts
      `#soa` inside `array_type` for `#soa[]T` and beside the type node for
      `#soa[4]T`.

      `using` outside a struct is followed too (`lang/odin/using.odin`): the
      statement (`using p`) in the scope it sits in, from where it is written, and
      the parameter (`proc(using p: Point)`) over the whole procedure. The
      compiler gates the statement behind `#+feature using-stmt`, but the grammar
      parses it and code that enables it must still resolve. An ordinary binding
      always wins over a `using` field; only a struct field matched on name alone
      loses to one, since such a match names whichever struct happened to declare
      it while the `using` names the one that is open here.

      **Still open:** a `#soa` completion row labels the field with the element
      struct's own declaration rather than the array it is held in. That falls
      through to the flat name scan.

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
      `test_member_bit_set_element`), `lang/odin/container_test.odin` (swizzles,
      `#soa`, nested containers past the old eight-level cap and union-variant
      completion) and
      `lang/odin/using_test.odin` (the `using` statement and parameter: goto,
      hover, completion, scope and precedence).
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

      **Visibility attributes** are modelled. `collect_defs` records a
      `Def.visibility` for every top-level declaration, read off the `attributes`
      node (`decl_visibility`) rather than the text before the name — so a
      `private` inside an unrelated value (`@(link_name = "private_thing")`) is
      not mistaken for one — and the index carries it per row. `def_reaches` is
      the single predicate every cross-file consumer asks: `@(private)` (and its
      `@(private = "package")` spelling) reaches only the declaring directory,
      `@(private = "file")` no other file at all. Each caller says which side of
      that line it stands on rather than comparing paths per candidate: the
      package-scoped index pass is same-package by construction and the widened
      one is not, and a scan reached through a qualifier (`pkg.Name`, `pkg.f(`,
      `pkg.` completion, base:runtime) is always foreign. Goto, hover,
      completion, signature help, the type locator and the package-doc page all
      filter; the builtin cache drops base:runtime's private helpers.
      **Ctrl+Q does not**, deliberately — the workspace symbol picker is
      navigation, not name resolution, and a private declaration is still a place
      to jump to.

      Rename gains a correctness fix from the same model: a `@(private = "file")`
      declaration now narrows the scan to its own file (`Ref_Target.one_file`),
      where before a sibling's identically-spelled file-private procedure was
      renamed along with it.
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
      declared result.

      **Expression typing.** `binary_expr_type` (`infer.odin`) covers
      arithmetic and bitwise operators (`+ - * / % %% & | ~ << >> &~`, typed as
      whichever operand resolves — an untyped literal on the other side never
      does, so `x + 1` naturally takes `x`'s type with no separate
      untyped-constant representation), comparison and logical operators
      (`== != < <= > >= && ||`, always `bool`), `in`/`not_in`
      (`in_expression`, always `bool`), and `or_else` — confirmed by
      `ts-probe` to parse as a `binary_expression` with `or_else` as the
      operator token, not a distinct node type — which types as its left
      operand. `cast(T)v`/`transmute(T)v` were already covered.

      **Generics.** `polymorphic_call_result` (`generics.odin`) resolves a
      call's result when it reuses one of the callee's own polymorphic
      parameters: `identity :: proc(v: $T) -> T` (the bare shorthand),
      `first :: proc(xs: []$T) -> T` and `singleton :: proc(v: $T) -> []T`
      ($T wrapped in a container on either side — `map[K]`, `bit_set[E]`,
      `[]`/`[N]`/`[dynamic]`, composed with pointers), `deref :: proc(l: ^$T)
      -> T` (a pointer wrapping $T on the parameter side — transparent, like
      everywhere else a pointer appears in this engine), `pair :: proc(a: $T,
      b: $U) -> (T, U)` (several `$`-declared names composed into a tuple
      result, each slot resolved independently), and the explicit
      `identity2 :: proc($T: typeid, v: T) -> T` / `$T: typeid/Constraint`
      binding form (`ts-probe`-confirmed real Odin syntax — "specialization" —
      not shorthand). `peel_poly_shape` walks a parameter's or a result's
      pointer/container prefixes (the same grammar `result_type_ref` walks)
      down to a leaf that may be `$Name` or a plain `Name`; `polymorphic_params`
      collects every name a signature declares, and `result_poly_use` answers
      which one a given result slot reuses and what wraps it there. The
      substitution unwraps the parameter's container layers off the bound
      argument's own inferred type, then wraps the result's back on — the
      bare case is the zero-layers instance of this rule, not a separate path.

      Still open, deliberately: a named generic type's own type argument
      (`^List($T)`) — no `Type_Ref` anywhere carries one, since a plain `l:
      List(int)` doesn't retain its `int` argument either, so there is no data
      to read "the T of a `List(T)`-typed argument" from; and constraint
      *validation* (rejecting an argument that doesn't satisfy `$T:
      typeid/Ordered`) — only the binding site is recognized, never checked,
      since Thor's diagnostics already come from a real `odin check` run
      (`check.odin`) that validates this authoritatively, and duplicating a
      slice of the Odin type checker here would be redundant, much larger
      work for no benefit over what the compiler already reports.

      **Hover shows a computed type for a non-identifier expression.**
      `hover_expr` (`resolve.odin`) is a `Hover`-only fallback that runs after
      `identifier_at` fails on the caret — an operator, a cast's parens,
      `or_else`'s keyword — and climbs to the smallest enclosing expression
      `infer_expr_result` can type, rendering it with `type_ref_text`. A bare
      identifier always resolves through the ordinary declaration-text path
      first, since that only reaches this fallback by failing.
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
- [x] **Workspace symbols.** Ctrl+Q; `Workspace_Symbols` request served by
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
        `shared` of another package is no longer listed. A
        `@(private = "file")` one narrows further, to the declaring file alone
        (`Ref_Target.one_file`): no other file can name it, so the sibling files
        are not scanned and a same-spelled file-private declaration there is left
        alone;
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
      on one reaches the members rather than the list — the call's arity and its
      argument types picking one of them when they can, see **Overload sets**
      above, whose "still open" note covers what the type pass cannot read. The auto
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
      per file, and one run at a time: `Diagnostics` is in `EXCLUSIVE_KINDS`, so a
      request queued while a run is in flight waits in its debounce slot instead of
      on a worker — a compiler run cannot be interrupted, and blocking on it would
      pin the second of the pool's `WORKERS_MIN` threads for the run's whole
      duration. `check_mutex` backstops that with a try-lock (never a wait), and a
      superseded check is cancelled and never spawns a process. The run
      carries the workspace config's collections as `-collection:` flags; an entry
      the compiler would reject (a reserved name, a path that is not a directory)
      is dropped, because such a flag aborts the run before it checks anything.
      A run that never reached the compiler — `odin` absent from PATH, a flag it
      refused — fails with no parseable diagnostic, which is why `shell.run_status`
      reports the exit code: an empty report would read as "clean" and retire the
      whole package's squiggles, so it answers `ok = false` and they stand.
      Push-model diagnostics (an LSP server volunteering them between requests)
      have a channel on the seam since M0: `Backend.poll`, drained by
      `manager_dispatch` once per frame under the same feature gate a dispatch
      passes. Nothing produces them yet. The editor applies a report whose
      `revision` matches the live buffer *or* whose file still matches disk, so a
      server that checked the unsaved text and a compiler that checked the file
      are both correct; `Diagnostic_Report.scope` may name one file as well as a
      package directory.
- [x] **Code actions.** Ctrl+Shift+U (Ctrl+. is the command palette); a
      `Code_Actions` request served by `actions.odin`, whose producers each append
      a `lang.Code_Action` — a title, a kind, and the `Text_Edit`s that apply it.
      Unlike LSP there is no offer-then-resolve round trip: that split exists to
      keep IPC off the offer path, and an in-client backend has none, so computing
      the edits up front is both cheaper and free of the window where the buffer
      moves between offering a fix and applying it. Six producers, each reusing
      machinery that already existed:
      *add missing import* (an unresolved `pkg.member` — searches `core:`/`vendor:`/
      `base:` under `ODIN_ROOT` two levels deep, the config's collections, then the
      workspace for a relative import; also sweeps every sibling file the
      workspace index shows using the same unqualified package name, so one
      fix can add the import everywhere it is missing — see *multi-file edits*
      below), *fix diagnostic* (an `odin check` `'name' undeclared` diagnostic
      overlapping the caret delegates to add-missing-import from the
      diagnostic's own position, widening the trigger beyond the caret sitting
      exactly on the identifier; the LSP backend builds its own diagnostic
      context from its server cache and never reads this), *remove unused
      import* (the caret's, plus a bulk action; a `_` alias is never
      reported), *fill switch cases* (an enum switch missing arms, via the
      `visit_type_decl` enum locator behind implicit selectors; covered cases
      are read as the text after the last `.`, so `.Vertical` and
      `Axis.Vertical` both count), and *declare variable* (`count = 1` with
      nothing declaring `count` becomes `:=` — or, when the single RHS value
      types (§ Type inference above), `count: int := a + b` instead, falling
      back to the bare `:=` for anything inference can't type).
      Host: `thor/codeactions.odin` clones the offers into Thor-owned storage (the
      Result is freed before the pick lands, as with the symbol picker's jump
      targets) and applies the chosen one through `thor_apply_edits` — the rename
      applier, generalized: every edit is verified against the content it will land
      in and the whole set is refused on any mismatch, so a fix never half-lands,
      and an open buffer takes it as one undo entry.

      **Multi-file edits.** `Edit_Spec` (`actions.odin`) carries an optional
      `path`/`source` pair, defaulting to the request file; `push_action`
      clamps and slices old-text against whichever file a spec names, so one
      `Code_Action` can span several files' edits — proven today by
      add-missing-import, which finds sibling files through
      `index_ref_files` and re-parses each to place its own import line (or
      skip it, already imported). `thor_apply_edits` needed no change: it
      already groups edits by path and applies the set atomically, as rename's
      multi-file edits already exercised.

      **Diagnostic-anchored actions.** `Request.diagnostics` (`lang.odin`) is
      a new, optional `[]Diagnostic_Ref` (byte offsets already — the host
      converts line:col once, when it reads `Open_File.diagnostics`) threaded
      through `manager_request`/`manager_request_latest`/
      `manager_request_debounced`/`Pending`/`dispatch_owned` the same way the
      M9 selection-range `end` field was; `thor_code_actions` gathers the
      caret/selection's overlapping diagnostics before dispatching. Empty for
      every other request kind, and the LSP backend ignores it, keeping its
      own server-side diagnostic cache.
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

      **`Enum_Member` and `Field` are emitted for the qualified selector
      shapes.** `member_token_kind` (`semantic.odin`) runs before the grammar
      skip, on the *member* side of a qualified selector — `Axis.Vertical`,
      `p.x` — once the operand is a real identifier: it resolves the operand
      through the same bucketed lookup below, and if the operand names a
      type/enum it checks the identifier against the enum's members
      (`visit_type_decl(..., "enum_declaration", ...)`, the same locator
      `action_fill_switch_cases` uses); otherwise it tries `member_field_type`,
      the struct-field resolver goto/hover already share. A miss falls through
      to the ordinary skip — unclassified, never misread as unresolved.
      Bounded by `SEMANTIC_MEMBER_LIMIT` (512): past that many qualified
      selectors in one file, the rest are left unclassified rather than paying
      an unbounded per-selector resolution cost. **Still open:** an *implicit*
      selector (`.Vertical`, no operand at all) needs the far more expensive
      expected-type walk (`expected_type_at`) completion already pays for at
      the caret — deliberately out of scope for a whole-file pass, so it
      stays unclassified.

      **Classifying a whole file's shadowing resolution is bounded.**
      `semantic_tokens` groups `collect_defs`'s output by name once
      (`group_defs_by_name`) and `resolve_local_grouped` scans only the
      matching bucket per identifier, so the walk is no longer O(idents ×
      defs) — the per-identifier cost is now the shadowing depth at that name,
      not the file's total declaration count (`semantic_test.odin`'s
      `test_semantic_grouped_resolution_bucket_stays_bounded` asserts the
      bucket a synthetic file's tenfold growth leaves behind stays at 1). The
      member/enum resolution above is a separate, real per-selector cost this
      grouping does not touch, which is what `SEMANTIC_MEMBER_LIMIT` bounds
      instead.

      Tests are `lang/odin/semantic_test.odin` (param vs local vs package vs
      procedure vs type, the skip positions, the qualified enum-member/field
      shapes, an implicit selector and a package selector staying
      unclassified, the member-resolution cap, ascending order, dimming an
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
        variable in a `unary_expression`. All three now come out of
        `collect_value_decls`, so go-to-definition, completion and the symbol
        list gain them too — and `range_binding` (`infer.odin`) unwraps the same
        shape, so a by-reference loop variable infers its element type as well.
      - A file-scope `when` is not a scope. `base:runtime` keeps `delete_key`,
        `make_map` and the rest of the map builtins inside `when MAP_ENABLED`,
        and treating that block as a scope dropped them from both the builtin
        cache and the workspace index.
- [x] **Formatting.** Three seam entries — `lang.Request_Kind.Format`,
      `.Format_Range` (a whole-line-aligned selection) and `.Format_On_Type`
      (fired after a trigger character, debounced like completion) — served
      differently per backend. Odin: a native printer (`lang/odin/format`,
      package `odinfmt`) built on `core:odin/parser` — `core:odin/format`/
      `printer` are deprecated `#panic` stubs in the toolchain, so the printer
      is hand-written, not inherited — answers all three. The printer is
      whole-file only (`core:odin/parser` has no partial-parse entry point), so
      `.Format_Range` and `.Format_On_Type` format everything and keep only the
      diff spans inside their window: the selection for a range, the trigger's
      own line for on-type. A span that straddles the edge is dropped whole
      rather than half-applied, and only `.Format` may change the file's line
      endings. `}` is the engine's one on-type trigger. Every other language: the LSP
      backend (`lang/lsp/requests.odin`'s `METHODS`,
      `lang/lsp/capability.odin`'s `PROVIDER_KEYS`) sends all three as
      `textDocument/formatting` / `rangeFormatting` / `onTypeFormatting`, with
      `tabSize` from the buffer's `tab_width` and `insertSpaces` always true —
      Thor's editor is soft-tabs only. A reply is reconstructed against the
      request's own source and re-diffed (`lang.diff_spans`, shared with the
      Odin printer) into minimal edits, since most servers answer one TextEdit
      replacing the whole file. Odin's per-workspace options live in
      `.thor/odin-formatter.json` (odinfmt/OLS's schema; see
      `docs/configuration.md`), read by a stat-invalidated cache mirroring
      `odin-analyzer.json`'s; every other language's formatting follows the
      server's own config file. Triggered by `ctrl + alt + l` / "Edit: Format
      Document", `ctrl + alt + shift + l` / "Edit: Format Selection" (falls
      back to the whole document with no selection), `format_on_save` and
      `format_on_type` (both off by default). Odin refuses on any syntax error
      rather than guess; on-type formatting is silent on every outcome,
      including a stale result the buffer has since moved past. The printer's
      `character_width` wraps call argument lists, procedure parameter lists and
      composite literals, one item per line with a trailing comma, and hugs any
      list holding an argument that forces a line break (a proc literal) as
      before. `sort_imports` reorders a comment-free import run,
      collection-qualified paths first. `align_struct_fields` lines up struct
      field types, `align_struct_values` the `=` of enum members and multi-line
      composite literals and the `|` of a bit field, `align_constant_definitions`
      and `align_struct_declarations` the `::` of consecutive declarations.
      Missing, Odin-printer-only: wrapping of long binary-expression chains and
      procedure *result* lists, and alignment across a run split by a comment.

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
        parse for unchanged files. The walk is not free at 4000 files, so the
        kinds that redraw as the user types (`INDEX_TYPING_KINDS` — signature
        help, semantic tokens) reuse a walk younger than `INDEX_WALK_INTERVAL`
        instead of repeating it. Every other kind walks, including completion:
        a cross-file candidate list must show what the last request found.
        `index_forget` and `index_clear` drop the stamp.
      - *Reindex on save*: the engine's `notify` slot marks one path stale
        (`index_forget`) — a fast path over the stat-walk. No file watcher exists,
        so external edits rely on the stat-walk.
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
      full declaration text), `collect_workspace_symbols` (Ctrl+Q), and
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
        Follow-up landed: the engine now fills the seam's `notify` slot and drops
        the saved file's index entry (`index_forget`), so the next sync re-parses
        it whatever its stat says. The lock is a `try_lock` — this runs on the
        main thread, and a dropped invalidation only costs the stat gate catching
        the save instead.
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

## The optional LSP backend

The seam was prepared for it in M0; `lang/lsp` is the backend, and it now answers
every request kind the seam defines, including the two editing kinds (Rename,
Code Actions).

Prepared (`lang/lang.odin`, `thor/diagnostics.odin`):

- [x] `Backend.supports(data, ext, kind)` — per-kind capability, so a server that
      does definition but not rename says so. `nil` means every kind the backend
      claims by extension. Read by `manager_allows`, `manager_request` and
      `manager_request_debounced` through `backend_for_kind`; precedence stays
      all-or-nothing per extension, so a declining backend does not fall through
      to the next one. Main thread, and it must not lock: a worker may be inside
      `resolve` at the same time.
- [x] `Backend.poll(data, res)` — the notification channel, drained by
      `manager_dispatch` after the finished jobs, feature-gated, capped at
      `POLL_MAX_PER_FRAME` per backend. `Result.id` is 0 on a push.
- [x] `Backend.notify(data, event, path, ext, source, revision)` and
      `manager_notify` — `Doc_Event.{Opened, Changed, Saved, Closed}`, so document
      sync follows the editor's file lifecycle rather than only requests. Main
      thread, must not block. No host call site yet; the host wiring lands with
      the backend that acts on it.
- [x] `result_free` split out of `job_free`, so a pushed Result frees on the same
      path a job's does.
- [x] `lang.source_read` promoted out of `lang/odin`, so the CRLF-collapsed byte
      space every offset is counted in belongs to the seam.

Landed since (`lang/lsp`, M1–M7):

- [x] Long-lived child process with async stdio (a reader thread), `Content-Length`
      framing, JSON-RPC request/response id matching. `shell/child_*.odin` is the
      piped process pair; `transport.odin`, `framing.odin` and `jsonrpc.odin` are
      the layers over it.
- [x] LSP handshake (`initialize`/`initialized`, capabilities) and document sync.
      Sync is **full text**, not incremental: `thor_sync_lang_documents` sends at
      most one `didChange` per file per frame, keyed off `Open_File.lang_revision`.
- [x] UTF-16 position ↔ byte offset conversion at the backend edge
      (`position.odin`, both encodings, surrogate pairs, CRLF).
- [x] Server lifecycle: the merged table in `settings/lsp.json` +
      `<workspace>/.thor/lsp.json` (deliberately Thor's own file, not each
      server's), spawn on the first document event for a claimed extension,
      restart on crash with backoff, `shutdown`/`exit`/kill on exit.
- [x] Registered *after* the Odin engine, so in-client wins for `.odin` and the
      LSP covers everything else (clangd, rust-analyzer, gopls, …); an entry that
      sets `"override": true` for `.odin` swaps the order.
- [x] Ten request kinds answered: `Definition`, `Hover`, `Document_Symbols`,
      `Workspace_Symbols`, `References`, `Signature_Help`, `Completion`
      (plus `Resolve_Completion`, its follow-up),
      `Diagnostics`, `Semantic_Tokens` and `Package_Doc`
      (`requests.odin` for the method and the params, `decode.odin` for the
      reply). A request publishes its own buffer to the server before it names a
      position in it, since the pump drains document events on its own schedule.
      Semantic tokens are read against the legend the server advertised;
      `keyword`, `string`, `comment`, `number` and `operator` are dropped, so a
      server token never overrules a grammar color with a worse one, and
      `Unresolved` is never emitted — an absent token is not proof of an
      undeclared name. This is where `Field` and `Enum_Member` first become real.
      `workspace/symbol` carries the picker's typed text (see the
      `workspace/symbol` query entry below), and
      `thor_goto_workspace_symbol` (`thor/lang_host.odin`) does not send that
      initial round trip for a server-backed extension: a server that answers an
      empty query with nothing (clangd, gopls, pyright) would just come back
      empty anyway, so the picker opens straight into its "type to search" hint
      and the first real request is the one the user's typing dispatches.
      `Package_Doc` has no LSP method of its own; it rides `textDocument/hover`
      (`decode_package_doc`, unlike `decode_hover`, keeps the reply as Markdown
      rather than flattening it, and synthesizes the `title`/`path` a hover
      reply has no fields for).
- [x] Diagnostics both ways. `textDocument/publishDiagnostics` is decoded by the
      pump into the per-server push queue and taken by `manager_dispatch` through
      `Backend.poll`; `textDocument/diagnostic` is the pull, answered where the
      server advertises `diagnosticProvider`. A push for a file the editor never
      opened, and one for text a newer `didChange` already superseded, are both
      dropped — `Result.revision` is the editor revision the diagnosed text came
      from, which is what lets `thor_apply_diagnostics` place the positions
      against the live buffer. The protocol's four severities coarsen to the
      seam's two: only `Error` stays an error, `Warning`/`Information`/`Hint` all
      read as a warning, and a diagnostic that named no severity is an error.
      An `unchanged` pull report answers nothing; `relatedDocuments` is dropped.
- [x] Rename and Code Actions. `Rename` reconstructs `Text_Edit.old_text`
      itself — the field has no LSP counterpart — by reading the current bytes
      at each range from the request's own buffer, a server-held open document
      (`ask_source`'s third source, needed so a second open file's `old_text`
      verifies against its live text rather than a stale disk copy), or disk.
      A `WorkspaceEdit`'s `CreateFile`/`RenameFile`/`DeleteFile` entries decode
      into `lang.Resource_Op` (`Result.resource_ops`, `Code_Action.resource_ops`)
      alongside the text edits; we declare `resourceOperations:
      ["create","rename","delete"]` so a server is told it can send one.
      `thor_apply_edits` runs them in a fixed phase order — Create, then the
      text edits, then Rename, then Delete — rather than replaying
      `documentChanges`' own array position (see `lang.Resource_Op`'s doc
      comment for why that is enough in practice). Only an unrecognized `kind`
      still refuses the whole set. Neither a resource op nor the file it
      touches joins the edits' combined Ctrl+Z record — same as the explorer's
      own rename/delete, which have no undo of their own either; a follow-up
      would need new `Edit_Undo_File` variants for a reversible rename/delete.
      `Code_Actions` calls `codeAction/resolve` eagerly on the same
      worker for any action returned with no `edit`. An action that still has
      none is kept when it names a `command`: `Code_Action` carries the command
      and its arguments as raw JSON, and picking it dispatches
      `lang.Request_Kind.Execute_Command` (`workspace/executeCommand`, gated on
      `executeCommandProvider`) — the server's own changes come back through the
      pushed `workspace/applyEdit` path, so nothing waits on the reply. An action
      carrying both applies its edits first, the order LSP defines; one with
      neither is dropped. The in-client Odin engine declines the kind outright.
- [x] **Completion candidates carry everything the protocol gives them.**
      `lang.Completion_Item` (`lang.odin`) replaces the `Symbol` completion used
      to borrow: the row and the text to insert are separate, and the candidate
      also carries the byte range it replaces (`textEdit`), the changes it needs
      elsewhere (`additionalTextEdits`), its follow-up `command`, its
      `filterText`/`sortText`, whether the insert is a snippet template, and the
      raw JSON to echo back on resolve. `decode_completion` sorts by `sortText`
      before it answers — a server returns candidates unordered and states the
      order it wants in that key. `isIncomplete` reaches the popup as
      `Result.incomplete`: a complete list is narrowed client-side as the word
      grows instead of being asked for again on every keystroke.
      `insertReplaceSupport`, `labelDetailsSupport` and
      `completionList.itemDefaults` are deliberately not advertised, so a server
      must send one plain `TextEdit` per candidate and no shared defaults.
      An `InsertReplaceEdit` sent anyway takes its `replace` range.
      **Covered by** `test_decode_completion_text_edit`,
      `test_decode_completion_insert_replace_edit`,
      `test_decode_completion_sorts_by_sort_text`,
      `test_decode_completion_additional_edits_and_command` and
      `test_decode_completion_refuses_a_bad_text_edit`.
- [x] **`completionItem/resolve`, on accept.** `lang.Request_Kind`
      `.Resolve_Completion` (`completionItem/resolve`, gated on
      `completionProvider.resolveProvider`) sends the picked candidate back
      verbatim in `Request.item`, which is what TypeScript, Go and Rust servers
      need before they will produce an auto-import edit at all. Dispatched from
      `thor_completion_accept` (`thor/lang_host.odin`) *after* the text lands, so
      the edits it brings are validated by `thor_apply_edits` against what is
      really in the file and the whole set is refused rather than half-spliced.
      `resolveSupport` names `detail`, `documentation`, `additionalTextEdits` and
      `command`. The in-client Odin engine declines the kind outright — it
      computes everything up front.
      **Covered by** `test_decode_resolve_completion`,
      `test_decode_resolve_completion_without_edits` and
      `test_capabilities_completion_options`.
- [x] **Snippets, with tabstop navigation.** `snippetSupport` is advertised and
      `widgets/snippet.odin` parses the template: `$1`, `${1}`, `${1:default}`,
      `${1|a,b|}` (first alternative), `$0`, the `\$`/`\}`/`\\` escapes and the
      `TM_*` variables. Accepting one opens a session on the editor — the first
      placeholder is selected, Tab and Shift+Tab walk the stops, `$0` is where
      the caret leaves, and Escape ends it. The stops are plain byte offsets
      kept current by the typed delta alone, since `textedit` has no markers, so
      anything that cannot be followed — a second cursor, an undo, a batched
      edit, a caret that left the snippet — ends the session rather than guesses.
      **Still open:** a tabstop used twice mirrors the first's text at insert
      time only; editing one does not follow into the other. A
      `${1/regex/format/}` transform is dropped, the stop kept.
      **Covered by** `test_snippet_parse_grammar`, `test_snippet_parse_variables`,
      `test_snippet_session_walks_tabstops`, `test_snippet_session_follows_typing`
      and `test_snippet_session_ends_when_the_caret_leaves`.
- [x] **A real completion context.** `completionProvider.triggerCharacters` is
      read into `Capabilities.item_triggers`, and a request fired by one of them
      sends `triggerKind: 2` with the character instead of the `Invoked` (1) it
      always claimed — a server that offers members only on its own trigger
      lists nothing when the same keystroke arrives as an explicit request.
      `Request.trigger`, which was Format_On_Type-only, now carries the character
      just typed for completion as well.

Landed since (M9):

- [x] Re-reads the table and restarts the servers when the workspace changes.
      `thor_reload_lang` (`thor/lang_host.odin`) drains the Manager
      (`manager_cancel_all` + a `manager_busy` loop, the same guarantee
      `manager_destroy` gives every backend at shutdown), destroys the old
      `lsp` backend by name (`manager_backend_named`), builds a fresh `Client`
      against the new workspace root, and re-registers both backends in the
      override-decided order (`manager_set_backends` — a rebuild rather than a
      patch, since a workspace's `"override"` for `.odin` can flip relative to
      the last one). The in-client Odin engine is left running: it
      re-validates its own config file per request already.
- [x] Incremental `didChange`, per server. `Capabilities.sync_incremental`
      decodes `textDocumentSync.change == 2`; `server_publish` computes
      `treecache.source_edit(doc.text, source)` against the document's
      **previous** text and `Line_Index` (both about to be overwritten by
      `server_document`), converts the byte span with `position_from_offset`,
      and sends `did_change_incremental_params` — a ranged change carrying
      only the replaced substring. A server that doesn't advertise it (or
      advertises plain Full) still gets today's whole-buffer form; the first
      `didOpen` for a file is always full, since there is nothing yet to diff
      against.
- [x] A real `workspace/symbol` query. `lang.Request`/`Pending` gained a
      `query` field, cloned/freed the same four places `new_name` is
      (`dispatch_owned`'s no-backend path, `job_free`, `pending_clear`, the
      `Pending` copy); `manager_request`/`_latest`/`_debounced` all take it.
      `lang/lsp/requests.odin` sends `req.query` instead of the hardcoded
      `""`. The in-client Odin backend reads it too: `lang.symbol_matches`
      (`lang/match.odin`, a case-insensitive subsequence — ranking stays with
      the picker) filters both the live buffer's decls and `index_all_symbols`,
      so a keystroke on a large workspace carries back the matches instead of
      every symbol. Document outlines share `collect_symbols_into` and pass no
      query, so they stay unfiltered. Ctrl+Q's opening fetch is unchanged (empty
      query, whole list, client-side fuzzy filter);
      `widgets.Command_Palette` gained an `on_query_changed`
      hook, fired on an actual keystroke and never on the reset a picker
      opens with, that `thor_goto_workspace_symbol` wires to
      `thor_workspace_symbol_query_changed` — a debounced re-dispatch
      carrying the typed text, re-marking the picker loading
      (`command_palette_set_loading`) without clearing its current rows. An
      empty result from a *typing*-triggered re-dispatch
      (`Thor.workspace_symbols_typing`) empties the list rather than closing
      the picker the way an empty *initial* scan still does.
- [x] `semanticTokens/full/delta`. `Capabilities.token_delta` decodes
      `semanticTokensProvider.full.delta`; each `Document` caches the flat
      delta-encoded array and `resultId` from its last reply
      (`server_store_semantic`/`server_semantic_data`/
      `server_semantic_result_id`, all under `docs_mutex`). A request for a
      file with a cached id asks `.../full/delta` with `previousResultId`
      instead of `.../full`; `decode.odin`'s `apply_semantic_edits` splices
      each edit against the array the edit before it left, in the order the
      protocol defines. Resolved entirely inside `lang/lsp` — `res.tokens`
      leaving the package is always the same full, absolute list a `full`
      reply decodes to, delta or not, so neither the seam nor
      `thor_update_semantic` changed. An edit whose range falls outside the
      cached array (a restart) answers nothing and drops the cache
      (`server_clear_semantic`), so the next request asks for `full` again
      instead of feeding a bad array into another delta.
- [x] `$/progress` into the statusline. `lang.Request_Kind` gained a push-only
      `Progress` kind and `Result` a `Progress_Info` (`message`, `done`);
      `server_drain_pushes` decodes a `$/progress` notification's `begin`/
      `report` into a message (`message`, falling back to `title`, with
      `"(N%)"` appended when `percentage` is present) and `end` into
      `done = true` with an empty one. `thor_apply_progress`
      (`thor/lang_host.odin`) stores it on `Thor.lsp_progress_message`, which
      `thor_status_info` shows in place of the generic `thor_lang_busy_label`
      text whenever it is set.
- [x] `workspace/applyEdit` routed through the push channel. `Conn_Answers`
      gained an `apply_edit` callback the owning `Server` wires
      (`server_apply_edit`); it decodes `params["edit"]` with the same
      `decode_workspace_edit` `Rename` uses (against a synthetic `Request`
      whose empty `path` never shortcuts `resolve_range`/`ask_source`, so
      every file resolves through the server's open documents or disk), sorts
      them ascending by (path, start) as `Rename` does — a server lists one
      file's edits in any order, and the applier splices a closed file straight
      by that order — pushes a push-only `Apply_Edit` result carrying the edits
      plus a `token`/`on_applied` reply pair, and blocks up to
      `APPLY_EDIT_TIMEOUT` for the main thread to answer. `thor_apply_pushed_edit` (`thor/lang_host.odin`)
      applies it through `thor_apply_edits` — the same all-or-nothing applier
      Rename and Code Actions use — then calls `on_applied` with the result.
      An `Apply_Wait`'s two-sided refcount (the pump's bounded wait and the
      main thread's callback) means whichever side finishes second frees it,
      so a starved push (feature gated off, or dropped at shutdown) still
      answers the server honestly instead of hanging it.
- [x] A selection range on `Request`, unlocking selection-scoped code actions.
      `Request` gained an `end` field (defaulting to `offset`, so every
      existing call site is unaffected); `thor_code_actions`
      (`thor/codeactions.odin`) reads `textedit.selection_range` instead of
      only the caret, and `lang/lsp/requests.odin`'s `Code_Actions` params
      builder sends `[offset, end)` instead of a hardcoded zero-width range.
      The in-client Odin engine's code-actions path stays caret-only by
      design and simply ignores `end`.
- [x] Ctrl+Q's picker shows an explicit "type to search" hint instead of a
      bare blank list when a server-backed workspace scan lands empty because
      it needs a typed query (pyright, gopls, clangd) — `Command_Palette`
      gained a `pick_hint` field, shown with the same reserved-row mechanism
      as the "Loading…" state and cleared the moment real rows land.
      `thor_update_workspace_symbols` passes it only for the needs-query,
      not-yet-typed case; a genuinely empty result after typing still reads
      as "no matches", same as every other fuzzy search.
- [x] `codeAction` requests carry live diagnostics instead of a hardcoded
      `context.diagnostics: []` — a server that only offers a fix when it sees
      its own diagnostic in the request (basedpyright's "add missing import") never
      offered it otherwise, so `codeAction/resolve` never had anything to
      resolve. Each `Document` caches its last publish/pull diagnostics
      verbatim (`Cached_Diagnostic`, `lang/lsp/document.odin`); the pull and
      push decoders (`decode_pull_diagnostics`, `decode_publish_diagnostics`)
      replace the cache under `docs_mutex`. `server_code_action_diagnostics`
      (`server.odin`) filters it to the diagnostics overlapping the request's
      range (inclusive at the edges, so a zero-width caret still matches a
      diagnostic that starts or ends exactly there) and joins their JSON
      verbatim into the outgoing request — deliberately not through the
      seam's own `lang.Diagnostic`, which coarsens severity and drops `code`,
      the field a server like basedpyright keys its fixes on.
- [x] `thor_edit_target` (`thor/lang_host.odin`) recognized the origin buffer
      with `canonical == origin`, a plain string compare. A server's edit
      names its file by the drive letter it spelled the URI with — basedpyright
      lowercases it — which need not match the case Thor opened the file
      under, so the compare missed even though `thor_same_path` (used one line
      above, for the same file) would have matched. A missed match fell
      through to the "already saved" branch, which an unsaved buffer always
      fails: exactly the state a quick fix is applied from, so "add missing
      import" landed the edit from the server but silently never applied it.
      Fixed by comparing with `thor_same_path` there too.

Still to add: nothing from the M9 list — it is complete.

### M10 — setup and visibility

Everything around the client, rather than the protocol. What was missing was
never a feature: it was getting a server configured, knowing whether it worked,
and changing it without a restart.

- [x] `Config_Problem` (`lang/lsp/config.odin`): every silent drop reports
      instead — invalid JSON, a non-object root, a missing or non-array
      `servers`, an entry with no `id`, a known key of the wrong type, an
      unknown key (a warning, never a drop, so a file written for a later
      version still loads), and an entry `config_finish` drops for naming no
      command. Exported by `client_diagnostics`, rendered by the panel, and
      logged once at `config_load`.
- [x] `initialization_options` also accepts `init_options`, the spelling the
      documentation carried.
- [x] Schema: `name`, `install` (per platform, resolved at parse time against
      `ODIN_OS` so the host makes no platform decision), `docs_url`,
      `setup_command`, and `${workspace}` / `${userHome}` / `${env:NAME}`
      expansion in `command`, `cwd` and `env` values. An unresolvable name is
      left as written and reported.
- [x] `Server_Status` + `client_server_status` / `client_extension_owner` /
      `server_state_name` (`lang/lsp/lsp.odin`): the state, the resolved
      program, the root, the restart count, the last error, and the entry that
      took the extension when a second one claims it. `status_mutex` is the new
      leaf lock over `root`, `restarts` and `last_error`; the pump snapshots the
      stderr tail into `last_error` at the moment a start fails, since
      `conn_lock` is held shared for a whole round trip and a live read of it
      could wait out a request.
- [x] Pushed `publishDiagnostics`, `$/progress` and `workspace/applyEdit` now
      pass the Settings-owned `server_admin_features` gate, not the `lsp.json`
      seed. Turning Diagnostics off for one server in Settings stops its pushes.
- [x] Editor side (`thor/lsp_ui.odin`, `thor/lsp_config.odin`): a Language
      Servers settings category with status, install, restart, docs and an
      "Add a Server…" writer; `lsp.json` watched in all three layers and
      reloaded through `thor.lang_reload_pending` at the head of the run loop;
      `thor_reload_lang` re-mirrors the open buffers onto the new servers and
      drops what the dead ones left on screen; `thor_poll_lsp_health` says once
      when a server fails, crashes or comes back.
- [x] The seven `plugins/*-setup` Lua plugins are gone. Their PATH check is
      `lsp.executable_find` (no process spawn), their install table is the
      `install` key, and their one genuinely external piece —
      `compile_commands.json` detection — is `plugins/compile-commands`, reached
      from the panel through `setup_command`.

Cut from M10, deliberately:

- **Multiple servers per language.** One enabled entry answers for an extension.
  The collision is now visible (`Server_Status.claimed_by`) instead of silent,
  which is a different thing from fixing it.
- **`filenames` for extensionless files** (`Makefile`, `CMakeLists.txt`). It
  reads like an `lsp.json` key and is really a change to the seam's routing
  key: `lang.Manager`, `handles`, `supports`, `notify` and `on_type_trigger` all
  key on an extension.
- **Per-server restart.** `stopping` is a one-way latch and the "no worker in
  flight" precondition needs the whole-manager drain `thor_reload_lang` does.

`LSP_PLAN.md` is the implementation plan for all of it: the `lang/lsp` package
and what it may import, the child process and `Content-Length` transport, the
notification channel a pushed `publishDiagnostics` needs, the per-kind method
mapping, the position-encoding edge, `settings/lsp.json`, the headless test
strategy, and the milestone order. Read it before starting here; it is a design,
not a status, so this section stays the source of truth for what is built.

## Known limitations / cleanups

- `index_package_dir` now resolves a symlink or (on Windows) an 8.3 short name
  that makes a package directory's spelling disagree with the index: past the
  literal and `filepath.abs` tiers, a third tier asks the OS for each side's
  canonical spelling (`path_real`, `lang/odin/path_windows.odin` /
  `path_posix.odin` — `GetFinalPathNameByHandleW` on Windows, already-realpath
  `filepath.abs` on POSIX) and compares those. Only runs once the cheap tiers
  miss, so a workspace with matching spellings pays nothing extra. `path_equal`
  and `path_in_dir` themselves stay a literal, separator/case-folded compare —
  they run inside per-file loops over the whole index, where a `path_real` call
  per file would reintroduce the cost tier 3 exists to avoid. Their remaining
  imprecision (the `skip` exclusion missing a live buffer's own stale index
  entry under a mismatched spelling) is a duplicate-or-briefly-stale candidate,
  self-healing on the next stat-walk, not a wrong answer.
- The vendored Odin `LOCALS` query models `:=` as `variable_declaration`, which
  this grammar does not produce — handled in `collect_short_decls`; revisit if
  the grammar is regenerated.
- Only `.odin` is handled in-client. Another language is answered by a
  configured language server, which reaches only as far as that server does.
  `Package_Doc` rides `textDocument/hover`, `Workspace_Symbols`' initial empty
  query is no longer sent at all for a server-backed extension (the picker
  opens straight into its "type to search" hint; a query-gated server
  answering nothing until typed is still a protocol characteristic, not a
  dispatch bug), and `Rename`/`Code_Actions`/a pushed `applyEdit` now apply a
  `WorkspaceEdit`'s `CreateFile`/`RenameFile`/`DeleteFile` operations
  (`lang.Resource_Op`) — in a fixed phase order rather than
  `documentChanges`' own array position, and with no Ctrl+Z of their own (see
  `lang.Resource_Op`'s doc comment and the M9 Rename/Code Actions entry
  above). A follow-up: reversible resource ops would need new
  `Edit_Undo_File` variants.
