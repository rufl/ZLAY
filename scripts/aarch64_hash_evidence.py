#!/usr/bin/env python3
"""Capture and validate raw ZL-202 AArch64 hash execution records.

The record is deliberately not a certificate. Validation checks the versioned
schema, current certification-input digest, immutable runner-record preflight,
strictly parsed and byte-bound native test logs, canonical bindings, exact
traces, and internally consistent recorded claims.
It cannot prove that capture or physical execution occurred. Physical-machine
provenance remains an operator claim pending human review.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import os
import platform
import re
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

from zig_test_log import ZigTestLogError, ZigTestLogSummary, validate_zig_test_log


REPO_ROOT = Path(__file__).resolve().parents[1]

SCHEMA = "zlay.aarch64-hash-execution.v1"
PROVENANCE_SCHEMA = "zlay.aarch64-runner-provenance.v1"
SNAPSHOT_SCHEMA = "zlay.aarch64-certification-input-snapshot.v1"
RUNNER_PREFLIGHT_SCHEMA = "zlay.aarch64-runner-preflight.v1"
BACKLOG_ID = "ZL-202"
PINNED_CLAY_COMMIT = "e6cc36941ab2af5d81107617039d6f527a1c660b"
PINNED_HEADER_SHA256 = "54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728"
TRACE_IDENTITY = "hash-default"
TRACE_LINE_COUNT = 18
TRACE_BYTE_COUNT = 426
TRACE_SHA256 = "68b1ce5dfef146735d34889f337fa3f73a597b0511a5fc511f9e399d263dc787"
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_RUNNER_RECORD_BYTES = 16 * 1024 * 1024
MAX_SOURCE_INPUT_BYTES = 16 * 1024 * 1024
MAX_SOURCE_INPUT_TOTAL_BYTES = 64 * 1024 * 1024
MAX_TEST_LOG_BYTES = 16 * 1024 * 1024
MAX_JSON_INTEGER_DIGITS = 128
MAX_JSON_NESTING = 256
MAX_FUTURE_CLOCK_SKEW = dt.timedelta(minutes=5)

MODULE_TEST_ALLOWED_SKIPS = (
    "hash.test.textWithConfig matches pinned x86_64 default C oracle vectors",
)
TEST_RUN_ALLOWED_SKIPS = {
    "module_tests": MODULE_TEST_ALLOWED_SKIPS,
    "ordinary_manifest_tests": (),
}
TEST_RUN_KEYS = tuple(TEST_RUN_ALLOWED_SKIPS)

SOURCE_INPUTS = (
    "build.zig",
    "build.zig.zon",
    "evidence/aarch64-hash-evidence.schema.json",
    "evidence/aarch64-hash-runner-preflight.schema.json",
    "scripts/aarch64_hash_evidence.py",
    "scripts/check_aarch64_hash_build_contract.py",
    "scripts/zig_test_log.py",
    "tests/oracle/check_header.zig",
    "tests/oracle/check_native_aarch64_host.zig",
    "tests/oracle/clay.h",
    "tests/oracle/compare.zig",
    "tests/oracle/hash_default_fixture.c",
    "tests/oracle/hash_default_fixture.zig",
    "tests/oracle/ordinary_manifest.zig",
    "tests/test_aarch64_hash_evidence.py",
    "tests/test_aarch64_hash_build_contract.py",
)

EXECUTABLE_KEYS = (
    "c_oracle",
    "zig_oracle",
    "comparator",
    "module_tests",
    "ordinary_manifest_tests",
    "native_host_guard",
    "header_checker",
    "zig_compiler",
)

GATE_KEYS = (
    "pre_gate_source_snapshot",
    "runner_record_preflight",
    "native_host_guard",
    "header_digest",
    "ordinary_manifest_tests",
    "hash_oracle_compare",
    "native_zlay_tests",
    "evidence_contract_tests",
    "build_orchestration_contract",
)

PROOF_BOUNDARY = {
    "artifact_kind": "raw-execution-record",
    "machine_validation": "execution-and-runner-binding-contract-only",
    "physical_hardware_machine_verified": False,
    "provenance_review_status": "pending",
    "backlog_closed": False,
}

CACHE_DIRECTORY_NAMES = frozenset(
    {".zig-cache", ".zig-global-cache", "zig-cache", "zig-out", "__pycache__"}
)
HEX_256 = re.compile(r"[0-9a-f]{64}\Z")
ABSOLUTE_URI_PATTERN = r"[A-Za-z][A-Za-z0-9+.-]*:[^\s]*\Z"
ABSOLUTE_URI_SCHEMA_PATTERN = r"^[A-Za-z][A-Za-z0-9+.-]*:[^\s]*$"
ABSOLUTE_URI = re.compile(ABSOLUTE_URI_PATTERN)
NATIVE_HOST_LINE = re.compile(
    r"native-host sysname=(\S+) release=(\S+) machine=(aarch64|arm64) word_bits=(64)\n\Z"
)


class EvidenceError(RuntimeError):
    pass


@dataclass(frozen=True)
class RunnerFacts:
    system: str
    release: str
    version: str
    machine: str
    userspace_bits: int


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise EvidenceError(f"duplicate JSON key is not allowed: {key!r}")
        value[key] = item
    return value


def _reject_non_finite_json(value: str) -> None:
    raise EvidenceError(f"non-finite JSON number is not allowed: {value}")


def _parse_json_integer(value: str) -> int:
    digits = value[1:] if value.startswith("-") else value
    if len(digits) > MAX_JSON_INTEGER_DIGITS:
        raise EvidenceError(
            f"JSON integer exceeds the {MAX_JSON_INTEGER_DIGITS}-digit input limit"
        )
    return int(value)


def _reject_excessive_json_nesting(raw: bytes | str) -> None:
    """Bound structural nesting without trusting the JSON decoder's C stack."""
    quote = 0x22 if isinstance(raw, bytes) else '"'
    escape_marker = 0x5C if isinstance(raw, bytes) else "\\"
    opens = (0x5B, 0x7B) if isinstance(raw, bytes) else ("[", "{")
    closes = (0x5D, 0x7D) if isinstance(raw, bytes) else ("]", "}")
    depth = 0
    in_string = False
    escaped = False
    for token in raw:
        if in_string:
            if escaped:
                escaped = False
            elif token == escape_marker:
                escaped = True
            elif token == quote:
                in_string = False
            continue
        if token == quote:
            in_string = True
        elif token in opens:
            depth += 1
            if depth > MAX_JSON_NESTING:
                raise EvidenceError(
                    f"JSON input nesting is too deep (limit {MAX_JSON_NESTING})"
                )
        elif token in closes and depth > 0:
            depth -= 1


def _load_json(raw: bytes | str) -> Any:
    _reject_excessive_json_nesting(raw)
    try:
        return json.loads(
            raw,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_non_finite_json,
            parse_int=_parse_json_integer,
        )
    except RecursionError as error:
        raise EvidenceError("JSON input nesting is too deep") from error


def _canonical_json(value: Any) -> bytes:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except UnicodeEncodeError as error:
        raise EvidenceError("canonical JSON contains an invalid Unicode surrogate") from error
    except RecursionError as error:
        raise EvidenceError("canonical JSON nesting is too deep") from error
    except (TypeError, ValueError) as error:
        raise EvidenceError(f"cannot canonicalize JSON: {error}") from error


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _read_bounded(path: Path, label: str, maximum: int) -> bytes:
    try:
        with path.open("rb") as source:
            contents = source.read(maximum + 1)
    except OSError as error:
        raise EvidenceError(f"cannot read {label} {path}: {error}") from error
    if len(contents) > maximum:
        raise EvidenceError(f"{label} exceeds the {maximum}-byte input limit")
    return contents


def _require_exact_keys(value: Any, keys: Sequence[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be an object")
    expected = set(keys)
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise EvidenceError(f"{label} keys differ; missing={missing} unknown={unknown}")
    return value


def _require_string(value: Any, label: str, *, maximum: int = 1024) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise EvidenceError(f"{label} must be a non-empty string of at most {maximum} characters")
    if "\x00" in value:
        raise EvidenceError(f"{label} must not contain NUL")
    return value


def _require_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or HEX_256.fullmatch(value) is None:
        raise EvidenceError(f"{label} must be a lowercase SHA-256 digest")
    return value


def _source_input_paths(repo_root: Path) -> tuple[Path, ...]:
    relative_paths = {Path(path) for path in SOURCE_INPUTS}
    src_root = repo_root / "src"
    if not src_root.is_dir():
        raise EvidenceError(f"certification source directory is missing: {src_root}")
    relative_paths.update(path.relative_to(repo_root) for path in src_root.rglob("*.zig"))
    ordered = tuple(sorted(relative_paths, key=lambda path: path.as_posix()))
    missing = [path.as_posix() for path in ordered if not (repo_root / path).is_file()]
    if missing:
        raise EvidenceError(f"certification input files are missing: {missing}")
    return ordered


def certification_inputs(repo_root: Path) -> tuple[list[dict[str, Any]], str]:
    files: list[dict[str, Any]] = []
    framed = hashlib.sha256()
    total_bytes = 0
    for relative in _source_input_paths(repo_root):
        data = _read_bounded(
            repo_root / relative,
            f"certification input {relative.as_posix()}",
            MAX_SOURCE_INPUT_BYTES,
        )
        total_bytes += len(data)
        if total_bytes > MAX_SOURCE_INPUT_TOTAL_BYTES:
            raise EvidenceError(
                "certification inputs exceed the aggregate source-contract byte limit"
            )
        path_bytes = relative.as_posix().encode("utf-8")
        framed.update(len(path_bytes).to_bytes(8, "big"))
        framed.update(path_bytes)
        framed.update(len(data).to_bytes(8, "big"))
        framed.update(data)
        files.append(
            {
                "path": relative.as_posix(),
                "byte_count": len(data),
                "sha256": _sha256_bytes(data),
            }
        )
    return files, framed.hexdigest()


def _snapshot_payload(snapshot: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "schema": snapshot["schema"],
        "files": copy.deepcopy(snapshot["files"]),
        "certification_inputs_sha256": snapshot["certification_inputs_sha256"],
    }


def create_source_snapshot(
    repo_root: Path, expected_build_zig_sha256: str
) -> dict[str, Any]:
    expected_build_digest = _require_sha256(
        expected_build_zig_sha256, "expected build.zig SHA-256"
    )
    files, source_digest = certification_inputs(repo_root.resolve())
    snapshotted_build_digest = next(
        (record["sha256"] for record in files if record["path"] == "build.zig"), None
    )
    if snapshotted_build_digest != expected_build_digest:
        raise EvidenceError(
            "live build.zig SHA-256 differs from the build-embedded snapshot digest: "
            f"expected={expected_build_digest} actual={snapshotted_build_digest}"
        )
    snapshot: dict[str, Any] = {
        "schema": SNAPSHOT_SCHEMA,
        "files": files,
        "certification_inputs_sha256": source_digest,
    }
    snapshot["snapshot_sha256"] = _sha256_bytes(_canonical_json(snapshot))
    return snapshot


def validate_source_snapshot(value: Any, repo_root: Path) -> dict[str, Any]:
    snapshot = _require_exact_keys(
        value,
        ("schema", "files", "certification_inputs_sha256", "snapshot_sha256"),
        "source snapshot",
    )
    if snapshot["schema"] != SNAPSHOT_SCHEMA:
        raise EvidenceError(f"source snapshot schema must be {SNAPSHOT_SCHEMA!r}")
    files = snapshot["files"]
    if not isinstance(files, list) or not files:
        raise EvidenceError("source snapshot files must be a non-empty array")
    for index, record in enumerate(files):
        item = _require_exact_keys(
            record, ("path", "byte_count", "sha256"), f"source snapshot files[{index}]"
        )
        _require_string(item["path"], f"source snapshot files[{index}].path", maximum=4096)
        if type(item["byte_count"]) is not int or item["byte_count"] < 0:
            raise EvidenceError(
                f"source snapshot files[{index}].byte_count must be a non-negative integer"
            )
        _require_sha256(item["sha256"], f"source snapshot files[{index}].sha256")
    source_digest = _require_sha256(
        snapshot["certification_inputs_sha256"],
        "source snapshot certification_inputs_sha256",
    )
    snapshot_digest = _require_sha256(snapshot["snapshot_sha256"], "source snapshot SHA-256")
    if snapshot_digest != _sha256_bytes(_canonical_json(_snapshot_payload(snapshot))):
        raise EvidenceError("source snapshot SHA-256 does not match its canonical payload")

    expected_files, expected_digest = certification_inputs(repo_root.resolve())
    if files != expected_files:
        raise EvidenceError("source snapshot files differ from current certification inputs")
    if source_digest != expected_digest:
        raise EvidenceError("source snapshot digest differs from current certification inputs")
    return copy.deepcopy(dict(snapshot))


def load_source_snapshot(path: Path, repo_root: Path) -> dict[str, Any]:
    try:
        contents = _read_bounded(path, "source snapshot", MAX_JSON_BYTES)
        value = _load_json(contents)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot load source snapshot {path}: {error}") from error
    return validate_source_snapshot(value, repo_root)


def _validate_zig_version(version: Any) -> str:
    version = _require_string(version, "toolchain.zig_version", maximum=128)
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$", version)
    if match is None or tuple(map(int, match.groups()))[:2] != (0, 16):
        raise EvidenceError("toolchain.zig_version must be within the Zig 0.16 compatibility line")
    return version


def _validate_timestamp(value: Any) -> str:
    value = _require_string(value, "execution.generated_at_utc", maximum=64)
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value) is None:
        raise EvidenceError("execution.generated_at_utc must use the RFC3339 UTC second format")
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise EvidenceError("execution.generated_at_utc is not a valid RFC3339 timestamp") from error
    if parsed.tzinfo != dt.timezone.utc:
        raise EvidenceError("execution.generated_at_utc must use UTC")
    if parsed > dt.datetime.now(dt.timezone.utc) + MAX_FUTURE_CLOCK_SKEW:
        raise EvidenceError("execution.generated_at_utc is too far in the future")
    return value


def _read_trace(path: Path, label: str) -> tuple[str, bytes]:
    try:
        raw = _read_bounded(path, f"{label} trace", TRACE_BYTE_COUNT)
    except EvidenceError:
        raise
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError(f"{label} trace must be UTF-8") from error
    if not text.endswith("\n"):
        raise EvidenceError(f"{label} trace must end with a newline")
    return text, raw


def _validate_trace_bytes(raw: bytes, label: str) -> None:
    line_count = raw.count(b"\n")
    digest = _sha256_bytes(raw)
    if len(raw) != TRACE_BYTE_COUNT or line_count != TRACE_LINE_COUNT or digest != TRACE_SHA256:
        raise EvidenceError(
            f"{label} trace does not match the AArch64 contract: "
            f"lines={line_count} bytes={len(raw)} sha256={digest}"
        )


def _validate_provenance(value: Any) -> dict[str, Any]:
    provenance = _require_exact_keys(
        value,
        (
            "schema",
            "runner_id",
            "hardware_model",
            "recorded_by",
            "operator_claim",
            "attachment",
        ),
        "runner_provenance",
    )
    if provenance["schema"] != PROVENANCE_SCHEMA:
        raise EvidenceError(f"runner_provenance.schema must be {PROVENANCE_SCHEMA!r}")
    for key in ("runner_id", "hardware_model", "recorded_by"):
        _require_string(provenance[key], f"runner_provenance.{key}", maximum=256)
    if provenance["operator_claim"] != "physical-non-emulated":
        raise EvidenceError("runner_provenance.operator_claim must be 'physical-non-emulated'")
    attachment = _require_exact_keys(
        provenance["attachment"], ("uri", "sha256"), "runner_provenance.attachment"
    )
    uri = _require_string(attachment["uri"], "runner_provenance.attachment.uri", maximum=2048)
    if any(character.isspace() for character in uri) or ABSOLUTE_URI.match(uri) is None:
        raise EvidenceError("runner_provenance.attachment.uri must be an absolute URI without whitespace")
    _require_sha256(attachment["sha256"], "runner_provenance.attachment.sha256")
    return copy.deepcopy(dict(provenance))


def load_provenance(path: Path) -> dict[str, Any]:
    try:
        raw = _read_bounded(path, "runner provenance", MAX_JSON_BYTES)
        value = _load_json(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot load runner provenance {path}: {error}") from error
    return _validate_provenance(value)


def _runner_record_binding(
    provenance: Mapping[str, Any], runner_record_bytes: bytes
) -> dict[str, Any]:
    if not runner_record_bytes:
        raise EvidenceError("runner record must not be empty")
    attachment = provenance["attachment"]
    actual_digest = _sha256_bytes(runner_record_bytes)
    if actual_digest != attachment["sha256"]:
        raise EvidenceError(
            "runner record digest does not match runner_provenance.attachment.sha256"
        )
    return {
        "uri": attachment["uri"],
        "sha256": actual_digest,
        "byte_count": len(runner_record_bytes),
    }


def _runner_preflight_payload(preflight: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "schema": preflight["schema"],
        "runner_provenance": copy.deepcopy(preflight["runner_provenance"]),
        "runner_provenance_sha256": preflight["runner_provenance_sha256"],
        "runner_record": copy.deepcopy(preflight["runner_record"]),
    }


def _preflight_from_parts(
    provenance: Mapping[str, Any], runner_record_bytes: bytes
) -> dict[str, Any]:
    validated_provenance = _validate_provenance(provenance)
    preflight: dict[str, Any] = {
        "schema": RUNNER_PREFLIGHT_SCHEMA,
        "runner_provenance": validated_provenance,
        "runner_provenance_sha256": _sha256_bytes(
            _canonical_json(validated_provenance)
        ),
        "runner_record": _runner_record_binding(
            validated_provenance, runner_record_bytes
        ),
    }
    preflight["preflight_sha256"] = _sha256_bytes(
        _canonical_json(_runner_preflight_payload(preflight))
    )
    return preflight


def create_runner_preflight(
    provenance_path: Path, runner_record_path: Path
) -> dict[str, Any]:
    provenance = load_provenance(provenance_path)
    runner_record_bytes = _read_bounded(
        runner_record_path, "runner record", MAX_RUNNER_RECORD_BYTES
    )
    return _preflight_from_parts(provenance, runner_record_bytes)


def create_runner_provenance(
    *,
    runner_record_path: Path,
    runner_record_uri: str,
    runner_id: str,
    hardware_model: str,
    recorded_by: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    runner_record_bytes = _read_bounded(
        runner_record_path, "runner record", MAX_RUNNER_RECORD_BYTES
    )
    provenance = _validate_provenance(
        {
            "schema": PROVENANCE_SCHEMA,
            "runner_id": runner_id,
            "hardware_model": hardware_model,
            "recorded_by": recorded_by,
            "operator_claim": "physical-non-emulated",
            "attachment": {
                "uri": runner_record_uri,
                "sha256": _sha256_bytes(runner_record_bytes),
            },
        }
    )
    return provenance, _preflight_from_parts(provenance, runner_record_bytes)


def validate_runner_preflight(value: Any) -> dict[str, Any]:
    preflight = _require_exact_keys(
        value,
        (
            "schema",
            "runner_provenance",
            "runner_provenance_sha256",
            "runner_record",
            "preflight_sha256",
        ),
        "runner preflight",
    )
    if preflight["schema"] != RUNNER_PREFLIGHT_SCHEMA:
        raise EvidenceError(
            f"runner preflight schema must be {RUNNER_PREFLIGHT_SCHEMA!r}"
        )
    provenance = _validate_provenance(preflight["runner_provenance"])
    provenance_digest = _require_sha256(
        preflight["runner_provenance_sha256"],
        "runner preflight runner_provenance_sha256",
    )
    if provenance_digest != _sha256_bytes(_canonical_json(provenance)):
        raise EvidenceError(
            "runner preflight provenance digest does not match its canonical object"
        )
    runner_record = _require_exact_keys(
        preflight["runner_record"],
        ("uri", "sha256", "byte_count"),
        "runner preflight runner_record",
    )
    uri = _require_string(
        runner_record["uri"], "runner preflight runner_record.uri", maximum=2048
    )
    if any(character.isspace() for character in uri) or ABSOLUTE_URI.match(uri) is None:
        raise EvidenceError(
            "runner preflight runner_record.uri must be an absolute URI without whitespace"
        )
    digest = _require_sha256(
        runner_record["sha256"], "runner preflight runner_record.sha256"
    )
    byte_count = runner_record["byte_count"]
    if (
        type(byte_count) is not int
        or byte_count <= 0
        or byte_count > MAX_RUNNER_RECORD_BYTES
    ):
        raise EvidenceError(
            "runner preflight runner_record.byte_count must be a positive bounded integer"
        )
    attachment = provenance["attachment"]
    if uri != attachment["uri"] or digest != attachment["sha256"]:
        raise EvidenceError(
            "runner preflight runner_record binding differs from provenance attachment"
        )
    preflight_digest = _require_sha256(
        preflight["preflight_sha256"], "runner preflight preflight_sha256"
    )
    validated = {
        "schema": RUNNER_PREFLIGHT_SCHEMA,
        "runner_provenance": provenance,
        "runner_provenance_sha256": provenance_digest,
        "runner_record": {
            "uri": uri,
            "sha256": digest,
            "byte_count": byte_count,
        },
        "preflight_sha256": preflight_digest,
    }
    expected_preflight_digest = _sha256_bytes(
        _canonical_json(_runner_preflight_payload(validated))
    )
    if preflight_digest != expected_preflight_digest:
        raise EvidenceError(
            "runner preflight digest does not match its canonical payload"
        )
    return copy.deepcopy(validated)


def load_runner_preflight(path: Path) -> dict[str, Any]:
    try:
        raw = _read_bounded(path, "runner preflight", MAX_JSON_BYTES)
        value = _load_json(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot load runner preflight {path}: {error}") from error
    return validate_runner_preflight(value)


def _preflight_from_envelope(envelope: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "schema": RUNNER_PREFLIGHT_SCHEMA,
        "runner_provenance": copy.deepcopy(envelope["runner_provenance"]),
        "runner_provenance_sha256": envelope["runner_provenance_sha256"],
        "runner_record": copy.deepcopy(envelope["runner_record"]),
        "preflight_sha256": envelope["runner_preflight_sha256"],
    }


def runner_preflight_marker(preflight_value: Mapping[str, Any]) -> str:
    preflight = validate_runner_preflight(preflight_value)
    runner_record = preflight["runner_record"]
    return (
        "runner-provenance-valid "
        f"preflight_sha256={preflight['preflight_sha256']} "
        f"provenance_sha256={preflight['runner_provenance_sha256']} "
        f"runner_record_sha256={runner_record['sha256']} "
        f"runner_record_byte_count={runner_record['byte_count']} "
        "physical_machine_proof=false backlog_closed=false"
    )


def runner_provenance_marker(envelope: Mapping[str, Any]) -> str:
    return runner_preflight_marker(_preflight_from_envelope(envelope))


def collect_runner_facts() -> RunnerFacts:
    uname = platform.uname()
    return RunnerFacts(
        system=uname.system,
        release=uname.release,
        version=uname.version,
        machine=uname.machine.lower(),
        userspace_bits=struct.calcsize("P") * 8,
    )


def collect_zig_version(zig_executable: Path) -> str:
    try:
        result = subprocess.run(
            [str(zig_executable), "version"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise EvidenceError(f"cannot query Zig version from {zig_executable}: {error}") from error
    return _validate_zig_version(result.stdout.strip())


def _load_native_host_trace(path: Path, runner: RunnerFacts) -> tuple[str, str]:
    try:
        raw = _read_bounded(path, "native host guard trace", 4096)
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError(f"cannot read native host guard trace {path}: {error}") from error
    match = NATIVE_HOST_LINE.fullmatch(text)
    if match is None:
        raise EvidenceError("native host guard trace does not match the v1 structured contract")
    sysname, release, machine, word_bits = match.groups()
    if (
        sysname != runner.system
        or release != runner.release
        or machine != runner.machine.lower()
        or int(word_bits) != runner.userspace_bits
    ):
        raise EvidenceError("native host guard trace disagrees with the capture process runner facts")
    return text, _sha256_bytes(raw)


def _test_run_record(summary: ZigTestLogSummary) -> dict[str, Any]:
    return {
        "total": summary.total,
        "passed": summary.passed,
        "skipped": summary.skipped,
        "skipped_names": list(summary.skipped_names),
        "byte_count": summary.byte_count,
        "sha256": summary.sha256,
        "log": summary.text,
    }


def _parse_test_run_bytes(data: bytes, key: str) -> dict[str, Any]:
    if key not in TEST_RUN_ALLOWED_SKIPS:
        raise EvidenceError(f"unknown certification test-run key: {key}")
    if len(data) > MAX_TEST_LOG_BYTES:
        raise EvidenceError(
            f"{key} log exceeds the {MAX_TEST_LOG_BYTES}-byte input limit"
        )
    try:
        summary = validate_zig_test_log(
            data,
            key,
            allowed_skips=TEST_RUN_ALLOWED_SKIPS[key],
        )
    except ZigTestLogError as error:
        raise EvidenceError(f"invalid {key} log: {error}") from error
    return _test_run_record(summary)


def _load_test_run(path: Path, key: str) -> dict[str, Any]:
    return _parse_test_run_bytes(
        _read_bounded(path, f"{key} log", MAX_TEST_LOG_BYTES),
        key,
    )


def _validate_recorded_test_runs(value: Any) -> dict[str, dict[str, Any]]:
    runs = _require_exact_keys(value, TEST_RUN_KEYS, "execution.test_runs")
    validated: dict[str, dict[str, Any]] = {}
    record_keys = (
        "total",
        "passed",
        "skipped",
        "skipped_names",
        "byte_count",
        "sha256",
        "log",
    )
    for key in TEST_RUN_KEYS:
        record = _require_exact_keys(
            runs[key], record_keys, f"execution.test_runs.{key}"
        )
        for field in ("total", "passed", "skipped", "byte_count"):
            if type(record[field]) is not int:
                raise EvidenceError(
                    f"execution.test_runs.{key}.{field} must be an integer"
                )
        skipped_names = record["skipped_names"]
        if not isinstance(skipped_names, list) or any(
            not isinstance(name, str) for name in skipped_names
        ):
            raise EvidenceError(
                f"execution.test_runs.{key}.skipped_names must be an array of strings"
            )
        _require_sha256(record["sha256"], f"execution.test_runs.{key}.sha256")
        log = _require_string(
            record["log"],
            f"execution.test_runs.{key}.log",
            maximum=MAX_TEST_LOG_BYTES,
        )
        expected = _parse_test_run_bytes(log.encode("utf-8"), key)
        if dict(record) != expected:
            raise EvidenceError(
                f"execution.test_runs.{key} metadata differs from its validated log"
            )
        validated[key] = expected
    return validated


def _validate_target(value: Any, runner: Mapping[str, Any]) -> dict[str, str]:
    target = _require_exact_keys(
        value,
        ("selection", "triple", "arch", "os", "abi", "endian", "cpu_model"),
        "execution.target",
    )
    for key in target:
        _require_string(target[key], f"execution.target.{key}", maximum=256)
    if target["selection"] != "native":
        raise EvidenceError("execution.target.selection must be 'native'")
    if target["arch"] != "aarch64" or target["endian"] != "little":
        raise EvidenceError("execution.target must be little-endian aarch64")
    triple_parts = target["triple"].split("-")
    if len(triple_parts) != 3:
        raise EvidenceError("execution.target.triple must contain arch, OS, and ABI components")
    triple_arch, triple_os, triple_abi = triple_parts
    if (
        triple_arch != target["arch"]
        or triple_os.split(".", 1)[0] != target["os"]
        or triple_abi.split(".", 1)[0] != target["abi"]
    ):
        raise EvidenceError("execution.target.triple disagrees with its arch, OS, or ABI fields")
    expected_os = {"linux": "linux", "darwin": "macos"}.get(str(runner["system"]).lower())
    if expected_os is not None and target["os"] != expected_os:
        raise EvidenceError("execution.target.os does not match the recorded host system")
    return {key: str(target[key]) for key in target}


def create_envelope(
    *,
    repo_root: Path,
    header: Path,
    c_trace: Path,
    zig_trace: Path,
    native_host_trace: Path,
    source_snapshot_path: Path,
    runner_preflight_path: Path,
    test_log_paths: Mapping[str, Path],
    executable_paths: Mapping[str, Path],
    zig_version: str,
    optimize: str,
    target: Mapping[str, str],
    runner_facts: RunnerFacts | None = None,
    generated_at_utc: str | None = None,
) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    runner_facts = runner_facts or collect_runner_facts()
    machine = runner_facts.machine.lower()
    if machine not in ("aarch64", "arm64"):
        raise EvidenceError(f"capture requires an AArch64 kernel machine; reported {machine!r}")
    if runner_facts.userspace_bits != 64:
        raise EvidenceError("capture requires a 64-bit userspace")
    for label, value in (
        ("runner.system", runner_facts.system),
        ("runner.release", runner_facts.release),
        ("runner.version", runner_facts.version),
    ):
        _require_string(value, label, maximum=2048)

    native_guard_trace, native_guard_sha256 = _load_native_host_trace(
        native_host_trace, runner_facts
    )
    source_snapshot = load_source_snapshot(source_snapshot_path, repo_root)

    if _sha256_file(header) != PINNED_HEADER_SHA256:
        raise EvidenceError("clay.h does not match the pinned SHA-256 digest")

    c_text, c_raw = _read_trace(c_trace, "pinned C")
    zig_text, zig_raw = _read_trace(zig_trace, "native Zig")
    _validate_trace_bytes(c_raw, "pinned C")
    _validate_trace_bytes(zig_raw, "native Zig")
    if c_raw != zig_raw:
        raise EvidenceError("pinned C and native Zig AArch64 traces differ")

    if set(test_log_paths) != set(TEST_RUN_KEYS):
        raise EvidenceError("test-log path keys do not match the v1 evidence contract")
    test_runs = {
        key: _load_test_run(test_log_paths[key], key) for key in TEST_RUN_KEYS
    }

    if set(executable_paths) != set(EXECUTABLE_KEYS):
        raise EvidenceError("executable path keys do not match the v1 evidence contract")
    executable_digests: dict[str, str] = {}
    for key in EXECUTABLE_KEYS:
        path = executable_paths[key]
        if not path.is_file():
            raise EvidenceError(f"certification executable is missing: {path}")
        executable_digests[key] = _sha256_file(path)

    runner_preflight = load_runner_preflight(runner_preflight_path)
    provenance = runner_preflight["runner_provenance"]
    provenance_sha256 = runner_preflight["runner_provenance_sha256"]
    source_files = source_snapshot["files"]
    source_digest = source_snapshot["certification_inputs_sha256"]
    zig_version = _validate_zig_version(zig_version)
    optimize = _require_string(optimize, "execution.toolchain.optimize", maximum=64)
    if optimize != "Debug":
        raise EvidenceError("execution.toolchain.optimize must be Debug for the v1 certification contract")
    generated = generated_at_utc or dt.datetime.now(dt.timezone.utc).isoformat(
        timespec="seconds"
    ).replace("+00:00", "Z")
    _validate_timestamp(generated)

    runner = {
        "system": runner_facts.system,
        "release": runner_facts.release,
        "version": runner_facts.version,
        "machine": machine,
        "userspace_bits": runner_facts.userspace_bits,
        "native_guard_trace": native_guard_trace,
        "native_guard_sha256": native_guard_sha256,
    }
    target_record = _validate_target(dict(target), runner)
    execution = {
        "generated_at_utc": generated,
        "command": "zig build aarch64-hash-certify",
        "backlog_id": BACKLOG_ID,
        "source": {
            "pinned_clay_commit": PINNED_CLAY_COMMIT,
            "clay_header_sha256": PINNED_HEADER_SHA256,
            "certification_inputs_sha256": source_digest,
            "pre_gate_snapshot_sha256": source_snapshot["snapshot_sha256"],
            "files": source_files,
        },
        "toolchain": {
            "zig_version": zig_version,
            "optimize": optimize,
        },
        "runner": runner,
        "target": target_record,
        "gates": {key: "passed" for key in GATE_KEYS},
        "executables": executable_digests,
        "test_runs": test_runs,
        "oracle": {
            "identity": TRACE_IDENTITY,
            "line_count": TRACE_LINE_COUNT,
            "byte_count": TRACE_BYTE_COUNT,
            "contract_sha256": TRACE_SHA256,
            "c_trace_sha256": _sha256_bytes(c_raw),
            "zig_trace_sha256": _sha256_bytes(zig_raw),
            "c_trace": c_text,
            "zig_trace": zig_text,
            "outputs_equal": True,
        },
    }
    return {
        "schema": SCHEMA,
        "execution": execution,
        "execution_sha256": _sha256_bytes(_canonical_json(execution)),
        "runner_provenance": provenance,
        "runner_provenance_sha256": provenance_sha256,
        "runner_record": runner_preflight["runner_record"],
        "runner_preflight_sha256": runner_preflight["preflight_sha256"],
        "review": {
            "status": "pending",
            "reviewer": None,
            "reviewed_at_utc": None,
            "notes": None,
        },
        "proof_boundary": dict(PROOF_BOUNDARY),
    }


def validate_envelope(value: Any, repo_root: Path) -> dict[str, Any]:
    envelope = _require_exact_keys(
        value,
        (
            "schema",
            "execution",
            "execution_sha256",
            "runner_provenance",
            "runner_provenance_sha256",
            "runner_record",
            "runner_preflight_sha256",
            "review",
            "proof_boundary",
        ),
        "evidence",
    )
    if envelope["schema"] != SCHEMA:
        raise EvidenceError(f"evidence.schema must be {SCHEMA!r}")
    execution = _require_exact_keys(
        envelope["execution"],
        (
            "generated_at_utc",
            "command",
            "backlog_id",
            "source",
            "toolchain",
            "runner",
            "target",
            "gates",
            "executables",
            "test_runs",
            "oracle",
        ),
        "execution",
    )
    execution_sha256 = _require_sha256(envelope["execution_sha256"], "execution_sha256")
    if execution_sha256 != _sha256_bytes(_canonical_json(execution)):
        raise EvidenceError("execution_sha256 does not match the canonical execution object")
    _validate_timestamp(execution["generated_at_utc"])
    if execution["command"] != "zig build aarch64-hash-certify":
        raise EvidenceError("execution.command is not the certification entry point")
    if execution["backlog_id"] != BACKLOG_ID:
        raise EvidenceError(f"execution.backlog_id must be {BACKLOG_ID}")

    source = _require_exact_keys(
        execution["source"],
        (
            "pinned_clay_commit",
            "clay_header_sha256",
            "certification_inputs_sha256",
            "pre_gate_snapshot_sha256",
            "files",
        ),
        "execution.source",
    )
    if source["pinned_clay_commit"] != PINNED_CLAY_COMMIT:
        raise EvidenceError("execution.source.pinned_clay_commit differs from the pinned snapshot")
    if source["clay_header_sha256"] != PINNED_HEADER_SHA256:
        raise EvidenceError("execution.source.clay_header_sha256 differs from the pinned header")
    expected_files, expected_source_digest = certification_inputs(repo_root.resolve())
    if source["files"] != expected_files:
        raise EvidenceError("execution.source.files differ from the current certification inputs")
    if source["certification_inputs_sha256"] != expected_source_digest:
        raise EvidenceError("execution source digest differs from the current certification inputs")
    snapshot_payload = {
        "schema": SNAPSHOT_SCHEMA,
        "files": source["files"],
        "certification_inputs_sha256": source["certification_inputs_sha256"],
    }
    expected_snapshot_digest = _sha256_bytes(_canonical_json(snapshot_payload))
    snapshot_digest = _require_sha256(
        source["pre_gate_snapshot_sha256"], "execution.source.pre_gate_snapshot_sha256"
    )
    if snapshot_digest != expected_snapshot_digest:
        raise EvidenceError(
            "execution pre-gate snapshot digest does not match its bound source payload"
        )

    toolchain = _require_exact_keys(
        execution["toolchain"], ("zig_version", "optimize"), "execution.toolchain"
    )
    _validate_zig_version(toolchain["zig_version"])
    optimize = _require_string(toolchain["optimize"], "execution.toolchain.optimize", maximum=64)
    if optimize != "Debug":
        raise EvidenceError("execution.toolchain.optimize must be Debug for the v1 certification contract")

    runner = _require_exact_keys(
        execution["runner"],
        (
            "system",
            "release",
            "version",
            "machine",
            "userspace_bits",
            "native_guard_trace",
            "native_guard_sha256",
        ),
        "execution.runner",
    )
    for key in ("system", "release", "version"):
        _require_string(runner[key], f"execution.runner.{key}", maximum=2048)
    if runner["machine"] not in ("aarch64", "arm64"):
        raise EvidenceError("execution.runner.machine must be aarch64 or arm64")
    if type(runner["userspace_bits"]) is not int or runner["userspace_bits"] != 64:
        raise EvidenceError("execution.runner.userspace_bits must be integer 64")
    native_guard_trace = _require_string(
        runner["native_guard_trace"], "execution.runner.native_guard_trace", maximum=4096
    )
    match = NATIVE_HOST_LINE.fullmatch(native_guard_trace)
    if match is None:
        raise EvidenceError("execution.runner.native_guard_trace does not match the v1 contract")
    sysname, release, machine, word_bits = match.groups()
    if (
        sysname != runner["system"]
        or release != runner["release"]
        or machine != runner["machine"]
        or int(word_bits) != runner["userspace_bits"]
    ):
        raise EvidenceError("execution.runner.native_guard_trace disagrees with runner fields")
    native_guard_sha256 = _require_sha256(
        runner["native_guard_sha256"], "execution.runner.native_guard_sha256"
    )
    if native_guard_sha256 != _sha256_bytes(native_guard_trace.encode("utf-8")):
        raise EvidenceError("execution.runner.native_guard_sha256 does not match the guard trace")
    _validate_target(execution["target"], runner)

    gates = _require_exact_keys(execution["gates"], GATE_KEYS, "execution.gates")
    failed_gates = [key for key in GATE_KEYS if gates[key] != "passed"]
    if failed_gates:
        raise EvidenceError(f"execution gates are not all passed: {failed_gates}")

    executables = _require_exact_keys(
        execution["executables"], EXECUTABLE_KEYS, "execution.executables"
    )
    for key in EXECUTABLE_KEYS:
        _require_sha256(executables[key], f"execution.executables.{key}")

    _validate_recorded_test_runs(execution["test_runs"])

    oracle = _require_exact_keys(
        execution["oracle"],
        (
            "identity",
            "line_count",
            "byte_count",
            "contract_sha256",
            "c_trace_sha256",
            "zig_trace_sha256",
            "c_trace",
            "zig_trace",
            "outputs_equal",
        ),
        "execution.oracle",
    )
    if oracle["identity"] != TRACE_IDENTITY:
        raise EvidenceError("execution.oracle.identity differs from the hash-default contract")
    if type(oracle["line_count"]) is not int or oracle["line_count"] != TRACE_LINE_COUNT:
        raise EvidenceError("execution.oracle.line_count differs from the AArch64 contract")
    if type(oracle["byte_count"]) is not int or oracle["byte_count"] != TRACE_BYTE_COUNT:
        raise EvidenceError("execution.oracle.byte_count differs from the AArch64 contract")
    if oracle["contract_sha256"] != TRACE_SHA256:
        raise EvidenceError("execution.oracle.contract_sha256 differs from the AArch64 contract")
    if not isinstance(oracle["c_trace"], str) or not isinstance(oracle["zig_trace"], str):
        raise EvidenceError("execution.oracle traces must be strings")
    c_raw = oracle["c_trace"].encode("utf-8")
    zig_raw = oracle["zig_trace"].encode("utf-8")
    _validate_trace_bytes(c_raw, "recorded pinned C")
    _validate_trace_bytes(zig_raw, "recorded native Zig")
    if oracle["c_trace_sha256"] != _sha256_bytes(c_raw):
        raise EvidenceError("execution.oracle.c_trace_sha256 does not match the recorded trace")
    if oracle["zig_trace_sha256"] != _sha256_bytes(zig_raw):
        raise EvidenceError("execution.oracle.zig_trace_sha256 does not match the recorded trace")
    if oracle["outputs_equal"] is not True or c_raw != zig_raw:
        raise EvidenceError("recorded pinned C and native Zig traces are not equal")

    provenance = _validate_provenance(envelope["runner_provenance"])
    provenance_sha256 = _require_sha256(
        envelope["runner_provenance_sha256"], "runner_provenance_sha256"
    )
    if provenance_sha256 != _sha256_bytes(_canonical_json(provenance)):
        raise EvidenceError("runner_provenance_sha256 does not match the canonical provenance object")
    validate_runner_preflight(_preflight_from_envelope(envelope))
    review = _require_exact_keys(
        envelope["review"], ("status", "reviewer", "reviewed_at_utc", "notes"), "review"
    )
    if review != {"status": "pending", "reviewer": None, "reviewed_at_utc": None, "notes": None}:
        raise EvidenceError("raw evidence review state must remain pending and unreviewed")
    proof_boundary = _require_exact_keys(
        envelope["proof_boundary"], tuple(PROOF_BOUNDARY), "proof_boundary"
    )
    if any(
        type(proof_boundary[key]) is not type(expected) or proof_boundary[key] != expected
        for key, expected in PROOF_BOUNDARY.items()
    ):
        raise EvidenceError("proof_boundary must preserve the raw, non-closing evidence limits")
    return copy.deepcopy(dict(envelope))


def load_bytes_and_validate(path: Path, repo_root: Path) -> tuple[dict[str, Any], bytes]:
    try:
        raw = _read_bounded(path, "raw evidence", MAX_JSON_BYTES)
        value = _load_json(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot load evidence {path}: {error}") from error
    return validate_envelope(value, repo_root), raw


def load_and_validate(path: Path, repo_root: Path) -> dict[str, Any]:
    envelope, _ = load_bytes_and_validate(path, repo_root)
    return envelope


def _reject_cache_output(path: Path) -> None:
    resolved = path.resolve()
    if any(part in CACHE_DIRECTORY_NAMES for part in resolved.parts):
        raise EvidenceError(
            "evidence output must be outside Zig cache, output, and system temporary directories"
        )
    temporary_roots = {
        Path(tempfile.gettempdir()).resolve(),
        Path("/var/tmp").resolve(),
        Path("/dev/shm").resolve(),
        Path("/run/user").resolve(),
        Path("/run/lock").resolve(),
    }
    if runtime_dir := os.environ.get("XDG_RUNTIME_DIR"):
        temporary_roots.add(Path(runtime_dir).resolve())
    for temporary_root in temporary_roots:
        try:
            resolved.relative_to(temporary_root)
        except ValueError:
            continue
        raise EvidenceError(
            "evidence output must be outside Zig cache, output, and system temporary directories"
        )


def write_atomic_bytes_new(path: Path, data: bytes) -> str:
    _reject_cache_output(path)
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    linked = False
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        try:
            os.link(temporary_name, path)
        except FileExistsError as error:
            raise EvidenceError(f"refusing to overwrite existing evidence: {path}") from error
        linked = True
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except EvidenceError:
        raise
    except OSError as error:
        if linked:
            try:
                path.unlink()
            except OSError:  # craft-ignore: Preserve the original durability error.
                pass
        raise EvidenceError(f"cannot durably create evidence {path}: {error}") from error
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)
    return _sha256_bytes(data)


def write_atomic_new(path: Path, value: Any) -> str:
    try:
        data = json.dumps(
            value,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8") + b"\n"
    except (TypeError, ValueError) as error:
        raise EvidenceError(f"cannot serialize JSON output: {error}") from error
    if len(data) > MAX_JSON_BYTES:
        raise EvidenceError(
            f"JSON output exceeds the {MAX_JSON_BYTES}-byte reload limit"
        )
    return write_atomic_bytes_new(path, data)


def write_atomic_replacing(path: Path, value: Any) -> str:
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(
        value, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False
    ).encode("utf-8") + b"\n"
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(data)
        os.replace(temporary_name, path)
        temporary_name = None
    except OSError as error:
        raise EvidenceError(f"cannot atomically replace source snapshot {path}: {error}") from error
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)
    return _sha256_bytes(data)


def _add_common_review_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    provenance_create = commands.add_parser(
        "runner-provenance-create",
        help="create non-overwriting provenance bound to the actual runner-record bytes",
    )
    provenance_create.add_argument("--runner-record", type=Path, required=True)
    provenance_create.add_argument("--runner-record-uri", required=True)
    provenance_create.add_argument("--runner-id", required=True)
    provenance_create.add_argument("--hardware-model", required=True)
    provenance_create.add_argument("--recorded-by", required=True)
    provenance_create.add_argument(
        "--claim-physical-non-emulated", action="store_true", required=True
    )
    provenance_create.add_argument("--output", type=Path, required=True)

    runner_validate = commands.add_parser(
        "runner-validate",
        help="validate provenance against the actual bounded runner-record bytes",
    )
    runner_validate.add_argument("--provenance", type=Path, required=True)
    runner_validate.add_argument("--runner-record", type=Path, required=True)

    runner_preflight = commands.add_parser(
        "runner-preflight",
        help="atomically replace the ephemeral runner binding consumed by certification",
    )
    runner_preflight.add_argument("--provenance", type=Path, required=True)
    runner_preflight.add_argument("--runner-record", type=Path, required=True)
    runner_preflight.add_argument("--output", type=Path, required=True)

    snapshot = commands.add_parser(
        "snapshot", help="atomically replace the ephemeral pre-gate source snapshot"
    )
    _add_common_review_arguments(snapshot)
    snapshot.add_argument("--expected-build-zig-sha256", required=True)
    snapshot.add_argument("--output", type=Path, required=True)

    capture = commands.add_parser("capture", help="write a raw execution record after all gates pass")
    _add_common_review_arguments(capture)
    capture.add_argument("--output", type=Path, required=True)
    capture.add_argument("--header", type=Path, required=True)
    capture.add_argument("--c-trace", type=Path, required=True)
    capture.add_argument("--zig-trace", type=Path, required=True)
    capture.add_argument("--native-host-trace", type=Path, required=True)
    capture.add_argument("--source-snapshot", type=Path, required=True)
    capture.add_argument("--runner-preflight", type=Path, required=True)
    for key in TEST_RUN_KEYS:
        capture.add_argument(f"--{key.replace('_', '-')}-log", type=Path, required=True)
    capture.add_argument("--zig-exe", type=Path, required=True)
    capture.add_argument("--optimize", required=True)
    capture.add_argument("--target-triple", required=True)
    capture.add_argument("--target-arch", required=True)
    capture.add_argument("--target-os", required=True)
    capture.add_argument("--target-abi", required=True)
    capture.add_argument("--target-endian", required=True)
    capture.add_argument("--target-cpu-model", required=True)
    for key in EXECUTABLE_KEYS[:-1]:
        capture.add_argument(f"--{key.replace('_', '-')}-exe", type=Path, required=True)

    validate = commands.add_parser("validate", help="validate a raw record on any review host")
    _add_common_review_arguments(validate)
    validate.add_argument("--evidence", type=Path, required=True)

    import_command = commands.add_parser(
        "import", help="validate and atomically copy a raw record into a durable review path"
    )
    _add_common_review_arguments(import_command)
    import_command.add_argument("--evidence", type=Path, required=True)
    import_command.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "runner-provenance-create":
            provenance, preflight = create_runner_provenance(
                runner_record_path=args.runner_record,
                runner_record_uri=args.runner_record_uri,
                runner_id=args.runner_id,
                hardware_model=args.hardware_model,
                recorded_by=args.recorded_by,
            )
            digest = write_atomic_new(args.output, provenance)
            runner_record = preflight["runner_record"]
            print(
                f"runner-provenance-created file_sha256={digest} "
                f"runner_record_sha256={runner_record['sha256']} "
                f"runner_record_byte_count={runner_record['byte_count']} "
                "operator_claim=physical-non-emulated physical_machine_proof=false "
                f"backlog_closed=false path={args.output.resolve()}"
            )
        elif args.command == "runner-validate":
            preflight = create_runner_preflight(
                args.provenance, args.runner_record
            )
            print(runner_preflight_marker(preflight))
        elif args.command == "runner-preflight":
            preflight = create_runner_preflight(
                args.provenance, args.runner_record
            )
            file_digest = write_atomic_replacing(args.output, preflight)
            print(
                f"{runner_preflight_marker(preflight)} "
                f"file_sha256={file_digest} path={args.output.resolve()}"
            )
        elif args.command == "snapshot":
            snapshot = create_source_snapshot(
                args.repo_root, args.expected_build_zig_sha256
            )
            file_digest = write_atomic_replacing(args.output, snapshot)
            print(
                f"source-snapshot-written snapshot_sha256={snapshot['snapshot_sha256']} "
                f"file_sha256={file_digest} path={args.output.resolve()}"
            )
        elif args.command == "capture":
            executable_paths = {
                key: getattr(args, f"{key}_exe") for key in EXECUTABLE_KEYS[:-1]
            }
            executable_paths["zig_compiler"] = args.zig_exe
            test_log_paths = {
                key: getattr(args, f"{key}_log") for key in TEST_RUN_KEYS
            }
            envelope = create_envelope(
                repo_root=args.repo_root,
                header=args.header,
                c_trace=args.c_trace,
                zig_trace=args.zig_trace,
                native_host_trace=args.native_host_trace,
                source_snapshot_path=args.source_snapshot,
                runner_preflight_path=args.runner_preflight,
                test_log_paths=test_log_paths,
                executable_paths=executable_paths,
                zig_version=collect_zig_version(args.zig_exe),
                optimize=args.optimize,
                target={
                    "selection": "native",
                    "triple": args.target_triple,
                    "arch": args.target_arch,
                    "os": args.target_os,
                    "abi": args.target_abi,
                    "endian": args.target_endian,
                    "cpu_model": args.target_cpu_model,
                },
            )
            digest = write_atomic_new(args.output, envelope)
            print(envelope["execution"]["runner"]["native_guard_trace"], end="")
            print(runner_provenance_marker(envelope))
            print(
                f"evidence-captured sha256={digest} provenance_review=pending "
                "backlog_closed=false"
            )
            print(f"evidence-path path={args.output.resolve()}")
        elif args.command == "validate":
            envelope = load_and_validate(args.evidence, args.repo_root)
            print(
                "evidence-valid record_contract=valid recorded_gates=passed "
                f"execution_sha256={envelope['execution_sha256']} "
                "provenance_review=pending backlog_closed=false"
            )
        elif args.command == "import":
            _, source_bytes = load_bytes_and_validate(args.evidence, args.repo_root)
            digest = write_atomic_bytes_new(args.output, source_bytes)
            print(
                f"evidence-imported sha256={digest} provenance_review=pending "
                f"backlog_closed=false path={args.output.resolve()}"
            )
        else:  # pragma: no cover - argparse makes this unreachable
            raise AssertionError(args.command)
    except EvidenceError as error:
        print(f"aarch64 hash evidence error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
