# ZLAY Memory

## Current State

- ZLAY is a renderer-neutral, native Zig rewrite of pinned Clay 0.14 behavior.
- Production code under `src/` is Zig-only and has no package dependencies.
- The optional paragraph-provider seam carries advanced shaping state and
  generation-bound render leases without selecting a font library.
- The compiled mock provider demonstrates that seam, and the built-in inspector
  has an opt-in higher-contrast, larger-type, roomier-row theme while retaining
  pinned defaults.
- Push/PR CI runs the bounded C-free check; a separate read-only manual/weekly
  workflow runs the complete aggregate matrix.
- Maintained local gate: `zig build verify-all` with Zig 0.16.0.
- The only open proof item is physical AArch64 target-default hash execution;
  the 2026-07-31 QEMU 11.0.3 refresh passes 206/207 module tests plus 4/4
  manifest tests but remains supplemental and cannot close it.
- The first package release does not wait for ZL-202: its documented support
  boundary is native x86-64 Linux plus the maintained freestanding-WebAssembly
  compile/runtime lanes.

## Architecture Notes

- `Context` owns allocator-backed frame and retained state. Applications own
  graphics, font loading, shaping, rasterization, glyph atlases, and drawing.
- Legacy text follows Clay's callback/cache/wrapping contract. Advanced text
  uses `ParagraphProvider` and exact text/style/final-width cache keys.
- Returned command arrays, text bytes, style slices, and provider payloads are
  borrowed according to the lifetimes documented in `docs/API.md`.

## Migration Boundary

- Production is already Zig. C is retained only as the SHA-pinned differential
  oracle; replacing it would remove the independent parity reference.
- Python is retained for proof/evidence tooling where its standard-library JSON,
  filesystem, and mutation-test support is substantially smaller than a Zig
  rewrite. Shell remains only for direct external-tool orchestration, and the
  20-line JavaScript file is the WebAssembly host smoke.
- Migrate a tool only when the Zig replacement is smaller, preserves its proof
  contract, and passes the same mutation matrix. Language conversion alone is
  not an accepted reason.

## Gotchas

- This repository requires Zig 0.16.x; `/usr/bin/zig` is the validated local
  binary in this workspace.
- Do not edit `tests/oracle/clay.h` without updating the explicit upstream pin
  and every dependent parity artifact.
- Do not retain paragraph command pointers across Context mutation; retain the
  provider lease explicitly for asynchronous rendering.