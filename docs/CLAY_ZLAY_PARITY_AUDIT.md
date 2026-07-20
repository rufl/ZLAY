# Clay to ZLAY 1:1 parity audit

Audit date: 2026-07-13  
Evidence-workflow refresh: 2026-07-14  
Supplemental AArch64 emulation refresh: 2026-07-14  
Text-cache topology refresh: 2026-07-15  
Accountable source-coverage refresh: 2026-07-15  
Normative source: Nic Barker's `clay.h` at commit
`e6cc36941ab2af5d81107617039d6f527a1c660b`, SHA-256
`54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728`.

## Verdict

ZLAY's **host/pinned-source parity contract is complete on x86-64**. The audit
found real implementation mismatches and proof gaps; every confirmed host
defect was corrected, every audited high-value gap was promoted into a
maintained C/Zig contract, and all 25 ordinary comparisons are byte-identical
with exact observable `f32` bits. Intentional observable behavioral differences
are digest-pinned; structural allocator, context, and ABI choices are explicitly
documented or normalized rather than mislabeled as equality.

The recorded AArch64 target extension is not yet closed: the adaptive
target-default hash fixture has architecture-selected exact x86-64/AArch64
contracts, portable boundary vectors, a fail-closed Debug raw execution-record
workflow, a mutation-audited certification DAG with a pre-gate source snapshot,
an immutable-within-the-DAG runner preflight, and an any-host human-review
receipt workflow. Both cache-managed pre-gates may be replaced by later
invocations. The snapshot checks live
`build.zig` against a build-embedded digest before every dependent certification
artifact compiles, and capture requires all live inputs still match it.
Those equality checks detect persistent drift but compilation reads the live
checkout, so adversarial change-and-restore/source-to-binary binding remains
outside both the certification and supplemental QEMU proof boundaries.
Certification requires a native target query and captures a fresh
PATH-independent Zig host-guard trace, but it has not executed on real AArch64
hardware because no qualifying physical runner is available to this checkout.
The optional `aarch64-hash-qemu` lane now executes internally pinned static
Debug `aarch64-linux-musl` root tests, manifest tests, and the exact C/Zig trace
with `qemu-aarch64 -cpu max`; its bound report and host-only mutation audit mark
all certification, physical-machine-proof, and backlog-closure flags false.
That supplemental emulator result is isolated from the physical evidence and
review workflows.
No real imported raw record, runner record, completed certification log, or
receipt exists. That externally blocked evidence requirement is the sole open
backlog row, not a known host implementation gap.

“1:1” in this project means the same observable values, layout, command order,
callback timing, diagnostics, and state transitions for the pinned source. It
does not require a C ABI, C memory layout, or C's undefined behavior. Every
intentional native safety difference must have a narrow description and a
two-sided executable trace.

## Scope and method

The review used four complementary passes:

1. Reconciled the pinned public surface against the native root facade.
2. Read the layout, text, interaction, scrolling, transition, inspector, and
   command-generation implementations against their corresponding `clay.h`
   ranges.
3. Compiled every C fixture with Clang source coverage and merged the profiles.
4. Ran focused C/Zig probes for suspicious branches, then promoted confirmed
   defects into maintained differential or native regression tests.

The Go and Odin-inspired reference ports remain useful for design direction,
but only the pinned official header is normative.

## Public-surface reconciliation

| Surface | Pinned Clay inventory | ZLAY disposition |
| --- | ---: | --- |
| Named public types | 64 including `Clay_Context` | All represented; `Context` is allocator-owned rather than C-ABI-compatible |
| Enums | 19 enums / 86 declared values | All represented with matching numeric values |
| Callback shapes | 7 | All represented, including nullable hover registration |
| Declared public functions | 34 | All mapped or explicitly classified as allocator/current-context divergences |
| Implementation-only public functions | 1 | `Clay_SetExternalScrollHandlingEnabled` mapped |
| Macro-support functions | 8 | All mapped to combined or split native declaration operations |
| Public macro spellings | 26 | All inventoried; typed or comptime Zig equivalents are identified |
| Exported globals | 3 | Mutable layout default is shared; debug width/color are explicit per-context state with read/write methods |

The facade test reads the exact pinned header and verifies its SHA-256. A
separate lexical parser now extracts every supported public declaration class
and compares it with a checked-in upstream-to-ZLAY manifest and the facade
ledger. Mutation tests prove that a newly added function or macro fails closed,
that commented-out ledger/root declarations cannot satisfy the gate, and that
duplicate manifest metadata is rejected. Implementation-only
`CLAY_WASM_EXPORT` functions are inventoried separately and have their own
omission mutation. Aggregate fields, enum members, C sizes,
alignments, and calling conventions remain outside this lexical gate; they are
covered by value/behavior contracts rather than mislabeled as C ABI proof.

## Defects found and corrected

| Area | Previous behavior | Pinned Clay behavior / correction |
| --- | --- | --- |
| Render command capacity | Defaulted to four commands per element and admitted every slot | Capacity now equals `maxElementCount`; `Clay__AddRenderCommand` reserves the final slot, and ZLAY rejects a truncated prefix if omission leaves a render scope open |
| Non-ASCII IDs | Always treated ID bytes as unsigned | ID hashing now follows the active target C `char` signedness, including high-bit and UTF-8 bytes |
| Public string IDs | Slice helpers discarded static-lifetime metadata | Exact `String`-accepting `getElementId` and `getElementIdWithIndex` operations preserve the full `ElementId.string_id` |
| Hover registration | Could not pass a null callback | `onHover` accepts a nullable callback and can explicitly clear a registration |
| Measure callback mutation | Later callback mutations were applied to disposable copies | Initial line height and wrapping/render-time text config now follow Clay's mutable-pointer timing |
| Missing-measure warning latch | Reinstalling/clearing the callback reset the same-frame latch | The latch is reset only by `beginLayout`, matching Clay |
| Fresh element query | A first-frame element was absent until `endLayout` | An opened current-frame ID is immediately `found` with its zero/default box |
| Floating-root aspect ratio | Aspect ratio was post-applied to every node, including a floating root | Only hierarchical children collected by the X-axis breadth-first pass receive the two post-scaling phases |
| Missing floating parent | A missing ID inherited the enclosing clip | Missing `element_with_id` attachment now has clip ID zero after reporting the diagnostic |
| Wrapped-line arena | Wrapped lines could grow without Clay's global element-count ceiling | Per-frame wrapped output is capped at `maxElementCount`, and query height reflects retained lines |
| Mutable layout default | Exposed only an inert constant | A shared mutable `layout_default` handle is read for text nodes during final layout |
| Debug globals | Only write methods existed | Per-context width and highlight-color state now has matching getters |
| Macro ledger | Omitted two string-support macros and mapped conditional min/max to different NaN semantics | Inventory is 26; single-evaluation `clayMin`/`clayMax` preserve Clay's conditional value selection |
| Equality comparator | Two empty traces could pass | Exact comparisons now reject empty or incomplete newline-delimited traces |
| Production-native policy | Relied only on indirect freestanding compilation | The build now directly rejects C imports, C ABI declarations, and C build hooks under `src/` |
| `Clay_EaseOut` proof | Implemented and unit-tested only | A 78-case bitwise C/Zig grid covers every property bit/composite, zero/mid/exact/over/negative elapsed time, and zero duration |
| Public value proof | Defaults and enum values were reviewed but not exhaustively differential | A 174-line bitwise fixture now covers all 19 public enums/86 values, masks, public defaults/helpers, ID metadata, and globals |
| Inspector phase order | Built the inspector after a layout pass even when no transition data existed, exposing aspect-mutated declaration bounds too early | Ordinary frames now declare the inspector before the sole final layout; transition frames retain Clay's preliminary target pass |
| Aspect/percent sizing union state | Preserving Clay's unconditional second-float write by accessing an inactive Zig `min_max` union member could panic in safety builds when percent height reached propagation | A dedicated `percent_height_max` field retains that C-union value, so ordinary percent-height trees and aspect-plus-percent propagation reach the vertical pass without inactive-union access |
| Runtime text-cache topology | `setMaxMeasureTextCacheWordCount` changed only the native word ceiling, leaving the initialization-time hash divisor active | The active bucket divisor now follows Clay's `limit / 32` topology for defined values; the original allocation is retained so 96-to-64-to-96 lookups match exactly, while below-32 and above-allocation cases clamp safely instead of reproducing modulo-zero/out-of-bounds behavior |
| Mid-frame text-cache reset | Final wrapping replaced the declaration-time preferred dimensions with measurements made after `resetMeasureTextCache`, changing width and natural line height when the callback's metrics changed | Each text record retains its declaration-time preferred dimensions; the expanded exact C/Zig lifecycle trace locks reset-between-declaration-and-`endLayout` behavior |
| Oracle numeric precision | Older equality fixtures rounded observable floats and some color/radius fields | All ordinary fixtures serialize exact IEEE-754 `f32` bits; no tolerance exception remains |
| Oracle diagnostics and bounded logs | Some unexpected diagnostics reached stderr only and some fixed logs silently truncated | Unexpected diagnostics and log overflow are fatal unless explicitly serialized as expected contract data |

## Coverage evidence and its limit

The first audit pass used one merged profile and retained the following figures
as historical evidence only:

| Metric | Covered | Total | Percent |
| --- | ---: | ---: | ---: |
| Executable lines | 2,560 | 3,083 | 83.04% |
| Branches | 1,341 | 1,716 | 78.15% |
| Functions | 84 | 107 | 78.50% |
| Regions | 2,452 | 3,500 | 70.06% |

Those numbers exposed an entirely uncalled `Clay_EaseOut`, thin inspector
coverage, and untested lifecycle/capacity paths. They are not comparable to the
current gate because the old pass mixed scalar and target-default mappings.

The certifying pass now builds two explicit profiles. All 36 C fixtures compile
under host Clang/C99 with `CLAY_DISABLE_SIMD` for the scalar/common profile. Its
unmodified raw LLVM report is:

| Raw scalar/common metric | Covered | Total | Percent |
| --- | ---: | ---: | ---: |
| Executable lines | 3,076 | 3,083 | 99.77% |
| Functions | 107 | 107 | 100.00% |
| Branches | 1,698 | 1,716 | 98.95% |
| Regions | 3,495 | 3,500 | 99.86% |

The fail-closed source inventory then reconciles the raw misses to detailed
source obligations:

| Accountable scalar/common obligation | Covered | In scope | Dispositions | Result |
| --- | ---: | ---: | ---: | ---: |
| Raw executable lines | 3,076 | 3,076 | 7 | 100.00% |
| Mapped physical lines | 3,322 | 3,322 | 7 | 100.00% |
| Source-level function definitions | 107 | 107 | 0 | 100.00% |
| Raw branch directions | 1,698 | 1,698 | 18 | 100.00% |
| Emitted branch-record directions | 2,446 | 2,446 | 18 | 100.00% |

The seven line dispositions are four exact LLVM closing-brace mapping artifacts
after executed floating-sizing arms and three lines in a body made unreachable
by Clay's nonnull hash-map sentinel. The eighteen branch dispositions are
thirteen exact dominated/sentinel source invariants and five exact
macro-expansion invariants; every safely reachable branch direction is driven.
Coordinates, branch kind/file IDs/occurrences, inventories, and rationales are
SHA-pinned, and a covered disposition becomes stale and fails the gate. A
source-level function definition is covered when at least one emitted
translation-unit instance executes; duplicate static-inline copies are not
separate source definitions.

The native x86-64 supplement compiles only `hash_default_fixture.c` without
`CLAY_DISABLE_SIMD` and scopes accountability to the active x86-64 hash and
memory-comparison bodies:

| Scoped x86-64 SIMD obligation | Covered | Total | Result |
| --- | ---: | ---: | ---: |
| Mapped physical lines | 62 | 62 | 100.00% |
| Functions | 4 | 4 | 100.00% |
| Branch-record directions | 14 | 14 | 100.00% |

The certifier rejects activation of the AArch64 or scalar bodies in that
supplement. This execution accountability is not behavioral equivalence, C ABI
proof, every compiler/preprocessor/language profile, infinite-input proof, or
cross-target certification; differential and reviewed-divergence contracts
remain the behavioral authority.

## Audit closure evidence

| Contract | Clay result | ZLAY result | Disposition |
| --- | --- | --- | --- |
| Ordinary equality manifest | 25 reviewed traces | Same 25 traces | Exact bytes, line/byte counts, SHA-256, final newline, complete records, and IEEE-754 observable fields |
| Supplemental AArch64 QEMU execution | Exact target-default C trace from the static Debug `aarch64-linux-musl` fixture under `qemu-aarch64 -cpu max` | Root and manifest tests pass under the same emulator; the Zig fixture trace is byte-identical to C | The runtime report binds QEMU/Zig, source, all four target artifacts, target, and trace identities with `certification=false`, `physical_machine_proof=false`, and `backlog_closed=false`; the host-only audit mutation-tests wiring and separation, no certification artifact path is reachable, and live-source equality detects persistent drift rather than adversarial ABA |
| Raw AArch64 execution-record contract | Current-source Debug execution, runner-record URI/SHA-256/byte-count plus preflight digest/gate, source-snapshot digest/gate, exact strict-validated native/manifest Zig test logs, exact trace, fresh native-host guard, and executable/toolchain/target/runner binding | Same contract validates on any review host | Workflow is fail-closed; capture embeds and re-parses the exact test-log bytes and metadata, consumes only the preflight, is atomic/non-overwriting, and fsyncs file plus parent; import preserves exact bytes; raw state stays pending/non-closing and is not physical-runner evidence |
| AArch64 certification build-DAG contract | Required evidence/provenance/runner-record paths, precompile cache-managed runner preflight, every artifact compile gated by it and the build-embedded/live `build.zig` all-input snapshot, final preflight-only capture/live-input equality, native-target/Debug guards, fresh runs, exact stderr capture/binding for both Zig suites, guard/header ordering, complete capture dependencies, and sole writer | Same orchestration is mutation-audited | Closes runner-input and test-result-binding gaps and detects ordinary persistent source drift; compilation still reads the live checkout, so adversarial ABA/source-to-binary binding remains outside the proof; proves build-source wiring, not execution |
| AArch64 provenance-review receipt contract | Actual pre-run runner-record digest/byte count, completed-log digest and exact runner-preflight/native-host/raw-capture markers, current review contract, and separate human attestations | Same bindings validate on any review host | Non-overwriting accepted receipt is human-attested; reviewer identity and physical hardware are not machine-verified, and automatic/backlog closure stays false |
| Bidirectional aspect and horizontal scroll | 11 lines / 1,098 bytes / `a23128a0...97776` | Identical | Exact parity |
| Text-cache lifecycle and mid-frame reset | 20 lines / 925 bytes / `fae48c88...27b013` | Identical | Exact parity, including declaration-time preferred metrics after cache reset |
| Text-cache runtime setter topology | 3 lines / 163 bytes / `5917ef87...38a02` | Identical | Exact parity for the safe initial 96, lowered 64, restored 96 sequence; native below-32 and above-allocation clamps are separately unit-tested |
| Transition record lifecycle | 100 lines / 14,171 bytes / `3b17ee21...31067` | Identical | Exact parity; also GCC/Clang, ReleaseSafe, and C UBSan checked |
| Retained state and two contexts | 72 lines / 4,983 bytes / `dc7c359c...047300` | 72 lines / 4,978 bytes / `5e3e3214...812b0` | Exact after excluding global-current/explicit-instance labels, the separately reviewed duplicate-bounds line, exact measurement/query callback-owner records, and exact debug-global ownership records; those records prove C's latest process-global callback functions with per-context data and shared debug globals versus ZLAY's per-Context callback pairs and debug settings |
| API calls outside an open declaration | 6 lines / 396 bytes / `a0cfbe4d...c1fce` | 6 lines / 371 bytes / `c14cda9a...5988` | Reviewed checked-lifecycle divergence; following-frame recovery is exact |
| Render scope capacity | 7-line trace, `7bce37f8...fa5380`; returns success with an unmatched final scissor start | 4-line trace `870aa5b6...0a395`; closes the frame, returns `RenderCommandCapacityExceeded`, and exposes zero commands through checked context access | Reviewed safety divergence; ZLAY never exposes the structurally invalid array |

The original audit additions closed ZL-116, ZL-119, and ZL-121; the 2026-07-15
accountability and ownership refresh closes ZL-215. The maintained production-
C-free gate rejects `@cImport`, C ABI declarations, and C build hooks. A
separate repository scan found no TODO, FIXME, stub, placeholder, or
unimplemented marker under `src/`; the pinned C header exists only under the
oracle/provenance boundary.

## Current proof boundary by subsystem

| Subsystem | Current assessment | Boundary or remaining proof |
| --- | --- | --- |
| Public types and facade | Parsed declaration manifest, explicit native mappings, and exhaustive public values pass; oversized native `String`/`StringSlice` constructor lengths clamp to signed public metadata | Aggregate field semantics remain behaviorally covered rather than C-ABI-compatible |
| IDs and hash helpers | Corrected target-aware IDs; default x86-64/AArch64/scalar algorithms implemented with exact host-C and boundary vectors; ZL-204 clamps malformed public String lengths before byte-reading hashes in all four optimization modes; the static Debug QEMU lane executes the exact AArch64 tests/trace with bound non-certifying identities | Physical non-emulated AArch64 execution of the adaptive C/Zig fixture and its complete certification/review artifact set |
| Declaration and sizing | Exact basic, dense, residual, bidirectional-aspect, floating, capacity, and declaration-order fixtures pass; height propagation is linear across 50,000-depth, 50,000 declaration-width, and 20,000 reverse-index-width regressions and validates duplicate edges, malformed ranges, and disconnected cycles before changing dimensions; child-gap totals widen before multiplication on 32-bit targets; public sizing helpers reject malformed roots/edges/maps and backing-aliased scratch and reserve all scratch growth before dimension mutation; percentage/missing-parent diagnostics wait for successful declaration preflight; non-finite/non-progressing distribution terminates; scoped helpers enforce exact node/parent identity and abort ancestor replacement or underflow | No known host gap in the audited matrix |
| Text and cache | Exact wrap/callback/capacity traces plus stale-generation, word/item free-list, and mid-frame-reset lifecycle pass; declaration-time preferred dimensions survive cache reset; invalid C `-1` edge is digest-pinned; public reservation totals are checked, declaration/output/cache allocation failure precedes measurement callbacks, measurement callbacks cannot recursively reset, destroy, or retune cache state, exact distinct final-pass cache misses are reserved before transition callbacks, and concrete same/different-length full 32-bit hash collisions plus malformed same-pointer static strings retain distinct content/configuration identities | Allocator-owned cache-item storage and collision-resistant full identity remain intentional ownership/safety divergences |
| Rendering and culling | Every engine-emitted command kind and active payload is covered; all observable fields are bit-exact; the scoped-capacity divergence prevents an unbalanced prefix from escaping, and callback-time checked command access cannot mutate the validated live stream | Concrete graphics backends remain adapters outside the core |
| Pointer, hover, floating, clip | Dense attachment/pointer matrix plus digest-pinned floating-plus-clip safety correction; rejected frames cannot replace committed hit data, pointer OOM fires no callbacks or partial update, recursive pointer samples fail explicitly, and pointer-over queries expose only const slices; later duplicates own no ID-keyed hits/transition blocking, while exact node ancestry preserves their descendant clip bounds and negative-z unique roots retain prior committed parent/clip fallback | No known host gap in the audited matrix |
| Scrolling | Vertical/horizontal drag, stationary reset, release/momentum, pruning, nested/external behavior match; rejected frames restore committed containers and invoke no external query, callback-time pointers are detached, preborrowed aliases are restored, stale selections return null, and later duplicate IDs cannot create/overwrite first-owner scroll state; zero/non-finite drag sample time or stored state cannot retain non-finite momentum | Stale replacement-pointer behavior, zero-time release division, invalid stored-state persistence, and first-owner duplicate safety are intentionally corrected |
| Transitions | Dense property/trigger/ease grid plus 100-line prune/removal/reappearance/reparenting lifecycle trace pass; rejected frames restore runtime state and complete layout, render-scope, text-cache, retained-snapshot, and commit preflight before callbacks; later duplicate IDs cannot replace first-declaration transition state; Context deltas normalize to positive finite time and border-width extrapolation is bounded | Ordinary valid-input behavior remains exact; invalid numeric conversion and first-owner duplicate safety are native divergences |
| Debug inspector | Exact 733-line trace selects layout, text, color/radius, aspect, image, floating, clip, and border panes and exercises custom rendering plus warning payload storage; selection/collapse/close state commits only with a successful frame, and native row/numeric conversion rejects or clamps invalid floats | Pinned Clay has no warning-array producer; the fixture injects its internal storage directly |
| Lifecycle and contexts | A 72-line retained/two-context matrix passes after exact explicit-context, duplicate-bounds, measurement/query callback-owner, and debug-global normalization; malformed and no-open lifecycle differences plus recovery are digest-pinned; duplicate-ID retained exits preserve the first declaration | Process-global C context selection is intentionally replaced by explicit Zig instances. Pinned C combines the latest process-global measurement and external-scroll-query functions with each context's retained user data and shares debug width/color; ZLAY owns each function/data pair and debug setting per `Context` |

## Intentional native differences

The following are not source-parity claims and must stay visibly classified:

- `std.mem.Allocator` ownership replaces Clay's caller-partitioned byte arena
  and `Clay_MinMemorySize` model.
- Explicit `*Context` parameters replace the process-global current context;
  measurement/query callback functions and debug width/color are per-context in
  ZLAY instead of process-global as in pinned Clay. Exact two-context owner
  records pin these differences.
- Fallible Zig operations and nullable checked access replace several C
  sentinel/default-object and out-of-bounds behaviors.
- ZLAY fully repairs an unbalanced declaration stack; pinned Clay closes only
  one element and can leave deeper stacks malformed.
- ZLAY avoids Clay's stale ephemeral scroll pointer and preserves the first
  duplicate-ID query record.
- ZLAY balances a floating element that is also a clipping element instead of
  reproducing Clay's leaked clip-stack entry.
- ZLAY does not construct an invalid negative-length string slice for Clay's
  leading-space/empty wrapped-line corner case.
- Native string/slice constructors clamp lengths above `maxInt(i32)`; zero or
  invalid drag sample time yields no release momentum; Context transition time,
  border-width conversion, and inspector numeric conversion are bounded rather
  than inheriting C division/conversion undefined behavior.
- Non-finite stored scroll state is normalized, non-finite/non-progressing
  layout distribution terminates, callback command queries use detached
  scratch, and retained duplicate-ID lookup keeps the first declaration.
- ZLAY rejects a command-capacity prefix with an unclosed scissor or overlay
  scope instead of returning it as a successful render array.
- Zig-only scoped wrappers abort the current frame if automatic cleanup cannot
  allocate; oversized native capacities clamp before signed public metadata
  conversion, and duplicate debug bookkeeping is preflighted before mutation.
- ZLAY reports checked `NoOpenElement` behavior outside a user declaration
  scope instead of reproducing Clay's internal-error/default-object and retained
  synthetic-root results.

Source-comparable behavioral safety differences have two-sided, digest-pinned
numeric traces; native-only invalid-input boundaries have focused regressions in
every optimization mode. Lifecycle-sensitive cases include next-frame recovery
checks. The C invalid slice is never dereferenced; the fixture records its
signed length and numeric metadata, and also passes UBSan. Allocator, ABI, and
explicit-context choices are structural differences, with retained state
compared through explicit normalization rather than false byte-layout
equivalence.

## Proof-gate result and remaining evidence

All 25 ordinary equality pairs have fail-closed identity, nonempty-record,
final-newline, line-count, byte-count, SHA-256, and exact-byte contracts. Every
observable float is serialized as IEEE-754 bits. Unexpected diagnostics and
bounded-log overflow are fatal unless explicitly serialized as expected output.

The inspector fixture exercises every emitted pane with active values, while
the separate public-values, sizing, declaration, floating, and transition
fixtures exercise enum values and behavioral variants. This is a maintained,
reviewed test matrix rather than a formal proof over an infinite input space.

`verify-all` preserves full Debug and ReleaseSafe differential verification,
followed by the C-free native/WebAssembly check in ReleaseFast and ReleaseSmall.
The manifest self-tests are now build-wired, and the default-hash identity
selects exact x86-64 and AArch64 digests while rejecting other architectures.
The raw-v1 evidence contract, runner preflight, pre-gate source
snapshot/certification build DAG, and human-review receipt contract are
build-wired and fail closed under mutation, but their synthetic tests prove only
the workflows. Separately, the optional QEMU lane and its host-only audit prove
internally pinned static Debug target execution under the recorded user-mode
emulator while emitting tool/source/artifact/trace identities and all three
false proof flags. They never enter raw-v1 capture, runner provenance, import,
review, or certification. The only open certification evidence is real
execution of the target-default C/Zig hash oracle on the recorded AArch64
runner, followed by validation of the immutable pre-run runner record, completed
certification log, and separate accepted human-review receipt, then an explicit
maintainer closure decision (`ZL-202`).

## Reproduction

The required local gates are:

```sh
zig build verify-all
zig build hash-default-parity
zig build aarch64-hash-compile -Dtarget=aarch64-linux
zig build aarch64-hash-qemu-audit
zig build aarch64-hash-evidence-audit
zig build aarch64-hash-build-contract-audit
zig build aarch64-hash-review-audit
```

The QEMU contract audit above is host-only. When optional `qemu-aarch64`
contributor tooling is installed, reproduce the supplemental target-execution
rung separately:

```sh
zig build aarch64-hash-qemu
```

The command internally selects static Debug `aarch64-linux-musl` and runs the
root tests, manifest tests, and both exact hash fixtures with
`qemu-aarch64 -cpu max`. Its report must retain
`certification=false physical_machine_proof=false backlog_closed=false` and is
not an input to any step below.

Before the run, create the immutable runner identity/inventory record. Use
`python3 -B scripts/aarch64_hash_evidence.py runner-provenance-create` with the
actual record, its URI, runner ID, hardware model, recorder, explicit
`--claim-physical-non-emulated`, and durable output, then validate the exact
binding with `aarch64-hash-runner-preflight` as described in
[`evidence/README.md`](../evidence/README.md). The explicit claim is not machine
proof, and the attachment is not the not-yet-complete certification log. The
capture command must use Debug and the native target query, without a target
override, on the recorded AArch64 runner:

```sh
set -o pipefail
zig build aarch64-hash-certify -Doptimize=Debug \
  -Daarch64-evidence-out=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-provenance=/durable/path/runner-provenance.json \
  -Daarch64-runner-record=/durable/path/runner-record.json 2>&1 \
  | tee /durable/path/zlay-aarch64-hash-certification.log
```

Internally, a cache-managed `zlay.aarch64-runner-preflight.v1` first binds the
canonical provenance digest and exact runner-record URI, SHA-256, and byte count
under its own digest. A fresh pre-gate source snapshot also verifies live
`build.zig` against the SHA-256 embedded in the compiled build runner and
records every certification input. Every certification artifact compile
depends on both pre-gates. They are replaceable between invocations but their
generated bytes are immutable inputs within one certification DAG. The
PATH-independent Zig `uname` guard and
pinned-header gate then
precede certification-only `has_side_effects` executions of the manifest,
native suite, and exact 18-line / 426-byte C/Zig contract. Final
capture consumes the exact native and manifest stderr logs, requires contiguous
successful records and exact summaries, permits only the pinned x86-64-only
skip in the native suite and no manifest skip, and embeds both complete logs
with their counts, exact skip names, byte counts, and SHA-256 digests. Final
capture rejects any live input that differs from the snapshot before atomically
creating a new raw-v1 JSON file outside cache/output and system temporary
directories. It refuses overwrite and fsyncs the file and parent directory. The
record binds `runner_record`, `runner_preflight_sha256`, the passed
`runner_record_preflight` gate, `pre_gate_snapshot_sha256`, the passed
`pre_gate_source_snapshot` gate, current certification inputs, exact traces,
the strict-validated native/manifest test logs, the captured native-host line/digest, certification executables, toolchain,
target, runner facts, and the external provenance object. Final capture consumes
only the runner preflight, not the mutable provenance and record paths.

Validate and perform the required exact-byte repository import on any review
host against the same source inputs:

```sh
zig build aarch64-hash-evidence-validate \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json
zig build aarch64-hash-evidence-import \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-import-out=evidence/zl-202-aarch64-hash-evidence.json
```

Capture and import refuse overwrite, and import preserves the validated raw
bytes exactly. Validation and import both enforce pending review,
`physical_hardware_machine_verified=false`, and `backlog_closed=false`.

After the completed log exists, validate the exact pre-run runner record,
prepare the separate human statement from the evidence workflow, and create and
validate the receipt:

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

The completed log must contain the raw record's exact
`runner-provenance-valid ... physical_machine_proof=false backlog_closed=false`
marker, native-host guard trace, and
`evidence-captured sha256=<raw-file-sha256> provenance_review=pending backlog_closed=false`.
The separate statement's review timestamp cannot predate raw generation. The
receipt binds the raw bytes, runner record, completed log, current review
contract, and human attestations. Machine checks cannot rule out every
full-system emulator or authenticate the reviewer, and an accepted receipt
keeps automatic closure and `backlog_closed` false. No real imported raw record,
runner record, completed log, or receipt is checked in.

Run the audit-only pinned-C source coverage pass with:

```sh
zig build coverage-audit
```

Run the fail-closed certification contract with:

```sh
zig build clay-coverage-certify
```

The script compiles every `tests/oracle/*_fixture.c` with Clang source-coverage
instrumentation in the scalar/common profile, separately compiles the native
x86-64 SIMD fixture, runs the executables, and emits raw report/show/export
artifacts for `tests/oracle/clay.h`. Certification binds those artifacts to the
exact header, fixture list, source inventories, profile flags, reviewed
dispositions, and scoped SIMD ranges. Artifacts are written under a unique
`${TMPDIR:-/tmp}/zlay-clay-coverage.XXXXXX` directory. Default certification
removes that scratch after success or failure; direct invocation with
`--keep-artifacts` retains complete or partial output for inspection. Coverage
remains execution accountability rather than parity proof; differential
fixtures retain that role.

Host/pinned-source parity is declared only when `BACKLOG.md` has no open host
behavior or proof-integrity row and the complete verification matrix passes
against the unchanged pinned header; those conditions are now met. Closure of
the recorded AArch64 target extension additionally requires the real ZL-202
AArch64 raw record and its exact-byte repository import, exact runner record,
completed log, accepted validated receipt, and an explicit maintainer closure
decision. The
QEMU execution report is supplemental target-execution evidence only and cannot
substitute for any item in that physical non-emulated proof set.
