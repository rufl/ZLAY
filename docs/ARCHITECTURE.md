# ZLAY architecture

ZLAY is a native Zig, renderer-neutral layout core. It ports Clay's data flow
and low-level declaration lifecycle while replacing the C library's global
current context and caller-partitioned arena with an explicit allocator-owned
`Context`.

The source baseline is Nic Barker's Clay `clay.h` at commit
`e6cc36941ab2af5d81107617039d6f527a1c660b`. The exact pin, file hash, and
source-region map are recorded in [UPSTREAM.md](UPSTREAM.md). ZLAY production
sources do not compile or call that header.

## Module boundaries

| Module | Responsibility |
| --- | --- |
| `src/root.zig` | Stable package entry point, version/pin constants, public aliases, and common constructors. |
| `src/types.zig` | Native public strings, geometry, IDs, configuration, callbacks, errors, and render-command data. These are not C-ABI layouts. |
| `src/hash.zig` | Clay-compatible ID, data, and text/config hashing. Scalar ID fields are covered by pinned oracle-derived vectors and layout-oracle IDs; byte-reading public `String` paths use the bounded safe slice view. |
| `src/geometry.zig` | Pure clipping, intersection, floating attachment, child placement, and content-geometry helpers. |
| `src/layout.zig` | Internal node model, checked public intrinsic/sizing helpers, two-axis sizing/compression, aspect propagation support, and stable root z sorting. |
| `src/text.zig` | Allocator-owned measurement cache with collision-resistant content/configuration identity, measured-word storage, wrapping, newline handling, and line alignment. It borrows application text and calls the application font measurer. |
| `src/paragraph_provider.zig` | Generic context-local provider declarations, advanced typography types, validated layout leases, and typed render transport. |
| `src/scroll.zig` | Persistent clip-container state, nested priority, wheel/drag updates, momentum, clamping, and stale-container pruning. |
| `src/transition.zig` | Pure transition interpolation, changed-property detection, property application, and the cubic ease-out callback. |
| `src/debug.zig` | Inspector constants, labels, logical row traversal, hover-row math, collapse/close decoding, and presentation helpers. |
| `src/renderer.zig` | Allocation-free command-array validation, scope balancing, statistics, and active-union dispatch to application backends. |
| `src/profile.zig` | Fixed-buffer allocator instrumentation for current/peak bytes, attempts, failures, and headroom. |
| `src/context.zig` | Frame orchestration, split and combined declarations, persistent maps, retained exit subtrees, inspector declaration, input/hit testing, layout passes, transition runtime, and iterative command emission. |

Lower-level modules remain exported for tests and advanced consumers, but
normal applications should enter through `zlay.Context` and the root aliases.
Internal module APIs are not covered by semantic-version compatibility; the
supported application surface is the root `zlay` module documented in
`docs/API.md`.

## State and ownership

`Context` separates frame-local lengths from cross-frame state.

Frame-local collections include layout nodes, child indices, open elements,
floating roots, text records, wrapped lines, render commands, and hit records.
Reusable breadth-first layout lists, subtree-clone maps, and the iterative
render stack are also context-owned scratch. `beginLayout` clears frame-local
lengths while retaining allocated capacity.

Persistent collections include the prior element map, text measurement cache,
scroll containers, transition runtimes plus their authoritative declaration-
order ID list, pointer state, installed callbacks, optional paragraph-provider
registration, and a snapshot of the prior
element/text tree when exit transitions need it.
Before each frame, allocator-owned rollback copies protect scroll containers
and transition runtime/order state. Frame declarations retain Clay's mutation
order on the working collections; rejection swaps the copies back without
allocating. External scroll-query IDs are recorded frame-locally and dispatched
only in the infallible commit tail.
Hover, transition, external-scroll, text-measurement, and diagnostic callbacks
run under an explicit callback phase. Read-only queries remain available, but
nested frame, declaration, input, cache-lifecycle, and destruction mutation
cannot replace storage that the engine is using. Pointer-over arrays expose
const slices, callback-time scroll-data pointers target detached scratch, and a
pre-reserved value clone restores live scroll storage over pointers borrowed
before callback entry.
The standalone text cache also guards its own measurement callback against
recursive measure/reset/destruction.
Generation numbers let the context prune stale elements and cache entries.
Completed bounding boxes and hover callbacks become the input to the next
frame's hit testing.

Inspector presentation is context-local. The default `debug.Theme` preserves
the pinned output exactly; the optional accessibility preset changes only debug
text contrast, font size, row density, and tree/close target sizes. Theme
normalization keeps rows tall enough for their text and controls. A single
queued `debug.Action` lets applications map non-pointer input without adding a
platform dependency; selection, collapse, close, and internal reveal scrolling
commit or roll back with the frame. `debug.State` publishes only the committed
enabled/selection/row summary, keeping frame-local row storage private.

All storage uses the allocator passed to `Context.init`. There is no implicit
global context, hidden fallback allocator, or C allocation path. One context is
mutable and not internally synchronized; callers must serialize access to it.
Independent contexts can be isolated by giving each appropriate allocator and
callback state.

The optional paragraph provider is a native addition, not part of the pinned
Clay parity surface. Its `null` default leaves the legacy measurement, cache,
wrapping, and render-command flow unchanged. `ParagraphTextStyle` preserves
advanced values independently of Clay's unsigned configuration. The legacy
`Context.text` path constructs it through `fromLegacy`; the explicit
`Context.textWithParagraphStyle` path carries advanced typography directly.
When installed, one coherent path uses provider intrinsic metrics and an exact
text/style/final-width cache. Each successful cache miss owns one generation-bound lease, and
duplicate keys share it. Existing `custom` commands transport typed lease data
without changing Clay's public `TextRenderData`, `RenderData`, or command-kind
layout; a Context resolver validates exact current-array command and cache-entry
addresses in constant time before returning the typed payload. Frame start,
reset, provider replacement, failure, and destruction release every owned entry
exactly once.

## Frame pipeline

1. The application updates viewport dimensions, pointer state, and scroll
   input. Pointer hit testing uses the previous completed frame.
2. `beginLayout` snapshots persistent scroll/transition state, increments the
   generation, resets frame lengths, and opens a fixed-size synthetic root.
   Debug mode subtracts up to the configured inspector width, 400 pixels by
   default, from that root. Narrow viewports clamp the inspector to the
   available width instead of creating negative root sizing.
3. Combined `openElement*` calls, scoped `element*` wrappers, or the split
   `openElement*Unconfigured`/`configureOpenElement` primitives build a flat
   node array plus child-index ranges. The split form preserves Clay macro
   evaluation order for declaration-time hover and scroll queries. Closing a
   node finalizes its intrinsic size. Floating elements become separate roots
   with attachment and z-order metadata. Scoped wrappers unwind on callback
   error and verify the exact node and parent they opened, rejecting same-depth
   replacement; ancestor replacement/underflow or an allocation failure during
   unwind aborts the frame without allocation rather than leaving a stale open
   stack.
4. `endLayout` closes any unbalanced declarations with a diagnostic and
   reinserts removed subtrees whose exit transitions remain active. Exit
   trigger policy, former sibling position, text records, and interaction
   suppression are carried with those synthetic nodes.
5. If transition runtime data exists, a preliminary target/geometry pass
   computes current targets and transition overrides. Its command prefix is
   validated before any transition callback runs. Ordinary frames do not perform
   this preliminary pass.
6. When enabled, the inspector snapshots the user root/element lengths and
   declares its live tree without recursively inspecting itself. On ordinary
   frames this occurs before the sole layout pass, so it sees retained boxes
   and current unmutated declarations exactly when Clay does; transition frames
   declare it after the preliminary pass. Its lower details pane also shrinks
   on short viewports so the header and element list retain usable space.
7. Transition frames reserve final sizing/render scratch, the maximum possible
   wrapped-line and command growth, text-cache item/word nodes for each distinct
   prospective post-mutation key miss using its exact word count, retained
   snapshots, and persistent-map storage. Only then are application transition
   callbacks invoked. No internally allocating Clay-compatibility operation
   remains that can reject the frame after an externally visible transition
   callback. An installed external paragraph provider can still reject a newly
   produced post-transition width; provider callbacks must therefore obey their
   side-effect and failure contract.
8. The final target pass performs horizontal sizing, wraps legacy text or
   resolves one cached provider paragraph at the exact available width, applies
   aspect-ratio height constraints, propagates heights, performs vertical
   sizing, makes the final aspect-ratio width adjustment, and stably sorts roots
   by z-index.
9. Iterative geometry/render traversal assigns bounding boxes, records hit-test
   data, updates clip/scroll container dimensions, and emits renderer-neutral
   commands in nested scope order. Neither height propagation nor render
   traversal recurses on the native call stack. Height propagation is
   root-driven for arbitrary exported trees and uses a linear declaration-order
   fast path; regressions exercise both a 50,000-element chain and a
   50,000-sibling tree. Arbitrary forests are completely validated before any
   supplied-root dimension is changed. If command capacity truncates a scope
   delimiter pair,
   the frame is rejected, its partial commands and staged hit records are
   discarded, and the last committed hit data remains active.
10. The current tree and hit records are staged when exit transitions require
   them. Retained ID maps preserve the first declaration when duplicate IDs
   exist, matching the native query rule. Persistent-map and stale-ID capacity is reserved before map mutation
   (and before callbacks on transition frames). Only after all required
   reservations succeed are external scroll queries applied,
   staged snapshot/hit data committed, the rollback snapshot retired, stale
   retained state pruned, and the borrowed command slice returned.
   Callback-time command queries read detached scratch, so the infallible commit
   tail cannot mutate a stream after its scope validation.

The renderer is intentionally downstream of this pipeline. It consumes command
order and active payloads but never participates in sizing. Conversely, font
measurement is intentionally upstream: inaccurate application measurements
produce inaccurate layout.

`src/renderer.zig` is the checked boundary between the untagged payload union
and a concrete backend. It validates the complete stream before dispatch and
passes custom commands by borrowed pointer so context-owned paragraph handles
retain their validated command identity. It does not allocate, draw pixels,
load images, or rasterize fonts. The native and freestanding-WebAssembly smokes
execute the same real layout and dispatcher path, with Node used only to
instantiate and call the emitted WebAssembly.

## Command model

The command stream contains ten command kinds: none, rectangle, border, text,
image, scissor start/end, overlay-color start/end, and custom. `RenderData` is
an untagged native union, with `RenderCommandType` acting as the external tag.
This keeps the data model close to Clay's command contract without requiring C
layout, but it makes correct tag dispatch a renderer responsibility.

Scissor and overlay pairs are nested scopes. Floating roots are sorted before
traversal, and commands within a root preserve declaration/traversal order.
Culling suppresses offscreen drawing commands by default while geometry and
hit state continue through the frame pipeline as needed.

Returned arrays and pointers alias context storage. `beginLayout` clears the
command list, and later growth can reallocate it, so a renderer must consume or
copy commands before advancing the context.

## Allocation and capacity policy

The allocator model is intentionally idiomatic Zig rather than a byte-for-byte
copy of Clay's arena partitions. `std.ArrayList`, `std.AutoHashMap`, individual
text-cache nodes, and bucket storage grow on demand. A fixed-buffer allocator is
supported, but callers must size it for the actual peak workload; there is no
implemented `Clay_MinMemorySize` equivalent.

The primary policy knobs are:

- `max_element_count`, a declaration limit with a default of 8192;
- `max_render_command_count`, where zero derives the array capacity from
  `max_element_count`; insertion reserves Clay's final slot and excess commands
  are diagnosed then omitted; a truncated prefix is returned only if its
  scissor and overlay scopes remain balanced; and
- `max_text_cache_word_count`, a hard ceiling on measured-word nodes. Resetting
  the cache recycles owned nodes, and the runtime setter changes the ceiling
  without discarding existing allocations. The allocation-time bucket count is
  retained separately from the active lookup count: safe runtime reductions and
  restorations follow Clay's `count / 32` topology, while divisors below one or
  beyond allocated storage clamp to the memory-safe range.

Element and positive render-command ceilings clamp to `maxInt(i32)` because
the public array capacity fields are signed 32-bit integers. This clamp is
applied at initialization and by the element-count setter.

Frame arrays and algorithm scratch retain capacity, so a warmed stable layout
reuses storage. New peak layouts, persistent IDs, text measurements, scroll
containers, transition states, or larger retained exit trees can allocate.
With a fixed buffer, interleaved container growth may consume more backing
storage than the final live byte count. Exact upstream partition sizes and
`Clay_MinMemorySize` arithmetic are intentionally not reproduced.

`FixedBufferProfiler` observes the backing allocator's end offset after
successful allocation, resize, and remap operations. It gives repeatable peak
evidence for representative workloads without estimating a universal minimum.

## Deliberate native differences

- Context selection is explicit; there is no `Clay_GetCurrentContext` or
  `Clay_SetCurrentContext` global.
- Public structs, unions, callbacks, and enums use native Zig layout and calling
  conventions and are not ABI-compatible with `clay.h`.
- `std.mem.Allocator` replaces Clay's caller-described arena. The public
  `Arena` data type exists for source-model coverage but is not the `Context`
  allocator implementation.
- Zig errors report lifecycle and allocation failure. The optional error
  callback separately carries non-fatal Clay-style diagnostics.
- Public `String` retains signed length metadata for source-model compatibility,
  slice constructors clamp native lengths to `maxInt(i32)`, and byte-reading
  hash paths consume `String.asSlice()`: nonpositive lengths are empty and
  positive overlong lengths clamp to available bytes.
- Context transition progress and scroll drag sampling accept only positive
  finite frame deltas. Zero/invalid drag samples yield no release momentum;
  stored non-finite scroll position/momentum is normalized; border-width
  interpolation saturates out-of-range numeric results and preserves the
  starting value for NaN. Non-finite or non-progressing layout distribution is
  stopped instead of entering an unbounded leveling loop.
- Inspector row selection rejects non-finite/out-of-range coordinates before
  integer conversion, and inspector numeric formatting clamps extreme values
  while rendering NaN deterministically as zero.
- Scroll containers retain ID/value-owned layout state instead of Clay's pointer
  into reset ephemeral storage, avoiding replacement aliasing and a skipped
  swap-removed update.
- Duplicate IDs retain the first declared map entry for both ordinary queries
  and retained exit-transition lookup; later duplicates cannot install
  transition or scroll state, overwrite first-owner scroll geometry, emit
  ID-keyed hits, or borrow first-owner transition interaction state. Exact
  frame-local parent/clip indexes disambiguate visible duplicate subtrees and
  negative-z floating roots while preserving prior committed fallback for
  unique nodes that have not rendered yet.
- Text-cache bucket placement retains Clay's target-default 32-bit hash, but a
  hit additionally requires safe length/configuration plus a SHA-256 digest for
  dynamic text or the complete pointer for static text. Full hash collisions
  therefore cannot share metrics or measured-word offsets.
- Public low-level sizing validates roots, child ranges, parent links, cycles,
  floating-parent map entries, and scratch-list backing-allocation aliasing
  before dimensions are changed; all scratch growth is also pre-reserved before
  the first write. Intrinsic finalization and stale scroll selection reject
  invalid indexes without trapping.
- Inspector selection, collapse, and close state is staged with the frame and
  committed only after layout/render/commit preflight succeeds.
- Debug duplicate-collision storage is reserved before combined, split, or text
  declaration mutation, so allocation failure cannot leave a partial tree.
- Scoped helper cleanup propagates its own allocation failure and aborts the
  current frame allocation-free; it never reports only the callback error while
  retaining an unclosed element.
- A capacity warning may still yield a balanced shortened command stream, but
  a prefix with an unclosed scissor or overlay scope closes the frame and
  returns `RenderCommandCapacityExceeded`; rejected commands and hit records
  are not published.
- Pointer updates reserve their complete worst-case hit set before changing
  pointer state or invoking hover callbacks and reject recursive pointer
  updates. Every application callback family prevents callback-time
  frame/input/cache mutation or destruction; const pointer-over views and
  detached callback scroll pointers plus restoration of preborrowed aliases
  close the query-result paths. Transition
  frames also reserve exact distinct text-cache misses plus all final
  layout/render/commit growth
  before invoking callbacks. Late frame commits stage retained exit snapshots
  and hit records, snapshot scroll/transition state, and defer guarded external
  scroll queries, keeping the last completed surfaces intact on rejection
  without leaking callback effects.
- Public array capacities are logical rather than allocator reservations.
  Pointer-over capacity is persistent and non-shrinking like Clay's initialized
  array; render capacity uses the explicit command capacity or current
  element-count default.
- Renderers and font systems remain application adapters rather than core
  dependencies.

These differences do not waive behavioral proof. Observable semantics still
need native tests and pinned-upstream comparisons unless a divergence is
explicitly reviewed and recorded.

## Verification boundary

`zig build verify` combines the C-free native gate with the pinned-header check
and compiled-C differential fixtures for one optimization mode. `zig build
verify-all` runs the complete Debug and ReleaseSafe differential matrix, then
the C-free native/WebAssembly checks in ReleaseFast and ReleaseSmall, and also
runs `clay-coverage-certify`. The four nested mode invocations use distinct
local caches, preventing shared-cache cleanup from invalidating another mode's
pending executable or WebAssembly smoke artifact. The certifier binds the exact header and complete
C-fixture inventory, then requires every executable line, source-level function,
and source branch direction emitted by the host Clang/C99 scalar/common profile
and native x86-64 SIMD supplement either to run or to have one exact reviewed
disposition. Raw LLVM percentages remain visible; the accountable 100% result
is currently 3,322/3,322 mapped scalar/common lines, 107/107 source definitions,
and 2,446/2,446 branch-record directions, plus 62/62 lines, 4/4 functions, and
14/14 directions in the active x86-64 SIMD scope. One executed translation-unit
instance covers a source definition; duplicate static-inline copies are not
separate source definitions. The result is deliberately not a claim of C ABI,
every preprocessor/language mode, cross-target, or infinite-input equivalence. The native
gate covers lifecycle and OOM rollback, two-axis layout, text and commands,
   pointer/scroll behavior, enter/change/retained-exit transitions, declaration
   evaluation order, atomic duplicate bookkeeping, atomic pointer/frame commit,
   scoped-cleanup frame abort, persistent pointer capacity metadata,
   render-scope rejection/hidden prefix, scroll/transition rollback, all five
   application-callback reentrancy families and detached scroll/command query aliases, checked cache
   reservation arithmetic, exact/deduplicated post-mutation text-cache
   preflight, signed-length constructor clamps, invalid time/transition numeric
   bounds, normalized stored scroll state, non-progressing layout distribution,
   duplicate retained exits, inspector coordinate conversion, pre-handler allocation failure, and root-driven arbitrary-order
   plus deep/wide linear iterative traversal with dimension-atomic
   malformed-forest rejection.
It also compiles the core for `wasm32-freestanding`.

`zig build aarch64-hash-qemu` is an opt-in supplemental execution branch. It
ignores the ordinary selected target for its internally pinned static Debug
`aarch64-linux-musl` root tests, manifest tests, and C/Zig hash fixtures, runs
each target artifact through `qemu-aarch64 -cpu max`, and compares the exact
trace with a host tool. Its runtime line binds tool, target/source, artifact,
and trace identities while setting
`certification=false physical_machine_proof=false backlog_closed=false`.
`zig build aarch64-hash-qemu-audit` is the host-only mutation audit for that
branch and requires no QEMU. Neither step is connected to raw-v1 capture,
provenance, import, review, or certification.

The differential fixtures cover exact serialized output for basic and complex
layout, dense sizing/text and render matrices, IDs/errors/collisions and a
normalized capacity boundary, ordinary plus external/nested scrolling, all 81
floating attachment pairs with pointer/clip edges, a dense multi-frame
transition matrix, transition record pruning/removal/reappearance/reparenting,
string/text callback and cache lifecycle, stale cache/free-list reuse,
bidirectional aspect sizing, horizontal drag/momentum, and the live inspector.
All 25 ordinary outputs are exact-bit and digest pinned. The retained/two-context
and no-open API matrices record reviewed structural/lifecycle differences while
requiring ordinary retained behavior and recovery to match.

Focused fixtures deliberately do not compare equal for the stale scroll layout
pointer, duplicate-ID bounds overwrite, invalid command access, element/text
capacity failure, render-scope truncation, explicit versus global context
selection, or no-open API failure policy. Render capacity metadata and its
effective final-slot boundary compare exactly; the unsafe scoped-prefix outcome
is separately digest-pinned.
Exact digests keep those native divergence choices executable without relabeling
them as parity.

The remaining boundaries are:

- Exact upstream arena partitions, alignment accounting, and
  `Clay_MinMemorySize` are an intentional native divergence; `Context` uses a
  supplied `std.mem.Allocator` instead.
- Public declarations, values, ordinary behavior, retained/current-context
  lifecycle, inspector output, and proof-gate integrity have pinned-C evidence.
  The only open certification artifact set is real target-default hashing on
  AArch64 plus provenance review and explicit maintainer closure. It is
  externally blocked in this checkout by the absent qualifying physical runner,
  not by a known code failure. Its ordinary-
  manifest identity selects exact x86-64/AArch64 contracts,
  `hash-default-parity` passes on x86-64, and
  `aarch64-hash-compile -Dtarget=aarch64-linux` cross-compiles the guarded
  fixtures and native tests. The optional `aarch64-hash-qemu` rung then executes
  internally pinned static Debug AArch64 root tests, manifest tests, and exact
  C/Zig output under QEMU user mode; its host-only audit locks the emulator,
  target, dependency, report, and proof-separation contract. This is stronger
  than compile-only coverage but remains explicitly emulated and non-certifying.
  The certification lane requires Debug, a native
  target query, all three evidence/provenance/runner-record paths, and a
  PATH-independent Zig `uname` guard. Provenance creation reads the actual
  runner-record bytes into a durable non-overwriting record; its explicit
  physical/non-emulated operator claim is not machine proof. A local
  `aarch64-hash-runner-preflight` step validates the byte binding. Before
  certification artifacts compile, a cache-managed
  `zlay.aarch64-runner-preflight.v1` binds the canonical provenance digest and
  exact record URI/SHA-256/byte count under its own digest, while a fresh source
  snapshot verifies live `build.zig` against the build-embedded digest and
  records all certification inputs. Both generated files are replaceable
  between invocations but immutable inputs within one certification DAG. Every
  artifact compile depends on both; capture consumes only that DAG's runner
  preflight and requires the live source inputs
  to remain exactly equal. The raw record binds `runner_record`,
  `runner_preflight_sha256`, the passed `runner_record_preflight` gate,
  `pre_gate_snapshot_sha256`, the passed `pre_gate_source_snapshot` gate, and
  that fresh guard line/digest. The native and ordinary-manifest test stderr
  streams are exact final-capture inputs: strict parsing requires contiguous
  successful Zig records, matching summaries, at least one passing test, only
  the pinned x86-64-only native skip, and no manifest skip. The canonical raw
  execution embeds both complete logs plus their counts, exact skip names, byte
  counts, and SHA-256 digests, and validation re-parses the embedded bytes.
  Guard/header ordering, certification-only `has_side_effects` executions, and
  a mutation-tested build DAG prevent changed, cached, or reordered work from
  becoming fresh evidence. Only the final Python step writes an atomic,
  non-overwriting raw-v1 record outside cache/output and system temporary
  directories, fsyncing the file and parent directory. The record binds current
  source inputs, exact test logs, exact traces, executable/toolchain/target/runner digests and
  facts, external provenance, and the preflight-derived runner binding;
  any-host validation/import enforces pending, non-closing state; exact-byte
  repository import is required for closure and preserves the raw bytes exactly.

  The pre-run provenance attachment is an immutable runner identity/inventory
  record rather than the not-yet-complete certification log. Post-run review
  validates its actual digest and byte count and binds the completed log's exact
  `runner-provenance-valid ... physical_machine_proof=false
  backlog_closed=false` marker, native-host line, raw-capture marker, and digest
  plus a separate human statement into a
  non-overwriting `zlay.aarch64-hash-review-receipt.v1`. The review timestamp
  cannot precede raw generation. An accepted receipt remains human-attested:
  reviewer identity is unauthenticated, physical hardware is not
  machine-verified, and automatic/backlog closure is false. No real imported raw
  record, runner record, completed log, or receipt exists yet. ZL-202 therefore
  remains open for physical non-emulated AArch64 execution and the complete
  artifact/review set; the QEMU branch cannot satisfy that boundary.
- A checked dispatcher and actual native/WebAssembly execution smoke are
  bundled, but a concrete graphics API and broad OS/browser runtime matrix are
  adapters outside the layout-core parity boundary.

Completion criteria and the evidence required to change these statements live
in [PARITY.md](PARITY.md) and [BACKLOG.md](../BACKLOG.md).
