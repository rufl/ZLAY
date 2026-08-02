# ZLAY backlog

This file contains only open work. Completed rows move to `BACKLOG_ARCHIVE.md`
with the command or artifact that proves completion.

The normative upstream snapshot is Nic Barker's Clay `clay.h` at
`e6cc36941ab2af5d81107617039d6f527a1c660b`; see `docs/UPSTREAM.md`.

## Source Of Truth Policy

- `[truth:code]` `src/` is the production implementation; production remains
  Zig-only and dependency-free.
- `[truth:test]` `zig build verify-all` is the maintained aggregate proof gate;
  `.overzeer/proof-results.md` records maintainer-run outcomes.
- `[truth:docs]` `BACKLOG.md` contains only open work, while completed work and
  its proof move to `BACKLOG_ARCHIVE.md`.
- `[truth:upstream]` `tests/oracle/clay.h`, `docs/UPSTREAM.md`, and the recorded
  SHA-256 pin define the differential parity baseline.
- A source or documentation claim is not complete solely because code exists;
  closure requires the acceptance proof named by its backlog row.

The broad ZL-115 certification row was superseded by the 2026-07-13 audit and
decomposed into measurable proof obligations; its lineage is retained in
`BACKLOG_ARCHIVE.md`. All host/pinned-source behavioral and proof-integrity rows
are now archived. The only open evidence row is target-default hash execution
on real AArch64 hardware. Supplemental static Debug AArch64 execution under
QEMU is complete and archived, but is explicitly non-certifying.

## P1 — first release

| ID | Work | Acceptance proof | Status |
|---|---|---|---|
| ZL-218 | Publish the first supported ZLAY package release | Owner selects the canonical source URL; package version leaves `-dev`; a clean URL-based consumer build, read-only CI run, signed/tagged release, and published changelog all pass | The first release is scoped to verified native x86-64 Linux plus the maintained freestanding-WebAssembly compile/runtime lanes; physical AArch64 certification is explicitly deferred to ZL-202. Publication remains externally blocked only on the canonical destination and resulting hosted URL/tag proof. Local source, path and generated-archive consumers, the mock paragraph-provider example, security, documentation, and aggregate verification gates pass; `docs/RELEASE.md` records the remaining procedure. |

## P2 — cross-target proof

| ID | Work | Acceptance proof | Status |
|---|---|---|---|
| ZL-202 | Match and verify target-default text-cache data hashing | Default and scalar C/Zig vectors cover empty and boundary lengths on x86-64 and AArch64; wasm/other targets retain the pinned scalar fallback; collision/cache lifecycle tests pass; a current-source Debug raw record from native physical AArch64 execution validates and is exact-byte imported; its immutable runner record, completed certification log, exact runner-provenance, native-host, and capture markers, and separate accepted human-review receipt validate; maintainers then make the explicit closure decision | Externally blocked in this checkout by the absence of a qualifying physical AArch64 runner and resulting artifact set; the exact-output manifest selects reviewed x86-64/AArch64 contracts, the x86-64 comparison passes, the guarded AArch64 fixtures/tests cross-compile, and the archived supplemental lane freshly runs the static Debug root suite, manifest suite, and exact C/Zig trace under identified QEMU user mode with every proof/closure flag false; non-overwriting runner-provenance creation, local record preflight, precompile cache-managed runner binding, pre-gate source snapshot plus ordinary persistent-drift checks (not adversarial ABA/source-to-binary proof), raw-v1 capture/validation/required import, build-DAG mutation audit, and review-receipt contracts are build-wired; no real imported raw record, runner record, completed log, or receipt exists yet |

The complete fail-closed certification, import, provenance, and review
procedure lives in [`evidence/README.md`](evidence/README.md) and is exposed by
the `aarch64-hash-*` build steps documented in `README.md`. Its machine checks
bind source, runner records, test logs, artifacts, and non-overwriting outputs,
but physical-machine identity and final closure remain explicit human decisions.
Cross-compilation, QEMU, translated execution, and synthetic receipts cannot
close ZL-202.

## Deliberate boundaries

- Production ZLAY must not use `@cImport`, link Clay C objects, or call through an
  FFI layer.
- Renderer implementations are adapters, not part of the layout core.
- The pinned C header may be used only by differential tests and provenance
  tooling.
- A generated binding or compile-only smoke does not close a behavioral parity
  row.
- Retryable Zig errors, checked nullable accessors, explicit contexts, full
  unbalanced-stack repair, and selected upstream-bug repairs are reviewed native
  divergences recorded in `docs/PARITY.md`.
- Public pointer capacity starts from the configured element ceiling and remains
  persistent when that ceiling is lowered, matching Clay's initialized array;
  render capacity derives from the current ceiling unless an explicit render
  ceiling is supplied. Render insertion reserves the final slot exactly as
  pinned Clay does. Oversized native ceilings clamp to `maxInt(i32)`, and an
  overflow prefix with an open scissor/overlay scope is rejected rather than
  returned or retained through checked context access.
- Duplicate IDs preserve the first declared query entry instead of letting the
  later duplicate overwrite its bounds; both observed traces are digest-pinned.
