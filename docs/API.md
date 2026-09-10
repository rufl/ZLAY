# ZLAY API

This reference describes the public API exported by `src/root.zig` at version
`0.1.0`. It is a native Zig API, not a C ABI. The behavioral baseline is
Clay commit `e6cc36941ab2af5d81107617039d6f527a1c660b`; the root module exports
that value as `upstream_commit` and the pinned header digest as
`upstream_header_sha256`. Unverified parity must not be inferred from similar
names.

## Import and ownership

Import the package with:

```zig
const zlay = @import("zlay");
```

Every `Context` owns its state through the allocator supplied to `Context.init`.
Contexts do not use a process-global current-context pointer and can be advanced
independently. Text-measurement and external-scroll-query callback functions,
their user data, and debug width/highlight settings are likewise owned by the
individual context. Optional paragraph-provider registration is also context-
local and defaults to `null`. This deliberately differs from pinned Clay, whose callback
functions and debug settings are process-global even though callback user data
is retained per context. Call `deinit` exactly once after the last frame.

The slices and pointers returned by `RenderCommandArray`, `renderCommand`, and
ordinary `ScrollContainerData.scroll_position` calls borrow context-owned
storage. `ElementIdArray` exposes a read-only borrowed slice. During an
application callback, `ScrollContainerData.scroll_position` instead points to
detached scratch and is valid only until the next scroll-data query; writes do
not change live scroll state. `renderCommand` likewise returns detached scratch
during callbacks, valid until the next command query, so callback writes cannot
alter the validated live stream. Do not retain borrowed storage across a
subsequent frame mutation that can clear, prune, or reallocate it. Text bytes
passed to `text` or `textSlice` must remain valid through `endLayout` and command
consumption. If a text node can be retained by an exit transition, its bytes
must remain valid until that retained exit subtree completes.

Prefer `String.fromSlice` and `String.literal`, which keep `length` equal to the
backing slice length when it fits the signed Clay field and otherwise clamp it
to `maxInt(i32)`. `StringSlice.fromSlice` and `derive` use the same rule. Direct
public-struct construction is still bounded at
every byte-reading path: `String.asSlice`, element-ID hashing, and non-static
text-cache hashing treat nonpositive lengths as empty and clamp positive
lengths to `chars.len`. This native safety rule prevents malformed metadata
from creating an out-of-bounds slice in any optimization mode without changing
valid-input hashes. The compact Clay-compatible text-cache hash selects a
bucket, but is not accepted as full identity: dynamic text is additionally
matched by a SHA-256 content digest, safe length, and measurement configuration;
static text uses the complete native pointer plus declared length and
configuration. This prevents ordinary 32-bit collisions from reusing unrelated
metrics or wrapping offsets while retaining the pinned static-lifetime model.

## Construction and options

```zig
var context = zlay.Context.init(allocator, dimensions, options);
defer context.deinit();
```

`ContextOptions` fields are:

| Field | Default | Current behavior |
| --- | ---: | --- |
| `max_element_count` | `8192` | Opening an element or text leaf at the limit reports an error and returns `error.ElementCapacityExceeded`. Values above `maxInt(i32)` clamp to that public-array metadata limit. |
| `max_render_command_count` | `0` | Zero derives the command-array capacity from `max_element_count`; a positive value is the explicit capacity and clamps to `maxInt(i32)`. Like pinned Clay, insertion reserves the final slot and reports/omits excess commands once per frame. |
| `max_text_cache_word_count` | `16384` | Hard ceiling on allocator-owned measured-word nodes. Recycled nodes remain reusable at the limit; exhaustion reports a diagnostic and returns `TextMeasurementCapacityExceeded`. |
| `error_handler` | empty | Optional diagnostic callback and user data. |

`ContextError` declares `LayoutAlreadyOpen`, `LayoutNotOpen`, `NoOpenElement`,
`CannotCloseRoot`, `CannotConfigureRoot`, `ElementAlreadyConfigured`,
`ScopedElementUnbalanced`, `PointerUpdateAlreadyActive`,
`CallbackReentryNotAllowed`, `ElementCapacityExceeded`,
`TextMeasurementCapacityExceeded`, `DebugStringCapacityExceeded`,
`RenderCommandCapacityExceeded`, and `ParagraphProviderNotInstalled`. Public fallible operations may also return
allocator errors such as `error.OutOfMemory`. A missing measurement callback is
reported through the diagnostic handler and produces zero preferred text
dimensions; it does not fail `Context.text`. Render-command exhaustion emits a
diagnostic and omits excess commands. If the retained prefix is still
structurally balanced, `endLayout` returns it; if omission splits a scissor or
overlay scope, `endLayout` closes the frame and returns
`RenderCommandCapacityExceeded` instead of exposing an invalid stream. Failed
layout completion also clears the context's partial command prefix, so
`renderCommand()` cannot retrieve rejected commands after the error.
Declaration storage and text/wrapped-output capacity are reserved before
externally observable diagnostics or measurement callbacks. An unrelated OOM
therefore reports neither a percentage/missing-floating-parent warning nor a
measurement callback for a declaration/output that was not committed.

Configuration methods:

| Method | Purpose |
| --- | --- |
| `setMeasureTextFunction(function, user_data)` | Install or clear the font/text measurement callback. Required for meaningful text dimensions. |
| `setParagraphProvider(provider)` / `getParagraphProvider()` | Store/query one context-local optional generic paragraph provider. `null` preserves the complete legacy path. Replacement is ignored during an open layout; otherwise it releases outstanding provider leases and invalidates prior commands. |
| `textWithParagraphStyle(value, config, style)` / `textSliceWithParagraphStyle(value, config, style)` | Declare provider-backed text with advanced shaping and typography fields. Fails with `ParagraphProviderNotInstalled` when no provider is installed. |
| `getLastParagraphProviderFailure()` | Return the last stable provider failure class/code, if an operational callback failed. |
| `paragraphRenderData(&command)` | Resolve typed provider data in constant time only for a command borrowed from the current context command array. Copied and unrelated custom commands return `null`; the pointer expires on the next Context mutation. |
| `resetMeasureTextCache()` | Recycle cached text measurements and release/invalidate provider paragraph commands. Call after font metrics change. |
| `setQueryScrollOffsetFunction(function, user_data)` | Install the application callback used by external scrolling. |
| `setLayoutDimensions(dimensions)` / `getLayoutDimensions()` | Update/query the synthetic root size. Set dimensions before `beginLayout`. |
| `setDebugModeEnabled(bool)` / `isDebugModeEnabled()` | Toggle the native built-in inspector and its upstream-compatible content-width reservation. |
| `setDebugViewWidth(u32)` / `getDebugViewWidth()` | Override/read the default 400-pixel inspector width for following frames. |
| `setDebugViewHighlightColor(Color)` / `getDebugViewHighlightColor()` | Override/read the translucent element-highlight color. |
| `setDebugViewTheme(DebugViewTheme)` / `getDebugViewTheme()` | Override/read inspector text colors, font size, row height, and tree/close target sizes. Defaults preserve pinned output. Font size clamps to 8–48 pixels, controls to 1–30 pixels, and rows to their largest content size through 64 pixels. |
| `setDebugViewAction(DebugViewAction)` | Queue one renderer-neutral `.select_previous`, `.select_next`, `.toggle_collapse`, or `.close` intent before `beginLayout`. Later calls replace the queued action; rejected frames retain it for retry. |
| `getDebugViewState()` | Read the committed inspector enabled flag, selected element ID, selected row index, and row count. Disabled inspectors return the zero/default state. |
| `setCullingEnabled(bool)` | Enable or disable viewport command culling. Enabled by default. |
| `setExternalScrollHandlingEnabled(bool)` | Switch clipped children to application-supplied offsets instead of internal offsets. |
| `getMaxElementCount()` / `setMaxElementCount(count)` | Query/change the element declaration limit. The setter clamps values above `maxInt(i32)`. Pointer-array capacity is persistent like Clay's initialization-time allocation: raising the limit can grow it, while lowering the limit never reports a capacity below an already published hit count. |
| `getMaxMeasureTextCacheWordCount()` / `setMaxMeasureTextCacheWordCount(count)` | Query/change the measured-word ceiling and subsequent cache-lookup topology. Lowering the ceiling does not discard already-owned nodes; it prevents new allocation until the ceiling again exceeds the owned count. Within the initialization-time bucket allocation, the active divisor follows Clay's `count / 32` behavior, so restoring a prior count can recover entries left in its buckets. Counts below 32 use one active bucket, and counts above the allocated topology use all allocated buckets, avoiding Clay's division-by-zero and out-of-bounds cases. |

Application callbacks may use read-only context queries. Frame, declaration,
pointer, and configuration mutation is not accepted while a hover, transition,
external-scroll, text-measurement, paragraph-provider, or diagnostic callback is active: fallible
methods return
`CallbackReentryNotAllowed` (recursive pointer sampling retains the more
specific `PointerUpdateAlreadyActive`), while Clay-compatible `void` setters
and `updateScrollContainers` leave state unchanged. Callback-time `deinit` is
also ignored so an in-progress engine operation cannot resume on destroyed
storage. Pointer-over arrays are const views, and callback-time scroll-data and
command pointers are detached copies, so query results cannot bypass these
guards. The context also snapshots scroll values around every callback and
restores them over the original storage, so a mutable pointer borrowed before
callback entry cannot bypass the same guard.

### Built-in inspector

Enable the inspector before `beginLayout` with
`context.setDebugModeEnabled(true)`. The user root reserves the configured
inspector width and `endLayout` appends the inspector as high-z floating roots.
The returned command stream therefore includes its backgrounds, text, borders,
scissors, row highlights, configuration/warning pane, and hovered-element
overlay.

The configured width is an upper bound. If the viewport is narrower, the
inspector becomes viewport-wide instead of producing negative content width or
overflowing past the right edge. Short viewports shrink the lower details pane
and preserve room for the header and element list. Ordinary 400-by-300 inspector
geometry remains unchanged when the viewport has enough space.

For a higher-contrast inspector with 18-pixel text, 36-pixel rows, and
24-pixel interaction targets:

```zig
context.setDebugViewTheme(zlay.debug_view_accessibility_theme);
```

Applications can map keyboard, gamepad, switch, or remote-control input without
making ZLAY depend on a platform input API:

```zig
if (input.down_pressed) context.setDebugViewAction(.select_next);
if (input.up_pressed) context.setDebugViewAction(.select_previous);
if (input.activate_pressed) context.setDebugViewAction(.toggle_collapse);
if (input.dismiss_pressed) context.setDebugViewAction(.close);
```

Queue at most one action before `beginLayout`; a later call intentionally wins.
Selection skips text-preview and root-separator rows, clamps at list ends, and
keeps the selected row visible when ZLAY owns scrolling. With external scroll
handling enabled, the application remains responsible for revealing it.
`getDebugViewState()` gives assistive, remote-control, and external-scroll
adapters the committed selection and list position without exposing inspector
storage or requiring a pointer device. It does not define platform accessibility
semantics; those remain renderer/application-owned.

The default theme remains bit-compatible with the pinned inspector. A custom
theme changes only inspector presentation; application layout and commands
outside the debug view are unaffected.

The inspector uses the application's measurement callback with font ID zero.
Pointer hit testing still consumes the prior completed frame: call
`setPointerState` before declaration as usual, then advance the same persistent
context so row selection, collapse, close, and inspector scrolling retain
state. Pointer and renderer-neutral action input share the same transactional
commit boundary. Inspector declarations count against `max_element_count` and can grow
allocator usage; leave headroom beyond the application's largest user tree.

`MeasureTextFunction` has this shape:

```zig
fn measure(
    text: zlay.StringSlice,
    config: *zlay.TextElementConfig,
    user_data: ?*anyopaque,
) zlay.Dimensions
```

The callback must measure exactly `text.asSlice()` using the supplied font ID,
size, spacing, and application state. It is invoked for spaces, words, and
other spans needed by wrapping. It may mutate the supplied text configuration,
matching Clay, but cannot recursively mutate its `Context`; the standalone
`text_engine.Cache` likewise rejects recursive measurement and ignores
callback-time reset or destruction.

### Optional paragraph-provider types

`ParagraphProvider` stores an opaque context and a generic vtable for intrinsic
measurement, final-width layout, and paragraph retain/release operations. The
validated wrapper rejects malformed UTF-8, invalid widths/metrics, zero handles,
and zero generations before ZLAY adopts a result. With a provider installed,
`Context.text` uses provider intrinsic metrics and the final wrapping pass calls
`layoutParagraph` once for each exact text/style/width key. The legacy callback
is not invoked or used as an operational fallback on this path.

Successful layouts own one lease in the frame cache. ZLAY emits one existing
`custom` command per provider paragraph; its background color carries the
legacy text paint color, while `paragraphRenderData` safely resolves the opaque
payload to the exact lease and available width. Commands and the resolved data
are borrowed only until the next frame mutation/reset/provider replacement.
Expired pointers must not be reused because later command storage may occupy the
same address. Every owned cache entry is released exactly once on those
boundaries, on frame failure, or during `deinit`. Style differences and exact final widths create
distinct entries; duplicate keys share one live lease. Stable operational
failure classes map into ZLAY's fallible layout surface without silently mixing
provider measurement with legacy wrapping.
If a renderer queues work beyond command consumption, it must call
`ParagraphProvider.retainParagraph` before the frame lease expires and pair it
with exactly one `releaseParagraph` after the queued work completes.

`ParagraphTextStyle` carries provider-facing typography without narrowing:
32-bit font-stack identity, float size, signed/fractional letter and word
spacing, direction, script, borrowed language, features, variations, advanced
line height, wrap, physical/logical alignment, overflow, and line limit.
`fromLegacy(TextElementConfig)` widens the legacy unsigned fields exactly,
preserves physical alignment, and maps the pinned implementation's equivalent
hard-break-only `.newlines`/`.none` behavior to provider `.none`. The explicit
`Context.textWithParagraphStyle` path carries this model directly; `Context.text`
remains the lossless legacy bridge.

The checked renderer passes `.custom` methods the original borrowed command
pointer so paragraph identity remains resolvable:

```zig
pub fn custom(
    self: *Backend,
    command: *const zlay.RenderCommand,
    data: zlay.CustomRenderData,
) !void {
    if (self.context.paragraphRenderData(command)) |paragraph| {
        try self.fonts.drawParagraph(
            paragraph.lease.handle,
            command.bounding_box,
            data.background_color,
        );
        return;
    }
    try self.drawApplicationCustom(command.*, data);
}
```

The provider owns glyph runs, atlas references, and shaping data behind the
handle. ZLAY supplies placement, clipping, paint color, lease lifetime, and the
exact final layout width without choosing a font library.

Run `zig build paragraph-provider-example` for a complete dependency-free mock
that exercises advanced features/variations, typed custom-command resolution,
and retaining a paragraph while queued renderer work outlives its frame.

### Fixed-buffer profiling

`zlay.profile.FixedBufferProfiler` is an optional instrumentation allocator for
fixed-buffer users:

```zig
var storage: [1024 * 1024]u8 = undefined;
var profiler = zlay.profile.FixedBufferProfiler.init(&storage);
var context = zlay.Context.init(profiler.allocator(), dimensions, options);
defer context.deinit();

// Draw representative warm and peak frames.
const snapshot = profiler.snapshot();
std.debug.print("peak={d} headroom={d}\n", .{
    snapshot.peak_bytes,
    snapshot.headroomBytes(),
});
```

`Snapshot` also exposes `capacity_bytes`, `current_bytes`,
`successful_allocations`, and `failed_allocations`. `reset()` invalidates every
outstanding allocation and starts a fresh profiling run; call it only after
destroying all values using that allocator. The result is workload-specific
high-water evidence, not Clay arena-partition or `Clay_MinMemorySize`
equivalence.

## Per-frame input and lifecycle

A typical interactive frame is ordered as follows:

```zig
context.setLayoutDimensions(viewport);
try context.setPointerState(pointer_position, pointer_down);
context.updateScrollContainers(enable_drag, wheel_delta, delta_time);

try context.beginLayout();
// Declare elements and text here.
const commands = try context.endLayout(delta_time);
// Render commands now, before the next beginLayout.
```

`setPointerState` performs hit testing against the last completed layout,
updates the four-state pointer state, and invokes retained hover callbacks.
It reserves the worst-case hit set before making any observable change; an
`OutOfMemory` result preserves the previous position, interaction state, hit
IDs, and callback count. Hover callbacks may perform read-only context queries.
They cannot open or commit a nested layout or mutate input/configuration state;
fallible mutation returns `CallbackReentryNotAllowed`, while a recursive
`setPointerState` call returns `PointerUpdateAlreadyActive`. The outer sample
therefore continues against one immutable committed-frame snapshot and
publishes one coherent hit set and state transition.
`updateScrollContainers` advances wheel, drag, momentum, and pruning state. The
two calls are valid before the first frame; there will simply be no retained
geometry or scroll containers yet. Drag sampling accumulates only positive
finite `delta_time`; releasing without a valid positive sample produces zero
momentum instead of a non-finite velocity.

`beginLayout()` snapshots persistent scroll/transition state, clears frame-local
lengths while retaining capacity, advances the generation, and opens the
synthetic root. It returns
`LayoutAlreadyOpen` if a frame is already open.

`endLayout(delta_time)` closes the root, reinserts any retained exit subtrees,
resolves target layout and wrapping, advances transitions, performs a final
layout/render pass when transition overrides are active, commits retained
query/hit-test data, and closes the frame. If user elements remain open, it
emits `unbalanced_open_close` to the error handler and closes them before
continuing. A capacity-truncated, unbalanced render scope returns
`RenderCommandCapacityExceeded` without committing that frame; the context is
closed, its partial commands are hidden, and its hit-test records are discarded.
The transition-bearing preliminary render is validated before user transition
callbacks run. Debug declarations, final layout/render scratch, the maximum
wrapped-line and render-command growth, exact distinct text-cache item/word
misses after measurement-config mutation, retained exit snapshots, and
persistent element updates are all allocation-preflighted before those callbacks. Scroll
containers and transition runtimes are restored from the `beginLayout` snapshot
on rejection, and no transition callback fires for a frame that later returns an
allocator or render-structure error.
External scroll queries are invoked in declaration order only after commit can
no longer fail. A late `OutOfMemory` therefore leaves the last completed query,
hit-test, scroll, and exit-transition snapshot available. The context accepts
the next `beginLayout`. Calling `endLayout` without an open frame returns
`LayoutNotOpen`.
Negative or non-finite `delta_time` is normalized to zero before transition
runtime progress is accumulated. Direct border-width interpolation also bounds
out-of-range results to `u16` and preserves the starting width for NaN input.
Scroll updates clear non-finite stored position/momentum, and layout sizing
stops a distribution pass whose amount is non-finite or cannot make numeric
progress rather than looping indefinitely.

## Declaring elements

The low-level declaration API is deliberately explicit:

| Method | Purpose |
| --- | --- |
| `openElement(declaration)` | Open a child with an automatic structural ID. |
| `openElementWithId(id, declaration)` | Open a child with an explicit ID. |
| `openElementUnconfigured()` | Open an automatic-ID child before evaluating its declaration. Pair with `configureOpenElement`. |
| `openElementWithIdUnconfigured(id)` | Open an explicit-ID child before evaluating its declaration. Pair with `configureOpenElement`. |
| `configureOpenElement(declaration)` | Configure the most recently opened, still-unconfigured child. It rejects the synthetic root and double configuration. |
| `element(declaration, body)` | Run `body(context)` inside an automatic-ID element and close the element on success or body error. |
| `elementWithId(id, declaration, body)` | Explicit-ID scoped counterpart to `element`. |
| `elementDeferred(factory, body)` | Scoped automatic-ID form that opens first, then invokes a fallible declaration factory. |
| `elementWithIdDeferred(id, factory, body)` | Explicit-ID deferred counterpart; preserves declaration query order. |
| `closeElement()` | Finalize the current element and return to its parent. The synthetic root cannot be closed directly. |
| `text(value, config)` | Append a text leaf from `zlay.String`. |
| `textSlice(bytes, config)` | Convenience form accepting `[]const u8`. |

The split open/configure form preserves the evaluation order of Clay's element
macros. Use it when the declaration itself calls `hovered()`,
`getScrollOffset()`, `getOpenElementId()`, or another query that must observe
the newly opened element:

```zig
try context.openElementUnconfigured();
const is_hovered = context.hovered();
try context.configureOpenElement(.{
    .background_color = if (is_hovered) hot else idle,
});
try context.closeElement();
```

The combined methods are appropriate when declaration evaluation does not
depend on the new open-element scope. The scoped `element*` helpers accept a
function that receives `*Context`; if that function returns an error, the helper
restores the open stack before propagating it. `elementDeferred` and
`elementWithIdDeferred` invoke a fallible `fn (*Context) !ElementDeclaration`
after opening, so they retain split-form evaluation order without manual close
bookkeeping. A body that returns successfully with unmatched nested elements
receives `ScopedElementUnbalanced` after cleanup. If automatic cleanup itself
cannot allocate while closing a node, its error takes precedence and the
current frame is aborted without allocation. The last completed retained
geometry remains available, and the context accepts a fresh `beginLayout`.
The helpers compare the exact node and parent they opened as well as stack
depth. Closing either and rebuilding replacements is rejected; a replaced or
underflowed ancestor aborts the malformed frame before later declarations can
continue against the wrong parent.

`ElementDeclaration` contains layout, background and overlay colors, corner
radius, aspect ratio, image data, floating attachment, custom data, clipping,
border, transition, and opaque user data. Configuration fields are plain native
Zig structs with defaults, so declarations can initialize only what they use.

Sizing and decoration helpers exported by the root module are `fit`, `fitMin`,
`fitMinMax`, `grow`, `growMin`, `growMinMax`, `fixed`, `percent`, `padding`,
`cornerRadius`, `borderOutside`, `borderAll`, `clayMin`, and `clayMax`.
`easeOut` is the built-in transition callback. `layout_default` is a mutable
`*LayoutConfig` handle corresponding to Clay's writable global.

Text wrapping modes are `.words`, `.newlines`, and `.none`; alignment is
`.left`, `.center`, or `.right`. ZLAY emits one text command per non-empty
wrapped line.

## IDs, interaction, and queries

| Method | Purpose |
| --- | --- |
| `getElementId(value: String)` | Exact `Clay_GetElementId` mapping; preserves string backing and static-lifetime metadata. |
| `getElementIdWithIndex(value: String, index)` | Exact indexed mapping with full string metadata. |
| `id(label)` / `staticId(comptime label)` | Hash a dynamic or compile-time unindexed global ID. |
| `indexedId(label, index)` / `staticIndexedId(comptime label, index)` | Hash a dynamic or compile-time global ID with a numeric index. |
| `localId(label)` / `staticLocalId(comptime label)` | Hash a dynamic or compile-time label relative to the currently open element; fails with `NoOpenElement` if none exists. |
| `indexedLocalId(label, index)` / `staticIndexedLocalId(comptime label, index)` | Indexed form relative to the currently open element. |
| `getOpenElementId()` | Return the numeric `u32` ID of the current user element, or `NoOpenElement` outside a declaration scope. |
| `hovered()` | Test whether the current user element appears in retained pointer-over IDs; returns `false` outside a declaration scope. |
| `onHover(?function, user_data)` | Attach, replace, or explicitly clear a callback on the current user element for future pointer updates; returns `NoOpenElement` outside a declaration scope. |
| `pointerOver(element_id)` | Test an explicit ID. |
| `getPointerOverIds()` | Borrow the current z-prioritized overlap list. |
| `getPointerState()` | Return the retained position and pressed/released transition state. |
| `getElementData(element_id)` | Return the retained bounding box and `found` flag. A newly opened first-frame ID is immediately found with a zero/default box, matching Clay. |

Automatic IDs depend on tree position. Prefer explicit IDs for any element used
across frames by queries, scrolling, hover logic, floating attachment, or
transitions. ID hashing follows the active target C `char` signedness, while
text-cache data hashing follows Clay's target-default x86-64/AArch64/scalar
selection. Explicit scalar helpers remain available for oracle work.

Scrolling queries are:

| Method | Purpose |
| --- | --- |
| `getScrollOffset()` | Return the current open element's internal scroll offset, or zero when unavailable. |
| `getScrollOffsetFor(element_id)` | Return the named container's internal offset, or zero when absent. |
| `getScrollContainerData(element_id)` | Return dimensions, clip configuration, `found`, and a borrowed mutable scroll-position pointer outside callbacks. During callbacks the pointer targets detached per-query scratch; writes through pointers borrowed before callback entry are also restored before the callback returns. |

The outside-scope results are deliberate checked Zig behavior. Pinned Clay
reports internal errors before the first frame and can expose the retained
synthetic root after `EndLayout`; ZLAY returns the safe values/errors documented
above. Both traces and an exact following-frame recovery are digest-pinned by
`zig build reviewed-divergences`.

When external scroll handling is enabled, install a
`QueryScrollOffsetFunction` of shape
`fn (id: u32, user_data: ?*anyopaque) zlay.Vector2` before layout. Successful
frames invoke it once per clip declaration, in declaration order, during the
infallible commit tail. Rejected frames invoke no external scroll query. Query
callbacks may inspect the context but cannot open a nested frame or advance
scroll/input/configuration state.

## Renderer command contract

`endLayout` returns `RenderCommandArray`; use `items()` to obtain the bounded
slice or `get(index)`/`context.renderCommand(index)` for checked access. Render
the slice in order. Floating roots have already been stably sorted by z-index.
During an application callback, `context.renderCommand(index)` points to
detached scratch rather than this live array.
The array's `capacity` is the configured logical command ceiling, not the
allocator's current reservation. `ElementIdArray.capacity` likewise reports
`max_element_count`. Both values are always representable as `i32` because
oversized configuration values are clamped during initialization or by the
element-count setter.

`RenderData` is an untagged union. `command_type` is its external tag, so only
read the payload named in this table:

| `command_type` | Active payload | Backend action |
| --- | --- | --- |
| `.none` | none | Ignore. |
| `.rectangle` | `.rectangle` | Draw `bounding_box` using background color and corner radii. |
| `.border` | `.border` | Draw per-side border widths, color, and corner radii. |
| `.text` | `.text` | Draw `string_contents.asSlice()` with the supplied font fields at `bounding_box`. |
| `.image` | `.image` | Interpret `image_data` in the application, tint/fill as required, and draw in `bounding_box`. |
| `.custom` | `.custom` | Interpret `custom_data` in the application. |
| `.scissor_start` | `.clip` | Push/intersect a clip scope using `bounding_box` and the horizontal/vertical flags. |
| `.scissor_end` | none | Pop the matching clip scope. |
| `.overlay_color_start` | `.overlay_color` | Push an overlay-color scope. |
| `.overlay_color_end` | none | Pop the matching overlay-color scope. |

Clip and overlay commands are nested scope delimiters; do not reorder them.
`id`, `z_index`, and `user_data` support renderer caching and application-owned
dispatch, but the renderer must not dereference opaque image/custom/user data
without knowing the concrete application type. A successful `endLayout` never
returns a capacity-truncated prefix with unbalanced scope delimiters.

### Checked renderer dispatcher

`zlay.renderer` provides a small allocation-free adapter above the raw tagged
union. `validate`/`validateArray` check array metadata and balanced independent
scissor/overlay scopes. `consume`/`consumeArray` validate the full stream before
calling a backend, so malformed scope structure cannot partially mutate it:

```zig
const stats = try zlay.renderer.consumeArray(MyBackend, &backend, commands);
```

`MyBackend` supplies one public method for each `RenderCommandType`: `none`,
`rectangle`, `border`, `text`, `image`, `custom`, `scissorStart`, `scissorEnd`,
`overlayColorStart`, and `overlayColorEnd`. Payload-bearing methods receive only
the active `RenderData` field. `custom` receives `*const RenderCommand` rather
than a copy so context-owned paragraph payloads can be resolved safely; the
other methods receive commands by value. (`pub fn` is required when the backend
is declared outside `renderer.zig`.) `Stats` returns per-kind counts and maximum
scope depth. The adapter dispatches commands; application code still performs
actual graphics, font, image, and custom rendering.

## Errors and diagnostics

Fallible methods use Zig errors for invalid lifecycle/capacity states and
allocation failure. Separately, `ContextOptions.error_handler` receives
Clay-style diagnostics such as missing text measurement, duplicate IDs,
missing floating parents, percentages over one, capacity warnings, and
unbalanced nesting. A reported diagnostic does not always abort the frame.
Element and text declaration paths preflight their required storage so a failed
operation does not leave a partially appended element in the current tree.
That preflight includes debug duplicate-collision bookkeeping for combined,
split, and text declarations. Pointer updates preflight their complete hit set;
frame completion stages hit and exit-snapshot data and reserves persistent-map
commit storage before publishing any of those surfaces.

Paragraph providers additionally surface `ParagraphProviderFailed`,
`ParagraphProviderContractViolation`, `ParagraphProviderStaleHandle`, and
`ParagraphProviderNotInstalled`.
Limit failures use `TextMeasurementCapacityExceeded`, and provider allocation
failure uses `OutOfMemory`. The diagnostic callback receives an
`internal_error` summary; `getLastParagraphProviderFailure` retains the stable
class and provider-specific numeric code.

For ordinary compatibility diagnostics, the callback receives the matching
phase, error type, exact literal bytes/length, `is_statically_allocated = true`,
and the configured user-data pointer. Diagnostic callbacks may query the
context but cannot recursively advance, mutate, or destroy it. Capacity
failures and native safety repairs retain their documented Zig error flow;
notably, an unbalanced
`endLayout` closes every outstanding user element after reporting the warning,
where pinned C closes only one. See the reviewed-divergence table in
`PARITY.md` for these non-equal contracts.

The current package is deliberately conservative about compatibility claims.
See [PARITY.md](PARITY.md) for the required differential evidence and
[ARCHITECTURE.md](ARCHITECTURE.md) for known subsystem boundaries.

## Additive animation timelines

`zlay.animation` provides opt-in fixed-capacity timelines over `TransitionData`.
It is separate from Clay-compatible `TransitionElementConfig` and does not
change existing transition behavior. `Timeline` supports keyframes, delay,
repeats, alternating direction, reverse playback, custom easing, cancellation,
and deterministic completion. `VisualStateBridge` animates visual layout state
from immutable current/target snapshots without mutating layout targets and
settles directly to the target under reduced motion. Evaluation never allocates.

## Retained layout foundation

`zlay.retained_layout.LayoutTree` is an additive, bounded retained tree for
game and native UI. It supports generational node IDs; dependency-aware dirty
recomputation; row and column flex layout in forward or reverse main-axis
directions; wrapping and reverse wrapping; flex basis/grow/shrink;
justification; wrapped-line `align_content`; cross-axis and baseline alignment;
flex auto margins; nine-position overlays with intrinsic sizing and per-axis
auto margins; LTR/RTL flex, overlay, and grid placement; min/max dimensions;
aspect ratios; `display: none`; flow-neutral relative inset offsets; physical
absolute insets with opposing-inset auto sizing and positioned auto margins;
fixed padding and margins with optional fixed/percentage `ResponsiveEdges`
overrides; allocation-free clipped retained-node hit testing with explicit
per-node priority; and auto/length/percentage/stretch/min-content/max-content/
fit-content dimensions.
Shared and axis-specific typed gaps support fixed values, including negative
overlap, plus non-negative percentage and stretch units with optional bounds.
`Overflow.clip` exposes inherited renderer-neutral clip rectangles.

The grid subset supports fixed, intrinsic-auto, fractional, and bounded
`GridTrack.minmax` tracks; shared or axis-specific typed gaps; explicit,
partially specified, sparse automatic, or dense automatic placement; row- or
column-major auto flow; implicit tracks; and row/column spans. Intrinsic grid
sizing includes implicit tracks and fixed or measured child contributions to
auto tracks. Grid items honor explicit, percentage, stretch, and intrinsic
sizes within their cells; logical nine-position alignment and per-axis auto
margins place remaining cell space.
Track and tree limits are explicit: `max_supported_grid_tracks` bounds
allocation-free grid scratch to 256 tracks per axis, while
`max_supported_tree_depth` bounds layout descent to 256 levels.
Hidden-tree and destruction traversal are iterative.

`computeWithMeasure` supplies allocation-free intrinsic leaf measurement.
`computeWithMeasureTiers` adds minimum, preferred, and maximum intrinsic
dimensions. Width-dependent leaves are remeasured after flex shrink.
`computeDirty` and `computeDirtyWithMeasure` restart from the topmost ancestor;
`computeDirtySubtree` keeps a caller-selected root. All three reuse clean
subtree layouts only when cached origin, containing-block, forced-size,
root-size, and clip inputs still match. Changed dependencies are recomputed.
Block flow, CSS parsing, and complete browser layout semantics remain outside
this API.

`zlay.retained_store` provides caller-owned generational records for ECS-style
applications that keep authoritative topology, style, and layout data outside
`LayoutTree`. It supplies bounded node records, flat child buckets, stale-ID
detection, and explicit style/layout mutation. Styles must change through
`setStyle` or `update`, which advances each record's solver-visible revision.
`StoreSolver` keeps mirror topology and synchronization scratch persistent:
stable styles are not recopied, only changed parent lists are rebuilt, dirty
layout starts at the requested subtree, and one bounded subtree traversal
writes results back. `lastSyncStats` reports style updates, rebuilt parents,
and written nodes for profiling and regression checks.

## Interaction foundation

`zlay.interaction.Interaction` provides caller-storage-backed focus and pointer
state. Registering elements establishes deterministic keyboard order. Navigation
supports wrapping or clamping, pointer capture is explicit, and `dispatch`
returns a renderer-neutral target decision for keyboard focus, pointer capture,
or hit-test input. Unregistering an element clears any focus or capture owned by
it.

## Widget state primitives

`zlay.widgets` provides renderer-neutral, caller-storage-backed state for
buttons, tabs, keyboard-navigable lists, and modal dialogs. Buttons expose
explicit activation/consumption; tabs and lists preserve registration order
with wrapping or clamped movement; dialogs provide open, close, toggle, and
Escape handling. These types contain interaction state only; layout, drawing,
platform input, and accessibility semantics remain application-owned.

## Text widgets and virtualization

`zlay.text_widgets` provides caller-storage-backed byte-oriented text editing
and pure virtual-list range calculations. `TextInput` supports cursor movement,
selection, insertion, deletion, and bounded capacity. Virtual-list helpers
return deterministic half-open visible ranges with optional overscan. UTF-8
grapheme behavior, font measurement, row rendering, and data ownership remain
application-owned.

## Accessibility and reduced motion

`zlay.accessibility` provides renderer-neutral semantic metadata and a
caller-storage-backed registry. Roles, labels, descriptions, and state flags
are exposed as borrowed values for application adapters. Its reduced-motion
policy settles opt-in animation calculations deterministically without changing
the existing Clay-compatible transition path. OS accessibility mappings,
announcements, focus visuals, and platform input remain application-owned.
