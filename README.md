# ZLAY

ZLAY is a renderer-agnostic, native Zig port of Nic Barker's
[Clay](https://github.com/nicbarker/clay). Production code is Zig-only,
dependency-free, and never imports or links the C implementation. It provides
layout, interaction state, scrolling, transitions, renderer-neutral commands,
a checked renderer dispatcher, fixed-buffer profiling, and the built-in
inspector.

## Status at a glance

| Surface | Status |
|---|---|
| Native x86-64 parity | Closed: all pinned public declarations are mapped, 25 ordinary traces are byte-identical and bit-exact, and reviewed divergences have executable contracts. |
| Pinned-source accountability | Closed for the host scalar/common profile and native x86-64 SIMD supplement through fail-closed line, function, and branch-direction accounting. |
| Physical AArch64 certification | Externally blocked: no qualifying runner or resulting artifact set is available in this checkout. |
| Rendering and fonts | Application-owned by design; ZLAY emits commands and optional paragraph leases but does not rasterize. |
| Maintained aggregate gate | `zig build verify-all` on Zig 0.16.0. |
| First release support scope | Verified native x86-64 Linux plus the maintained `wasm32-freestanding` compile and Node runtime smoke; AArch64 remains explicitly uncertified. |

Raw coverage remains separate from behavioral equivalence. Other OS, browser,
graphics-backend, and visual-output matrices remain outside the core proof.

The implementation is pinned to Clay commit
[`e6cc36941ab2af5d81107617039d6f527a1c660b`](https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b).
See [the upstream record](docs/UPSTREAM.md) and
[the parity contract](docs/PARITY.md) for the exact source boundary and proof
standard. Maintainers preparing a tag should follow the bounded
[release procedure](docs/RELEASE.md).

## UI and visual-output boundary

ZLAY owns layout and interaction behavior, not pixels. End-to-end visual UX is
therefore completed in the consuming renderer, font system, assets, and input
adapter. The library side supplies deterministic command order, clipping,
responsive sizing, pointer state, advanced paragraph transport, explicit
lifetimes, and checked failures so a backend can render that experience without
guessing at hidden state. No visual redesign is meaningful inside ZLAY without
choosing a concrete backend.

## Requirements and dependency setup

ZLAY currently requires Zig 0.16.0. Python 3.10 or newer is required by
repository audit, evidence, and review gates. Full repository verification also
requires Bash, Clang, `llvm-profdata`, `llvm-cov`, and ripgrep (`rg`). Node.js is required by `zig build check` for the freestanding-WebAssembly
runtime smoke. `qemu-aarch64` is optional contributor tooling for the
supplemental AArch64 user-mode execution lane. Library users need neither
runtime.
Until the package has a published source URL, add it as a path dependency in the
consumer's `build.zig.zon`:

```zig
.dependencies = .{
    .zlay = .{ .path = "../ZLAY" },
},
```

Then expose its module to the consumer executable in `build.zig`:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
const zlay_dep = b.dependency("zlay", .{
    .target = target,
    .optimize = optimize,
});

const app = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
app.root_module.addImport("zlay", zlay_dep.module("zlay"));
```

Application code can then use `const zlay = @import("zlay");`.

## Minimal layout

Text layout requires an application-supplied measurement callback because ZLAY
does not own fonts. This example is the same flow compiled by `zig build check`:

```zig
const std = @import("std");
const zlay = @import("zlay");

fn measureMonospace(text: zlay.StringSlice, config: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) *
            @as(f32, @floatFromInt(config.font_size)) * 0.6,
        .height = @floatFromInt(config.font_size),
    };
}

pub fn main() !void {
    var context = zlay.Context.init(
        std.heap.page_allocator,
        .{ .width = 800, .height = 600 },
        .{},
    );
    defer context.deinit();
    context.setMeasureTextFunction(measureMonospace, null);

    try context.beginLayout();
    try context.openElementWithId(context.id("panel"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .padding = zlay.padding(16),
            .child_gap = 12,
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 32, .g = 36, .b = 48, .a = 255 },
        .corner_radius = zlay.cornerRadius(8),
    });
    try context.textSlice("Native Zig layout", .{
        .font_size = 24,
        .text_color = .{ .r = 245, .g = 245, .b = 250, .a = 255 },
    });
    try context.closeElement();

    const commands = try context.endLayout(1.0 / 60.0);
    std.debug.print("ZLAY emitted {d} commands\n", .{commands.length});
}
```

Run the repository example with `zig build example`.

## Optional paragraph-provider integration

`Context.setParagraphProvider` stores one optional generic provider per
context; it defaults to `null`, and clearing it restores that exact state. The
existing Clay-compatible measurement callback, cache, wrapper, and text render
commands remain the only active path while no provider is installed. With a
provider installed, `Context.text` obtains intrinsic metrics from that provider
and the final-width pass creates one generation-bound paragraph lease per exact
text/style/width cache key without invoking the legacy measurement callback.

`ParagraphTextStyle` is a separate provider-facing style model. It retains a
32-bit font-stack ID, float size, signed/fractional letter and word spacing,
script/language/direction, OpenType features and variations, advanced line
height, word/grapheme/no wrapping, physical or logical alignment, overflow,
and line limits. `ParagraphTextStyle.fromLegacy` widens legacy values exactly. Use
`Context.textWithParagraphStyle` or `Context.textSliceWithParagraphStyle` for
direct advanced per-element styles; these methods fail closed unless a
paragraph provider is installed.

Provider paragraphs emit one existing `custom` render command. Call
`Context.paragraphRenderData(&command)` with a command borrowed from the current
array to resolve its typed `ParagraphRenderData`; copied and unrelated custom
commands are rejected without interpreting their opaque pointers. The command
pointer expires on the next Context mutation and may then alias reused storage.
The checked `renderer.consume`/`consumeArray` adapter preserves identity by
passing `.custom` backends the original `*const RenderCommand`. The lease
remains live through command consumption and is released exactly once on
the next frame, cache reset, provider replacement, failed frame, or context
destruction. Operational failures abort the provider path instead of mixing its
metrics with legacy wrapping. This proves the generic ZLAY integration seam,
not a concrete text-engine adapter or rendered glyph output.

## Frame lifecycle

Create one `Context` for each independent UI and keep it alive across frames.
At the start of a frame, update dimensions and pointer state, then advance
scrolling with the current input. Call `beginLayout`, declare a balanced tree
with `openElement*`, `text*`, and `closeElement`, and finish with
`endLayout(delta_time)`. Negative and non-finite frame deltas are normalized to
zero for Context transition progress. The scroll engine likewise accumulates
only positive finite drag sample time and suppresses release momentum when no
valid time sample exists; non-finite stored position or momentum is normalized
before an update. Layout distribution also exits safely when invalid dimensions
produce a non-finite or non-progressing amount.

`endLayout` returns a borrowed `RenderCommandArray`. Consume its commands in
array order before the next `beginLayout` or before destroying the context.
Read only the `render_data` field selected by `command_type`. A backend must
handle rectangles, borders, text, images, custom data, nested scissor
start/end, and overlay-color start/end commands. ZLAY deliberately does not
choose a graphics API.

Pointer hit testing and hover callbacks use geometry retained from the most
recent completed frame. Stable explicit IDs are therefore recommended for
interactive, queried, scrolled, or transitioned elements.
Application hover, transition, external-scroll, text-measurement, and diagnostic
callbacks may inspect context state, but frame/declaration/input mutation is
guarded: fallible methods return `CallbackReentryNotAllowed`, recursive pointer
sampling returns `PointerUpdateAlreadyActive`, and Clay-compatible `void`
mutators (including callback-time destruction) leave state unchanged until
called outside the callback. Pointer-over query slices are read-only, and the
Clay-shaped mutable scroll pointer refers to detached scratch while a callback
is active. Scroll storage is also value-snapshotted around every callback, so a
pointer borrowed before callback entry cannot mutate the committed position
from inside that callback. `renderCommand` likewise returns detached command
scratch during a callback, so inspection cannot alter a validated live stream.
The standalone text cache applies the same rule to recursive measurement,
reset, destruction, and topology retuning.

Clay's declaration macros open an element before evaluating its declaration.
When a declaration depends on `hovered()` or `getScrollOffset()`, use the split
primitive so Zig preserves that ordering:

```zig
try context.openElementWithIdUnconfigured(context.id("scroll-panel"));
const offset = context.getScrollOffset();
try context.configureOpenElement(.{
    .clip = .{ .vertical = true, .child_offset = offset },
});
// Children...
try context.closeElement();
```

For declarations that do not query the newly opened element, the combined
`openElement` and `openElementWithId` methods are the shorter equivalent.
`element` and `elementWithId` additionally provide scoped body callbacks that
restore the open stack if the body returns an error. Their `elementDeferred`
and `elementWithIdDeferred` counterparts invoke a declaration factory after
opening and therefore preserve query-sensitive evaluation order. Every scoped
form verifies the exact opened node, not only stack depth: a body that closes it
and opens a replacement receives `ScopedElementUnbalanced` and the replacement
is cleaned up. Unwinding past the helper's parent aborts the frame. If automatic
cleanup itself runs out of memory, the cleanup error wins and the current frame
is aborted allocation-free; the context can begin a new frame instead of
retaining a stale open stack.

## Fixed-buffer allocation

`Context` accepts any `std.mem.Allocator`, including a fixed buffer:

```zig
var memory: [2 * 1024 * 1024]u8 = undefined; // Illustrative; size for your workload.
var fixed = std.heap.FixedBufferAllocator.init(&memory);
var context = zlay.Context.init(
    fixed.allocator(),
    .{ .width = 800, .height = 600 },
    .{ .max_element_count = 2048 },
);
defer context.deinit();
```

There is no native equivalent of Clay's exact `Clay_MinMemorySize`. Array
lists, maps, persistent state, render commands, and measured text use the
supplied allocator. An undersized fixed buffer therefore returns
`error.OutOfMemory`; the 2 MiB value above is illustrative, not a guarantee.
Size from representative peak layouts with margin. Reusing one context retains
scratch and collection capacity across frames, but new peak structure, IDs,
scroll/transition state, or text can still allocate.

Allocator failure is transactional at the public pointer and frame-commit
boundaries. `setPointerState` changes no state and fires no callbacks unless its
complete hit set fits, and a hover callback that re-enters the method receives
`PointerUpdateAlreadyActive` without disturbing the outer update. Nested frame
or input mutation from every engine-owned application callback is blocked, so
callback source snapshots and cache free lists cannot be replaced
mid-iteration.
`beginLayout` snapshots persistent scroll and transition runtime state;
rejected or aborted frames restore it. Before transition callbacks run,
`endLayout` preflights final layout/render scratch, maximum wrapped-line and
command growth, exact distinct measurement-cache misses caused by mutable text
configuration, exit snapshots, and persistent-map storage. It then defers
external scroll queries until commit is infallible. A rejected frame therefore
fires neither transition callbacks nor external queries; a late OOM keeps the
last completed query, hit-test, scroll, and retained-transition surfaces and
hides partial render commands.

Text declaration and wrapping follow the same callback boundary: cache nodes,
tree storage, and worst-case bounded wrapped-line output are reserved before the
application measurement callback runs. Allocation or configured word-limit
failure therefore invokes no measurement callback and leaves the declaration
tree/output unchanged.

Element and positive render-command ceilings clamp to `maxInt(i32)`, the range
of the public array metadata. Render-command overflow still follows Clay's
reserved-final-slot rule, but `endLayout` rejects a truncated prefix if it
would leave scissor or overlay scopes unbalanced.

`zlay.profile.FixedBufferProfiler` wraps a fixed-buffer allocator and reports
current bytes, peak bytes, allocation attempts, failures, and remaining
headroom. Run `zig build profile` for a repeatable example that warms eight
frames and verifies an unchanged high-water mark over another 64 frames. This
is a workload profiler, not a `Clay_MinMemorySize` equivalent.

## Verification and current limits

The 2026-07-31 refresh reran the C-free `zig build check --summary all` gate:
26/26 steps and 210/210 combined tests pass on Zig 0.16.0. No source-owned
backlog row is actionable; ZL-202 still requires evidence from physical,
non-emulated AArch64 hardware and must not be closed by local code or QEMU.

`zig build verify` is the complete local gate for the selected optimization
mode; `zig build verify-all` runs it sequentially in Debug and ReleaseSafe,
then runs the C-free native/WebAssembly check in ReleaseFast and ReleaseSmall
and certifies accountable pinned-Clay source coverage.
It format-checks the Zig sources, runs the native suite, compiles the examples and
`wasm32-freestanding` library target, executes the same renderer smoke natively
and through Node's WebAssembly runtime, verifies the pinned `clay.h` digest,
and compares deterministic Zig fixture output with executables built from the
pinned C oracle. Every ordinary pair is identity/count/digest pinned, and the
gate also executes the ordinary-manifest self-tests, verifies the parsed public
declaration manifest, and checks reviewed scroll, duplicate-ID, checked-access,
capacity, render-scope capacity, malformed-stack, floating-clip, invalid-slice,
retained/two-context, and no-open API lifecycle divergences. The target-default
hash identity selects separate exact x86-64 and AArch64 contracts and rejects
unrecorded targets.
Malformed public `String` lengths are also regression-tested across all four
optimization modes: nonpositive lengths hash empty, while positive overlong
lengths are clamped to the available bytes.
Native regressions also cover scoped-cleanup OOM recovery, atomic duplicate-ID
debug bookkeeping, and signed public-capacity metadata. The fail-closed raw
AArch64 evidence, certification-DAG, and review-receipt contracts are also
mutation-tested. Public render-capacity metadata now compares exactly. `zig
build check` is the C-free compile/test/example gate; `zig build renderer-smoke`,
`zig build consumer-smoke`, `zig build wasm-runtime-smoke`, and
`zig build profile` expose the focused runtime checks. `zig build
coverage-audit` emits and retains the unmodified raw LLVM report and detailed
artifacts; `zig build clay-coverage-certify` additionally requires every uncovered
line/function/branch direction to match the SHA-pinned, exact-coordinate
review manifest and rejects stale dispositions or fixture-inventory drift. On
the current toolchain the scalar/common raw report is 3,076/3,083 lines,
107/107 source-level functions, 1,698/1,716 branches, and 3,495/3,500 regions.
After the seven exact line dispositions and eighteen exact branch-direction
dispositions, accountable coverage is 3,322/3,322 mapped physical lines,
107/107 function definitions, and 2,446/2,446 emitted branch-record directions.
The active x86-64 SIMD supplement separately requires 62/62 mapped lines, 4/4
functions, and 14/14 branch-record directions. A source-level function is
covered when at least one emitted translation-unit instance executes; this does
not claim that every duplicate static-inline copy executes. Certification
scratch artifacts are removed after a successful run; invoke
`bash scripts/audit_clay_coverage.sh --certify --keep-artifacts` when the detailed
certification files, including partial failure artifacts, need to be retained
for inspection.

Contributors with `qemu-aarch64` on `PATH` can run the supplemental execution
lane, while its mutation audit is host-only and does not require QEMU:

```sh
zig build aarch64-hash-qemu
zig build aarch64-hash-qemu-audit
```

`aarch64-hash-qemu` internally pins static Debug `aarch64-linux-musl` artifacts
and runs the root module tests, ordinary-manifest tests, and exact C/Zig
target-default hash trace through `qemu-aarch64 -cpu max`. Its runtime report
binds the QEMU and Zig identities, target/source contract, four executed
artifacts, and trace identity, and always ends with
`certification=false physical_machine_proof=false backlog_closed=false`.
`aarch64-hash-qemu-audit` mutation-tests that wiring and proof separation on the
host. This optional rung is entirely outside raw-v1 capture, runner provenance,
repository import, human review, and certification; it cannot close ZL-202 or
replace execution on physical non-emulated AArch64 hardware.

The 2026-07-31 current-source refresh passes 16/16 QEMU lane steps, 205/206
module tests with the one exact x86-only skip, 4/4 manifest tests, and the
unchanged 18-line / 426-byte trace SHA-256
`68b1ce5dfef146735d34889f337fa3f73a597b0511a5fc511f9e399d263dc787`.
The complete non-certifying identity record is retained in
`.overzeer/aarch64-qemu-smoke.md`.

The bounded ZL-202 workflow is:

```sh
zig build hash-default-parity
zig build aarch64-hash-compile -Dtarget=aarch64-linux
zig build aarch64-hash-evidence-audit
zig build aarch64-hash-build-contract-audit
zig build aarch64-hash-review-audit

# Before the physical run, create the immutable runner identity/inventory file,
# then create non-overwriting provenance from its actual bytes.
python3 -B scripts/aarch64_hash_evidence.py runner-provenance-create \
  --runner-record=/durable/path/runner-record.json \
  --runner-record-uri=file:///durable/path/runner-record.json \
  --runner-id='<stable runner identity>' \
  --hardware-model='<physical machine model>' \
  --recorded-by='<operator or CI identity>' \
  --claim-physical-non-emulated \
  --output=/durable/path/runner-provenance.json
zig build aarch64-hash-runner-preflight \
  -Daarch64-provenance=/durable/path/runner-provenance.json \
  -Daarch64-runner-record=/durable/path/runner-record.json

# On recorded, non-emulated AArch64 hardware only, in Debug with no target override:
set -o pipefail
zig build aarch64-hash-certify -Doptimize=Debug \
  -Daarch64-evidence-out=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-provenance=/durable/path/runner-provenance.json \
  -Daarch64-runner-record=/durable/path/runner-record.json 2>&1 \
  | tee /durable/path/zlay-aarch64-hash-certification.log

# On any review host; exact-byte repository import is required for closure:
zig build aarch64-hash-evidence-validate \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json
zig build aarch64-hash-evidence-import \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-import-out=evidence/zl-202-aarch64-hash-evidence.json
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

Certification v1 requires Debug, Zig's native target query on an AArch64 build
host, and all three `-Daarch64-evidence-out`, `-Daarch64-provenance`, and
`-Daarch64-runner-record` paths. Before any certification artifact compiles, it
generates a cache-managed
`zlay.aarch64-runner-preflight.v1` from the exact runner-record bytes and
canonical provenance. The preflight binds the record URI, SHA-256, byte count,
and its own canonical digest. Both cache-managed pre-gates may be replaced by a
later invocation, but their generated bytes are immutable inputs within one
certification DAG; every compilation depends on them, and final capture
consumes only that DAG's preflight rather than the mutable originals. The fresh
source snapshot also verifies live `build.zig` against the SHA-256
embedded when the build runner was compiled and records every certification
input, including every recursively discovered `src/**/*.zig` file. Every
certification artifact compilation depends on that snapshot, and
final capture rejects any live input that no longer matches it. The raw record
binds `runner_record`, `runner_preflight_sha256`, the passed
`runner_record_preflight` gate, `pre_gate_snapshot_sha256`, and the passed
`pre_gate_source_snapshot` gate. A
PATH-independent Zig executable then checks `uname` and the 64-bit userspace
before the pinned-header gate; certification-only `has_side_effects` executions
fresh-run the ordinary manifest, native suite, and architecture-selected
18-line C/Zig trace. Their exact Zig stderr logs are captured into the final
writer, strictly re-parsed for contiguous records and matching success
summaries, and embedded with byte counts, SHA-256 digests, pass/skip counts, and
exact skip names. The native suite permits only the pinned x86-64-only oracle
skip; the manifest suite permits none. The raw record includes those logs and
the exact captured native-host line and its digest.

The source snapshot and final equality check detect ordinary drift that remains
present at either check. Certification artifacts still compile from the live
checkout rather than an immutable staged copy, so an adversarial source
change-and-restore between the checks (an ABA race) is not independently
excluded. The workflow is not complete source-to-binary or adversarial TOCTOU
proof. The supplemental QEMU lane's precheck/final source identity has the same
limitation, in addition to remaining explicitly non-certifying.
`aarch64-hash-build-contract-audit` mutation-tests the runner
preflight, source snapshot, their compilation dependencies, preflight-only
capture input, test-log captures/bindings, guard, ordering, fresh-run flags, CLI bindings, and exclusive
final writer.

Only the final Python capture runs after every gate and atomically creates a new
raw-v1 JSON file outside cache/output and system temporary directories. It
refuses overwrite and fsyncs both the file and parent directory. The required
repository import first validates and then preserves the original raw bytes
exactly. The record also
binds current certification source inputs, exact traces, certification
executables, the exact validated native and manifest test logs, Zig toolchain,
target, runner facts, the pre-run provenance object,
and the preflight-derived runner-record binding and digest. See
[the evidence workflow](evidence/README.md) for the provenance shape.

The provenance attachment must be an immutable runner identity/inventory record
that exists before certification; it cannot circularly contain the completed
log. After the run, the any-host review flow validates that runner record's
actual digest, requires the completed log's exact `runner-provenance-valid ...
physical_machine_proof=false backlog_closed=false` preflight marker,
native-host trace, and `evidence-captured` marker, and binds a separate human
statement whose review timestamp cannot predate raw generation into a
non-overwriting
`zlay.aarch64-hash-review-receipt.v1` receipt. Even an accepted receipt remains
human-attested: reviewer identity is unauthenticated, physical hardware is not
machine-verified, automatic closure is false, and `backlog_closed=false`.
Evidence/review inputs are size-bounded, future-dated records fail closed, and
durable outputs reject Zig caches plus standard temporary/runtime roots.
No real imported raw record, runner record, completed log, or receipt is
checked in, so ZL-202 remains externally blocked rather than failed or closed.
Cross-compilation is a prerequisite and QEMU user-mode execution is supplemental
target execution; neither is physical non-emulated certification evidence.

The native suite includes linear root-driven arbitrary-order height propagation,
a declaration-order fast path across both 50,000 nested elements and 50,000
siblings, a 20,000-sibling reverse-index tree, malformed-forest rejection, deep
iterative rendering, dimension-atomic malformed-forest failure, checked cache
reservation arithmetic, exact/deduplicated transition cache preflight,
callback-safe query views, callback reentrancy/rollback regressions, and a
multiframe live-inspector interaction test. It also covers signed-length
constructor clamps, bounded border-width extrapolation, invalid frame/drag
time, normalized stored scroll state, non-progressing/non-finite layout
distribution, duplicate-ID retained exits, detached callback command queries,
preborrowed scroll-pointer isolation, exact scoped-node identity, transactional
inspector interaction, stale selection and malformed public layout-helper
safety, later-duplicate transition suppression, concrete full text-cache hash
collisions, and non-finite or out-of-range inspector input. The compiled-C matrix covers
basic and complex layout; constrained sizing, compression, aspect ratio, every
text wrap mode, spacing, alignment, culling, and resize; all render command
kinds and active payloads; global/indexed/local/automatic IDs, bucket
collisions, diagnostics, lookup, and normalized capacity; ordinary and
external/nested scrolling; all 81 floating attach-point pairs plus clip,
external-scroll, z-order, capture, and pointer-boundary cases; and a dense
enter/change/retained-exit transition matrix across every observable property,
trigger, reparenting, sibling order, retained text, resize, zero duration, and
interaction policy. A 110-line string/text fixture covers callback lifecycle,
cache reset, whitespace/newlines, metadata, and retained text; an independent
20-line trace exercises stale cache generations, both free lists, and
declaration-time preferred metrics across a mid-frame reset. An
11-line trace covers aspect sizing in both directions and horizontal
drag/stationary/release/momentum behavior. A 100-line transition-lifecycle trace
covers handler pruning/restoration, disappearance/reappearance, repeated
reparenting, and nested exiting-tree removal, while a 733-line inspector
fixture covers exact selected layout/text/configuration payloads,
injected warning storage, scroll, highlight, collapse, close, and width
restoration. A 122-line declaration/layout fixture covers nested axes,
constraints, compression, padding, gaps, alignment, ID forms, and prior-frame
queries; a 16-line API/diagnostics fixture covers public settings and exact
ordinary error payload metadata. The maintained matrix is the project's
auditable behavioral contract; it does not claim a formal proof over every
possible user input.

The focused review is recorded in
[the Clay-to-ZLAY parity audit](docs/CLAY_ZLAY_PARITY_AUDIT.md). Important
boundaries are:

- The parsed public manifest mechanically inventories and maps 45 aggregate or
  opaque types, 19 enums, 7 callbacks, 34 declared public functions, 1
  implementation-only exported function, 8 macro-support functions, 26 macros,
  and 3 globals. The exhaustive public-values trace separately locks all 86 enum
  values, defaults, helpers, ID metadata, and globals; aggregate fields remain
  a value/behavior contract, and neither gate claims C ABI layout compatibility.
- Pinned C retains a pointer into ephemeral layout storage for each scroll
  container. If an omitted container's slot is immediately reused by a new ID,
  C aliases replacement geometry and skips a swap-removed update. ZLAY keeps
  ID/value-owned state and intentionally does not reproduce that stale-pointer
  bug; `zig build reviewed-divergences` locks both observed traces.
- Pinned C lets a later duplicate render write through the first ID-map entry;
  ZLAY reports the duplicate but preserves the first declared query bounds.
  Checked command access and element/text capacity failure also use explicit
  native contracts; those differences are trace-digest protected.
- Pinned C can return a render-capacity prefix whose final scissor or overlay
  scope is left open. ZLAY returns `RenderCommandCapacityExceeded`, closes the
  frame, clears the rejected command prefix, retains the last committed hit
  data, and never exposes that invalid stream; both outputs are digest-pinned.
- Scoped helper cleanup OOM aborts the current frame instead of hiding the
  cleanup failure behind the body error. Rejected frames restore the last
  committed transition and scroll state, invoke no deferred external-scroll
  query, reserve exact distinct final-pass text-cache misses, and validate
  transition render scopes before invoking callbacks. Pointer mutation and late
  frame commit are failure-atomic; hover, transition, external-scroll,
  measurement, and diagnostic reentry is guarded; pointer-over queries are
  read-only, callback-time scroll/command pointers are detached, and scroll
  values are restored over aliases borrowed before callback entry; duplicate-ID
  debug bookkeeping is preflighted before tree or text mutation; retained and
  transitioning duplicate IDs preserve the first declaration; later duplicates
  own no ID-keyed hits, and exact node indexes keep duplicate clip/floating
  ancestry spatially correct; percentage/missing-parent diagnostics wait until
  declaration preflight succeeds; scoped helpers retain exact node identity;
  inspector interaction commits only with its frame; and public capacities
  clamp to signed metadata range.
- Clay's text cache treats a 32-bit hash as full identity. ZLAY retains that
  hash for bucket selection but verifies dynamic text with SHA-256 plus length
  and measurement configuration (and static text with the complete pointer,
  declared length, and safely accessible slice length),
  preventing real full-hash collisions from reusing unrelated metrics or word
  offsets.
- Public `String` values retain Clay-compatible signed length metadata, but all
  slice constructors clamp lengths above `maxInt(i32)` and all byte-reading hash
  entry points use the safe public slice view. Nonpositive lengths hash empty
  and positive lengths beyond `chars.len` are clamped; the four-mode regressions
  keep valid hashes and APIs unchanged.
- Pinned Clay can divide drag release distance by zero elapsed time and relies
  on undefined out-of-range float-to-integer conversions in transition and
  inspector edges. ZLAY suppresses invalid momentum, bounds border widths,
  normalizes Context transition deltas and stored scroll state, rejects invalid
  inspector rows, prevents invalid layout distribution from spinning, and
  keeps the inspector panes within narrow or short viewports.
- Pinned Clay can leak a clip-stack entry when one element is both floating and
  clipping, can leave deeply unbalanced declaration stacks malformed, and can
  form a negative-length wrapped slice. ZLAY keeps safe behavior; exact
  non-equal traces and following-frame recovery are digest-pinned by
  `reviewed-divergences`.
- Clay's process-global current context is normalized to explicit Zig context
  instances by a 72-line retained-state matrix. Its exact callback-owner records
  pin both Clay process-global callback functions—text measurement and external
  scroll query—plus per-context data against ZLAY's context-owned function/data
  pairs. The same matrix pins Clay's process-global debug width/color against
  ZLAY's deliberately per-context debug settings. A separate reviewed trace
  pins Clay's pre-frame/after-frame sentinel behavior against ZLAY's checked
  `NoOpenElement` contract and proves exact following-frame recovery.
- All observable ordinary fixture floats use exact IEEE-754 bit serialization;
  unexpected diagnostics and bounded-log overflow fail the gate. The sole open
  certification row is real AArch64 execution of target-default hashing. The
  x86-64 trace passes, the predicted AArch64 trace is separately digest-pinned,
  portable vectors and scalar fallback pass, the guarded AArch64 fixtures and
  tests cross-compile, the optional static Debug QEMU lane runs the AArch64 root
  tests, manifest tests, and exact C/Zig trace with explicitly non-certifying
  output, and the raw evidence workflow is fail-closed; none substitutes for
  the physical run and human provenance review.
- Enter/change/exit transitions, floating attachment, and pointer behavior are
  differentially verified across their current dense matrices. This includes
  Clay's declaration-order runtime array, swap-remove completion timing, and
  root-sticky transition interaction suppression.
- The allocator model is native Zig rather than Clay's byte-exact arena and
  minimum-memory calculation.
- The package includes an allocation-free command dispatcher and deterministic
  native/WebAssembly runtime smoke. It does not choose or bundle a concrete
  graphics API, font rasterizer, image decoder, or broad OS/browser matrix.

See [API.md](docs/API.md) for the callable surface,
[ARCHITECTURE.md](docs/ARCHITECTURE.md) for ownership and pipeline details, and
[BACKLOG.md](BACKLOG.md) for the remaining cross-target evidence work.

ZLAY retains Clay's zlib/libpng license. See [LICENSE.md](LICENSE.md) and
[NOTICE.md](NOTICE.md).
