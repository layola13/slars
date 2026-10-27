# slars — Design Notes (phase 1)

slars is a small Rust: a language frontend whose surface syntax tracks
Rust (stable) as closely as the shared SLA backend allows, with
Rust-style default immutability and mutable borrows enforced by a
slars-owned strict checker. It exists so that future Rust code can be
converted mechanically (rust2slars); the list of differences from full
Rust is decided by that census, not by taste, and every difference is
recorded here as supported / erased / loudly rejected — never silently
dropped.

## §1 Architecture and the sharing contract

Hard condition (user ruling, 2026-10-27): fork ONLY the frontend
(parse + check). Lowering and both code generators (SA text and SAB)
are shared with SLA as one codebase. The slars repository implements
this as a symlink farm:

- `src/*.zig` — every file is a relative symlink
  `../../sa_plugin_sla/src/<file>` EXCEPT the owned files below.
- Owned files: `parser.zig` and `plugin_compile.zig` (copies of the SLA
  files carrying small, auditable slars patches), `plugin.zig`,
  `plugin_commands.zig`, `local_cli.zig`, `plugin_skills.zig` (plugin
  identity: descriptor name, command marker, CLI marker, skill name —
  all "slars"), and `slars_frontend.zig` (the only new module).
- `build.zig` is a copy of SLA's with the library/CLI names changed to
  `slars`; `sap.json` declares `kind: "language"` and
  `language_extensions: [".slars"]`, so the host dispatches `.slars`
  files to this frontend by extension.
- SLA and sci are never modified by this project: at delivery both
  repositories are `git status`-clean at their pre-existing HEADs.

Why not a full fork: two diverging compilers. Why not a build.zig
module split: Zig's one-module-per-relative-import law makes the SLA
sources a single module graph rooted at `plugin.zig`; the seam that
actually exists is the Parser construction (module table + root) and
the compile entry points. The symlink farm was proven by a decisive
micro-test during M0 exploration of the original build: a cross-tree
relative `@import` fails ("import of file outside module path"), but a
symlinked file's imports resolve by the LINK's directory — so the
shared files see slars's own `parser.zig`, and the hook below applies
to every module in the tree. (Implementation note: this rebuild's
parser hook differs from the lost original in placement only — the
transform lives in `Parser.initWithDirAndOptions`, which both the root
parse and the module table use, instead of the Lexer.)

The two patches:

1. `parser.zig`: one import line, and in `initWithDirAndOptions`,
   `lexer.Lexer.init(buffer)` becomes
   `lexer.Lexer.init(slars_frontend.transformSource(allocator, buffer))`.
   The transform is a token-level Rust→SLA surface rewrite. It is a
   no-op on valid SLA sources: every rule targets a token pattern the
   SLA surface cannot contain (attributes `#[...]`, `let mut`,
   lifetimes, `ident!(...)`, char literals, `..=`, block comments...),
   so shared SLA behaviour is untouched.
2. `plugin_compile.zig`: one import line, and in `runSlaFrontend`
   (the shared trunk both codegen tails diverge from) a root-file
   gate: for `.slars` roots only,
   `slars_frontend.checkSource(...)` runs validation + the strict
   checker and aborts the compile on failure. `SLARS_DISABLE_STRICT=1`
   disables the gate (it exists to produce the bidirectional evidence
   of §5). The `check` subcommand in `plugin_commands.zig` runs its
   own inline frontend pipeline (it does not use `runSlaFrontend`), so
   the same gate is applied there too — this was found the hard way
   during the rebuild: `sa check` initially bypassed the gate while
   `sa build-exe` enforced it.

`slars_frontend.zig` contains: a small tokenizer (tokens carry source
ranges, prefix ranges and line numbers; it understands strings, raw
strings, char-vs-lifetime disambiguation, number suffixes and
longest-match punctuation), `transformSource` (§3, §6, §7) and
`checkSource = validateSource + strictCheck` (§5, §7).

## §2 Identity

- Plugin/descriptor/CLI name: `slars`; host command `sa slars ...`
  (the two-layer form is deprecated by the host; extension dispatch is
  the primary route).
- Library artifact: `libslars.so`; cache directory and freshness
  namespace are inherited from the shared backend (`.sla-cache`,
  namespace "sla") — a registered cosmetic inheritance, see §11.

## §3 The surface transform (what is rewritten before the shared parser)

- `let mut x` / `&mut T` / `mut` parameters: `mut` dropped (SLA
  bindings are mutable); mutability is remembered by the strict
  checker (§5), not by the backend.
- Lifetimes (`<'a, T>`, `&'a mut T`, `'_`): dropped, with comma fixups
  (`<'a, T>` → `<T>`, `<T, 'a>` → `<T>`). Lifetimes are the canonical
  erasure: SA's ownership/referee model checks what lifetimes would
  express.
- Char literals → decimal codepoints (`'a'` → `97`, `'\n'` → `10`,
  `'\u{1F600}'` → `128512`). A binding annotated `char` names the
  shared backend's user-defined char type, which has no literal
  constructor on the SLA surface — see §11.
- `loop { ... }` → `while true { ... }`.
- `pub` / `pub(crate)` etc: dropped (SLA has no visibility surface).
- `use a::b;`: erased when the path head is a prelude root
  (`std`/`core`/`alloc`); anything else is rejected (§6).
- `move` closures, `dyn` trait objects: keyword dropped.
- `extern "C" fn`: the ABI string is dropped.
- Block comments `/* ... */` (nested): blanked in prefixes, newlines
  preserved.
- `..=` in a `for` header: rewritten to `..` with ` + 1` spliced
  before the header's `{` (the range end is a full expression in the
  shared grammar). Outside `for` headers: rejected (§6).
- Attributes: see §6/§8. Macros: see §7.

## §4 Type mapping

Rust `str`/`&str` parameters bind SLA string literals directly
(`{ptr, len}` model shared with SLA); `String` is the SLA-side string
struct type, so a literal does not annotate as `String` (same rule as
SLA). `char` literals are codepoint integers. Integers/floats keep their Rust suffixes
(`5i64`, `5u64` are native SLA literal forms). Tuples, arrays, enums
(incl. tuple variants), `Option`/`Result` (from
`sa_std/core/option.sa`) are the shared backend's types — slars adds no
type machinery of its own, by design (the sharing contract).

## §5 The strict checker

Three rules, enforced on the ROOT `.slars` file before expansion
(imported `.sla` modules are SLA's business; imported `.slars` modules
still get the transform via the parser hook but are not strict-gated —
a phase-1 scoping decision, §11):

- `SLARS-IMMUTABLE-ASSIGN`: assignment (`=`, `+=`, ...) to a binding
  not declared `let mut`; also field/index-chain assignment through
  such a binding, unless the binding holds a `&mut` (pointee
  mutability — assignment through a field of a `&mut` is legal Rust
  and is allowed).
- `SLARS-BORROW-CONFLICT`: when a `let` takes a borrow of a root
  binding while another borrow of the same root is live in an
  enclosing-or-same frame and either side is mutable. Liveness is
  lexical-conservative (no NLL): a borrow dies with the frame that
  holds its binding.
- `SLARS-BORROW-IMMUTABLE`: `&mut` of a binding that is neither
  `let mut` nor itself holding a `&mut`.

Metadata lives in the checker, not the AST: the shared AST has no
mutability bits or source positions, so the checker runs on the token
stream with a frame stack (bindings + live borrows per `{}` frame)
and declaration-index bookkeeping to avoid self-hits.

Bidirectional evidence for SLARS-BORROW-IMMUTABLE (the rule that has
no SLA counterpart: with the gate off, the transform erases `mut` and
the shared backend accepts the program): recorded in
`tests/run_tests.sh` runs during development and reproduced by
`SLARS_DISABLE_STRICT=1 sa check tests/fail/fail_borrow_immutable.slars`
(rc=0) vs the same command without the env var (rc=1,
`SLA
...[truncated 10348 chars]