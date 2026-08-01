//! Compile-time ledger for the public facade translated from the pinned Clay
//! 0.14 header. The ledger is deliberately explicit: adding or removing a
//! public upstream symbol requires choosing its native Zig mapping here.

const std = @import("std");

const pinned_commit = "e6cc36941ab2af5d81107617039d6f527a1c660b";
const pinned_header_sha256 = "54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728";

const TypeMapping = struct {
    upstream: []const u8,
    native: []const u8,
};

/// Every named public data type in the pinned header. `Clay_Context` is
/// checked separately because it maps to the native engine type rather than
/// to `types.zig`.
pub const pinned_public_types = [_]TypeMapping{
    .{ .upstream = "Clay_String", .native = "String" },
    .{ .upstream = "Clay_StringSlice", .native = "StringSlice" },
    .{ .upstream = "Clay_Arena", .native = "Arena" },
    .{ .upstream = "Clay_Dimensions", .native = "Dimensions" },
    .{ .upstream = "Clay_Vector2", .native = "Vector2" },
    .{ .upstream = "Clay_Color", .native = "Color" },
    .{ .upstream = "Clay_BoundingBox", .native = "BoundingBox" },
    .{ .upstream = "Clay_ElementId", .native = "ElementId" },
    .{ .upstream = "Clay_ElementIdArray", .native = "ElementIdArray" },
    .{ .upstream = "Clay_CornerRadius", .native = "CornerRadius" },
    .{ .upstream = "Clay_LayoutDirection", .native = "LayoutDirection" },
    .{ .upstream = "Clay_LayoutAlignmentX", .native = "LayoutAlignmentX" },
    .{ .upstream = "Clay_LayoutAlignmentY", .native = "LayoutAlignmentY" },
    .{ .upstream = "Clay__SizingType", .native = "SizingType" },
    .{ .upstream = "Clay_ChildAlignment", .native = "ChildAlignment" },
    .{ .upstream = "Clay_SizingMinMax", .native = "SizingMinMax" },
    .{ .upstream = "Clay_SizingAxis", .native = "SizingAxis" },
    .{ .upstream = "Clay_Sizing", .native = "Sizing" },
    .{ .upstream = "Clay_Padding", .native = "Padding" },
    .{ .upstream = "Clay_LayoutConfig", .native = "LayoutConfig" },
    .{ .upstream = "Clay_TextElementConfigWrapMode", .native = "TextElementConfigWrapMode" },
    .{ .upstream = "Clay_TextAlignment", .native = "TextAlignment" },
    .{ .upstream = "Clay_TextElementConfig", .native = "TextElementConfig" },
    .{ .upstream = "Clay_AspectRatioElementConfig", .native = "AspectRatioElementConfig" },
    .{ .upstream = "Clay_ImageElementConfig", .native = "ImageElementConfig" },
    .{ .upstream = "Clay_FloatingAttachPointType", .native = "FloatingAttachPointType" },
    .{ .upstream = "Clay_FloatingAttachPoints", .native = "FloatingAttachPoints" },
    .{ .upstream = "Clay_PointerCaptureMode", .native = "PointerCaptureMode" },
    .{ .upstream = "Clay_FloatingAttachToElement", .native = "FloatingAttachToElement" },
    .{ .upstream = "Clay_FloatingClipToElement", .native = "FloatingClipToElement" },
    .{ .upstream = "Clay_FloatingElementConfig", .native = "FloatingElementConfig" },
    .{ .upstream = "Clay_CustomElementConfig", .native = "CustomElementConfig" },
    .{ .upstream = "Clay_ClipElementConfig", .native = "ClipElementConfig" },
    .{ .upstream = "Clay_BorderWidth", .native = "BorderWidth" },
    .{ .upstream = "Clay_BorderElementConfig", .native = "BorderElementConfig" },
    .{ .upstream = "Clay_TransitionData", .native = "TransitionData" },
    .{ .upstream = "Clay_TransitionState", .native = "TransitionState" },
    .{ .upstream = "Clay_TransitionProperty", .native = "TransitionProperty" },
    .{ .upstream = "Clay_TransitionCallbackArguments", .native = "TransitionCallbackArguments" },
    .{ .upstream = "Clay_TransitionEnterTriggerType", .native = "TransitionEnterTriggerType" },
    .{ .upstream = "Clay_TransitionExitTriggerType", .native = "TransitionExitTriggerType" },
    .{ .upstream = "Clay_TransitionInteractionHandlingType", .native = "TransitionInteractionHandlingType" },
    .{ .upstream = "Clay_ExitTransitionSiblingOrdering", .native = "ExitTransitionSiblingOrdering" },
    .{ .upstream = "Clay_TransitionElementConfig", .native = "TransitionElementConfig" },
    .{ .upstream = "Clay_TextRenderData", .native = "TextRenderData" },
    .{ .upstream = "Clay_RectangleRenderData", .native = "RectangleRenderData" },
    .{ .upstream = "Clay_ImageRenderData", .native = "ImageRenderData" },
    .{ .upstream = "Clay_CustomRenderData", .native = "CustomRenderData" },
    .{ .upstream = "Clay_ClipRenderData", .native = "ClipRenderData" },
    .{ .upstream = "Clay_OverlayColorRenderData", .native = "OverlayColorRenderData" },
    .{ .upstream = "Clay_BorderRenderData", .native = "BorderRenderData" },
    .{ .upstream = "Clay_RenderData", .native = "RenderData" },
    .{ .upstream = "Clay_ScrollContainerData", .native = "ScrollContainerData" },
    .{ .upstream = "Clay_ElementData", .native = "ElementData" },
    .{ .upstream = "Clay_RenderCommandType", .native = "RenderCommandType" },
    .{ .upstream = "Clay_RenderCommand", .native = "RenderCommand" },
    .{ .upstream = "Clay_RenderCommandArray", .native = "RenderCommandArray" },
    .{ .upstream = "Clay_PointerDataInteractionState", .native = "PointerDataInteractionState" },
    .{ .upstream = "Clay_PointerData", .native = "PointerData" },
    .{ .upstream = "Clay_ElementDeclaration", .native = "ElementDeclaration" },
    .{ .upstream = "Clay_ErrorType", .native = "ErrorType" },
    .{ .upstream = "Clay_ErrorData", .native = "ErrorData" },
    .{ .upstream = "Clay_ErrorHandler", .native = "ErrorHandler" },
};

/// C spells these as function-pointer fields or parameters rather than named
/// typedefs. Zig gives each callback shape a stable public name.
pub const pinned_public_callbacks = [_]TypeMapping{
    .{ .upstream = "bool (*handler)(Clay_TransitionCallbackArguments arguments)", .native = "TransitionHandler" },
    .{ .upstream = "(*setInitialState)(Clay_TransitionData targetState, Clay_TransitionProperty properties)", .native = "TransitionSetInitialStateFunction" },
    .{ .upstream = "(*setFinalState)(Clay_TransitionData initialState, Clay_TransitionProperty properties)", .native = "TransitionSetFinalStateFunction" },
    .{ .upstream = "(*errorHandlerFunction)(Clay_ErrorData errorText)", .native = "ErrorHandlerFunction" },
    .{ .upstream = "(*onHoverFunction)(Clay_ElementId elementId, Clay_PointerData pointerData, void *userData)", .native = "HoverFunction" },
    .{ .upstream = "(*measureTextFunction)(Clay_StringSlice text, Clay_TextElementConfig *config, void *userData)", .native = "MeasureTextFunction" },
    .{ .upstream = "(*queryScrollOffsetFunction)(uint32_t elementId, void *userData)", .native = "QueryScrollOffsetFunction" },
};

const MappingKind = enum {
    context_method,
    type_method,
    root_helper,
    module_helper,
    explicit_context,
    intentional_divergence,
};

const FunctionMapping = struct {
    upstream: []const u8,
    owner: []const u8,
    native: []const u8,
    kind: MappingKind,
};

/// All 34 functions declared under "Public API functions" in the pinned
/// header. Intentional allocator/current-context differences receive an
/// explicit disposition so they cannot disappear or be overstated silently.
pub const pinned_public_functions = [_]FunctionMapping{
    .{ .upstream = "Clay_MinMemorySize", .owner = "allocator model", .native = "no byte-exact equivalent", .kind = .intentional_divergence },
    .{ .upstream = "Clay_CreateArenaWithCapacityAndMemory", .owner = "Arena", .native = "init", .kind = .type_method },
    .{ .upstream = "Clay_SetPointerState", .owner = "Context", .native = "setPointerState", .kind = .context_method },
    .{ .upstream = "Clay_GetPointerState", .owner = "Context", .native = "getPointerState", .kind = .context_method },
    .{ .upstream = "Clay_Initialize", .owner = "Context", .native = "init", .kind = .context_method },
    .{ .upstream = "Clay_GetCurrentContext", .owner = "Context", .native = "explicit parameter", .kind = .explicit_context },
    .{ .upstream = "Clay_SetCurrentContext", .owner = "Context", .native = "explicit parameter", .kind = .explicit_context },
    .{ .upstream = "Clay_UpdateScrollContainers", .owner = "Context", .native = "updateScrollContainers", .kind = .context_method },
    .{ .upstream = "Clay_GetScrollOffset", .owner = "Context", .native = "getScrollOffset", .kind = .context_method },
    .{ .upstream = "Clay_SetLayoutDimensions", .owner = "Context", .native = "setLayoutDimensions", .kind = .context_method },
    .{ .upstream = "Clay_GetLayoutDimensions", .owner = "Context", .native = "getLayoutDimensions", .kind = .context_method },
    .{ .upstream = "Clay_BeginLayout", .owner = "Context", .native = "beginLayout", .kind = .context_method },
    .{ .upstream = "Clay_EndLayout", .owner = "Context", .native = "endLayout", .kind = .context_method },
    .{ .upstream = "Clay_GetOpenElementId", .owner = "Context", .native = "getOpenElementId", .kind = .context_method },
    .{ .upstream = "Clay_GetElementId", .owner = "Context", .native = "getElementId", .kind = .context_method },
    .{ .upstream = "Clay_GetElementIdWithIndex", .owner = "Context", .native = "getElementIdWithIndex", .kind = .context_method },
    .{ .upstream = "Clay_GetElementData", .owner = "Context", .native = "getElementData", .kind = .context_method },
    .{ .upstream = "Clay_Hovered", .owner = "Context", .native = "hovered", .kind = .context_method },
    .{ .upstream = "Clay_OnHover", .owner = "Context", .native = "onHover", .kind = .context_method },
    .{ .upstream = "Clay_PointerOver", .owner = "Context", .native = "pointerOver", .kind = .context_method },
    .{ .upstream = "Clay_GetPointerOverIds", .owner = "Context", .native = "getPointerOverIds", .kind = .context_method },
    .{ .upstream = "Clay_GetScrollContainerData", .owner = "Context", .native = "getScrollContainerData", .kind = .context_method },
    .{ .upstream = "Clay_SetMeasureTextFunction", .owner = "Context", .native = "setMeasureTextFunction", .kind = .context_method },
    .{ .upstream = "Clay_SetQueryScrollOffsetFunction", .owner = "Context", .native = "setQueryScrollOffsetFunction", .kind = .context_method },
    .{ .upstream = "Clay_RenderCommandArray_Get", .owner = "RenderCommandArray", .native = "get", .kind = .type_method },
    .{ .upstream = "Clay_SetDebugModeEnabled", .owner = "Context", .native = "setDebugModeEnabled", .kind = .context_method },
    .{ .upstream = "Clay_IsDebugModeEnabled", .owner = "Context", .native = "isDebugModeEnabled", .kind = .context_method },
    .{ .upstream = "Clay_SetCullingEnabled", .owner = "Context", .native = "setCullingEnabled", .kind = .context_method },
    .{ .upstream = "Clay_GetMaxElementCount", .owner = "Context", .native = "getMaxElementCount", .kind = .context_method },
    .{ .upstream = "Clay_SetMaxElementCount", .owner = "Context", .native = "setMaxElementCount", .kind = .context_method },
    .{ .upstream = "Clay_GetMaxMeasureTextCacheWordCount", .owner = "Context", .native = "getMaxMeasureTextCacheWordCount", .kind = .context_method },
    .{ .upstream = "Clay_SetMaxMeasureTextCacheWordCount", .owner = "Context", .native = "setMaxMeasureTextCacheWordCount", .kind = .context_method },
    .{ .upstream = "Clay_ResetMeasureTextCache", .owner = "Context", .native = "resetMeasureTextCache", .kind = .context_method },
    .{ .upstream = "Clay_EaseOut", .owner = "root", .native = "easeOut", .kind = .root_helper },
};

/// This public function exists in the implementation at the pinned commit but
/// is accidentally absent from its forward-declaration block.
pub const pinned_implementation_only_functions = [_]FunctionMapping{
    .{ .upstream = "Clay_SetExternalScrollHandlingEnabled", .owner = "Context", .native = "setExternalScrollHandlingEnabled", .kind = .context_method },
};

/// The eight exported operations used by the C declaration macros.
pub const pinned_macro_support_functions = [_]FunctionMapping{
    .{ .upstream = "Clay__OpenElement", .owner = "Context", .native = "openElementUnconfigured", .kind = .context_method },
    .{ .upstream = "Clay__OpenElementWithId", .owner = "Context", .native = "openElementWithIdUnconfigured", .kind = .context_method },
    .{ .upstream = "Clay__ConfigureOpenElement", .owner = "Context", .native = "configureOpenElement", .kind = .context_method },
    .{ .upstream = "Clay__ConfigureOpenElementPtr", .owner = "Context", .native = "configureOpenElement", .kind = .context_method },
    .{ .upstream = "Clay__CloseElement", .owner = "Context", .native = "closeElement", .kind = .context_method },
    .{ .upstream = "Clay__HashString", .owner = "hash", .native = "string", .kind = .module_helper },
    .{ .upstream = "Clay__HashStringWithOffset", .owner = "hash", .native = "stringWithOffset", .kind = .module_helper },
    .{ .upstream = "Clay__OpenTextElement", .owner = "Context", .native = "text", .kind = .context_method },
};

const MacroMapping = struct {
    upstream: []const u8,
    native: []const u8,
};

/// Public macro spellings and their native Zig declaration helpers. Entries
/// mapped to a Zig construct remain explicit even though there is no decl to
/// reflect (`@min`, `@max`, and struct literals).
pub const pinned_public_macros = [_]MacroMapping{
    .{ .upstream = "CLAY__MAX", .native = "clayMax" },
    .{ .upstream = "CLAY__MIN", .native = "clayMin" },
    .{ .upstream = "CLAY_TEXT_CONFIG", .native = "TextElementConfig literal" },
    .{ .upstream = "CLAY_BORDER_OUTSIDE", .native = "borderOutside" },
    .{ .upstream = "CLAY_BORDER_ALL", .native = "borderAll" },
    .{ .upstream = "CLAY_CORNER_RADIUS", .native = "cornerRadius" },
    .{ .upstream = "CLAY_PADDING_ALL", .native = "padding" },
    .{ .upstream = "CLAY_SIZING_FIT", .native = "fit / fitMin / fitMinMax" },
    .{ .upstream = "CLAY_SIZING_GROW", .native = "grow / growMin / growMinMax" },
    .{ .upstream = "CLAY_SIZING_FIXED", .native = "fixed" },
    .{ .upstream = "CLAY_SIZING_PERCENT", .native = "percent" },
    .{ .upstream = "CLAY_ID", .native = "Context.staticId" },
    .{ .upstream = "CLAY_SID", .native = "Context.getElementId" },
    .{ .upstream = "CLAY_IDI", .native = "Context.staticIndexedId" },
    .{ .upstream = "CLAY_SIDI", .native = "Context.getElementIdWithIndex" },
    .{ .upstream = "CLAY_ID_LOCAL", .native = "Context.staticLocalId" },
    .{ .upstream = "CLAY_SID_LOCAL", .native = "Context.getLocalElementId" },
    .{ .upstream = "CLAY_IDI_LOCAL", .native = "Context.staticIndexedLocalId" },
    .{ .upstream = "CLAY_SIDI_LOCAL", .native = "Context.getLocalElementIdWithIndex" },
    .{ .upstream = "CLAY__STRING_LENGTH", .native = "slice.len / String.length" },
    .{ .upstream = "CLAY__ENSURE_STRING_LITERAL", .native = "String.literal comptime parameter" },
    .{ .upstream = "CLAY_STRING", .native = "String.literal" },
    .{ .upstream = "CLAY_STRING_CONST", .native = "String.literal" },
    .{ .upstream = "CLAY_AUTO_ID", .native = "Context.element / Context.elementDeferred" },
    .{ .upstream = "CLAY", .native = "Context.elementWithId / Context.elementWithIdDeferred" },
    .{ .upstream = "CLAY_TEXT", .native = "Context.text" },
};

const GlobalMapping = struct {
    upstream: []const u8,
    native: []const u8,
};

pub const pinned_public_globals = [_]GlobalMapping{
    .{ .upstream = "CLAY_LAYOUT_DEFAULT", .native = "layout_default" },
    .{ .upstream = "Clay__debugViewHighlightColor", .native = "Context.get/setDebugViewHighlightColor" },
    .{ .upstream = "Clay__debugViewWidth", .native = "Context.get/setDebugViewWidth" },
};

/// Native public surface that has no one-to-one C type. Keeping this separate
/// avoids presenting Zig-only ergonomics as upstream API parity.
pub const native_type_additions = [_][]const u8{
    "SizingAxisSize",
    "TransitionEnterConfig",
    "TransitionExitConfig",
    "ContextOptions",
    "ContextError",
    "DebugViewTheme",
};

/// Renderer/profile are deliberately separate native additions.
pub const renderer_additions = [_][]const u8{
    "Error",
    "Stats",
    "validate",
    "validateArray",
    "consume",
    "consumeArray",
};

pub const profile_additions = [_][]const u8{
    "Snapshot",
    "FixedBufferProfiler",
};

fn requirePinnedSymbol(header: []const u8, symbol: []const u8) !void {
    if (symbol.len == 0) return error.UnnamedPinnedFacadeSymbol;
    if (std.mem.indexOf(u8, header, symbol) == null) {
        std.debug.print("pinned facade ledger symbol is absent from tests/oracle/clay.h: {s}\n", .{symbol});
        return error.PinnedFacadeSymbolMissing;
    }
}

fn requireAlias(comptime facade_type: type, comptime source_type: type, comptime name: []const u8) void {
    if (facade_type != source_type) {
        @compileError(name ++ " must remain a direct public alias");
    }
}

fn requireDecl(comptime owner: type, comptime name: []const u8, comptime label: []const u8) void {
    if (!@hasDecl(owner, name)) @compileError(label ++ " is missing native declaration " ++ name);
}

fn requireFunctionParams(comptime function: anytype, comptime params: []const type, comptime name: []const u8) @TypeOf(@typeInfo(@TypeOf(function)).@"fn") {
    const info = @typeInfo(@TypeOf(function)).@"fn";
    if (info.is_generic) @compileError(name ++ " unexpectedly became generic");
    if (info.is_var_args) @compileError(name ++ " unexpectedly became variadic");
    if (info.params.len != params.len) @compileError(name ++ " parameter count changed");
    inline for (params, 0..) |expected, index| {
        if (info.params[index].type == null or info.params[index].type.? != expected) {
            @compileError(name ++ " parameter type changed");
        }
    }
    return info;
}

fn requireExactSignature(
    comptime function: anytype,
    comptime params: []const type,
    comptime return_type: type,
    comptime name: []const u8,
) void {
    const info = requireFunctionParams(function, params, name);
    if (info.return_type == null or info.return_type.? != return_type) {
        @compileError(name ++ " return type changed");
    }
}

fn requireFallibleSignature(
    comptime function: anytype,
    comptime params: []const type,
    comptime payload: type,
    comptime name: []const u8,
) void {
    const info = requireFunctionParams(function, params, name);
    if (info.return_type == null) @compileError(name ++ " lost its return type");
    const return_info = @typeInfo(info.return_type.?);
    if (return_info != .error_union or return_info.error_union.payload != payload) {
        @compileError(name ++ " must return an error union with the mapped payload");
    }
}

fn requireGenericSignature(
    comptime function: anytype,
    comptime params: []const ?type,
    comptime name: []const u8,
) void {
    const info = @typeInfo(@TypeOf(function)).@"fn";
    if (!info.is_generic) @compileError(name ++ " must remain generic");
    if (info.is_var_args) @compileError(name ++ " unexpectedly became variadic");
    if (info.params.len != params.len) @compileError(name ++ " parameter count changed");
    inline for (params, 0..) |expected, index| {
        if (expected) |expected_type| {
            if (info.params[index].type == null or info.params[index].type.? != expected_type) {
                @compileError(name ++ " fixed parameter type changed");
            }
        }
    }
}

fn verifyMappingDecls(comptime zlay: type) void {
    inline for (pinned_public_functions) |mapping| {
        switch (mapping.kind) {
            .context_method => requireDecl(zlay.Context, mapping.native, mapping.upstream),
            .type_method => if (std.mem.eql(u8, mapping.owner, "Arena")) {
                requireDecl(zlay.Arena, mapping.native, mapping.upstream);
            } else {
                requireDecl(zlay.RenderCommandArray, mapping.native, mapping.upstream);
            },
            .root_helper => requireDecl(zlay, mapping.native, mapping.upstream),
            .module_helper => if (std.mem.eql(u8, mapping.owner, "hash")) {
                requireDecl(zlay.hash, mapping.native, mapping.upstream);
            } else {
                requireDecl(zlay.profile.FixedBufferProfiler, mapping.native, mapping.upstream);
            },
            .explicit_context => requireDecl(zlay, "Context", mapping.upstream),
            .intentional_divergence => requireDecl(zlay, "Context", mapping.upstream),
        }
    }

    inline for (pinned_implementation_only_functions) |mapping| {
        requireDecl(zlay.Context, mapping.native, mapping.upstream);
    }

    inline for (pinned_macro_support_functions) |mapping| {
        if (mapping.kind == .context_method) {
            requireDecl(zlay.Context, mapping.native, mapping.upstream);
        } else {
            requireDecl(zlay.hash, mapping.native, mapping.upstream);
        }
    }
}

fn verifyFunctionSignatures(comptime zlay: type) void {
    const Context = zlay.Context;
    const Allocator = std.mem.Allocator;

    requireExactSignature(zlay.Arena.init, &.{[]u8}, zlay.Arena, "Clay_CreateArenaWithCapacityAndMemory mapping");
    requireFallibleSignature(Context.setPointerState, &.{ *Context, zlay.Vector2, bool }, void, "Clay_SetPointerState");
    requireExactSignature(Context.getPointerState, &.{*const Context}, zlay.PointerData, "Clay_GetPointerState");
    requireExactSignature(Context.init, &.{ Allocator, zlay.Dimensions, zlay.ContextOptions }, Context, "Clay_Initialize");
    requireExactSignature(Context.updateScrollContainers, &.{ *Context, bool, zlay.Vector2, f32 }, void, "Clay_UpdateScrollContainers");
    requireExactSignature(Context.getScrollOffset, &.{*Context}, zlay.Vector2, "Clay_GetScrollOffset");
    requireExactSignature(Context.setLayoutDimensions, &.{ *Context, zlay.Dimensions }, void, "Clay_SetLayoutDimensions");
    requireExactSignature(Context.getLayoutDimensions, &.{*const Context}, zlay.Dimensions, "Clay_GetLayoutDimensions");
    requireFallibleSignature(Context.beginLayout, &.{*Context}, void, "Clay_BeginLayout");
    requireFallibleSignature(Context.endLayout, &.{ *Context, f32 }, zlay.RenderCommandArray, "Clay_EndLayout");
    requireFallibleSignature(Context.getOpenElementId, &.{*const Context}, u32, "Clay_GetOpenElementId");
    requireExactSignature(Context.getElementId, &.{ *const Context, zlay.String }, zlay.ElementId, "Clay_GetElementId");
    requireExactSignature(Context.getElementIdWithIndex, &.{ *const Context, zlay.String, u32 }, zlay.ElementId, "Clay_GetElementIdWithIndex");
    requireExactSignature(Context.getElementData, &.{ *const Context, zlay.ElementId }, zlay.ElementData, "Clay_GetElementData");
    requireExactSignature(Context.hovered, &.{*const Context}, bool, "Clay_Hovered");
    requireFallibleSignature(Context.onHover, &.{ *Context, ?zlay.HoverFunction, ?*anyopaque }, void, "Clay_OnHover");
    requireExactSignature(Context.pointerOver, &.{ *const Context, zlay.ElementId }, bool, "Clay_PointerOver");
    requireExactSignature(Context.getPointerOverIds, &.{*Context}, zlay.ElementIdArray, "Clay_GetPointerOverIds");
    requireExactSignature(Context.getScrollContainerData, &.{ *Context, zlay.ElementId }, zlay.ScrollContainerData, "Clay_GetScrollContainerData");
    requireExactSignature(Context.setMeasureTextFunction, &.{ *Context, ?zlay.MeasureTextFunction, ?*anyopaque }, void, "Clay_SetMeasureTextFunction");
    requireExactSignature(Context.setQueryScrollOffsetFunction, &.{ *Context, ?zlay.QueryScrollOffsetFunction, ?*anyopaque }, void, "Clay_SetQueryScrollOffsetFunction");
    requireExactSignature(zlay.RenderCommandArray.get, &.{ *zlay.RenderCommandArray, i32 }, ?*zlay.RenderCommand, "Clay_RenderCommandArray_Get");
    requireExactSignature(Context.setDebugModeEnabled, &.{ *Context, bool }, void, "Clay_SetDebugModeEnabled");
    requireExactSignature(Context.isDebugModeEnabled, &.{*const Context}, bool, "Clay_IsDebugModeEnabled");
    requireExactSignature(Context.setCullingEnabled, &.{ *Context, bool }, void, "Clay_SetCullingEnabled");
    requireExactSignature(Context.getMaxElementCount, &.{*const Context}, usize, "Clay_GetMaxElementCount");
    requireExactSignature(Context.setMaxElementCount, &.{ *Context, usize }, void, "Clay_SetMaxElementCount");
    requireExactSignature(Context.getMaxMeasureTextCacheWordCount, &.{*const Context}, usize, "Clay_GetMaxMeasureTextCacheWordCount");
    requireExactSignature(Context.setMaxMeasureTextCacheWordCount, &.{ *Context, usize }, void, "Clay_SetMaxMeasureTextCacheWordCount");
    requireExactSignature(Context.resetMeasureTextCache, &.{*Context}, void, "Clay_ResetMeasureTextCache");
    requireExactSignature(zlay.easeOut, &.{zlay.TransitionCallbackArguments}, bool, "Clay_EaseOut");

    requireExactSignature(Context.setExternalScrollHandlingEnabled, &.{ *Context, bool }, void, "Clay_SetExternalScrollHandlingEnabled");

    requireFallibleSignature(Context.openElementUnconfigured, &.{*Context}, void, "Clay__OpenElement");
    requireFallibleSignature(Context.openElementWithIdUnconfigured, &.{ *Context, zlay.ElementId }, void, "Clay__OpenElementWithId");
    requireFallibleSignature(Context.configureOpenElement, &.{ *Context, zlay.ElementDeclaration }, void, "Clay__ConfigureOpenElement");
    requireFallibleSignature(Context.closeElement, &.{*Context}, void, "Clay__CloseElement");
    requireExactSignature(zlay.hash.string, &.{ zlay.String, u32 }, zlay.ElementId, "Clay__HashString");
    requireExactSignature(zlay.hash.stringWithOffset, &.{ zlay.String, u32, u32 }, zlay.ElementId, "Clay__HashStringWithOffset");
    requireFallibleSignature(Context.text, &.{ *Context, zlay.String, zlay.TextElementConfig }, void, "Clay__OpenTextElement");

    requireExactSignature(Context.setDebugViewHighlightColor, &.{ *Context, zlay.Color }, void, "Clay__debugViewHighlightColor replacement");
    requireExactSignature(Context.getDebugViewHighlightColor, &.{*const Context}, zlay.Color, "Clay__debugViewHighlightColor read replacement");
    requireExactSignature(Context.setDebugViewWidth, &.{ *Context, u32 }, void, "Clay__debugViewWidth replacement");
    requireExactSignature(Context.getDebugViewWidth, &.{*const Context}, u32, "Clay__debugViewWidth read replacement");
}

fn verifyMacroHelpers(comptime zlay: type) void {
    requireGenericSignature(zlay.clayMax, &.{ null, null }, "CLAY__MAX");
    requireGenericSignature(zlay.clayMin, &.{ null, null }, "CLAY__MIN");
    requireExactSignature(zlay.fit, &.{}, zlay.SizingAxis, "CLAY_SIZING_FIT");
    requireExactSignature(zlay.fitMin, &.{f32}, zlay.SizingAxis, "CLAY_SIZING_FIT minimum");
    requireExactSignature(zlay.fitMinMax, &.{ f32, f32 }, zlay.SizingAxis, "CLAY_SIZING_FIT bounds");
    requireExactSignature(zlay.grow, &.{}, zlay.SizingAxis, "CLAY_SIZING_GROW");
    requireExactSignature(zlay.growMin, &.{f32}, zlay.SizingAxis, "CLAY_SIZING_GROW minimum");
    requireExactSignature(zlay.growMinMax, &.{ f32, f32 }, zlay.SizingAxis, "CLAY_SIZING_GROW bounds");
    requireExactSignature(zlay.fixed, &.{f32}, zlay.SizingAxis, "CLAY_SIZING_FIXED");
    requireExactSignature(zlay.percent, &.{f32}, zlay.SizingAxis, "CLAY_SIZING_PERCENT");
    requireExactSignature(zlay.padding, &.{u16}, zlay.Padding, "CLAY_PADDING_ALL");
    requireExactSignature(zlay.cornerRadius, &.{f32}, zlay.CornerRadius, "CLAY_CORNER_RADIUS");
    requireExactSignature(zlay.borderOutside, &.{u16}, zlay.BorderWidth, "CLAY_BORDER_OUTSIDE");
    requireExactSignature(zlay.borderAll, &.{u16}, zlay.BorderWidth, "CLAY_BORDER_ALL");

    requireExactSignature(zlay.String.fromSlice, &.{[]const u8}, zlay.String, "dynamic Clay_String replacement");
    requireGenericSignature(zlay.String.literal, &.{[]const u8}, "CLAY_STRING");
    requireGenericSignature(zlay.Context.staticId, &.{ *const zlay.Context, []const u8 }, "CLAY_ID");
    requireExactSignature(zlay.Context.getElementId, &.{ *const zlay.Context, zlay.String }, zlay.ElementId, "CLAY_SID");
    requireGenericSignature(zlay.Context.staticIndexedId, &.{ *const zlay.Context, []const u8, u32 }, "CLAY_IDI");
    requireExactSignature(zlay.Context.getElementIdWithIndex, &.{ *const zlay.Context, zlay.String, u32 }, zlay.ElementId, "CLAY_SIDI");
    requireGenericSignature(zlay.Context.staticLocalId, &.{ *const zlay.Context, []const u8 }, "CLAY_ID_LOCAL");
    requireFallibleSignature(zlay.Context.getLocalElementId, &.{ *const zlay.Context, zlay.String }, zlay.ElementId, "CLAY_SID_LOCAL");
    requireGenericSignature(zlay.Context.staticIndexedLocalId, &.{ *const zlay.Context, []const u8, u32 }, "CLAY_IDI_LOCAL");
    requireFallibleSignature(zlay.Context.getLocalElementIdWithIndex, &.{ *const zlay.Context, zlay.String, u32 }, zlay.ElementId, "CLAY_SIDI_LOCAL");

    requireGenericSignature(zlay.Context.element, &.{ *zlay.Context, zlay.ElementDeclaration, null }, "CLAY_AUTO_ID");
    requireGenericSignature(zlay.Context.elementDeferred, &.{ *zlay.Context, null, null }, "CLAY_AUTO_ID deferred");
    requireGenericSignature(zlay.Context.elementWithId, &.{ *zlay.Context, zlay.ElementId, zlay.ElementDeclaration, null }, "CLAY");
    requireGenericSignature(zlay.Context.elementWithIdDeferred, &.{ *zlay.Context, zlay.ElementId, null, null }, "CLAY deferred");
    requireFallibleSignature(zlay.Context.text, &.{ *zlay.Context, zlay.String, zlay.TextElementConfig }, void, "CLAY_TEXT");
}

fn verifyNativeAdditions(comptime zlay: type) void {
    requireAlias(zlay.SizingAxisSize, zlay.types.SizingAxisSize, "SizingAxisSize");
    requireAlias(zlay.TransitionEnterConfig, zlay.types.TransitionEnterConfig, "TransitionEnterConfig");
    requireAlias(zlay.TransitionExitConfig, zlay.types.TransitionExitConfig, "TransitionExitConfig");
    requireAlias(zlay.ContextOptions, zlay.engine.Options, "ContextOptions");
    requireAlias(zlay.ContextError, zlay.engine.Error, "ContextError");
    requireAlias(zlay.DebugViewTheme, zlay.debug.Theme, "DebugViewTheme");
    requireExactSignature(
        zlay.Context.setDebugViewTheme,
        &.{ *zlay.Context, zlay.DebugViewTheme },
        void,
        "debug view theme setter",
    );
    requireExactSignature(
        zlay.Context.getDebugViewTheme,
        &.{*const zlay.Context},
        zlay.DebugViewTheme,
        "debug view theme getter",
    );
    requireAlias(
        @TypeOf(zlay.debug_view_accessibility_theme),
        zlay.DebugViewTheme,
        "debug view accessibility theme",
    );
    requireAlias(zlay.ParagraphProvider, zlay.paragraph_provider.Provider, "ParagraphProvider");
    requireAlias(zlay.ParagraphTextStyle, zlay.paragraph_provider.TextStyle, "ParagraphTextStyle");
    requireAlias(zlay.ParagraphRenderData, zlay.paragraph_provider.RenderData, "ParagraphRenderData");
    requireExactSignature(zlay.Context.setParagraphProvider, &.{ *zlay.Context, ?zlay.ParagraphProvider }, void, "optional paragraph provider setter");
    requireExactSignature(zlay.Context.getParagraphProvider, &.{*const zlay.Context}, ?zlay.ParagraphProvider, "optional paragraph provider getter");
    requireExactSignature(zlay.Context.getLastParagraphProviderFailure, &.{*const zlay.Context}, ?zlay.ParagraphProviderFailure, "paragraph provider diagnostic");
    requireExactSignature(zlay.Context.paragraphRenderData, &.{ *const zlay.Context, *const zlay.RenderCommand }, ?*const zlay.ParagraphRenderData, "paragraph command resolver");
    requireFallibleSignature(zlay.Context.textWithParagraphStyle, &.{ *zlay.Context, zlay.String, zlay.TextElementConfig, zlay.ParagraphTextStyle }, void, "advanced paragraph text");
    requireFallibleSignature(zlay.Context.textSliceWithParagraphStyle, &.{ *zlay.Context, []const u8, zlay.TextElementConfig, zlay.ParagraphTextStyle }, void, "advanced paragraph text slice");
    requireExactSignature(zlay.ParagraphTextStyle.fromLegacy, &.{zlay.TextElementConfig}, zlay.ParagraphTextStyle, "legacy paragraph style bridge");

    inline for (renderer_additions) |name| requireDecl(zlay.renderer, name, "renderer addition");
    requireExactSignature(zlay.renderer.validate, &.{[]const zlay.RenderCommand}, zlay.renderer.Error!zlay.renderer.Stats, "renderer.validate");
    requireExactSignature(zlay.renderer.validateArray, &.{zlay.RenderCommandArray}, zlay.renderer.Error!zlay.renderer.Stats, "renderer.validateArray");
    requireGenericSignature(zlay.renderer.consume, &.{ type, null, []const zlay.RenderCommand }, "renderer.consume");
    requireGenericSignature(zlay.renderer.consumeArray, &.{ type, null, zlay.RenderCommandArray }, "renderer.consumeArray");

    inline for (profile_additions) |name| requireDecl(zlay.profile, name, "profile addition");
    requireExactSignature(zlay.profile.FixedBufferProfiler.init, &.{[]u8}, zlay.profile.FixedBufferProfiler, "profile.FixedBufferProfiler.init");
    requireExactSignature(zlay.profile.FixedBufferProfiler.allocator, &.{*zlay.profile.FixedBufferProfiler}, std.mem.Allocator, "profile.FixedBufferProfiler.allocator");
    requireExactSignature(zlay.profile.FixedBufferProfiler.snapshot, &.{*const zlay.profile.FixedBufferProfiler}, zlay.profile.Snapshot, "profile.FixedBufferProfiler.snapshot");
    requireExactSignature(zlay.profile.FixedBufferProfiler.reset, &.{*zlay.profile.FixedBufferProfiler}, void, "profile.FixedBufferProfiler.reset");
    requireExactSignature(zlay.profile.Snapshot.headroomBytes, &.{zlay.profile.Snapshot}, usize, "profile.Snapshot.headroomBytes");
}

fn verifyPinnedHeaderSymbols(header: []const u8) !void {
    try requirePinnedSymbol(header, "Clay_Context");
    for (pinned_public_types) |mapping| try requirePinnedSymbol(header, mapping.upstream);
    for (pinned_public_callbacks) |mapping| try requirePinnedSymbol(header, mapping.upstream);
    for (pinned_public_functions) |mapping| try requirePinnedSymbol(header, mapping.upstream);
    for (pinned_implementation_only_functions) |mapping| try requirePinnedSymbol(header, mapping.upstream);
    for (pinned_macro_support_functions) |mapping| try requirePinnedSymbol(header, mapping.upstream);
    for (pinned_public_macros) |mapping| try requirePinnedSymbol(header, mapping.upstream);
    for (pinned_public_globals) |mapping| try requirePinnedSymbol(header, mapping.upstream);
}

pub fn expectPublicFacade(comptime zlay: type) !void {
    comptime {
        @setEvalBranchQuota(50_000_000);
        if (!std.mem.eql(u8, zlay.upstream_commit, pinned_commit)) {
            @compileError("facade ledger pin does not match root.upstream_commit");
        }
        if (!std.mem.eql(u8, zlay.upstream_header_sha256, pinned_header_sha256)) {
            @compileError("facade ledger pin does not match root.upstream_header_sha256");
        }
        if (pinned_public_types.len != 63 or
            pinned_public_callbacks.len != 7 or
            pinned_public_functions.len != 34 or
            pinned_implementation_only_functions.len != 1 or
            pinned_macro_support_functions.len != 8 or
            pinned_public_macros.len != 26 or
            pinned_public_globals.len != 3)
        {
            @compileError("pinned Clay 0.14 public ledger count changed; audit the header before updating it");
        }

        requireAlias(zlay.Context, zlay.engine.Context, "Context");
        for (pinned_public_types) |mapping| {
            requireAlias(@field(zlay, mapping.native), @field(zlay.types, mapping.native), mapping.native);
        }
        for (pinned_public_callbacks) |mapping| {
            requireAlias(@field(zlay, mapping.native), @field(zlay.types, mapping.native), mapping.native);
        }

        verifyMappingDecls(zlay);
        verifyFunctionSignatures(zlay);
        verifyMacroHelpers(zlay);
        verifyNativeAdditions(zlay);

        if (@TypeOf(zlay.layout_default) != *zlay.LayoutConfig) {
            @compileError("layout_default must expose mutable LayoutConfig storage");
        }
    }

    const header = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/oracle/clay.h",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(header);

    var actual_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(header, &actual_digest, .{});
    var expected_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_digest, pinned_header_sha256);
    try std.testing.expectEqualSlices(u8, &expected_digest, &actual_digest);
    try verifyPinnedHeaderSymbols(header);

    try std.testing.expectEqual(zlay.LayoutDirection.left_to_right, zlay.layout_default.layout_direction);
    try std.testing.expectEqual(zlay.SizingType.fit, zlay.layout_default.sizing.width.type);
    try std.testing.expectEqual(@as(u16, 0), zlay.layout_default.padding.left);
}
