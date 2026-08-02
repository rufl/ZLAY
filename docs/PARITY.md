# Clay parity contract

This document defines what “fully rewritten in native Zig” means for ZLAY and
records the current evidence boundary. The target is the exact `clay.h` pinned
in [`UPSTREAM.md`](UPSTREAM.md), not a general resemblance to a Clay release or
to a third-party binding.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| Not implemented | The upstream behavior is absent. |
| Native verified | Native Zig tests exercise the behavior, but the required pinned-C comparisons are incomplete. |
| Partially differential | One or more compiled pinned-C fixtures match exactly, but the full fixture group is not covered. |
| Differentially verified | The required pinned-C fixture group and native-only safety tests pass. |
| Intentional Zig divergence | The Zig API deliberately differs and the difference is documented; it is not claimed as source parity. |
| Native verified plus reviewed divergence | Native behavior is tested and both sides of a deliberate non-equal C/Zig trace are digest-pinned. |
| Differentially verified plus reviewed divergence | Matching fixtures cover the required ordinary cases and digest-pinned traces cover deliberate non-equal edge behavior. |

Compilation, an example renderer, or a screenshot alone does not establish
behavioral parity. A status applies only to the row and cases described.

## Current implementation snapshot

Status as of 2026-07-15: **host/pinned-source parity contract complete; the
recorded AArch64 target extension is externally blocked in this checkout on
real physical execution, its artifact set, and explicit maintainer closure**.

ZLAY implements an allocator-owned, C-free `Context`, target-compatible ID and
text-cache hashing, flat declarative hierarchy construction, both layout axes, all sizing
modes, text measurement and wrapping, aspect ratio propagation, floating roots,
renderer-neutral commands, pointer hit testing, internal/external scrolling,
enter/change/retained-exit transitions, and a live native inspector. The split
declaration primitives preserve Clay macro evaluation order. Height propagation
is linear in nodes plus edges and has deep-chain and wide-tree regression
coverage; render traversal is iterative with deep-chain coverage.
ZL-204 makes malformed public `String` metadata safe at every byte-reading hash
boundary. The current native boundary also clamps oversized slice-constructor
metadata, invalid transition/scroll time, border-width extrapolation, and
inspector float-to-integer inputs without changing ordinary pinned results.
The 2026-07-15 audit additionally repaired percent-height/aspect union handling
in safety builds and made runtime text-cache word-limit changes update the
active hash topology exactly for the defined upstream range.

`zig build verify` checks the pinned header digest and runs compiled-C basic and
complex layout, sizing/text, string/callback/cache lifecycle, render,
ID/error/collision, normalized-capacity, direct ease-out/default-hash, focused
audit regression, dense transition and transition lifecycle, pointer/hover,
81-pair floating attachment, vertical and horizontal scroll, external/nested
scroll, and live inspector fixtures. It also runs the C-free native gate and
executes the same renderer smoke natively and in `wasm32-freestanding` through
Node. Those fixtures establish exact parity for their serialized fields and
inputs. All 25 ordinary trace identities are fail-closed on
identity/count/SHA-256 with bit-exact observable floats; the target-default hash
identity selects separate reviewed x86-64 and AArch64 contracts. Manifest
self-tests run in the build, and the parsed public manifest fails if a supported
declaration is omitted from the facade mapping. The Debug-only raw AArch64
execution-record contract is build-tested against source, trace, target,
captured native-host guard, runner, provenance/preflight bindings, review-state,
and overwrite/cache-path mutations. Non-overwriting provenance creation reads
the actual runner-record bytes, and a local runner-preflight step validates that
binding. Before any certification artifact compiles, a cache-managed
`zlay.aarch64-runner-preflight.v1` binds the canonical provenance digest and
record URI/SHA-256/byte count; every compilation depends on it and capture
consumes only that preflight. A fresh pre-gate input snapshot checks live
`build.zig` against a build-embedded SHA-256, gates every certification artifact
compile, and must still match all live inputs at capture. Separate mutation
audits protect that snapshot/build DAG and the any-host
runner-record/log/human-review receipt workflow.
The artifacts compile from the live checkout, so these checks detect ordinary
persistent drift but do not independently bind a binary to immutable staged
source or exclude an adversarial change-and-restore between checks.

An opt-in `aarch64-hash-qemu` lane separately executes internally pinned static
Debug `aarch64-linux-musl` root tests, manifest tests, and the exact C/Zig
target-default trace through `qemu-aarch64 -cpu max`. Its host-only
`aarch64-hash-qemu-audit` mutation-tests the lane without requiring QEMU. The
runtime report binds tool, target/source, artifact, and trace identities and
sets `certification=false physical_machine_proof=false backlog_closed=false`.
This supplemental result is isolated from every raw-v1, provenance, import,
review, and certification path.

The gate separately pins both sides of reviewed scroll replacement,
duplicate-ID lookup, invalid command access, element-capacity, text-capacity,
render-scope capacity, malformed-stack, floating-plus-clip, invalid
wrapped-slice, retained/two-context, and no-open API traces whose differences
are intentional. Render-capacity metadata and its effective final-slot limit
compare exactly; a separate pair pins C's unbalanced overflow prefix against
ZLAY's checked frame rejection.

The debug inspector has a 733-line exact trace across command output, phase
ordering, every emitted selected configuration pane, injected warning storage,
scrolling, selection, highlight, collapse, close, and width restoration.
Floating/pointer and transition behavior have dense exact matrices, and
`Clay_EaseOut` has a direct 78-case bitwise grid. Clay's
exact caller-partitioned arena and `Clay_MinMemorySize` are intentionally
replaced by a supplied `std.mem.Allocator`. The audit found no remaining open
host behavioral or proof-integrity row. Real AArch64 execution of the
target-default hash oracle is the sole open evidence item in `BACKLOG.md`.

## Public surface status

Native structs are not required to match C ABI sizes or calling conventions.
Numeric semantics, callback timing, command order, and observable geometry must
match unless an intentional divergence is recorded.

| Surface | Current status | Evidence boundary |
| --- | --- | --- |
| Strings and slices | Differentially verified plus native malformed-input safety | A 110-line callback/cache trace covers valid empty, static, dynamic, and derived values; bytes, lengths, static metadata, base relationships, whitespace/newline edges, and retained-exit lifetime. Native regressions prove nonpositive public `String.length` values expose no bytes, positive overlong values clamp to `chars.len`, and slice constructors clamp metadata above `maxInt(i32)`. |
| ID hashing and `ElementId` fields | Differentially verified plus reviewed divergence | Target-aware high-bit bytes, global/indexed/local/automatic fields, full valid string metadata, distinct bucket collisions, fresh/missing queries, and diagnostics match; malformed public lengths are clamped before every byte-reading hash path, while duplicate query contamination is separately digest-pinned. |
| Geometry, layout, text, floating, clip, border, transition, pointer, error, and declaration types | Differentially verified at the value surface | The parsed manifest covers all 45 aggregate/opaque types and 19 enums; a 174-line bitwise fixture covers all 86 enum values, transition masks, public zero/default structs, helpers, ID metadata, and globals. Subsystem behavior is classified separately below. |
| Render command types, arrays, and active union payloads | Differentially verified plus reviewed divergence | Fixtures compare every engine-emitted kind across the suite, normalized opaque payloads, active payloads, scope control, culling, and exact capacity; invalid access is a reviewed nullable-access divergence, and capacity-truncated scope rejection is separately digest-pinned. |
| `Arena` source-model type | Intentional Zig divergence | Public model coverage exists, but `Context` does not allocate through Clay's arena partitions. |
| Explicit allocator-owned `Context` | Intentional Zig divergence with differential normalization | A 72-line retained/context trace compares two C current-context instances with two explicit Zig instances, requiring exact normalized retained, pointer, hover, scroll, query, prune, recovery, callback-owner, and debug-setting records. It pins C's process-global measurement and external-scroll-query functions plus retained per-context data against ZLAY's context-owned function/data pairs, and C's shared debug globals against ZLAY's per-context settings. There is no process-global Zig pointer or C ABI. |

## Public function mapping

| Pinned Clay operation | Native Zig operation | Current status |
| --- | --- | --- |
| `Clay_MinMemorySize` | No byte-exact equivalent | Intentional Zig divergence |
| `Clay_CreateArenaWithCapacityAndMemory` | `Arena` descriptor helper; not the `Context` allocator | Intentional Zig divergence |
| `Clay_Initialize` | `Context.init(allocator, dimensions, options)` | Intentional Zig divergence; lifecycle native verified |
| `Clay_GetCurrentContext` / `Clay_SetCurrentContext` | Pass an explicit `*Context` | Intentional Zig divergence; 72-line retained lifecycle/ownership trace normalized and digest-pinned |
| `Clay_SetPointerState` / `Clay_GetPointerState` | `setPointerState` / `getPointerState` | Differentially verified |
| `Clay_UpdateScrollContainers` / `Clay_GetScrollOffset` | `updateScrollContainers`, `getScrollOffset`, `getScrollOffsetFor` | Differentially verified plus reviewed divergence |
| `Clay_SetLayoutDimensions` / `Clay_GetLayoutDimensions` | `setLayoutDimensions` / `getLayoutDimensions` | Differentially verified |
| `Clay_BeginLayout` / `Clay_EndLayout(float)` | `beginLayout` / `endLayout(delta_time)` | Differentially verified plus reviewed divergence |
| `Clay_GetOpenElementId` | `getOpenElementId` | Differentially verified plus reviewed no-open divergence |
| `Clay_GetElementId` / `Clay_GetElementIdWithIndex` | `getElementId(String)`, `getElementIdWithIndex(String, u32)`; slice/comptime helpers are additions | Differentially verified |
| `Clay_GetElementData` | `getElementData` | Differentially verified plus reviewed divergence |
| `Clay_Hovered`, `Clay_OnHover`, `Clay_PointerOver`, `Clay_GetPointerOverIds` | `hovered`, `onHover`, `pointerOver`, `getPointerOverIds` | Differentially verified plus reviewed no-open divergence |
| `Clay_GetScrollContainerData` | `getScrollContainerData` | Differentially verified plus reviewed divergence |
| `Clay_SetMeasureTextFunction` | `setMeasureTextFunction` | Differentially verified plus reviewed two-context ownership divergence |
| `Clay_SetQueryScrollOffsetFunction` | `setQueryScrollOffsetFunction` | Differentially verified plus reviewed two-context ownership divergence |
| `Clay_RenderCommandArray_Get` | `RenderCommandArray.get` / `renderCommand` | Differentially verified plus reviewed divergence |
| `Clay_SetDebugModeEnabled` / `Clay_IsDebugModeEnabled` | Same native spelling | Differentially verified |
| `Clay_SetCullingEnabled` | `setCullingEnabled` | Differentially verified |
| `Clay_GetMaxElementCount` / `Clay_SetMaxElementCount` | Same native spelling | Differentially verified plus reviewed divergence |
| `Clay_GetMaxMeasureTextCacheWordCount` / `Clay_SetMaxMeasureTextCacheWordCount` | Same native spelling | Differentially verified plus reviewed divergence |
| `Clay_ResetMeasureTextCache` | `resetMeasureTextCache` | Differentially verified |
| `Clay_EaseOut` | `easeOut` | Differentially verified |
| `Clay_SetExternalScrollHandlingEnabled` | `setExternalScrollHandlingEnabled` | Differentially verified |

The C macro support lifecycle is present as both combined and split primitives:

| C macro-support operation | Native Zig operation | Current status |
| --- | --- | --- |
| `Clay__OpenElement` | `openElement`, `openElementUnconfigured` | Differentially verified |
| `Clay__OpenElementWithId` | `openElementWithId`, `openElementWithIdUnconfigured` | Differentially verified |
| `Clay__ConfigureOpenElement` / `Ptr` | `configureOpenElement` | Differentially verified |
| `Clay__CloseElement` | `closeElement` | Differentially verified plus reviewed divergence |
| `Clay__HashString` / `Clay__HashStringWithOffset` | Native hash functions and ID helpers | Differentially verified |
| `Clay__OpenTextElement` | `text` / `textSlice` | Differentially verified plus reviewed divergence |

`element` and `elementWithId` are Zig-only scoped wrappers over the combined
open/close primitives. They restore the open stack when a body callback fails;
they do not change the canonical declaration-order semantics. If closing during
that restoration fails, the cleanup error takes precedence and the current
frame is aborted allocation-free so no stale open stack survives.

`elementDeferred` and `elementWithIdDeferred` are scoped wrappers over the
split primitives. Their fallible declaration factory runs after the new element
is open, so query-sensitive construction retains Clay's evaluation order.

## Native divergences and review state

These differences are deliberate Zig API/ownership decisions. They are not
counted as C behavior parity, even where they make failure handling safer. A
behavioral row is not “reviewed” until both non-equal traces are executable.

| Surface | Pinned C behavior | Native ZLAY behavior | Review state |
| --- | --- | --- | --- |
| Allocation and context selection | Caller-partitioned arena, `Clay_MinMemorySize`, and a process-global current-context pointer | Caller-supplied `std.mem.Allocator`, explicit `*Context`, and independent contexts | Structural API divergence |
| Callback and debug-setting ownership | Measurement/query functions and debug width/color are process-global; callback user data remains per context | Each `Context` owns both callback function/data pairs and its debug width/color | Exact 72-line two-context trace with digest-pinned owner records |
| Capacity failure flow | Element overflow poisons the frame; text-cache exhaustion substitutes default measurement and continues | Fallible mutations report once, return a Zig error where applicable, and preserve retryable tree state | Digest-pinned |
| Render scope capacity | Command insertion can omit a closing scissor or overlay delimiter and return the unbalanced prefix | A balanced shortened prefix may succeed; an unbalanced prefix closes the frame, clears checked command access, and returns `RenderCommandCapacityExceeded` | Digest-pinned: C `7bce37f8...fa5380`, Zig `870aa5b6...0a395` |
| Scoped helper integrity and cleanup failure | No scoped callback wrapper | Helpers require the exact node and parent they opened, clean up a same-depth element replacement, abort on ancestor replacement/underflow, and let cleanup failure win while restoring committed transition/scroll state | Native regressions; Zig-only wrapper |
| Pointer/frame commit allocation failure | Arena storage is fixed before layout and pointer mutation is infallible | Pointer mutation reserves its full hit set before callbacks; frame hit data and exit snapshots are staged, persistent-map mutation is allocation-preflighted, and late OOM preserves the last completed surfaces | Native failure-atomicity regressions |
| Rejected transition/scroll frame | Declaration mutates fixed persistent state directly and callbacks follow upstream timing | `beginLayout` snapshots transition and scroll state; preliminary render plus final layout/render/commit and exact distinct text-cache miss allocation is validated or reserved before transition callbacks, and external scroll queries run only in the infallible commit tail | Native transactional regressions |
| Reentrant application callback mutation | No checked reentrancy contract | Recursive `setPointerState` returns `PointerUpdateAlreadyActive`; other fallible frame/input mutation returns `CallbackReentryNotAllowed`; `void` mutation/destruction is ignored while hover, transition, external-scroll, measurement, or diagnostic callbacks inspect active state; pointer-over views are const, callback-time scroll and command pointers are detached, preborrowed scroll aliases are restored, and the standalone cache independently guards recursive measure/reset/destruction | Native lifecycle regressions |
| Pointer-over query mutability | `Clay_ElementIdArray` exposes mutable element pointers | `ElementIdArray` exposes a read-only slice so callback inspection cannot overwrite live hit IDs | Native compile-time safety divergence |
| Public capacity range | Public capacities and setters are signed `int32_t` | Oversized `usize` options and setter values clamp to `maxInt(i32)` before public metadata conversion | Native regression; structural type-safety divergence |
| Invalid time and numeric conversion | Can divide drag release distance by zero sample time and relies on undefined out-of-range float-to-integer conversion | Context transition time and drag sampling use only positive finite deltas; zero/invalid release time yields zero momentum; stored scroll state is normalized; border widths saturate; inspector rows reject invalid coordinates; non-finite/non-progressing layout distribution terminates | Native safety regressions; valid-input oracle output unchanged |
| Text cache item storage | Persistent cache-item count is bounded by the element arena partition | Cache items are allocator-owned; measured words retain the explicit hard ceiling | Structural ownership divergence |
| Text cache full-hash collision | The compact 32-bit lookup hash is treated as complete identity, so collisions can reuse unrelated metrics and word offsets | The compact hash selects a bucket; safe length/configuration and SHA-256 dynamic content or the complete static pointer determine a hit | Native collision-safety regressions; ordinary oracle output unchanged |
| Checked command access | Invalid C array access reports `internal_error` and returns a default object pointer | `RenderCommandArray.get` and `Context.renderCommand` return `null` without a diagnostic | Digest-pinned |
| Query APIs with no user element open | Before the first frame, C reports internal errors and returns sentinel/default values; after `EndLayout`, it can expose the retained synthetic root as open | Checked Zig accessors return safe defaults or `NoOpenElement`; hover registration fails explicitly | Digest-pinned before first frame, after frame end, and through exact recovery |
| Unbalanced layout end | Closes once before checking; deeper stacks remain malformed | Closes every outstanding user element to restore a valid frame | Digest-pinned at depths 0/1/2/3 with recovery |
| Duplicate-ID state writes | The later duplicate can write through the first hash entry and ID-keyed state | Preserves the first declaration's query bounds, retained exit source, transition configuration, scroll configuration/geometry/query ownership, hover-hit ownership, and transition interaction state; exact node indexes preserve the later duplicate's visual clip/floating ancestry for unique descendants | Digest-pinned bounds plus native retained/transition/scroll/interaction regressions |
| Replaced scroll-container storage | A retained pointer into ephemeral layout storage can alias a replacement and skip an update | ID/value-owned geometry avoids stale aliasing | Digest-pinned |
| Floating plus clipping | Pushes two clip entries and pops one, leaking a stale clip into later declarations | Keeps balanced explicit clip ancestry | Digest-pinned with recovery |
| Invalid wrapped empty line | Can construct a negative string length in the leading-space empty-line edge | Preserves a valid zero-length slice | Digest-pinned numeric metadata; C slice is never dereferenced |
| ABI and union storage | C layouts, calling conventions, and an untagged payload union | Native Zig layouts, callbacks, optionals, slices, and no C ABI guarantee | Structural API divergence |

`ContextError` names the explicit lifecycle/capacity errors declared by the
engine; method inference can additionally include allocator errors such as
`error.OutOfMemory`. Error enum members retained from the source model are not
all emitted by the allocator-owned implementation.

## Feature matrix

| Feature | Current status | Current proof boundary |
| --- | --- | --- |
| Arena and bounded storage | Intentional Zig divergence | Allocator-owned collections, explicit limits, OOM rollback, atomic duplicate bookkeeping, scoped-cleanup frame abort, signed metadata clamps, and fixed-buffer use replace byte-exact upstream partitions and minimum-size arithmetic. |
| IDs and lookup | Differentially verified plus reviewed divergence | Target-aware high-bit vectors, global/indexed/local/automatic IDs, metadata, same-bucket distinct IDs, fresh/missing lookup, and duplicate handling are executable; duplicate bounds contamination is digest-pinned. |
| Declarative hierarchy | Differentially verified plus reviewed safety divergence | Combined and residual fixtures cover split/combined order, IDs, declaration queries, nested axes, and balanced lifecycle; malformed depths 0/1/2/3 and following-frame recovery are digest-pinned. |
| Horizontal and vertical layout | Differentially verified | Basic, complex, dense sizing, and residual fixtures cover mixed/nested directions, padding, gaps, alignment, intrinsic placement, min/max constraints, compression, and resize. |
| FIT/GROW/FIXED/PERCENT sizing | Differentially verified | Dense fixtures cover fixed/percent plus min-only/min-max fit/grow, actual compression, and resize; native tests cover additional axis arithmetic. |
| Text measurement, cache, and wrapping | Differentially verified plus reviewed safety divergence | Wrap modes, callback mutation, spacing, line height, alignment, culling, resize, global line capacity, stale generation pruning, word/item free-list reuse, and a runtime 96-to-64-to-96 cache-topology sequence are executable; below-32 and above-allocation topology changes clamp safely, while the invalid negative-slice edge and recovery are digest-pinned. |
| Aspect ratio | Differentially verified | Responsive width-from-height and height-from-width behavior, the unconditional sizing-union write, and the no-post-scale floating-root rule match. |
| Rectangle, image, custom, and border commands | Differentially verified | The render matrix compares active payloads, normalized opaque data, order, IDs, z, bounds, and between-child output. |
| Clipping and overlays | Differentially verified plus reviewed safety divergence | Dedicated render output covers nested scissors, overlays, and default closing controls; the render-capacity pair pins C's unbalanced prefix and ZLAY's checked rejection. |
| Floating elements | Differentially verified plus reviewed safety divergence | The 225-line matrix plus focused missing-parent/aspect regression match; floating-plus-clipping stack leakage and recovery are digest-pinned. |
| Render ordering and culling | Differentially verified | Two-frame render and sizing fixtures compare z-sorted offscreen inclusion/exclusion and complete covered command order. |
| Pointer interaction | Differentially verified | Core plus 225-line edge traces cover prior-frame state, callback/overlap order, nullable clearing, press/hold/release, inclusive boundaries, clipping/external-scroll bypass, z order, capture/passthrough, and transition policy. |
| Internal and external scrolling | Differentially verified plus reviewed divergence | Vertical and horizontal registration/drag/stationary reset/release/momentum/pruning and a 52-line nested-priority/external-query trace match. The stale replacement-pointer behavior intentionally differs and is digest-pinned; zero/non-finite drag sample time safely produces no release momentum, and non-finite stored state is cleared before advance. |
| Enter/change/exit transitions | Differentially verified plus native numeric safety | Core, dense, and 100-line lifecycle traces plus direct 78-case ease-out proof cover observable properties, triggers, handler pruning/restoration, disappearance/reappearance, repeated reparenting, sibling orders, nested exiting-tree removal, retained text, callbacks, completion, and interaction policies. Negative/non-finite Context deltas normalize to zero and out-of-range border-width extrapolation is bounded. |
| Retained-mode queries and multiple contexts | Differentially verified plus reviewed divergence | A 72-line matrix covers fresh/prior/stale/missing queries, collision/duplicate IDs, two-context switching, retained hover/pointer/scroll state, pruning, recovery, both callback-owner families, and debug-global ownership. In addition to explicit context selection and the separately reviewed duplicate-bounds fix, pinned C uses the most recently installed process-global measurement and external-scroll-query functions with each context's retained user data, while ZLAY retains each function/data pair per `Context`; pinned C shares debug width/color process-wide while ZLAY owns them per context. |
| Debug inspector | Differentially verified for every emitted configuration pane plus native input, narrow-viewport, and opt-in accessibility support | A 733-line bitwise trace covers phase ordering, live interaction, layout/text/color/radius/aspect/image/floating/clip/border panes, custom badge/rendering, injected warning storage, highlight, scrolling, collapse, close, and width restoration. Native probes reject non-finite/out-of-range row coordinates, safely format extreme numeric values, clamp a too-wide panel to the viewport, and shrink its details pane while preserving ordinary geometry. The default theme remains pinned; native additions raise contrast/type/target size, provide transactional renderer-neutral actions with internal reveal scrolling, and expose a read-only committed selection/row summary. |
| Native targets | Host native verified; supplemental AArch64 emulation lane available; physical execution/review open | x86-64 native execution and `wasm32-freestanding` compilation pass; the same 14-command dispatcher frame executes through Node WebAssembly with deterministic output. The exact AArch64 hash contract and native tests cross-compile behind an architecture guard. The optional QEMU lane runs internally pinned static Debug `aarch64-linux-musl` root tests, manifest tests, and exact C/Zig hash output with `qemu-aarch64 -cpu max`; its bound report and audit remain explicitly non-certifying. The separate Debug-only runner-provenance creation/local validation, precompile runner preflight, pre-gate source snapshot, raw capture, exact-byte validation/import, build-DAG audit, and runner/log/human-review receipt contracts are executable, but no real raw record, runner record, completed log, or receipt exists; ZL-202 remains open for physical non-emulated AArch64 proof. Broader OS/browser/graphics-backend coverage is outside the core proof. |

## Current executable evidence

| Gate or fixture | What it proves |
| --- | --- |
| Pinned-header digest checker | `tests/oracle/clay.h` is the exact commit and SHA-256 recorded in `UPSTREAM.md`. |
| Parsed public-API manifest | Exact inventory and explicit native mapping for 45 aggregate/opaque types, 19 enums, 7 callbacks, 34 declared functions, 1 implementation-only exported function, 8 macro-support functions, 26 macros, and 3 globals; mutation tests fail on declared-function, implementation-only export, macro omissions, commented-out facade/root declarations, and duplicate manifest metadata. Aggregate fields and enum members remain value/behavior contracts rather than C-ABI parser claims. |
| Accountable pinned-source coverage | `clay-coverage-certify` binds the exact header, all 36 C fixtures, host Clang/C99 scalar/common profile, native x86-64 SIMD supplement, raw LLVM summaries, detailed source rows, functions, and every emitted branch-record direction. Scalar/common accountable results are 3,322/3,322 mapped physical lines, 107/107 source definitions, and 2,446/2,446 branch-record directions after 7 exact line and 18 exact branch dispositions; the x86-64 SIMD scope is 62/62 lines, 4/4 functions, and 14/14 directions with no dispositions. Stale exclusions, inventory drift, mixed mappings, and raw/detailed missed-count disagreement fail. One executed translation-unit instance covers a source definition; duplicate static-inline copies are not separate source definitions. This execution contract is not behavioral equivalence, every preprocessor/language mode, or cross-target proof. |
| Ordinary trace manifest | All 25 equality identities are fail-closed on fixture identity, nonempty complete records, final newline, line/byte counts, SHA-256, and exact C/Zig bytes; the default-hash identity has explicit x86-64 and AArch64 variants, unrecorded targets fail, and the manifest self-tests are part of `check`/`parity`. |
| Supplemental AArch64 QEMU execution | `aarch64-hash-qemu` runs internally pinned static Debug `aarch64-linux-musl` root and manifest tests plus both exact hash fixtures with `qemu-aarch64 -cpu max`, compares the C/Zig trace, and emits QEMU/Zig, source, artifact, target, and trace identities with all three proof flags false. `aarch64-hash-qemu-audit` is a host-only mutation test of the lane and its separation. This proves execution under the recorded user-mode emulator, not physical hardware or certification, and does not consume or produce raw-v1/provenance/import/review state. Its live-source checks detect persistent drift but do not bind compilation to immutable staged bytes or exclude an ABA change-and-restore. |
| Raw AArch64 evidence contract | `aarch64-hash-evidence-audit` fails closed on schema, current certification inputs, the bound runner-record URI/SHA-256/byte count, canonical provenance and preflight digests, passed `runner_record_preflight` gate, bound `pre_gate_snapshot_sha256` and passed `pre_gate_source_snapshot` gate, Debug mode, canonical execution digest, exact native and manifest Zig test logs with strict skip policies and bound content/count/digest metadata, exact traces, captured native-host guard line/digest, executable/toolchain/target/runner consistency, output/overwrite policy, duplicate keys, and any attempt to promote raw review state. Capture consumes only the cache preflight, fsyncs file and parent, and import preserves the validated raw bytes exactly. This proves the record workflow, not the recorded execution claims or physical execution. |
| AArch64 certification build-DAG contract | `aarch64-hash-build-contract-audit` mutation-tests the required evidence/provenance/runner-record options, cache-managed runner-preflight creation before compilation, dependency from every certification artifact compile to that preflight, final capture's preflight-only input, build-embedded/live `build.zig` digest check, fresh source snapshot, final live-input equality check, native-target/Debug guards, fresh side-effecting runs, exact stderr capture and final-writer binding for both Zig test suites, option bindings, guard/header ordering, complete final-capture dependencies, and sole-writer boundary. It proves orchestration source, not a run or adversarial source-to-binary binding; a change restored before the final live check remains outside the contract. |
| AArch64 human-review receipt contract | `aarch64-hash-review-audit` mutation-tests runner-record digest and byte-count binding, completed-log digest plus exact runner-preflight/native-host/raw-capture marker binding, current review-contract binding, time-ordered separate human attestations, non-overwriting receipt creation, and conservative proof fields. Runner-record, receipt-create, and receipt-validate steps run on any host. An accepted receipt is human-attested; it does not authenticate the reviewer, machine-verify physical hardware, or close the backlog automatically. |
| Basic compiled-C fixture | Exact serialized bounds and rectangle command type/ID/geometry for a two-child grow row. |
| Complex compiled-C fixture | Exact serialized element bounds and covered command order/type/ID/z/geometry/payloads for mixed sizing, text, clip, border, and floating behavior. |
| Sizing/text compiled-C fixture | Exact 73-line trace for min-only/min-max fit/grow, compression, aspect, all wrap modes, spacing, line height, alignment, culling, and resize. |
| String/text edge compiled-C fixture | Exact 110-line / 7,627-byte trace for static/dynamic/derived metadata, callback payload/order, clear/reinstall, cache reset, whitespace/newlines, missing-measure fallback commands, and retained-exit text. |
| Text-cache lifecycle compiled-C fixture | Exact 20-line / 925-byte trace, SHA-256 `fae48c88...27b013`, for stale-generation hits, pruning, one-bucket pressure, measured-word/cache-item free-list reuse, and declaration-time preferred metrics across a mid-frame cache reset. |
| Text-cache runtime-setter compiled-C fixture | Exact 3-line / 163-byte trace, SHA-256 `5917ef87...38a02`, for allocation-time 96-word topology, runtime reduction to 64, and restoration to 96 with the original cache entry reused. |
| Declaration/layout compiled-C fixture | Exact 122-line / 11,110-byte trace for nested axes, min/max fit/grow, fixed/percent, compression, padding, gaps, alignment, automatic/local/indexed IDs, and prior-frame declaration queries. |
| Layout/scroll breadth compiled-C fixture | Exact 11-line / 1,098-byte trace, SHA-256 `a23128a0...97776`, for aspect width-from-height and height-from-width plus horizontal drag, stationary reset, release momentum, and decay. |
| API/diagnostics compiled-C fixture | Exact 16-line / 1,044-byte trace for max-count, layout-dimension, and debug setters/getters plus ordinary diagnostic phase, type, static flag, length, exact text, and user data. |
| Render compiled-C fixture | Exact two-frame 33-command trace for image/custom pointers, rectangles, borders, overlays, nested scissors, control defaults, culling, and z ordering. |
| ID/error/collision fixtures | Exact helper fields, automatic hierarchy IDs, diagnostics, missing lookup, and distinct same-bucket lookup bounds. |
| Normalized capacity fixture | Exact seven-command stream and one render-capacity diagnostic at equivalent effective limits. |
| Focused audit regression fixture | Exact bitwise trace for fresh current-frame queries, floating-root aspect, missing-parent clip inheritance, wrapped-line ceiling, missing-measure latch, mutable layout default, callback config mutation, and nullable hover clearing. |
| Default hash compiled-C fixture | `hash-default-parity` checks the exact x86-64 target-default data/text-cache trace; the 18-line / 426-byte AArch64 expectation is separately pinned as SHA-256 `68b1ce5d...63dc787`. `aarch64-hash-qemu` runs that AArch64 trace and the root/manifest tests under the pinned emulated target but always reports all three proof flags false. Separately, `aarch64-hash-certify` requires a native target query, AArch64 host, Debug mode, and evidence/provenance/runner-record paths; creates immutable-per-DAG runner-preflight and source-snapshot record bytes though later invocations replace them; requires live-source equality again at capture; captures the fresh native-host guard line/digest and exact strict-validated Zig test logs; fresh-runs the header/manifest/native/C/Zig checks; and only then may write a raw-v1 record. Compilation still reads the live checkout rather than a staged snapshot. Scalar helpers retain separate pinned vectors. |
| Malformed public String hash regression | `malformed public String lengths are clamped before hashing` covers `hash.string`, `hash.stringWithOffset`, and non-static target-default/scalar text-config hashes; `public ID helpers clamp malformed String lengths` covers global, indexed, local, and indexed-local `Context` entry points. `zig test src/hash.zig` passes 18/18 in Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall; valid pinned vectors remain unchanged. |
| Direct ease-out compiled-C fixture | Exact 78-line bitwise grid across every property bit/composite, six elapsed/duration edges, completion, untouched fields, colors, geometry, and integer border widths. |
| Public-values compiled-C fixture | Exact 174-line value trace covering every declared public enum value, masks, zero/default semantics, helpers, full ID metadata/high-bit bytes, and mutable globals. |
| Transition compiled-C fixture | Exact 53-line / 7,846-byte multi-frame callback/state and command output for enter, ordinary X/background change, retained natural-order exit, callback timing, and completion-frame removal. |
| Transition matrix compiled-C fixture | Exact 322-line / 45,474-byte trace for all observable properties, zero duration, resize, parent triggers, reparenting, sibling orders, retained text, callbacks, completion timing, and interaction policies. |
| Transition lifecycle compiled-C fixture | Exact 100-line / 14,171-byte trace, SHA-256 `3b17ee21...31067`, for handler removal/pruning/restoration, disappearance/reappearance, repeated reparenting, nested exiting-tree removal, callback order, and record lifecycle. |
| Pointer compiled-C fixture | Exact initial/prior-frame state, hover callback and overlap ordering, press/hold/release transitions, clip rejection, and floating capture/passthrough output. |
| Floating/pointer edge compiled-C fixture | Exact 225-line / 25,759-byte trace for every attach-point pair, attachment/clip mode, internal/external scroll, z order, pointer states, capture, and boundary behavior. |
| Ordinary scroll compiled-C fixture | Exact registration, prior-frame pointer order, drag sampling, release momentum, decay, public data, and stale-pruning output. |
| External/nested scroll compiled-C fixture | Exact 52-line query callback order, nested wheel priority, pointer IDs, public data, and command geometry/order. |
| Debug inspector compiled-C fixture | Exact 733-line / 70,836-byte multiframe bitwise command trace for phase order, selected configuration values, warning payload storage, scroll, highlight, collapse, close, and width restoration. |
| Reviewed scroll divergence fixture | Exact C (`882a9516...300ed`) and Zig (`93db21e7...d7fdd`) trace digests cover matching registration/wheel/clamp behavior and deliberately different replacement/prune/drag/momentum behavior caused by C's stale ephemeral pointer. |
| Reviewed retained/context fixture | Exact 72-line / 4,983-byte C (`dc7c359c...047300`) and 72-line / 4,978-byte Zig (`5e3e3214...812b0`) traces normalize global-current versus explicit-instance selection, the reviewed duplicate-bounds line, exact callback-owner records for measurement and external scroll, and exact debug-global ownership records. They prove C's latest-installed process-global callback functions plus context-retained data versus ZLAY's context-owned pairs, and C's shared debug globals versus ZLAY's per-context settings; every other retained query, pointer, hover, scroll, prune, recovery, callback, and debug record must match. |
| Reviewed no-open API fixture | Exact 6-line C (`a0cfbe4d...c1fce`) and Zig (`c14cda9a...5988`) traces pin pre-frame and post-frame sentinel/error behavior and require byte-identical following-frame recovery. |
| Reviewed ID/access/capacity fixtures | Exact digest pairs protect duplicate query bounds (`43b6309b...ae95b` / `8f0c6ea1...4436`), invalid command access, element ceiling/fallback, text ceiling/failure flow, and render-scope overflow (`7bce37f8...fa5380` / `870aa5b6...0a395`). |
| Reviewed lifecycle/safety fixture | Exact C (`2c72689c...f9fc15`) and Zig (`e9595acf...f49cb9`) traces protect malformed-stack repair, floating-plus-clip balancing, invalid wrapped-slice suppression, and every recovery frame. |
| Public-metadata fixture | Pointer/render capacity and diagnostic static metadata compare exactly, including capacity 8 and effective render limit 7. |
| Native module/integration regressions | Safety, lifecycle, OOM rollback, checked cache-reservation overflow, exact scoped-node/parent handling, scroll/transition rejection rollback, all application-callback mutation rejection including detached and preborrowed command/scroll aliases, callback-free allocation failures, exact/deduplicated post-mutation text-cache preflight, concrete full-hash and malformed-static cache collisions, oversized string/slice constructor clamps, invalid drag/transition time and stored-scroll handling, bounded transition integer conversion, transactional inspector interaction, safe inspector coordinates, terminating invalid layout distribution, first-declaration duplicate retained/transition/scroll/hit state with exact duplicate clip ancestry, checked malformed public layout helpers and backing-aliased scratch, arbitrary-order linear root-driven height propagation and dimension-atomic malformed-forest rejection, atomic combined/split/text duplicate bookkeeping and diagnostics, signed capacity clamping, hashing, geometry, layout, text, commands, pointer, scroll, transitions, declaration order, and live inspector interaction. |
| Deep and wide traversal regressions | Height propagation accepts root-reachable arbitrary node ordering, ignores disconnected subtrees, validates malformed forests before mutating dimensions, and completes both a 50,000-element chain and 50,000-sibling declaration tree through its linear fast path; public render traversal completes the deep chain without native stack recursion. |
| Native/WebAssembly renderer smoke | An exhaustive checked dispatcher consumes a real 14-command frame natively and through Node-instantiated `wasm32-freestanding`, returning `0x5a1a110e` both times. |
| WebAssembly compile gate | The production Zig module compiles for `wasm32-freestanding` without the C oracle. |

The pinned C header is test-only. Production `src/` code must not use
`@cImport`, link Clay, load a translated object, or fall back to FFI.

## Required comparison contract

For equivalent input fixtures, compare:

- `ElementId.id`, `offset`, and `base_id` exactly;
- enum values, flags, diagnostics, and callback order exactly;
- found/not-found results and pointer-over ordering exactly;
- command count, order, type, ID, z-index, user-data identity, and active payload
  exactly;
- integer fields exactly;
- geometry and colors bit-for-bit through exact IEEE-754 `f32` serialization;
  and
- scroll, pointer, and transition state across every frame of a trace.

Every ordinary output is identity/count/digest pinned. All maintained equality
fixtures serialize observable floats and color channels as exact `f32` bits;
there are no rounded-field or field-specific tolerance exceptions. Unexpected
diagnostics and bounded-log overflow are fatal unless the diagnostic is an
explicit serialized part of the contract.

Never compare inactive union bytes or C struct padding. Normalize pointers and
compare the semantic value selected by the command/config type.

An intentional divergence trace is not passed through the equality comparator.
Its C and Zig outputs each have a reviewed SHA-256 enforced by
`zig build reviewed-divergences`, so either side changing requires an explicit
contract review.

## Remaining evidence gap

The conservative proof ladder is host exact comparison, guarded AArch64
cross-compilation, supplemental QEMU user-mode execution, then physical
non-emulated AArch64 certification and review. The optional third rung is
reproduced with:

```sh
zig build aarch64-hash-qemu-audit
zig build aarch64-hash-qemu
```

The audit is host-only; the execution step requires `qemu-aarch64` on `PATH`.
Both are deliberately outside the certification artifact graph and keep
`certification=false`, `physical_machine_proof=false`, and
`backlog_closed=false`.

This step is externally blocked in the current checkout until a qualifying
physical AArch64 runner is available. Then execute `zig build
aarch64-hash-certify -Doptimize=Debug` with all three
`-Daarch64-evidence-out`, `-Daarch64-provenance`, and
`-Daarch64-runner-record` paths on the recorded AArch64 runner (`ZL-202`). The
provenance should first be created from the actual record bytes with
`runner-provenance-create` and checked with `aarch64-hash-runner-preflight`; the
required physical/non-emulated flag is an operator claim, not machine proof.
The host x86-64 comparison, target-aware exact-output
manifest, portable AArch64 boundary/trace vectors, scalar fallback, guarded
AArch64 cross-compilation, and x86-64 mode matrix already pass. The native
command requires Zig's native target query; its PATH-independent Zig `uname`
guard and pinned-header check precede fresh certification-only manifest,
native-test, and exact C/Zig executions. Before those artifacts compile, an
internal cache-managed `zlay.aarch64-runner-preflight.v1` binds the canonical
provenance digest and exact record URI/SHA-256/byte count under its own digest.
It and the fresh source snapshot are replaceable between invocations but
immutable inputs within one certification DAG. Every artifact compile depends
on both; final capture consumes only that DAG's preflight. The source snapshot
also verifies live `build.zig` against the
digest embedded in the compiled build runner and records all certification
inputs. Every certification artifact compile depends on it; final capture
rechecks the live inputs exactly. This detects changes present at either check,
but compilation reads the live checkout and an ABA change-and-restore is not
independently excluded. The raw record binds `runner_record`,
`runner_preflight_sha256`, the passed `runner_record_preflight` gate, its
`pre_gate_snapshot_sha256`, passed `pre_gate_source_snapshot` gate, and fresh
host-guard line/digest. Both Zig test stderr streams are exact capture inputs;
the native log may contain only the pinned x86-64-only skip and the manifest
log may contain no skips, and both complete logs plus counts and digests are
embedded and revalidated. A final Python step alone may atomically create a
non-overwriting raw record outside cache/output and system temporary
directories, fsyncing both file and parent directory and binding current inputs,
executables, toolchain, target, runner facts, exact traces, external
provenance. Required any-host repository import writes the validated source
bytes unchanged.

The pre-run provenance attachment is an immutable runner identity/inventory
record, not the still-incomplete certification log. After capture, the any-host
review workflow validates that record's actual digest and byte count, the
completed log's digest, exact raw runner-preflight marker, native-host guard
trace, and exact
`evidence-captured sha256=<raw-file-sha256> provenance_review=pending backlog_closed=false`
marker, and a separate human review statement whose timestamp cannot predate
raw generation. It then creates and validates a
non-overwriting `zlay.aarch64-hash-review-receipt.v1`.

No real imported raw record, runner record, completed certification log, or
receipt is checked in. Raw validation/import remain pending and non-closing. Even an
accepted receipt is human-attested: the reviewer identity is not authenticated,
physical hardware is not machine-verified, and both automatic closure and
`backlog_closed` remain false. Cross-compilation and synthetic contract tests
are not being mislabeled as target execution; QEMU execution is target execution
under an emulator and is not being mislabeled as physical certification.

## Completion rule

ZLAY's host/pinned-source parity contract is complete because every required
observable behavioral surface and audited feature is either differentially
verified or recorded as an executable reviewed intentional Zig divergence.
Structural allocator, context-selection, and ABI exclusions are explicitly
documented. The accountable coverage gate additionally gives every executable
host-profile line, source-level function definition, and emitted branch
direction an executed or exact reviewed disposition. A function definition is
covered when at least one emitted translation-unit instance runs. This is not C
memory-layout, byte-arena,
undefined-behavior, or all-target compatibility.

Closure of the recorded AArch64 target extension still requires successful
real execution of ZL-202 against the unchanged pinned header, exact-byte
repository import of the validated raw record, the exact pre-run runner record,
the completed certification log, an accepted validated review receipt, and an
explicit maintainer closure decision. The accepted
receipt itself deliberately keeps `automatic_backlog_closure=false` and
`backlog_closed=false`. Until the full artifact set exists and that decision is
recorded, documentation must keep the host/cross-target boundary explicit even
though no known host implementation or proof-integrity row remains open. The
supplemental QEMU report and its host audit do not change this completion rule.
