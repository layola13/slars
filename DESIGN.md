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
## §11 Phase-2 verification registrations (AG6, 2026-10-27)

Scope: std semantic verification + acceptance wave 2 + two registered
items. Measured on Colab runtime 410dd20b5a78 against sci 33df6307,
sa_plugin_sla 3de91932, this repo at 84ae20c. (Note: the phase-1 DESIGN
as pushed ends at §5; §§6–§10 are referenced in the text but absent.)

### §11.1 plugin_* std surfaces: semantic verification verdict

Phase 1's M3 evidence for `plugin_async.sla` / `plugin_http_server.sla` /
`plugin_sqlite.sla` was import-level only (empty mains). AG6 drove all
three for real. Headline: **the surfaces compile, but the SA-macro
facades they wrap are largely NOT drivable from SLA/slars surface code
at this HEAD; the underlying std ABI is sound and is driven positively
instead.** The verification pack lives in `tests/verify/`
(`run_verify.sh`: 3 positives + 7 repros with expected signatures).

**§11.1.0 The .sla surface alone does not export the macros.** A root
file importing only `sa_std/plugin_async.sla` and calling
`PLUGIN_ASYNC_OP_NEW` fails `sa check` with
`Undefined call: PLUGIN_ASYNC_OP_NEW (error.UndefinedVariable)`.
Identical for `SA_HTTP_SERVER_ACCEPT_V2` via `plugin_http_server.sla`
and `SA_SQLITE_OPEN` via `plugin_sqlite.sla`. Macro visibility is
per-file direct-import: consumers must also import the underlying `.sa`
directly — which is what production SLA code in fact does. Repro:
`tests/verify/repro_sla_surface_macros.slars`.

**§11.1.1 Root cause (shared SLA macro-call lowering).** For an SA
macro whose leading parameter is an output the macro assigns, the SLA
frontend does not treat the argument as a definition of the caller's
variable:

- Register-backed (integer) variable: the expansion's first assignment
  (e.g. `%out_db = 0` in `SA_SQLITE_OPEN`, `%out_stmt = 0` in
  `SA_SQLITE_PREPARE`) collides with the frontend-materialized
  initializer — `build-exe` fails SAB verification with
  `RegisterRedefinition` ("register is already live").
- Slot-backed (pointer) variable: the frontend passes the slot's loaded
  value (NULL) as the argument; the expansion writes a throwaway temp
  and the result is discarded — the caller's pointer stays NULL and the
  first dereference segfaults. Visible directly in generated SA:
  `tmp_3 = load op+0 as ptr` / `EXPAND PLUGIN_ASYNC_OP_NEW tmp_3, ...` /
  `!tmp_3`, with no store-back to the slot.

Discrimination evidence (all in `tests/verify/`): the segfault
reproduces identically from a `.slars` root (`repro_plugin_facades.
slars`), a pure `.sla` root (`repro_plugin_facades_twin.sla`), and when
the macro call sits inside an imported `.sla` wrapper whose result is
returned to the root (`wrap_poll.sla` + `run_wrap_probe.slars` exits 2:
the poll pointer comes back NULL). So this is the shared checker's /
lowering's behaviour, not the slars transform. Macros whose outputs are
only assigned as the final act from a call result (e.g.
`SA_SQLITE_EXEC`'s status) survive; the PollResult value readers
(`POLL_RESULT_IS_READY` etc.) are fine — only the pointer-producing
calls are lost. Hand-written SA is unaffected: sci's
plugin-imported-macro seed tests drive the same macros from SA.

**§11.1.2 Per-surface verdicts.**

- `plugin_async`: facade NOT drivable. `PLUGIN_ASYNC_OP_*` and
  `PLUGIN_ASYNC_POLL_RESULT` lose their pointer outputs (segfault rc
  139, zero output, both root forms + wrapper form above). Positive
  drive of the same surface at the ABI level: `run_plugin_async_http.
  slars` runs an in-process v2 server + async client GET on
  127.0.0.1:18098 through the `sa_http_client_*_v2` externs the adapter
  wraps — poll to ready, status 200, body byte-verified, rc 0.
- `plugin_http_server`: facade NOT drivable. `SA_HTTP_SERVER_ACCEPT_V2`
  in isolation segfaults (`repro_accept_v2.slars`, rc 139);
  `SA_HTTP_SERVER_RESP_SEND_V2` traps at build with `CapabilityMismatch`
  at the expansion's call site for both u32 and i32 consumer variables
  (`repro_resp_send.sla`) — its macro head declares the status output
  u32 over an extern the generated SA calls under a mismatched
  contract. Positive drive: `run_plugin_http_server.slars` serves a
  real loopback request on 127.0.0.1:18097 via the v2 externs; curl
  receives exactly `{"hello":"slars-plugin-http"}`; rc 0.
- `plugin_sqlite`: facade PARTLY drivable. `SA_SQLITE_OPEN` and
  `SA_SQLITE_PREPARE` trap at build (`RegisterRedefinition`,
  `repro_sqlite_facade.sla`). `EXEC` / `BIND_TEXT` / `BIND_INT` /
  `STEP_JSON` / `QUERY_JSON` / `FINALIZE` / `CLOSE` build and run from
  surface code through one-macro-per-helper wrappers with pointer
  outputs consumed inside the receiving helper. `run_plugin_sqlite.
  slars` (raw externs for open/prepare, facade for the rest) performs
  full CRUD on a real file: DDL + wipe via EXEC, row 1 via
  prepare/bind/step, row 2 via EXEC, read-back via QUERY_JSON verified
  through sa_std JSON (count 2, k="answer", v=42), and an independent
  python3 sqlite3 cross-check of the file: `[('answer', 42),
  ('other', 7)]`. rc 0.

**Production exposure note.** The broken OPEN shape ships in the CXU
tree: `apps/free-key-server/src/licenseStore.sla` `sa_sqlite_open` is
byte-for-byte the wrapper shape that traps here (check-level gates
never exercised `build-exe` on it). Pointer-output consumers of the
`al_step_row` kind (`SA_SQLITE_STEP_JSON`'s `rp` read inside the same
helper) are the slot-backed class: the wrapper probe (§11.1.1) shows
inside-helper consumption does not rescue a lost pointer for the
PollResult shape; whether `rp` specifically survives should be audited
before any store is trusted at runtime. AG6's own QUERY_JSON read-back
above did survive — the difference between the STEP/QUERY load-outs and
the alloc-outs is registered here as observed behaviour, not explained
mechanism.

**Suggested fix paths (registered, not implemented — AG6 is
verify-only).** (1) Compiler side, the real fix: in the SLA macro-call
lowering, treat leading macro outputs as definitions — store back into
slot-backed variables (the pattern of the earlier `genImportedMacroCall`
C3 fix, extended to `.sa`-sourced macros) and suppress/version
the materialized initializer for register-backed variables whose first
definition is a macro output. (2) Std side, partial: pointer-style
macros (pass `&slot`, store through it — the `BYTES_EQ` pattern the sla
demos already use) are drivable today; converting the facade producers
to that shape would make them consumable without a compiler change,
but changes the macro contracts. (3) Shipping SLA wrapper functions in
the `plugin_*.sla` files does NOT work around the pointer loss (wrap
probe), so it is not a substitute for (1).

### §11.2 Registration (a): `&str` parameters and string literals

Minimal probes (`sa check`, canonical env, caches cleared; `.slars`
unless noted):

| probe | shape | result |
|---|---|---|
| p1 | `fn greet(s: &str)`, call `greet("hi")` | rc 1, TypeMismatch at call |
| p2 | `&str` param, let-bound literal variable as arg | rc 1, same TypeMismatch |
| p3 | `String` param, literal arg | rc 0 |
| p4 | pure `.sla`: `fn greet(s: str)`, literal arg | rc 1, identical TypeMismatch |
| p5 | pure `.sla`: `String` param, literal arg | rc 0 |
| p6/p7 | `let g: String = "hi";` | rc 1 at the let (declared tag=user_defined, val tag=primitive) |
| p6b–p8b | `fn mk() -> String { return "hi"; }` | rc 1 at return (expected String, actual raw_ptr) |

Qualification: **shared type-checker shape problem, not slars-transform
local.** Pure SLA reproduces p1 bit-for-bit (p4), and the checker files
are the shared symlink set. Two distinct gaps: (i) a `str` parameter
accepts neither a string literal nor a string binding at a call site —
the type appears unusable as a parameter type today (zero `: str`
parameter uses exist in sa_std's own `.sla` files); (ii) literal →
`String` coercion exists only in direct call-argument position, not in
let-annotation or return positions. A transform-side rewrite of `&str`
to `String` would typecheck (p3) but is NOT semantics-preserving
(`String` is owned: the argument moves, repeated calls would hit
UseAfterMove) and cannot even construct the value in let/return
positions per (ii) — so it is not recommended as the fix. Suggested
path: checker-side coercion — let a `str` parameter accept a string
literal/binding as a {ptr, len} pair (matching how std `.sa` code
receives slices via STR_PTR/STR_LEN), and extend literal → `String`
coercion to let/return positions or document its absence. Also note:
§4's statement that Rust `str`/`&str` parameters bind SLA string
literals directly is contradicted by p1/p2 and should be corrected
when this is fixed.

### §11.3 Registration (b): workspace entry resolution ignores `.slars`

Host-side status, evidenced behaviourally. The shared workspace
resolver (`src/workspace.zig` `sourcePathForRoot`, symlinked into this
plugin) hardcodes the member entry as `<root>/src/main.sla`, falling
back to `<root>/main.sla`, else `error.FileNotFound` — it never
consults the language-extension registry that file dispatch uses.

| scenario | result |
|---|---|
| workspace with member entry `src/main.slars`, `sa slars build-workspace` | rc 1: `workspace member has no src/main.sla or main.sla entry source` |
| identical control workspace with `src/main.sla`, `sa sla build-workspace` | rc 0 |
| host verb `sa build-workspace` (no file) inside the `.slars` workspace | rc 1: `error: FileNotFound` |

So extension dispatch works for explicit files (phase 1), but
workspace entry resolution is the hardcoded part. Suggested fix
(shared sci/sa_plugin_sla resolver, registered only): when probing a
member root, try `src/main.<ext>` / `main.<ext>` for each registered
language extension of the dispatching frontend, not only `.sla`.

### §11.4 Acceptance wave 2 (frozen in `acceptance/`)

Two larger real samples from box `codex-react-ui` @ `e113825e`, run
through the unchanged phase-1 walkers (`ts_walk.slars` vs `ref_walk.
sla`, byte-compare both ways and against the frozen expected):

| sample | origin | lines / bytes | expected bytes | node total |
|---|---|---|---|---|
| `topicTranscriptStore.ts` | `apps/web/src/app/transcripts/topicTranscriptStore.ts` | 1218 / 50,914 | 3,600 | 14,700 |
| `GatewayStatsPanel.tsx` | `apps/web/src/components/GatewayStatsPanel.tsx` | 998 / 51,393 | 2,166 | 18,358 |

Full suite after the addition: **5/5 byte-identical** — the two new
samples plus the original three unregressed (975 / 1,161 / 1,611
bytes, matching phase 1). Expected outputs were generated by the SLA
reference walker and then confirmed byte-identical against the slars
walker by `run_acceptance.sh`.
