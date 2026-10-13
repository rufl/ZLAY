#!/usr/bin/env python3

from __future__ import annotations

import copy
import contextlib
import hashlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import aarch64_hash_evidence as evidence  # noqa: E402


AARCH64_TRACE = """data 0 0
data 1 0
data 4 129691398728704
data 7 1303921783522487300
data 8 1303921783522488836
data 9 18174341066911135968
data 15 149934752496362724
data 16 18308448450054203108
data 17 4486647907394536192
data 24 6212722439340698421
data 31 1103406062466163403
data 32 1103406062466150603
data 64 3753674313972326855
binary 4104036501107535511
text empty 1
text clay 4144509781
text styled 3043263680
text binary 3562463298
"""

MODULE_TEST_LOG = """1/2 module test passes...OK
2/2 hash.test.textWithConfig matches pinned x86_64 default C oracle vectors...SKIP
1 passed; 1 skipped; 0 failed.
"""

MANIFEST_TEST_LOG = """1/1 ordinary manifest test passes...OK
All 1 tests passed.
"""


class Aarch64HashEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch_dir = tempfile.TemporaryDirectory(prefix=".zlay-evidence-test-", dir=REPO_ROOT)
        self.work = Path(self.scratch_dir.name)
        self.c_trace = self.work / "c.txt"
        self.zig_trace = self.work / "zig.txt"
        self.c_trace.write_text(AARCH64_TRACE, encoding="utf-8")
        self.zig_trace.write_text(AARCH64_TRACE, encoding="utf-8")
        self.native_host_trace = self.work / "native-host.txt"
        self.native_host_trace.write_text(
            "native-host sysname=Linux release=6.12.0-test machine=aarch64 word_bits=64\n",
            encoding="utf-8",
        )
        self.source_snapshot = self.work / "source-snapshot.json"
        snapshot = evidence.create_source_snapshot(
            REPO_ROOT,
            hashlib.sha256((REPO_ROOT / "build.zig").read_bytes()).hexdigest(),
        )
        evidence.write_atomic_replacing(self.source_snapshot, snapshot)
        self.runner_record = self.work / "runner-record.txt"
        self.runner_record.write_text(
            "runner=lab-arm64-01\nmodel=Example physical ARMv8 board\n",
            encoding="utf-8",
        )
        self.provenance = self.work / "provenance.json"
        self.provenance.write_text(
            json.dumps(
                {
                    "schema": evidence.PROVENANCE_SCHEMA,
                    "runner_id": "lab-arm64-01",
                    "hardware_model": "Example physical ARMv8 board",
                    "recorded_by": "test operator",
                    "operator_claim": "physical-non-emulated",
                    "attachment": {
                        "uri": "urn:zlay:test-provenance",
                        "sha256": hashlib.sha256(
                            self.runner_record.read_bytes()
                        ).hexdigest(),
                    },
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        self.runner_preflight = self.work / "runner-preflight.json"
        evidence.write_atomic_replacing(
            self.runner_preflight,
            evidence.create_runner_preflight(self.provenance, self.runner_record),
        )
        self.module_tests_log = self.work / "module-tests.log"
        self.module_tests_log.write_text(MODULE_TEST_LOG, encoding="utf-8")
        self.manifest_tests_log = self.work / "manifest-tests.log"
        self.manifest_tests_log.write_text(MANIFEST_TEST_LOG, encoding="utf-8")
        self.test_logs = {
            "module_tests": self.module_tests_log,
            "ordinary_manifest_tests": self.manifest_tests_log,
        }
        self.executables: dict[str, Path] = {}
        for index, key in enumerate(evidence.EXECUTABLE_KEYS):
            path = self.work / f"{key}.bin"
            path.write_bytes(f"synthetic executable {index}\n".encode())
            self.executables[key] = path

    def tearDown(self) -> None:
        self.scratch_dir.cleanup()

    def make_envelope(self) -> dict:
        return evidence.create_envelope(
            repo_root=REPO_ROOT,
            header=REPO_ROOT / "tests/oracle/clay.h",
            c_trace=self.c_trace,
            zig_trace=self.zig_trace,
            native_host_trace=self.native_host_trace,
            source_snapshot_path=self.source_snapshot,
            runner_preflight_path=self.runner_preflight,
            test_log_paths=self.test_logs,
            executable_paths=self.executables,
            zig_version="0.17.0",
            optimize="Debug",
            target={
                "selection": "native",
                "triple": "aarch64-linux-gnu",
                "arch": "aarch64",
                "os": "linux",
                "abi": "gnu",
                "endian": "little",
                "cpu_model": "synthetic-test-cpu",
            },
            runner_facts=evidence.RunnerFacts(
                system="Linux",
                release="6.12.0-test",
                version="#1 test kernel",
                machine="aarch64",
                userspace_bits=64,
            ),
            generated_at_utc="2020-07-14T12:00:00Z",
        )

    @staticmethod
    def resign(envelope: dict) -> None:
        envelope["execution_sha256"] = hashlib.sha256(
            evidence._canonical_json(envelope["execution"])
        ).hexdigest()

    def test_valid_record_is_source_bound_and_non_closing(self) -> None:
        envelope = self.make_envelope()
        validated = evidence.validate_envelope(envelope, REPO_ROOT)
        self.assertEqual(evidence.SCHEMA, validated["schema"])
        self.assertEqual("pending", validated["review"]["status"])
        self.assertFalse(validated["proof_boundary"]["physical_hardware_machine_verified"])
        self.assertFalse(validated["proof_boundary"]["backlog_closed"])
        self.assertEqual(evidence.TRACE_SHA256, validated["execution"]["oracle"]["c_trace_sha256"])
        self.assertEqual(
            hashlib.sha256(self.runner_record.read_bytes()).hexdigest(),
            validated["runner_record"]["sha256"],
        )
        self.assertEqual(
            len(self.runner_record.read_bytes()),
            validated["runner_record"]["byte_count"],
        )
        module_run = validated["execution"]["test_runs"]["module_tests"]
        self.assertEqual(2, module_run["total"])
        self.assertEqual(1, module_run["passed"])
        self.assertEqual(1, module_run["skipped"])
        self.assertEqual(list(evidence.MODULE_TEST_ALLOWED_SKIPS), module_run["skipped_names"])
        self.assertEqual(
            hashlib.sha256(MODULE_TEST_LOG.encode()).hexdigest(),
            module_run["sha256"],
        )
        manifest_run = validated["execution"]["test_runs"]["ordinary_manifest_tests"]
        self.assertEqual(1, manifest_run["passed"])
        self.assertEqual(0, manifest_run["skipped"])
        self.assertEqual(MANIFEST_TEST_LOG, manifest_run["log"])
        self.assertIn(
            "physical_machine_proof=false backlog_closed=false",
            evidence.runner_provenance_marker(validated),
        )

    def test_runner_provenance_creation_preflight_and_immutable_capture_input(self) -> None:
        generated_provenance = self.work / "generated-provenance.json"
        output = io.StringIO()
        with mock.patch.object(evidence.os, "fsync"), contextlib.redirect_stdout(output):
            self.assertEqual(
                0,
                evidence.main(
                    [
                        "runner-provenance-create",
                        "--runner-record",
                        str(self.runner_record),
                        "--runner-record-uri",
                        "urn:zlay:test:generated-runner-record",
                        "--runner-id",
                        "lab-arm64-01",
                        "--hardware-model",
                        "Example physical ARMv8 board",
                        "--recorded-by",
                        "test operator",
                        "--claim-physical-non-emulated",
                        "--output",
                        str(generated_provenance),
                    ]
                ),
            )
        generated = evidence.load_provenance(generated_provenance)
        self.assertEqual(
            hashlib.sha256(self.runner_record.read_bytes()).hexdigest(),
            generated["attachment"]["sha256"],
        )
        self.assertIn("physical_machine_proof=false", output.getvalue())

        original_read_bounded = evidence._read_bounded
        runner_record_reads = 0

        def count_runner_record_reads(path: Path, label: str, maximum: int) -> bytes:
            nonlocal runner_record_reads
            if path.resolve() == self.runner_record.resolve():
                runner_record_reads += 1
            return original_read_bounded(path, label, maximum)

        with mock.patch.object(
            evidence, "_read_bounded", count_runner_record_reads
        ):
            preflight = evidence.create_runner_preflight(
                generated_provenance, self.runner_record
            )
        self.assertEqual(
            1, runner_record_reads, "preflight must bind one runner-record byte read"
        )
        validated = evidence.validate_runner_preflight(preflight)
        self.assertEqual(evidence.RUNNER_PREFLIGHT_SCHEMA, validated["schema"])
        self.assertEqual(
            len(self.runner_record.read_bytes()), validated["runner_record"]["byte_count"]
        )

        cli_preflight = self.work / ".zig-cache" / "runner-preflight.json"
        cli_preflight.parent.mkdir()
        cli_preflight.write_text("stale\n", encoding="utf-8")
        preflight_output = io.StringIO()
        with contextlib.redirect_stdout(preflight_output):
            self.assertEqual(
                0,
                evidence.main(
                    [
                        "runner-validate",
                        "--provenance",
                        str(generated_provenance),
                        "--runner-record",
                        str(self.runner_record),
                    ]
                ),
            )
            self.assertEqual(
                0,
                evidence.main(
                    [
                        "runner-preflight",
                        "--provenance",
                        str(generated_provenance),
                        "--runner-record",
                        str(self.runner_record),
                        "--output",
                        str(cli_preflight),
                    ]
                ),
            )
        self.assertEqual(
            validated["preflight_sha256"],
            evidence.load_runner_preflight(cli_preflight)["preflight_sha256"],
        )
        self.assertIn("runner-provenance-valid", preflight_output.getvalue())

        frozen_preflight = self.work / "frozen-runner-preflight.json"
        evidence.write_atomic_replacing(frozen_preflight, preflight)
        original_record = self.runner_record.read_bytes()
        self.runner_record.write_bytes(original_record + b"mutated after preflight\n")
        with self.assertRaisesRegex(evidence.EvidenceError, "runner record digest"):
            evidence.create_runner_preflight(generated_provenance, self.runner_record)
        envelope = evidence.create_envelope(
            repo_root=REPO_ROOT,
            header=REPO_ROOT / "tests/oracle/clay.h",
            c_trace=self.c_trace,
            zig_trace=self.zig_trace,
            native_host_trace=self.native_host_trace,
            source_snapshot_path=self.source_snapshot,
            runner_preflight_path=frozen_preflight,
            test_log_paths=self.test_logs,
            executable_paths=self.executables,
            zig_version="0.17.0",
            optimize="Debug",
            target={
                "selection": "native",
                "triple": "aarch64-linux-gnu",
                "arch": "aarch64",
                "os": "linux",
                "abi": "gnu",
                "endian": "little",
                "cpu_model": "synthetic-test-cpu",
            },
            runner_facts=evidence.RunnerFacts(
                "Linux", "6.12.0-test", "#1 test kernel", "aarch64", 64
            ),
            generated_at_utc="2020-07-14T12:00:00Z",
        )
        self.assertEqual(
            hashlib.sha256(original_record).hexdigest(), envelope["runner_record"]["sha256"]
        )

        changed = copy.deepcopy(preflight)
        changed["runner_record"]["byte_count"] += 1
        with self.assertRaisesRegex(evidence.EvidenceError, "canonical payload"):
            evidence.validate_runner_preflight(changed)

    def test_capture_rejects_wrong_host_and_trace_mismatch(self) -> None:
        with self.assertRaisesRegex(evidence.EvidenceError, "AArch64 kernel machine"):
            evidence.create_envelope(
                repo_root=REPO_ROOT,
                header=REPO_ROOT / "tests/oracle/clay.h",
                c_trace=self.c_trace,
                zig_trace=self.zig_trace,
                native_host_trace=self.native_host_trace,
                source_snapshot_path=self.source_snapshot,
                runner_preflight_path=self.runner_preflight,
                test_log_paths=self.test_logs,
                executable_paths=self.executables,
                zig_version="0.17.0",
                optimize="Debug",
                target={
                    "selection": "native",
                    "triple": "x86_64-linux-gnu",
                    "arch": "x86_64",
                    "os": "linux",
                    "abi": "gnu",
                    "endian": "little",
                    "cpu_model": "test",
                },
                runner_facts=evidence.RunnerFacts("Linux", "test", "test", "x86_64", 64),
            )

        self.native_host_trace.write_text(
            "native-host sysname=Linux release=wrong machine=aarch64 word_bits=64\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "disagrees with the capture process"):
            self.make_envelope()
        self.native_host_trace.write_text(
            "native-host sysname=Linux release=6.12.0-test machine=aarch64 word_bits=64\n",
            encoding="utf-8",
        )
        self.zig_trace.write_text(AARCH64_TRACE.replace("text binary 3562463298", "text binary 0"), encoding="utf-8")
        with self.assertRaisesRegex(evidence.EvidenceError, "does not match the AArch64 contract"):
            self.make_envelope()

    def test_capture_rejects_unexpected_missing_and_all_skipped_test_logs(self) -> None:
        self.module_tests_log.write_text(
            MODULE_TEST_LOG.replace("module test passes...OK", "unexpected module skip...SKIP")
            .replace("1 passed; 1 skipped", "0 passed; 2 skipped"),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "no passing tests"):
            self.make_envelope()

        self.module_tests_log.write_text(
            MODULE_TEST_LOG.replace(
                "hash.test.textWithConfig matches pinned x86_64 default C oracle vectors",
                "unexpected skipped test",
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "skipped tests differ"):
            self.make_envelope()

        self.module_tests_log.write_text(
            MODULE_TEST_LOG.replace("...SKIP", "...OK").replace(
                "1 passed; 1 skipped; 0 failed.", "All 2 tests passed."
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "skipped tests differ"):
            self.make_envelope()

        self.module_tests_log.write_text(MODULE_TEST_LOG, encoding="utf-8")
        self.manifest_tests_log.write_text(
            MANIFEST_TEST_LOG.replace("...OK", "...SKIP").replace(
                "All 1 tests passed.", "0 passed; 1 skipped; 0 failed."
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "no passing tests"):
            self.make_envelope()

    def test_mutation_matrix_is_fail_closed_even_after_execution_resign(self) -> None:
        original = self.make_envelope()
        mutations = {
            "schema": lambda item: item.__setitem__("schema", "unknown"),
            "source": lambda item: item["execution"]["source"].__setitem__(
                "clay_header_sha256", "0" * 64
            ),
            "pre-gate-snapshot": lambda item: item["execution"]["source"].__setitem__(
                "pre_gate_snapshot_sha256", "0" * 64
            ),
            "future-timestamp": lambda item: item["execution"].__setitem__(
                "generated_at_utc", "2999-01-01T00:00:00Z"
            ),
            "target": lambda item: item["execution"]["target"].__setitem__("selection", "cross"),
            "runner": lambda item: item["execution"]["runner"].__setitem__("machine", "x86_64"),
            "native-guard": lambda item: item["execution"]["runner"].__setitem__(
                "native_guard_trace",
                "native-host sysname=Linux release=wrong machine=aarch64 word_bits=64\n",
            ),
            "gate": lambda item: item["execution"]["gates"].__setitem__(
                "native_zlay_tests", "failed"
            ),
            "executable": lambda item: item["execution"]["executables"].__setitem__(
                "c_oracle", "short"
            ),
            "zig-version": lambda item: item["execution"]["toolchain"].__setitem__(
                "zig_version", "0.18.0"
            ),
            "optimize": lambda item: item["execution"]["toolchain"].__setitem__(
                "optimize", "ReleaseSafe"
            ),
            "target-triple": lambda item: item["execution"]["target"].__setitem__(
                "triple", "aarch64-macos-none"
            ),
            "trace": lambda item: item["execution"]["oracle"].__setitem__(
                "c_trace", AARCH64_TRACE.replace("data 0 0", "data 0 1")
            ),
            "test-log": lambda item: item["execution"]["test_runs"][
                "module_tests"
            ].__setitem__("log", MODULE_TEST_LOG.replace("module test", "changed test")),
            "test-log-metadata": lambda item: item["execution"]["test_runs"][
                "module_tests"
            ].__setitem__("byte_count", 1),
            "provenance": lambda item: item["runner_provenance"].__setitem__(
                "operator_claim", "unknown"
            ),
            "runner-record": lambda item: item["runner_record"].__setitem__(
                "sha256", "0" * 64
            ),
            "runner-preflight": lambda item: item.__setitem__(
                "runner_preflight_sha256", "0" * 64
            ),
            "review": lambda item: item["review"].__setitem__("status", "accepted"),
            "boundary": lambda item: item["proof_boundary"].__setitem__(
                "backlog_closed", True
            ),
            "boundary-integer-zero": lambda item: item["proof_boundary"].__setitem__(
                "backlog_closed", 0
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                changed = copy.deepcopy(original)
                mutate(changed)
                self.resign(changed)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_envelope(changed, REPO_ROOT)

        invalid_uri = copy.deepcopy(original)
        invalid_uri["runner_provenance"]["attachment"]["uri"] = ":not-a-uri"
        invalid_uri["runner_provenance_sha256"] = hashlib.sha256(
            evidence._canonical_json(invalid_uri["runner_provenance"])
        ).hexdigest()
        with self.assertRaisesRegex(evidence.EvidenceError, "absolute URI"):
            evidence.validate_envelope(invalid_uri, REPO_ROOT)

    def test_atomic_write_import_and_overwrite_refusal(self) -> None:
        envelope = self.make_envelope()
        raw_path = self.work / "raw.json"
        imported_path = self.work / "review" / "imported.json"
        fsync_patch = mock.patch.object(evidence.os, "fsync")
        fsync = fsync_patch.start()
        self.addCleanup(fsync_patch.stop)
        digest = evidence.write_atomic_new(raw_path, envelope)
        self.assertGreaterEqual(fsync.call_count, 2, "file and parent directory must be fsynced")
        self.assertEqual(hashlib.sha256(raw_path.read_bytes()).hexdigest(), digest)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(
                0,
                evidence.main(
                    ["validate", "--repo-root", str(REPO_ROOT), "--evidence", str(raw_path)]
                ),
            )
            self.assertEqual(
                0,
                evidence.main(
                    [
                        "import",
                        "--repo-root",
                        str(REPO_ROOT),
                        "--evidence",
                        str(raw_path),
                        "--output",
                        str(imported_path),
                    ]
                ),
            )
        self.assertIn("provenance_review=pending backlog_closed=false", output.getvalue())
        loaded = evidence.load_and_validate(raw_path, REPO_ROOT)
        self.assertEqual(loaded, evidence.load_and_validate(imported_path, REPO_ROOT))
        compact_path = self.work / "compact.json"
        compact_path.write_bytes(evidence._canonical_json(envelope))
        preserved_path = self.work / "review" / "preserved.json"
        self.assertEqual(
            0,
            evidence.main(
                [
                    "import",
                    "--repo-root",
                    str(REPO_ROOT),
                    "--evidence",
                    str(compact_path),
                    "--output",
                    str(preserved_path),
                ]
            ),
        )
        self.assertEqual(compact_path.read_bytes(), preserved_path.read_bytes())

        moving_path = self.work / "moving-source.json"
        moving_bytes = evidence._canonical_json(envelope)
        moving_path.write_bytes(moving_bytes)
        moving_import = self.work / "review" / "moving-import.json"
        original_read_bounded = evidence._read_bounded
        source_reads = 0

        def changing_read_bounded(path: Path, label: str, maximum: int) -> bytes:
            nonlocal source_reads
            if path.resolve() == moving_path.resolve():
                source_reads += 1
                return moving_bytes if source_reads == 1 else moving_bytes + b" \n"
            return original_read_bounded(path, label, maximum)

        with mock.patch.object(evidence, "_read_bounded", changing_read_bounded):
            self.assertEqual(
                0,
                evidence.main(
                    [
                        "import",
                        "--repo-root",
                        str(REPO_ROOT),
                        "--evidence",
                        str(moving_path),
                        "--output",
                        str(moving_import),
                    ]
                ),
            )
        self.assertEqual(1, source_reads, "validated import bytes must be read exactly once")
        self.assertEqual(moving_bytes, moving_import.read_bytes())
        with self.assertRaisesRegex(evidence.EvidenceError, "refusing to overwrite"):
            evidence.write_atomic_new(raw_path, envelope)
        cache_path = self.work / ".zig-cache" / "evidence.json"
        with self.assertRaisesRegex(evidence.EvidenceError, "outside Zig cache"):
            evidence.write_atomic_new(cache_path, envelope)
        self.assertFalse(cache_path.exists())
        temporary_path = Path(tempfile.gettempdir()) / f"{self.work.name}-must-not-exist.json"
        with self.assertRaisesRegex(evidence.EvidenceError, "system temp"):
            evidence.write_atomic_new(temporary_path, envelope)
        self.assertFalse(temporary_path.exists())
        for temporary_root in (Path("/var/tmp"), Path("/dev/shm"), Path("/run/user")):
            blocked_path = temporary_root / f"{self.work.name}-must-not-exist.json"
            with self.assertRaisesRegex(evidence.EvidenceError, "system temp"):
                evidence.write_atomic_new(blocked_path, envelope)
            self.assertFalse(blocked_path.exists())

    def test_atomic_json_writer_enforces_the_exact_reload_byte_limit(self) -> None:
        payload = {"payload": "x" * 257}
        serialized = (
            json.dumps(
                payload,
                indent=2,
                sort_keys=True,
                ensure_ascii=False,
                allow_nan=False,
            ).encode("utf-8")
            + b"\n"
        )
        rejected = self.work / "oversized.json"
        with mock.patch.object(evidence, "MAX_JSON_BYTES", len(serialized) - 1):
            with self.assertRaisesRegex(evidence.EvidenceError, "reload limit"):
                evidence.write_atomic_new(rejected, payload)
        self.assertFalse(rejected.exists())

        accepted = self.work / "exact-limit.json"
        with mock.patch.object(evidence, "MAX_JSON_BYTES", len(serialized)), mock.patch.object(
            evidence.os, "fsync"
        ):
            evidence.write_atomic_new(accepted, payload)
        self.assertEqual(serialized, accepted.read_bytes())

    def test_duplicate_json_keys_are_rejected_at_every_input_boundary(self) -> None:
        duplicate_provenance = self.work / "duplicate-provenance.json"
        duplicate_provenance.write_text(
            '{"schema":"zlay.aarch64-runner-provenance.v1",'
            '"runner_id":"first","runner_id":"second"}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "duplicate JSON key"):
            evidence.load_provenance(duplicate_provenance)

        envelope = self.make_envelope()
        raw = json.dumps(envelope, sort_keys=True)
        duplicate_evidence = self.work / "duplicate-evidence.json"
        duplicate_evidence.write_text(
            raw[:-1] + ',"schema":"zlay.aarch64-hash-execution.v1"}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "duplicate JSON key"):
            evidence.load_and_validate(duplicate_evidence, REPO_ROOT)

        snapshot = self.source_snapshot.read_text(encoding="utf-8").rstrip()
        duplicate_snapshot = self.work / "duplicate-snapshot.json"
        duplicate_snapshot.write_text(
            snapshot[:-1]
            + f',"schema":"{evidence.SNAPSHOT_SCHEMA}"}}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "duplicate JSON key"):
            evidence.load_source_snapshot(duplicate_snapshot, REPO_ROOT)

        preflight = self.runner_preflight.read_text(encoding="utf-8").rstrip()
        duplicate_preflight = self.work / "duplicate-preflight.json"
        duplicate_preflight.write_text(
            preflight[:-1]
            + f',"schema":"{evidence.RUNNER_PREFLIGHT_SCHEMA}"}}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "duplicate JSON key"):
            evidence.load_runner_preflight(duplicate_preflight)

        with mock.patch.object(evidence, "MAX_JSON_BYTES", 16):
            with self.assertRaisesRegex(evidence.EvidenceError, "input limit"):
                evidence.load_provenance(self.provenance)

    def test_malformed_json_resource_and_unicode_inputs_fail_closed(self) -> None:
        oversized_integer = b'{"value":' + b"9" * 5000 + b"}"
        with self.assertRaisesRegex(evidence.EvidenceError, "integer exceeds"):
            evidence._load_json(oversized_integer)

        deeply_nested = b"[" * 100_000 + b"0" + b"]" * 100_000
        with self.assertRaisesRegex(evidence.EvidenceError, "nesting is too deep"):
            evidence._load_json(deeply_nested)

        with self.assertRaisesRegex(evidence.EvidenceError, "invalid Unicode surrogate"):
            evidence._canonical_json({"value": "\ud800"})

        overflowed_float = evidence._load_json(b'{"value":1e999}')
        with self.assertRaisesRegex(evidence.EvidenceError, "cannot canonicalize JSON"):
            evidence._canonical_json(overflowed_float)

    def test_pre_gate_snapshots_are_current_replaceable_and_loaded_once(self) -> None:
        loaded = evidence.load_source_snapshot(self.source_snapshot, REPO_ROOT)
        expected_files, expected_digest = evidence.certification_inputs(REPO_ROOT)
        self.assertEqual(evidence.SNAPSHOT_SCHEMA, loaded["schema"])
        self.assertEqual(expected_files, loaded["files"])
        self.assertEqual(expected_digest, loaded["certification_inputs_sha256"])
        self.assertEqual(
            hashlib.sha256(
                evidence._canonical_json(evidence._snapshot_payload(loaded))
            ).hexdigest(),
            loaded["snapshot_sha256"],
        )

        cache_snapshot = self.work / ".zig-cache" / "pre-gate.json"
        cache_snapshot.parent.mkdir()
        cache_snapshot.write_text("stale\n", encoding="utf-8")
        self.assertEqual(
            0,
            evidence.main(
                [
                    "snapshot",
                    "--repo-root",
                    str(REPO_ROOT),
                    "--expected-build-zig-sha256",
                    hashlib.sha256((REPO_ROOT / "build.zig").read_bytes()).hexdigest(),
                    "--output",
                    str(cache_snapshot),
                ]
            ),
        )
        self.assertEqual(
            expected_digest,
            evidence.load_source_snapshot(cache_snapshot, REPO_ROOT)[
                "certification_inputs_sha256"
            ],
        )

        original_read_bounded = evidence._read_bounded
        snapshot_reads = 0
        runner_preflight_reads = 0
        module_log_reads = 0
        manifest_log_reads = 0

        def counting_read_bounded(path: Path, label: str, maximum: int) -> bytes:
            nonlocal snapshot_reads, runner_preflight_reads, module_log_reads, manifest_log_reads
            if path.resolve() == self.source_snapshot.resolve():
                snapshot_reads += 1
            if path.resolve() == self.runner_preflight.resolve():
                runner_preflight_reads += 1
            if path.resolve() == self.module_tests_log.resolve():
                module_log_reads += 1
            if path.resolve() == self.manifest_tests_log.resolve():
                manifest_log_reads += 1
            return original_read_bounded(path, label, maximum)

        with mock.patch.object(evidence, "_read_bounded", counting_read_bounded):
            self.make_envelope()
        self.assertEqual(1, snapshot_reads, "capture must load the pre-gate snapshot once")
        self.assertEqual(
            1,
            runner_preflight_reads,
            "capture must load the immutable runner preflight once",
        )
        self.assertEqual(1, module_log_reads, "capture must bind one module-log byte read")
        self.assertEqual(1, manifest_log_reads, "capture must bind one manifest-log byte read")

    def test_snapshot_rejects_build_source_and_payload_mutation(self) -> None:
        with mock.patch.object(evidence, "MAX_SOURCE_INPUT_BYTES", 1):
            with self.assertRaisesRegex(evidence.EvidenceError, "input limit"):
                evidence.certification_inputs(REPO_ROOT)
        with mock.patch.object(evidence, "MAX_SOURCE_INPUT_TOTAL_BYTES", 1):
            with self.assertRaisesRegex(evidence.EvidenceError, "aggregate"):
                evidence.certification_inputs(REPO_ROOT)

        with mock.patch.object(
            evidence,
            "certification_inputs",
            wraps=evidence.certification_inputs,
        ) as inputs:
            with self.assertRaisesRegex(evidence.EvidenceError, "live build.zig SHA-256"):
                evidence.create_source_snapshot(REPO_ROOT, "0" * 64)
            inputs.assert_called_once_with(REPO_ROOT.resolve())

        valid = evidence.load_source_snapshot(self.source_snapshot, REPO_ROOT)
        changed_payload = copy.deepcopy(valid)
        changed_payload["files"][0]["sha256"] = "0" * 64
        changed_payload["snapshot_sha256"] = hashlib.sha256(
            evidence._canonical_json(evidence._snapshot_payload(changed_payload))
        ).hexdigest()
        changed_path = self.work / "changed-snapshot.json"
        changed_path.write_text(json.dumps(changed_payload), encoding="utf-8")
        with self.assertRaisesRegex(evidence.EvidenceError, "files differ"):
            evidence.load_source_snapshot(changed_path, REPO_ROOT)

        corrupted_digest = copy.deepcopy(valid)
        corrupted_digest["snapshot_sha256"] = "0" * 64
        corrupted_path = self.work / "corrupted-snapshot.json"
        corrupted_path.write_text(json.dumps(corrupted_digest), encoding="utf-8")
        with self.assertRaisesRegex(evidence.EvidenceError, "canonical payload"):
            evidence.load_source_snapshot(corrupted_path, REPO_ROOT)

        current_files, current_digest = evidence.certification_inputs(REPO_ROOT)
        changed_current_files = copy.deepcopy(current_files)
        changed_current_files[0]["byte_count"] += 1
        with mock.patch.object(
            evidence,
            "certification_inputs",
            return_value=(changed_current_files, current_digest),
        ):
            with self.assertRaisesRegex(evidence.EvidenceError, "files differ"):
                evidence.load_source_snapshot(self.source_snapshot, REPO_ROOT)

    def test_source_input_discovery_recursively_binds_nested_zig_sources(self) -> None:
        synthetic = self.work / "synthetic-repository"
        for relative in evidence.SOURCE_INPUTS:
            path = synthetic / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"fixture for {relative}\n", encoding="utf-8")
        (synthetic / "src").mkdir(exist_ok=True)
        (synthetic / "src/root.zig").write_text("const root = true;\n", encoding="utf-8")
        nested = synthetic / "src/platform/aarch64/nested.zig"
        nested.parent.mkdir(parents=True)
        nested.write_text("const nested = true;\n", encoding="utf-8")
        (nested.parent / "ignored.txt").write_text("not a Zig source\n", encoding="utf-8")

        discovered = {
            path.as_posix() for path in evidence._source_input_paths(synthetic)
        }
        self.assertIn("src/root.zig", discovered)
        self.assertIn("src/platform/aarch64/nested.zig", discovered)
        self.assertNotIn("src/platform/aarch64/ignored.txt", discovered)

    def test_contract_constants_match_checked_in_sources(self) -> None:
        raw = AARCH64_TRACE.encode()
        self.assertEqual(evidence.TRACE_LINE_COUNT, raw.count(b"\n"))
        self.assertEqual(evidence.TRACE_BYTE_COUNT, len(raw))
        self.assertEqual(evidence.TRACE_SHA256, hashlib.sha256(raw).hexdigest())
        self.assertEqual(
            evidence.PINNED_HEADER_SHA256,
            hashlib.sha256((REPO_ROOT / "tests/oracle/clay.h").read_bytes()).hexdigest(),
        )
        manifest = (REPO_ROOT / "tests/oracle/ordinary_manifest.zig").read_text(encoding="utf-8")
        for expected in (
            evidence.TRACE_SHA256,
            f".line_count = {evidence.TRACE_LINE_COUNT}",
            f".byte_count = {evidence.TRACE_BYTE_COUNT}",
        ):
            self.assertIn(expected, manifest)

        schema = evidence._load_json(
            (REPO_ROOT / "evidence/aarch64-hash-evidence.schema.json").read_bytes()
        )
        properties = schema["properties"]
        execution_properties = properties["execution"]["properties"]
        source_properties = execution_properties["source"]["properties"]
        oracle_properties = execution_properties["oracle"]["properties"]
        test_runs_properties = execution_properties["test_runs"]["properties"]
        self.assertEqual(evidence.SCHEMA, properties["schema"]["const"])
        self.assertEqual(
            evidence.PINNED_CLAY_COMMIT, source_properties["pinned_clay_commit"]["const"]
        )
        self.assertEqual(
            evidence.PINNED_HEADER_SHA256, source_properties["clay_header_sha256"]["const"]
        )
        self.assertEqual(
            {"$ref": "#/$defs/sha256"}, source_properties["pre_gate_snapshot_sha256"]
        )
        self.assertEqual(evidence.TRACE_LINE_COUNT, oracle_properties["line_count"]["const"])
        self.assertEqual(evidence.TRACE_BYTE_COUNT, oracle_properties["byte_count"]["const"])
        self.assertEqual(evidence.TRACE_SHA256, oracle_properties["contract_sha256"]["const"])
        self.assertEqual(set(evidence.GATE_KEYS), set(execution_properties["gates"]["required"]))
        self.assertEqual(
            set(evidence.EXECUTABLE_KEYS), set(execution_properties["executables"]["required"])
        )
        self.assertEqual(
            set(evidence.TEST_RUN_KEYS), set(execution_properties["test_runs"]["required"])
        )
        for key in evidence.TEST_RUN_KEYS:
            self.assertEqual({"$ref": "#/$defs/test_run"}, test_runs_properties[key])
        self.assertEqual(
            evidence.MAX_TEST_LOG_BYTES,
            schema["$defs"]["test_run"]["properties"]["byte_count"]["maximum"],
        )
        self.assertEqual(
            evidence.MAX_TEST_LOG_BYTES,
            schema["$defs"]["test_run"]["properties"]["log"]["maxLength"],
        )
        self.assertLessEqual(evidence.MAX_TEST_LOG_BYTES, evidence.MAX_JSON_BYTES)
        self.assertEqual(evidence.PROOF_BOUNDARY, properties["proof_boundary"]["const"])
        self.assertEqual("pending", properties["review"]["const"]["status"])
        self.assertEqual(
            evidence.PROVENANCE_SCHEMA,
            schema["$defs"]["provenance"]["properties"]["schema"]["const"],
        )
        self.assertEqual(
            evidence.ABSOLUTE_URI_SCHEMA_PATTERN,
            schema["$defs"]["provenance"]["properties"]["attachment"]["properties"][
                "uri"
            ]["pattern"],
        )
        for key in ("runner_id", "hardware_model", "recorded_by"):
            self.assertEqual(
                256,
                schema["$defs"]["provenance"]["properties"][key]["maxLength"],
            )
        self.assertEqual(
            "Debug", execution_properties["toolchain"]["properties"]["optimize"]["const"]
        )
        self.assertEqual(
            64, execution_properties["generated_at_utc"]["maxLength"]
        )
        source_file_properties = source_properties["files"]["items"]["properties"]
        self.assertEqual(4096, source_file_properties["path"]["maxLength"])
        self.assertEqual(
            evidence.MAX_SOURCE_INPUT_BYTES,
            source_file_properties["byte_count"]["maximum"],
        )
        self.assertEqual(
            128,
            execution_properties["toolchain"]["properties"]["zig_version"][
                "maxLength"
            ],
        )
        runner_properties = execution_properties["runner"]["properties"]
        for key in ("system", "release", "version"):
            self.assertEqual(2048, runner_properties[key]["maxLength"])
        self.assertEqual(4096, runner_properties["native_guard_trace"]["maxLength"])
        target_properties = execution_properties["target"]["properties"]
        for key in ("triple", "os", "abi", "cpu_model"):
            self.assertEqual(256, target_properties[key]["maxLength"])
        self.assertEqual(
            evidence.TRACE_BYTE_COUNT, oracle_properties["c_trace"]["maxLength"]
        )
        self.assertEqual(
            evidence.TRACE_BYTE_COUNT, oracle_properties["zig_trace"]["maxLength"]
        )
        self.assertEqual(
            {"$ref": "#/$defs/runner_record"}, properties["runner_record"]
        )
        self.assertEqual(
            {"$ref": "#/$defs/sha256"}, properties["runner_preflight_sha256"]
        )

        preflight_schema = evidence._load_json(
            (
                REPO_ROOT
                / "evidence/aarch64-hash-runner-preflight.schema.json"
            ).read_bytes()
        )
        self.assertEqual(
            evidence.RUNNER_PREFLIGHT_SCHEMA,
            preflight_schema["properties"]["schema"]["const"],
        )
        self.assertEqual(
            evidence.MAX_RUNNER_RECORD_BYTES,
            preflight_schema["$defs"]["runner_record"]["properties"]["byte_count"][
                "maximum"
            ],
        )
        self.assertEqual(
            evidence.ABSOLUTE_URI_SCHEMA_PATTERN,
            preflight_schema["$defs"]["absolute_uri"]["pattern"],
        )
        for key in ("runner_id", "hardware_model", "recorded_by"):
            self.assertEqual(
                256,
                preflight_schema["$defs"]["provenance"]["properties"][key][
                    "maxLength"
                ],
            )


if __name__ == "__main__":
    unittest.main()
