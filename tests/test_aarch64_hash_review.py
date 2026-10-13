#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import copy
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

import aarch64_hash_evidence as raw_evidence  # noqa: E402
import aarch64_hash_review as review  # noqa: E402


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


class Aarch64HashReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fsync_patch = mock.patch.object(raw_evidence.os, "fsync")
        self.fsync_patch.start()
        self.scratch_dir = tempfile.TemporaryDirectory(
            prefix=".zlay-review-test-", dir=REPO_ROOT
        )
        self.work = Path(self.scratch_dir.name)
        self.runner_record = self.work / "runner-record.txt"
        self.runner_record.write_text(
            "runner=lab-arm64-01\nmodel=Example physical ARMv8 board\n",
            encoding="utf-8",
        )
        self.c_trace = self.work / "c.txt"
        self.zig_trace = self.work / "zig.txt"
        self.native_host_trace = self.work / "native-host.txt"
        self.c_trace.write_text(AARCH64_TRACE, encoding="utf-8")
        self.zig_trace.write_text(AARCH64_TRACE, encoding="utf-8")
        self.native_host_trace.write_text(
            "native-host sysname=Linux release=6.12.0-test "
            "machine=aarch64 word_bits=64\n",
            encoding="utf-8",
        )
        self.source_snapshot = self.work / "source-snapshot.json"
        source_snapshot = raw_evidence.create_source_snapshot(
            REPO_ROOT,
            hashlib.sha256((REPO_ROOT / "build.zig").read_bytes()).hexdigest(),
        )
        raw_evidence.write_atomic_replacing(self.source_snapshot, source_snapshot)
        self.provenance = self.work / "provenance.json"
        self.provenance.write_text(
            json.dumps(
                {
                    "schema": raw_evidence.PROVENANCE_SCHEMA,
                    "runner_id": "lab-arm64-01",
                    "hardware_model": "Example physical ARMv8 board",
                    "recorded_by": "test operator",
                    "operator_claim": "physical-non-emulated",
                    "attachment": {
                        "uri": "urn:zlay:test:runner-record",
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
        raw_evidence.write_atomic_replacing(
            self.runner_preflight,
            raw_evidence.create_runner_preflight(
                self.provenance, self.runner_record
            ),
        )
        self.module_tests_log = self.work / "module-tests.log"
        self.module_tests_log.write_text(MODULE_TEST_LOG, encoding="utf-8")
        self.manifest_tests_log = self.work / "manifest-tests.log"
        self.manifest_tests_log.write_text(MANIFEST_TEST_LOG, encoding="utf-8")
        self.executables: dict[str, Path] = {}
        for index, key in enumerate(raw_evidence.EXECUTABLE_KEYS):
            path = self.work / f"{key}.bin"
            path.write_bytes(f"synthetic executable {index}\n".encode())
            self.executables[key] = path

        envelope = raw_evidence.create_envelope(
            repo_root=REPO_ROOT,
            header=REPO_ROOT / "tests/oracle/clay.h",
            c_trace=self.c_trace,
            zig_trace=self.zig_trace,
            native_host_trace=self.native_host_trace,
            source_snapshot_path=self.source_snapshot,
            runner_preflight_path=self.runner_preflight,
            test_log_paths={
                "module_tests": self.module_tests_log,
                "ordinary_manifest_tests": self.manifest_tests_log,
            },
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
            runner_facts=raw_evidence.RunnerFacts(
                system="Linux",
                release="6.12.0-test",
                version="#1 test kernel",
                machine="aarch64",
                userspace_bits=64,
            ),
            generated_at_utc="2020-07-14T12:00:00Z",
        )
        self.raw_path = self.work / "raw.json"
        raw_evidence.write_atomic_new(self.raw_path, envelope)
        self.raw_original = self.raw_path.read_bytes()
        raw_digest = hashlib.sha256(self.raw_original).hexdigest()
        self.log = self.work / "certification.log"
        self.log.write_text(
            "native-host sysname=Linux release=6.12.0-test "
            "machine=aarch64 word_bits=64\n"
            f"{raw_evidence.runner_provenance_marker(envelope)}\n"
            f"evidence-captured sha256={raw_digest} provenance_review=pending "
            "backlog_closed=false\n"
            "evidence-path path=/durable/raw.json\n",
            encoding="utf-8",
        )
        self.statement = self.work / "review-statement.json"
        self.statement.write_text(
            json.dumps(
                {
                    "schema": review.STATEMENT_SCHEMA,
                    "raw_evidence_uri": "urn:zlay:test:raw-evidence",
                    "certification_log_uri": "urn:zlay:test:certification-log",
                    "reviewer": "independent test reviewer",
                    "reviewed_at_utc": "2020-07-14T13:00:00Z",
                    "notes": "Synthetic contract test; not execution evidence.",
                    "attestations": {key: True for key in review.ATTESTATION_KEYS},
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.fsync_patch.stop()
        self.scratch_dir.cleanup()

    def create_receipt(self) -> dict:
        return review.create_receipt(
            repo_root=REPO_ROOT,
            evidence_path=self.raw_path,
            runner_record_path=self.runner_record,
            certification_log_path=self.log,
            statement_path=self.statement,
        )

    @staticmethod
    def resign(receipt: dict) -> None:
        receipt["payload_sha256"] = hashlib.sha256(
            review._canonical_json(review._receipt_payload(receipt))
        ).hexdigest()

    def write_receipt(self, receipt: dict | None = None) -> Path:
        path = self.work / "receipt.json"
        raw_evidence.write_atomic_new(path, receipt or self.create_receipt())
        return path

    def validate_path(self, receipt_path: Path) -> dict:
        return review.load_and_validate_receipt(
            receipt_path=receipt_path,
            repo_root=REPO_ROOT,
            evidence_path=self.raw_path,
            runner_record_path=self.runner_record,
            certification_log_path=self.log,
        )

    def test_receipt_binds_current_sources_files_and_non_closing_boundary(self) -> None:
        receipt = self.create_receipt()
        receipt_path = self.write_receipt(receipt)
        validated = self.validate_path(receipt_path)
        self.assertEqual(review.RECEIPT_SCHEMA, validated["schema"])
        self.assertEqual("accepted", validated["human_review"]["status"])
        self.assertEqual(review.PROOF_BOUNDARY, validated["proof_boundary"])
        self.assertFalse(validated["proof_boundary"]["backlog_closed"])
        self.assertFalse(
            validated["proof_boundary"]["physical_hardware_verified_by_machine"]
        )
        self.assertEqual(self.raw_original, self.raw_path.read_bytes())
        expected_files, expected_digest = review.review_contract(REPO_ROOT)
        self.assertEqual(expected_files, validated["review_contract"]["files"])
        self.assertEqual(expected_digest, validated["review_contract"]["inputs_sha256"])
        self.assertEqual(
            raw_evidence.runner_provenance_marker(
                raw_evidence.load_and_validate(self.raw_path, REPO_ROOT)
            ),
            validated["certification_log"]["runner_preflight_marker"],
        )

    def test_runner_record_validation_opens_and_hashes_the_actual_file(self) -> None:
        binding = review.validate_runner_record(
            repo_root=REPO_ROOT,
            evidence_path=self.raw_path,
            runner_record_path=self.runner_record,
        )
        self.assertEqual(hashlib.sha256(self.runner_record.read_bytes()).hexdigest(), binding["sha256"])
        self.runner_record.write_bytes(self.runner_record.read_bytes() + b"changed\n")
        with self.assertRaisesRegex(review.ReviewError, "runner record digest"):
            review.validate_runner_record(
                repo_root=REPO_ROOT,
                evidence_path=self.raw_path,
                runner_record_path=self.runner_record,
            )

    def test_receipt_rejects_raw_runner_and_log_mutation_or_swap(self) -> None:
        receipt_path = self.write_receipt()
        cases = (
            (self.raw_path, self.raw_original + b" \n", "raw_evidence binding"),
            (
                self.runner_record,
                self.runner_record.read_bytes() + b"mutation\n",
                "runner record digest",
            ),
            (self.log, self.log.read_bytes() + b"mutation\n", "certification_log binding"),
        )
        originals = {path: path.read_bytes() for path, _, _ in cases}
        for path, mutation, message in cases:
            with self.subTest(path=path.name):
                path.write_bytes(mutation)
                with self.assertRaisesRegex(review.ReviewError, message):
                    self.validate_path(receipt_path)
                path.write_bytes(originals[path])

        wrong_log = self.log.read_text(encoding="utf-8").replace(
            hashlib.sha256(self.raw_original).hexdigest(), "0" * 64
        )
        self.log.write_text(wrong_log, encoding="utf-8")
        with self.assertRaisesRegex(review.ReviewError, "capture marker"):
            self.validate_path(receipt_path)

    def test_creation_requires_exact_log_marker_and_all_human_attestations(self) -> None:
        self.log.write_text("successful certification without binding\n", encoding="utf-8")
        with self.assertRaisesRegex(review.ReviewError, "capture marker"):
            self.create_receipt()

        raw_digest = hashlib.sha256(self.raw_original).hexdigest()
        envelope = raw_evidence.load_and_validate(self.raw_path, REPO_ROOT)
        deceptive_log = (
            f"ERROR expected {review._capture_marker(raw_digest)} but absent\n"
            "not-a-marker:"
            + raw_evidence.runner_provenance_marker(envelope)
            + ":suffix\n"
            "not-a-line:"
            + envelope["execution"]["runner"]["native_guard_trace"].rstrip("\n")
            + ":failure\n"
        )
        self.log.write_text(deceptive_log, encoding="utf-8")
        with self.assertRaisesRegex(review.ReviewError, "capture marker line"):
            self.create_receipt()

        self.log.write_text(
            f"evidence-captured sha256={raw_digest} provenance_review=pending "
            "backlog_closed=false\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(review.ReviewError, "native host guard marker"):
            self.create_receipt()
        self.log.write_text(
            "native-host sysname=Linux release=6.12.0-test "
            "machine=aarch64 word_bits=64\n"
            f"evidence-captured sha256={raw_digest} provenance_review=pending "
            "backlog_closed=false\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(review.ReviewError, "runner preflight marker"):
            self.create_receipt()
        self.log.write_text(
            "native-host sysname=Linux release=6.12.0-test "
            "machine=aarch64 word_bits=64\n"
            f"{raw_evidence.runner_provenance_marker(envelope)}\n"
            f"evidence-captured sha256={raw_digest} provenance_review=pending "
            "backlog_closed=false\n",
            encoding="utf-8",
        )
        statement = json.loads(self.statement.read_text(encoding="utf-8"))
        statement["attestations"][review.ATTESTATION_KEYS[0]] = False
        self.statement.write_text(json.dumps(statement), encoding="utf-8")
        with self.assertRaisesRegex(review.ReviewError, "every human attestation"):
            self.create_receipt()

    def test_statement_rejects_invalid_uri_and_pre_execution_review_time(self) -> None:
        statement = json.loads(self.statement.read_text(encoding="utf-8"))
        statement["raw_evidence_uri"] = ":bad"
        self.statement.write_text(json.dumps(statement), encoding="utf-8")
        with self.assertRaisesRegex(review.ReviewError, "absolute URI"):
            self.create_receipt()

        statement["raw_evidence_uri"] = "urn:zlay:test:raw-evidence"
        statement["reviewed_at_utc"] = "2020-07-14T11:59:59Z"
        self.statement.write_text(json.dumps(statement), encoding="utf-8")
        with self.assertRaisesRegex(review.ReviewError, "precedes raw evidence"):
            self.create_receipt()

        statement["reviewed_at_utc"] = "2999-01-01T00:00:00Z"
        self.statement.write_text(json.dumps(statement), encoding="utf-8")
        with self.assertRaisesRegex(review.ReviewError, "too far in the future"):
            self.create_receipt()

    def test_receipt_mutation_matrix_fails_even_after_payload_resign(self) -> None:
        original = self.create_receipt()
        mutations = {
            "status": lambda item: item["human_review"].__setitem__("status", "pending"),
            "claim": lambda item: item["human_review"]["reviewed_claims"].__setitem__(
                "runner_id", "other-runner"
            ),
            "attestation": lambda item: item["human_review"]["attestations"].__setitem__(
                review.ATTESTATION_KEYS[0], False
            ),
            "machine-check": lambda item: item["machine_checks"].__setitem__(
                "raw_contract", "claimed"
            ),
            "boundary": lambda item: item["proof_boundary"].__setitem__(
                "backlog_closed", True
            ),
            "source": lambda item: item["review_contract"].__setitem__(
                "inputs_sha256", "0" * 64
            ),
            "runner-preflight": lambda item: item["raw_evidence"].__setitem__(
                "runner_preflight_sha256", "0" * 64
            ),
        }
        envelope, raw_bytes = review._validated_raw(self.raw_path, REPO_ROOT)
        runner_bytes = self.runner_record.read_bytes()
        log_bytes = self.log.read_bytes()
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                changed = copy.deepcopy(original)
                mutate(changed)
                self.resign(changed)
                with self.assertRaises(review.ReviewError):
                    review.validate_receipt(
                        changed,
                        repo_root=REPO_ROOT,
                        envelope=envelope,
                        raw_bytes=raw_bytes,
                        runner_record_bytes=runner_bytes,
                        log_bytes=log_bytes,
                    )

    def test_duplicate_keys_overwrite_refusal_and_conservative_cli_output(self) -> None:
        duplicate = self.work / "duplicate-statement.json"
        duplicate.write_text(
            '{"schema":"first","schema":"second"}\n', encoding="utf-8"
        )
        with self.assertRaisesRegex(review.ReviewError, "duplicate JSON key"):
            review.load_statement(duplicate)
        with mock.patch.object(review, "MAX_ATTACHMENT_BYTES", 16):
            with self.assertRaisesRegex(review.ReviewError, "review limit"):
                review.load_statement(self.statement)
        with mock.patch.object(review, "MAX_ATTACHMENT_BYTES", 1):
            with self.assertRaisesRegex(review.ReviewError, "review limit"):
                review.review_contract(REPO_ROOT)
        with mock.patch.object(review, "MAX_REVIEW_CONTRACT_TOTAL_BYTES", 1):
            with self.assertRaisesRegex(review.ReviewError, "aggregate"):
                review.review_contract(REPO_ROOT)

        receipt_path = self.work / "receipt.json"
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(
                0,
                review.main(
                    [
                        "review-create",
                        "--repo-root",
                        str(REPO_ROOT),
                        "--evidence",
                        str(self.raw_path),
                        "--runner-record",
                        str(self.runner_record),
                        "--certification-log",
                        str(self.log),
                        "--statement",
                        str(self.statement),
                        "--output",
                        str(receipt_path),
                    ]
                ),
            )
            self.assertEqual(
                0,
                review.main(
                    [
                        "review-validate",
                        "--repo-root",
                        str(REPO_ROOT),
                        "--evidence",
                        str(self.raw_path),
                        "--runner-record",
                        str(self.runner_record),
                        "--certification-log",
                        str(self.log),
                        "--receipt",
                        str(receipt_path),
                    ]
                ),
            )
        self.assertIn("human_provenance_review=accepted", output.getvalue())
        self.assertIn("physical_machine_proof=false", output.getvalue())
        self.assertIn("backlog_closed=false", output.getvalue())
        duplicate_receipt = self.work / "duplicate-receipt.json"
        receipt_text = receipt_path.read_text(encoding="utf-8").rstrip()
        duplicate_receipt.write_text(
            receipt_text[:-1]
            + f',"schema":"{review.RECEIPT_SCHEMA}"}}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(review.ReviewError, "duplicate JSON key"):
            self.validate_path(duplicate_receipt)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(
                1,
                review.main(
                    [
                        "review-create",
                        "--repo-root",
                        str(REPO_ROOT),
                        "--evidence",
                        str(self.raw_path),
                        "--runner-record",
                        str(self.runner_record),
                        "--certification-log",
                        str(self.log),
                        "--statement",
                        str(self.statement),
                        "--output",
                        str(receipt_path),
                    ]
                ),
            )
            cache_output = self.work / ".zig-cache" / "receipt.json"
            self.assertEqual(
                1,
                review.main(
                    [
                        "review-create",
                        "--repo-root",
                        str(REPO_ROOT),
                        "--evidence",
                        str(self.raw_path),
                        "--runner-record",
                        str(self.runner_record),
                        "--certification-log",
                        str(self.log),
                        "--statement",
                        str(self.statement),
                        "--output",
                        str(cache_output),
                    ]
                ),
            )
            self.assertFalse(cache_output.exists())
            temporary_output = Path(tempfile.gettempdir()) / (
                f"{self.work.name}-review-receipt.json"
            )
            temporary_output.unlink(missing_ok=True)
            self.assertEqual(
                1,
                review.main(
                    [
                        "review-create",
                        "--repo-root",
                        str(REPO_ROOT),
                        "--evidence",
                        str(self.raw_path),
                        "--runner-record",
                        str(self.runner_record),
                        "--certification-log",
                        str(self.log),
                        "--statement",
                        str(self.statement),
                        "--output",
                        str(temporary_output),
                    ]
                ),
            )
            self.assertFalse(temporary_output.exists())

    def test_schema_constants_match_the_executable_contract(self) -> None:
        schema = raw_evidence._load_json(
            (REPO_ROOT / "evidence/aarch64-hash-review.schema.json").read_bytes()
        )
        properties = schema["properties"]
        self.assertEqual(review.RECEIPT_SCHEMA, properties["schema"]["const"])
        self.assertEqual(review.BACKLOG_ID, properties["backlog_id"]["const"])
        self.assertEqual(review.MACHINE_CHECKS, properties["machine_checks"]["const"])
        self.assertEqual(review.PROOF_BOUNDARY, properties["proof_boundary"]["const"])
        self.assertEqual(
            raw_evidence.ABSOLUTE_URI_SCHEMA_PATTERN,
            schema["$defs"]["uri"]["pattern"],
        )
        self.assertEqual(
            review.CAPTURE_MARKER_SCHEMA_PATTERN,
            properties["certification_log"]["properties"]["capture_marker"]["pattern"],
        )
        self.assertEqual(
            review.RUNNER_PREFLIGHT_MARKER_SCHEMA_PATTERN,
            properties["certification_log"]["properties"]["runner_preflight_marker"][
                "pattern"
            ],
        )
        self.assertEqual(
            review.MAX_ATTACHMENT_BYTES,
            properties["runner_record"]["properties"]["byte_count"]["maximum"],
        )
        self.assertEqual(
            review.MAX_ATTACHMENT_BYTES,
            properties["raw_evidence"]["properties"]["byte_count"]["maximum"],
        )
        self.assertEqual(
            review.MAX_ATTACHMENT_BYTES,
            properties["certification_log"]["properties"]["byte_count"]["maximum"],
        )
        human_properties = properties["human_review"]["properties"]
        self.assertEqual(64, human_properties["reviewed_at_utc"]["maxLength"])
        for key in ("runner_id", "hardware_model", "recorded_by"):
            self.assertEqual(
                256,
                human_properties["reviewed_claims"]["properties"][key]["maxLength"],
            )
        self.assertEqual(4096, schema["$defs"]["file"]["properties"]["path"]["maxLength"])
        self.assertEqual(
            review.MAX_ATTACHMENT_BYTES,
            schema["$defs"]["file"]["properties"]["byte_count"]["maximum"],
        )
        self.assertEqual(
            {key: True for key in review.ATTESTATION_KEYS},
            properties["human_review"]["properties"]["attestations"]["const"],
        )
        files, _ = review.review_contract(REPO_ROOT)
        self.assertEqual(list(review.REVIEW_SOURCE_INPUTS), [item["path"] for item in files])


if __name__ == "__main__":
    unittest.main()
