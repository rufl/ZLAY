from __future__ import annotations

import hashlib
import importlib.util
import os
import struct
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
REPORTER_PATH = REPO_ROOT / "scripts/aarch64_hash_qemu_report.py"
CHECKER_PATH = REPO_ROOT / "scripts/check_aarch64_hash_qemu_contract.py"
sys.path.insert(0, str(REPO_ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("aarch64_hash_qemu_report", REPORTER_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover - import setup invariant
    raise RuntimeError(f"cannot load {REPORTER_PATH}")
reporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reporter)
CHECKER_SPEC = importlib.util.spec_from_file_location(
    "check_aarch64_hash_qemu_contract", CHECKER_PATH
)
if CHECKER_SPEC is None or CHECKER_SPEC.loader is None:  # pragma: no cover
    raise RuntimeError(f"cannot load {CHECKER_PATH}")
checker = importlib.util.module_from_spec(CHECKER_SPEC)
CHECKER_SPEC.loader.exec_module(checker)

EXPECTED_TRACE = b"".join(
    (
        b"data 0 0\n",
        b"data 1 0\n",
        b"data 4 129691398728704\n",
        b"data 7 1303921783522487300\n",
        b"data 8 1303921783522488836\n",
        b"data 9 18174341066911135968\n",
        b"data 15 149934752496362724\n",
        b"data 16 18308448450054203108\n",
        b"data 17 4486647907394536192\n",
        b"data 24 6212722439340698421\n",
        b"data 31 1103406062466163403\n",
        b"data 32 1103406062466150603\n",
        b"data 64 3753674313972326855\n",
        b"binary 4104036501107535511\n",
        b"text empty 1\n",
        b"text clay 4144509781\n",
        b"text styled 3043263680\n",
        b"text binary 3562463298\n",
    )
)


def make_aarch64_elf(
    *,
    program_type: int = 1,
    machine: int = 183,
    elf_type: int = 2,
    program_count: int = 1,
    file_size: int = 1,
    memory_size: int = 1,
    flags: int = 5,
) -> bytes:
    image = bytearray(64 + 56 * program_count + max(file_size, 1))
    image[:16] = b"\x7fELF\x02\x01\x01" + b"\0" * 9
    struct.pack_into("<H", image, 16, elf_type)
    struct.pack_into("<H", image, 18, machine)
    struct.pack_into("<I", image, 20, 1)
    struct.pack_into("<Q", image, 24, 0x10000)
    struct.pack_into("<Q", image, 32, 64)
    struct.pack_into("<H", image, 52, 64)
    struct.pack_into("<H", image, 54, 56)
    struct.pack_into("<H", image, 56, program_count)
    if program_count > 0:
        struct.pack_into("<II", image, 64, program_type, flags)
        struct.pack_into("<Q", image, 72, 64 + 56 * program_count)
        struct.pack_into("<Q", image, 80, 0x10000)
        struct.pack_into("<Q", image, 96, file_size)
        struct.pack_into("<Q", image, 104, memory_size)
    return bytes(image)


class Aarch64HashQemuReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch_dir = tempfile.TemporaryDirectory(prefix="zlay-qemu-report-")
        self.root = Path(self.scratch_dir.name)
        self.qemu = self.root / "qemu-aarch64"
        self.zig = self.root / "zig"
        self.c_trace = self.root / "c.trace"
        self.zig_trace = self.root / "zig.trace"
        self.module_tests_log = self.root / "module-tests.log"
        self.manifest_tests_log = self.root / "manifest-tests.log"
        self.c_executable = self.root / "c.elf"
        self.zig_executable = self.root / "zig.elf"
        self.module_tests_executable = self.root / "module-tests.elf"
        self.manifest_tests_executable = self.root / "manifest-tests.elf"
        self.qemu.write_text(
            "#!/bin/sh\nprintf 'qemu-aarch64 version 11.0.2\\n'\n",
            encoding="utf-8",
        )
        self.zig.write_text("#!/bin/sh\nprintf '0.17.0\\n'\n", encoding="utf-8")
        os.chmod(self.qemu, 0o755)
        os.chmod(self.zig, 0o755)
        self.c_trace.write_bytes(EXPECTED_TRACE)
        self.zig_trace.write_bytes(EXPECTED_TRACE)
        self.module_tests_log.write_bytes(
            b"1/2 module pass...OK\n"
            b"2/2 hash.test.textWithConfig matches pinned x86_64 default C oracle vectors...SKIP\n"
            b"1 passed; 1 skipped; 0 failed.\n"
        )
        self.manifest_tests_log.write_bytes(
            b"1/1 manifest pass...OK\nAll 1 tests passed.\n"
        )
        self.c_executable.write_bytes(make_aarch64_elf())
        self.zig_executable.write_bytes(make_aarch64_elf())
        self.module_tests_executable.write_bytes(make_aarch64_elf())
        self.manifest_tests_executable.write_bytes(make_aarch64_elf())

    def tearDown(self) -> None:
        self.scratch_dir.cleanup()

    def create_report(self) -> str:
        source_sha256 = reporter._source_contract(REPO_ROOT)[1]
        return reporter.create_report(
            REPO_ROOT,
            self.qemu,
            self.zig,
            self.c_trace,
            self.zig_trace,
            self.module_tests_log,
            self.manifest_tests_log,
            self.c_executable,
            self.zig_executable,
            self.module_tests_executable,
            self.manifest_tests_executable,
            source_sha256,
        )

    def test_reviewed_trace_constant_is_exact(self) -> None:
        self.assertEqual(426, len(EXPECTED_TRACE))
        self.assertEqual(18, len(EXPECTED_TRACE.splitlines()))
        self.assertEqual(
            reporter.EXPECTED_TRACE_SHA256,
            hashlib.sha256(EXPECTED_TRACE).hexdigest(),
        )

    def test_runtime_and_embedded_source_contract_file_order_is_identical(self) -> None:
        reporter_paths = tuple(
            path.relative_to(REPO_ROOT).as_posix()
            for path in reporter._source_paths(REPO_ROOT)
        )
        self.assertEqual(checker.SOURCE_CONTRACT_FILES, reporter_paths)

    def test_source_contract_discovers_nested_zig_sources(self) -> None:
        nested = self.root / "src" / "nested" / "future.zig"
        nested.parent.mkdir(parents=True)
        nested.write_text("test {}\n", encoding="utf-8")
        self.assertIn(nested, reporter._source_paths(self.root))

    def test_pre_gate_source_contract_binds_compiled_build_runner(self) -> None:
        self.assertEqual(
            reporter._source_contract(REPO_ROOT)[1],
            reporter.create_source_contract(REPO_ROOT, REPO_ROOT / "build.zig"),
        )

    def test_stale_compiled_build_runner_is_rejected(self) -> None:
        stale_build = self.root / "embedded-build.zig"
        stale_build.write_text("const stale = true;\n", encoding="utf-8")
        with self.assertRaisesRegex(reporter.ReportError, "compiled build runner"):
            reporter.create_source_contract(REPO_ROOT, stale_build)

    def test_pre_gate_source_contract_file_is_canonical(self) -> None:
        contract_file = self.root / "source.sha256"
        digest = "a" * 64
        contract_file.write_text(digest + "\n", encoding="ascii")
        self.assertEqual(digest, reporter._read_expected_source_file(contract_file))
        for invalid in (digest, digest.upper() + "\n", digest + "\n\n"):
            with self.subTest(invalid=repr(invalid)):
                contract_file.write_text(invalid, encoding="ascii")
                with self.assertRaises(reporter.ReportError):
                    reporter._read_expected_source_file(contract_file)

    def test_report_binds_tools_sources_artifacts_and_non_closing_state(self) -> None:
        report = self.create_report()
        required = (
            "schema=zlay.aarch64-hash-qemu.v1",
            "identity=hash-default execution=emulated",
            f"executor={self.qemu}",
            "qemu_version=11.0.2",
            f"zig_executable={self.zig}",
            "zig_version=0.17.0",
            "target=aarch64-linux-musl arch=aarch64 os=linux abi=musl",
            "endian=little target_cpu=baseline qemu_cpu=max",
            "optimize=Debug linkage=static",
            f"upstream_commit={reporter.UPSTREAM_COMMIT}",
            f"clay_header_sha256={reporter.EXPECTED_HEADER_SHA256}",
            "lines=18 bytes=426",
            "module_tests_total=2 module_tests_passed=1 module_tests_skipped=1",
            "manifest_tests_total=1 manifest_tests_passed=1 manifest_tests_skipped=0",
            f"trace_sha256={reporter.EXPECTED_TRACE_SHA256}",
            "certification=false physical_machine_proof=false backlog_closed=false",
        )
        for fragment in required:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, report)
        for field in (
            "qemu_sha256",
            "zig_sha256",
            "source_sha256",
            "c_executable_sha256",
            "zig_executable_sha256",
            "module_tests_executable_sha256",
            "manifest_tests_executable_sha256",
            "module_tests_log_sha256",
            "manifest_tests_log_sha256",
        ):
            with self.subTest(field=field):
                self.assertRegex(report, rf"(?:^| ){field}=[0-9a-f]{{64}}(?: |$)")

    def test_trace_mutation_is_rejected(self) -> None:
        self.zig_trace.write_bytes(EXPECTED_TRACE[:-2] + b"9\n")
        with self.assertRaisesRegex(reporter.ReportError, "Zig trace SHA-256"):
            self.create_report()

    def test_failed_or_inconsistent_test_log_is_rejected(self) -> None:
        invalid_logs = (
            b"1/1 module fail...FAIL\n0 passed; 0 skipped; 1 failed.\n",
            b"1/2 module pass...OK\nAll 2 tests passed.\n",
            b"1/1 module pass...OK\n0 passed; 1 skipped; 0 failed.\n",
        )
        for invalid in invalid_logs:
            with self.subTest(invalid=invalid):
                self.module_tests_log.write_bytes(invalid)
                with self.assertRaises(reporter.ReportError):
                    self.create_report()

    def test_module_skip_policy_is_exact_and_requires_a_pass(self) -> None:
        invalid_logs = (
            b"1/2 module pass...OK\n"
            b"2/2 arbitrary skipped test...SKIP\n"
            b"1 passed; 1 skipped; 0 failed.\n",
            b"1/1 module pass...OK\nAll 1 tests passed.\n",
            b"1/1 hash.test.textWithConfig matches pinned x86_64 default C oracle vectors...SKIP\n"
            b"0 passed; 1 skipped; 0 failed.\n",
        )
        for invalid in invalid_logs:
            with self.subTest(invalid=invalid):
                self.module_tests_log.write_bytes(invalid)
                with self.assertRaises(reporter.ReportError):
                    self.create_report()

    def test_test_log_rejects_duplicate_names_and_invalid_utf8(self) -> None:
        invalid_logs = (
            b"1/3 duplicate...OK\n"
            b"2/3 duplicate...OK\n"
            b"3/3 hash.test.textWithConfig matches pinned x86_64 default C oracle vectors...SKIP\n"
            b"2 passed; 1 skipped; 0 failed.\n",
            b"1/2 module \xff...OK\n"
            b"2/2 hash.test.textWithConfig matches pinned x86_64 default C oracle vectors...SKIP\n"
            b"1 passed; 1 skipped; 0 failed.\n",
        )
        for invalid in invalid_logs:
            with self.subTest(invalid=invalid):
                self.module_tests_log.write_bytes(invalid)
                with self.assertRaises(reporter.ReportError):
                    self.create_report()

    def test_strict_test_log_summary_binds_content_and_metadata(self) -> None:
        data = self.module_tests_log.read_bytes()
        summary = reporter._validate_zig_test_log(
            data,
            "module-tests log",
            reporter.MODULE_ALLOWED_SKIPS,
        )
        self.assertEqual((2, 1, 1), (summary.total, summary.passed, summary.skipped))
        self.assertEqual(reporter.MODULE_ALLOWED_SKIPS, summary.skipped_names)
        self.assertEqual(len(data), summary.byte_count)
        self.assertEqual(hashlib.sha256(data).hexdigest(), summary.sha256)
        self.assertEqual(data.decode("utf-8"), summary.text)

    def test_non_aarch64_artifact_is_rejected(self) -> None:
        self.c_executable.write_bytes(make_aarch64_elf(machine=62))
        with self.assertRaisesRegex(reporter.ReportError, "not an AArch64 ELF"):
            self.create_report()

    def test_interpreter_bearing_artifact_is_rejected(self) -> None:
        self.zig_executable.write_bytes(make_aarch64_elf(program_type=3))
        with self.assertRaisesRegex(reporter.ReportError, "PT_INTERP present"):
            self.create_report()

    def test_non_executable_or_loadless_elf_is_rejected(self) -> None:
        invalid_images = (
            make_aarch64_elf(elf_type=1),
            make_aarch64_elf(program_count=0),
            make_aarch64_elf(file_size=0, memory_size=0),
            make_aarch64_elf(file_size=0, memory_size=1),
            make_aarch64_elf(flags=4),
        )
        for image in invalid_images:
            with self.subTest(image=image[:64]):
                with self.assertRaises(reporter.ReportError):
                    reporter._validate_static_aarch64_elf(image, "test executable")

    def test_oversized_input_is_rejected_before_read(self) -> None:
        oversized = self.root / "oversized"
        with oversized.open("wb") as stream:
            stream.truncate(reporter.MAX_INPUT_BYTES + 1)
        with self.assertRaisesRegex(reporter.ReportError, "exceeds"):
            reporter._read_bounded(oversized, "test input")

    def test_bounded_reader_never_requests_an_unbounded_file_read(self) -> None:
        source = mock.MagicMock()
        source.__enter__.return_value.read.return_value = b"x" * 5
        with mock.patch.object(Path, "open", return_value=source):
            with self.assertRaisesRegex(reporter.ReportError, "exceeds"):
                reporter._read_bounded(self.root / "synthetic", "test input", 4)
        source.__enter__.return_value.read.assert_called_once_with(5)

    def test_pathological_decimal_test_counts_are_rejected_cleanly(self) -> None:
        enormous = b"9" * 5000
        invalid_logs = (
            enormous + b"/1 module pass...OK\nAll 1 tests passed.\n",
            b"1/1 module pass...OK\nAll " + enormous + b" tests passed.\n",
        )
        for invalid in invalid_logs:
            with self.subTest(kind=invalid[:16]):
                with self.assertRaises(reporter.ReportError):
                    reporter._validate_zig_test_log(
                        invalid,
                        "module-tests log",
                        reporter.MODULE_ALLOWED_SKIPS,
                    )

    def test_unrecognized_tool_version_is_rejected(self) -> None:
        self.qemu.write_text("#!/bin/sh\nprintf 'not qemu\\n'\n", encoding="utf-8")
        with self.assertRaisesRegex(reporter.ReportError, "unexpected QEMU version"):
            self.create_report()

    def test_packager_suffix_in_qemu_version_is_bounded_to_version_token(self) -> None:
        self.qemu.write_text(
            "#!/bin/sh\nprintf 'qemu-aarch64 version 11.0.2 (distribution build)\\n'\n",
            encoding="utf-8",
        )
        self.assertIn("qemu_version=11.0.2", self.create_report())

    def test_stale_embedded_source_contract_is_rejected(self) -> None:
        with self.assertRaisesRegex(reporter.ReportError, "embedded build contract"):
            reporter.create_report(
                REPO_ROOT,
                self.qemu,
                self.zig,
                self.c_trace,
                self.zig_trace,
                self.module_tests_log,
                self.manifest_tests_log,
                self.c_executable,
                self.zig_executable,
                self.module_tests_executable,
                self.manifest_tests_executable,
                "0" * 64,
            )


if __name__ == "__main__":
    unittest.main()
