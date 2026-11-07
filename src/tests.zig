const zlay = @import("zlay");

test {
    _ = zlay;
    _ = @import("integration_tests.zig");
    _ = @import("audit_regression_tests.zig");
    _ = @import("exit_transition_tests.zig");
    _ = @import("declaration_order_tests.zig");
    _ = @import("deep_render_tests.zig");
    _ = @import("allocation_discipline_tests.zig");
    _ = @import("debug_inspector_tests.zig");
    _ = @import("public_metadata_tests.zig");
    _ = @import("retained_reference_tests.zig");
}

test "root exposes the complete public helper and callback facade" {
    try @import("facade_tests.zig").expectPublicFacade(zlay);
}
