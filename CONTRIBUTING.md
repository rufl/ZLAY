# Contributing to ZLAY

ZLAY is a behavior-preserving native Zig rewrite. Changes should be easy to map
back to the pinned upstream source and easy to disprove when they diverge.

## Local gate

Use Zig 0.16.0 or newer within the 0.16 compatibility line. Repository audit,
evidence, and review gates also require Python 3.10 or newer. The full gate
requires Clang, `llvm-profdata`, and `llvm-cov` for the pinned-source coverage
contract. Node.js lets the complete gate execute, rather than merely compile,
the freestanding-WebAssembly renderer smoke. `qemu-aarch64` is optional
contributor tooling for the separate supplemental AArch64 execution lane:

```sh
zig build verify-all
```

This runs formatting, the native suite, consumer examples, deterministic native
and WebAssembly renderer execution, the `wasm32-freestanding` compile, the
pinned-header digest check, compiled-C differential fixtures plus
reviewed-divergence trace digests, and the accountable pinned-source coverage
certifier. `zig build check` is the C-free subset for
fast iteration. `zig build renderer-smoke`, `zig build wasm-runtime-smoke`, and
`zig build profile` expose focused runtime/allocation checks. For changes to
sizing, hashing, commands, or transitions, `verify-all` preserves the required
Debug and ReleaseSafe matrix plus ReleaseFast/ReleaseSmall C-free
native/WebAssembly check lanes.
Use `zig build verify` only for the selected-mode iteration gate. Use `zig build
coverage-audit` to refresh the raw pinned-C coverage report and `zig build
clay-coverage-certify` to enforce the SHA-pinned fixture inventory plus 100%
accountable executable-line, source-function, and source-branch-direction
contract. The latter fails on any new uncovered coordinate, stale exclusion,
or fixture drift. Coverage demonstrates execution/accountability for the host
Clang/C99 scalar/common profile plus the native x86-64 SIMD source supplement;
a source function is covered when at least one emitted translation-unit instance
executes. Duplicate static-inline copies are not separate source definitions.
Differential traces and reviewed divergences remain the behavioral parity proof.

For target-default hash work, run the focused host comparison and guarded
cross-compile lane. Changes to the certification, raw-record, build-DAG, or
human-review contracts must also pass all focused mutation audits:

```sh
zig build hash-default-parity
zig build aarch64-hash-compile -Dtarget=aarch64-linux
zig build aarch64-hash-evidence-audit
zig build aarch64-hash-build-contract-audit
zig build aarch64-hash-review-audit
```

For the supplemental emulation contract, run its host-only mutation audit on
every host. If `qemu-aarch64` is available on `PATH`, also run the execution
lane:

```sh
zig build aarch64-hash-qemu-audit
zig build aarch64-hash-qemu
```

The lane internally builds static Debug `aarch64-linux-musl` root tests,
ordinary-manifest tests, and the C and Zig target-default hash fixtures, then
runs all four artifacts with `qemu-aarch64 -cpu max` and compares the exact
trace on the host. Its report binds runtime QEMU/Zig, target/source, artifact,
and trace identities and states
`certification=false physical_machine_proof=false backlog_closed=false`. The
audit requires no QEMU and mutation-tests both this wiring and the absence of
certification hooks. Neither command reads or writes raw-v1 evidence,
provenance, import, review, or certification state, and neither can close
ZL-202. The physical non-emulated workflow remains the sequence below.

Prepare the immutable runner identity/inventory record, then use
`python3 -B scripts/aarch64_hash_evidence.py runner-provenance-create` with the
actual record, its absolute URI, runner ID, hardware model, recorder, explicit
`--claim-physical-non-emulated`, and a durable output as described in
[`evidence/README.md`](evidence/README.md). The flag records an operator claim;
it does not prove physical hardware. Validate the exact byte binding locally:

```sh
zig build aarch64-hash-runner-preflight \
  -Daarch64-provenance=/durable/path/runner-provenance.json \
  -Daarch64-runner-record=/durable/path/runner-record.json
```

That pre-run attachment is not the certification log: it must already exist
before its digest can be embedded in the raw record. On the recorded AArch64
machine, capture the complete command log while using the native target query
and Debug mode, with no target override:

```sh
set -o pipefail
zig build aarch64-hash-certify -Doptimize=Debug \
  -Daarch64-evidence-out=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-provenance=/durable/path/runner-provenance.json \
  -Daarch64-runner-record=/durable/path/runner-record.json 2>&1 \
  | tee /durable/path/zlay-aarch64-hash-certification.log
```

Certification is deliberately Debug-only and requires all three
`-Daarch64-evidence-out`, `-Daarch64-provenance`, and
`-Daarch64-runner-record` options. Before certification artifacts compile, it
creates a cache-managed `zlay.aarch64-runner-preflight.v1` from the exact
runner-record bytes and canonical provenance. The preflight and fresh source
snapshot may be replaced between invocations, but their generated bytes are
immutable inputs within one certification DAG. Every compilation depends on
both, and final capture consumes only that DAG's preflight, not the mutable
original paths. The source snapshot also verifies live `build.zig`
against the digest embedded in the compiled build runner and records every
certification input. Every certification artifact compilation depends on that
snapshot; final capture requires the live inputs to match it exactly. The raw
record binds `runner_record`, `runner_preflight_sha256`, the passed
`runner_record_preflight` gate, `pre_gate_snapshot_sha256`, and the passed
`pre_gate_source_snapshot` gate. The
compiled Zig host guard then queries `uname` without depending on PATH, and the
header gate precedes fresh certification-only manifest, native-test, and C/Zig
oracle executions. The raw record captures the exact native-host guard line and
its digest. Those runs are marked `has_side_effects` so cached success cannot be
presented as a new certification, and a mutation audit protects both pre-gate
dependency graphs and the preflight-only capture input. Only the final capture
step writes, atomically and without
overwrite, after all gates pass; it fsyncs the file and parent directory.
Outputs beneath Zig cache/output or system temporary directories are rejected.

Validate and then import the raw record on any review host. Exact-byte
repository import is required for ZL-202 closure and preserves the validated
source bytes exactly:

```sh
zig build aarch64-hash-evidence-validate \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json
zig build aarch64-hash-evidence-import \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-import-out=evidence/zl-202-aarch64-hash-evidence.json
```

Validation rebinds the record to the current certification source inputs,
checks the exact traces, and structurally validates the recorded executable,
toolchain, target, runner, external-provenance, runner-record, and preflight
fields. It does not replay or authenticate those recorded claims. Import also
refuses overwrite. Both raw and imported v1 records remain pending and
explicitly non-closing.

After the capture log is complete, validate the exact pre-run runner record,
prepare the separate human review statement documented in
[`evidence/README.md`](evidence/README.md), and create and validate a new receipt:

```sh
zig build aarch64-hash-runner-record-validate \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-runner-record=/durable/path/runner-record.json
zig build aarch64-hash-review-receipt \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-runner-record=/durable/path/runner-record.json \
  -Daarch64-certification-log=/durable/path/zlay-aarch64-hash-certification.log \
  -Daarch64-review-statement=/durable/path/review-statement.json \
  -Daarch64-review-out=/durable/path/zlay-aarch64-hash-review-receipt.json
zig build aarch64-hash-review-validate \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-runner-record=/durable/path/runner-record.json \
  -Daarch64-certification-log=/durable/path/zlay-aarch64-hash-certification.log \
  -Daarch64-review-receipt=/durable/path/zlay-aarch64-hash-review-receipt.json
```

The log must contain the raw record's exact
`runner-provenance-valid preflight_sha256=... provenance_sha256=...
runner_record_sha256=... runner_record_byte_count=...
physical_machine_proof=false backlog_closed=false` marker, native-host guard
trace, and exact `evidence-captured sha256=...` pending/non-closing marker. The
human review timestamp cannot predate raw generation. The non-overwriting
`zlay.aarch64-hash-review-receipt.v1` binds the raw bytes, runner record, log,
current review contract, and human attestations. It records an accepted human
review; it does not authenticate the reviewer, machine-verify physical
hardware, or automatically close ZL-202. Explicit maintainer closure is still
required. No real imported raw record, runner record, completed log, or receipt
exists yet; ZL-202 is externally blocked on the physical runner and artifact
set, not on a known code failure.

Evidence/review JSON and attachment inputs are capped at 16 MiB. Review times
must be ordered after raw generation and no more than five minutes ahead of the
validation host. Durable outputs reject Zig caches and standard system
temporary/runtime roots.

For a public-surface change, run `zig build public-api-audit` and update the
checked-in manifest only after reconciling the pinned declaration with an
explicit native mapping. New ordinary C/Zig fixture pairs must add a reviewed
identity, line count, byte count, and SHA-256 entry to
`tests/oracle/ordinary_manifest.zig`. Serialize every observable `f32` and
color channel as its exact IEEE-754 bits; rounded decimal tolerances are not an
accepted parity contract. Unexpected diagnostics and fixed-log overflow must
fail the fixture unless the diagnostic is intentionally serialized as expected
output.

Public `String` hash changes must preserve the ZL-204 safety boundary: every
byte-reading path goes through `String.asSlice()`, so nonpositive lengths are
empty and positive overlong lengths clamp to `chars.len`. Run `zig test
src/hash.zig` in Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall, then run
`zig build test` for the public `Context` ID entry-point regression; valid-input
oracle vectors must remain unchanged. Constructor changes must also keep
`String` and `StringSlice` metadata bounded to `maxInt(i32)` for oversized
native slices in every optimization mode.

Declaration or command-capacity changes must preserve the native safety
contracts: duplicate debug bookkeeping is reserved before tree/text mutation;
scoped cleanup allocation failure aborts the current frame and takes precedence
over the callback error; pointer mutation fires no callbacks or partial update
on OOM; late frame OOM preserves committed hit, query, and retained-exit state;
callback queries cannot expose mutable pointer-over or live scroll aliases;
callback-time command queries cannot mutate the validated live stream;
duplicate-ID retained snapshots keep the first declaration; cache reservation
totals are checked; malformed-forest errors do not alter dimensions;
non-finite/non-progressing layout distribution terminates; invalid/non-positive
frame time and stored scroll state cannot create persistent non-finite momentum;
transition/inspector float-to-integer conversion is bounded; and `endLayout`
never exposes an unbalanced scissor/overlay prefix,
including through checked context access after rejection. Keep the render-scope
C/Zig digest pair in `check_capacity_divergences.zig` current when that
reviewed behavior changes.

Run a focused source test while iterating:

```sh
zig test src/types.zig
```

Do not commit `.zig-cache`, `zig-cache`, or `zig-out` artifacts.

## Porting rules

1. Treat the pinned `clay.h`, not README prose or a third-party port, as the
   behavioral oracle.
2. Preserve integer widths, `f32` operation order, command ordering, ID hashing,
   lifecycle timing, and capacity/error behavior unless a deviation is recorded
   in `docs/PARITY.md`.
3. Keep the production module native Zig: no `@cImport`, translated C object,
   linked Clay archive, or FFI fallback.
4. Use other language rewrites to understand intent, never as authority when
   they conflict with the pinned header.
5. Add the smallest deterministic test that would catch a regression. Prefer a
   differential fixture when the C oracle can express the same case.
6. Update `BACKLOG.md`, `BACKLOG_ARCHIVE.md`, `CHANGELOG.md`, and the parity
   matrix in the same change as the implementation.

The pinned header under `tests/oracle/` is test-only. Production `src/` code
must remain compilable without libc or Clay C objects, including for the
WebAssembly compile target.

## Commit scope

Keep changes aligned to one subsystem from the upstream source map. If a port
intentionally improves the Zig-facing API, put the ergonomic wrapper above the
canonical primitive rather than changing the primitive's behavior.
