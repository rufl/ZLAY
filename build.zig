const std = @import("std");
const builtin = @import("builtin");

const embedded_build_zig_sha256 = blk: {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("build.zig"), &digest, .{});
    break :blk std.fmt.bytesToHex(digest, .lower);
};
const embedded_build_zig_source = @embedFile("build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aarch64_evidence_out = b.option(
        []const u8,
        "aarch64-evidence-out",
        "Durable output path for a raw native-AArch64 hash execution record",
    );
    const aarch64_provenance = b.option(
        []const u8,
        "aarch64-provenance",
        "Runner provenance JSON consumed by native AArch64 certification",
    );
    const aarch64_evidence = b.option(
        []const u8,
        "aarch64-evidence",
        "Raw AArch64 hash evidence JSON to validate or import",
    );
    const aarch64_import_out = b.option(
        []const u8,
        "aarch64-import-out",
        "Durable output path for an imported, still-pending evidence record",
    );
    const aarch64_runner_record = b.option(
        []const u8,
        "aarch64-runner-record",
        "Immutable runner identity/inventory record preflight-bound before certification and review",
    );
    const aarch64_certification_log = b.option(
        []const u8,
        "aarch64-certification-log",
        "Completed native certification log to bind into a review receipt",
    );
    const aarch64_review_statement = b.option(
        []const u8,
        "aarch64-review-statement",
        "Human reviewer statement JSON consumed when creating a review receipt",
    );
    const aarch64_review_out = b.option(
        []const u8,
        "aarch64-review-out",
        "Durable output path for a new AArch64 review receipt",
    );
    const aarch64_review_receipt = b.option(
        []const u8,
        "aarch64-review-receipt",
        "AArch64 review receipt JSON to validate",
    );

    const zlay = b.addModule("zlay", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module_tests = b.addTest(.{
        .root_module = zlay,
    });
    const run_tests = b.addRunArtifact(module_tests);

    const ordinary_manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/ordinary_manifest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ordinary_manifest_tests = b.addRunArtifact(ordinary_manifest_tests);

    const example = b.addExecutable(.{
        .name = "zlay-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run the renderer-neutral basic example");
    example_step.dependOn(&run_example.step);

    const paragraph_provider_example = b.addExecutable(.{
        .name = "zlay-paragraph-provider-mock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/paragraph_provider_mock.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    b.installArtifact(paragraph_provider_example);
    const run_paragraph_provider_example = b.addRunArtifact(paragraph_provider_example);
    const paragraph_provider_example_step = b.step(
        "paragraph-provider-example",
        "Run the mock paragraph provider and retained-render lease example",
    );
    paragraph_provider_example_step.dependOn(&run_paragraph_provider_example.step);

    const renderer_smoke = b.addExecutable(.{
        .name = "zlay-renderer-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/renderer_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    b.installArtifact(renderer_smoke);
    const run_renderer_smoke = b.addRunArtifact(renderer_smoke);
    const renderer_smoke_step = b.step("renderer-smoke", "Run the deterministic native renderer adapter smoke");
    renderer_smoke_step.dependOn(&run_renderer_smoke.step);

    const fixed_buffer_profile = b.addExecutable(.{
        .name = "zlay-fixed-buffer-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/fixed_buffer_profile.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    b.installArtifact(fixed_buffer_profile);
    const run_fixed_buffer_profile = b.addRunArtifact(fixed_buffer_profile);
    const fixed_buffer_profile_step = b.step("profile", "Run the repeatable fixed-buffer high-water profile");
    fixed_buffer_profile_step.dependOn(&run_fixed_buffer_profile.step);

    const run_consumer_smoke = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "run",
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        "--cache-dir",
        "../../.zig-cache/consumer-smoke",
    });
    run_consumer_smoke.setCwd(b.path("tests/consumer"));
    const consumer_smoke_step = b.step("consumer-smoke", "Build and run a real path-dependency consumer");
    consumer_smoke_step.dependOn(&run_consumer_smoke.step);

    const aarch64_evidence_contract_tests = b.addSystemCommand(&.{
        "python3",
        "-B",
        "-m",
        "unittest",
        "tests/test_aarch64_hash_evidence.py",
        "-v",
    });
    const aarch64_evidence_audit_step = b.step(
        "aarch64-hash-evidence-audit",
        "Test the fail-closed raw AArch64 execution-record contract",
    );
    aarch64_evidence_audit_step.dependOn(&aarch64_evidence_contract_tests.step);

    const aarch64_hash_build_contract_tests = b.addSystemCommand(&.{
        "python3",
        "-B",
        "-m",
        "unittest",
        "tests/test_aarch64_hash_build_contract.py",
        "-v",
    });
    const aarch64_hash_build_contract_audit_step = b.step(
        "aarch64-hash-build-contract-audit",
        "Audit and mutation-test the native AArch64 certification DAG",
    );
    aarch64_hash_build_contract_audit_step.dependOn(&aarch64_hash_build_contract_tests.step);
    aarch64_evidence_audit_step.dependOn(&aarch64_hash_build_contract_tests.step);

    const aarch64_hash_review_contract_tests = b.addSystemCommand(&.{
        "python3",
        "-B",
        "-m",
        "unittest",
        "tests/test_aarch64_hash_review.py",
        "-v",
    });
    const aarch64_hash_review_audit_step = b.step(
        "aarch64-hash-review-audit",
        "Test the non-closing AArch64 human-review receipt contract",
    );
    aarch64_hash_review_audit_step.dependOn(&aarch64_hash_review_contract_tests.step);

    const aarch64_hash_qemu_contract_audit = b.addSystemCommand(&.{
        "python3",
        "-B",
        "scripts/check_aarch64_hash_qemu_contract.py",
    });
    const aarch64_hash_qemu_contract_tests = b.addSystemCommand(&.{
        "python3",
        "-B",
        "-m",
        "unittest",
        "tests/test_aarch64_hash_qemu_contract.py",
        "tests/test_aarch64_hash_qemu_report.py",
        "-v",
    });
    aarch64_hash_qemu_contract_tests.step.dependOn(&aarch64_hash_qemu_contract_audit.step);
    const aarch64_hash_qemu_audit_step = b.step(
        "aarch64-hash-qemu-audit",
        "Audit and mutation-test the non-certifying AArch64 QEMU user-mode lane",
    );
    aarch64_hash_qemu_audit_step.dependOn(&aarch64_hash_qemu_contract_tests.step);

    const test_step = b.step("test", "Run the native ZLAY test suite");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_ordinary_manifest_tests.step);
    test_step.dependOn(&aarch64_evidence_contract_tests.step);
    test_step.dependOn(&aarch64_hash_build_contract_tests.step);
    test_step.dependOn(&aarch64_hash_review_contract_tests.step);
    test_step.dependOn(&aarch64_hash_qemu_contract_tests.step);

    const fmt_check = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src"), b.path("examples"), b.path("tests/oracle"), b.path("tests/consumer") },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check Zig source formatting");
    fmt_step.dependOn(&fmt_check.step);

    const production_c_free = b.addSystemCommand(&.{ "bash", "scripts/check_production_c_free.sh" });
    const production_c_free_tests = b.addSystemCommand(&.{
        "python3",
        "-B",
        "-m",
        "unittest",
        "tests/test_production_c_free.py",
        "-v",
    });
    production_c_free_tests.step.dependOn(&production_c_free.step);
    const production_c_free_step = b.step("production-c-free", "Reject C imports and C ABI/build hooks in production Zig sources");
    production_c_free_step.dependOn(&production_c_free_tests.step);
    test_step.dependOn(&production_c_free_tests.step);

    const public_api_manifest_audit = b.addSystemCommand(&.{ "python3", "-B", "scripts/check_public_api_manifest.py" });
    const public_api_manifest_tests = b.addSystemCommand(&.{ "python3", "-B", "-m", "unittest", "tests/test_public_api_manifest.py", "-v" });
    public_api_manifest_tests.step.dependOn(&public_api_manifest_audit.step);
    const public_api_audit_step = b.step("public-api-audit", "Prove the pinned Clay public declaration inventory is completely mapped");
    public_api_audit_step.dependOn(&public_api_manifest_tests.step);
    test_step.dependOn(&public_api_manifest_tests.step);

    const aarch64_evidence_validate_step = b.step(
        "aarch64-hash-evidence-validate",
        "Validate raw AArch64 hash evidence against the current source tree",
    );
    if (aarch64_evidence) |evidence_path| {
        const validate_evidence = b.addSystemCommand(&.{
            "python3",
            "-B",
            "scripts/aarch64_hash_evidence.py",
            "validate",
            "--repo-root",
        });
        validate_evidence.addFileArg(b.path("."));
        validate_evidence.addArg("--evidence");
        validate_evidence.addFileArg(.{ .cwd_relative = evidence_path });
        aarch64_evidence_validate_step.dependOn(&validate_evidence.step);
    } else {
        const missing_evidence = b.addFail(
            "aarch64-hash-evidence-validate requires -Daarch64-evidence=/absolute/evidence.json",
        );
        aarch64_evidence_validate_step.dependOn(&missing_evidence.step);
    }

    const aarch64_evidence_import_step = b.step(
        "aarch64-hash-evidence-import",
        "Validate and import raw AArch64 hash evidence without overwriting",
    );
    if (aarch64_evidence != null and aarch64_import_out != null) {
        const import_evidence = b.addSystemCommand(&.{
            "python3",
            "-B",
            "scripts/aarch64_hash_evidence.py",
            "import",
            "--repo-root",
        });
        import_evidence.addFileArg(b.path("."));
        import_evidence.addArg("--evidence");
        import_evidence.addFileArg(.{ .cwd_relative = aarch64_evidence.? });
        import_evidence.addArgs(&.{ "--output", aarch64_import_out.? });
        import_evidence.has_side_effects = true;
        aarch64_evidence_import_step.dependOn(&import_evidence.step);
    } else {
        const missing_import_paths = b.addFail(
            "aarch64-hash-evidence-import requires both -Daarch64-evidence and -Daarch64-import-out",
        );
        aarch64_evidence_import_step.dependOn(&missing_import_paths.step);
    }

    const aarch64_runner_record_validate_step = b.step(
        "aarch64-hash-runner-record-validate",
        "Validate the raw evidence binding to an immutable runner record",
    );
    if (aarch64_evidence != null and aarch64_runner_record != null) {
        const validate_runner_record = b.addSystemCommand(&.{
            "python3",
            "-B",
            "scripts/aarch64_hash_review.py",
            "runner-record-validate",
            "--repo-root",
        });
        validate_runner_record.addFileArg(b.path("."));
        validate_runner_record.addArg("--evidence");
        validate_runner_record.addFileArg(.{ .cwd_relative = aarch64_evidence.? });
        validate_runner_record.addArg("--runner-record");
        validate_runner_record.addFileArg(.{ .cwd_relative = aarch64_runner_record.? });
        validate_runner_record.step.dependOn(&aarch64_hash_review_contract_tests.step);
        aarch64_runner_record_validate_step.dependOn(&validate_runner_record.step);
    } else {
        const missing_runner_record_inputs = b.addFail(
            "aarch64-hash-runner-record-validate requires both -Daarch64-evidence and -Daarch64-runner-record",
        );
        aarch64_runner_record_validate_step.dependOn(&missing_runner_record_inputs.step);
    }

    const aarch64_runner_preflight_step = b.step(
        "aarch64-hash-runner-preflight",
        "Validate runner provenance against the actual immutable runner-record bytes",
    );
    if (aarch64_provenance != null and aarch64_runner_record != null) {
        const validate_runner_preflight = b.addSystemCommand(&.{
            "python3",
            "-B",
            "scripts/aarch64_hash_evidence.py",
            "runner-validate",
            "--provenance",
        });
        validate_runner_preflight.addFileArg(.{ .cwd_relative = aarch64_provenance.? });
        validate_runner_preflight.addArg("--runner-record");
        validate_runner_preflight.addFileArg(.{ .cwd_relative = aarch64_runner_record.? });
        validate_runner_preflight.has_side_effects = true;
        validate_runner_preflight.step.dependOn(&aarch64_evidence_contract_tests.step);
        aarch64_runner_preflight_step.dependOn(&validate_runner_preflight.step);
    } else {
        const missing_runner_preflight_inputs = b.addFail(
            "aarch64-hash-runner-preflight requires both -Daarch64-provenance and -Daarch64-runner-record",
        );
        aarch64_runner_preflight_step.dependOn(&missing_runner_preflight_inputs.step);
    }

    const aarch64_review_receipt_step = b.step(
        "aarch64-hash-review-receipt",
        "Create a non-closing human-review receipt bound to raw evidence and run artifacts",
    );
    if (aarch64_evidence != null and
        aarch64_runner_record != null and
        aarch64_certification_log != null and
        aarch64_review_statement != null and
        aarch64_review_out != null)
    {
        const create_review_receipt = b.addSystemCommand(&.{
            "python3",
            "-B",
            "scripts/aarch64_hash_review.py",
            "review-create",
            "--repo-root",
        });
        create_review_receipt.addFileArg(b.path("."));
        create_review_receipt.addArg("--evidence");
        create_review_receipt.addFileArg(.{ .cwd_relative = aarch64_evidence.? });
        create_review_receipt.addArg("--runner-record");
        create_review_receipt.addFileArg(.{ .cwd_relative = aarch64_runner_record.? });
        create_review_receipt.addArg("--certification-log");
        create_review_receipt.addFileArg(.{ .cwd_relative = aarch64_certification_log.? });
        create_review_receipt.addArg("--statement");
        create_review_receipt.addFileArg(.{ .cwd_relative = aarch64_review_statement.? });
        create_review_receipt.addArgs(&.{ "--output", aarch64_review_out.? });
        create_review_receipt.has_side_effects = true;
        create_review_receipt.step.dependOn(&aarch64_hash_review_contract_tests.step);
        aarch64_review_receipt_step.dependOn(&create_review_receipt.step);
    } else {
        const missing_review_create_inputs = b.addFail(
            "aarch64-hash-review-receipt requires -Daarch64-evidence, -Daarch64-runner-record, -Daarch64-certification-log, -Daarch64-review-statement, and -Daarch64-review-out",
        );
        aarch64_review_receipt_step.dependOn(&missing_review_create_inputs.step);
    }

    const aarch64_review_validate_step = b.step(
        "aarch64-hash-review-validate",
        "Validate a review receipt and all of its local byte bindings",
    );
    if (aarch64_evidence != null and
        aarch64_runner_record != null and
        aarch64_certification_log != null and
        aarch64_review_receipt != null)
    {
        const validate_review_receipt = b.addSystemCommand(&.{
            "python3",
            "-B",
            "scripts/aarch64_hash_review.py",
            "review-validate",
            "--repo-root",
        });
        validate_review_receipt.addFileArg(b.path("."));
        validate_review_receipt.addArg("--evidence");
        validate_review_receipt.addFileArg(.{ .cwd_relative = aarch64_evidence.? });
        validate_review_receipt.addArg("--runner-record");
        validate_review_receipt.addFileArg(.{ .cwd_relative = aarch64_runner_record.? });
        validate_review_receipt.addArg("--certification-log");
        validate_review_receipt.addFileArg(.{ .cwd_relative = aarch64_certification_log.? });
        validate_review_receipt.addArg("--receipt");
        validate_review_receipt.addFileArg(.{ .cwd_relative = aarch64_review_receipt.? });
        validate_review_receipt.step.dependOn(&aarch64_hash_review_contract_tests.step);
        aarch64_review_validate_step.dependOn(&validate_review_receipt.step);
    } else {
        const missing_review_validate_inputs = b.addFail(
            "aarch64-hash-review-validate requires -Daarch64-evidence, -Daarch64-runner-record, -Daarch64-certification-log, and -Daarch64-review-receipt",
        );
        aarch64_review_validate_step.dependOn(&missing_review_validate_inputs.step);
    }

    const coverage_audit = b.addSystemCommand(&.{ "bash", "scripts/audit_clay_coverage.sh" });
    const coverage_audit_step = b.step("coverage-audit", "Measure scalar/common and x86_64 SIMD pinned-Clay coverage profiles");
    coverage_audit_step.dependOn(&coverage_audit.step);

    const clay_coverage_contract_tests = b.addSystemCommand(&.{
        "python3",
        "-B",
        "-m",
        "unittest",
        "tests/test_clay_coverage.py",
        "-v",
    });
    test_step.dependOn(&clay_coverage_contract_tests.step);
    const clay_coverage_certify = b.addSystemCommand(&.{
        "bash",
        "scripts/audit_clay_coverage.sh",
        "--certify",
    });
    clay_coverage_certify.step.dependOn(&clay_coverage_contract_tests.step);
    const clay_coverage_certify_step = b.step(
        "clay-coverage-certify",
        "Certify scalar raw-accountable and mapped source coverage plus the active x86_64 SIMD bodies",
    );
    clay_coverage_certify_step.dependOn(&clay_coverage_certify.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const wasm_object = b.addObject(.{
        .name = "zlay-wasm-check",
        .root_module = wasm_module,
    });
    const wasm_step = b.step("wasm-check", "Compile the native library for wasm32-freestanding");
    wasm_step.dependOn(&wasm_object.step);

    const wasm_renderer_module = b.createModule(.{
        .root_source_file = b.path("examples/renderer_smoke_wasm.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zlay", .module = wasm_module }},
    });
    wasm_renderer_module.export_symbol_names = &.{"zlay_renderer_smoke"};
    const wasm_renderer_smoke = b.addExecutable(.{
        .name = "zlay-renderer-smoke",
        .root_module = wasm_renderer_module,
    });
    wasm_renderer_smoke.entry = .disabled;
    const wasm_runtime_step = b.step("wasm-runtime-smoke", "Execute the deterministic renderer smoke in WebAssembly");
    const node = b.findProgram(.{ .names = &.{ "node", "nodejs" } });
    if (node) |node_executable| {
        const run_wasm_renderer_smoke = b.addSystemCommand(&.{ node_executable, "tests/run_wasm_smoke.mjs" });
        run_wasm_renderer_smoke.addFileArg(wasm_renderer_smoke.getEmittedBin());
        wasm_runtime_step.dependOn(&run_wasm_renderer_smoke.step);
    } else {
        const missing_wasm_runtime = b.addFail("wasm-runtime-smoke requires Node.js; compile-only wasm-check remains available");
        wasm_runtime_step.dependOn(&missing_wasm_runtime.step);
    }

    const check_step = b.step("check", "Compile, format-check, and test ZLAY");
    check_step.dependOn(&fmt_check.step);
    check_step.dependOn(&production_c_free_tests.step);
    check_step.dependOn(&public_api_manifest_tests.step);
    check_step.dependOn(&aarch64_evidence_contract_tests.step);
    check_step.dependOn(&aarch64_hash_build_contract_tests.step);
    check_step.dependOn(&aarch64_hash_review_contract_tests.step);
    check_step.dependOn(&aarch64_hash_qemu_contract_tests.step);
    check_step.dependOn(&clay_coverage_contract_tests.step);
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&run_ordinary_manifest_tests.step);
    check_step.dependOn(&example.step);
    check_step.dependOn(&run_paragraph_provider_example.step);
    check_step.dependOn(&run_renderer_smoke.step);
    check_step.dependOn(&run_fixed_buffer_profile.step);
    check_step.dependOn(&run_consumer_smoke.step);
    check_step.dependOn(&wasm_object.step);
    if (node != null) check_step.dependOn(wasm_runtime_step);

    const c_oracle_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    c_oracle_module.addIncludePath(b.path("tests/oracle"));
    c_oracle_module.addCSourceFile(.{
        .file = b.path("tests/oracle/layout_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const c_oracle = b.addExecutable(.{
        .name = "zlay-clay-oracle",
        .root_module = c_oracle_module,
    });
    const run_c_oracle = b.addRunArtifact(c_oracle);
    const c_output = run_c_oracle.captureStdOut(.{ .basename = "clay-oracle.txt" });

    const zig_oracle = b.addExecutable(.{
        .name = "zlay-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/zig_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_zig_oracle = b.addRunArtifact(zig_oracle);
    const zig_output = run_zig_oracle.captureStdOut(.{ .basename = "zlay-oracle.txt" });

    const compare_oracles = b.addExecutable(.{
        .name = "zlay-compare-oracles",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/compare.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_compare = b.addRunArtifact(compare_oracles);
    run_compare.addFileArg(c_output);
    run_compare.addFileArg(zig_output);

    const header_checker = b.addExecutable(.{
        .name = "zlay-check-pinned-header",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_header.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const run_header_checker = b.addRunArtifact(header_checker);
    run_header_checker.addFileArg(b.path("tests/oracle/clay.h"));

    const complex_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    complex_c_module.addIncludePath(b.path("tests/oracle"));
    complex_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/complex_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const complex_c_oracle = b.addExecutable(.{
        .name = "zlay-complex-clay-oracle",
        .root_module = complex_c_module,
    });
    const run_complex_c = b.addRunArtifact(complex_c_oracle);
    const complex_c_output = run_complex_c.captureStdOut(.{ .basename = "complex-clay-oracle.txt" });

    const complex_zig_oracle = b.addExecutable(.{
        .name = "zlay-complex-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/complex_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_complex_zig = b.addRunArtifact(complex_zig_oracle);
    const complex_zig_output = run_complex_zig.captureStdOut(.{ .basename = "complex-zig-oracle.txt" });

    const run_complex_compare = b.addRunArtifact(compare_oracles);
    run_complex_compare.addFileArg(complex_c_output);
    run_complex_compare.addFileArg(complex_zig_output);

    const transition_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    transition_c_module.addIncludePath(b.path("tests/oracle"));
    transition_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/transition_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const transition_c_oracle = b.addExecutable(.{
        .name = "zlay-transition-clay-oracle",
        .root_module = transition_c_module,
    });
    const run_transition_c = b.addRunArtifact(transition_c_oracle);
    const transition_c_output = run_transition_c.captureStdOut(.{ .basename = "transition-clay-oracle.txt" });

    const transition_zig_oracle = b.addExecutable(.{
        .name = "zlay-transition-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/transition_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_transition_zig = b.addRunArtifact(transition_zig_oracle);
    const transition_zig_output = run_transition_zig.captureStdOut(.{ .basename = "transition-zig-oracle.txt" });

    const run_transition_compare = b.addRunArtifact(compare_oracles);
    run_transition_compare.addFileArg(transition_c_output);
    run_transition_compare.addFileArg(transition_zig_output);

    const transition_matrix_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    transition_matrix_c_module.addIncludePath(b.path("tests/oracle"));
    transition_matrix_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/transition_matrix_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const transition_matrix_c_oracle = b.addExecutable(.{
        .name = "zlay-transition-matrix-clay-oracle",
        .root_module = transition_matrix_c_module,
    });
    const run_transition_matrix_c = b.addRunArtifact(transition_matrix_c_oracle);
    const transition_matrix_c_output = run_transition_matrix_c.captureStdOut(.{ .basename = "transition-matrix-clay-oracle.txt" });

    const transition_matrix_zig_oracle = b.addExecutable(.{
        .name = "zlay-transition-matrix-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/transition_matrix_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_transition_matrix_zig = b.addRunArtifact(transition_matrix_zig_oracle);
    const transition_matrix_zig_output = run_transition_matrix_zig.captureStdOut(.{ .basename = "transition-matrix-zig-oracle.txt" });

    const run_transition_matrix_compare = b.addRunArtifact(compare_oracles);
    run_transition_matrix_compare.addFileArg(transition_matrix_c_output);
    run_transition_matrix_compare.addFileArg(transition_matrix_zig_output);

    const pointer_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    pointer_c_module.addIncludePath(b.path("tests/oracle"));
    pointer_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/pointer_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const pointer_c_oracle = b.addExecutable(.{
        .name = "zlay-pointer-clay-oracle",
        .root_module = pointer_c_module,
    });
    const run_pointer_c = b.addRunArtifact(pointer_c_oracle);
    const pointer_c_output = run_pointer_c.captureStdOut(.{ .basename = "pointer-clay-oracle.txt" });

    const pointer_zig_oracle = b.addExecutable(.{
        .name = "zlay-pointer-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/pointer_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_pointer_zig = b.addRunArtifact(pointer_zig_oracle);
    const pointer_zig_output = run_pointer_zig.captureStdOut(.{ .basename = "pointer-zig-oracle.txt" });

    const run_pointer_compare = b.addRunArtifact(compare_oracles);
    run_pointer_compare.addFileArg(pointer_c_output);
    run_pointer_compare.addFileArg(pointer_zig_output);

    const floating_pointer_edge_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    floating_pointer_edge_c_module.addIncludePath(b.path("tests/oracle"));
    floating_pointer_edge_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/floating_pointer_edge_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const floating_pointer_edge_c_oracle = b.addExecutable(.{
        .name = "zlay-floating-pointer-edge-clay-oracle",
        .root_module = floating_pointer_edge_c_module,
    });
    const run_floating_pointer_edge_c = b.addRunArtifact(floating_pointer_edge_c_oracle);
    const floating_pointer_edge_c_output = run_floating_pointer_edge_c.captureStdOut(.{ .basename = "floating-pointer-edge-clay-oracle.txt" });

    const floating_pointer_edge_zig_oracle = b.addExecutable(.{
        .name = "zlay-floating-pointer-edge-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/floating_pointer_edge_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_floating_pointer_edge_zig = b.addRunArtifact(floating_pointer_edge_zig_oracle);
    const floating_pointer_edge_zig_output = run_floating_pointer_edge_zig.captureStdOut(.{ .basename = "floating-pointer-edge-zig-oracle.txt" });

    const run_floating_pointer_edge_compare = b.addRunArtifact(compare_oracles);
    run_floating_pointer_edge_compare.addFileArg(floating_pointer_edge_c_output);
    run_floating_pointer_edge_compare.addFileArg(floating_pointer_edge_zig_output);

    const scroll_parity_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    scroll_parity_c_module.addIncludePath(b.path("tests/oracle"));
    scroll_parity_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/scroll_parity_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const scroll_parity_c_oracle = b.addExecutable(.{
        .name = "zlay-scroll-parity-clay-oracle",
        .root_module = scroll_parity_c_module,
    });
    const run_scroll_parity_c = b.addRunArtifact(scroll_parity_c_oracle);
    const scroll_parity_c_output = run_scroll_parity_c.captureStdOut(.{ .basename = "scroll-parity-clay-oracle.txt" });

    const scroll_parity_zig_oracle = b.addExecutable(.{
        .name = "zlay-scroll-parity-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/scroll_parity_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_scroll_parity_zig = b.addRunArtifact(scroll_parity_zig_oracle);
    const scroll_parity_zig_output = run_scroll_parity_zig.captureStdOut(.{ .basename = "scroll-parity-zig-oracle.txt" });

    const run_scroll_parity_compare = b.addRunArtifact(compare_oracles);
    run_scroll_parity_compare.addFileArg(scroll_parity_c_output);
    run_scroll_parity_compare.addFileArg(scroll_parity_zig_output);

    const external_scroll_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    external_scroll_c_module.addIncludePath(b.path("tests/oracle"));
    external_scroll_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/external_scroll_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const external_scroll_c_oracle = b.addExecutable(.{
        .name = "zlay-external-scroll-clay-oracle",
        .root_module = external_scroll_c_module,
    });
    const run_external_scroll_c = b.addRunArtifact(external_scroll_c_oracle);
    const external_scroll_c_output = run_external_scroll_c.captureStdOut(.{ .basename = "external-scroll-clay-oracle.txt" });

    const external_scroll_zig_oracle = b.addExecutable(.{
        .name = "zlay-external-scroll-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/external_scroll_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_external_scroll_zig = b.addRunArtifact(external_scroll_zig_oracle);
    const external_scroll_zig_output = run_external_scroll_zig.captureStdOut(.{ .basename = "external-scroll-zig-oracle.txt" });

    const run_external_scroll_compare = b.addRunArtifact(compare_oracles);
    run_external_scroll_compare.addFileArg(external_scroll_c_output);
    run_external_scroll_compare.addFileArg(external_scroll_zig_output);

    const render_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    render_c_module.addIncludePath(b.path("tests/oracle"));
    render_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/render_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const render_c_oracle = b.addExecutable(.{
        .name = "zlay-render-clay-oracle",
        .root_module = render_c_module,
    });
    const run_render_c = b.addRunArtifact(render_c_oracle);
    const render_c_output = run_render_c.captureStdOut(.{ .basename = "render-clay-oracle.txt" });

    const render_zig_oracle = b.addExecutable(.{
        .name = "zlay-render-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/render_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_render_zig = b.addRunArtifact(render_zig_oracle);
    const render_zig_output = run_render_zig.captureStdOut(.{ .basename = "render-zig-oracle.txt" });

    const run_render_compare = b.addRunArtifact(compare_oracles);
    run_render_compare.addFileArg(render_c_output);
    run_render_compare.addFileArg(render_zig_output);

    const sizing_text_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    sizing_text_c_module.addIncludePath(b.path("tests/oracle"));
    sizing_text_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/sizing_text_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const sizing_text_c_oracle = b.addExecutable(.{
        .name = "zlay-sizing-text-clay-oracle",
        .root_module = sizing_text_c_module,
    });
    const run_sizing_text_c = b.addRunArtifact(sizing_text_c_oracle);
    const sizing_text_c_output = run_sizing_text_c.captureStdOut(.{ .basename = "sizing-text-clay-oracle.txt" });

    const sizing_text_zig_oracle = b.addExecutable(.{
        .name = "zlay-sizing-text-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/sizing_text_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_sizing_text_zig = b.addRunArtifact(sizing_text_zig_oracle);
    const sizing_text_zig_output = run_sizing_text_zig.captureStdOut(.{ .basename = "sizing-text-zig-oracle.txt" });

    const run_sizing_text_compare = b.addRunArtifact(compare_oracles);
    run_sizing_text_compare.addFileArg(sizing_text_c_output);
    run_sizing_text_compare.addFileArg(sizing_text_zig_output);

    const string_text_edge_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    string_text_edge_c_module.addIncludePath(b.path("tests/oracle"));
    string_text_edge_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/string_text_edge_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const string_text_edge_c_oracle = b.addExecutable(.{
        .name = "zlay-string-text-edge-clay-oracle",
        .root_module = string_text_edge_c_module,
    });
    const run_string_text_edge_c = b.addRunArtifact(string_text_edge_c_oracle);
    const string_text_edge_c_output = run_string_text_edge_c.captureStdOut(.{ .basename = "string-text-edge-clay-oracle.txt" });

    const string_text_edge_zig_oracle = b.addExecutable(.{
        .name = "zlay-string-text-edge-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/string_text_edge_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_string_text_edge_zig = b.addRunArtifact(string_text_edge_zig_oracle);
    const string_text_edge_zig_output = run_string_text_edge_zig.captureStdOut(.{ .basename = "string-text-edge-zig-oracle.txt" });

    const run_string_text_edge_compare = b.addRunArtifact(compare_oracles);
    run_string_text_edge_compare.addFileArg(string_text_edge_c_output);
    run_string_text_edge_compare.addFileArg(string_text_edge_zig_output);

    const declaration_layout_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    declaration_layout_c_module.addIncludePath(b.path("tests/oracle"));
    declaration_layout_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/declaration_layout_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const declaration_layout_c_oracle = b.addExecutable(.{
        .name = "zlay-declaration-layout-clay-oracle",
        .root_module = declaration_layout_c_module,
    });
    const run_declaration_layout_c = b.addRunArtifact(declaration_layout_c_oracle);
    const declaration_layout_c_output = run_declaration_layout_c.captureStdOut(.{ .basename = "declaration-layout-clay-oracle.txt" });

    const declaration_layout_zig_oracle = b.addExecutable(.{
        .name = "zlay-declaration-layout-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/declaration_layout_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_declaration_layout_zig = b.addRunArtifact(declaration_layout_zig_oracle);
    const declaration_layout_zig_output = run_declaration_layout_zig.captureStdOut(.{ .basename = "declaration-layout-zig-oracle.txt" });

    const run_declaration_layout_compare = b.addRunArtifact(compare_oracles);
    run_declaration_layout_compare.addFileArg(declaration_layout_c_output);
    run_declaration_layout_compare.addFileArg(declaration_layout_zig_output);

    const api_diagnostics_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    api_diagnostics_c_module.addIncludePath(b.path("tests/oracle"));
    api_diagnostics_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/api_diagnostics_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const api_diagnostics_c_oracle = b.addExecutable(.{
        .name = "zlay-api-diagnostics-clay-oracle",
        .root_module = api_diagnostics_c_module,
    });
    const run_api_diagnostics_c = b.addRunArtifact(api_diagnostics_c_oracle);
    const api_diagnostics_c_output = run_api_diagnostics_c.captureStdOut(.{ .basename = "api-diagnostics-clay-oracle.txt" });

    const api_diagnostics_zig_oracle = b.addExecutable(.{
        .name = "zlay-api-diagnostics-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/api_diagnostics_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_api_diagnostics_zig = b.addRunArtifact(api_diagnostics_zig_oracle);
    const api_diagnostics_zig_output = run_api_diagnostics_zig.captureStdOut(.{ .basename = "api-diagnostics-zig-oracle.txt" });

    const run_api_diagnostics_compare = b.addRunArtifact(compare_oracles);
    run_api_diagnostics_compare.addFileArg(api_diagnostics_c_output);
    run_api_diagnostics_compare.addFileArg(api_diagnostics_zig_output);

    const debug_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    debug_c_module.addIncludePath(b.path("tests/oracle"));
    debug_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/debug_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const debug_c_oracle = b.addExecutable(.{
        .name = "zlay-debug-clay-oracle",
        .root_module = debug_c_module,
    });
    const run_debug_c = b.addRunArtifact(debug_c_oracle);
    const debug_c_output = run_debug_c.captureStdOut(.{ .basename = "debug-clay-oracle.txt" });

    const debug_zig_oracle = b.addExecutable(.{
        .name = "zlay-debug-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/debug_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_debug_zig = b.addRunArtifact(debug_zig_oracle);
    const debug_zig_output = run_debug_zig.captureStdOut(.{ .basename = "debug-zig-oracle.txt" });

    const run_debug_compare = b.addRunArtifact(compare_oracles);
    run_debug_compare.addFileArg(debug_c_output);
    run_debug_compare.addFileArg(debug_zig_output);

    const id_error_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    id_error_c_module.addIncludePath(b.path("tests/oracle"));
    id_error_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/id_error_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const id_error_c_oracle = b.addExecutable(.{
        .name = "zlay-id-error-clay-oracle",
        .root_module = id_error_c_module,
    });
    const run_id_error_c = b.addRunArtifact(id_error_c_oracle);
    const id_error_c_output = run_id_error_c.captureStdOut(.{ .basename = "id-error-clay-oracle.txt" });

    const id_error_zig_oracle = b.addExecutable(.{
        .name = "zlay-id-error-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/id_error_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_id_error_zig = b.addRunArtifact(id_error_zig_oracle);
    const id_error_zig_output = run_id_error_zig.captureStdOut(.{ .basename = "id-error-zig-oracle.txt" });

    const run_id_error_compare = b.addRunArtifact(compare_oracles);
    run_id_error_compare.addFileArg(id_error_c_output);
    run_id_error_compare.addFileArg(id_error_zig_output);

    const id_collision_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    id_collision_c_module.addIncludePath(b.path("tests/oracle"));
    id_collision_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/id_collision_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const id_collision_c_oracle = b.addExecutable(.{
        .name = "zlay-id-collision-clay-oracle",
        .root_module = id_collision_c_module,
    });
    const run_id_collision_c = b.addRunArtifact(id_collision_c_oracle);
    const id_collision_c_output = run_id_collision_c.captureStdOut(.{ .basename = "id-collision-clay-oracle.txt" });

    const id_collision_zig_oracle = b.addExecutable(.{
        .name = "zlay-id-collision-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/id_collision_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_id_collision_zig = b.addRunArtifact(id_collision_zig_oracle);
    const id_collision_zig_output = run_id_collision_zig.captureStdOut(.{ .basename = "id-collision-zig-oracle.txt" });

    const run_id_collision_compare = b.addRunArtifact(compare_oracles);
    run_id_collision_compare.addFileArg(id_collision_c_output);
    run_id_collision_compare.addFileArg(id_collision_zig_output);

    const duplicate_lookup_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    duplicate_lookup_c_module.addIncludePath(b.path("tests/oracle"));
    duplicate_lookup_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/duplicate_lookup_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const duplicate_lookup_c_oracle = b.addExecutable(.{
        .name = "zlay-duplicate-lookup-clay-oracle",
        .root_module = duplicate_lookup_c_module,
    });
    const run_duplicate_lookup_c = b.addRunArtifact(duplicate_lookup_c_oracle);
    const duplicate_lookup_c_output = run_duplicate_lookup_c.captureStdOut(.{ .basename = "duplicate-lookup-clay-oracle.txt" });

    const duplicate_lookup_zig_oracle = b.addExecutable(.{
        .name = "zlay-duplicate-lookup-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/duplicate_lookup_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_duplicate_lookup_zig = b.addRunArtifact(duplicate_lookup_zig_oracle);
    const duplicate_lookup_zig_output = run_duplicate_lookup_zig.captureStdOut(.{ .basename = "duplicate-lookup-zig-oracle.txt" });

    const duplicate_lookup_divergence_checker = b.addExecutable(.{
        .name = "zlay-check-duplicate-lookup-divergence",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_duplicate_lookup_divergence.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_duplicate_lookup_divergence_checker = b.addRunArtifact(duplicate_lookup_divergence_checker);
    run_duplicate_lookup_divergence_checker.addFileArg(duplicate_lookup_c_output);
    run_duplicate_lookup_divergence_checker.addFileArg(duplicate_lookup_zig_output);

    const capacity_match_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    capacity_match_c_module.addIncludePath(b.path("tests/oracle"));
    capacity_match_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/capacity_match_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const capacity_match_c_oracle = b.addExecutable(.{
        .name = "zlay-capacity-match-clay-oracle",
        .root_module = capacity_match_c_module,
    });
    const run_capacity_match_c = b.addRunArtifact(capacity_match_c_oracle);
    const capacity_match_c_output = run_capacity_match_c.captureStdOut(.{ .basename = "capacity-match-clay-oracle.txt" });

    const capacity_match_zig_oracle = b.addExecutable(.{
        .name = "zlay-capacity-match-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/capacity_match_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_capacity_match_zig = b.addRunArtifact(capacity_match_zig_oracle);
    const capacity_match_zig_output = run_capacity_match_zig.captureStdOut(.{ .basename = "capacity-match-zig-oracle.txt" });

    const capacity_match_checker = b.addExecutable(.{
        .name = "zlay-check-capacity-match",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_capacity_match.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_capacity_match_checker = b.addRunArtifact(capacity_match_checker);
    run_capacity_match_checker.addFileArg(capacity_match_c_output);
    run_capacity_match_checker.addFileArg(capacity_match_zig_output);

    const invalid_access_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    invalid_access_c_module.addIncludePath(b.path("tests/oracle"));
    invalid_access_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/invalid_render_access_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const invalid_access_c_oracle = b.addExecutable(.{
        .name = "zlay-invalid-render-access-clay-oracle",
        .root_module = invalid_access_c_module,
    });
    const run_invalid_access_c = b.addRunArtifact(invalid_access_c_oracle);
    const invalid_access_c_output = run_invalid_access_c.captureStdOut(.{ .basename = "invalid-render-access-clay-oracle.txt" });

    const invalid_access_zig_oracle = b.addExecutable(.{
        .name = "zlay-invalid-render-access-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/invalid_render_access_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_invalid_access_zig = b.addRunArtifact(invalid_access_zig_oracle);
    const invalid_access_zig_output = run_invalid_access_zig.captureStdOut(.{ .basename = "invalid-render-access-zig-oracle.txt" });

    const element_capacity_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    element_capacity_c_module.addIncludePath(b.path("tests/oracle"));
    element_capacity_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/element_capacity_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const element_capacity_c_oracle = b.addExecutable(.{
        .name = "zlay-element-capacity-clay-oracle",
        .root_module = element_capacity_c_module,
    });
    const run_element_capacity_c = b.addRunArtifact(element_capacity_c_oracle);
    const element_capacity_c_output = run_element_capacity_c.captureStdOut(.{ .basename = "element-capacity-clay-oracle.txt" });

    const element_capacity_zig_oracle = b.addExecutable(.{
        .name = "zlay-element-capacity-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/element_capacity_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_element_capacity_zig = b.addRunArtifact(element_capacity_zig_oracle);
    const element_capacity_zig_output = run_element_capacity_zig.captureStdOut(.{ .basename = "element-capacity-zig-oracle.txt" });

    const text_capacity_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    text_capacity_c_module.addIncludePath(b.path("tests/oracle"));
    text_capacity_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/text_capacity_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const text_capacity_c_oracle = b.addExecutable(.{
        .name = "zlay-text-capacity-clay-oracle",
        .root_module = text_capacity_c_module,
    });
    const run_text_capacity_c = b.addRunArtifact(text_capacity_c_oracle);
    const text_capacity_c_output = run_text_capacity_c.captureStdOut(.{ .basename = "text-capacity-clay-oracle.txt" });

    const text_capacity_zig_oracle = b.addExecutable(.{
        .name = "zlay-text-capacity-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/text_capacity_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_text_capacity_zig = b.addRunArtifact(text_capacity_zig_oracle);
    const text_capacity_zig_output = run_text_capacity_zig.captureStdOut(.{ .basename = "text-capacity-zig-oracle.txt" });

    const render_scope_capacity_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    render_scope_capacity_c_module.addIncludePath(b.path("tests/oracle"));
    render_scope_capacity_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/render_scope_capacity_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const render_scope_capacity_c_oracle = b.addExecutable(.{
        .name = "zlay-render-scope-capacity-clay-oracle",
        .root_module = render_scope_capacity_c_module,
    });
    const run_render_scope_capacity_c = b.addRunArtifact(render_scope_capacity_c_oracle);
    const render_scope_capacity_c_output = run_render_scope_capacity_c.captureStdOut(.{
        .basename = "render-scope-capacity-clay-oracle.txt",
    });

    const render_scope_capacity_zig_oracle = b.addExecutable(.{
        .name = "zlay-render-scope-capacity-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/render_scope_capacity_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_render_scope_capacity_zig = b.addRunArtifact(render_scope_capacity_zig_oracle);
    const render_scope_capacity_zig_output = run_render_scope_capacity_zig.captureStdOut(.{
        .basename = "render-scope-capacity-zig-oracle.txt",
    });

    const capacity_divergence_checker = b.addExecutable(.{
        .name = "zlay-check-capacity-divergences",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_capacity_divergences.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_capacity_divergence_checker = b.addRunArtifact(capacity_divergence_checker);
    run_capacity_divergence_checker.addFileArg(invalid_access_c_output);
    run_capacity_divergence_checker.addFileArg(invalid_access_zig_output);
    run_capacity_divergence_checker.addFileArg(element_capacity_c_output);
    run_capacity_divergence_checker.addFileArg(element_capacity_zig_output);
    run_capacity_divergence_checker.addFileArg(text_capacity_c_output);
    run_capacity_divergence_checker.addFileArg(text_capacity_zig_output);
    run_capacity_divergence_checker.addFileArg(render_scope_capacity_c_output);
    run_capacity_divergence_checker.addFileArg(render_scope_capacity_zig_output);

    const public_metadata_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    public_metadata_c_module.addIncludePath(b.path("tests/oracle"));
    public_metadata_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/public_metadata_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const public_metadata_c_oracle = b.addExecutable(.{
        .name = "zlay-public-metadata-clay-oracle",
        .root_module = public_metadata_c_module,
    });
    const run_public_metadata_c = b.addRunArtifact(public_metadata_c_oracle);
    const public_metadata_c_output = run_public_metadata_c.captureStdOut(.{ .basename = "public-metadata-clay-oracle.txt" });

    const public_metadata_zig_oracle = b.addExecutable(.{
        .name = "zlay-public-metadata-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/public_metadata_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_public_metadata_zig = b.addRunArtifact(public_metadata_zig_oracle);
    const public_metadata_zig_output = run_public_metadata_zig.captureStdOut(.{ .basename = "public-metadata-zig-oracle.txt" });

    const run_public_metadata_compare = b.addRunArtifact(compare_oracles);
    run_public_metadata_compare.addFileArg(public_metadata_c_output);
    run_public_metadata_compare.addFileArg(public_metadata_zig_output);

    const ease_out_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    ease_out_c_module.addIncludePath(b.path("tests/oracle"));
    ease_out_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/ease_out_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const ease_out_c_oracle = b.addExecutable(.{
        .name = "zlay-ease-out-clay-oracle",
        .root_module = ease_out_c_module,
    });
    const run_ease_out_c = b.addRunArtifact(ease_out_c_oracle);
    const ease_out_c_output = run_ease_out_c.captureStdOut(.{ .basename = "ease-out-clay-oracle.txt" });

    const ease_out_zig_oracle = b.addExecutable(.{
        .name = "zlay-ease-out-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/ease_out_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_ease_out_zig = b.addRunArtifact(ease_out_zig_oracle);
    const ease_out_zig_output = run_ease_out_zig.captureStdOut(.{ .basename = "ease-out-zig-oracle.txt" });

    const run_ease_out_compare = b.addRunArtifact(compare_oracles);
    run_ease_out_compare.addFileArg(ease_out_c_output);
    run_ease_out_compare.addFileArg(ease_out_zig_output);

    const hash_default_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    hash_default_c_module.addIncludePath(b.path("tests/oracle"));
    hash_default_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/hash_default_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const hash_default_c_oracle = b.addExecutable(.{
        .name = "zlay-hash-default-clay-oracle",
        .root_module = hash_default_c_module,
    });
    const run_hash_default_c = b.addRunArtifact(hash_default_c_oracle);
    const hash_default_c_output = run_hash_default_c.captureStdOut(.{ .basename = "hash-default-clay-oracle.txt" });

    const hash_default_zig_oracle = b.addExecutable(.{
        .name = "zlay-hash-default-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/hash_default_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_hash_default_zig = b.addRunArtifact(hash_default_zig_oracle);
    const hash_default_zig_output = run_hash_default_zig.captureStdOut(.{ .basename = "hash-default-zig-oracle.txt" });

    const run_hash_default_compare = b.addRunArtifact(compare_oracles);
    run_hash_default_compare.addFileArg(hash_default_c_output);
    run_hash_default_compare.addFileArg(hash_default_zig_output);

    const run_hash_default_certify_compare = b.addRunArtifact(compare_oracles);
    run_hash_default_certify_compare.addFileArg(hash_default_c_output);
    run_hash_default_certify_compare.addFileArg(hash_default_zig_output);
    run_hash_default_certify_compare.addArg("--report");

    const hash_default_parity_step = b.step(
        "hash-default-parity",
        "Verify the target-aware pinned-C/native-Zig default-hash trace",
    );
    hash_default_parity_step.dependOn(&run_header_checker.step);
    hash_default_parity_step.dependOn(&run_ordinary_manifest_tests.step);
    hash_default_parity_step.dependOn(&run_hash_default_certify_compare.step);

    // BEGIN AARCH64 HASH QEMU CONTRACT
    // This opt-in lane executes internally pinned static AArch64 artifacts
    // under QEMU user mode. It is intentionally separate from native AArch64
    // certification and never produces certification evidence.
    const aarch64_qemu_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .cpu_model = .baseline,
        .os_tag = .linux,
        .abi = .musl,
    });
    const aarch64_qemu_zlay = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = aarch64_qemu_target,
        .optimize = .debug,
    });
    const aarch64_qemu_module_tests = b.addTest(.{
        .name = "zlay-aarch64-qemu-module-tests",
        .root_module = aarch64_qemu_zlay,
    });
    aarch64_qemu_module_tests.linkage = .static;

    const aarch64_qemu_manifest_tests = b.addTest(.{
        .name = "zlay-aarch64-qemu-manifest-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/ordinary_manifest.zig"),
            .target = aarch64_qemu_target,
            .optimize = .debug,
        }),
    });
    aarch64_qemu_manifest_tests.linkage = .static;

    const aarch64_qemu_c_module = b.createModule(.{
        .target = aarch64_qemu_target,
        .optimize = .debug,
        .link_libc = true,
    });
    aarch64_qemu_c_module.addIncludePath(b.path("tests/oracle"));
    aarch64_qemu_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/hash_default_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const aarch64_qemu_c_oracle = b.addExecutable(.{
        .name = "zlay-aarch64-qemu-hash-clay",
        .root_module = aarch64_qemu_c_module,
        .linkage = .static,
    });

    const aarch64_qemu_zig_oracle = b.addExecutable(.{
        .name = "zlay-aarch64-qemu-hash-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/hash_default_fixture.zig"),
            .target = aarch64_qemu_target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = aarch64_qemu_zlay }},
        }),
        .linkage = .static,
    });

    const aarch64_qemu_comparator = b.addExecutable(.{
        .name = "zlay-aarch64-qemu-hash-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/compare.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
        .linkage = .static,
    });

    const aarch64_hash_qemu_step = b.step(
        "aarch64-hash-qemu",
        "Execute the AArch64 hash contract and native tests under QEMU user mode without certification",
    );
    const qemu_aarch64 = b.findProgram(.{ .names = &.{"qemu-aarch64"} });
    if (qemu_aarch64) |qemu_exe| {
        const write_aarch64_qemu_embedded_build = b.addWriteFiles();
        const aarch64_qemu_embedded_build_zig = write_aarch64_qemu_embedded_build.add(
            "aarch64-qemu-embedded-build.zig",
            embedded_build_zig_source,
        );
        const capture_aarch64_qemu_source_contract = b.addSystemCommand(&.{
            "python3",
            "-B",
            "scripts/aarch64_hash_qemu_report.py",
            "source-contract",
            "--repo-root",
        });
        capture_aarch64_qemu_source_contract.addFileArg(b.path("."));
        capture_aarch64_qemu_source_contract.addArg("--expected-build-zig-source");
        capture_aarch64_qemu_source_contract.addFileArg(aarch64_qemu_embedded_build_zig);
        capture_aarch64_qemu_source_contract.has_side_effects = true;
        const aarch64_qemu_source_contract = capture_aarch64_qemu_source_contract.captureStdOut(.{
            .basename = "aarch64-qemu-source-contract.sha256",
        });

        aarch64_qemu_module_tests.step.dependOn(&capture_aarch64_qemu_source_contract.step);
        aarch64_qemu_manifest_tests.step.dependOn(&capture_aarch64_qemu_source_contract.step);
        aarch64_qemu_c_oracle.step.dependOn(&capture_aarch64_qemu_source_contract.step);
        aarch64_qemu_zig_oracle.step.dependOn(&capture_aarch64_qemu_source_contract.step);
        aarch64_qemu_comparator.step.dependOn(&capture_aarch64_qemu_source_contract.step);

        const run_aarch64_qemu_module_tests = b.addSystemCommand(&.{ qemu_exe, "-cpu", "max" });
        run_aarch64_qemu_module_tests.has_side_effects = true;
        run_aarch64_qemu_module_tests.addFileArg(aarch64_qemu_module_tests.getEmittedBin());
        run_aarch64_qemu_module_tests.expectExitCode(0);
        const aarch64_qemu_module_tests_log = run_aarch64_qemu_module_tests.captureStdErr(.{
            .basename = "aarch64-qemu-module-tests.log",
        });

        const run_aarch64_qemu_manifest_tests = b.addSystemCommand(&.{ qemu_exe, "-cpu", "max" });
        run_aarch64_qemu_manifest_tests.has_side_effects = true;
        run_aarch64_qemu_manifest_tests.addFileArg(aarch64_qemu_manifest_tests.getEmittedBin());
        run_aarch64_qemu_manifest_tests.expectExitCode(0);
        const aarch64_qemu_manifest_tests_log = run_aarch64_qemu_manifest_tests.captureStdErr(.{
            .basename = "aarch64-qemu-manifest-tests.log",
        });

        const run_aarch64_qemu_c = b.addSystemCommand(&.{ qemu_exe, "-cpu", "max" });
        run_aarch64_qemu_c.has_side_effects = true;
        run_aarch64_qemu_c.addFileArg(aarch64_qemu_c_oracle.getEmittedBin());
        run_aarch64_qemu_c.expectExitCode(0);
        const aarch64_qemu_c_output = run_aarch64_qemu_c.captureStdOut(.{
            .basename = "hash-default-clay-oracle.txt",
        });

        const run_aarch64_qemu_zig = b.addSystemCommand(&.{ qemu_exe, "-cpu", "max" });
        run_aarch64_qemu_zig.has_side_effects = true;
        run_aarch64_qemu_zig.addFileArg(aarch64_qemu_zig_oracle.getEmittedBin());
        run_aarch64_qemu_zig.expectExitCode(0);
        const aarch64_qemu_zig_output = run_aarch64_qemu_zig.captureStdOut(.{
            .basename = "hash-default-zig-oracle.txt",
        });

        const run_aarch64_qemu_compare = b.addRunArtifact(aarch64_qemu_comparator);
        run_aarch64_qemu_compare.has_side_effects = true;
        run_aarch64_qemu_compare.addFileArg(aarch64_qemu_c_output);
        run_aarch64_qemu_compare.addFileArg(aarch64_qemu_zig_output);
        run_aarch64_qemu_compare.addArg("--qemu-aarch64-report");
        run_aarch64_qemu_compare.expectStdErrEqual(
            "oracle-emulation identity=hash-default target=aarch64-linux-musl cpu=baseline executor=qemu-aarch64 qemu_cpu=max lines=18 bytes=426 sha256=68b1ce5dfef146735d34889f337fa3f73a597b0511a5fc511f9e399d263dc787 certification=false physical_machine_proof=false backlog_closed=false\n",
        );
        run_aarch64_qemu_compare.expectExitCode(0);

        const run_aarch64_qemu_report = b.addSystemCommand(&.{
            "python3",
            "-B",
            "scripts/aarch64_hash_qemu_report.py",
            "report",
            "--repo-root",
        });
        run_aarch64_qemu_report.addFileArg(b.path("."));
        run_aarch64_qemu_report.addArg("--qemu");
        run_aarch64_qemu_report.addArg(qemu_exe);
        run_aarch64_qemu_report.addArg("--zig");
        run_aarch64_qemu_report.addArg(b.graph.zig_exe);
        run_aarch64_qemu_report.addArg("--c-trace");
        run_aarch64_qemu_report.addFileArg(aarch64_qemu_c_output);
        run_aarch64_qemu_report.addArg("--zig-trace");
        run_aarch64_qemu_report.addFileArg(aarch64_qemu_zig_output);
        run_aarch64_qemu_report.addArg("--module-tests-log");
        run_aarch64_qemu_report.addFileArg(aarch64_qemu_module_tests_log);
        run_aarch64_qemu_report.addArg("--manifest-tests-log");
        run_aarch64_qemu_report.addFileArg(aarch64_qemu_manifest_tests_log);
        run_aarch64_qemu_report.addArg("--c-executable");
        run_aarch64_qemu_report.addFileArg(aarch64_qemu_c_oracle.getEmittedBin());
        run_aarch64_qemu_report.addArg("--zig-executable");
        run_aarch64_qemu_report.addFileArg(aarch64_qemu_zig_oracle.getEmittedBin());
        run_aarch64_qemu_report.addArg("--module-tests-executable");
        run_aarch64_qemu_report.addFileArg(aarch64_qemu_module_tests.getEmittedBin());
        run_aarch64_qemu_report.addArg("--manifest-tests-executable");
        run_aarch64_qemu_report.addFileArg(aarch64_qemu_manifest_tests.getEmittedBin());
        run_aarch64_qemu_report.addArg("--expected-source-file");
        run_aarch64_qemu_report.addFileArg(aarch64_qemu_source_contract);
        run_aarch64_qemu_report.has_side_effects = true;
        run_aarch64_qemu_report.step.dependOn(&run_header_checker.step);
        run_aarch64_qemu_report.step.dependOn(&run_aarch64_qemu_module_tests.step);
        run_aarch64_qemu_report.step.dependOn(&run_aarch64_qemu_manifest_tests.step);
        run_aarch64_qemu_report.step.dependOn(&run_aarch64_qemu_compare.step);

        aarch64_hash_qemu_step.dependOn(&run_aarch64_qemu_report.step);
    } else {
        const missing_qemu_aarch64 = b.addFail(
            "aarch64-hash-qemu requires qemu-aarch64; this optional emulation lane is not certification",
        );
        aarch64_hash_qemu_step.dependOn(&missing_qemu_aarch64.step);
    }
    // END AARCH64 HASH QEMU CONTRACT

    const native_aarch64_host_checker = b.addExecutable(.{
        .name = "zlay-check-native-aarch64-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_native_aarch64_host.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });

    const aarch64_hash_compile_step = b.step(
        "aarch64-hash-compile",
        "Cross-compile the AArch64 hash certification fixtures and tests",
    );
    if (target.result.cpu.arch == .aarch64 and target.result.os.tag == .linux) {
        aarch64_hash_compile_step.dependOn(&module_tests.step);
        aarch64_hash_compile_step.dependOn(&ordinary_manifest_tests.step);
        aarch64_hash_compile_step.dependOn(&hash_default_c_oracle.step);
        aarch64_hash_compile_step.dependOn(&hash_default_zig_oracle.step);
        aarch64_hash_compile_step.dependOn(&compare_oracles.step);
        aarch64_hash_compile_step.dependOn(&native_aarch64_host_checker.step);
        aarch64_hash_compile_step.dependOn(&run_header_checker.step);
    } else {
        const wrong_cross_target = b.addFail(
            "aarch64-hash-compile requires -Dtarget=aarch64-linux; compile-only proof does not certify execution",
        );
        aarch64_hash_compile_step.dependOn(&wrong_cross_target.step);
    }

    // BEGIN AARCH64 HASH CERTIFICATION CONTRACT
    const aarch64_hash_certify_step = b.step(
        "aarch64-hash-certify",
        "Fresh-run the hash contract and native regressions, then write raw AArch64 evidence",
    );
    if (builtin.target.cpu.arch == .aarch64 and
        target.result.cpu.arch == .aarch64 and
        target.query.isNative() and
        optimize == .Debug)
    {
        if (aarch64_evidence_out != null and
            aarch64_provenance != null and
            aarch64_runner_record != null)
        {
            const capture_runner_preflight = b.addSystemCommand(&.{
                "python3",
                "-B",
                "scripts/aarch64_hash_evidence.py",
                "runner-preflight",
                "--provenance",
            });
            capture_runner_preflight.addFileArg(.{ .cwd_relative = aarch64_provenance.? });
            capture_runner_preflight.addArg("--runner-record");
            capture_runner_preflight.addFileArg(.{ .cwd_relative = aarch64_runner_record.? });
            capture_runner_preflight.addArg("--output");
            capture_runner_preflight.has_side_effects = true;
            const certification_runner_preflight = capture_runner_preflight.addOutputFileArg(
                "aarch64-runner-preflight.json",
            );

            const capture_source_snapshot = b.addSystemCommand(&.{
                "python3",
                "-B",
                "scripts/aarch64_hash_evidence.py",
                "snapshot",
                "--repo-root",
            });
            capture_source_snapshot.addFileArg(b.path("."));
            capture_source_snapshot.addArg("--expected-build-zig-sha256");
            capture_source_snapshot.addArg(embedded_build_zig_sha256[0..]);
            capture_source_snapshot.addArg("--output");
            capture_source_snapshot.has_side_effects = true;
            const certification_source_snapshot = capture_source_snapshot.addOutputFileArg(
                "aarch64-certification-input-snapshot.json",
            );

            module_tests.step.dependOn(&capture_source_snapshot.step);
            ordinary_manifest_tests.step.dependOn(&capture_source_snapshot.step);
            hash_default_c_oracle.step.dependOn(&capture_source_snapshot.step);
            hash_default_zig_oracle.step.dependOn(&capture_source_snapshot.step);
            compare_oracles.step.dependOn(&capture_source_snapshot.step);
            native_aarch64_host_checker.step.dependOn(&capture_source_snapshot.step);
            header_checker.step.dependOn(&capture_source_snapshot.step);

            module_tests.step.dependOn(&capture_runner_preflight.step);
            ordinary_manifest_tests.step.dependOn(&capture_runner_preflight.step);
            hash_default_c_oracle.step.dependOn(&capture_runner_preflight.step);
            hash_default_zig_oracle.step.dependOn(&capture_runner_preflight.step);
            compare_oracles.step.dependOn(&capture_runner_preflight.step);
            native_aarch64_host_checker.step.dependOn(&capture_runner_preflight.step);
            header_checker.step.dependOn(&capture_runner_preflight.step);

            const run_native_aarch64_host = b.addRunArtifact(native_aarch64_host_checker);
            run_native_aarch64_host.has_side_effects = true;
            const native_aarch64_host_output = run_native_aarch64_host.captureStdOut(.{
                .basename = "aarch64-cert-native-host.txt",
            });

            const run_aarch64_header_checker = b.addRunArtifact(header_checker);
            run_aarch64_header_checker.addFileArg(b.path("tests/oracle/clay.h"));
            run_aarch64_header_checker.has_side_effects = true;
            run_aarch64_header_checker.step.dependOn(&run_native_aarch64_host.step);

            const run_aarch64_manifest_tests = b.addRunArtifact(ordinary_manifest_tests);
            run_aarch64_manifest_tests.has_side_effects = true;
            run_aarch64_manifest_tests.step.dependOn(&run_aarch64_header_checker.step);
            const aarch64_manifest_tests_log = run_aarch64_manifest_tests.captureStdErr(.{
                .basename = "aarch64-cert-manifest-tests.log",
            });

            const run_aarch64_module_tests = b.addRunArtifact(module_tests);
            run_aarch64_module_tests.has_side_effects = true;
            run_aarch64_module_tests.step.dependOn(&run_aarch64_header_checker.step);
            const aarch64_module_tests_log = run_aarch64_module_tests.captureStdErr(.{
                .basename = "aarch64-cert-module-tests.log",
            });

            const run_aarch64_hash_c = b.addRunArtifact(hash_default_c_oracle);
            run_aarch64_hash_c.has_side_effects = true;
            run_aarch64_hash_c.step.dependOn(&run_aarch64_header_checker.step);
            const aarch64_hash_c_output = run_aarch64_hash_c.captureStdOut(.{
                .basename = "aarch64-cert-hash-default-clay.txt",
            });

            const run_aarch64_hash_zig = b.addRunArtifact(hash_default_zig_oracle);
            run_aarch64_hash_zig.has_side_effects = true;
            run_aarch64_hash_zig.step.dependOn(&run_aarch64_header_checker.step);
            const aarch64_hash_zig_output = run_aarch64_hash_zig.captureStdOut(.{
                .basename = "aarch64-cert-hash-default-zig.txt",
            });

            const run_aarch64_hash_compare = b.addRunArtifact(compare_oracles);
            run_aarch64_hash_compare.has_side_effects = true;
            run_aarch64_hash_compare.addFileArg(aarch64_hash_c_output);
            run_aarch64_hash_compare.addFileArg(aarch64_hash_zig_output);

            const capture_evidence = b.addSystemCommand(&.{
                "python3",
                "-B",
                "scripts/aarch64_hash_evidence.py",
                "capture",
                "--repo-root",
            });
            capture_evidence.addFileArg(b.path("."));
            capture_evidence.addArg("--output");
            capture_evidence.addArg(aarch64_evidence_out.?);
            capture_evidence.addArg("--header");
            capture_evidence.has_side_effects = true;
            capture_evidence.addFileArg(b.path("tests/oracle/clay.h"));
            capture_evidence.addArg("--source-snapshot");
            capture_evidence.addFileArg(certification_source_snapshot);
            capture_evidence.addArg("--c-trace");
            capture_evidence.addFileArg(aarch64_hash_c_output);
            capture_evidence.addArg("--zig-trace");
            capture_evidence.addFileArg(aarch64_hash_zig_output);
            capture_evidence.addArg("--native-host-trace");
            capture_evidence.addFileArg(native_aarch64_host_output);
            capture_evidence.addArg("--runner-preflight");
            capture_evidence.addFileArg(certification_runner_preflight);
            capture_evidence.addArg("--module-tests-log");
            capture_evidence.addFileArg(aarch64_module_tests_log);
            capture_evidence.addArg("--ordinary-manifest-tests-log");
            capture_evidence.addFileArg(aarch64_manifest_tests_log);
            capture_evidence.addArgs(&.{
                "--zig-exe",
                b.graph.zig_exe,
                "--optimize",
                @tagName(optimize),
                "--target-triple",
                target.result.zigTriple(b.allocator) catch @panic("OOM"),
                "--target-arch",
                @tagName(target.result.cpu.arch),
                "--target-os",
                @tagName(target.result.os.tag),
                "--target-abi",
                @tagName(target.result.abi),
                "--target-endian",
                @tagName(target.result.cpu.arch.endian()),
                "--target-cpu-model",
                target.result.cpu.model.name,
                "--c-oracle-exe",
            });
            capture_evidence.addFileArg(hash_default_c_oracle.getEmittedBin());
            capture_evidence.addArg("--zig-oracle-exe");
            capture_evidence.addFileArg(hash_default_zig_oracle.getEmittedBin());
            capture_evidence.addArg("--comparator-exe");
            capture_evidence.addFileArg(compare_oracles.getEmittedBin());
            capture_evidence.addArg("--module-tests-exe");
            capture_evidence.addFileArg(module_tests.getEmittedBin());
            capture_evidence.addArg("--ordinary-manifest-tests-exe");
            capture_evidence.addFileArg(ordinary_manifest_tests.getEmittedBin());
            capture_evidence.addArg("--native-host-guard-exe");
            capture_evidence.addFileArg(native_aarch64_host_checker.getEmittedBin());
            capture_evidence.addArg("--header-checker-exe");
            capture_evidence.addFileArg(header_checker.getEmittedBin());

            capture_evidence.step.dependOn(&run_native_aarch64_host.step);
            capture_evidence.step.dependOn(&run_aarch64_header_checker.step);
            capture_evidence.step.dependOn(&run_aarch64_manifest_tests.step);
            capture_evidence.step.dependOn(&run_aarch64_module_tests.step);
            capture_evidence.step.dependOn(&run_aarch64_hash_compare.step);
            capture_evidence.step.dependOn(&aarch64_evidence_contract_tests.step);
            capture_evidence.step.dependOn(&aarch64_hash_build_contract_tests.step);
            capture_evidence.step.dependOn(&capture_source_snapshot.step);
            capture_evidence.step.dependOn(&capture_runner_preflight.step);
            aarch64_hash_certify_step.dependOn(&capture_evidence.step);
        } else {
            const missing_evidence_inputs = b.addFail(
                "aarch64-hash-certify requires -Daarch64-evidence-out, -Daarch64-provenance, and -Daarch64-runner-record",
            );
            aarch64_hash_certify_step.dependOn(&missing_evidence_inputs.step);
        }
    } else {
        const non_native_aarch64 = b.addFail(
            "aarch64-hash-certify requires Debug with a native target query on an AArch64 build host; cross-target, emulated, translated, or non-Debug execution is not certification",
        );
        aarch64_hash_certify_step.dependOn(&non_native_aarch64.step);
    }
    // END AARCH64 HASH CERTIFICATION CONTRACT

    const parity_regression_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    parity_regression_c_module.addIncludePath(b.path("tests/oracle"));
    parity_regression_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/parity_regression_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const parity_regression_c_oracle = b.addExecutable(.{
        .name = "zlay-parity-regression-clay-oracle",
        .root_module = parity_regression_c_module,
    });
    const run_parity_regression_c = b.addRunArtifact(parity_regression_c_oracle);
    const parity_regression_c_output = run_parity_regression_c.captureStdOut(.{ .basename = "parity-regression-clay-oracle.txt" });

    const parity_regression_zig_oracle = b.addExecutable(.{
        .name = "zlay-parity-regression-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/parity_regression_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_parity_regression_zig = b.addRunArtifact(parity_regression_zig_oracle);
    const parity_regression_zig_output = run_parity_regression_zig.captureStdOut(.{ .basename = "parity-regression-zig-oracle.txt" });

    const run_parity_regression_compare = b.addRunArtifact(compare_oracles);
    run_parity_regression_compare.addFileArg(parity_regression_c_output);
    run_parity_regression_compare.addFileArg(parity_regression_zig_output);

    const public_values_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    public_values_c_module.addIncludePath(b.path("tests/oracle"));
    public_values_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/public_values_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const public_values_c_oracle = b.addExecutable(.{
        .name = "zlay-public-values-clay-oracle",
        .root_module = public_values_c_module,
    });
    const run_public_values_c = b.addRunArtifact(public_values_c_oracle);
    const public_values_c_output = run_public_values_c.captureStdOut(.{ .basename = "public-values-clay-oracle.txt" });

    const public_values_zig_oracle = b.addExecutable(.{
        .name = "zlay-public-values-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/public_values_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_public_values_zig = b.addRunArtifact(public_values_zig_oracle);
    const public_values_zig_output = run_public_values_zig.captureStdOut(.{ .basename = "public-values-zig-oracle.txt" });

    const run_public_values_compare = b.addRunArtifact(compare_oracles);
    run_public_values_compare.addFileArg(public_values_c_output);
    run_public_values_compare.addFileArg(public_values_zig_output);

    const layout_scroll_breadth_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    layout_scroll_breadth_c_module.addIncludePath(b.path("tests/oracle"));
    layout_scroll_breadth_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/layout_scroll_breadth_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const layout_scroll_breadth_c_oracle = b.addExecutable(.{
        .name = "zlay-layout-scroll-breadth-clay-oracle",
        .root_module = layout_scroll_breadth_c_module,
    });
    const run_layout_scroll_breadth_c = b.addRunArtifact(layout_scroll_breadth_c_oracle);
    const layout_scroll_breadth_c_output = run_layout_scroll_breadth_c.captureStdOut(.{ .basename = "layout-scroll-breadth-clay-oracle.txt" });

    const layout_scroll_breadth_zig_oracle = b.addExecutable(.{
        .name = "zlay-layout-scroll-breadth-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/layout_scroll_breadth_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_layout_scroll_breadth_zig = b.addRunArtifact(layout_scroll_breadth_zig_oracle);
    const layout_scroll_breadth_zig_output = run_layout_scroll_breadth_zig.captureStdOut(.{ .basename = "layout-scroll-breadth-zig-oracle.txt" });

    const run_layout_scroll_breadth_compare = b.addRunArtifact(compare_oracles);
    run_layout_scroll_breadth_compare.addFileArg(layout_scroll_breadth_c_output);
    run_layout_scroll_breadth_compare.addFileArg(layout_scroll_breadth_zig_output);

    const text_cache_lifecycle_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    text_cache_lifecycle_c_module.addIncludePath(b.path("tests/oracle"));
    text_cache_lifecycle_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/text_cache_lifecycle_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const text_cache_lifecycle_c_oracle = b.addExecutable(.{
        .name = "zlay-text-cache-lifecycle-clay-oracle",
        .root_module = text_cache_lifecycle_c_module,
    });
    const run_text_cache_lifecycle_c = b.addRunArtifact(text_cache_lifecycle_c_oracle);
    const text_cache_lifecycle_c_output = run_text_cache_lifecycle_c.captureStdOut(.{ .basename = "text-cache-lifecycle-clay-oracle.txt" });

    const text_cache_lifecycle_zig_oracle = b.addExecutable(.{
        .name = "zlay-text-cache-lifecycle-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/text_cache_lifecycle_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_text_cache_lifecycle_zig = b.addRunArtifact(text_cache_lifecycle_zig_oracle);
    const text_cache_lifecycle_zig_output = run_text_cache_lifecycle_zig.captureStdOut(.{ .basename = "text-cache-lifecycle-zig-oracle.txt" });

    const run_text_cache_lifecycle_compare = b.addRunArtifact(compare_oracles);
    run_text_cache_lifecycle_compare.addFileArg(text_cache_lifecycle_c_output);
    run_text_cache_lifecycle_compare.addFileArg(text_cache_lifecycle_zig_output);

    const text_cache_runtime_setter_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    text_cache_runtime_setter_c_module.addIncludePath(b.path("tests/oracle"));
    text_cache_runtime_setter_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/text_cache_runtime_setter_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const text_cache_runtime_setter_c_oracle = b.addExecutable(.{
        .name = "zlay-text-cache-runtime-setter-clay-oracle",
        .root_module = text_cache_runtime_setter_c_module,
    });
    const run_text_cache_runtime_setter_c = b.addRunArtifact(text_cache_runtime_setter_c_oracle);
    const text_cache_runtime_setter_c_output = run_text_cache_runtime_setter_c.captureStdOut(.{ .basename = "text-cache-runtime-setter-clay-oracle.txt" });

    const text_cache_runtime_setter_zig_oracle = b.addExecutable(.{
        .name = "zlay-text-cache-runtime-setter-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/text_cache_runtime_setter_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_text_cache_runtime_setter_zig = b.addRunArtifact(text_cache_runtime_setter_zig_oracle);
    const text_cache_runtime_setter_zig_output = run_text_cache_runtime_setter_zig.captureStdOut(.{ .basename = "text-cache-runtime-setter-zig-oracle.txt" });

    const run_text_cache_runtime_setter_compare = b.addRunArtifact(compare_oracles);
    run_text_cache_runtime_setter_compare.addFileArg(text_cache_runtime_setter_c_output);
    run_text_cache_runtime_setter_compare.addFileArg(text_cache_runtime_setter_zig_output);

    const transition_lifecycle_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    transition_lifecycle_c_module.addIncludePath(b.path("tests/oracle"));
    transition_lifecycle_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/transition_lifecycle_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const transition_lifecycle_c_oracle = b.addExecutable(.{
        .name = "zlay-transition-lifecycle-clay-oracle",
        .root_module = transition_lifecycle_c_module,
    });
    const run_transition_lifecycle_c = b.addRunArtifact(transition_lifecycle_c_oracle);
    const transition_lifecycle_c_output = run_transition_lifecycle_c.captureStdOut(.{ .basename = "transition-lifecycle-clay-oracle.txt" });

    const transition_lifecycle_zig_oracle = b.addExecutable(.{
        .name = "zlay-transition-lifecycle-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/transition_lifecycle_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_transition_lifecycle_zig = b.addRunArtifact(transition_lifecycle_zig_oracle);
    const transition_lifecycle_zig_output = run_transition_lifecycle_zig.captureStdOut(.{ .basename = "transition-lifecycle-zig-oracle.txt" });

    const transition_lifecycle_checker = b.addExecutable(.{
        .name = "zlay-check-transition-lifecycle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_transition_lifecycle.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_transition_lifecycle_checker = b.addRunArtifact(transition_lifecycle_checker);
    run_transition_lifecycle_checker.addFileArg(transition_lifecycle_c_output);
    run_transition_lifecycle_checker.addFileArg(transition_lifecycle_zig_output);

    const scroll_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    scroll_c_module.addIncludePath(b.path("tests/oracle"));
    scroll_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/scroll_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const scroll_c_oracle = b.addExecutable(.{
        .name = "zlay-scroll-clay-oracle",
        .root_module = scroll_c_module,
    });
    const run_scroll_c = b.addRunArtifact(scroll_c_oracle);
    const scroll_c_output = run_scroll_c.captureStdOut(.{ .basename = "scroll-clay-oracle.txt" });

    const scroll_zig_oracle = b.addExecutable(.{
        .name = "zlay-scroll-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/scroll_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_scroll_zig = b.addRunArtifact(scroll_zig_oracle);
    const scroll_zig_output = run_scroll_zig.captureStdOut(.{ .basename = "scroll-zig-oracle.txt" });

    const scroll_divergence_checker = b.addExecutable(.{
        .name = "zlay-check-scroll-divergence",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_scroll_divergence.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_scroll_divergence_checker = b.addRunArtifact(scroll_divergence_checker);
    run_scroll_divergence_checker.addFileArg(scroll_c_output);
    run_scroll_divergence_checker.addFileArg(scroll_zig_output);

    const safety_divergence_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    safety_divergence_c_module.addIncludePath(b.path("tests/oracle"));
    safety_divergence_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/safety_divergence_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const safety_divergence_c_oracle = b.addExecutable(.{
        .name = "zlay-safety-divergence-clay-oracle",
        .root_module = safety_divergence_c_module,
    });
    const run_safety_divergence_c = b.addRunArtifact(safety_divergence_c_oracle);
    const safety_divergence_c_output = run_safety_divergence_c.captureStdOut(.{ .basename = "safety-divergence-clay-oracle.txt" });

    const safety_divergence_zig_oracle = b.addExecutable(.{
        .name = "zlay-safety-divergence-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/safety_divergence_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_safety_divergence_zig = b.addRunArtifact(safety_divergence_zig_oracle);
    const safety_divergence_zig_output = run_safety_divergence_zig.captureStdOut(.{ .basename = "safety-divergence-zig-oracle.txt" });

    const safety_divergence_checker = b.addExecutable(.{
        .name = "zlay-check-safety-divergences",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_safety_divergences.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_safety_divergence_checker = b.addRunArtifact(safety_divergence_checker);
    run_safety_divergence_checker.addFileArg(safety_divergence_c_output);
    run_safety_divergence_checker.addFileArg(safety_divergence_zig_output);

    const retained_context_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    retained_context_c_module.addIncludePath(b.path("tests/oracle"));
    retained_context_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/retained_context_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const retained_context_c_oracle = b.addExecutable(.{
        .name = "zlay-retained-context-clay-oracle",
        .root_module = retained_context_c_module,
    });
    const run_retained_context_c = b.addRunArtifact(retained_context_c_oracle);
    const retained_context_c_output = run_retained_context_c.captureStdOut(.{ .basename = "retained-context-clay-oracle.txt" });

    const retained_context_zig_oracle = b.addExecutable(.{
        .name = "zlay-retained-context-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/retained_context_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_retained_context_zig = b.addRunArtifact(retained_context_zig_oracle);
    const retained_context_zig_output = run_retained_context_zig.captureStdOut(.{ .basename = "retained-context-zig-oracle.txt" });

    const retained_context_checker = b.addExecutable(.{
        .name = "zlay-check-retained-context-divergences",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_retained_context_divergences.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_retained_context_checker = b.addRunArtifact(retained_context_checker);
    run_retained_context_checker.addFileArg(retained_context_c_output);
    run_retained_context_checker.addFileArg(retained_context_zig_output);

    const no_open_api_c_module = b.createModule(.{
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    no_open_api_c_module.addIncludePath(b.path("tests/oracle"));
    no_open_api_c_module.addCSourceFile(.{
        .file = b.path("tests/oracle/no_open_api_fixture.c"),
        .flags = &.{"-std=c99"},
    });
    const no_open_api_c_oracle = b.addExecutable(.{
        .name = "zlay-no-open-api-clay-oracle",
        .root_module = no_open_api_c_module,
    });
    const run_no_open_api_c = b.addRunArtifact(no_open_api_c_oracle);
    const no_open_api_c_output = run_no_open_api_c.captureStdOut(.{ .basename = "no-open-api-clay-oracle.txt" });

    const no_open_api_zig_oracle = b.addExecutable(.{
        .name = "zlay-no-open-api-zig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/no_open_api_fixture.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "zlay", .module = zlay }},
        }),
    });
    const run_no_open_api_zig = b.addRunArtifact(no_open_api_zig_oracle);
    const no_open_api_zig_output = run_no_open_api_zig.captureStdOut(.{ .basename = "no-open-api-zig-oracle.txt" });

    const no_open_api_checker = b.addExecutable(.{
        .name = "zlay-check-no-open-api-divergence",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle/check_no_open_api_divergence.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_no_open_api_checker = b.addRunArtifact(no_open_api_checker);
    run_no_open_api_checker.addFileArg(no_open_api_c_output);
    run_no_open_api_checker.addFileArg(no_open_api_zig_output);

    const parity_step = b.step("parity", "Verify exact pinned-Clay/native-Zig behavioral fixtures");
    parity_step.dependOn(&run_header_checker.step);
    parity_step.dependOn(&public_api_manifest_tests.step);
    parity_step.dependOn(&run_ordinary_manifest_tests.step);
    parity_step.dependOn(&run_compare.step);
    parity_step.dependOn(&run_complex_compare.step);
    parity_step.dependOn(&run_transition_compare.step);
    parity_step.dependOn(&run_transition_matrix_compare.step);
    parity_step.dependOn(&run_pointer_compare.step);
    parity_step.dependOn(&run_floating_pointer_edge_compare.step);
    parity_step.dependOn(&run_scroll_parity_compare.step);
    parity_step.dependOn(&run_external_scroll_compare.step);
    parity_step.dependOn(&run_render_compare.step);
    parity_step.dependOn(&run_sizing_text_compare.step);
    parity_step.dependOn(&run_string_text_edge_compare.step);
    parity_step.dependOn(&run_declaration_layout_compare.step);
    parity_step.dependOn(&run_api_diagnostics_compare.step);
    parity_step.dependOn(&run_debug_compare.step);
    parity_step.dependOn(&run_id_error_compare.step);
    parity_step.dependOn(&run_id_collision_compare.step);
    parity_step.dependOn(&run_capacity_match_checker.step);
    parity_step.dependOn(&run_public_metadata_compare.step);
    parity_step.dependOn(&run_ease_out_compare.step);
    parity_step.dependOn(&run_hash_default_compare.step);
    parity_step.dependOn(&run_parity_regression_compare.step);
    parity_step.dependOn(&run_public_values_compare.step);
    parity_step.dependOn(&run_layout_scroll_breadth_compare.step);
    parity_step.dependOn(&run_text_cache_lifecycle_compare.step);
    parity_step.dependOn(&run_text_cache_runtime_setter_compare.step);
    parity_step.dependOn(&run_transition_lifecycle_checker.step);

    const divergence_step = b.step("reviewed-divergences", "Verify reviewed intentional native divergences against pinned C traces");
    divergence_step.dependOn(&run_header_checker.step);
    divergence_step.dependOn(&run_scroll_divergence_checker.step);
    divergence_step.dependOn(&run_duplicate_lookup_divergence_checker.step);
    divergence_step.dependOn(&run_capacity_divergence_checker.step);
    divergence_step.dependOn(&run_safety_divergence_checker.step);
    divergence_step.dependOn(&run_retained_context_checker.step);
    divergence_step.dependOn(&run_no_open_api_checker.step);

    const verify_step = b.step("verify", "Alias for the complete local verification gate");
    verify_step.dependOn(check_step);
    verify_step.dependOn(parity_step);
    verify_step.dependOn(divergence_step);
    verify_step.dependOn(wasm_runtime_step);

    const verify_debug = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "verify",
        "-Doptimize=Debug",
        "--cache-dir",
        ".zig-cache/verify-debug",
    });
    const verify_release_safe = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "verify",
        "-Doptimize=ReleaseSafe",
        "--cache-dir",
        ".zig-cache/verify-release-safe",
    });
    const check_release_fast = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "check",
        "-Doptimize=ReleaseFast",
        "--cache-dir",
        ".zig-cache/check-release-fast",
    });
    const check_release_small = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "check",
        "-Doptimize=ReleaseSmall",
        "--cache-dir",
        ".zig-cache/check-release-small",
    });
    verify_release_safe.step.dependOn(&verify_debug.step);
    check_release_fast.step.dependOn(&verify_release_safe.step);
    check_release_small.step.dependOn(&check_release_fast.step);
    const verify_all_step = b.step("verify-all", "Run full Debug/ReleaseSafe verification plus ReleaseFast/ReleaseSmall C-free native/WebAssembly checks");
    verify_all_step.dependOn(&check_release_small.step);
    verify_all_step.dependOn(clay_coverage_certify_step);
}
