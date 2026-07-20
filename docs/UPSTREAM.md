# Upstream reference

ZLAY is a native Zig port of [Clay](https://github.com/nicbarker/clay),
the renderer-agnostic UI layout library by Nic Barker. This document fixes the
source baseline used for implementation and parity work. Moving the baseline is
a deliberate migration, not an incidental update to `main`.

## Normative baseline

| Field | Pinned value |
| --- | --- |
| Repository | [`nicbarker/clay`](https://github.com/nicbarker/clay) |
| Repository commit | [`e6cc36941ab2af5d81107617039d6f527a1c660b`](https://github.com/nicbarker/clay/commit/e6cc36941ab2af5d81107617039d6f527a1c660b) |
| Commit date | 2026-05-20 |
| Canonical source | [`clay.h` at the pinned commit](https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h) |
| `clay.h` SHA-256 | `54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728` |
| `clay.h` size | 303,701 bytes |
| `clay.h` lines | 5,058 physical lines; 4,621 code LOC as reported by GitHub |
| Header version comment | `0.14` |
| Latest tagged release | [`v0.14`](https://github.com/nicbarker/clay/releases/tag/v0.14), commit [`b25a31c1a152915cd7dd6796e6592273e5a10aac`](https://github.com/nicbarker/clay/commit/b25a31c1a152915cd7dd6796e6592273e5a10aac), 2025-06-06 |

The pinned HEAD commit updates only official Odin binding artifacts. Its parent,
[`139802baaa144c3a674db72efc25685f68fe391f`](https://github.com/nicbarker/clay/commit/139802baaa144c3a674db72efc25685f68fe391f),
is the latest core commit at that repository state. Pinning the repository HEAD
rather than only that parent also fixes the examples and official bindings used
for reference.

The `v0.14` tag is not the ZLAY implementation target. At the pinned state the
release page reports 99 commits on `main` since `v0.14`; tagged `clay.h` is 4,393
lines / 3,997 code LOC, while the pinned source includes the newer transition
API and subsequent fixes. The unchanged `// VERSION: 0.14` header comment is
therefore not a sufficient source identifier. ZLAY records the full commit and
file digest.

## Authority order

When upstream sources disagree, use this order:

1. The exact pinned `clay.h` behavior and declarations.
2. Examples and renderer code from the same pinned repository tree.
3. The [pinned README](https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/README.md) for design intent and usage guidance.
4. The [official website](https://www.nicbarker.com/clay) for visual and product-level intent.
5. The `v0.14` release notes for migration history, not current-main API truth.

External language rewrites are useful implementation commentary, but they are
not parity authorities. They may target older Clay revisions, omit features, or
make language-specific behavior changes.

## Canonical source map

The implementation is a single header. These ranges are the audit map for the
pinned file:

| Upstream lines | Responsibility |
| --- | --- |
| 1-193 | Includes, build flags, public helper macros, ID/string macros, and declarative element macros |
| 194-927 | Public strings, arena, geometry, configuration, transition, render, pointer, and error types |
| 928-1051 | Public function declarations and the internal functions required by the macros |
| 1052-1389 | Implementation setup, bounded-array machinery, internal records, and `Clay_Context` |
| 1390-1779 | String helpers, element-ID hashing, SIMD/scalar data hashing, and text measurement cache |
| 1780-2219 | Element hash map and open/configure/close tree construction |
| 2220-2266 | Ephemeral and persistent arena initialization |
| 2267-2514 | Axis sizing algorithm |
| 2515-3195 | Text wrapping, aspect-ratio propagation, position calculation, z sorting, culling, and render-command generation |
| 3196-3229 | Pointer-over result access |
| 3230-3954 | Built-in debug inspector |
| 3955-4023 | Arena and array support functions |
| 4024-4354 | Public memory, initialization, context, pointer, and scrolling lifecycle |
| 4355-4373 | `Clay_BeginLayout` |
| 4374-4818 | Retained exit-transition trees, transition application, and `Clay_EndLayout` |
| 4819-5058 | Remaining query/configuration APIs and `Clay_EaseOut` |

## Native port map

This map is the line-range accountability record for the rewrite. It names the
native implementation that owns each canonical range; `PARITY.md` remains the
authority for whether the current proof is differential, native-only, or an
intentional Zig divergence.

| Upstream lines | Native implementation | Current boundary |
| --- | --- | --- |
| 1-193 | `src/root.zig`, `src/types.zig`, and the combined/split/scoped methods in `src/context.zig` | Macros become typed helpers and methods; declaration evaluation order is tested. |
| 194-927 | `src/types.zig`, `src/transition.zig`, root aliases, and the parsed public manifest/facade ledger | The complete named declaration inventory and exhaustive enum/default/helper values are mechanically checked; no C ABI promise. Oversized native slice metadata clamps to signed public range and out-of-range border-width conversion is deterministic. |
| 928-1051 | `src/context.zig`, `src/root.zig`, and `src/facade_tests.zig` | Public callable surface is mapped; arena/current-context calls are documented divergences. |
| 1052-1389 | `src/context.zig`, `src/layout.zig`, `src/text.zig`, `src/scroll.zig`, and `src/transition.zig` | Internal state is allocator-owned instead of arena-partitioned. |
| 1390-1779 | `src/hash.zig` and `src/text.zig` | Scalar/target-default hashes, wrapping inputs, capacity boundaries, stale-generation pruning, measured-word/cache-item free-list reuse, and runtime 96-to-64-to-96 active bucket topology are executable. The target-default oracle has exact x86-64/AArch64 manifest contracts plus focused host, cross-compile, supplemental QEMU, and native-certification lanes. The opt-in QEMU lane runs internally pinned static Debug `aarch64-linux-musl` root tests, manifest tests, and the exact C/Zig trace with `qemu-aarch64 -cpu max`; its bound runtime identities and host-only mutation audit remain explicitly non-certifying. Provenance can be created non-overwriting from the actual runner-record bytes and locally validated. Debug-only certification requires evidence/provenance/record paths and, before compilation, creates a cache-managed `zlay.aarch64-runner-preflight.v1` that binds canonical provenance plus the record URI/SHA-256/byte count; all artifact compiles depend on it and final capture consumes only it. Raw-v1 binds that runner record/preflight digest/passed gate plus the fresh native-host guard and `pre_gate_snapshot_sha256`/`pre_gate_source_snapshot`; the source snapshot verifies live `build.zig` against a build-embedded digest before every dependent certification artifact compile, and capture requires exact live-input equality. Both fresh Zig test stderr logs are strict-validated and embedded with their complete bytes, counts, skip names, byte counts, and SHA-256 digests; only the pinned x86-64-only native skip is allowed and manifest skips are forbidden. Evidence/build-DAG mutation audits, file-and-parent-fsynced capture, exact-byte import, and any-host validation remain pending/non-closing. A separate mutation-tested workflow binds the actual pre-run runner record, completed log's exact runner-preflight/native-host/capture markers, and human statement into a non-overwriting review receipt. No real raw record, runner record, completed log, or receipt exists; physical-runner execution, accepted human review, and explicit maintainer closure remain open. |
| 1780-2219 | ID maps and declaration lifecycle in `src/context.zig` | Exact ID/error/collision fixtures plus reviewed duplicate-ID behavior; duplicate debug bookkeeping and diagnostics are allocation-preflighted before combined, split, or text effects, retained exit/state/hit lookup preserves the first declaration, and exact clip/floating node ancestry disambiguates visible duplicate subtrees. |
| 2220-2266 | `Context.init`, `deinit`, and retained-capacity collections | Intentional allocator/arena divergence; fixed-buffer, OOM rollback, scoped-cleanup frame abort, and signed public-capacity clamps are tested. |
| 2267-2514 | `src/layout.zig` plus sizing orchestration in `src/context.zig` | Basic, complex, dense constrained-sizing, 122-line declaration/layout, and 11-line bidirectional-aspect/horizontal-scroll fixtures match; native regressions cover ordinary percent-height parents and aspect-plus-percent union propagation without inactive Zig union access; invalid non-finite/non-progressing distribution terminates safely. |
| 2515-3195 | `src/text.zig`, `src/geometry.zig`, and iterative command emission in `src/context.zig` | Dense text/render/culling fixtures compare every engine-emitted command kind across the suite and the active payloads they serialize; a reviewed capacity pair pins C's unbalanced scoped prefix against ZLAY's checked frame rejection, callback command queries use detached scratch, text/output capacity precedes measurement callbacks, and exact node ancestry keeps duplicate/negative-z clipping and attachment coherent. |
| 3196-3229 | Pointer array/query methods in `src/context.zig` | Core and 81-pair floating/pointer edge fixtures match, including array metadata, clipping, external scroll, z order, capture, and boundary behavior; checked command-array access remains a separate reviewed divergence. |
| 3230-3954 | `src/debug.zig`, inspector declaration helpers in `src/context.zig`, and `src/debug_inspector_tests.zig` | Native multiframe proof and a byte-identical 733-line compiled-C trace cover interaction, every selected configuration branch, active payloads, injected warning storage, and phase ordering; invalid native coordinates and numeric values are conversion-safe. |
| 3955-4023 | Native collections and bounds checks across `src/types.zig` and `src/context.zig` | Exact ceilings and nullable access replace C sentinel/default-object flow. |
| 4024-4354 | `src/context.zig` and `src/scroll.zig` | Lifecycle plus vertical/horizontal and external/nested scrolling match; a 72-line retained/two-context trace normalizes explicit instances and pins process-global-C versus per-context-Zig ownership for measurement and external-scroll-query callbacks plus debug settings, while the stale replacement pointer, zero-time release division, and persistent non-finite stored momentum are intentionally fixed. |
| 4355-4373 | `Context.beginLayout` | Root setup, generation, warning reset, and inspector width are native-tested and fixture-covered through frames. |
| 4374-4818 | `src/context.zig`, `src/transition.zig`, and `src/exit_transition_tests.zig` | Core, 322-line combination, and 100-line lifecycle traces match across observable properties, triggers, handler pruning/restoration, disappearance/reappearance, repeated reparenting, nested exiting-tree removal, retained text, callback order, completion timing, and interaction policy. |
| 4819-5058 | Public query/configuration methods in `src/context.zig` and `easeOut` in `src/transition.zig` | Callable mapping is implemented; configuration/diagnostics and retained queries have exact fixtures, `Clay_EaseOut` has a direct 78-case bitwise comparison, and a 6-line reviewed trace pins checked no-open API behavior plus exact recovery. |

For the hashing boundary, ZL-204 preserves every valid pinned result while
hardening malformed native `String` metadata: all byte-reading hash paths use
`String.asSlice()`, so nonpositive lengths are empty and positive overlong
lengths clamp to the available bytes. The certification runner preflight and
source snapshot are replaceable between invocations but immutable inputs within
one certification DAG. Compilation still reads the live checkout, so final
equality detects persistent drift but not an adversarial change-and-restore or
independent source-to-binary binding. Contributors can reproduce the separate
emulator rung with `zig build aarch64-hash-qemu` when optional `qemu-aarch64` tooling is
available and can always run its host-only source contract with
`zig build aarch64-hash-qemu-audit`. The runtime report binds QEMU/Zig, source, artifact,
target, and trace identities but fixes `certification=false`,
`physical_machine_proof=false`, and `backlog_closed=false`; it has no raw-v1,
provenance, import, review, or certification integration. ZL-202 closure
additionally requires exact-byte repository import of the validated raw record;
the physical non-emulated AArch64 run and artifact set remain externally
unavailable in this checkout.

The upstream tree also contains 26 binding files, 112 example files, 20
renderer files, and 3 files under `tests/`. The upstream test directory is a
GCC 9.4/CMake build smoke; it is not a behavioral test suite. ZLAY must supply
its own behavioral and differential evidence.

The official `bindings/zig/README` contains only links to external C bindings.
It is not a native Zig implementation and is not used by ZLAY at runtime.

`src/renderer.zig` and `src/profile.zig` are native downstream additions rather
than ports of a `clay.h` source range. They dispatch the renderer-neutral output
contract and profile the intentional allocator-model replacement; neither is
used to claim equivalence with an upstream renderer or `Clay_MinMemorySize`.

## Header versus README differences

The pinned README contains stale API details. These differences are recorded so
the port does not accidentally implement prose that disagrees with the source:

| Subject | Pinned `clay.h` | README or other upstream prose | ZLAY rule |
| --- | --- | --- | --- |
| End-layout signature | `Clay_EndLayout(float deltaTime)` | API section shows `Clay_EndLayout()` | Accept and apply `deltaTime`; source is normative. |
| Open-element ID result | `Clay_GetOpenElementId()` returns `uint32_t` | API section says `Clay_ElementId` | Preserve the source result semantics in the parity layer. |
| External scroll switch | `Clay_SetExternalScrollHandlingEnabled(bool)` is implemented at line 4922 | It has no public forward declaration and is not documented with the main public API | Track it as an upstream implementation-only public symbol and port its behavior explicitly. |
| WASM layout-dimension export | `Clay_GetLayoutDimensions` is annotated with export name `"Clay_SetLayoutDimensions"` | No warning in README | Treat this as an upstream export annotation defect; do not reproduce the duplicate name in an idiomatic native Zig API. |
| Culling control | Runtime `Clay_SetCullingEnabled(bool)` | README still mentions `CLAY_DISABLE_CULLING` | Implement the runtime API. The obsolete define is not in the pinned header. |
| Version identity | Header comment remains `0.14` | Latest release is also called `0.14` | Use commit plus SHA-256, never the version comment alone. |

Any intentional correction belongs in the Zig-facing convenience layer and
must remain distinguishable from source-parity behavior.

## Upstream architecture constraints

The following properties are part of the target, not optional optimizations:

- Core operation uses caller-owned arena memory and performs no `malloc` or
  `free`.
- Default limits are 8,192 layout elements and 16,384 cached measured words.
- Persistent data and per-layout ephemeral data share the arena but have
  different reset lifetimes.
- Element IDs and text cache keys have defined hash behavior; ID results must be
  exact.
- Strings are counted slices and are not guaranteed to be null terminated.
  Dynamic ID backing storage must remain valid for the lifetime required by
  Clay.
- Layout is constructed immediately through open/configure/close operations,
  then resolved in sizing, wrapping, positioning, and command-generation
  passes.
- Render output is renderer agnostic and already sorted in drawing order.
- Pointer overlap and internally managed scroll state depend on retained data
  from prior frames.
- Multiple contexts are supported through a global current-context pointer.
  Upstream does not support concurrent rendering from multiple threads.
- Transition exit behavior retains and clones prior-frame subtrees. It cannot be
  reduced to interpolation of only the current frame's element.

ZLAY production code is native Zig. It must not use `@cImport`, link Clay's C
implementation, or dispatch layout work to generated bindings. The pinned C
header may be compiled only as a test oracle for differential verification.

## License and attribution

Clay uses the [zlib/libpng license](https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/LICENSE.md),
copyright 2024 Nic Barker. It permits use, alteration, and redistribution,
including commercially, subject to three relevant conditions:

- Do not misrepresent the origin of the original software.
- Plainly mark altered source versions.
- Do not remove or alter the upstream notice.

ZLAY is an altered, independently maintained native Zig port. The repository's
license and notice files must retain upstream attribution and must not claim
that ZLAY is the original Clay implementation.

## Updating the pin

An upstream update is complete only when all of the following move together:

1. The full commit, file digest, sizes, and source map in this document.
2. The type, function, and feature matrices in `PARITY.md`.
3. Differential fixtures for changed behavior.
4. ZLAY implementation and public API documentation.
5. Changelog and backlog truth.

Until that work lands and passes, the commit above remains the only normative
baseline.
