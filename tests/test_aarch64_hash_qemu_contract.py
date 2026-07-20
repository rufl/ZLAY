from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER_PATH = REPO_ROOT / "scripts/check_aarch64_hash_qemu_contract.py"
BUILD_PATH = REPO_ROOT / "build.zig"
COMPARE_PATH = REPO_ROOT / "tests/oracle/compare.zig"

SPEC = importlib.util.spec_from_file_location(
    "check_aarch64_hash_qemu_contract", CHECKER_PATH
)
if SPEC is None or SPEC.loader is None:  # pragma: no cover - import invariant
    raise RuntimeError(f"cannot load {CHECKER_PATH}")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class Aarch64HashQemuContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build_source = BUILD_PATH.read_text(encoding="utf-8")
        cls.compare_source = COMPARE_PATH.read_text(encoding="utf-8")

    def assert_rejected(
        self,
        label: str,
        *,
        build_source: str | None = None,
        compare_source: str | None = None,
    ) -> None:
        with self.subTest(label=label):
            with self.assertRaises(checker.ContractError):
                checker.check_qemu_contract(
                    self.build_source if build_source is None else build_source,
                    self.compare_source if compare_source is None else compare_source,
                )

    def replace_once(self, source: str, old: str, new: str, label: str) -> str:
        self.assertEqual(1, source.count(old), f"{label}: mutation anchor count")
        return source.replace(old, new, 1)

    def replace_lane_once(self, old: str, new: str, label: str) -> str:
        begin = self.build_source.index(checker.BEGIN_MARKER) + len(
            checker.BEGIN_MARKER
        )
        end = self.build_source.index(checker.END_MARKER)
        lane = self.build_source[begin:end]
        changed = self.replace_once(lane, old, new, label)
        return self.build_source[:begin] + changed + self.build_source[end:]

    def replace_compare_once(self, old: str, new: str, label: str) -> str:
        return self.replace_once(self.compare_source, old, new, label)

    def test_current_sources_satisfy_contract(self) -> None:
        checker.check_qemu_contract(self.build_source, self.compare_source)

    def test_markers_are_exact_and_unique(self) -> None:
        for marker in (checker.BEGIN_MARKER, checker.END_MARKER):
            self.assert_rejected(
                f"changed {marker}",
                build_source=self.replace_once(
                    self.build_source, marker, f"{marker} changed", marker
                ),
            )
            self.assert_rejected(
                f"duplicate {marker}", build_source=f"{marker}\n{self.build_source}"
            )

    def test_raw_embedded_build_source_for_pre_gate_is_exact(self) -> None:
        mutations = (
            (
                'const embedded_build_zig_source = @embedFile("build.zig");',
                'const embedded_build_zig_text = @embedFile("build.zig");',
                "embedded source declaration",
            ),
            (
                'const embedded_build_zig_source = @embedFile("build.zig");',
                'const embedded_build_zig_source = @embedFile("build.zig.zon");',
                "embedded build source",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(
                label,
                build_source=self.replace_once(self.build_source, old, new, label),
            )
        declaration = 'const embedded_build_zig_source = @embedFile("build.zig");'
        self.assert_rejected(
            "duplicate embedded source declaration",
            build_source=f"{declaration}\n{self.build_source}",
        )

    def test_target_and_artifact_pins_cannot_drift(self) -> None:
        mutations = (
            (".cpu_arch = .aarch64", ".cpu_arch = .x86_64", "target arch"),
            (".cpu_model = .baseline", ".cpu_model = .native", "target CPU"),
            (".os_tag = .linux", ".os_tag = .windows", "target OS"),
            (".abi = .musl", ".abi = .gnu", "target ABI"),
            (
                '.root_source_file = b.path("src/root.zig"),',
                '.root_source_file = b.path("src/hash.zig"),',
                "root source",
            ),
            (
                'b.path("tests/oracle/ordinary_manifest.zig")',
                'b.path("src/root.zig")',
                "manifest source",
            ),
            (
                'b.path("tests/oracle/hash_default_fixture.c")',
                'b.path("tests/oracle/not_default.c")',
                "C fixture",
            ),
            (
                'b.path("tests/oracle/hash_default_fixture.zig")',
                'b.path("tests/oracle/not_default.zig")',
                "Zig fixture",
            ),
            (
                '.root_source_file = b.path("tests/oracle/compare.zig"),',
                '.root_source_file = b.path("tests/oracle/check_header.zig"),',
                "comparator source",
            ),
            (".target = b.graph.host", ".target = aarch64_qemu_target", "host comparator"),
            (
                "aarch64_qemu_module_tests.linkage = .static;",
                "aarch64_qemu_module_tests.linkage = .dynamic;",
                "module-test linkage",
            ),
            (
                ".root_source_file = b.path(\"src/root.zig\"),\n"
                "        .target = aarch64_qemu_target,\n"
                "        .optimize = .Debug,",
                ".root_source_file = b.path(\"src/root.zig\"),\n"
                "        .target = aarch64_qemu_target,\n"
                "        .optimize = .ReleaseSafe,",
                "root optimization",
            ),
            ('&.{"-std=c99"}', '&.{"-std=gnu99"}', "C language pin"),
        )
        for old, new, label in mutations:
            self.assert_rejected(
                label, build_source=self.replace_lane_once(old, new, label)
            )

    def test_runtime_source_pre_gate_command_output_and_freshness_are_exact(self) -> None:
        command_prefix = (
            '"python3",\n'
            '            "-B",\n'
            '            "scripts/aarch64_hash_qemu_report.py",\n'
            '            "source-contract",'
        )
        mutations = (
            (
                command_prefix,
                command_prefix.replace('"python3"', '"python"'),
                "pre-gate Python",
            ),
            (
                command_prefix,
                command_prefix.replace('"-B"', '"-O"'),
                "pre-gate no-bytecode mode",
            ),
            (
                command_prefix,
                command_prefix.replace('"source-contract"', '"report"'),
                "pre-gate subcommand",
            ),
            (
                '"source-contract",\n            "--repo-root",\n'
                '            b.pathFromRoot("."),',
                '"source-contract",\n            "--repo-root",\n'
                '            b.pathFromRoot(".."),',
                "pre-gate repo root",
            ),
            (
                '"--expected-build-zig-source",',
                '"--expected-build-zig-sha256",',
                "pre-gate expected source option",
            ),
            (
                "capture_aarch64_qemu_source_contract.addFileArg("
                "aarch64_qemu_embedded_build_zig);",
                "capture_aarch64_qemu_source_contract.addFileArg("
                "aarch64_qemu_source_contract);",
                "pre-gate generated source binding",
            ),
            (
                "capture_aarch64_qemu_source_contract.has_side_effects = true;",
                "capture_aarch64_qemu_source_contract.has_side_effects = false;",
                "pre-gate freshness",
            ),
            (
                "capture_aarch64_qemu_source_contract.captureStdOut(",
                "capture_aarch64_qemu_source_contract.addOutputFileArg(",
                "pre-gate stdout capture",
            ),
            (
                '"aarch64-qemu-source-contract.sha256"',
                '"source-contract.txt"',
                "pre-gate output basename",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(
                label, build_source=self.replace_lane_once(old, new, label)
            )

        declaration = (
            "const capture_aarch64_qemu_source_contract = b.addSystemCommand(&.{"
        )
        self.assert_rejected(
            "deleted pre-gate command",
            build_source=self.replace_lane_once(
                declaration,
                "const capture_aarch64_qemu_source_contract = b.addRunArtifact(&.{",
                "pre-gate command",
            ),
        )

    def test_write_files_embedded_build_artifact_is_exact(self) -> None:
        mutations = (
            (
                "const write_aarch64_qemu_embedded_build = b.addWriteFiles();",
                "const write_aarch64_qemu_embedded_build = b.addUpdateSourceFiles();",
                "WriteFiles step",
            ),
            (
                '"aarch64-qemu-embedded-build.zig",',
                '"embedded-build.txt",',
                "generated build source name",
            ),
            (
                "            embedded_build_zig_source,\n        );",
                '            "not the embedded build",\n        );',
                "generated build source content",
            ),
            (
                "capture_aarch64_qemu_source_contract.addFileArg("
                "aarch64_qemu_embedded_build_zig);",
                "",
                "generated build source argument",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(
                label, build_source=self.replace_lane_once(old, new, label)
            )

        option = '            "--expected-build-zig-source",\n        });\n'
        reordered = (
            '            "--expected-build-zig-source",\n'
            "        });\n"
            "        capture_aarch64_qemu_source_contract.has_side_effects = true;\n"
        )
        old = (
            option
            + "        capture_aarch64_qemu_source_contract.addFileArg("
            "aarch64_qemu_embedded_build_zig);\n"
            + "        capture_aarch64_qemu_source_contract.has_side_effects = true;\n"
        )
        new = (
            reordered
            + "        capture_aarch64_qemu_source_contract.addFileArg("
            "aarch64_qemu_embedded_build_zig);\n"
        )
        self.assert_rejected(
            "reordered expected-source file binding",
            build_source=self.replace_lane_once(old, new, "source binding order"),
        )

    def test_qemu_pre_gate_forbids_old_digest_bindings(self) -> None:
        anchor = (
            "capture_aarch64_qemu_source_contract.addFileArg("
            "aarch64_qemu_embedded_build_zig);"
        )
        injections = (
            "capture_aarch64_qemu_source_contract.addArg("
            "embedded_build_zig_sha256[0..]);",
            'capture_aarch64_qemu_source_contract.addArg('
            '"--expected-build-zig-sha256");',
        )
        for injection in injections:
            self.assert_rejected(
                injection,
                build_source=self.replace_lane_once(
                    anchor, f"{anchor}\n        {injection}", injection
                ),
            )

    def test_every_compile_step_depends_on_pre_gate_in_exact_order(self) -> None:
        for compile_step in checker.PRE_GATE_COMPILE_STEPS:
            dependency = (
                f"{compile_step}.step.dependOn"
                "(&capture_aarch64_qemu_source_contract.step);"
            )
            self.assert_rejected(
                f"removed pre-gate dependency {compile_step}",
                build_source=self.replace_lane_once(dependency, "", compile_step),
            )

        first = (
            "aarch64_qemu_module_tests.step.dependOn"
            "(&capture_aarch64_qemu_source_contract.step);\n"
            "        aarch64_qemu_manifest_tests.step.dependOn"
            "(&capture_aarch64_qemu_source_contract.step);"
        )
        swapped = (
            "aarch64_qemu_manifest_tests.step.dependOn"
            "(&capture_aarch64_qemu_source_contract.step);\n"
            "        aarch64_qemu_module_tests.step.dependOn"
            "(&capture_aarch64_qemu_source_contract.step);"
        )
        self.assert_rejected(
            "reordered pre-gate compile dependencies",
            build_source=self.replace_lane_once(first, swapped, "pre-gate order"),
        )

        injected = self.replace_once(
            self.build_source,
            "pub fn build(b: *std.Build) void {",
            "const aarch64_qemu_source_contract_sha256 = \"0\" ** 64;\n\n"
            "pub fn build(b: *std.Build) void {",
            "obsolete comptime source digest",
        )
        self.assert_rejected("obsolete comptime source digest", build_source=injected)

    def test_each_qemu_run_requires_exact_artifact_exit_and_freshness(self) -> None:
        for run_variable, artifact in checker.QEMU_RUNS.items():
            mutations = (
                (
                    f"{run_variable}.addFileArg({artifact}.getEmittedBin());",
                    f"{run_variable}.addFileArg(aarch64_qemu_c_oracle.getEmittedBin());"
                    if artifact != "aarch64_qemu_c_oracle"
                    else f"{run_variable}.addFileArg(aarch64_qemu_zig_oracle.getEmittedBin());",
                    "artifact",
                ),
                (
                    f"{run_variable}.expectExitCode(0);",
                    f"{run_variable}.expectExitCode(1);",
                    "exit",
                ),
                (
                    f"{run_variable}.expectExitCode(0);",
                    "",
                    "removed exit",
                ),
                (
                    f"{run_variable}.has_side_effects = true;",
                    f"{run_variable}.has_side_effects = false;",
                    "freshness",
                ),
            )
            for old, new, field in mutations:
                label = f"{run_variable} {field}"
                self.assert_rejected(
                    label, build_source=self.replace_lane_once(old, new, label)
                )

    def test_qemu_executor_and_cpu_are_not_substitutable(self) -> None:
        mutations = (
            (
                'b.findProgram(&.{"qemu-aarch64"}, &.{}) catch null',
                'b.findProgram(&.{"qemu-system-aarch64"}, &.{}) catch null',
                "alternative resolver",
            ),
            (
                "const run_aarch64_qemu_module_tests = "
                'b.addSystemCommand(&.{ qemu_exe, "-cpu", "max" });',
                "const run_aarch64_qemu_module_tests = "
                'b.addSystemCommand(&.{ "qemu-aarch64", "-cpu", "max" });',
                "hard-coded executor",
            ),
            (
                "const run_aarch64_qemu_module_tests = "
                'b.addSystemCommand(&.{ qemu_exe, "-cpu", "max" });',
                "const run_aarch64_qemu_module_tests = "
                'b.addSystemCommand(&.{ qemu_exe, "-cpu", "baseline" });',
                "changed QEMU CPU",
            ),
            (
                "const run_aarch64_qemu_module_tests = "
                'b.addSystemCommand(&.{ qemu_exe, "-cpu", "max" });',
                "const run_aarch64_qemu_module_tests = "
                "b.addRunArtifact(aarch64_qemu_module_tests);",
                "addRunArtifact substitution",
            ),
            (
                "const run_aarch64_qemu_module_tests = "
                'b.addSystemCommand(&.{ qemu_exe, "-cpu", "max" });',
                "",
                "deleted QEMU run",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(
                label, build_source=self.replace_lane_once(old, new, label)
            )

        for basename in (
            "hash-default-clay-oracle.txt",
            "hash-default-zig-oracle.txt",
        ):
            self.assert_rejected(
                f"changed capture basename {basename}",
                build_source=self.replace_lane_once(
                    basename, f"aarch64-qemu-{basename}", basename
                ),
            )

    def test_module_and_manifest_stderr_logs_are_exact(self) -> None:
        captures = (
            (
                "aarch64_qemu_module_tests_log",
                "run_aarch64_qemu_module_tests",
                "aarch64-qemu-module-tests.log",
            ),
            (
                "aarch64_qemu_manifest_tests_log",
                "run_aarch64_qemu_manifest_tests",
                "aarch64-qemu-manifest-tests.log",
            ),
        )
        for output, run_variable, basename in captures:
            mutations = (
                (
                    f"{run_variable}.captureStdErr(",
                    f"{run_variable}.captureStdOut(",
                    "capture channel",
                ),
                (f'"{basename}"', f'"changed-{basename}"', "basename"),
                (
                    f"const {output} = {run_variable}.captureStdErr(",
                    f"const {output} = {run_variable}.captureStdOut(",
                    "capture declaration",
                ),
            )
            for old, new, field in mutations:
                label = f"{output} {field}"
                self.assert_rejected(
                    label, build_source=self.replace_lane_once(old, new, label)
                )

    def test_comparator_inputs_mode_report_and_exit_are_exact(self) -> None:
        c_input = "run_aarch64_qemu_compare.addFileArg(aarch64_qemu_c_output);"
        zig_input = "run_aarch64_qemu_compare.addFileArg(aarch64_qemu_zig_output);"
        ordered = f"{c_input}\n        {zig_input}"
        mutations = (
            (ordered, f"{zig_input}\n        {c_input}", "swapped comparator inputs"),
            (ordered, f"{c_input}\n        {c_input}", "duplicate comparator input"),
            (
                'run_aarch64_qemu_compare.addArg("--qemu-aarch64-report");',
                'run_aarch64_qemu_compare.addArg("--report");',
                "comparator mode",
            ),
            (
                "run_aarch64_qemu_compare.expectExitCode(0);",
                "run_aarch64_qemu_compare.expectExitCode(1);",
                "comparator exit",
            ),
            (
                "run_aarch64_qemu_compare.has_side_effects = true;",
                "run_aarch64_qemu_compare.has_side_effects = false;",
                "comparator freshness",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(
                label, build_source=self.replace_lane_once(old, new, label)
            )

        for field in (
            "cpu=baseline ",
            "qemu_cpu=max ",
            "certification=false ",
            "physical_machine_proof=false ",
            "backlog_closed=false",
        ):
            self.assert_rejected(
                f"removed build report field {field}",
                build_source=self.replace_lane_once(field, "", field),
            )

    def test_reporter_cli_inputs_artifacts_and_source_file_are_exact(self) -> None:
        mutations = (
            (
                '"python3",\n            "-B",\n'
                '            "scripts/aarch64_hash_qemu_report.py",\n'
                '            "report",',
                '"python",\n            "-B",\n'
                '            "scripts/aarch64_hash_qemu_report.py",\n'
                '            "report",',
                "report Python",
            ),
            (
                '"scripts/aarch64_hash_qemu_report.py",\n            "report",',
                '"scripts/aarch64_hash_evidence.py",\n            "report",',
                "report script",
            ),
            (
                '"report",\n            "--repo-root",\n'
                '            b.pathFromRoot("."),',
                '"report",\n            "--repo-root",\n'
                '            b.pathFromRoot(".."),',
                "report repo root",
            ),
            ('"--qemu",\n            qemu_exe,', '"--qemu",\n            "qemu-aarch64",', "report QEMU"),
            ('"--zig",\n            b.graph.zig_exe,', '"--zig",\n            "zig",', "report Zig"),
            (
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_c_output);",
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_zig_output);",
                "duplicate report trace",
            ),
            (
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_zig_oracle.getEmittedBin());",
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_c_oracle.getEmittedBin());",
                "duplicate report oracle artifact",
            ),
            (
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_module_tests.getEmittedBin());",
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_manifest_tests.getEmittedBin());",
                "duplicate report test artifact",
            ),
            (
                'run_aarch64_qemu_report.addArg("--module-tests-log");',
                'run_aarch64_qemu_report.addArg("--module-log");',
                "module-tests log option",
            ),
            (
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_module_tests_log);",
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_manifest_tests_log);",
                "duplicate report test log",
            ),
            (
                'run_aarch64_qemu_report.addArg("--manifest-tests-log");',
                'run_aarch64_qemu_report.addArg("--manifest-log");',
                "manifest-tests log option",
            ),
            (
                'run_aarch64_qemu_report.addArg("--expected-source-file");',
                'run_aarch64_qemu_report.addArg("--expected-source-sha256");',
                "report source option",
            ),
            (
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_source_contract);",
                "run_aarch64_qemu_report.addFileArg(aarch64_qemu_c_output);",
                "report pre-gate output binding",
            ),
            (
                "run_aarch64_qemu_report.has_side_effects = true;",
                "run_aarch64_qemu_report.has_side_effects = false;",
                "report freshness",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(
                label, build_source=self.replace_lane_once(old, new, label)
            )

    def test_reporter_predecessors_and_final_dependency_are_exact(self) -> None:
        for dependency in checker.REPORT_DEPENDENCIES:
            line = (
                "run_aarch64_qemu_report.step.dependOn"
                f"(&{dependency}.step);"
            )
            self.assert_rejected(
                f"removed reporter dependency {dependency}",
                build_source=self.replace_lane_once(line, "", dependency),
            )

        first = (
            "run_aarch64_qemu_report.step.dependOn(&run_header_checker.step);\n"
            "        run_aarch64_qemu_report.step.dependOn"
            "(&run_aarch64_qemu_module_tests.step);"
        )
        swapped = (
            "run_aarch64_qemu_report.step.dependOn"
            "(&run_aarch64_qemu_module_tests.step);\n"
            "        run_aarch64_qemu_report.step.dependOn(&run_header_checker.step);"
        )
        self.assert_rejected(
            "reordered reporter dependencies",
            build_source=self.replace_lane_once(first, swapped, "dependency order"),
        )
        self.assert_rejected(
            "bypassed final reporter",
            build_source=self.replace_lane_once(
                "aarch64_hash_qemu_step.dependOn(&run_aarch64_qemu_report.step);",
                "aarch64_hash_qemu_step.dependOn(&run_aarch64_qemu_compare.step);",
                "final reporter dependency",
            ),
        )

    def test_missing_qemu_cannot_silently_skip(self) -> None:
        mutations = (
            (
                'const qemu_aarch64 = b.findProgram(&.{"qemu-aarch64"}, &.{}) catch null;',
                'const qemu_aarch64 = b.findProgram(&.{"qemu-aarch64"}, &.{}) catch return;',
                "resolver failure behavior",
            ),
            (
                "const missing_qemu_aarch64 = b.addFail(",
                "const missing_qemu_aarch64 = b.step(",
                "silent missing-QEMU step",
            ),
            (
                "aarch64-hash-qemu requires qemu-aarch64; this optional emulation lane is not certification",
                "qemu-aarch64 unavailable; skipped",
                "missing-QEMU message",
            ),
            (
                "aarch64_hash_qemu_step.dependOn(&missing_qemu_aarch64.step);",
                "// silently skipped",
                "missing-QEMU dependency",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(
                label, build_source=self.replace_lane_once(old, new, label)
            )

    def test_certification_evidence_provenance_and_host_guards_are_forbidden(self) -> None:
        injections = (
            "aarch64_hash_qemu_step.dependOn(&aarch64_hash_certify_step.step);",
            "run_aarch64_qemu_report.step.dependOn(&aarch64_evidence_out.step);",
            "const runner_provenance = aarch64_provenance;",
            "const native_host_guard = native_aarch64_host_checker;",
        )
        anchor = "aarch64_hash_qemu_step.dependOn(&run_aarch64_qemu_report.step);"
        for injection in injections:
            mutated = self.replace_lane_once(
                anchor, f"{injection}\n        {anchor}", injection
            )
            self.assert_rejected(injection, build_source=mutated)

    def test_compare_source_pins_four_args_qemu_mode_arch_identity_and_report(self) -> None:
        mutations = (
            (
                "if (args.len != 3 and args.len != 4)",
                "if (args.len != 3 and args.len != 4 and args.len != 5)",
                "compare argument count",
            ),
            ('"--qemu-aarch64-report"', '"--report"', "compare QEMU mode"),
            (
                "if (report_mode == .qemu_aarch64)\n        .aarch64\n    else\n        builtin.target.cpu.arch;",
                "builtin.target.cpu.arch;",
                "compare explicit AArch64 selection",
            ),
            (
                'std.mem.eql(u8, entry.identity, "hash-default")',
                'std.mem.eql(u8, entry.identity, "hash-reordered")',
                "compare identity",
            ),
            (
                "                entry.identity,\n"
                "                contract.line_count,",
                "                contract.line_count,\n"
                "                entry.identity,",
                "compare report argument order",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(
                label,
                compare_source=self.replace_compare_once(old, new, label),
            )

        for field in (
            "cpu=baseline ",
            "qemu_cpu=max ",
            "certification=false ",
            "physical_machine_proof=false ",
            "backlog_closed=false",
        ):
            self.assert_rejected(
                f"removed comparator report field {field}",
                compare_source=self.replace_compare_once(field, "", field),
            )

        self.assert_rejected(
            "comparator source digest argument",
            compare_source=self.replace_compare_once(
                "    const entry = manifest.entryForPaths(args[1], args[2]) orelse {",
                "    const source_contract_sha256 = args[4];\n"
                "    const entry = manifest.entryForPaths(args[1], args[2]) orelse {",
                "comparator source digest argument",
            ),
        )


if __name__ == "__main__":
    unittest.main()
