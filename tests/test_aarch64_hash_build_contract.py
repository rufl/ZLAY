from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER_PATH = REPO_ROOT / "scripts/check_aarch64_hash_build_contract.py"
BUILD_PATH = REPO_ROOT / "build.zig"

SPEC = importlib.util.spec_from_file_location("check_aarch64_hash_build_contract", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover - import setup invariant
    raise RuntimeError(f"cannot load {CHECKER_PATH}")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class Aarch64HashBuildContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = BUILD_PATH.read_text(encoding="utf-8")

    def assert_rejected(self, source: str, label: str) -> None:
        with self.subTest(label=label):
            with self.assertRaises(checker.ContractError):
                checker.check_build_contract(source)

    def replace_once(self, source: str, old: str, new: str, label: str) -> str:
        count = source.count(old)
        self.assertEqual(1, count, f"{label}: mutation anchor count")
        return source.replace(old, new, 1)

    def replace_contract_once(self, old: str, new: str, label: str) -> str:
        begin = self.source.index(checker.BEGIN_MARKER) + len(checker.BEGIN_MARKER)
        end = self.source.index(checker.END_MARKER)
        contract = self.source[begin:end]
        changed = self.replace_once(contract, old, new, label)
        return self.source[:begin] + changed + self.source[end:]

    def sub_contract_once(self, pattern: str, replacement: str, label: str) -> str:
        begin = self.source.index(checker.BEGIN_MARKER) + len(checker.BEGIN_MARKER)
        end = self.source.index(checker.END_MARKER)
        contract = self.source[begin:end]
        changed, count = re.subn(pattern, replacement, contract, count=1, flags=re.DOTALL)
        self.assertEqual(1, count, f"{label}: mutation anchor count")
        return self.source[:begin] + changed + self.source[end:]

    def test_current_build_satisfies_contract(self) -> None:
        checker.check_build_contract(self.source)

    def test_compile_time_build_zig_digest_is_mandatory(self) -> None:
        mutations = (
            (
                "const embedded_build_zig_sha256 = blk: {",
                "const embedded_build_zig_sha256 = [_]u8{0} ** 64; //",
                "embedded digest declaration",
            ),
            (
                'std.crypto.hash.sha2.Sha256.hash(@embedFile("build.zig"), &digest, .{});',
                'std.crypto.hash.sha2.Sha256.hash(@embedFile("build.zig.zon"), &digest, .{});',
                "embedded build.zig source",
            ),
            (
                "std.crypto.hash.sha2.Sha256.hash(",
                "std.crypto.hash.sha2.Sha512.hash(",
                "embedded SHA-256 hash",
            ),
            (
                "std.fmt.bytesToHex(digest, .lower)",
                "std.fmt.bytesToHex(digest, .upper)",
                "embedded digest encoding",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(self.replace_once(self.source, old, new, label), label)

    def test_markers_are_mandatory_and_unique(self) -> None:
        for marker in (checker.BEGIN_MARKER, checker.END_MARKER):
            self.assert_rejected(
                self.replace_once(self.source, marker, f"{marker} changed", marker),
                f"changed {marker}",
            )
            self.assert_rejected(f"{marker}\n{self.source}", f"duplicate {marker}")

    def test_required_build_options_cannot_change(self) -> None:
        for old, new in (
            ('"aarch64-evidence-out"', '"aarch64-evidence-output"'),
            ('"aarch64-provenance"', '"aarch64-runner-provenance"'),
            ('"aarch64-runner-record"', '"aarch64-runner-inventory"'),
        ):
            # The declarations are the first occurrences in build.zig. Replace
            # only that occurrence because failure messages repeat the spelling.
            index = self.source.index(old)
            mutated = self.source[:index] + new + self.source[index + len(old) :]
            self.assert_rejected(mutated, old)

    def test_host_target_native_and_debug_guards_are_mandatory(self) -> None:
        fragments = (
            ("builtin.target.cpu.arch == .aarch64", "builtin.target.cpu.arch == .x86_64"),
            ("target.result.cpu.arch == .aarch64", "target.result.cpu.arch == .x86_64"),
            ("target.query.isNative()", "!target.query.isNative()"),
            ("optimize == .Debug", "optimize == .ReleaseSafe"),
        )
        for old, new in fragments:
            self.assert_rejected(self.replace_contract_once(old, new, old), old)

    def test_evidence_inputs_must_all_be_guarded(self) -> None:
        for old, new in (
            ("aarch64_evidence_out != null", "aarch64_evidence_out == null"),
            ("aarch64_provenance != null", "aarch64_provenance == null"),
            ("aarch64_runner_record != null", "aarch64_runner_record == null"),
        ):
            self.assert_rejected(self.replace_contract_once(old, new, old), old)

    def test_every_certification_program_is_a_fresh_run(self) -> None:
        declarations = (
            "const run_native_aarch64_host = b.addRunArtifact(native_aarch64_host_checker);",
            "const run_aarch64_header_checker = b.addRunArtifact(header_checker);",
            "const run_aarch64_manifest_tests = b.addRunArtifact(ordinary_manifest_tests);",
            "const run_aarch64_module_tests = b.addRunArtifact(module_tests);",
            "const run_aarch64_hash_c = b.addRunArtifact(hash_default_c_oracle);",
            "const run_aarch64_hash_zig = b.addRunArtifact(hash_default_zig_oracle);",
            "const run_aarch64_hash_compare = b.addRunArtifact(compare_oracles);",
        )
        for declaration in declarations:
            self.assert_rejected(
                self.replace_contract_once(declaration, f"// removed: {declaration}", declaration),
                declaration,
            )

        self.assert_rejected(
            self.replace_contract_once(
                '"scripts/aarch64_hash_evidence.py",\n                "capture",',
                '"scripts/not_the_evidence_writer.py",\n                "capture",',
                "capture script",
            ),
            "capture script",
        )
        self.assert_rejected(
            self.replace_contract_once('"capture",', '"validate",', "capture mode"),
            "capture mode",
        )

    def test_final_capture_command_arguments_are_exact(self) -> None:
        capture_prefix = (
            '                "python3",\n'
            '                "-B",\n'
            '                "scripts/aarch64_hash_evidence.py",\n'
            '                "capture",'
        )
        mutations = (
            (
                capture_prefix,
                capture_prefix.replace(
                    '                "-B",\n',
                    '                "-B",\n                "-c",\n',
                ),
                "injected capture -c argument",
            ),
            (
                capture_prefix,
                capture_prefix.replace(
                    '                "python3",\n                "-B",',
                    '                "-B",\n                "python3",',
                ),
                "reordered capture command tokens",
            ),
            (
                '            capture_evidence.addArg("--output");\n'
                '            capture_evidence.addArg(aarch64_evidence_out.?);\n'
                '            capture_evidence.addArg("--header");',
                '            capture_evidence.addArg("--output");\n'
                '            capture_evidence.addArg("--unexpected");\n'
                '            capture_evidence.addArg("--header");',
                "extra capture string argument",
            ),
            (
                '            capture_evidence.addArg("--output");\n'
                '            capture_evidence.addArg(aarch64_evidence_out.?);\n'
                '            capture_evidence.addArg("--header");',
                '            capture_evidence.addArg("--output");\n'
                '            capture_evidence.addArg(aarch64_evidence_out.?);\n'
                '            capture_evidence.addArg(aarch64_provenance.?);\n'
                '            capture_evidence.addArg("--header");',
                "extra capture expression argument",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(self.replace_contract_once(old, new, label), label)

    def test_pre_gate_source_snapshot_command_and_output_are_pinned(self) -> None:
        snapshot_prefix = (
            '"python3",\n'
            '                "-B",\n'
            '                "scripts/aarch64_hash_evidence.py",\n'
            '                "snapshot",'
        )
        mutations = (
            (
                "const capture_source_snapshot = b.addSystemCommand(&.{",
                "const capture_source_snapshot = b.addRunArtifact(&.{",
                "snapshot system command",
            ),
            (
                snapshot_prefix,
                snapshot_prefix.replace('"python3"', '"python"'),
                "snapshot Python interpreter",
            ),
            (
                snapshot_prefix,
                snapshot_prefix.replace('"-B"', '"-O"'),
                "snapshot no-bytecode mode",
            ),
            (
                snapshot_prefix,
                snapshot_prefix.replace(
                    '"scripts/aarch64_hash_evidence.py"',
                    '"scripts/not_the_evidence_writer.py"',
                ),
                "snapshot script",
            ),
            ('"snapshot",', '"validate",', "snapshot mode"),
            (
                'capture_source_snapshot.addFileArg(b.path("."));',
                'capture_source_snapshot.addFileArg(b.path(".."));',
                "snapshot repository root",
            ),
            (
                'capture_source_snapshot.addArg("--expected-build-zig-sha256");',
                'capture_source_snapshot.addArg("--untrusted-build-zig-sha256");',
                "snapshot expected digest option",
            ),
            (
                "capture_source_snapshot.addArg(embedded_build_zig_sha256[0..]);",
                'capture_source_snapshot.addArg("0" ** 64);',
                "snapshot embedded digest value",
            ),
            ('capture_source_snapshot.addArg("--output");', 'capture_source_snapshot.addArg("--no-output");', "snapshot output option"),
            (
                "capture_source_snapshot.has_side_effects = true;",
                "capture_source_snapshot.has_side_effects = false;",
                "side-effecting snapshot",
            ),
            (
                "const certification_source_snapshot = capture_source_snapshot.addOutputFileArg(",
                "const certification_source_snapshot = capture_evidence.addOutputFileArg(",
                "generated snapshot output",
            ),
            (
                '"aarch64-certification-input-snapshot.json",',
                '"unbound-source-snapshot.json",',
                "snapshot output name",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(self.replace_contract_once(old, new, label), label)

    def test_runner_preflight_command_output_and_bindings_are_pinned(self) -> None:
        preflight_prefix = (
            '"python3",\n'
            '                "-B",\n'
            '                "scripts/aarch64_hash_evidence.py",\n'
            '                "runner-preflight",\n'
            '                "--provenance",'
        )
        mutations = (
            (
                "const capture_runner_preflight = b.addSystemCommand(&.{",
                "const capture_runner_preflight = b.addRunArtifact(&.{",
                "runner preflight system command",
            ),
            (
                preflight_prefix,
                preflight_prefix.replace('"python3"', '"python"'),
                "runner preflight Python interpreter",
            ),
            (
                preflight_prefix,
                preflight_prefix.replace('"-B"', '"-O"'),
                "runner preflight no-bytecode mode",
            ),
            (
                preflight_prefix,
                preflight_prefix.replace(
                    '"scripts/aarch64_hash_evidence.py"',
                    '"scripts/not_the_evidence_writer.py"',
                ),
                "runner preflight script",
            ),
            (
                '"runner-preflight",',
                '"runner-preflight-changed",',
                "runner preflight mode",
            ),
            (
                '"--provenance",',
                '"--changed-provenance",',
                "runner preflight provenance option",
            ),
            (
                "capture_runner_preflight.addFileArg(.{ .cwd_relative = aarch64_provenance.? });",
                "capture_runner_preflight.addFileArg(.{ .cwd_relative = aarch64_runner_record.? });",
                "runner preflight provenance binding",
            ),
            (
                'capture_runner_preflight.addArg("--runner-record");',
                'capture_runner_preflight.addArg("--changed-runner-record");',
                "runner preflight record option",
            ),
            (
                "capture_runner_preflight.addFileArg(.{ .cwd_relative = aarch64_runner_record.? });",
                "capture_runner_preflight.addFileArg(.{ .cwd_relative = aarch64_provenance.? });",
                "runner preflight record binding",
            ),
            (
                'capture_runner_preflight.addArg("--output");',
                'capture_runner_preflight.addArg("--changed-output");',
                "runner preflight output option",
            ),
            (
                "const certification_runner_preflight = capture_runner_preflight.addOutputFileArg(",
                "const certification_runner_preflight = capture_source_snapshot.addOutputFileArg(",
                "generated runner preflight output",
            ),
            (
                '"aarch64-runner-preflight.json",',
                '"unbound-runner-preflight.json",',
                "runner preflight output name",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(self.replace_contract_once(old, new, label), label)

        command_injected = self.replace_contract_once(
            '                "--provenance",\n            });',
            '                "--provenance",\n'
            "                aarch64_provenance.?,\n"
            "            });",
            "extra runner preflight command argument",
        )
        self.assert_rejected(
            command_injected,
            "extra runner preflight command argument",
        )

        output_call = (
            "const certification_runner_preflight = "
            "capture_runner_preflight.addOutputFileArg("
        )
        injected = self.replace_contract_once(
            output_call,
            'capture_runner_preflight.addArg("--extra");\n            ' + output_call,
            "extra runner preflight argument",
        )
        self.assert_rejected(injected, "extra runner preflight argument")

    def test_every_fresh_run_and_writer_is_side_effecting(self) -> None:
        variables = (
            "capture_source_snapshot",
            "capture_runner_preflight",
            "run_native_aarch64_host",
            "run_aarch64_header_checker",
            "run_aarch64_manifest_tests",
            "run_aarch64_module_tests",
            "run_aarch64_hash_c",
            "run_aarch64_hash_zig",
            "run_aarch64_hash_compare",
            "capture_evidence",
        )
        for variable in variables:
            old = f"{variable}.has_side_effects = true;"
            new = f"{variable}.has_side_effects = false;"
            self.assert_rejected(self.replace_contract_once(old, new, old), old)
            nested = f"if (false) {{\n                {old}\n            }}"
            self.assert_rejected(
                self.replace_contract_once(old, nested, f"nested {old}"),
                f"nested {old}",
            )

    def test_fresh_trace_capture_and_comparator_inputs_are_pinned(self) -> None:
        mutations = (
            (
                "const native_aarch64_host_output = run_native_aarch64_host.captureStdOut(.",
                "const native_aarch64_host_output = run_aarch64_header_checker.captureStdOut(.",
                "fresh native-host output",
            ),
            (
                '.basename = "aarch64-cert-native-host.txt",',
                '.basename = "not-the-native-host-trace.txt",',
                "native-host output basename",
            ),
            (
                "const aarch64_manifest_tests_log = run_aarch64_manifest_tests.captureStdErr(.",
                "const aarch64_manifest_tests_log = run_aarch64_module_tests.captureStdErr(.",
                "fresh manifest test log",
            ),
            (
                '.basename = "aarch64-cert-manifest-tests.log",',
                '.basename = "not-the-manifest-test-log.txt",',
                "manifest test-log basename",
            ),
            (
                "const aarch64_module_tests_log = run_aarch64_module_tests.captureStdErr(.",
                "const aarch64_module_tests_log = run_aarch64_manifest_tests.captureStdErr(.",
                "fresh module test log",
            ),
            (
                '.basename = "aarch64-cert-module-tests.log",',
                '.basename = "not-the-module-test-log.txt",',
                "module test-log basename",
            ),
            (
                "const aarch64_hash_c_output = run_aarch64_hash_c.captureStdOut(.",
                "const aarch64_hash_c_output = run_hash_default_c.captureStdOut(.",
                "fresh C output",
            ),
            (
                "const aarch64_hash_zig_output = run_aarch64_hash_zig.captureStdOut(.",
                "const aarch64_hash_zig_output = run_hash_default_zig.captureStdOut(.",
                "fresh Zig output",
            ),
            (
                "run_aarch64_hash_compare.addFileArg(aarch64_hash_c_output);",
                "run_aarch64_hash_compare.addFileArg(hash_default_c_output);",
                "comparator C input",
            ),
            (
                "run_aarch64_hash_compare.addFileArg(aarch64_hash_zig_output);",
                "run_aarch64_hash_compare.addFileArg(hash_default_zig_output);",
                "comparator Zig input",
            ),
        )
        for old, new, label in mutations:
            self.assert_rejected(self.replace_contract_once(old, new, label), label)

        old_order = (
            "run_aarch64_hash_compare.addFileArg(aarch64_hash_c_output);\n"
            "            run_aarch64_hash_compare.addFileArg(aarch64_hash_zig_output);"
        )
        new_order = (
            "run_aarch64_hash_compare.addFileArg(aarch64_hash_zig_output);\n"
            "            run_aarch64_hash_compare.addFileArg(aarch64_hash_c_output);"
        )
        self.assert_rejected(
            self.replace_contract_once(old_order, new_order, "comparator input order"),
            "comparator input order",
        )

    def test_exact_dependency_dag_rejects_each_deleted_or_changed_edge(self) -> None:
        edges = (
            ("module_tests", "capture_source_snapshot"),
            ("ordinary_manifest_tests", "capture_source_snapshot"),
            ("hash_default_c_oracle", "capture_source_snapshot"),
            ("hash_default_zig_oracle", "capture_source_snapshot"),
            ("compare_oracles", "capture_source_snapshot"),
            ("native_aarch64_host_checker", "capture_source_snapshot"),
            ("header_checker", "capture_source_snapshot"),
            ("module_tests", "capture_runner_preflight"),
            ("ordinary_manifest_tests", "capture_runner_preflight"),
            ("hash_default_c_oracle", "capture_runner_preflight"),
            ("hash_default_zig_oracle", "capture_runner_preflight"),
            ("compare_oracles", "capture_runner_preflight"),
            ("native_aarch64_host_checker", "capture_runner_preflight"),
            ("header_checker", "capture_runner_preflight"),
            ("run_aarch64_header_checker", "run_native_aarch64_host"),
            ("run_aarch64_manifest_tests", "run_aarch64_header_checker"),
            ("run_aarch64_module_tests", "run_aarch64_header_checker"),
            ("run_aarch64_hash_c", "run_aarch64_header_checker"),
            ("run_aarch64_hash_zig", "run_aarch64_header_checker"),
            ("capture_evidence", "run_native_aarch64_host"),
            ("capture_evidence", "run_aarch64_header_checker"),
            ("capture_evidence", "run_aarch64_manifest_tests"),
            ("capture_evidence", "run_aarch64_module_tests"),
            ("capture_evidence", "run_aarch64_hash_compare"),
            ("capture_evidence", "aarch64_evidence_contract_tests"),
            ("capture_evidence", "aarch64_hash_build_contract_tests"),
            ("capture_evidence", "capture_source_snapshot"),
            ("capture_evidence", "capture_runner_preflight"),
        )
        for owner, dependency in edges:
            line = f"{owner}.step.dependOn(&{dependency}.step);"
            self.assert_rejected(
                self.replace_contract_once(line, f"// removed edge: {line}", line),
                line,
            )
            nested = f"if (false) {{\n                {line}\n            }}"
            self.assert_rejected(
                self.replace_contract_once(line, nested, f"conditional edge: {line}"),
                f"conditional edge: {line}",
            )

        top_line = "aarch64_hash_certify_step.dependOn(&capture_evidence.step);"
        self.assert_rejected(
            self.replace_contract_once(top_line, f"// removed edge: {top_line}", top_line),
            top_line,
        )
        nested_top = f"if (false) {{\n                {top_line}\n            }}"
        self.assert_rejected(
            self.replace_contract_once(
                top_line,
                nested_top,
                "conditional final writer dependency",
            ),
            "conditional final writer dependency",
        )
        extra = f"{top_line}\n            aarch64_hash_certify_step.dependOn(&run_aarch64_hash_compare.step);"
        self.assert_rejected(
            self.replace_contract_once(top_line, extra, "exclusive top-level dependency"),
            "exclusive top-level dependency",
        )

    def test_both_failure_branches_are_required_and_exact(self) -> None:
        missing_branch = """        } else {
            const missing_evidence_inputs = b.addFail(
                "aarch64-hash-certify requires -Daarch64-evidence-out, -Daarch64-provenance, and -Daarch64-runner-record",
            );
            aarch64_hash_certify_step.dependOn(&missing_evidence_inputs.step);
        }"""
        non_native_branch = """    } else {
        const non_native_aarch64 = b.addFail(
            "aarch64-hash-certify requires Debug with a native target query on an AArch64 build host; cross-target, emulated, translated, or non-Debug execution is not certification",
        );
        aarch64_hash_certify_step.dependOn(&non_native_aarch64.step);
    }"""
        self.assert_rejected(
            self.replace_contract_once(
                missing_branch,
                "        }",
                "missing-input failure branch",
            ),
            "missing-input failure branch",
        )
        self.assert_rejected(
            self.replace_contract_once(
                non_native_branch,
                "    }",
                "non-native failure branch",
            ),
            "non-native failure branch",
        )

        for old, new, label in (
            (
                "aarch64_hash_certify_step.dependOn(&missing_evidence_inputs.step);",
                "aarch64_hash_certify_step.dependOn(&capture_evidence.step);",
                "missing-input failure dependency",
            ),
            (
                "aarch64_hash_certify_step.dependOn(&non_native_aarch64.step);",
                "aarch64_hash_certify_step.dependOn(&run_tests.step);",
                "non-native failure dependency",
            ),
            (
                "requires -Daarch64-evidence-out, -Daarch64-provenance, and -Daarch64-runner-record",
                "accepts missing evidence inputs",
                "missing-input failure message",
            ),
            (
                "requires Debug with a native target query on an AArch64 build host",
                "permits a cross-target build",
                "non-native failure message",
            ),
        ):
            self.assert_rejected(self.replace_contract_once(old, new, label), label)

        for dependency in ("missing_evidence_inputs", "non_native_aarch64"):
            line = f"aarch64_hash_certify_step.dependOn(&{dependency}.step);"
            nested = f"if (false) {{\n            {line}\n        }}"
            self.assert_rejected(
                self.replace_contract_once(
                    line,
                    nested,
                    f"conditional {dependency} guard dependency",
                ),
                f"conditional {dependency} guard dependency",
            )

    def test_certification_dependencies_are_globally_exclusive(self) -> None:
        injected = self.source.replace(
            checker.END_MARKER,
            checker.END_MARKER
            + "\n    aarch64_hash_certify_step.dependOn(&run_tests.step);",
            1,
        )
        self.assert_rejected(injected, "dependency outside contract marker")

    def test_required_capture_cli_options_cannot_change(self) -> None:
        options = (
            "--header",
            "--source-snapshot",
            "--runner-preflight",
            "--module-tests-log",
            "--ordinary-manifest-tests-log",
            "--c-trace",
            "--zig-trace",
            "--native-host-trace",
            "--zig-exe",
            "--optimize",
            "--target-triple",
            "--target-arch",
            "--target-os",
            "--target-abi",
            "--target-endian",
            "--target-cpu-model",
            "--c-oracle-exe",
            "--zig-oracle-exe",
            "--comparator-exe",
            "--module-tests-exe",
            "--ordinary-manifest-tests-exe",
            "--native-host-guard-exe",
            "--header-checker-exe",
        )
        for option in options:
            self.assert_rejected(
                self.replace_contract_once(f'"{option}"', f'"--changed-{option[2:]}"', option),
                option,
            )

        capture_repo_root = 'capture_evidence.addFileArg(b.path("."));'
        self.assert_rejected(
            self.replace_contract_once(
                capture_repo_root,
                'capture_evidence.addFileArg(b.path(".."));',
                "capture --repo-root",
            ),
            "capture --repo-root",
        )
        capture_output = (
            'capture_evidence.addArg("--output");\n'
            '            capture_evidence.addArg(aarch64_evidence_out.?);'
        )
        self.assert_rejected(
            self.replace_contract_once(
                capture_output,
                'capture_evidence.addArg("--changed-output");\n'
                '            capture_evidence.addArg(aarch64_evidence_out.?);',
                "capture --output",
            ),
            "capture --output",
        )

        runner_preflight_binding = (
            "capture_evidence.addFileArg(certification_runner_preflight);"
        )
        injected = self.replace_contract_once(
            runner_preflight_binding,
            runner_preflight_binding
            + '\n            capture_evidence.addArg("--provenance");\n'
            + "            capture_evidence.addFileArg(.{ .cwd_relative = aarch64_provenance.? });",
            "direct final-capture provenance",
        )
        self.assert_rejected(injected, "direct final-capture provenance")

        capture_header = '        capture_evidence.addArg("--header");'
        command_injected = self.replace_contract_once(
            capture_header,
            '        capture_evidence.addArg("--header");\n'
            '        capture_evidence.addArg("--provenance");',
            "direct final-capture command provenance",
        )
        self.assert_rejected(
            command_injected,
            "direct final-capture command provenance",
        )

        runner_preflight_pair = (
            'capture_evidence.addArg("--runner-preflight");\n'
            "            capture_evidence.addFileArg(certification_runner_preflight);"
        )
        nested_pair = (
            "if (false) {\n"
            f"                {runner_preflight_pair}\n"
            "            }"
        )
        self.assert_rejected(
            self.replace_contract_once(
                runner_preflight_pair,
                nested_pair,
                "conditional final-capture runner preflight",
            ),
            "conditional final-capture runner preflight",
        )

        final_binding = "capture_evidence.addFileArg(header_checker.getEmittedBin());"
        duplicate_output = (
            final_binding
            + '\n            capture_evidence.addArgs(&.{ "--output", "evidence/injected.json" });'
        )
        self.assert_rejected(
            self.replace_contract_once(
                final_binding,
                duplicate_output,
                "appended duplicate output override",
            ),
            "appended duplicate output override",
        )

        duplicate_preflight = (
            final_binding
            + '\n            capture_evidence.addArg("--runner-preflight");\n'
            + '            capture_evidence.addFileArg(b.path("evidence/alternate-runner-preflight.json"));'
        )
        self.assert_rejected(
            self.replace_contract_once(
                final_binding,
                duplicate_preflight,
                "appended duplicate runner preflight override",
            ),
            "appended duplicate runner preflight override",
        )

    def test_required_capture_cli_values_cannot_be_rebound(self) -> None:
        bindings = (
            ("aarch64_evidence_out.?", "aarch64_provenance.?", "evidence output"),
            ("b.graph.zig_exe", '"zig"', "Zig executable"),
            ("@tagName(optimize)", '"Debug"', "optimization mode"),
            (
                "target.result.zigTriple(b.allocator)",
                'b.dupe("aarch64-linux-gnu")',
                "target triple",
            ),
            ("@tagName(target.result.cpu.arch)", '"aarch64"', "target arch"),
            ("@tagName(target.result.os.tag)", '"linux"', "target OS"),
            ("@tagName(target.result.abi)", '"gnu"', "target ABI"),
            ("@tagName(target.result.cpu.arch.endian())", '"little"', "target endian"),
            ("target.result.cpu.model.name", '"generic"', "target CPU model"),
            (
                "hash_default_c_oracle.getEmittedBin()",
                "hash_default_zig_oracle.getEmittedBin()",
                "C executable",
            ),
            (
                "hash_default_zig_oracle.getEmittedBin()",
                "hash_default_c_oracle.getEmittedBin()",
                "Zig executable",
            ),
            ("compare_oracles.getEmittedBin()", "header_checker.getEmittedBin()", "comparator executable"),
            ("module_tests.getEmittedBin()", "ordinary_manifest_tests.getEmittedBin()", "module tests executable"),
            (
                "ordinary_manifest_tests.getEmittedBin()",
                "module_tests.getEmittedBin()",
                "manifest tests executable",
            ),
            (
                "native_aarch64_host_checker.getEmittedBin()",
                "header_checker.getEmittedBin()",
                "native host guard executable",
            ),
            ("header_checker.getEmittedBin()", "compare_oracles.getEmittedBin()", "header checker executable"),
        )
        for old, new, label in bindings:
            self.assert_rejected(self.replace_contract_once(old, new, label), label)

        header_binding = 'capture_evidence.addFileArg(b.path("tests/oracle/clay.h"));'
        changed_header_binding = (
            'capture_evidence.addFileArg(b.path("tests/oracle/hash_default_fixture.c"));'
        )
        self.assert_rejected(
            self.replace_contract_once(
                header_binding,
                changed_header_binding,
                "pinned header",
            ),
            "pinned header",
        )

        native_trace_binding = (
            "capture_evidence.addFileArg(native_aarch64_host_output);"
        )
        self.assert_rejected(
            self.replace_contract_once(
                native_trace_binding,
                "capture_evidence.addFileArg(aarch64_hash_c_output);",
                "native host trace",
            ),
            "native host trace",
        )

        source_snapshot_binding = (
            "capture_evidence.addFileArg(certification_source_snapshot);"
        )
        self.assert_rejected(
            self.replace_contract_once(
                source_snapshot_binding,
                "capture_evidence.addFileArg(aarch64_hash_c_output);",
                "source snapshot",
            ),
            "source snapshot",
        )

        runner_preflight_binding = (
            "capture_evidence.addFileArg(certification_runner_preflight);"
        )
        self.assert_rejected(
            self.replace_contract_once(
                runner_preflight_binding,
                "capture_evidence.addFileArg(certification_source_snapshot);",
                "runner preflight",
            ),
            "runner preflight",
        )

        for binding, replacement, label in (
            (
                "capture_evidence.addFileArg(aarch64_module_tests_log);",
                "capture_evidence.addFileArg(aarch64_manifest_tests_log);",
                "module test log",
            ),
            (
                "capture_evidence.addFileArg(aarch64_manifest_tests_log);",
                "capture_evidence.addFileArg(aarch64_module_tests_log);",
                "manifest test log",
            ),
        ):
            self.assert_rejected(
                self.replace_contract_once(binding, replacement, label),
                label,
            )


if __name__ == "__main__":
    unittest.main()
