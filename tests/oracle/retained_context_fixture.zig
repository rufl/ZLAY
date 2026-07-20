const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [16]zlay.ErrorType = undefined,
    length: usize = 0,
};

const MeasureProbe = struct {
    data_owner: u8,
    observed_function: u8 = '?',
    calls: usize = 0,
};

const QueryProbe = struct {
    data_owner: u8,
    observed_function: u8 = '?',
    calls: usize = 0,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("retained-context diagnostics");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
}

fn recordMeasure(
    value: zlay.StringSlice,
    user_data: ?*anyopaque,
    function_owner: u8,
) zlay.Dimensions {
    const probe: *MeasureProbe = @ptrCast(@alignCast(user_data.?));
    probe.observed_function = function_owner;
    probe.calls += 1;
    return .{ .width = @floatFromInt(value.asSlice().len), .height = 1 };
}

fn measureA(
    value: zlay.StringSlice,
    _: *zlay.TextElementConfig,
    user_data: ?*anyopaque,
) zlay.Dimensions {
    return recordMeasure(value, user_data, 'A');
}

fn measureB(
    value: zlay.StringSlice,
    _: *zlay.TextElementConfig,
    user_data: ?*anyopaque,
) zlay.Dimensions {
    return recordMeasure(value, user_data, 'B');
}

fn recordQuery(
    _: u32,
    user_data: ?*anyopaque,
    function_owner: u8,
) zlay.Vector2 {
    const probe: *QueryProbe = @ptrCast(@alignCast(user_data.?));
    probe.observed_function = function_owner;
    probe.calls += 1;
    return .{ .x = 2, .y = 3 };
}

fn queryA(element_id: u32, user_data: ?*anyopaque) zlay.Vector2 {
    return recordQuery(element_id, user_data, 'A');
}

fn queryB(element_id: u32, user_data: ?*anyopaque) zlay.Vector2 {
    return recordQuery(element_id, user_data, 'B');
}

fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

fn fixedBox(width: f32, height: f32) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(width),
            .height = zlay.fixed(height),
        } },
    };
}

fn routeContext(out: *std.Io.Writer, label: []const u8, context: *const zlay.Context) !void {
    // This is a routing marker, not a hidden current-context mutation. Every
    // operation below continues to receive its owning Context explicitly.
    const dimensions = context.getLayoutDimensions();
    try out.print("route {s} owner 1 dims {d} {d}\n", .{
        label,
        f32Bits(dimensions.width),
        f32Bits(dimensions.height),
    });
}

fn printQuery(
    out: *std.Io.Writer,
    context: *const zlay.Context,
    context_label: []const u8,
    label: []const u8,
    id: zlay.ElementId,
) !void {
    const data = context.getElementData(id);
    try out.print("query {s} {s} id {d} found {d} box {d} {d} {d} {d}\n", .{
        context_label,
        label,
        id.id,
        @intFromBool(data.found),
        f32Bits(data.bounding_box.x),
        f32Bits(data.bounding_box.y),
        f32Bits(data.bounding_box.width),
        f32Bits(data.bounding_box.height),
    });
}

fn printErrorDelta(
    out: *std.Io.Writer,
    context_label: []const u8,
    label: []const u8,
    log: *const ErrorLog,
    start: usize,
) !void {
    try out.print("errors {s} {s} delta {d}", .{ context_label, label, log.length - start });
    for (log.types[start..log.length]) |error_type| {
        try out.print(" {d}", .{@intFromEnum(error_type)});
    }
    try out.print(" total {d}\n", .{log.length});
}

fn printPointer(
    out: *std.Io.Writer,
    context: *zlay.Context,
    context_label: []const u8,
    label: []const u8,
) !void {
    const pointer = context.getPointerState();
    const over = context.getPointerOverIds().items();
    try out.print("pointer {s} {s} pos {d} {d} state {d} over {d}", .{
        context_label,
        label,
        f32Bits(pointer.position.x),
        f32Bits(pointer.position.y),
        @intFromEnum(pointer.state),
        over.len,
    });
    for (over) |element_id| try out.print(" {d}", .{element_id.id});
    try out.writeByte('\n');
}

fn printScroll(
    out: *std.Io.Writer,
    context: *zlay.Context,
    context_label: []const u8,
    label: []const u8,
    id: zlay.ElementId,
) !void {
    const data = context.getScrollContainerData(id);
    const position = if (data.scroll_position) |value| value.* else zlay.Vector2{};
    try out.print(
        "scroll {s} {s} id {d} found {d} pos {d} {d} viewport {d} {d} content {d} {d} config {d} {d}\n",
        .{
            context_label,
            label,
            id.id,
            @intFromBool(data.found),
            f32Bits(position.x),
            f32Bits(position.y),
            f32Bits(data.scroll_container_dimensions.width),
            f32Bits(data.scroll_container_dimensions.height),
            f32Bits(data.content_dimensions.width),
            f32Bits(data.content_dimensions.height),
            @intFromBool(data.config.horizontal),
            @intFromBool(data.config.vertical),
        },
    );
}

fn drawPointerFrame(
    out: *std.Io.Writer,
    context: *zlay.Context,
    id: zlay.ElementId,
    print_retained_hover: bool,
) !void {
    try context.beginLayout();
    try context.openElementWithIdUnconfigured(id);
    if (print_retained_hover) {
        try out.print("hovered A retained-declaration {d}\n", .{@intFromBool(context.hovered())});
    }
    try context.configureOpenElement(fixedBox(40, 40));
    try context.closeElement();
    _ = try context.endLayout(0);
}

fn drawScroll(
    out: *std.Io.Writer,
    context: *zlay.Context,
    context_label: []const u8,
    frame_label: []const u8,
    scroll_id: zlay.ElementId,
    content_id: zlay.ElementId,
    viewport_width: f32,
    viewport_height: f32,
    content_height: f32,
) !void {
    try context.beginLayout();
    try context.openElementWithIdUnconfigured(scroll_id);
    const offset = context.getScrollOffset();
    try out.print("offset {s} {s} {d} {d}\n", .{
        context_label,
        frame_label,
        f32Bits(offset.x),
        f32Bits(offset.y),
    });
    try context.configureOpenElement(.{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(viewport_width),
                .height = zlay.fixed(viewport_height),
            },
            .layout_direction = .top_to_bottom,
        },
        .clip = .{
            .vertical = true,
            .child_offset = offset,
        },
    });
    try context.openElementWithId(content_id, fixedBox(viewport_width, content_height));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

fn drawEmpty(context: *zlay.Context) !void {
    try context.beginLayout();
    _ = try context.endLayout(0);
}

fn drawMeasureProbe(context: *zlay.Context) !void {
    try context.beginLayout();
    try context.text(zlay.String.fromSlice("owner"), .{
        .font_size = 1,
        .wrap_mode = .none,
    });
    _ = try context.endLayout(0);
}

fn printMeasureProbe(
    out: *std.Io.Writer,
    context_label: []const u8,
    probe: *const MeasureProbe,
) !void {
    try out.print("callback-owner {s} install-order A-then-B function {c} data {c} calls {d}\n", .{
        context_label,
        probe.observed_function,
        probe.data_owner,
        probe.calls,
    });
}

fn printQueryProbe(
    out: *std.Io.Writer,
    context_label: []const u8,
    probe: *const QueryProbe,
) !void {
    try out.print("query-callback-owner {s} install-order A-then-B function {c} data {c} calls {d}\n", .{
        context_label,
        probe.observed_function,
        probe.data_owner,
        probe.calls,
    });
}

fn printDebugProbe(
    out: *std.Io.Writer,
    context_label: []const u8,
    context: *const zlay.Context,
) !void {
    const color = context.getDebugViewHighlightColor();
    try out.print("debug-global-owner {s} after-A-set width {d} color {d} {d} {d} {d}\n", .{
        context_label,
        context.getDebugViewWidth(),
        f32Bits(color.r),
        f32Bits(color.g),
        f32Bits(color.b),
        f32Bits(color.a),
    });
}

pub fn main(init: std.process.Init) !void {
    var errors_a = ErrorLog{};
    var errors_b = ErrorLog{};
    var context_a = zlay.Context.init(std.heap.page_allocator, .{ .width = 100, .height = 80 }, .{
        .max_element_count = 8,
        .max_text_cache_word_count = 32,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors_a,
        },
    });
    defer context_a.deinit();
    var context_b = zlay.Context.init(std.heap.page_allocator, .{ .width = 160, .height = 120 }, .{
        .max_element_count = 8,
        .max_text_cache_word_count = 32,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors_b,
        },
    });
    defer context_b.deinit();

    const shared_id = context_a.staticId("retained-shared");
    const missing_id = context_a.staticId("retained-missing");
    const duplicate_id = context_a.staticId("retained-duplicate");
    const alpha_id = context_a.staticId("alpha");
    const delta_id = context_a.staticId("delta");
    const pointer_id = context_a.staticId("retained-pointer");
    const scroll_id = context_a.staticId("retained-scroll");
    const content_id = context_a.staticId("retained-scroll-content");
    const callback_scroll_id = context_a.staticId("retained-callback-scroll");
    const callback_content_id = context_a.staticId("retained-callback-scroll-content");

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.writeAll("context-model explicit-instances\n");

    try routeContext(out, "A", &context_a);
    try context_a.setPointerState(.{ .x = 1, .y = 1 }, false);
    try context_a.setPointerState(.{ .x = 1, .y = 1 }, false);
    try printQuery(out, &context_a, "A", "initial-missing", shared_id);
    try printQuery(out, &context_a, "A", "unknown-missing", missing_id);
    try context_a.beginLayout();
    try printQuery(out, &context_a, "A", "fresh-before-open", shared_id);
    try context_a.openElementWithIdUnconfigured(shared_id);
    try printQuery(out, &context_a, "A", "fresh-open", shared_id);
    try context_a.configureOpenElement(fixedBox(20, 30));
    try context_a.closeElement();
    try printQuery(out, &context_a, "A", "fresh-closed", shared_id);
    _ = try context_a.endLayout(0);
    try printQuery(out, &context_a, "A", "fresh-ended", shared_id);
    try printPointer(out, &context_a, "A", "normalized-initial");

    try routeContext(out, "B", &context_b);
    try context_b.setPointerState(.{ .x = 150, .y = 110 }, false);
    try context_b.setPointerState(.{ .x = 150, .y = 110 }, false);
    try printQuery(out, &context_b, "B", "isolated-missing", shared_id);
    try context_b.beginLayout();
    try context_b.openElementWithIdUnconfigured(shared_id);
    try printQuery(out, &context_b, "B", "fresh-open", shared_id);
    try context_b.configureOpenElement(fixedBox(70, 40));
    try context_b.closeElement();
    _ = try context_b.endLayout(0);
    try printQuery(out, &context_b, "B", "fresh-ended", shared_id);
    try printPointer(out, &context_b, "B", "normalized-initial");

    try routeContext(out, "A", &context_a);
    try printQuery(out, &context_a, "A", "prior-idle", shared_id);
    try context_a.beginLayout();
    try printQuery(out, &context_a, "A", "prior-open-frame", shared_id);
    _ = try context_a.endLayout(0);
    try printQuery(out, &context_a, "A", "stale-ended", shared_id);
    try printQuery(out, &context_a, "A", "unknown-ended", missing_id);

    try routeContext(out, "B", &context_b);
    try printQuery(out, &context_b, "B", "retained-while-A-stale", shared_id);

    try routeContext(out, "A", &context_a);
    const duplicate_error_start = errors_a.length;
    try context_a.beginLayout();
    try context_a.openElementWithId(duplicate_id, fixedBox(10, 12));
    try context_a.closeElement();
    try context_a.openElementWithId(duplicate_id, fixedBox(30, 12));
    try context_a.closeElement();
    try context_a.openElementWithId(alpha_id, fixedBox(11, 13));
    try context_a.closeElement();
    try context_a.openElementWithId(delta_id, fixedBox(17, 13));
    try context_a.closeElement();
    _ = try context_a.endLayout(0);
    try out.print("collision ids {d} {d} buckets {d} {d} distinct {d} same-bucket {d}\n", .{
        alpha_id.id,
        delta_id.id,
        alpha_id.id % 8,
        delta_id.id % 8,
        @intFromBool(alpha_id.id != delta_id.id),
        @intFromBool(alpha_id.id % 8 == delta_id.id % 8),
    });
    try printErrorDelta(out, "A", "duplicate-frame", &errors_a, duplicate_error_start);
    try printQuery(out, &context_a, "A", "duplicate-ended", duplicate_id);
    try printQuery(out, &context_a, "A", "collision-alpha", alpha_id);
    try printQuery(out, &context_a, "A", "collision-delta", delta_id);

    const recovery_error_start = errors_a.length;
    try context_a.beginLayout();
    try context_a.openElementWithId(duplicate_id, fixedBox(14, 12));
    try context_a.closeElement();
    try context_a.openElementWithId(alpha_id, fixedBox(11, 13));
    try context_a.closeElement();
    try context_a.openElementWithId(delta_id, fixedBox(17, 13));
    try context_a.closeElement();
    _ = try context_a.endLayout(0);
    try printErrorDelta(out, "A", "duplicate-recovery", &errors_a, recovery_error_start);
    try printQuery(out, &context_a, "A", "duplicate-recovery", duplicate_id);
    try printQuery(out, &context_a, "A", "collision-alpha-recovery", alpha_id);
    try printQuery(out, &context_a, "A", "collision-delta-recovery", delta_id);

    try drawPointerFrame(out, &context_a, pointer_id, false);
    try context_a.setPointerState(.{ .x = 5, .y = 5 }, true);
    try printPointer(out, &context_a, "A", "press");

    try routeContext(out, "B", &context_b);
    try printPointer(out, &context_b, "B", "unchanged-during-A-press");

    try routeContext(out, "A", &context_a);
    try printPointer(out, &context_a, "A", "retained-after-switch");
    try drawPointerFrame(out, &context_a, pointer_id, true);
    try printPointer(out, &context_a, "A", "retained-after-frame");
    try context_a.setPointerState(.{ .x = 5, .y = 5 }, true);
    try printPointer(out, &context_a, "A", "held-resampled");
    try context_a.setPointerState(.{ .x = 5, .y = 5 }, false);
    try context_a.setPointerState(.{ .x = 5, .y = 5 }, false);

    try drawScroll(out, &context_a, "A", "frame-1", scroll_id, content_id, 40, 30, 90);
    try printPointer(out, &context_a, "A", "scroll-before-sample");
    try context_a.setPointerState(.{ .x = 5, .y = 5 }, false);
    try printPointer(out, &context_a, "A", "scroll-sampled");
    context_a.updateScrollContainers(false, .{ .y = -2 }, 0.016);
    try printScroll(out, &context_a, "A", "wheel", scroll_id);

    try routeContext(out, "B", &context_b);
    try printScroll(out, &context_b, "B", "isolated-missing", scroll_id);

    try routeContext(out, "A", &context_a);
    try printScroll(out, &context_a, "A", "retained-after-switch", scroll_id);
    try drawScroll(out, &context_a, "A", "frame-2", scroll_id, content_id, 40, 30, 90);
    try printScroll(out, &context_a, "A", "redrawn", scroll_id);
    context_a.updateScrollContainers(false, .{}, 0.016);

    try routeContext(out, "B", &context_b);
    try drawScroll(out, &context_b, "B", "frame-1", scroll_id, content_id, 50, 25, 75);
    try context_b.setPointerState(.{ .x = 5, .y = 5 }, false);
    try printPointer(out, &context_b, "B", "scroll-sampled");
    context_b.updateScrollContainers(false, .{ .y = -1 }, 0.016);
    try printScroll(out, &context_b, "B", "wheel", scroll_id);

    try routeContext(out, "A", &context_a);
    try printScroll(out, &context_a, "A", "unchanged-during-B-wheel", scroll_id);
    try printPointer(out, &context_a, "A", "retained-before-stale-frame");
    try drawEmpty(&context_a);
    try printPointer(out, &context_a, "A", "retained-after-stale-frame");
    context_a.updateScrollContainers(false, .{}, 0.016);
    try printScroll(out, &context_a, "A", "stale-pruned", scroll_id);
    try context_a.setPointerState(.{ .x = 5, .y = 5 }, false);
    try printPointer(out, &context_a, "A", "resampled-after-stale-frame");

    try routeContext(out, "B", &context_b);
    try printScroll(out, &context_b, "B", "retained-after-A-prune", scroll_id);

    var measure_probe_a = MeasureProbe{ .data_owner = 'A' };
    var measure_probe_b = MeasureProbe{ .data_owner = 'B' };
    context_a.setMeasureTextFunction(measureA, &measure_probe_a);
    context_b.setMeasureTextFunction(measureB, &measure_probe_b);
    try drawMeasureProbe(&context_a);
    try drawMeasureProbe(&context_b);
    try printMeasureProbe(out, "A", &measure_probe_a);
    try printMeasureProbe(out, "B", &measure_probe_b);

    var query_probe_a = QueryProbe{ .data_owner = 'A' };
    var query_probe_b = QueryProbe{ .data_owner = 'B' };
    context_a.setExternalScrollHandlingEnabled(true);
    context_a.setQueryScrollOffsetFunction(queryA, &query_probe_a);
    context_b.setExternalScrollHandlingEnabled(true);
    context_b.setQueryScrollOffsetFunction(queryB, &query_probe_b);
    try drawScroll(out, &context_a, "A", "callback-owner", callback_scroll_id, callback_content_id, 40, 30, 90);
    try drawScroll(out, &context_b, "B", "callback-owner", callback_scroll_id, callback_content_id, 50, 25, 75);
    try printQueryProbe(out, "A", &query_probe_a);
    try printQueryProbe(out, "B", &query_probe_b);

    context_a.setDebugViewWidth(321);
    context_a.setDebugViewHighlightColor(.{ .r = 1.25, .g = 2.5, .b = 3.75, .a = 4 });
    try printDebugProbe(out, "A", &context_a);
    try printDebugProbe(out, "B", &context_b);

    try printErrorDelta(out, "B", "final", &errors_b, 0);

    try routeContext(out, "A", &context_a);
    try printErrorDelta(out, "A", "final", &errors_a, 0);

    try out.flush();
}
