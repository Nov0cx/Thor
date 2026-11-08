# Language intelligence

This is the living
source of truth: read it before you add a feature to `lang/`, and update it afterwards.

Sources rank in this order when they disagree: the code, then `CLAUDE.md`, then this file.

This file replaces `ROADMAP.md`, `LSP_PLAN.md` and `odin-analyzer-plan.md`. The numbered
milestones of those files are gone; git history keeps them.

Contents:

1. [Overview and status](#1-overview-and-status)
2. [The seam (`lang`)](#2-the-seam-lang)
3. [The host (`thor`)](#3-the-host-thor)
4. [The in-client Odin analyzer](#4-the-in-client-odin-analyzer)
5. [Diagnostics: tiers, ids, suppression](#5-diagnostics-tiers-ids-suppression)
6. [The formatter](#6-the-formatter)
7. [The LSP backend (`lang/lsp`)](#7-the-lsp-backend-langlsp)
8. [Adding a language](#8-adding-a-language)
9. [Design decisions](#9-design-decisions)
10. [Missing](#10-missing)
11. [Known issues](#11-known-issues)

---

## 1. Overview and status

Thor serves LSP-style features in two ways, behind one interface:

| Path | For | How |
| --- | --- | --- |
| In-client analyzer | Odin | A native analyzer on worker threads. It shares the buffer by pointer. No JSON, no IPC. |
| LSP client | Every other language | A subprocess language server. `lang/lsp` talks JSON-RPC to it. |

The editor only talks to `lang.Manager`. It does not know which path answers.

Status on branch `odin_analyzer`:

- The tree-sitter Odin engine is gone. The Odin analyzer is a rebuild on its own front end
  (`lang/odin/syntax`) and its own analysis layer (`lang/odin/sema`).
- Every `lang.Request_Kind` the old engine answered is back, and more (inlay hints, hierarchies,
  code lens, refactorings, lints). Section 4 lists each kind and its file.
- The branch is not merged. The rebuild stays off `master` until it is ready, so no release uses it
  (decision in section 9).
- `lang/lsp` is complete: milestones M0 to M11 are built.

tree-sitter remains for **highlighting** of every language, Odin included. It is not used for
analysis.

---

## 2. The seam (`lang`)

`lang/lang.odin` is the only contract between the editor and an analyzer.

### Backend

```odin
Backend :: struct {
    data:    rawptr,
    name:    string,
    handles: proc(data: rawptr, ext: string) -> bool,
    resolve: proc(data: rawptr, req: ^Request, res: ^Result),
    destroy: proc(data: rawptr),
    // Optional (nil means the default):
    supports:        proc(data: rawptr, ext: string, kind: Request_Kind) -> bool,
    poll:            proc(data: rawptr, res: ^Result) -> bool,
    notify:          proc(data: rawptr, event: Doc_Event, path, ext, source: string, revision: u64),
    on_type_trigger: proc(data: rawptr, ext: string, char: string) -> bool,
}
```

| Field | Rule |
| --- | --- |
| `handles` | Main thread. Claims a routing key (see below). No lock. |
| `resolve` | **Worker thread.** May block (parse, disk scan, pipe read). Must poll `lang.request_cancelled(req)` in long loops. |
| `supports` | Main thread, while a worker may be inside `resolve`. Read only atomically published data. **Never lock.** `nil` means every kind the backend claims. |
| `poll` | Main thread, once per frame, until it returns false. For results nobody asked for (pushed diagnostics). `Result.id` is 0. Capped at `POLL_MAX_PER_FRAME` per backend. |
| `notify` | Main thread. Must not block. Tells the backend a buffer was opened, changed, saved or closed (`Doc_Event`). |
| `on_type_trigger` | The caller **must** ask before it sends `Format_On_Type`. `nil` means never. |
| `destroy` | Called after the worker pool is gone. No worker is inside `resolve`. |

### Manager

- `manager_register(m, backend)` — **registration order is precedence.** `backend_for` returns the
  first backend whose `handles` is true. Precedence is all-or-nothing per routing key: a backend that
  declines one kind does not hand it to the next backend.
- `manager_set_backends(m, backends...)` — variadic. Replaces the whole list.
- Routing key: `thor_lang_key`. It is a file's bare name when a backend claims that name
  (`lang.manager_claims`, outside the `enabled` gate so the key never moves), else its extension.
  A name beats an extension, so `CMakeLists.txt` reaches a cmake server and not a `.txt` one.
- A bounded worker pool (`WORKERS_MIN` 2, `WORKERS_MAX` 4) runs `resolve`.
- Results come back to the main thread through a lock-free stack (`lockfree.Stack`).
  `manager_dispatch` reaps them once per frame and then drains each backend `poll`.

### Dispatch rules

Every request kind has exactly one consumer slot (`*_request_id`) on `Thor`. Use one of:

- `manager_request_latest` — immediate; cancels the older request of the same kind.
- `manager_request_debounced` — for triggers that fire while typing (`DEBOUNCE_TYPING` 50 ms,
  `DEBOUNCE_HOVER` 150 ms, `DEBOUNCE_CHECK` 400 ms).
- `manager_request` — when a second consumer must not cancel the first (peek definition).

A cancelled result is freed without reaching the handler. So `ok == false` always means "found
nothing".

`EXCLUSIVE_KINDS` (`Diagnostics`) never have two jobs in flight. A second one waits in its debounce
slot. It does not take a worker, because that starves the pool.

### The three gates

A kind runs only when all three allow it:

1. `language_intelligence` in `settings.lua` — master switch plus one key per kind
   (`lang.feature_name`). Enforced in the Manager: `manager_request` refuses a gated kind and
   cancels what is in flight. It also gates `poll` output.
2. `language_backends` — one level down. Keyed by backend id (`"odin"`, or an `lsp.lua` server id).
   A bool, or `enabled` plus one key per kind. Read by `setting.backend_state`, resolved by
   `thor_backend_gate`, pushed by `thor_apply_language_settings`.
3. The backend's own `supports`: the Odin `IMPLEMENTED` set and `admin_features`, or an LSP server's
   advertised capabilities.

`manager_allows(ext, kind)` is the question a caller with a fallback asks. Rename falls back to find
and replace.

### Positions and ownership

- **Byte offsets are the position currency.** They count over source with CRLF collapsed to LF, the
  form the editor holds a buffer in. Read files with `lang.source_read`. Never use
  `os.read_entire_file` in a backend; offsets into a CRLF file then miss by one byte per line.
- A backend that wants the buffer changed answers with `Text_Edit`s. It never writes a file itself.
  Each `Text_Edit` carries `old_text`; the host refuses the whole set when one does not match.
  Edits are sorted ascending by `(path, start)`.
- `Resource_Op` (create, rename, delete) travels beside the edits. The host applies the phases in
  fixed order: create, text edits, rename, delete.
- Strings in a `Result` are owned. They use the Manager allocator, and `lang.result_free` frees them.

### Request kinds

`Definition`, `Type_Definition`, `Hover`, `Document_Symbols`, `Workspace_Symbols`, `References`,
`Signature_Help`, `Completion`, `Resolve_Completion`, `Package_Doc`, `Rename`, `Diagnostics`,
`Syntax_Diagnostics`, `Code_Actions`, `Resolve_Action`, `Execute_Command`, `Semantic_Tokens`,
`Inlay_Hints`, `Document_Highlight`, `Format`, `Format_Range`, `Format_On_Type`, `Call_Hierarchy`,
`Type_Hierarchy`, `Implementations`, `Selection_Range`, `Code_Lens`.

Push-only kinds, never sent by the editor: `Progress`, `Message`, `Apply_Edit`.

---

## 3. The host (`thor`)

`thor/lang_host.odin` is the editor side.

- It dispatches requests, routes each result to the pane that asked, and drops superseded ones.
- `thor_lang_notify` and `thor_sync_lang_documents` mirror the open buffers onto a backend that
  tracks documents. At most one `.Changed` per file per frame, driven by `Open_File.lang_revision`.
- `thor_apply_edits` is the all-or-nothing applier for every backend edit set. Open buffers go
  through `textedit.replace_ranges` (one undo entry per file). Closed files are rewritten. The whole
  refactor, files included, is one Ctrl+Z record. A target that cannot be restored from a string (a
  directory) drops the record and the set stays unrecorded.
- `thor_apply_diagnostics` places a report when `res.revision` matches the live buffer **or** the
  buffer still matches disk. The first case is a server that checked the text we sent. The second is
  a compiler that checked the file.
- `thor_reload_lang` rebuilds the LSP client when the workspace or an `lsp.lua` layer changes. It
  drains the Manager first. It must never run inside an event callback; the paths set
  `thor.lang_reload_pending` and the head of the run loop acts.
- Peek definition (`thor/peek.odin`) is a second consumer of `.Definition`. It uses
  `manager_request`, not `_latest`, so a go-to in flight survives. It works for every backend.
- Go back and forward (`thor/jumplist.odin`) record in `thor_goto_location`, so every route into a
  jump is covered.

Features the host adds on top of the kinds: statusline busy indicator (`manager_busy_kinds`,
0.25 s delay), explained diagnostics on hover, Problems panel (`thor/problems.odin`), inlay pills
(`thor/inlays.odin`), occurrence highlights (`thor/occurrences.odin`), code actions menu
(`thor/codeactions.odin`), snippet sessions (`snippet/`). For key bindings see
[`docs/keybindings.md`](../docs/keybindings.md).

---

## 4. The in-client Odin analyzer

Three layers, each a leaf over the one below. None of the lower two imports `lang`.

```
lang/odin           Backend glue + one handler per request kind        imports lang, odinsema, odinsyntax, odinfmt
lang/odin/sema      Analysis: query DB, scopes, types, checks          imports odinsyntax, core:
lang/odin/syntax    Lexer, resilient parser, lossless tree             imports core:
lang/odin/format    Printer (package odinfmt)                          imports odinsyntax
```

Package names: `odin`, `odinsema`, `odinsyntax`, `odinfmt`, `syntaxgen`.

### 4.1 Syntax (`lang/odin/syntax`)

- **Lexer.** Never fails. Trivia (whitespace, comments, newlines) are tokens, so the tree is
  lossless. Odin's automatic semicolons are a flag on the newline token. Restartable at any token
  boundary. About 100 MB/s with `-o:speed`.
- **Parser.** Recursive descent. It follows `core:odin/parser` rule by rule but builds green nodes
  and never fails.
  - A missing token is left out of its node, not invented. `a.` is a `Selector_Expr` with no field.
    `foo(` at EOF is a call with an open `Arg_List`.
  - Skipped tokens go into one `Error` node. A skip takes whole bracket groups and never a `}` that
    closes an open block.
  - A newline after `.` or `->` ends the expression, so a dangling selector does not take the next
    line.
  - Nesting and operator chains share a depth limit of 400 (`Too_Deep`).
- **Tree.** A token holds no text. It is inline in an 8-byte child slot with kind, flags and length.
  A node is an 8-byte header with its children after it. The tree owns one copy of the source. About
  5.6 bytes per source byte. A node is known by its position, not its green pointer. Read text
  through the red layer (`syntax_token_text`, `node_text`).
- **Typed views.** `syntax.schema` lists every node kind, its categories and the children its view
  reads. `odin run build.odin -file -- gen_syntax` writes `kind.odin` and `views.odin`
  (`lang/odin/syntax/gen`). Edit the schema, never the generated files. A test fails when they are
  stale. `as_<kind>` casts; `<kind>_<child>(&view)` reads a child with no allocation and returns
  false when it is missing.
- **Incremental reparse.** `reparse(&old, src)` gives the tree `parse(src)` would give.
  1. One token that changes only its length is patched in place.
  2. Else the smallest `{ }` block around the edit is lexed and parsed alone, when its braces stay
     balanced.
  3. Else the whole text is parsed.

  Untouched subtrees are shared. The new tree owns the old one as its `base`, so free only the
  newest. After `MAX_GENERATIONS` (32) a full parse ends the chain. One keystroke in a 3,000-line
  file takes about 0.12 ms.
- **Checks.** `corpus_test.odin`: every file of Thor plus `base`/`core`/`vendor` parses losslessly.
  Each of about 1,900 files `core:odin/parser` accepts gives zero errors and the same declarations
  and expression nodes. 20,000 rounds of random edits and every prefix of a file parse with no stuck
  loop. `snapshot_test.odin` holds one input per language group in `testdata/*.odin.txt`
  (`-define:SYNTAX_BLESS=true` rewrites the `.dump` files).
- `Syntax_Diagnostics` reports parse errors live, debounced, for the pane on screen.

### 4.2 Sema (`lang/odin/sema`)

**Query database** (`db*.odin`). One `Db` per engine, shared by every worker.

- Files and package directories are interned by `path_key` as `File_Id` and `Package_Id`. An id is
  never reused.
- A request opens a `Snapshot` (`snapshot_begin`) and reads `db_file`, `db_parse`, `db_in_build`,
  `db_imports`, `db_package` and `db_workspace`. Values are immutable and refcounted. A snapshot pins
  what it reads until `snapshot_end`.
- Memos refresh by stat once per snapshot, and the workspace at most once a second
  (`WORKSPACE_INTERVAL`). A save reaches the engine through `notify`, whose `db_touch` makes that file
  current at once.
- Early cutoff: a package memo records the `shape_changed_at` of each file (`item_tree_shape_hash`).
  A body edit keeps the scope.
- Lock order: workspace slot, package slot, file slot, then `Db.lock`, `Db.lru_mutex` or
  `Db.type_mutex`.
- Limits: disk parses 64 MB (`BODY_BUDGET`), 8 live parses (`LIVE_SLOTS`), 64 package memos, 64 loose
  files. A workspace walk stops at 4,000 files and 12 levels.

**Layers.**

| File(s) | What |
| --- | --- |
| `item_tree.odin`, `nested.odin` | Top-level declarations of one file: kind, visibility, attributes, doc comment, one-line signature, children. `when` branches kept as guards. Owns its strings. |
| `target.odin`, `files.odin` | `file_in_build`: the compiler's file-name suffix rules and `#+build` expressions. Target is the host, overlaid by `target` and `defines` in `odin-analyzer.lua`, then per file by the `file_targets` setting (`file_target.odin`; an unknown target is ignored with a log warning). |
| `when.odin` | `guard_state` evaluates a compiled `when` condition to true, false or unknown. Unknown counts as active. |
| `package.odin`, `imports.odin` | `package_scope` (name to items, with conflicts), `file_imports` (alias to package directory). An item under a false `when` stays for navigation, marked inactive, and never conflicts. |
| `scope.odin`, `resolve.odin`, `using.odin` | `scope_map`: what each identifier in a body names lexically. `using` expansion. |
| `types.odin`, `check.odin`, `const.odin` | The interned `Type_Table`, `decl_type`, `type_expr`, constant evaluation. A named type is unique by its `Symbol`. |
| `expr.odin`, `call.odin`, `builtins_check.odin`, `where.odin` | `expr_type`, calls, groups, generics. `choose_member` scores overloads by the compiler's distance rules. `where` clauses and their intrinsics. |
| `layout.odin` | Size, alignment and offsets per target, checked against `odin check`. |
| `query.odin` | `expected_type_at`, `type_members`, `selector_symbol`, `symbol_range`, `expr_under`. |
| `type_cache.odin` | Types frozen across requests. A checker copies the state when every file and package it read is unchanged. An entry that reads the request buffer is never frozen. |
| `cfg.odin`, `flow.odin`, `liveness.odin` | Control-flow graph with `defer` unwinding; reachability, missing return, liveness. |
| `diagnose.odin`, `vet*.odin`, other lint files | The checks of section 5. |

A `Checker` owns its arena and borrows a `Snapshot`. Destroy it before `snapshot_end`.

**Stdlib cache.** Files and package directories under the Odin root are stated at most every 5 s
(`STABLE_INTERVAL`). Their item trees persist in `user/cache/odin/items-<hash>.bin`
(`tree_codec.odin`, `lang/odin/tree_cache.odin`). The key holds the root, the compiler's modtime and
size, the format and a schema hash. Any mismatch rebuilds silently. Parses stay lazy.

### 4.3 Features: kind to file

| Kind | File | Notes |
| --- | --- | --- |
| `Definition` | `definition.odin`, `target.odin` | Locals through `scope_map`; bare names reach the buffer, then the package directory in the build, never another directory. `pkg.name` through imports. Procedure groups narrowed by the call (`call_group_member`). Several candidates give a picker, inactive `when` ones last. |
| `Type_Definition` | `type_definition.odin` | Through pointers, containers and results to each declared type. |
| `Hover` | `hover.odin` | Signature, doc comment, layout (`// size 16, align 8`, `// offset 8, size 4`), constant values, type of the expression under the caret. |
| `Document_Symbols`, `Workspace_Symbols` | `symbols.odin` | From item trees. Nested procedures and types included. `Request.query` filters (`lang/match.odin`). |
| `References`, `Rename` | `references.odin` | Exact: confirmed by symbol, including fields, enum members, parameters and named arguments. Rename refuses builtins, keywords, import paths. |
| `Document_Highlight` | `references.odin` | Writes apart from reads. |
| `Signature_Help` | `signature.odin` | One entry per group member; the active one picked by `choose_member`. |
| `Completion` | `completion.odin`, `auto_import.odin` | Scope and member completion, expected-type ranking, struct-literal fields, snippets, postfix templates, auto-import. |
| `Semantic_Tokens` | `semantic.odin` | Kinds plus modifiers (`deprecated`, `distinct`) and inactive `when` ranges. Sparse by design. |
| `Inlay_Hints` | `inlay.odin` | Types of `:=` and `::`, parameter names at calls. |
| `Code_Actions`, `Resolve_Action` | `actions.odin`, `fixes.odin`, `compiler_fixes.odin`, `create_decl.odin`, `refactor.odin`, `extract.odin`, `change_signature.odin`, `move_decl.odin` | Quick fixes and refactorings. Compiler-message fixes include `&` for an immutable `for`/`switch` variable, removing an unneeded cast or `transmute`, and indenting a `-vet-tabs` line with tabs. Four refactorings ask for a name or path through `Code_Action.prompt`. |
| `Call_Hierarchy`, `Type_Hierarchy`, `Implementations` | `hierarchy.odin` | |
| `Selection_Range` | `selection.odin` | |
| `Code_Lens` | `lens.odin` | Reference counts. |
| `Package_Doc` | `package_doc.odin` | A Markdown page of a package. |
| `Diagnostics` | `check.odin` | Runs `odin check` on save. |
| `Syntax_Diagnostics` | `syntax_check.odin`, `name_check.odin`, `body_check.odin`, `vet_check.odin`, `package_live.odin` | The live report. |
| `Format*` | `formatter.odin`, `format/` | Section 6. |

Refactorings: inline variable, `if` chain to `switch` and back, extract variable, extract procedure,
change signature, move declaration (to another file or package).

`engine.odin` holds `IMPLEMENTED`, the set of kinds `supports` accepts.

### 4.4 Configuration

Layers: shipped `settings/*.lua`, then `user/*.lua`, then `<workspace>/.thor/`. `settings/` is
read-only for the running editor.

`.thor/odin-analyzer.lua` keys include: `collections` (`{name, path}`), `enable_*` per kind,
`enable_snippets`, `target`, `defines`, `diagnostics` (id to `off`/`hint`/`warning`/`error`), `vet`,
`inlay_types`, `inlay_parameters`, `package_diagnostics`, `diagnostics_telemetry`, `naming`. The file
is Thor's own, not `ols.json`. The engine caches it and re-reads it only when modtime or size moves.

Per-file build target: the `file_targets` setting (workspace-relative path or glob to `-target:`
value, matched like `file_languages`) is written to `<workspace>/.thor/settings.lua` for a workspace
file, else to the user layer; an empty value removes a lower layer's entry. The editor side is
`thor/file_target.odin`: the palette command "Odin: Select Build Target..." (`select_build_target`,
unbound), the View menu row, the status-bar segment `target` before `lang` (Odin files, engine on)
and the picker "Build Target of the File" with a "Workspace Default" row.

### 4.5 Performance (release build)

| Path | Measured | Budget |
| --- | --- | --- |
| Parse a 10k-line file | about 7 ms | 8 ms |
| Reparse after one keystroke | about 0.12 ms | 0.5 ms |
| Live diagnostics, warm | about 32 ms | 50 ms |
| First request, cold | about 110 ms (about 21 ms after prewarm) | — |

`odin run build.odin -file -- bench [-strict]` times parse, reparse, diagnostics and completion with
release flags. A measure over budget is a log warning, an error with `-strict`.

### 4.6 Tests

- `oracle_test.odin` (run with `-define:LIVE_ORACLE=true`): no live error on the 1,268 files of the
  310 `base`/`core`/`vendor` packages that `odin check` accepts; 1,335 seeded errors, all matched to
  the compiler's line, with no false error. Reports go to `bin/test/oracle_*.txt`.
- Expected-comment tests per feature, each in `*_test.odin` beside its file.
- A test driving a backend must use relative paths (an absolute literal fails on the POSIX runners).

---

## 5. Diagnostics: tiers, ids, suppression

Every live diagnostic has an id in `lang.Diagnostic.code`. The hover shows it after the message.
A diagnostic the compiler does not make has `lint = true`. The editor keeps lint items beside a
current `odin check` report. A current compiler report replaces non-lint items.

`lang.Diagnostic_Severity` is `Error`, `Warning`, `Hint`. A hint is a faint underline with no gutter
mark. LSP severities 3 and 4 map to `Hint`.

### Tier 1 — compiler parity (errors, live)

`syntax/error`, `name/undeclared`, `name/redeclared`, `name/private`, `import/unresolved`,
`import/cycle`, `type/mismatch`, `type/no-member`, `call/arity`, `call/named`, `call/overload`,
`poly/where`, `const/overflow`, `assert/static`, `flow/missing-return`, `switch/non-exhaustive`,
`or_return/mismatch`, `assign/count`, `flow/unreachable-defer`.

### Tier 2 — the compiler's `-vet` set (warnings)

`vet/unused-variable`, `vet/unused-import`, `vet/shadowing`, `vet/using-stmt`, `vet/when-shadowing`,
`vet/cast`. Opt-in: `vet/unused-procedure`, `vet/style`, `vet/semicolon`, `vet/tabs`. `#+vet` tags
add and `!name` removes checks per file. The save's `odin check` passes the matching `-vet-*` flag
and `-vet-packages:<package>`, and maps its lines to the same ids.

### Tier 3 — lints the compiler does not have (hints, each switchable)

`flow/unreachable`, `flow/dead-store`, `api/fmt-verbs`, `api/ignored-error`, `api/deprecated`,
`mem/dangling-slice`, `mem/temp-escape`, `defer/in-loop`, `perf/range-copy`, `nil/deref`,
`logic/self-assign`, `logic/const-condition`, `logic/identical-branches`, `style/naming`.

`api/deprecated` also covers proc-group members and bare deprecated types in type positions.
`logic/const-condition` reads constant expressions in `if`/`else if` (both polarities) and `for`
(always-false only), never `when`; it skips target-dependent conditions (`ODIN_*`, directives,
`size_of`) and conditions built only from names with no literal. `style/naming` checks an alias by
what it names (type, procedure or constant rule) and skips an alias named like the last part of its
target (`HWND :: win32.HWND`), an alias of a basic type, foreign blocks and aliases of
`base:intrinsics`/builtin.
Opt-in ownership dataflow: `mem/leak`, `mem/double-free`, `mem/use-after-free`.

Most lints were audited for false positives on the clean `base`/`core`/`vendor` corpus before they
shipped. Thresholds in the code (for example `RANGE_COPY_SIZE` 512 bytes) come from those audits.

### Suppression and severity

- `// thor:ignore <id>...` drops those ids on the next line (on its own line when it follows code).
  With no id, every id.
- `// thor:ignore-file <id>...` drops them in the whole file. An unknown id is a warning.
- `diagnostics = { ["<id>"] = "off" | "hint" | "warning" | "error" }` in `odin-analyzer.lua` sets an
  id's severity.

### Relationship with `odin check`

`odin check` runs on save and stays authoritative. The live checker shows errors while you type.
`diagnostics_telemetry` logs where the two disagree; that log is the checker's to-do list.
`package_diagnostics` also checks the other files of the package.

---

## 6. The formatter

`lang/odin/format` (package `odinfmt`) prints from the `odinsyntax` tree. `core:odin/parser` is used
only as a test oracle.

- `tree.odin` builds the line index and the comment groups in one walk. Comments and blank lines are
  in the tree, so `comments.odin` only decides placement.
- The printer builds a document (`doc.odin`) and lays it out against `character_width`.
  `visit_decl`, `visit_expr`, `visit_stmt`, `visit_field` and `visit_asm` print each node group.
- Options (`options.odin`): `character_width`, `spaces`, `newline_limit`, `tabs`, `tabs_width`,
  `convert_do`, `exp_multiline_composite_literals`, `brace_style`, `indent_cases`, `newline_style`,
  `inline_single_stmt_case`, `spaces_around_colons`, `sort_imports`, `space_single_line_blocks`, and
  the alignment options `align_struct_fields`, `align_struct_values`, `align_struct_declarations`,
  `align_constant_definitions`, `align_variable_declarations`, `align_comments`,
  `align_case_comments`, `align_field_defaults`. All alignment options default to on. Integer options
  outside their range reset to the default (`validate_options`).
- `lang/odin/formatter.odin` reads `<workspace>/.thor/odin-formatter.lua` through `luaconf`. The
  cache is stat-invalidated, like `Config_Cache`. The buffer's own indent applies unless the file
  names `tabs`, `spaces` or `tabs_width`. An absent `newline_style` leaves the line endings alone.

How a formatter answers the seam:

- It answers `Format`, `Format_Range` and `Format_On_Type`. The engine formats `[0, len)`, the
  selection, or the line of the caret. Format-on-type fires on `}` only.
- The printer emits `\n`. The result is **diffed** against `req.source` (`lang.diff_spans`) and
  returned as `Text_Edit`s, so cursors do not jump to the end of the file.
- A buffer with syntax errors answers `ok = false`. The host reads that as "fix syntax errors first".
  An already clean buffer answers `ok = true` with no edits.
- `Request.tab_size` and `Request.use_tabs` carry the buffer's indent. 0 means unset.

---

## 7. The LSP backend (`lang/lsp`)

The subprocess client for any language that has a server. One `Server` per entry of the merged
server table.

### 7.1 Package rules

`lang/lsp` may import only `core:*`, `base:runtime`, `lang`, `lockfree`, `luaconf`, `shell` and
`treecache`. It must **not** import `setting` (`setting` imports `lang`; that is a cycle), `msvc`,
`ui` or `thor`.

Files:

| File | What |
| --- | --- |
| `lsp.odin` | `Client` lifetime and the `lang.Backend`. `client_server_status` for the settings panel. |
| `server.odin` | One server: pump thread, spawn, handshake, restart, shutdown. |
| `transport.odin` | `Transport` vtable and the child-process transport. |
| `framing.odin` | `Content-Length` framing. Pure. |
| `jsonrpc.odin` | Message build and parse, id correlation, the reader thread (`Conn`). |
| `position.odin` | UTF-16/UTF-8 to byte offset. Pure. The riskiest file. |
| `capability.odin` | `initialize` result to the kinds a server answers. |
| `document.odin` | Per-document sync state. |
| `config.odin` | `settings/lsp.lua` and `.thor/lsp.lua`. |
| `executable.odin` | PATH lookup with PATHEXT. |
| `requests.odin` | Kind to LSP method and params. |
| `decode.odin` | LSP payload to `lang.Result`. |

### 7.2 Child process

A server does not run on `shell.Session`. `Session` merges stderr into stdout. A server logs to
stderr, so the text would land inside the `Content-Length` stream and break the parser for good. The
`shell/child_*.odin` pair (`child_windows.odin`, `child_posix.odin`; contract in `child.odin`) keeps
stdout and stderr on separate pipes. Windows puts the process in a Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. POSIX kills the process group. A program that cannot start is
reported on both platforms (POSIX carries the exec errno back on a close-on-exec pipe).

`lang/lsp` never touches `shell.Child` directly. All I/O goes through `Transport`. The tests use an
in-process transport (`mock_test.odin`), so handshake, correlation, cancel, deadline, EOF and pushed
diagnostics run on all four CI platforms with no server installed.

### 7.3 Threads and locks

- One **pump thread** per server does everything that can block on a pipe: spawn, handshake, outbox
  drain, restart. `notify` on the main thread only queues.
- One reader thread and one stderr drain thread per connection. The reader answers server-to-client
  requests itself (`workspace/configuration`, `workspace/workspaceFolders`,
  `client/registerCapability` with `null`, `workspace/applyEdit`).
- A worker in `resolve` holds `conn_lock` (shared) for the whole round trip, then `docs_mutex`.
  **Always in that order.** A restart takes `conn_lock` exclusively.
- `status_mutex` is a leaf lock over `root`, `restarts` and `last_error`. A status read must never
  take `conn_lock`.
- `push_mutex` guards the per-server push queue. It is never held with another lock.
- `state` is atomic. `caps` is written once, before the first `.Ready`. That is what lets `supports`
  read them without a lock.
- A request publishes its own buffer to the server before it names a position in it, because the
  pump drains document events on its own schedule.

### 7.4 Why `resolve` blocks

`resolve` waits for its reply. A fire-and-forget `resolve` leaves `ok == false`, which means "found
nothing", so the host would flash "No definition found" and then jump a second later. The push
channel (`poll`) is only for results nobody asked for.

The cost is a blocked pool worker. Mitigations:

- Deadlines: `DEADLINE_INTERACTIVE` 3 s (definition, hover, completion, signature),
  `DEADLINE_HEAVY` 15 s (whole-file and workspace kinds), `DEADLINE_START` 10 s, `DEADLINE_EXIT` 2 s.
  `POLL_SLICE` 25 ms wakes the wait to check for cancel.
- A request that misses its deadline gives `ok == false`; it does not stall the worker longer.
- Restart after a crash: up to `RESTART_LIMIT` (3) times with back-off of 1 s, 4 s and 16 s, then
  `.Failed` for the session. A program that cannot start fails at once, with no retry. "Restart This
  Server" in Settings clears the latch (`server_restart`).
- Thor never registers a server for `.odin` unless an entry sets `override = true`.

### 7.5 Handshake and capabilities

Thor advertises only what it can consume, so servers do not send shapes it drops:

- `positionEncodings`: `utf-8` first, then `utf-16`.
- Completion: `snippetSupport`, `preselectSupport`, `resolveSupport` (`detail`, `documentation`,
  `additionalTextEdits`, `command`). **Not** `insertReplaceSupport`, `labelDetailsSupport` or
  `itemDefaults`.
- `definition.linkSupport`, `publishDiagnostics.versionSupport`, `rename.prepareSupport`.
- Semantic tokens: `requests.full` only (no range). Thor asks for `full/delta` when the server
  advertises it.
- `workspaceEdit.resourceOperations`: create, rename, delete.
- `workDoneProgress`, `workspace.configuration`, `workspaceFolders`.

`textDocumentSync` is full text, or incremental when the server advertises it
(`treecache.source_edit` computes the covering span). A server is started by the first document
event for a key it claims, never at init. While a server is `.Starting`, `supports` answers true for
everything it is configured for, so the first requests are not swallowed.

### 7.6 Kind to method

| Kind | Method | Notes |
| --- | --- | --- |
| `Definition` | `textDocument/definition` | `Location`, `Location[]` or `LocationLink[]`. Several hits go to `res.symbols`. |
| `Type_Definition` | `textDocument/typeDefinition` | |
| `Hover` | `textDocument/hover` | `MarkupContent`, `MarkedString` or an array. |
| `Document_Symbols` | `textDocument/documentSymbol` | Tree or flat; flattened depth-first. |
| `Workspace_Symbols` | `workspace/symbol` | Sends `Request.query`. |
| `References` | `textDocument/references` | `includeDeclaration = false`. |
| `Signature_Help` | `textDocument/signatureHelp` | Parameter labels as substring or `[start, end]` over the label. |
| `Completion` | `textDocument/completion` | Sorted by `sortText`. `isIncomplete` reaches `Result.incomplete`. A trigger character sends `triggerKind 2`. |
| `Resolve_Completion` | `completionItem/resolve` | Sent when the user picks a candidate. Reads back `additionalTextEdits` and `command`. |
| `Package_Doc` | `textDocument/hover` | Keeps the reply as Markdown. |
| `Rename` | `textDocument/rename` (+ `prepareRename`) | The backend reconstructs `old_text` itself. Sorted ascending. |
| `Diagnostics` | push `publishDiagnostics`; pull `textDocument/diagnostic` | A push for an unopened file, or for superseded text, is dropped. |
| `Code_Actions` | `textDocument/codeAction` (+ `codeAction/resolve`) | Range is `[offset, end)`. The request replays cached diagnostics. A command-only action is kept and runs through `Execute_Command`. |
| `Execute_Command` | `workspace/executeCommand` | The server's changes return through `workspace/applyEdit`. |
| `Semantic_Tokens` | `.../full` or `.../full/delta` | Legend names map to `lang.Token_Kind`. `keyword`, `string`, `comment`, `number`, `operator` are dropped. `Unresolved` is never emitted. |
| `Inlay_Hints` | `textDocument/inlayHint` | |
| `Document_Highlight` | `textDocument/documentHighlight` | |
| `Implementations` | `textDocument/implementation` | |
| `Format` | `textDocument/formatting` | Re-diffed with `lang.diff_spans`; `insertSpaces` is always true. |
| `Format_Range` | `textDocument/rangeFormatting` | The host aligns the range to whole lines. |
| `Format_On_Type` | `textDocument/onTypeFormatting` | Only for the server's advertised trigger characters. |

In-client only (a server is never asked): `Syntax_Diagnostics`, `Resolve_Action`, `Call_Hierarchy`,
`Type_Hierarchy`, `Selection_Range`, `Code_Lens`. Pushes: `$/progress` becomes `Progress`
(statusline), `window/showMessage` becomes `Message`, `workspace/applyEdit` becomes `Apply_Edit`.
`window/logMessage` goes to the log.

### 7.7 Position encoding

All conversion happens inside `lang/lsp/position.odin`. No offset outside `lang/lsp` is anything but
a byte offset over LF-collapsed source.

- For a document Thor opened, it sends `req.source` (already LF-collapsed). The server's positions
  run over the same bytes, so a `Line_Index` of that text is enough. Sending the buffer text and
  never letting the server read the file is what makes this safe.
- For a file Thor never opened (a definition target, a reference, a rename edit), the server read it
  from disk with CRLF. Convert in three steps: read the file **raw**, resolve `(line, character)` to
  a raw byte offset, then subtract the `\r\n` pairs before it (`lf_offset`). A lone `\r` is not
  collapsed and is not counted.
- UTF-16: a rune costs 1 unit below `0x10000` and 2 at or above. A `character` inside a surrogate
  pair snaps to the rune start. Never return an offset that splits a UTF-8 sequence.
- `position_test.odin` is table-driven for both encodings: multi-byte and astral characters, clamping
  past a line end and past EOF, CRLF, lone `\r`, mixed endings, BOM.

A bug here is silent and destructive: an off-by-one in a `Text_Edit` corrupts a file the user never
opened. The `old_text` check in `thor_apply_edits` turns that into a refused edit.

### 7.8 Configuration

Files: `settings/lsp.lua` (shipped), overlaid by `user/lsp.lua`, overlaid by `<workspace>/.thor/lsp.lua`.
An entry with the same `id` replaces the shipped one field by field. A new `id` adds a server.
`enabled = false` switches one off.

```lua
return {
    servers = {
        {
            id = "rust-analyzer",
            name = "rust-analyzer (Rust)",
            command = { "rust-analyzer" },          -- [1] resolved on PATH; ${workspace}, ${userHome}, ${env:NAME}
            extensions = { ".rs" },                  -- leading dot added if missing
            filenames = { },                         -- whole names, kept verbatim, matched first
            root_markers = { "Cargo.toml", ".git" },
            install = { any = "rustup component add rust-analyzer" },   -- per platform
            docs_url = "https://rust-analyzer.github.io/manual.html",
            setup_command = nil,                     -- a plugin command the settings panel can run
            initialization_options = { },            -- also accepted as init_options
            settings = { },                          -- didChangeConfiguration and workspace/configuration
            features = { rename = false },           -- per-kind seed
            enabled = true,                          -- seeds admin_enabled
            override = false,                        -- true: register ahead of the Odin engine for these keys
            env = { }, cwd = "",
        },
    },
}
```

- `enabled` and `features` **seed** the server's `admin_enabled` and `admin_features` at
  `server_create`. After that the Settings panel (`language_backends`) owns them.
- A server whose program is not found stays in the table. It never starts, goes to `.Failed`, and the
  Settings panel lists it as "not found on PATH" with its `install` command (`lsp.executable_find`
  checks without a process spawn). An entry that names no command is dropped and reported as a
  `Config_Problem`.
- `config.odin` reports what a file got wrong as `Config_Problem`; unknown keys are a warning, not a
  drop.
- The workspace layer is repo-supplied and names programs. `client_create` takes `trust_workspace`
  and skips that layer when false. `thor/lsp_trust.odin` decides: the grant in
  `sessions/lsp-grants.json` keys on (workspace path, SHA-256 of the file). Any edit asks again.
- All three layers are watched (`thor/settings_watch.odin`). A change rebuilds the client at the head
  of the run loop. One server alone restarts through `server_restart`.
- One enabled entry answers for an extension. A second claim is shown as `Server_Status.claimed_by`.
- Windows: `which` does not read PATHEXT, so `lang/lsp/executable.odin` tries `name`, `name.exe`,
  `name.cmd`, `name.bat`, and runs a `.cmd` or `.bat` as `cmd.exe /c <path>`.

Coexistence with Odin: the Odin engine registers first and wins `.odin`. A user who overrides `.odin`
loses `Package_Doc` and the `odin-analyzer.lua` collections. That is the honest trade; it is also in
`docs/configuration.md`.

### 7.9 Tests

All hermetic, on all four platforms, with no installed server:

`framing_test` (byte-at-a-time feed, hostile lengths), `position_test`, `decode_test` (fixture
payloads for every kind, plus a malformed variant of each), `config_test`, `capability_test`,
`document_test`, `executable_test`, `jsonrpc_test`, `server_test`, `lsp_test`, `mock_test`
(full lifecycle on an in-process transport). `shell/child_test.odin` checks that stdout and stderr
arrive on separate pipes. The `lang` seam tests extend a `Probe` backend with `supports` and `poll`.

---

## 8. Adding a language

Two paths. Choose A unless you have a reason not to.

### Path A — a language server (no Odin code)

Add an entry to `settings/lsp.lua` (or `user/lsp.lua`, or `.thor/lsp.lua` for one project):

1. Set `id`, `command`, `extensions` (and `filenames` for names like `Makefile`).
2. Set `root_markers` so the server gets the right root.
3. Add `install` and `docs_url`, so the Settings panel can show how to get it.
4. Open a file. The server starts on the first document event.

Features, including formatting, follow the server's capabilities. Syntax colour is separate (below).
Limits of this path are in section 11: no `Package_Doc`, no hierarchies, no lens, no selection range.

### Path B — an in-client analyzer (Odin code)

Do this when no server exists, or when you need what a server cannot give (shared buffer, in-process
speed, the lints of section 5). Expect a large piece of work. The Odin analyzer is the reference.

**1. Layout and imports.** Make one package per layer, as `lang/odin` does:

```
lang/<lang>/syntax    lexer + resilient, lossless parser           imports core: only
lang/<lang>/sema      scopes, types, checks (optional at first)    imports syntax, core:
lang/<lang>/format    printer                                      imports syntax
lang/<lang>           Backend glue                                 imports lang, sema, syntax, format
```

Rules (checked by the `layering-reviewer` agent):
- Packages depend downward only. Nothing below `lang/<lang>` imports `lang`.
- `lang/<lang>` imports `lang` as `import lang ".."`, never `setting`, `thor` or `ui`.
- OS calls go in `<name>_windows.odin` / `<name>_posix.odin`. Handle Windows and POSIX paths.
- Add every package that has tests to the `packages` list in `run_tests` (`build.odin`) and to
  `VET_PACKAGES`. CI skips a package that is missing from the first list.

**2. Build the front end first.** Order of value:
1. A lexer that never fails and keeps trivia. The tree must be lossless, so a formatter and a
   refactoring can rebuild the file.
2. A parser that never fails. Put a missing token in the tree as absent, not as an error that stops
   the parse. Keep bracket balance sacred, so one bad expression cannot break block structure.
3. Test losslessness on a corpus, every prefix of a file, and random edits (see `corpus_test.odin`).
4. Incremental reparse later. A full parse is fast enough to start.

**3. Write the Backend.** Model it on `engine_backend`:

```odin
package mylang

import lang ".."

Engine :: struct {
    admin_enabled:  bool,                       // main thread only
    admin_features: bit_set[lang.Request_Kind], // main thread only
    // db, caches ... // owned
}

IMPLEMENTED :: bit_set[lang.Request_Kind]{.Format, .Document_Symbols, .Definition}

engine_backend :: proc(e: ^Engine) -> lang.Backend {
    return lang.Backend {
        data     = e,
        name     = "mylang (in-client)",
        handles  = handles,
        resolve  = resolve,
        destroy  = engine_destroy,
        supports = supports,
        notify   = notify,                      // optional
    }
}

handles :: proc(data: rawptr, ext: string) -> bool {
    return (ext == ".my") && (cast(^Engine)data).admin_enabled
}

supports :: proc(data: rawptr, ext: string, kind: lang.Request_Kind) -> bool {
    return (kind in IMPLEMENTED) && (kind in (cast(^Engine)data).admin_features)
}

resolve :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {
    e := cast(^Engine)data
    if lang.request_cancelled(req) { return }
    #partial switch req.kind {
    case .Format:           format_document(e, req, res)
    case .Document_Symbols: document_symbols(e, req, res)
    }
    // Leave res.ok false for a kind you do not answer.
}
```

Rules for `resolve`:
- It runs on a worker. Never touch UI state. Never allocate from the main allocator without care.
- Poll `lang.request_cancelled(req)` at the head of every expensive loop.
- Offsets are bytes over CRLF-collapsed text. Read other files with `lang.source_read`.
- Strings that leave `resolve` in `res` are cloned into the Manager allocator. `req` and its strings
  are owned by the job.
- `ok = false` means "found nothing". Set `ok = true` only when you have an answer, even an empty one
  where that is a valid answer (an already formatted buffer).
- Return `Text_Edit`s for any change. Never write a file.
- Declare only the kinds you answer in `IMPLEMENTED`. The editor shows or hides each feature from
  `supports`.

**4. Wire it into the host.** Registration is not generic. There are three places to touch:

| Where | What |
| --- | --- |
| `thor/thor.odin` (init, near `manager_register`) | Create the engine and register its backend. Registration order is precedence. |
| `thor/lang_host.odin` (`thor_reload_lang`) | Add the backend to the `manager_set_backends` call, in the same order. |
| `thor/lang_host.odin` (`thor_apply_language_settings`) and `thor/settings_ui.odin` (`ODIN_BACKEND_ID`) | The "odin" id is hard-coded here. Push the settings gate to your engine (`engine_set_enabled`, `engine_set_features`) and add its row and feature group to the Settings panel. |

Shutdown needs nothing: `manager_destroy` calls each `Backend.destroy`.

`manager_set_backends` is variadic, so a third backend needs no change in `lang/`. A generic
registry would remove the three edits; it does not exist yet (section 10).

**5. Features, in a useful order.**
1. `Syntax_Diagnostics` (parse errors) and `Format`. Both need only the front end.
2. `Document_Symbols`, `Workspace_Symbols`, `Definition`, `References`, `Rename`. These need scopes.
3. `Hover`, `Completion`, `Signature_Help`, `Semantic_Tokens`, `Inlay_Hints`. These need types.
4. Compiler-parity errors and lints. Prove them against the language's real compiler (see below).
5. `Code_Actions` and refactorings.

**6. Diagnostics.** Give every diagnostic a stable `code` (`area/name`). Add suppression and severity
from a `.thor/<lang>-analyzer.lua` through `luaconf`. Mark a check the compiler does not make as
`lint = true`. If the language has a compiler or linter, run it on save as the `Diagnostics` kind and
keep it authoritative; see `lang/odin/check.odin`. Add an **oracle test**: run the real compiler on a
large clean corpus (no live error allowed) and on seeded errors (each the compiler reports must match
on its line). This is the test that stops false positives.

**7. A formatter.** The formatter is one more kind, not a separate system.

1. Print from the lossless tree, not from an AST that lost comments.
2. Build an options struct with defaults. Validate integer ranges. Read it from
   `.thor/<lang>-formatter.lua` through `luaconf`, stat-cached like `Format_Config_Cache` in
   `formatter.odin`.
3. Answer `Format`. Answer `Format_Range` by formatting whole lines in the range. Answer
   `Format_On_Type` for the one or two characters that close a construct, and return true from
   `on_type_trigger` only for those.
4. Print into a string, then compute the minimal edits with `lang.diff_spans(old, new)` and return
   them. A whole-file replacement drags every cursor to the end.
5. When the buffer has syntax errors, answer `ok = false`. Do not guess.
6. Honour `Request.tab_size` and `Request.use_tabs` when the options file does not name an indent.
7. Test idempotence (`format(format(x)) == format(x)`), a corpus that must keep compiling, and an
   oracle against the language's reference formatter where one exists. Run the corpus under several
   option sets.

**8. Highlighting is separate.** Colour comes from a plugin (`plugins/<id>/plugin.lua`) with a
tree-sitter grammar or a pure-Lua `highlight` function. Use the `grammar-add` skill for a grammar.
The analyzer adds semantic tokens on top (`thor_merge_semantic`). Tokens must be ascending and
non-overlapping.

**9. Finish.** Add tests, add the packages to `run_tests` and `VET_PACKAGES`, run the `verify` skill,
update this file (sections 4, 8, 10, 11), add a `CHANGELOG.md` entry, and update `docs/`.

---

## 9. Design decisions

These are the answers that shaped the rebuild. They stay here so nobody reopens them by accident.

- **Own parser, not tree-sitter and not `core:odin/parser`.** The tree-sitter grammar is not the
  language, and a highlighting tree is not a semantic tree (every feature re-derived meaning from node
  names). Its recovery is generic (a dangling `.` derailed the parse). Two parsers disagreed (the
  formatter used `core:odin/parser`). The stdlib parser is not lossless or incremental, and its
  recovery drops the rest of a block. The own parser costs about 4 to 6k lines and gives one tree for
  analysis, formatting and refactoring. `core:odin/parser` stays as a test oracle.
- **Real types, not strings.** The old engine kept types as text and re-parsed it, with depth caps
  instead of memoization. The new engine has an interned type table. That is what makes live
  diagnostics possible.
- **Demand-driven, memoized queries with early cutoff.** The item tree (no bodies) is the firewall:
  a body edit leaves scopes and other files valid, and only that body is checked again.
- **`odin check` stays authoritative on save.** The live checker is for speed while typing and for
  the lints the compiler lacks. Disagreements are logged, not hidden.
- **Do not change the seam.** The `lang` interface survived the rewrite. The black-box tests drive
  `Request` to `Result`, so they run unchanged against any engine.
- **No two engines in a release.** The rebuild lives on its own branch. No `engine` switch ships. The
  merge of this branch is the switch.
- **Disk cache in the per-user cache dir** (`user/cache/`), never inside the workspace.
- **Tier 3 lints are hints by default,** with a per-id override. The ownership dataflow is opt-in.
- **Inactive `when` code** is greyed out and navigable. It produces no errors.
- **Target** is the host by default and overridable per workspace.
- **Blocking `resolve` in the LSP client** (section 7.4), with deadlines, rather than a fire-and-forget
  design that would flash "No definition found".
- **Full-text sync first, incremental per server later.** Full text is always correct and keeps the
  LF-collapsed invariant.
- **A server's workspace config is repo-supplied code.** It needs a grant keyed on the file hash.
- **Do not import `setting` from `lang/lsp`** (cycle). The package parses its own config.
- **Formatter alignment** of struct fields, constants, variables, comments and defaults is on by
  default and switchable.

---

## 10. Missing

Things that do not exist yet. Each is a candidate for future work.

### Analyzer (Odin)

- **Multi-target diagnostics.** One target per file at a time (the host, `target` in
  `odin-analyzer.lua`, or `file_targets`). Showing errors for several targets at once is not built.
  Files of one package with different targets make the `Package_Memo` (one configuration per package
  slot) and the `TYPE_STATE_SLOTS` (4) type caches churn. The result is correct but slower.
- **Workspace disk cache.** Only the stdlib item trees persist. Item trees of workspace files keyed
  by content hash are not cached.
- **Custom lints from Lua plugins.** The sema API is not exposed to plugins.
- **Other compiler messages as quick fixes.** `compiler_fixes.odin` handles a few; more remain. The
  indented `Suggestion:` lines of the compiler output are not read.

### Seam and host

- **A generic backend registry.** Adding an in-client backend needs four edits (section 8). Settings
  and the shutdown path know the id `"odin"`.
- **Multiple servers per language.** One enabled entry answers for an extension.
- **Several backends per key.** Precedence is all-or-nothing, so a declining backend does not fall
  through to the next.

### LSP

- **Dynamic registration.** `client/registerCapability` is answered `null` and ignored.
- **Kinds the LSP backend does not send:** `Call_Hierarchy`, `Type_Hierarchy`, `Selection_Range`,
  `Code_Lens`. They work only in-client; `METHODS` maps them to `""`.
- **LSP methods with no Thor kind:** `declaration`, `foldingRange` (folds come from tree-sitter for
  every grammar), `documentLink`, `linkedEditingRange`.
- **`Package_Doc`** rides `textDocument/hover`. There is no richer LSP equivalent.
- **`semanticTokens/range`.** Only full and delta.
- **Pull `relatedDocuments`** in diagnostic reports are dropped.
- **`labelDetails` and `completionList.itemDefaults`** are not advertised.

### Language coverage

- **Odin only has an in-client analyzer.** Every other language depends on its server.

---

## 11. Known issues

Behaviour that is wrong, partial, or surprising today.

### Analyzer

- **`vet/cast` oracle miss.** `test_oracle_clean_corpus` misses one `-vet-cast` line that a `#+vet`
  tag asks for (88 live vet items matched the compiler, none false, one missed).
- **Float constants.** Not reported: an integral hex float at or above 1e18 (the compiler prints
  garbage for it), a float constant from a selector (`pkg.F`), with an explicit type or from a
  multi-value declaration. Unknown struct tags are accepted, as the compiler does.
- **`vet-style`, `vet-semicolon`, `vet-tabs`** are live-only; the on-save `odin check` does not
  report them. `-vet-unused-procedures` does reach the save.
- **`nil/deref`** follows the elements of a fixed array only at a constant index; a variable-index
  store resets them all.
- **Polymorphic bodies.** An import used only in a body that the package does not instantiate is
  reported by name match. It can miss a report but cannot give a false one. The compiler does not
  check such bodies, so real errors in them are listed apart in the oracle (9 in the Odin sources).
- **Block-local type cache.** An entry that reads the request buffer is never frozen, so a request
  in a big file that declares the central type (`thor/thor.odin`) types it again (about 3.8 ms).
- **Cold start.** The first request takes about 110 ms. Warm live diagnostics take about 32 ms.
  Warm references on a widely used field take about 0.7 s in a debug build; most of it is the
  importer walk.
- **References without a checker.** With no memory left for a checker, a member falls back to a name
  match unless the operand names another type.
- **Statement-level `using`** works only in a file with `#+feature using-stmt`. The semantic
  `Unresolved` mark skips declarations with a `using`.
- **Workspace symbols are syntactic.** They do not run the checker.
- **Path spelling.** Symlinks and Windows 8.3 short names are resolved by `path_real` as a third
  tier. A mismatch that all three tiers miss widens a lookup instead of failing it.
- **Syntax.** `do` procedure bodies and `#+` tags after `package` are reported as errors.
  `core:odin/parser` is laxer than the compiler (commas between lines, `do` bodies, `#no_copy`), so
  `odin check -file` is the oracle for syntax.

### LSP

- **`workspace/symbol` and an empty query.** Servers such as clangd, gopls and pyright answer nothing
  for an empty query. The picker opens straight into a "type to search" hint for these. This is a
  protocol property, not a dispatch bug.
- **Completion limits.** An `InsertReplaceEdit` takes its `replace` range. `labelDetails` and shared
  `itemDefaults` are dropped.
- **Code actions.** A command-only action runs through `workspace/executeCommand`. The server must
  send its changes back as `applyEdit`. An action with neither edit nor command is dropped.
- **Resource operations** are applied in a fixed phase order (create, edits, rename, delete), not in
  the array order of `documentChanges`. An unknown `kind` refuses the whole set.
- **`Diagnostic_Severity`** has three levels. LSP `Information` and `Hint` both become `Hint`.
- **Slow or hung server.** Each blocked `resolve` holds one of 2 to 4 pool workers until its
  deadline (3 s interactive, 15 s heavy). A wedged server can slow other requests for that long.
  There is no per-server latch that stops sending after repeated deadline misses.
- **Executable lookup on Windows** depends on PATHEXT emulation. A `.cmd` shim runs through
  `cmd.exe /c`.

