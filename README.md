# slars

slars is a small Rust: a language frontend forked from SLA's frontend
(parser + checker surface), sharing SLA's lowering and both codegens
(text SA and SAB) through a symlink farm. Bindings are immutable by
default; `let mut`, `&` / `&mut` borrows and the rest of the Rust
surface syntax are supported as far as DESIGN.md's adjudication
table states. The goal is a future one-click Rust -> slars
conversion (rust2slars).

Layout:

- `src/` — every file is a relative symlink into
  `../../sa_plugin_sla/src/` EXCEPT the slars-owned frontend files:
  `parser.zig` (adds the transform hook), `plugin_compile.zig`
  (adds the .slars validation/strict gate) and `slars_frontend.zig`
  (the surface transform + strict checker; the only new module).
- `sla_std/std_macros.sla` — the hand-written standard macro library.
- `tests/` — the bidirectional corpus (pass / fail / run / unit).
- `acceptance/` — the phase-1 tree-sitter AST acceptance, frozen.
- `DESIGN.md` — the full design and adjudication record.

Build (from a checkout sitting next to sa_plugin_sla and sci):

```sh
/opt/zig17/zig build -Doptimize=ReleaseFast
SA_PLUGIN_DEV=1 sa plugin install --dev .
```
