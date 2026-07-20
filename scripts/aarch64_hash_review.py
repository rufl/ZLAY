#!/usr/bin/env python3
"""Validate ZL-202 runner records and create human-review receipts.

This workflow consumes a raw, still-pending AArch64 execution record. It can
verify file digests and record a human provenance decision, but it cannot prove
physical execution, authenticate the reviewer, or close the backlog row.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

import aarch64_hash_evidence as raw_evidence


REPO_ROOT = Path(__file__).resolve().parents[1]

RECEIPT_SCHEMA = "zlay.aarch64-hash-review-receipt.v1"
STATEMENT_SCHEMA = "zlay.aarch64-hash-review-statement.v1"
BACKLOG_ID = raw_evidence.BACKLOG_ID

REVIEW_SOURCE_INPUTS = (
    "evidence/aarch64-hash-review.schema.json",
    "scripts/aarch64_hash_review.py",
    "tests/test_aarch64_hash_review.py",
)

ATTESTATION_KEYS = (
    "runner_record_identifies_raw_runner",
    "hardware_model_matches_raw_claim",
    "certification_log_is_complete",
    "certification_log_matches_raw_execution",
    "physical_non_emulation_claim_reviewed",
)

MACHINE_CHECKS = {
    "raw_contract": "passed",
    "current_source_binding": "passed",
    "review_contract_binding": "passed",
    "raw_file_digest": "passed",
    "runner_record_digest": "passed",
    "certification_log_digest": "passed",
    "runner_preflight_marker": "passed",
    "capture_digest_marker": "passed",
    "native_host_marker": "passed",
}

PROOF_BOUNDARY = {
    "artifact_kind": "human-provenance-review-receipt",
    "machine_validation": "contract-digest-and-log-binding-only",
    "physical_hardware_verified_by_machine": False,
    "reviewer_identity_authenticated_by_machine": False,
    "human_provenance_review_status": "accepted",
    "automatic_backlog_closure": False,
    "backlog_closed": False,
}

MAX_ATTACHMENT_BYTES = 16 * 1024 * 1024
MAX_REVIEW_CONTRACT_TOTAL_BYTES = 64 * 1024 * 1024
HEX_256 = re.compile(r"[0-9a-f]{64}\Z")
CAPTURE_MARKER_SCHEMA_PATTERN = (
    r"^evidence-captured sha256=[0-9a-f]{64} "
    r"provenance_review=pending backlog_closed=false$"
)
RUNNER_PREFLIGHT_MARKER_SCHEMA_PATTERN = (
    r"^runner-provenance-valid preflight_sha256=[0-9a-f]{64} "
    r"provenance_sha256=[0-9a-f]{64} runner_record_sha256=[0-9a-f]{64} "
    r"runner_record_byte_count=[1-9][0-9]* physical_machine_proof=false "
    r"backlog_closed=false$"
)


class ReviewError(RuntimeError):
    pass


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _load_json(raw: bytes | str, label: str) -> Any:
    try:
        return raw_evidence._load_json(raw)
    except (UnicodeDecodeError, json.JSONDecodeError, raw_evidence.EvidenceError) as error:
        raise ReviewError(f"cannot load {label}: {error}") from error


def _load_json_file(path: Path, label: str) -> tuple[Any, bytes]:
    contents = _read_bounded(path, label)
    return _load_json(contents, label), contents


def _read_bounded(path: Path, label: str) -> bytes:
    try:
        with path.open("rb") as source:
            contents = source.read(MAX_ATTACHMENT_BYTES + 1)
    except OSError as error:
        raise ReviewError(f"cannot read {label} {path}: {error}") from error
    if not contents:
        raise ReviewError(f"{label} must not be empty")
    if len(contents) > MAX_ATTACHMENT_BYTES:
        raise ReviewError(
            f"{label} exceeds the {MAX_ATTACHMENT_BYTES}-byte review limit"
        )
    return contents


def _exact_object(value: Any, keys: Sequence[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ReviewError(f"{label} must be an object")
    expected = set(keys)
    actual = set(value)
    if actual != expected:
        raise ReviewError(
            f"{label} keys differ; missing={sorted(expected - actual)} "
            f"unknown={sorted(actual - expected)}"
        )
    return value


def _string(value: Any, label: str, maximum: int = 1024) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise ReviewError(
            f"{label} must be a non-empty string of at most {maximum} characters"
        )
    if "\x00" in value:
        raise ReviewError(f"{label} must not contain NUL")
    return value


def _sha256_value(value: Any, label: str) -> str:
    if not isinstance(value, str) or HEX_256.fullmatch(value) is None:
        raise ReviewError(f"{label} must be a lowercase SHA-256 digest")
    return value


def _uri(value: Any, label: str) -> str:
    uri = _string(value, label, 2048)
    if (
        raw_evidence.ABSOLUTE_URI.match(uri) is None
        or any(character.isspace() for character in uri)
    ):
        raise ReviewError(f"{label} must be an absolute URI without whitespace")
    return uri


def _timestamp(value: Any, label: str) -> str:
    timestamp = _string(value, label, 64)
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", timestamp) is None:
        raise ReviewError(f"{label} must use RFC3339 UTC seconds")
    try:
        parsed = dt.datetime.fromisoformat(timestamp[:-1] + "+00:00")
    except ValueError as error:
        raise ReviewError(f"{label} is not a valid timestamp") from error
    if parsed.tzinfo != dt.timezone.utc:
        raise ReviewError(f"{label} must use UTC")
    if parsed > dt.datetime.now(dt.timezone.utc) + raw_evidence.MAX_FUTURE_CLOCK_SKEW:
        raise ReviewError(f"{label} is too far in the future")
    return timestamp


def _timestamp_instant(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value[:-1] + "+00:00")


def review_contract(repo_root: Path) -> tuple[list[dict[str, Any]], str]:
    root = repo_root.resolve()
    records: list[dict[str, Any]] = []
    framed = hashlib.sha256()
    total_bytes = 0
    for relative_text in REVIEW_SOURCE_INPUTS:
        relative = Path(relative_text)
        path = root / relative
        if not path.is_file():
            raise ReviewError(f"review contract input is missing: {relative_text}")
        contents = _read_bounded(path, f"review contract input {relative_text}")
        total_bytes += len(contents)
        if total_bytes > MAX_REVIEW_CONTRACT_TOTAL_BYTES:
            raise ReviewError(
                "review contract inputs exceed the aggregate source-contract byte limit"
            )
        path_bytes = relative.as_posix().encode("utf-8")
        framed.update(len(path_bytes).to_bytes(8, "big"))
        framed.update(path_bytes)
        framed.update(len(contents).to_bytes(8, "big"))
        framed.update(contents)
        records.append(
            {
                "path": relative.as_posix(),
                "byte_count": len(contents),
                "sha256": _sha256(contents),
            }
        )
    return records, framed.hexdigest()


def _validated_raw(path: Path, repo_root: Path) -> tuple[dict[str, Any], bytes]:
    value, contents = _load_json_file(path, "raw evidence")
    try:
        envelope = raw_evidence.validate_envelope(value, repo_root.resolve())
    except raw_evidence.EvidenceError as error:
        raise ReviewError(f"raw evidence is invalid: {error}") from error
    return envelope, contents


def _validate_statement(value: Any) -> dict[str, Any]:
    statement = _exact_object(
        value,
        (
            "schema",
            "raw_evidence_uri",
            "certification_log_uri",
            "reviewer",
            "reviewed_at_utc",
            "notes",
            "attestations",
        ),
        "review statement",
    )
    if statement["schema"] != STATEMENT_SCHEMA:
        raise ReviewError(f"review statement schema must be {STATEMENT_SCHEMA!r}")
    raw_uri = _uri(statement["raw_evidence_uri"], "review statement raw_evidence_uri")
    log_uri = _uri(
        statement["certification_log_uri"],
        "review statement certification_log_uri",
    )
    reviewer = _string(statement["reviewer"], "review statement reviewer", 256)
    reviewed_at = _timestamp(
        statement["reviewed_at_utc"], "review statement reviewed_at_utc"
    )
    notes = _string(statement["notes"], "review statement notes", 4096)
    attestations = _exact_object(
        statement["attestations"], ATTESTATION_KEYS, "review statement attestations"
    )
    false_attestations = [key for key in ATTESTATION_KEYS if attestations[key] is not True]
    if false_attestations:
        raise ReviewError(
            f"accepted review requires every human attestation: {false_attestations}"
        )
    return {
        "raw_evidence_uri": raw_uri,
        "certification_log_uri": log_uri,
        "reviewer": reviewer,
        "reviewed_at_utc": reviewed_at,
        "notes": notes,
        "attestations": {key: True for key in ATTESTATION_KEYS},
    }


def load_statement(path: Path) -> dict[str, Any]:
    value, _ = _load_json_file(path, "review statement")
    return _validate_statement(value)


def _runner_record_binding(
    envelope: Mapping[str, Any], runner_record_bytes: bytes
) -> dict[str, Any]:
    recorded_binding = envelope["runner_record"]
    actual_digest = _sha256(runner_record_bytes)
    if (
        actual_digest != recorded_binding["sha256"]
        or len(runner_record_bytes) != recorded_binding["byte_count"]
    ):
        raise ReviewError(
            "runner record digest or byte count does not match the raw preflight binding"
        )
    return copy.deepcopy(dict(recorded_binding))


def _capture_marker(raw_digest: str) -> str:
    return (
        f"evidence-captured sha256={raw_digest} provenance_review=pending "
        "backlog_closed=false"
    )


def _log_binding(
    log_bytes: bytes,
    log_uri: str,
    raw_digest: str,
    native_host_trace: str,
    runner_preflight_marker: str,
) -> dict[str, Any]:
    marker = _capture_marker(raw_digest)
    log_lines = log_bytes.splitlines(keepends=True)
    if marker.encode("utf-8") + b"\n" not in log_lines:
        raise ReviewError(
            "certification log does not contain the exact raw-evidence capture marker line"
        )
    if native_host_trace.encode("utf-8") not in log_lines:
        raise ReviewError(
            "certification log does not contain the exact native host guard marker line"
        )
    if runner_preflight_marker.encode("utf-8") + b"\n" not in log_lines:
        raise ReviewError(
            "certification log does not contain the exact runner preflight marker line"
        )
    return {
        "uri": log_uri,
        "sha256": _sha256(log_bytes),
        "byte_count": len(log_bytes),
        "runner_preflight_marker": runner_preflight_marker,
        "capture_marker": marker,
    }


def _reviewed_claims(envelope: Mapping[str, Any]) -> dict[str, str]:
    provenance = envelope["runner_provenance"]
    return {
        "runner_id": provenance["runner_id"],
        "hardware_model": provenance["hardware_model"],
        "recorded_by": provenance["recorded_by"],
        "operator_claim": provenance["operator_claim"],
    }


def _receipt_payload(receipt: Mapping[str, Any]) -> dict[str, Any]:
    return {key: copy.deepcopy(value) for key, value in receipt.items() if key != "payload_sha256"}


def create_receipt(
    *,
    repo_root: Path,
    evidence_path: Path,
    runner_record_path: Path,
    certification_log_path: Path,
    statement_path: Path,
) -> dict[str, Any]:
    envelope, raw_bytes = _validated_raw(evidence_path, repo_root)
    runner_record_bytes = _read_bounded(runner_record_path, "runner record")
    log_bytes = _read_bounded(certification_log_path, "certification log")
    statement = load_statement(statement_path)

    if _timestamp_instant(statement["reviewed_at_utc"]) < _timestamp_instant(
        envelope["execution"]["generated_at_utc"]
    ):
        raise ReviewError("human review timestamp precedes raw evidence generation")

    runner_record = _runner_record_binding(envelope, runner_record_bytes)
    raw_digest = _sha256(raw_bytes)
    certification_log = _log_binding(
        log_bytes,
        statement["certification_log_uri"],
        raw_digest,
        envelope["execution"]["runner"]["native_guard_trace"],
        raw_evidence.runner_provenance_marker(envelope),
    )
    uris = (
        statement["raw_evidence_uri"],
        runner_record["uri"],
        certification_log["uri"],
    )
    if len(set(uris)) != len(uris):
        raise ReviewError("raw evidence, runner record, and certification log URIs must differ")

    contract_files, contract_digest = review_contract(repo_root)
    receipt: dict[str, Any] = {
        "schema": RECEIPT_SCHEMA,
        "backlog_id": BACKLOG_ID,
        "review_contract": {
            "inputs_sha256": contract_digest,
            "files": contract_files,
        },
        "raw_evidence": {
            "uri": statement["raw_evidence_uri"],
            "schema": envelope["schema"],
            "file_sha256": raw_digest,
            "byte_count": len(raw_bytes),
            "execution_sha256": envelope["execution_sha256"],
            "runner_provenance_sha256": envelope["runner_provenance_sha256"],
            "runner_preflight_sha256": envelope["runner_preflight_sha256"],
        },
        "runner_record": runner_record,
        "certification_log": certification_log,
        "machine_checks": dict(MACHINE_CHECKS),
        "human_review": {
            "status": "accepted",
            "reviewer": statement["reviewer"],
            "reviewed_at_utc": statement["reviewed_at_utc"],
            "notes": statement["notes"],
            "reviewed_claims": _reviewed_claims(envelope),
            "attestations": statement["attestations"],
        },
        "proof_boundary": dict(PROOF_BOUNDARY),
    }
    receipt["payload_sha256"] = _sha256(_canonical_json(receipt))
    validate_receipt(
        receipt,
        repo_root=repo_root,
        envelope=envelope,
        raw_bytes=raw_bytes,
        runner_record_bytes=runner_record_bytes,
        log_bytes=log_bytes,
    )
    return receipt


def _validate_file_records(value: Any, expected: list[dict[str, Any]]) -> None:
    if not isinstance(value, list) or value != expected:
        raise ReviewError("review_contract.files differ from current review inputs")
    for index, record in enumerate(value):
        _exact_object(record, ("path", "byte_count", "sha256"), f"review_contract.files[{index}]")


def validate_receipt(
    value: Any,
    *,
    repo_root: Path,
    envelope: Mapping[str, Any],
    raw_bytes: bytes,
    runner_record_bytes: bytes,
    log_bytes: bytes,
) -> dict[str, Any]:
    receipt = _exact_object(
        value,
        (
            "schema",
            "backlog_id",
            "review_contract",
            "raw_evidence",
            "runner_record",
            "certification_log",
            "machine_checks",
            "human_review",
            "proof_boundary",
            "payload_sha256",
        ),
        "review receipt",
    )
    if receipt["schema"] != RECEIPT_SCHEMA:
        raise ReviewError(f"review receipt schema must be {RECEIPT_SCHEMA!r}")
    if receipt["backlog_id"] != BACKLOG_ID:
        raise ReviewError(f"review receipt backlog_id must be {BACKLOG_ID}")
    payload_digest = _sha256_value(receipt["payload_sha256"], "payload_sha256")
    if payload_digest != _sha256(_canonical_json(_receipt_payload(receipt))):
        raise ReviewError("payload_sha256 does not match the canonical receipt payload")

    contract = _exact_object(
        receipt["review_contract"], ("inputs_sha256", "files"), "review_contract"
    )
    expected_files, expected_digest = review_contract(repo_root)
    _validate_file_records(contract["files"], expected_files)
    if contract["inputs_sha256"] != expected_digest:
        raise ReviewError("review contract digest differs from current review inputs")

    raw_record = _exact_object(
        receipt["raw_evidence"],
        (
            "uri",
            "schema",
            "file_sha256",
            "byte_count",
            "execution_sha256",
            "runner_provenance_sha256",
            "runner_preflight_sha256",
        ),
        "raw_evidence",
    )
    raw_uri = _uri(raw_record["uri"], "raw_evidence.uri")
    expected_raw = {
        "uri": raw_uri,
        "schema": raw_evidence.SCHEMA,
        "file_sha256": _sha256(raw_bytes),
        "byte_count": len(raw_bytes),
        "execution_sha256": envelope["execution_sha256"],
        "runner_provenance_sha256": envelope["runner_provenance_sha256"],
        "runner_preflight_sha256": envelope["runner_preflight_sha256"],
    }
    if dict(raw_record) != expected_raw:
        raise ReviewError("raw_evidence binding differs from the validated raw record")

    runner_record = _exact_object(
        receipt["runner_record"], ("uri", "sha256", "byte_count"), "runner_record"
    )
    expected_runner = _runner_record_binding(envelope, runner_record_bytes)
    if dict(runner_record) != expected_runner:
        raise ReviewError("runner_record binding differs from the validated attachment")

    certification_log = _exact_object(
        receipt["certification_log"],
        (
            "uri",
            "sha256",
            "byte_count",
            "runner_preflight_marker",
            "capture_marker",
        ),
        "certification_log",
    )
    log_uri = _uri(certification_log["uri"], "certification_log.uri")
    expected_log = _log_binding(
        log_bytes,
        log_uri,
        expected_raw["file_sha256"],
        envelope["execution"]["runner"]["native_guard_trace"],
        raw_evidence.runner_provenance_marker(envelope),
    )
    if dict(certification_log) != expected_log:
        raise ReviewError("certification_log binding differs from the supplied log")

    machine_checks = _exact_object(
        receipt["machine_checks"], tuple(MACHINE_CHECKS), "machine_checks"
    )
    if dict(machine_checks) != MACHINE_CHECKS:
        raise ReviewError("machine_checks must preserve the v1 passed checks")

    review = _exact_object(
        receipt["human_review"],
        (
            "status",
            "reviewer",
            "reviewed_at_utc",
            "notes",
            "reviewed_claims",
            "attestations",
        ),
        "human_review",
    )
    if review["status"] != "accepted":
        raise ReviewError("human_review.status must be 'accepted'")
    _string(review["reviewer"], "human_review.reviewer", 256)
    reviewed_at = _timestamp(
        review["reviewed_at_utc"], "human_review.reviewed_at_utc"
    )
    if _timestamp_instant(reviewed_at) < _timestamp_instant(
        envelope["execution"]["generated_at_utc"]
    ):
        raise ReviewError("human review timestamp precedes raw evidence generation")
    _string(review["notes"], "human_review.notes", 4096)
    claims = _exact_object(
        review["reviewed_claims"],
        ("runner_id", "hardware_model", "recorded_by", "operator_claim"),
        "human_review.reviewed_claims",
    )
    if dict(claims) != _reviewed_claims(envelope):
        raise ReviewError("human_review.reviewed_claims differ from raw provenance")
    attestations = _exact_object(
        review["attestations"], ATTESTATION_KEYS, "human_review.attestations"
    )
    false_attestations = [key for key in ATTESTATION_KEYS if attestations[key] is not True]
    if false_attestations:
        raise ReviewError(f"human review attestations are not all true: {false_attestations}")

    boundary = _exact_object(
        receipt["proof_boundary"], tuple(PROOF_BOUNDARY), "proof_boundary"
    )
    if dict(boundary) != PROOF_BOUNDARY:
        raise ReviewError("proof_boundary must preserve the non-closing review limits")
    if len({raw_uri, runner_record["uri"], log_uri}) != 3:
        raise ReviewError("raw evidence, runner record, and certification log URIs must differ")
    return copy.deepcopy(dict(receipt))


def load_and_validate_receipt(
    *,
    receipt_path: Path,
    repo_root: Path,
    evidence_path: Path,
    runner_record_path: Path,
    certification_log_path: Path,
) -> dict[str, Any]:
    receipt, _ = _load_json_file(receipt_path, "review receipt")
    envelope, raw_bytes = _validated_raw(evidence_path, repo_root)
    runner_record_bytes = _read_bounded(runner_record_path, "runner record")
    log_bytes = _read_bounded(certification_log_path, "certification log")
    return validate_receipt(
        receipt,
        repo_root=repo_root,
        envelope=envelope,
        raw_bytes=raw_bytes,
        runner_record_bytes=runner_record_bytes,
        log_bytes=log_bytes,
    )


def validate_runner_record(
    *, repo_root: Path, evidence_path: Path, runner_record_path: Path
) -> dict[str, Any]:
    envelope, _ = _validated_raw(evidence_path, repo_root)
    runner_record_bytes = _read_bounded(runner_record_path, "runner record")
    return _runner_record_binding(envelope, runner_record_bytes)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    runner = commands.add_parser(
        "runner-record-validate",
        help="validate the local runner record against pending raw evidence",
    )
    runner.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    runner.add_argument("--evidence", type=Path, required=True)
    runner.add_argument("--runner-record", type=Path, required=True)

    create = commands.add_parser(
        "review-create", help="create an accepted, explicitly non-closing review receipt"
    )
    create.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    create.add_argument("--evidence", type=Path, required=True)
    create.add_argument("--runner-record", type=Path, required=True)
    create.add_argument("--certification-log", type=Path, required=True)
    create.add_argument("--statement", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)

    validate = commands.add_parser(
        "review-validate", help="validate a receipt and every local file binding"
    )
    validate.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    validate.add_argument("--evidence", type=Path, required=True)
    validate.add_argument("--runner-record", type=Path, required=True)
    validate.add_argument("--certification-log", type=Path, required=True)
    validate.add_argument("--receipt", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "runner-record-validate":
            binding = validate_runner_record(
                repo_root=args.repo_root,
                evidence_path=args.evidence,
                runner_record_path=args.runner_record,
            )
            print(
                f"runner-record-valid sha256={binding['sha256']} "
                "provenance_review=pending physical_machine_proof=false "
                "backlog_closed=false"
            )
        elif args.command == "review-create":
            receipt = create_receipt(
                repo_root=args.repo_root,
                evidence_path=args.evidence,
                runner_record_path=args.runner_record,
                certification_log_path=args.certification_log,
                statement_path=args.statement,
            )
            digest = raw_evidence.write_atomic_new(args.output, receipt)
            print(
                f"review-receipt-created sha256={digest} "
                "human_provenance_review=accepted physical_machine_proof=false "
                f"backlog_closed=false path={args.output.resolve()}"
            )
        elif args.command == "review-validate":
            receipt = load_and_validate_receipt(
                receipt_path=args.receipt,
                repo_root=args.repo_root,
                evidence_path=args.evidence,
                runner_record_path=args.runner_record,
                certification_log_path=args.certification_log,
            )
            print(
                "review-receipt-valid human_provenance_review=accepted "
                "physical_machine_proof=false backlog_closed=false "
                f"payload_sha256={receipt['payload_sha256']}"
            )
        else:  # pragma: no cover - argparse guarantees a known command
            raise AssertionError(args.command)
    except (ReviewError, raw_evidence.EvidenceError) as error:
        print(f"aarch64 hash review error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
