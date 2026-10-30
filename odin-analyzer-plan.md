# Thor in-client Odin analyzer — next-generation plan

**Scope:** replace tree-sitter as the parser behind `lang/odin`, and grow the engine from a
"resolve what the caret names" navigator into a real static analyzer with its own type model,
live diagnostics and lints.
**Baseline:** `Nov0cx/Thor` at `29192c6` (release 2026.10.7).
**Status:** M1 (lexer, parser, compact tree, typed views) and M2 (incremental reparse, formatter
on the new tree) landed, plus live syntax errors. M3 is done: `lang/odin/sema` has item trees with doc comments (`//` and `/* */`), build file
selection, package scopes, lexical name resolution with `using` expansion, the universe scope, the
query DB and the stdlib cache (§5.10: Odin root files refreshed at most every 5 s, item trees kept
in `user/cache/odin/`), and serves document/workspace symbols, definition, references, rename and
package docs. M4 is done: the type table, `decl_type`, constant evaluation,
`expr_type` with calls, groups and generics, overload resolution by the compiler's distance scoring
with `where` clauses and their intrinsics, the layout engine (size, align, offsets per target), a type cache across
requests (`type_cache.odin`), and hover (with layout), completion (snippets, auto-import, `x.(`,
`x->`), signature help and semantic tokens. M5 started: the live report holds the Tier 1 name
errors (redeclaration, undeclared, private, unresolved import) and the first body errors (argument
count and names, missing members, non-exhaustive switches, `#assert`, type mismatches in arguments,
assignments, declarations and returns, group calls no member takes, constant overflow, missing
returns, `or_return`, false `where` clauses, assignment counts and import cycles), with per-id
severities in `.thor/odin-analyzer.json`; the M5 corpus bar (seeded-error suite against the
compiler) is next.
`lang/ROADMAP.md` ("Next engine") tracks the rest. Section 11 lists the
feature questions whose answers change the plan.

---

## 0. TL;DR

1. **Write a dedicated Odin front end** (`lang/odin/syntax`): a hand-written lexer and an
   error-resilient recursive-descent parser that produces a **lossless, immutable syntax tree**
   (every byte of the source, trivia included, lives in the tree). Incremental by re-lexing the
   edited span and re-parsing the smallest enclosing balanced block.
2. **Build a semantic layer** (`lang/odin/sema`) on a **demand-driven, memoized query graph**:
   item tree → package scopes → name resolution → interned types → per-procedure body checking →
   control-flow/dataflow → diagnostics. Types become real values (`Type_Id` into an interned
   table), not text that gets re-parsed (`Type_Ref.name`, `proc_sig`).
3. **Port every request kind** onto the new core one at a time, behind an engine switch, using the
   277 existing black-box tests (they drive `lang.Request` → `lang.Result`, so they survive the
   rewrite unchanged) plus differential tests between the old and new engine.
4. **Keep `odin check` as ground truth** on save; the native checker supplies *live* diagnostics
   while typing and the lints the compiler doesn't have.
5. tree-sitter stays only where it earns its place: highlighting other languages (and, until the
   new engine's semantic tokens can carry it, Odin highlighting).

---

## 1. Where the analyzer stands today

What I found reading the code — this is the baseline the plan is measured against.

### 1.1 Shape

| Area | Today |
| --- | --- |
| Size | `lang/odin`: ~14.8k lines across 27 non-test files, plus `format/` (~3.3k) and 277 tests. |
| Parsing | tree-sitter-odin (vendored grammar, pinned in `build.odin`), incremental through `treecache` (8 LRU slots, edit recovered by diffing the snapshot). ~950 `ts.` call sites across `lang/odin`. |
| Second parser | The formatter (`lang/odin/format`) already uses `core:odin/parser` + `core:odin/ast`. **The package parses the same file with two different parsers.** |
| Scopes | The grammar's `LOCALS` query, plus hand patches for what it misses (`collect_value_decls`: `:=` is modelled as a node the grammar never emits; typed `var` locals and `for … in` vars aren't captured). |
| Types | `Type_Ref` is text: `name`, `pkg`, `proc_sig` (signature *string*), `type_args` (text inside the parens), a fixed container stack. Results are read by re-parsing signature text after `->` (`proc_result_type`, `signature_result_type`). |
| Inference | Ad hoc, per feature, with depth caps (`INFER_DEPTH_LIMIT = 8`, `EMBED_DEPTH_LIMIT`, `CONTAINER_DEPTH_LIMIT`) and per-request budgets in `semantic.odin` (selector-resolution caps) to keep worst cases bounded. |
| Cross-file | `Symbol_Index`: per-file top-level decls (name, kind, *signature string*, offset), an identifier set for reference filtering, stat-gated reparse. Workspace files parse whole with no tree cache. |
| Diagnostics | Only `odin check` on save (`check.odin`) — "correct errors with no type checker to reimplement". Nothing while typing. |
| Seam | `lang.Backend` vtable, byte offsets over CRLF-collapsed source as position currency, bounded worker pool, cancellation via `request_cancelled`, debounced per-kind slots. Solid — **the plan keeps it untouched.** |

### 1.2 Why tree-sitter is the bottleneck

- **The grammar is not the language.** `CLAUDE.md` names grammar shapes as "the usual source of
  bugs" and the repo carries a `ts-probe` workflow just to learn node layouts (`or_else` is a
  `binary_expression`; `#soa` lands inside `array_type` for `#soa[]T` but beside it for
  `#soa[4]T`; the LOCALS query models `:=` wrong).
- **A highlighting CST is not a semantic AST.** Every feature re-derives meaning from node types
  and field names; that's why the same knowledge is spread over `infer.odin`, `typeref.odin`,
  `decl.odin`, `generics.odin`, `container.odin`, `using.odin`.
- **Error recovery is generic.** A dangling `.` "derails the parse", so completion re-parses with a
  filler identifier; "a *second* dangling dot earlier in the same block still swallows the line".
  A purpose-built parser knows `a.` is a selector with a missing name.
- **Two parsers disagree.** Analysis sees tree-sitter's view, formatting sees `core:odin/parser`'s.
- **Native dependency.** The grammar is C, built per machine, pinned per commit, and lags the
  language.

### 1.3 Why the inference keeps hitting walls

Types as strings means every step re-parses text, can't be compared by identity, can't represent
untyped constants, and needs depth caps instead of memoization. The roadmap explicitly parks
constraint validation, conversion rules and a real checker as "duplicating the compiler". That was
the right call without a type model — it stops being true once one exists, because live
diagnostics and lints *need* one.

---

## 2. Goals and non-goals

**Goals**

- G1 One parser for everything in `lang/odin` (analysis, formatter, semantic tokens, actions).
- G2 Parser never fails: any byte sequence yields a tree; edits re-parse in < 1 ms typical.
- G3 A semantic model that types every expression the compiler would, with memoized, incremental
  re-analysis.
- G4 Live diagnostics while typing, at "compiler-parity" for the common error classes.
- G5 Lints beyond the compiler (memory, flow, API misuse), each switchable.
- G6 No regression: every existing test passes on the new engine before the old one is deleted.
- G7 No change to the `lang` seam or host (`thor/lang_host.odin`).

**Non-goals (for this plan)**

- Code generation or a full compile; the compiler stays authoritative.
- Replacing tree-sitter for non-Odin languages.
- Being an external LSP server (though section 11 asks whether the core should be reusable as one).

---

## 3. Target architecture

```
             lang.Request (source snapshot, path, offset)              ── unchanged seam
                              │
┌─────────────────────────────┴──────────────────────────────────────────────┐
│ lang/odin  (engine.odin — Backend vtable; ide/* — one handler per kind)    │
└─────────────────────────────┬──────────────────────────────────────────────┘
                              │ queries
┌─────────────────────────────┴──────────────────────────────────────────────┐
│ lang/odin/sema   — the analysis database                                   │
│                                                                            │
│  file_text ─► parse ─► item_tree ─► package_scope ─► resolve_name          │
│                  │        (firewall)       │              │                │
│                  │                          ▼              ▼                │
│                  │                     decl_type ─► type_of_expr ◄─ body   │
│                  │                          │              │      check    │
│                  ▼                          ▼              ▼                │
│              line_index              const_eval      cfg ─► dataflow       │
│                                                            │                │
│                                         diagnostics ◄──────┴── lints        │
└─────────────────────────────┬──────────────────────────────────────────────┘
                              │
┌─────────────────────────────┴──────────────────────────────────────────────┐
│ lang/odin/syntax — lexer, resilient parser, lossless green tree, AST views │
└────────────────────────────────────────────────────────────────────────────┘
```

New packages (each a leaf over the one below; none imports `lang`, so all are unit-testable
without the seam):

| Package | Owns | Imports |
| --- | --- | --- |
| `lang/odin/syntax` | `Token_Kind`, `Syntax_Kind`, lexer, parser, green/red tree, typed AST views, incremental reparse, line index | `core:*` only |
| `lang/odin/sema` | query DB, packages/build config, scopes, symbols, types, const eval, checker, CFG, lints | `syntax`, `core:*` |
| `lang/odin` (existing) | Backend glue + IDE features translating sema answers into `lang.Result` | `lang`, `sema`, `syntax`, `format` |
| `lang/odin/format` | printer, ported from `core:odin/ast` to `syntax` | `syntax` |

Each new package with tests goes on the `packages` list in `run_tests` (`build.odin`).

---

## 4. Part A — the parser (`lang/odin/syntax`)

### 4.1 Options considered

| Option | For | Against | Verdict |
| --- | --- | --- | --- |
| **A. `core:odin/parser` as-is** (what the formatter uses, what OLS uses) | Zero parser work; tracks the stdlib | Pinned to the toolchain Thor was *built* with, not the user's; recovery produces `Bad_Expr`/`Bad_Stmt` and often loses the rest of a block; not incremental; not lossless (comments separate, no whitespace); allocation-heavy AST | Good as a **reference oracle in tests**, not as the engine's parser |
| **B. Fork `core:odin/parser` into the repo** | Fast start, familiar AST | Inherits A's recovery and allocation model; diverges from upstream anyway; retrofitting losslessness is most of a rewrite | Viable fallback if M1 slips |
| **C. Own lexer + resilient parser + lossless tree** (rust-analyzer / Roslyn model) | Recovery tuned to editing; incremental; one tree for analysis *and* formatting *and* refactors; full control of memory | Most upfront work (estimate: 4–6k lines incl. tests) | **Recommended** |

### 4.2 Lexer

- Byte-oriented, UTF-8 aware for identifiers, operates on the CRLF-collapsed source the seam
  already guarantees, so token offsets *are* `lang` offsets.
- Emits **trivia as tokens** (whitespace, newline, line comment, block comment — nested — and doc
  comments distinguished), so the tree is lossless.
- Handles Odin's automatic semicolon insertion the way the compiler does (a newline after an
  identifier, literal, `)`, `]`, `}`, `^`, `return`, `break`, `continue`, `fallthrough`, `---`,
  etc. is an implicit `;`) — modelled as a zero-width `Implicit_Semi` token flag rather than
  synthesized text, so losslessness holds.
- Never fails: unknown bytes become `Error_Token`; an unterminated string/rune/comment runs to the
  end of the line (or file for block comments) and carries an error flag.
- Restartable at any token boundary (needed for incremental relex: lexer state is just "inside
  nested block comment depth N" or nothing).

### 4.3 Tree representation

Two layers, as in rust-analyzer's rowan:

- **Green tree** (immutable, position-independent): `Green_Node{kind, text_len, children}` and
  `Green_Token{kind, text}`. Allocated in a per-parse `virtual.Arena` (the repo already uses
  `core:mem/virtual`). Identical subtrees can be shared between revisions, which is what makes
  incremental reparse cheap and lets old snapshots stay readable while a new one is built.
- **Red/cursor layer** (computed on demand): `Syntax_Node{green, offset, parent}` giving absolute
  byte offsets — exactly what every `lang.Request` handler needs.
- **Typed AST views** generated from a small schema file (`syntax.schema`): `Proc_Lit`,
  `Struct_Type`, `Selector_Expr`, … each a `distinct Syntax_Node` with accessors
  (`proc_type_params(&v)`, `selector_expr_field(&v) -> (Ident, bool)`). Accessors return "missing"
  rather than crash, which is how the analyzer copes with broken code. A code generator
  (`build.odin -- gen_syntax`) keeps the kinds and views in sync, and the corpus test checks every
  view against the parser — the replacement for `ts-probe`.

Memory target: ≤ 24 bytes/token, ≤ 32 bytes/node in the green tree; a 10k-line file under ~3 MB.
Landed: a token is inline in an 8-byte child slot with no text of its own (the tree keeps one copy of
the source), a node an 8-byte header — about 5.6 bytes per source byte, the source included.

### 4.4 Error recovery

The behaviour editing needs, made explicit:

- **Recovery sets per construct.** Statement parsing synchronises on `;`/newline-semi, `}` and
  statement-starting keywords; declaration parsing on `::` at column-start, `proc`, `struct`,
  `@(`, `#+`, `import`, `package`. A `}` is never consumed by an inner recovery unless it balances.
- **Missing tokens are nodes**, not failures: `a.` parses as `Selector_Expr{operand=a,
  field=<missing>}`; `foo(` at EOF as a call with an unclosed arg list; `x :=` as a value decl with
  a missing initializer. This retires the filler-identifier re-parse in completion and implicit
  selectors.
- **Errors wrap, they don't eat.** Unexpected tokens go into an `Error` node at the *smallest*
  level that can absorb them, so siblings after the error still parse. The "second dangling dot
  swallows the next line" case becomes a test.
- **Brace balance is sacred.** The parser tracks the bracket stack separately so one bad
  expression never desynchronises block structure — that is also what makes block-level
  incremental reparse sound.
- Every parse error is a diagnostic with a precise range and an id (`E-syntax-…`), so syntax errors
  appear live with no compiler run.

### 4.5 Incremental reparse

Keep the seam contract (full snapshot per request) and `treecache.source_edit` (the prefix/suffix
diff), then:

1. Relex only the damaged token range (expand to the enclosing token, plus a lookahead of one
   token for semi-insertion effects).
2. If the edit is inside one token whose kind doesn't change (typing within an identifier, string or
   comment), patch the green token in place — the common keystroke.
3. Otherwise find the smallest enclosing `{…}` block (or parenthesised list) whose bracket balance
   is unchanged by the edit, reparse just that node, splice it into a new green root, sharing every
   untouched sibling.
4. Fall back to a full parse when the balance changed at top level. Full parse budget is small
   anyway (see 4.8).

A per-buffer `Parse_Cache` (path → last source + green root) replaces the `treecache` entries the
engine uses today; `treecache` stays for `syntax/` highlighting.

### 4.6 Language coverage checklist

The parser is "done" when all of these parse to correct shapes (each gets a snapshot test):

- File headers: `package`, `#+build`, `#+private` / `#+private file`, `#+feature`, `#+vet`,
  `#+no-instrumentation`, `#+test`-style tags, `#+build ignore`.
- Imports: aliased, collection-qualified, `foreign import` (with lists and `{}` blocks),
  `foreign` blocks with attributes.
- Declarations: `::` constants/types/procs, `:` / `:=` values, multi-name, `---` uninitialised,
  `@(attr)` / `@attr` lists before any decl, `when` at file scope.
- Procedures: calling conventions (`proc "c"` …), `#force_inline`/`#force_no_inline`,
  `#optional_ok`, `#optional_allocator_error`, named results, default values, `..` variadics,
  `#c_vararg`, `#any_int`, `#by_ptr`, `#no_alias`, polymorphic `$T`, `$T: typeid/Constraint`,
  `where` clauses, `proc{…}` groups, `#type` proc types, `-> !` diverging.
- Types: pointers, multi-pointers `[^]T`, slices, fixed/enumerated arrays `[Enum]T`, `[?]T`,
  dynamic, maps, `bit_set[E; U]`, `bit_field U {…}`, `matrix[R, C]T`, `#simd[N]T`, `#soa`
  (both spellings), `#sparse`, `struct` with `#packed` / `#raw_union` / `#align(N)` /
  `#no_copy` and polymorphic params, `union` with `#no_nil` / `#shared_nil` / `#align`,
  `enum` with backing type, `distinct`, `typeid`, `any`, `#relative` if still accepted by the
  target toolchain.
- Statements: `if`/`else` with init clauses, `when`, `for` (C-style, range, `..<`/`..=`,
  `#reverse`, `#unroll`), `switch` (value, type `switch v in u`, `#partial`, `fallthrough`),
  labels with `break label`/`continue label`, `defer` (statement and block), `using`
  statement, `return`, `or_return`, `or_break`, `or_continue`, `or_else`, `#no_bounds_check` /
  `#bounds_check` blocks, `context = …`, inline `asm` (the formatter's `visit_asm` needs it).
- Expressions: all binary/unary ops incl. `&~`, `%%`, `in`/`not_in`, ternaries (`?:`, `if/else`
  form, `when` form), `cast`/`transmute`/`auto_cast`, type assertions `x.(T)`, `x.?`, implicit
  selector `.Member`, compound literals with field names and `[index] =` designators, slicing,
  matrix indexing `m[i, j]`, `->` selector-call, directives (`#load`, `#load_or`,
  `#load_directory`, `#directory`, `#file`, `#line`, `#procedure`, `#location`,
  `#caller_location`, `#exists`, `#defined`, `#config`, `#assert`, `#panic`, `#hash`).

### 4.7 Parser testing

- **Losslessness**: for every file in the corpus, the concatenated token text equals the source.
- **Corpus**: `$ODIN_ROOT/{base,core,vendor}` + Thor itself (~120k lines of Odin) + a few large
  public Odin projects pinned by commit. Zero parse errors required on all files the compiler
  accepts.
- **Differential vs `core:odin/parser`**: compare top-level declaration names, kinds and spans, and
  expression shapes for a sampled subset — the oracle catches misparses, our tree catches its
  recovery holes.
- **Fuzzing**: random deletions/insertions/duplications of tokens on corpus files; must terminate,
  never crash, stay linear time, and keep losslessness. Plus "every prefix of a file" parses (that
  is exactly the typing-from-scratch path).
- **Incremental = cold**: port `test_incremental_tree_matches_cold_parse` — after every edit in a
  scripted session the incremental tree is structurally identical to a cold parse.
- **Snapshot tests** in `syntax/testdata/*.odin` with an expected `debug_dump`.

### 4.8 Performance budget (release build, a mid-range laptop)

| Operation | Budget |
| --- | --- |
| Lex + parse a 10k-line file cold | ≤ 8 ms |
| Incremental reparse after one keystroke | ≤ 0.5 ms p95 |
| Parse all of `core:` cold (single thread) | ≤ 1.5 s; ≤ 400 ms on the worker pool |
| Bytes of tree per source byte | ≤ 8× (the §4.3 target; ≤ 4× needs 4-byte child slots and one arena per buffer) |

A `bench` subcommand in `build.odin` tracks these so CI can flag regressions.

---

## 5. Part B — the static analyzer (`lang/odin/sema`)

### 5.1 The query database

A small, explicit memoization layer — not a generic framework, just consistent rules:

- **Inputs:** `file_text(File_Id)`, `build_config()`, `workspace_config()`, `toolchain()`.
  Setting an input bumps a global `revision`.
- **Derived queries** are pure functions of other queries, memoized per key with the revision they
  were computed at and the inputs/queries they read (dependency edges recorded automatically by a
  `Query_Frame` on the calling thread).
- **Validation, not invalidation**: on the next read, a memo is re-checked by walking its
  dependencies ("red-green"); if every dependency is unchanged, it's reused without recomputing.
- **Early cutoff:** if a recomputed query yields an equal value (by hash), its dependents stay green.
  This is what makes the **item tree** a firewall: editing inside a procedure body changes `parse`
  but not `item_tree` (it ignores bodies), so package scopes, every other file's analysis and the
  workspace index stay valid; only that one procedure's body check re-runs.
- **Snapshots:** a request takes a read snapshot (`revision` + DB pointer under a read lock);
  writes (new file text) wait for in-flight readers *or* — better — the writer bumps a cancellation
  generation that long queries poll alongside `lang.request_cancelled`, so a keystroke cancels
  stale analysis instead of waiting on it.
- **Memory control:** LRU eviction of body-level memos (types of expressions, CFGs) for files not
  open in the editor; item trees and scopes for the whole workspace stay resident.

Key queries, coarse to fine:

| Query | Key | Value |
| --- | --- | --- |
| `parse` | File_Id | green root + syntax errors |
| `item_tree` | File_Id | top-level decls: name, kind, visibility, attrs, `when` guard, *syntax ptr* to signature/type (no bodies) |
| `file_in_build` | File_Id | does this file belong to the configured target (suffixes, `#+build`) |
| `package_files` | Package_Id | ordered files in the build |
| `package_scope` | Package_Id | name → Symbol_Id(s), with conflicts recorded |
| `file_imports` | File_Id | alias → Package_Id (file-private, as Odin has it) |
| `resolve_path` | (scope, name) | Symbol_Id or error |
| `const_value` | Symbol_Id / expr | evaluated constant (untyped int/float/rune/string/bool, typeid, …) |
| `decl_type` | Symbol_Id | Type_Id (struct/enum/proc signature …) |
| `body_check` | Proc_Id | expression types, resolved refs, local scopes, diagnostics |
| `cfg` | Proc_Id | basic blocks + edges incl. `defer` unwinding |
| `lints` | Proc_Id / File_Id | lint diagnostics |
| `file_diagnostics` | File_Id | union of the above for the file |

### 5.2 Packages and the build configuration

Odin packages are directories, and which files belong depends on the target — get this right first,
because everything else hangs off it.

- **Target**: OS + arch (+ `ODIN_DEBUG`, `ODIN_NO_RTTI`, … build constants and `-define`s). Default
  to the host; overridable in `.thor/odin-analyzer.json` (see Q2.1).
- **File selection**: filename suffix rules (`_windows`, `_linux`, `_darwin`, `_freebsd`,
  `_openbsd`, `_netbsd`, `_haiku`, `_js`, `_wasi`, `_freestanding`, arch suffixes and combined
  `_linux_amd64`), `#+build` expressions, `#+build ignore`, and `_test.odin` handling.
- **`when` evaluation** at file and block scope via `const_eval`: a declaration under a false
  `when` exists for navigation ("inactive" — greyed out) but not for resolution. This is the
  correct answer to today's "two declarations of the same name in one package → picker" for the
  per-OS case.
- **Collections**: `base`, `core`, `vendor`, `shared` from `ODIN_ROOT` plus the custom collections
  already read from `.thor/odin-analyzer.json` (`collection_flags` stays the one source).
- **Toolchain identity** (`odin version` + `ODIN_ROOT` hash) keys the persistent stdlib cache
  (5.10).

### 5.3 Name resolution

- **Scope chain**: block → procedure → file (imports and `#+private file` decls) → package →
  universe (`base:builtin` + `@(builtin)` in `base:runtime`, as `builtins.odin` already reads off
  the toolchain).
- **Order rules**: `::` decls order-independent within their scope; `:`/`:=` visible after their
  statement (today's `visible_from`, made structural); `x := x` reads the outer `x`.
- **`using`**: struct fields (embedding), parameters, the `using` statement (behind
  `#+feature using-stmt`), `using` of a package import if still accepted — all as scope entries
  that point at a field path, with ambiguity reported rather than silently resolved.
- **Labels**, **enum member implicit selectors** (resolved against the expected type, 5.5),
  **struct field names in compound literals** (against the literal's type).
- **Symbols are IDs** (`Symbol_Id` = file + item index or local index) so references, rename and
  "find implementations" compare integers, not names and offsets.
- **Visibility**: `@(private)`, `@(private="file")`, `#+private`, `#+private file` — enforced and
  reported (today's `Visibility` and `def_reaches`, moved into resolution).

### 5.4 Type representation

An interned table, `Type_Id :: distinct u32`, one per structurally unique type per DB revision
(named types are unique by symbol, structural ones by content hash):

- **Basic**: all sized ints (incl. endian-specific `i32le`/`u16be`…), `int`/`uint`/`uintptr`,
  floats (`f16`…`f64`, endian variants), complex and quaternion types, `bool`/`b8`…`b64`, `rune`,
  `string`, `cstring`, `rawptr`, `typeid`, `any`.
- **Untyped**: untyped int / float / rune / string / bool / nil / uninit — the representation the
  roadmap noted was missing, needed for constant arithmetic and `x + 1` typing.
- **Constructors**: pointer, multi-pointer, slice, array (with evaluated length), enumerated array,
  dynamic array, map, `bit_set` (element + backing), `bit_field`, matrix, `#simd`, `#soa` variants,
  struct (fields with offsets *optional*, tags, `using`, flags), union (variants, flags), enum
  (backing + members with evaluated values), proc (params with defaults/flags, results, calling
  convention, diverging, variadic kind), tuple (multi-returns), named (symbol + underlying),
  `distinct`, polymorphic parameter `$T`, instantiated generic (`List(int)` → substituted struct).
- **Pretty printer** that writes types the way the user wrote them (aliases kept), for hover and
  completion details — replaces `type_ref_text` and signature-text slicing.

### 5.5 Checking procedure bodies

Lazy, per procedure (`body_check`), so a keystroke re-checks one body. Bidirectional:
`check_expr(expr, expected: Type_Id) -> Operand{mode, type, const_value}`.

- **Literals and constants**: untyped constants with exact arithmetic (big-int for overflow
  detection; the `core:math/big` package exists), conversion to the expected type with
  range checks.
- **Implicit selectors** use `expected` directly — `expected_type_at`'s tree climb becomes the
  normal flow of type information.
- **Calls**: argument matching (positional, named, defaults, variadics, `#c_vararg`, `#any_int`),
  **proc-group overload resolution** with the compiler's scoring (exact > implicit conversion >
  untyped constant > `any`), multi-return unpacking, `#optional_ok` / `#optional_allocator_error`,
  `@(require_results)`.
- **Polymorphism**: real unification of `$T`/`$N` against argument types, `typeid` parameters,
  `where` clause evaluation (constant-folded), struct/union polymorphic params, instantiation cache
  keyed by (generic, args).
- **Conversions**: `cast`, `transmute` (size-equality check needs layout → optional, see Q3.4),
  `auto_cast`, call-style `T(x)`, assignability rules, distinct-type rules, comparison and
  operator validity per type class, `in`/`not_in` over maps and bit_sets.
- **Control constructs**: `or_return` (enclosing proc's last result must match), `or_else`,
  `or_break`/`or_continue`, type switches narrowing per case, `#partial switch` exhaustiveness,
  `defer`, `context` and `context.allocator` typing.
- **Builtins** typed by special rules (`len`, `cap`, `size_of`, `offset_of`, `type_of`,
  `typeid_of`, `make`, `new`, `append`, `delete`, `swizzle`, `min`/`max`/`clamp`, `soa_zip`, …) —
  a table in `sema/builtins_check.odin`, driven by the names `builtins.odin` already discovers.

### 5.6 Control flow and dataflow

Per procedure, from the checked body:

- **CFG** with `defer` modelled as code duplicated onto every exit edge of its scope (that is the
  semantic), plus `return`, `or_return`, `break`/`continue` with labels, `fallthrough`,
  `panic`/`-> !` calls as terminators, `#assert`/`assert` as conditional terminators.
- **Analyses** (monotone frameworks over the CFG):
  - reachability → unreachable code, missing return in a proc with results;
  - liveness → value assigned but never read, unused variable (with Odin's `_` rule);
  - simple nil-ness over pointers/maybe-unions → definite nil dereference;
  - allocation ownership (heuristic, opt-in): `make`/`new`/`clone`/`strings.*` results tracked to
    `delete`/`free`/return/escape into a struct → "allocated and never freed or returned",
    "freed twice on this path", "used after `delete`"; awareness of `context.temp_allocator`
    and arena allocators so those are not flagged;
  - escapes: returning a slice of a local fixed array, `&local` stored into something that outlives
    the frame.

### 5.7 Diagnostics catalog

Three tiers. Every diagnostic has a stable id (shown in hover, used for suppression).

**Tier 1 — compiler parity (errors, live while typing)**

| Id | What |
| --- | --- |
| `syntax/*` | every parse error from 4.4 |
| `name/undeclared` | undeclared identifier / package / field / enum member |
| `name/redeclared` | duplicate decl in a scope or package (build-aware) |
| `name/private` | use of a `@(private)` symbol from outside its package/file |
| `import/unresolved` | import path that resolves to no directory |
| `import/cycle` | import cycle |
| `type/mismatch` | assignment/argument/return type mismatch |
| `type/no-member` | selector on a type without that field/member |
| `call/arity`, `call/named` | wrong argument count, unknown/duplicate named arg |
| `call/overload` | no proc in the group matches / ambiguous match |
| `poly/where` | `where` clause or `$T: typeid/C` constraint not satisfied (today explicitly left to the compiler) |
| `const/overflow`, `const/not-constant` | constant out of range, non-constant where one is required (array len, `when`, `#assert`) |
| `assert/static` | `#assert` evaluates false |
| `flow/missing-return` | proc with results can fall off the end |
| `switch/non-exhaustive` | non-`#partial` switch over enum/union missing cases (with a quick fix) |
| `or_return/mismatch` | `or_return` in a proc whose results can't receive it |

**Tier 2 — the compiler's `-vet` family (warnings, each toggleable, defaults mirroring the flags)**

`vet/unused-variable`, `vet/unused-import`, `vet/unused-procedure`, `vet/shadowing`,
`vet/using-stmt`, `vet/using-param`, `vet/style`, `vet/semicolon`, `vet/cast` (redundant cast),
`vet/tabs`, `vet/packages`.

**Tier 3 — lints the compiler doesn't have (opt-in or warning; see Q4)**

| Id | What |
| --- | --- |
| `mem/leak` | allocation with no free/return/escape on some path (heuristic) |
| `mem/double-free`, `mem/use-after-free` | from the ownership dataflow |
| `mem/temp-escape` | value from `context.temp_allocator` stored somewhere long-lived |
| `mem/dangling-slice` | slice/pointer to a stack local escapes |
| `defer/in-loop` | `defer` inside a loop body (runs at scope end, often surprising) |
| `perf/range-copy` | `for x in big_structs` copying a large struct each iteration (suggest `&x`) |
| `api/ignored-error` | discarding an `Allocator_Error`/`bool ok`/error-union result |
| `api/fmt-verbs` | `fmt.printf`-family verb/arg count & type mismatch |
| `api/deprecated` | use of `@(deprecated)` symbols |
| `flow/unreachable` | code after `return`/`panic`/diverging call |
| `flow/dead-store` | value overwritten before being read |
| `nil/deref` | dereference of a definitely-nil pointer |
| `style/naming` | configurable naming conventions (`Ada_Case` types, `snake_case` procs…) |
| `logic/self-assign`, `logic/identical-branches`, `logic/const-condition` | classic sanity checks |

### 5.8 Relationship with `odin check`

- Native diagnostics are **live** (debounced like semantic tokens) for the open file and, cheaply,
  its package.
- `odin check` keeps running on save as today and remains **authoritative**: when it reports for a
  file, its errors replace native Tier 1 errors *at the same range/class*; native-only lints
  (Tier 3) are kept alongside.
- Disagreement telemetry (debug setting): when the compiler errors where the native checker was
  silent, or vice versa, log both — that log is the checker's to-do list.
- See Q1.3 for whether to make the compiler run optional.

### 5.9 Suppression and configuration

- Inline: `// thor:ignore <id>` (next line) and `// thor:ignore-file <id>`; unknown ids warn.
- `.thor/odin-analyzer.json` gains `"target"`, `"defines"`, `"diagnostics": {"<id>": "off" |
  "hint" | "warning" | "error"}`, `"lints": {"mem/leak": {"allocators": ["…"]}}`, and an
  `"engine": "legacy" | "next"` switch during migration. Parsed by the existing `config.odin` cache.

### 5.10 Persistent caches

- **Stdlib cache on disk**: item trees + package scopes + decl types for `base/core/vendor`, keyed by
  toolchain identity, written to Thor's cache dir. Cold start then never parses the stdlib for
  names, only for bodies the user navigates into.
- **Workspace cache** (optional, Q5.2): item trees per file keyed by content hash.
- Format: a versioned binary blob; any mismatch → rebuild silently.

---

## 6. Part C — porting the features

Each request kind moves to `lang/odin/ide/<feature>.odin` as a thin translation from sema answers to
`lang.Result`. The left column's files shrink to nothing.

| Request kind | Today | On the new core |
| --- | --- | --- |
| `Definition` | LOCALS + index scan + per-feature inference (`resolve.odin`, `infer.odin`, `decl.odin`, `typeref.odin`, `using.odin`, `container.odin`, `generics.odin`) | `body_check` gives every name/selector its `Symbol_Id`; jump to its decl. Proc groups: the overload resolver's choice, picker only when ambiguous. `when`-inactive candidates shown last, marked |
| `Hover` | decl text + `hover_expr` fallback | Type of the expression under the caret (pretty-printed), constant value, doc comment, size/align (if layout is on), for proc groups the chosen member |
| `Completion` | per-context producers, filler-identifier repair | Scope enumeration at caret + member enumeration of the operand's `Type_Id` + expected-type ranking (enum members first for `.`) + postfix and snippet completions (Q6) + auto-import of unimported packages |
| `Signature_Help` | call at caret, signature text | Resolved callee type; active param from the arg the caret is in, named args aware; for groups, members filtered by arguments so far |
| `References` / `Rename` | name-set prefilter + reparse + resolve each hit | Prefilter stays (identifier sets from the index), confirmation by `Symbol_Id` equality — exact, including through `using`, implicit selectors and compound-literal field names |
| `Document_Symbols` / `Workspace_Symbols` | index rows | `item_tree` rows; nested (struct fields, enum members, procs inside procs) |
| `Semantic_Tokens` | classify via resolution, with caps | Free byproduct of `body_check`: every identifier already has a resolved kind; caps go away. Adds tokens for inactive `when` regions, mutable vs constant, `distinct` types, deprecated |
| `Diagnostics` | `odin check` only | Native live (5.7) + `odin check` on save (5.8) |
| `Code_Actions` | add import, `:=` fixes, … | Existing ones on the new core + quick fixes attached to diagnostics: fill missing switch cases, add missing struct fields to a literal, add `or_return`, remove unused import/variable, add `#partial`, create declaration for undeclared proc/type, extract procedure/variable, inline variable, convert between `if` chains and `switch` (Q6) |
| `Format*` | `core:odin/parser` + printer | Printer ported to the lossless tree — comments and blank lines are in the tree, so `format/comments.odin`'s re-attachment logic shrinks; format-on-type can format just the closed block |
| `Package_Doc` | `packagedoc.odin` | `package_scope` + doc comments |

New request kinds this unlocks (seam additions, all optional — Q6): inlay hints (inferred types on
`:=`, parameter names at call sites), call hierarchy, type hierarchy (`using` embeddings, union
variants), find implementations of a proc type, selection range expansion, document highlight,
"go to type definition".

---

## 7. Part D — performance and concurrency

- **Threads**: the Manager's bounded pool is unchanged. The DB is shared; queries are memoized with
  per-slot locks (claim-or-wait), so two workers asking the same `package_scope` compute it once.
  Cycle detection in the query stack turns a recursive type (`Node :: struct { next: ^Node }` is
  fine; `A :: B; B :: A` is not) into a diagnostic, not a hang — replacing today's depth caps.
- **Cancellation**: every query loop polls a cheap flag combining `lang.request_cancelled(req)` and
  the DB's write generation.
- **Allocation**: green trees in per-parse arenas; sema tables in per-revision arenas swept by
  generation; request results still cloned into the Manager's allocator as the seam requires.
- **Budgets** (p95, release):

| Path | Budget |
| --- | --- |
| Keystroke → semantic tokens for the visible file | ≤ 16 ms |
| Keystroke → live diagnostics for the file | ≤ 50 ms |
| Completion list | ≤ 30 ms |
| Goto/hover | ≤ 10 ms warm |
| Cold open of a workspace the size of Thor (stdlib cache warm) | ≤ 1 s to first answers |
| Resident memory for Thor's workspace + stdlib | ≤ 400 MB |

- **Benchmarks** live beside the tests (`build.odin -- bench lang/odin`) and run Thor's own sources
  as the workload.

---

## 8. Part E — migration and milestones

Strategy: strangler fig. Both engines exist side by side behind `"engine"` in the workspace config
(default `legacy` until M6). The 277 existing tests run against both; new tests target `next` only.

| Milestone | Deliverable | Exit criteria |
| --- | --- | --- |
| **M0 — Groundwork** (1–2 wk) | `syntax`/`sema` package skeletons, `run_tests` entries, engine switch in `config.odin`, test harness that runs every existing test against a chosen engine, benchmark harness, corpus fetcher | Harness green on `legacy`; corpus pinned |
| **M1 — Lexer + parser** (4–6 wk) | 4.2–4.4, coverage list 4.6, `gen_syntax`, `debug_dump` | Lossless on corpus; zero errors on compiler-accepted files; fuzzing clean for 24 h; budgets 4.8 met |
| **M2 — Incremental + formatter port** (2–3 wk) | 4.5; formatter on the new tree | Incremental = cold across scripted sessions; all 1,140 lines of `format_test.odin` pass; `core:odin/parser` no longer imported outside tests |
| **M3 — Query DB, packages, item trees, resolution** (4 wk) | 5.1–5.3, universe scope from `builtins.odin`, stdlib disk cache | `Definition`, `References`, `Rename`, `Document/Workspace_Symbols`, `Package_Doc` pass all existing tests on `next`; build-aware duplicate handling |
| **M4 — Types + body checking** (6–8 wk) | 5.4–5.5 incl. generics and overloads | `Hover`, `Completion`, `Signature_Help`, `Semantic_Tokens` pass all existing tests on `next`; every expression in Thor's sources gets a type (coverage metric ≥ 99%) |
| **M5 — Live diagnostics, Tier 1** (3–4 wk) | 5.7 Tier 1, 5.8 merge | On the corpus: zero false errors on compiler-clean code; ≥ 90% of a seeded-error suite matched to the compiler's diagnostics |
| **M6 — Switch default** (1–2 wk) | `next` default; `legacy` still selectable | One release cycle with no regression reports; then delete `legacy` (`resolve.odin`, `infer.odin`, `typeref.odin`, `decl.odin`, `generics.odin`, `using.odin`, `container.odin`, LOCALS query use, `treecache` dependency in `lang/odin`) |
| **M7 — CFG, Tier 2 vet, quick fixes** (3–4 wk) | 5.6 reachability/liveness, vet family, fixes in section 6 | Vet output matches `odin check -vet` on the corpus |
| **M8 — Tier 3 lints + new request kinds** (ongoing) | Ownership dataflow, API lints, inlay hints etc. per answers in section 11 | Each lint ships with a false-positive audit on the corpus (≤ 1 FP per 10k lines before default-on) |

Rough total to M6: **~6 months for one person** working steadily; M1 and M4 are the long poles.

Documentation kept in step at each milestone: `lang/ROADMAP.md` (the living source of truth),
`CLAUDE.md`'s `lang` section and package list, `docs/` user docs for new diagnostics and settings,
and the `CHANGELOG.md`.

---

## 9. Testing strategy (summary)

1. **Existing black-box tests** (277) — run on both engines until M6, then on `next`.
2. **Parser**: losslessness, corpus, differential vs `core:odin/parser`, fuzzing, incremental = cold,
   snapshots.
3. **Sema**: `testdata` files with inline expectations — `x := f() // ^ type: []int` and
   `foo(1) // error: call/arity` — the rust-analyzer / clang `-verify` style, so a test is one file.
4. **Compiler oracle**: a seeded-error suite (mutate valid files: drop an import, change an argument
   type, delete a case) run through `odin check` and the native checker; compare id/line.
5. **Type coverage metric** on Thor's own sources (expressions with an unknown type / total).
6. **Benchmarks** with thresholds in CI (release flags only, so they don't flake under `-debug`).

---

## 10. Risks

| Risk | Mitigation |
| --- | --- |
| Odin keeps evolving (syntax and checker rules) | Toolchain identity in caches; the parser reports "unknown directive/attribute" softly instead of failing; differential tests against the installed toolchain catch drift; a quarterly sync task |
| Checker false positives erode trust | Tier 1 only turns default-on after the M5 corpus bar; `odin check` stays authoritative; ids + suppression from day one |
| Rewrite stalls with two engines forever | Hard milestone to delete `legacy` (M6); no new features on `legacy` after M3 |
| Memory blow-up from resident sema | Body-level LRU, per-revision arenas, a memory budget test on Thor's workspace |
| Thread contention in the DB | Per-slot locks, snapshot reads, early cutoff; measured by the benchmark suite under parallel requests |
| Generics/overload edge cases | Port the compiler's rules from `check_expr.cpp` / `check_type.cpp` deliberately, with the oracle suite as the judge |

---

## 11. Questions for you

These are the decisions that change scope, order or design. Each has my default in **bold**, so
"defaults are fine" is a complete answer.

### 11.1 Parser and the role of tree-sitter

1. **Parser approach** — own lossless resilient parser (option C), a fork of `core:odin/parser`
   (B), or start with B and migrate to C later? **C.**
3. **Toolchain target** — which Odin versions must the parser accept: only the latest `dev-YYYY-MM`,
   or a range (e.g. the last 6 monthly releases)? **Latest + previous 3.**
4. Should the new parser be usable **outside Thor** (its own repo / submodule like Loom, e.g. for a
   standalone LSP or CLI linter later)? This affects API tidiness and licensing (Thor is GPLv3).
   **Inside Thor, but with no imports from `lang`, so extraction stays cheap.**

### 11.2 Analyzer behaviour

1. **Build target** — analyze for the host OS/arch only, or let the workspace pick a target (and
   maybe several at once, e.g. "show me errors for Windows and Linux")? **Host by default,
   overridable per workspace; multi-target later.**
2. **Live diagnostics scope** — open files only, the open file's package, or the whole workspace in
   the background (a "Problems" panel)? **Open file live + its package on idle; workspace on demand.**
3. **`odin check`** — keep running it on save as authoritative, make it optional once native
   diagnostics are good, or run it only on demand? **Keep on save, authoritative.**
4. **Memory layout** — should hover show `size_of`/`align_of`/field offsets (requires a layout engine
   per target, and enables `transmute` size checks)? **Yes, in M4**
5. **Inactive `when` code** — grey it out, analyze it as if active (catch errors in other-OS
   code), or both? **Grey out + resolve navigation into it; no errors from it.**

### 11.3 Diagnostics and lints

1. Which **Tier 3 lints** matter most to you? Rank or cut: memory leak / double free /
   use-after-free, temp-allocator escape, dangling slice, `defer` in loop, range copy of large
   structs, ignored error results, `fmt.printf` verb checking, deprecated use, unreachable code,
   dead stores, nil deref, naming conventions, logic checks. **Default order: fmt verbs, ignored
   errors, unreachable, dangling slice, temp escape, leak/double-free, the rest.**
2. **Default severity** for Tier 3 — off by default, hints (faint), or warnings? **Hints, with
   per-id override.**
3. **Memory-ownership analysis** — worth the complexity (heuristic, some false positives), or out of
   scope? If in: which allocators should count as "no free needed" beyond `temp_allocator` and
   arenas? **In scope, opt-in, M8.**
4. **Suppression syntax** — `// thor:ignore <id>` OK, or a different spelling (e.g. one compatible
   with another tool)? **`thor:ignore`.**
5. Do you want **custom user lints** (e.g. Lua plugins walking the sema API, since Thor already has a
   sandboxed Lua plugin system)? **Not in this plan; design the sema API so it's possible.**

### 11.4 IDE features

1. Which **new request kinds** do you want, in priority order: inlay hints (types / parameter
   names), call hierarchy, type hierarchy, find implementations, document highlight, selection
   range, go to type definition, code lens (reference counts)? **Inlay hints → document highlight →
   go to type definition → call hierarchy → rest.**
2. **Refactorings** beyond rename: extract procedure/variable, inline variable, change signature
   (update all call sites), move declaration to another file/package, generate `switch` cases,
   generate struct literal fields, convert `if` chain ↔ `switch`. Which ones? **all**
3. **Completion extras**: postfix completions (`x.if`, `x.for`, `x.defer_delete`), snippet
   completions for procs (with parameters as tabstops — snippet support already exists from the LSP
   work), auto-import on accept? **All three, auto-import first.**
4. **Hover content**: also show doc comments rendered as markdown (Thor has a markdown renderer),
   constant values, and the instantiated signature for generic calls? **Yes to all.**

### 11.5 Performance and resources

1. Is a **disk cache** (stdlib + workspace item trees) acceptable, and where — Thor's per-user cache
   dir or `.thor/` in the workspace? **Per-user cache dir; never write into the workspace.**
2. **Memory ceiling** you'd accept for a big workspace? **~400 MB for Thor-sized + stdlib.**
3. Any **target hardware** to keep in mind (low-end laptops, CI runners) for the latency budgets?
   **Mid-range laptop; budgets in section 7.**

### 11.6 Process

1. Are you OK with **two engines side by side** for ~4 months, with `legacy` frozen for new
   features after M3? **No, different branch so not used in release.**
3. Would you rather ship **visible wins early** (e.g. live syntax errors right after M1 — they need
   only the parser) even before the rest is ported? **Yes: live syntax errors after M1, inlay hints
   after M4.**

## 12. Formatter

1. Add option to align vertically nicely like definitions in a struct (default enabled)

---

## Appendix — files touched (current repo)

- **Replaced over time:** `lang/odin/{resolve,infer,typeref,decl,generics,using,container,overload,
  signature,completion,references,symbols,semantic,actions,packagedoc,ast,index}.odin` → `sema/` +
  `ide/`.
- **Kept, adapted:** `engine.odin` (Backend glue; drops `ts.Language`, LOCALS query, `trees`),
  `config.odin` (new keys), `builtins.odin` (feeds the universe scope), `check.odin` (merge logic),
  `formatter.odin` + `format/` (ported to the new tree), `path_*.odin`.
- **Unchanged:** `lang/lang.odin` and the seam, `lang/lsp/*`, `thor/lang_host.odin`, `treecache`
  (still used by `syntax/` highlighting).
- **Build:** `build.odin` — `run_tests` packages, `gen_syntax`, `bench`; the tree-sitter Odin grammar
  stays in `GRAMMARS` while highlighting uses it (11.1.2).
