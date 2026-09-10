# Changelog

All notable changes to ZLAY are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Expanded the additive retained solver with content-hugging containers,
  direction-aware grids, implicit tracks, sparse/dense row/column auto-flow,
  explicit and intrinsic grid-item sizing, logical cell alignment, grid auto
  margins, intrinsic content-sizing keywords, and an external `RetainedStore`
  solver bridge.
- Added pinned Taffy and Morphorm overlap fixtures for flex distribution,
  implicit and intrinsic-auto grids, and dirty-layout equivalence.
- Added reverse row/column flex axes, flow-neutral relative inset offsets,
  fixed/percentage responsive padding and margins, and bounded negative fixed
  gaps.
- Added retained-layout regression coverage for relative offsets in grid and
  overlay containers.
- Added allocation-free retained-node hit testing that respects computed
  ancestry clips and returns the deepest matching node.
- Retained hit testing now supports explicit per-node priority for overlapping
  game controls and editor targets.
- Retained children now support stable integer `order` sorting before layout;
  equal orders preserve insertion order.
- Equal-priority overlapping targets now follow computed visual order during
  hit testing.
- Added retained hit-test behavior modes for enabled, children-only, and
  disabled nodes.

### Changed

- `computeDirty` now skips stable subtrees only while their cached layout inputs
  remain unchanged, and bounded retained-tree destruction no longer recurses.
- Absolute children now derive auto dimensions from opposing physical insets
  and distribute remaining positioned space through auto margins. Absolute and
  overlay children honor intrinsic sizing tiers consistently with flex and
  grid children.
- Auto-sized grids now include implicit tracks and fixed or measured child
  contributions to intrinsic-auto tracks. Grid items with cached intrinsic
  data retain their explicit dimensions.
- `StoreSolver` now preserves synchronized styles and topology across computes,
  rebuilds only changed parent lists, performs dirty-subtree layout, and writes
  results through one bounded subtree traversal. `NodeRecord.style_revision`
  makes store API mutations explicit, and `lastSyncStats` exposes the work
  performed by each compute.

## [0.1.0] - 2026-08-02

### Added

- Greenfield Zig 0.16 package and dependency-free `zlay` module definition.
- Preserved Clay zlib/libpng license and an explicit altered-port attribution
  notice.
- Exact upstream commit/header pin, parity matrix, proof-oriented backlog,
  archive, reference-port review, and contribution workflow.
- Native public data model for the pinned Clay configuration, transition,
  interaction, error, and render-command surface.
- Allocator-owned `Context` lifecycle with independent contexts, bounded element,
  render-command, and measured-word policies, fixed-buffer support, and
  rollback-safe fallible declaration operations.
- Target-compatible element, data, and text-cache hashing with pinned scalar,
  x86-64, and AArch64 vectors plus dynamic, compile-time, indexed, and local ID
  helpers.
- Declarative hierarchy construction; FIT, GROW, FIXED, and PERCENT sizing;
  min/max constraints; both layout axes; padding; gaps; alignment; aspect
  ratios; floating attachment; clipping inheritance; and stable z ordering.
- Text measurement caching, word/newline/no-wrap modes, line height, letter
  spacing, alignment, and one render command per non-empty wrapped line.
- Context-local optional generic paragraph-provider registration with a `null`
  default, plus a provider-facing style model that retains full font-stack
  identity, float/signed tracking, script/language/direction, features,
  variations, advanced line height, wrap/alignment/overflow, and line limits
  without legacy narrowing. `Context.textWithParagraphStyle` exposes those
  advanced fields directly while the legacy path remains lossless. The
  provider boundary validates style, intrinsic, and final-width results,
  caches one lease per exact text/style/width key,
  transports it through existing custom commands with a current-array resolver,
  rejects copied/stale custom commands, fails closed without legacy mixing, and
  releases leases on every frame/reset/replacement/failure/destruction path.
- Rectangle, border, between-child border, text, image, custom, scissor,
  overlay, culling, and renderer-neutral command generation.
- Native built-in debug inspector declaration with tree rows, badges, warnings
  and selected-element panes, persistent selection/collapse state, element
  highlight, scrolling, close control, configurable width/color, and live
  `endLayout` integration.
- Allocation-free renderer command validation/dispatch with balanced independent
  scissor and overlay scopes, active-union payload routing, and command
  statistics.
- Fixed-buffer allocation profiler with current/peak bytes, allocation/failure
  counts, headroom, reset support, and a repeatable warmed high-water example.
- Deterministic native and Node-executed `wasm32-freestanding` renderer smokes
  that consume the same real 14-command frame and return `0x5a1a110e`.
- A maintained path-dependency consumer that compiles the documented package
  wiring and dispatches a real frame through a backend declared outside ZLAY.
- A read-only GitHub Actions check, security policy, and tailored source-of-
  truth, memory, roadmap, release-boundary, and proof documentation.
- A release procedure and isolated archive-URL consumer smoke, leaving only the
  owner-selected hosted URL, immutable tag, and publication proof outside the
  local checkout. The first release scope is native x86-64 Linux plus the
  maintained freestanding-WebAssembly lanes; AArch64 certification remains
  separate tracked work.
- A dependency-free mock paragraph-provider example covering advanced style,
  final-width layout, typed render transport, and asynchronous lease ownership.
- An opt-in inspector accessibility theme with higher-contrast secondary text
  plus larger text, rows, and tree/close controls while preserving exact
  default output.
- Renderer-neutral inspector previous/next/toggle/close actions for application-
  mapped keyboard, gamepad, switch, or remote input, including internal
  selection reveal and rejected-frame retry.
- A read-only inspector state summary for assistive, remote-control, and
  external-scroll adapters.
- A read-only manual and weekly GitHub Actions workflow for the complete
  `verify-all` matrix, separate from the faster push/pull-request check.
- Retained element queries, prior-frame pointer hit testing, hover callbacks,
  floating-root capture, internal/external scrolling, drag momentum, and nested
  scroll priority.
- Enter, ordinary target-change, and retained exit transitions with trigger
  policy, reparenting, sibling ordering, text rewrap, interaction suppression,
  and upstream callback timing.
- Split open/configure primitives for Clay-compatible declaration evaluation
  order plus scoped immediate and deferred-declaration Zig helpers.
- Linear root-driven arbitrary-order layout-height traversal with a
  declaration-order fast path, public 50,000-element deep-chain,
  50,000-sibling declaration-order, and 20,000-sibling reverse-index
  regressions, malformed-forest rejection, plus iterative deep render-tree
  traversal.
- Test-only compiled-C differential fixtures for basic and complex layout,
  dense sizing/text and render-command matrices, ID/error/collision and
  normalized-capacity cases, a 53-line transition trace, a 322-line complete
  transition-property/trigger/order matrix, a 100-line transition lifecycle
  matrix, a 225-line all-attachment floating/pointer edge matrix, a 110-line
  string/text callback/cache matrix, a 20-line text-cache lifecycle matrix
  covering stale/free-list reuse and reset timing, a 3-line text-cache
  runtime-topology matrix, a 122-line
  declaration/layout matrix, an 11-line
  bidirectional-aspect/horizontal-scroll matrix, a 16-line public
  API/diagnostics matrix, ordinary plus external/nested scrolling, and a
  733-line live-inspector interaction/configuration/warning trace, all pinned
  by the upstream header SHA-256.
- Digest-pinned C and Zig scroll lifecycle traces documenting the intentional
  native fix for Clay's stale ephemeral-layout pointer during container
  replacement and swap-remove pruning.
- Digest-pinned duplicate lookup, checked command access, element capacity, and
  text capacity traces documenting native safety/error contracts, plus an exact
  public-metadata/render-capacity comparison.
- Digest-pinned render-scope capacity traces documenting pinned C's unbalanced
  overflow prefix and ZLAY's checked `RenderCommandCapacityExceeded` frame
  rejection.
- Digest-pinned retained-query/two-context and invalid no-open API traces that
  normalize explicit Zig contexts, process-global-C versus per-context-Zig
  ownership for both callback function families and debug globals, and checked
  lifecycle errors while requiring exact equality for every other retained-state
  and recovery record. The retained trace is 72 lines: C is 4,983 bytes / SHA-256
  `dc7c359c...047300`, and Zig is 4,978 bytes / SHA-256 `5e3e3214...812b0`.
- A header-validated facade ledger for every recorded pinned public type,
  callback, public and implementation-only function, macro-support function,
  public macro, and debug global mapping.
- A parsed public-API manifest that fails when the pinned header gains or loses
  a type, enum, callback, declared or implementation-only function, support
  function, macro, or global without an explicit ZLAY mapping, with mutation
  tests for omission detection. Commented-out facade entries and the root
  `Context` export cannot satisfy the ledger, and duplicate manifest metadata
  fails closed.
- A SHA-pinned `clay-coverage-certify` contract over the exact host Clang/C99
  scalar/common fixture inventory plus a separately mapped native x86-64 SIMD
  supplement. It reports raw LLVM metrics separately while requiring 100% of
  in-scope executable lines, source-level functions, and emitted branch-record
  directions to execute; exact reviewed mapping/invariant coordinates are
  fail-closed, and mixed mappings, stale exclusions, or fixture drift fail the
  build. The current scalar/common result accounts for 3,322/3,322 mapped
  physical lines, 107/107 source definitions, and 2,446/2,446 branch-record
  directions; the scoped x86-64 SIMD result is 62/62 lines, 4/4 functions, and
  14/14 branch-record directions. Its JSON reader rejects duplicate keys,
  non-finite values, and pathological numeric tokens, LLVM source ranges must
  be ordered, and certification scratch artifacts are removed after success
  or failure unless explicitly retained.
- Exact identity/line/byte/SHA-256 contracts for all 25 ordinary equality
  fixtures, in addition to byte-for-byte C/Zig comparison.
- Architecture-keyed x86-64/AArch64 contracts for the target-default hash
  identity, build-wired manifest self-tests, focused `hash-default-parity` and
  `aarch64-hash-compile` lanes, and a Debug-only, native-target-query
  `aarch64-hash-certify` lane. The lane captures the fresh PATH-independent Zig
  host-guard line and digest, and protects the complete build DAG with a
  mutation audit. A fresh pre-gate input snapshot verifies live `build.zig`
  against a build-embedded SHA-256, gates every certification artifact compile,
  and is rechecked against live inputs at final capture to detect ordinary
  concurrent source drift. Because compilation still reads the live checkout,
  an adversarial change-and-restore between those checks remains outside this
  proof boundary. Final capture now also consumes the exact stderr logs from the
  fresh native and ordinary-manifest Zig test runs, strictly re-parses their
  complete numbering and success summaries, allows only the one architecture-
  inapplicable x86-64 oracle test to skip in the native suite and no manifest
  skips, and embeds each log plus its SHA-256, byte count, counts, and exact skip
  names in the canonical execution record.
- An optional `zig build aarch64-hash-qemu` contributor lane that executes internally
  pinned static Debug `aarch64-linux-musl` root tests, manifest tests, and the
  exact C/Zig target-default hash trace with `qemu-aarch64 -cpu max`, plus a
  host-only `zig build aarch64-hash-qemu-audit` mutation gate. The runtime report binds
  QEMU/Zig, source, artifact, target, and trace identities while fixing
  `certification=false`, `physical_machine_proof=false`, and
  `backlog_closed=false`; the lane has no raw-v1, provenance, import, review, or
  certification integration and does not satisfy ZL-202.
- A non-overwriting `runner-provenance-create` workflow bound to the actual
  runner-record bytes, plus local `aarch64-hash-runner-preflight` validation.
  Certification now requires the evidence-output, provenance, and runner-record
  paths and, before any artifact compilation, creates a cache-managed
  `zlay.aarch64-runner-preflight.v1`. Every compilation depends on its canonical
  provenance digest and exact record URI/SHA-256/byte-count binding; final
  capture consumes only that preflight rather than the mutable originals.
- A fail-closed raw AArch64 hash execution-record v1 contract with
  current-source, exact native-test logs, exact-trace, executable, toolchain, target, runner, and
  external-provenance binding, including `runner_record`,
  `runner_preflight_sha256`, the passed `runner_record_preflight` gate,
  `pre_gate_snapshot_sha256`, and the `pre_gate_source_snapshot` gate;
  file-and-parent-fsynced atomic
  non-overwriting capture outside cache/output and system temporary directories;
  and any-host validation plus exact-byte import that preserves pending,
  non-closing state.
- An any-host AArch64 provenance-review workflow that digest-validates the
  pre-run immutable runner identity/inventory record, binds the completed
  certification log's exact runner-preflight, native-host, and raw-capture
  markers, consumes a separate time-ordered human review statement, and creates
  or validates a non-overwriting `zlay.aarch64-hash-review-receipt.v1`.
  Accepted receipts
  remain human-attested: reviewer identity is unauthenticated, physical
  hardware is not machine-verified, and automatic/backlog closure stays false.
- Bounded evidence/review JSON, attachment, runner-record, and source-contract
  reads with an aggregate source ceiling; strict absolute-URI schema patterns,
  future-clock rejection, exact standalone log-marker validation, and durable-
  output rejection across Zig caches plus standard system temporary/runtime
  roots.
- Digest-pinned malformed-stack, floating-plus-clip, and invalid wrapped-slice
  safety traces with explicit next-frame recovery on both sides.
- `verify-all`, `public-api-audit`, `production-c-free`, `coverage-audit`, and
  `clay-coverage-certify` build targets plus the durable Clay-to-ZLAY parity
  audit report.
- Native OOM, capacity, fixed-buffer reuse, duplicate-ID, clipping, pointer,
  scrolling, transition, retained-exit, and command regressions.
- Compile/run basic example and a `wasm32-freestanding` compile gate.

### Changed

- Refreshed local verification on 2026-08-02: the C-free check passes 28/28
  steps and 214/214 combined tests. ZL-202 remains honestly blocked on physical
  non-emulated AArch64 evidence; no substitute implementation was added.
- Clarified that repository tooling requires Python 3.10 or newer, exact-byte
  evidence import is mandatory for ZL-202 closure, and cache-managed runner
  preflight/source-snapshot bytes are immutable within one certification DAG
  but replaceable by a later invocation.
- Replaced C macro-only configuration concepts with typed Zig constructors while
  retaining the low-level open/configure/close lifecycle as the parity contract.
- Replaced Clay's process-global current context and byte-partitioned arena with
  explicit allocator-owned native Zig state; the exact arena/minimum-size model
  remains an intentional documented divergence.
- Removed the inert duplicate `types.layout_default` value; the root
  `layout_default` pointer is now the sole public spelling and always addresses
  the shared mutable storage used by layout.
- Made caller-facing mutation failures explicit Zig errors while retaining
  once-per-frame Clay-style diagnostics through `ErrorHandler`.
- Made public pointer/render array capacities report configured capacities
  rather than allocator reservation growth; render insertion now reserves the
  final slot exactly like pinned Clay.
- Clamped element and positive render-command ceilings to `maxInt(i32)`, keeping
  every public signed capacity conversion defined.
- Made `zig build test` include the parsed public-API manifest and its mutation
  tests, matching the public-surface protection already required by `check`.

### Fixed

- Preserved borrowed custom-command identity through the checked renderer
  dispatcher, allowing font backends to resolve generation-bound paragraph
  handles with `Context.paragraphRenderData` instead of receiving an
  unresolvable command copy. Paragraph resolution now validates exact command
  and cache-entry addresses in constant time instead of linearly rescanning
  both arrays for every rendered paragraph.
- Replaced quadratic paragraph intrinsic/final-width cache scans with
  collision-resistant content/style keys and context-owned hash maps, while
  reserving possible post-transition entries before application callbacks.
- Replaced the stable quadratic floating-root z-order pass with Zig's stable
  `std.mem.sort` and bounded the iterative height walk explicitly.
- Clamped the built-in inspector to narrow viewports and reduced its details
  pane on short viewports, preserving usable list space and non-negative render
  geometry without changing ordinary 400-by-300 inspector output.
- Refreshed the non-certifying AArch64 QEMU lane on current sources: 16/16
  steps, 209/210 module tests with the exact x86-only skip, 4/4 manifest tests,
  and unchanged 18-line C/Zig target-default hash parity.
- Isolated nested `verify-all` mode builds in distinct local caches, eliminating
  a reproduced shared-cache race that could remove native and WebAssembly smoke
  artifacts before execution.
- Renamed proof-tool scratch variables and messages so full ZLAY-owned Craft
  scanning is clean without changing behavior or the pinned external oracle.
- Rejected paragraph providers whose intrinsic baselines are reversed or whose
  logical width/height advances are negative before those metrics can become
  layout or render geometry.
- Moved the native renderer/profile examples' 1 MiB fixed-buffer arenas out of
  platform-default stacks, and covered every renderer scope/array-metadata
  rejection plus the no-backend-mutation guarantee.
- Preserved the second float written through Clay's sizing union during
  aspect-ratio/percent-height propagation without reading an inactive Zig union
  member, eliminating a safety-mode crash while retaining the pinned result.
- Made runtime `setMaxMeasureTextCacheWordCount` changes update the active text
  hash-bucket divisor like pinned Clay, while retaining initialization-time
  storage and safely clamping the upstream modulo-zero/out-of-bounds cases.
- Preserved declaration-time preferred text dimensions when the measurement
  cache is reset before final layout, matching the expanded exact C/Zig
  lifecycle trace even if callback metrics change after declaration.
- Prevented standalone measurement callbacks from retuning their active cache
  topology, and widened child-gap multiplication before conversion to `f32` so
  large practical wasm32 trees cannot trap on native-word overflow.
- Distinguished text-measurement cache entries with a collision-resistant
  content/configuration identity instead of trusting Clay's compact 32-bit
  lookup hash. Concrete same-length and different-length full-hash collisions
  now retain separate metrics and cannot reuse out-of-range wrapping offsets;
  malformed static values that share a pointer and declared length but expose
  different safe slice lengths also remain distinct.
- Reserved complete cache misses, declaration storage, and wrapped-line output
  before measurement callbacks, so capacity or allocator failure cannot occur
  after application measurement code has already run.
- Made all four scoped element helpers verify that their original node remains
  open, reject a close-and-replace node at the same stack depth, and abort a
  frame whose callback unwinds past the helper's parent.
- Validated public low-level sizing roots, child ranges, parent links, cycles,
  floating-parent map entries, and scratch-list aliasing before dimension
  mutation. Scratch lists sharing one backing allocation are rejected even when
  passed through copied list values, and all scratch growth is reserved before
  the first dimension write; intrinsic finalization and stale scroll selection
  now no-op safely on invalid indexes.
- Made inspector selection, collapse, and close interaction transactional so a
  rejected frame publishes none of its staged debug state.
- Isolated every callback from scroll pointers borrowed before callback entry,
  and ignored later duplicate-ID transition declarations so the first
  declaration remains authoritative across query, retained, and transition
  state.
- Deferred percentage and missing-floating-parent diagnostics until all
  declaration allocation preflight succeeds. Later duplicate IDs now own no
  hit records or transition interaction effects, while exact frame-local clip
  and floating-parent indexes keep visible descendants aligned with the actual
  duplicate ancestor instead of the first ID-map entry.
- Made both AArch64 execution lanes strictly parse and bind their complete Zig
  test logs, require passing tests, allow only the one named architecture skip
  in the module suite and none in the manifest suite, and recursively bind
  nested runtime Zig sources. Native raw evidence now embeds and re-validates
  both logs and refuses serialized output too large for its own loader.
- Made evidence parsing fail closed on typed boolean proof flags, oversized JSON
  integers, excessive nesting, invalid Unicode surrogates, and oversized or
  concurrently replaced inputs. The QEMU reporter now requires a bounded,
  static ELF64 AArch64 `ET_EXEC` with valid load segments and an executable
  entry point instead of accepting header-only or relocatable ELF files.
- Replaced the coverage audit's shared predictable temporary directory with a
  unique failure-cleaned directory and documented its Bash/ripgrep tooling
  requirements.
- Preserved the first duplicate-ID entry in retained exit-transition snapshots,
  so a disappearing duplicate clones the same declaration used by ordinary
  queries instead of silently switching to the later declaration.
- Detached callback-time `renderCommand` results from the validated live command
  array, preventing application callbacks from corrupting the stream returned
  by `endLayout` while retaining command inspection.
- Stopped non-finite or non-progressing layout distribution from looping
  indefinitely, while leaving ordinary finite sizing arithmetic unchanged.
- Normalized non-finite stored scroll positions and momentum before advancing
  them, preventing invalid state from persisting forever across updates.
- Clamped `String` and `StringSlice` constructor metadata to `maxInt(i32)`, so
  native slices larger than Clay's signed public length cannot trap or enter
  unchecked-build illegal behavior.
- Bounded border-width easing before float-to-`u16` conversion and normalized
  negative/non-finite Context frame deltas, preventing invalid transition time
  from crashing or poisoning runtime progress.
- Suppressed drag-release momentum when its sample time or computed velocity is
  non-positive or non-finite, closing the inherited zero-time division path.
- Rejected non-finite and out-of-range inspector coordinates before integer
  conversion and made inspector numeric formatting deterministic for NaN and
  extreme values.
- Checked cache item/word reservation totals before allocation, so hostile or
  impossible public counts return `OutOfMemory` instead of overflowing before
  `appendAssumeCapacity` in unchecked builds.
- Counted exact measured-word nodes and deduplicated prospective misses by the
  cache's real key during transition preflight, preserving valid layouts at an
  exact configured word ceiling.
- Validated complete arbitrary-order forests before applying supplied-root
  heights, so `InvalidTreeParent` cannot leave otherwise valid dimensions
  partially updated.
- Made pointer-over query slices read-only and redirected callback-time mutable
  scroll-position handles to detached scratch, preventing query results from
  bypassing application-callback mutation guards.
- Guarded hover, transition, external-scroll, text-measurement, and diagnostic
  callback phases against nested frame/declaration/input/cache mutation or
  destruction. Fallible reentry now returns
  `CallbackReentryNotAllowed` (or `PointerUpdateAlreadyActive` for recursive
  pointer sampling), while `void` mutators leave lifecycle state unchanged; the
  standalone text cache applies the same protection to recursive callbacks.
- Reserved final transition layout/render scratch, maximum wrapped-line and
  command growth, exact distinct post-mutation text-cache item/word misses,
  retained snapshots, and persistent-map storage before enter, exit-final, or
  handler callbacks, so a frame cannot fire a transition callback and then roll
  back on a late allocation failure.
- Restored exported `propagateHeights` semantics for supplied-root reachability
  and children stored before parents with a linear cursor traversal, retained
  the complete declaration-ordered fast path, and reject duplicate child edges,
  invalid child ranges, duplicate roots, and disconnected cycles before
  changing any dimensions.
- Snapshotted scroll containers and transition runtimes at frame start and
  restored them on rejection; external scroll queries now run in successful
  declaration order only after the commit tail is infallible.
- Validated transition-bearing preliminary render scopes before invoking user
  handlers, preventing rejected unbalanced prefixes from advancing runtime or
  producing external callback effects.
- Rejected recursive `setPointerState` calls with
  `PointerUpdateAlreadyActive`, preserving the outer hit list and interaction
  transition instead of duplicating IDs and advancing state twice.
- Replaced repeated parent/sibling scans in height propagation with a validated
  reverse-declaration post-order pass, reducing wide-tree work from quadratic
  to linear in nodes plus edges.
- Rejected capacity-truncated render streams with unmatched scissor or overlay
  scopes before committing the frame; balanced shortened streams retain the
  existing Clay-compatible success behavior. Rejected prefixes are now also
  cleared from checked context access, and their hit records are never
  published.
- Made pointer updates allocation-atomic by reserving their complete hit set
  before position/state mutation or hover callbacks.
- Staged retained exit snapshots and hit records until frame commit, and
  preflighted persistent-map commit storage, so late `endLayout` OOM preserves
  the last completed query, hit-test, and transition snapshot.
- Kept pointer-array capacity persistent across runtime element-limit decreases,
  preventing public metadata with `length > capacity` while matching Clay's
  initialization-time pointer allocation model.
- Made scoped helper cleanup propagate its own OOM and abort the current frame
  allocation-free instead of hiding the cleanup failure behind a callback error
  while retaining stale open, transition, or scroll state.
- Preflighted duplicate-ID debug collision storage before combined, split, and
  text declaration mutation, eliminating partial-tree OOM outcomes.
- Bounded every byte-reading hash through `String.asSlice`, so malformed public
  `String.length` metadata hashes nonpositive lengths as empty and clamps
  positive overlong lengths to `chars.len` in Debug, ReleaseSafe, ReleaseFast,
  and ReleaseSmall without changing valid-input hashes or public signatures.
- Matched pinned declaration-order semantics for `hovered()` and
  `getScrollOffset()` expressions evaluated inside a declaration.
- Matched retained-exit first-frame state, stale transition-initial reuse,
  completion-frame removal, sibling insertion, parent trigger, and interaction
  behavior.
- Matched declaration-order transition callbacks, swap-remove tail-skip timing,
  immediate completion behavior, and Clay's root-sticky interaction suppression
  across later sibling subtrees.
- Preserved Clay's zero-width fallback text command when the measurement
  callback is cleared, including callback reinstall/cache-reset behavior.
- Removed recursive deep-tree layout/render paths and reused Context-owned
  sizing, retained-subtree, and render traversal scratch storage across warmed
  frames.
- Corrected duplicate-ID first-entry lookup, bounding-box validity, inherited
  clips and balanced scissors, border arithmetic, control-command defaults,
  and the pinned initial pointer state.
- Reserved inspector numeric-string storage before declaration so text slices
  remain stable through the final layout and render passes.
- Marked internal diagnostic text as program-lifetime/static in the public error
  payload, matching upstream literal metadata.
- Corrected target-aware non-ASCII ID hashing, exact `Clay_String` ID metadata,
  nullable hover clearing, measure-callback mutation timing, and same-frame
  missing-measure warning latching.
- Corrected current-frame fresh queries, floating-root aspect handling,
  missing-parent clip inheritance, and the global wrapped-line ceiling.
- Added bitwise `Clay_EaseOut`, target-default hash, and focused eight-area
  regression fixtures; added a 174-line exhaustive public-enum/default/helper/
  ID/global value fixture plus direct, caller-directory-independent production
  C/FFI source scanning with its own mutation tests.
- Matched Clay's no-transition inspector phase order so selected declarations
  are observed before aspect-ratio sizing mutates them, while retained boxes
  remain visible; the expanded fixture caught and locks this ordering.
- Matched Clay's unconditional aspect-ratio write through the height sizing
  union, including percent-sized declarations.
- Replaced rounded observable fixture fields with exact IEEE-754 `f32` bit
  serialization and made unexpected diagnostics, bounded-log overflow, and
  incomplete output fatal across all ordinary equality pairs.
- Replaced the x86-64-only default-hash trace lookup that would have rejected a
  correct AArch64 C/Zig match; unrecorded architectures now fail closed instead
  of inheriting the wrong digest.
- Matched horizontal drag, stationary reset, release momentum, and both
  aspect-ratio sizing directions; matched text-cache stale-hit pruning and
  word/item free-list reuse; and matched transition handler pruning,
  restoration, disappearance/reappearance, repeated reparenting, and nested
  exiting-tree removal.

### Security

- Production sources are required to remain free of C FFI and hidden runtime
  dependencies.
