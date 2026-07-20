#!/usr/bin/env python3
"""Certify accountable source coverage for the pinned Clay header.

The raw percentages come from llvm-cov's report.  The certification boundary is
stricter and source-addressable: every mapped physical source line, every
source-level function definition, and both directions of every exported branch
record must either execute or have one exact, reviewed manifest disposition.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable


SCHEMA = "zlay-clay-source-coverage-v2"
MANIFEST_LIMIT = 1024 * 1024
EXPORT_LIMIT = 64 * 1024 * 1024
REPORT_LIMIT = 1024 * 1024
LINE_VIEW_LIMIT = 8 * 1024 * 1024
MAX_JSON_NUMBER_CHARS = 128
EXPECTED_PROFILE = {
    "name": "host-clang-c99-scalar",
    "target": "host",
    "architecture": "host",
    "scope": "scalar-and-common",
    "language_standard": "c99",
    "compiler": "clang",
    "fixture_glob": "tests/oracle/*_fixture.c",
    "compiler_args": [
        "-std=c99",
        "-I",
        "tests/oracle",
        "-DCLAY_DISABLE_SIMD=",
        "-fprofile-instr-generate",
        "-fcoverage-mapping",
    ],
}
EXPECTED_SIMD_PROFILE = {
    "name": "host-clang-c99-x86_64-simd-supplement",
    "target": "host",
    "architecture": "x86_64",
    "scope": "active-x86_64-simd-bodies",
    "language_standard": "c99",
    "compiler": "clang",
    "compiler_args": [
        "-std=c99",
        "-I",
        "tests/oracle",
        "-fprofile-instr-generate",
        "-fcoverage-mapping",
    ],
}
EXPECTED_SIMD_SOURCE_RANGES = ((1475, 1526), (1978, 2002))
SIMD_INACTIVE_SOURCE_RANGES = ((1528, 1580), (1582, 1591), (2004, 2029), (2031, 2038))
SUPPORTED_EXPORT_MAJOR = 3
TOP_LEVEL_KEYS = {
    "schema",
    "header",
    "line_inventory",
    "function_inventory",
    "branch_inventory",
    "profile",
    "simd_supplement",
    "excluded_lines",
    "excluded_functions",
    "excluded_branches",
}
HEADER_KEYS = {"path", "sha256", "byte_count", "line_count"}
LINE_INVENTORY_KEYS = {"executable_count", "sha256"}
STATIC_INVENTORY_KEYS = {"count", "sha256"}
PROFILE_KEYS = set(EXPECTED_PROFILE) | {"fixtures"}
SIMD_PROFILE_KEYS = set(EXPECTED_SIMD_PROFILE) | {"fixtures"}
SIMD_SUPPLEMENT_KEYS = {
    "profile",
    "source_ranges",
    "line_inventory",
    "function_inventory",
    "branch_inventory",
}
SOURCE_SCOPE_KEYS = {"start_line", "end_line"}
LINE_EXCLUSION_KEYS = {"line", "reason"}
FUNCTION_EXCLUSION_KEYS = {
    "start_line",
    "start_column",
    "end_line",
    "end_column",
    "reason",
}
BRANCH_EXCLUSION_KEYS = FUNCTION_EXCLUSION_KEYS | {
    "file_id",
    "expanded_file_id",
    "kind",
    "occurrence",
    "direction",
}


class CoverageError(RuntimeError):
    pass


@dataclass(frozen=True, order=True)
class SourceRange:
    start_line: int
    start_column: int
    end_line: int
    end_column: int


@dataclass(frozen=True, order=True)
class BranchRecordDirection:
    source_range: SourceRange
    file_id: int
    expanded_file_id: int
    kind: int
    occurrence: int
    direction: str


@dataclass(frozen=True)
class RawMetric:
    total: int
    covered: int

    @property
    def missed(self) -> int:
        return self.total - self.covered

    @property
    def percent(self) -> float:
        return 100.0 if self.total == 0 else self.covered * 100.0 / self.total


@dataclass(frozen=True)
class CoverageResult:
    raw: dict[str, RawMetric]
    raw_accountable_lines: RawMetric
    raw_accountable_branches: RawMetric
    accountable_lines: RawMetric
    accountable_functions: RawMetric
    accountable_branches: RawMetric
    excluded_line_count: int
    excluded_function_count: int
    excluded_branch_count: int
    fixture_count: int
    header_sha256: str


@dataclass(frozen=True)
class SimdCoverageResult:
    raw: dict[str, RawMetric]
    scoped_lines: RawMetric
    scoped_functions: RawMetric
    scoped_branch_directions: RawMetric
    fixture_count: int


def _read_limited(path: Path, limit: int) -> bytes:
    try:
        with path.open("rb") as handle:
            contents = handle.read(limit + 1)
    except OSError as error:
        raise CoverageError(f"cannot read {path}: {error}") from error
    if len(contents) > limit:
        raise CoverageError(f"{path} exceeds the {limit}-byte input limit")
    return contents


def _decode_utf8(path: Path, contents: bytes) -> str:
    try:
        return contents.decode("utf-8")
    except UnicodeError as error:
        raise CoverageError(f"{path} is not valid UTF-8: {error}") from error


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CoverageError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise CoverageError(f"non-finite JSON number is not permitted: {value}")


def _parse_json_integer(value: str) -> int:
    if len(value) > MAX_JSON_NUMBER_CHARS:
        raise CoverageError("JSON integer token exceeds the input limit")
    return int(value)


def _parse_json_float(value: str) -> float:
    if len(value) > MAX_JSON_NUMBER_CHARS:
        raise CoverageError("JSON floating-point token exceeds the input limit")
    result = float(value)
    if not math.isfinite(result):
        raise CoverageError(f"JSON number decodes to a non-finite value: {value}")
    return result


def _load_json(path: Path, limit: int) -> Any:
    text = _decode_utf8(path, _read_limited(path, limit))
    try:
        return json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_constant=_reject_json_constant,
            parse_int=_parse_json_integer,
            parse_float=_parse_json_float,
        )
    except CoverageError:
        raise
    except (json.JSONDecodeError, RecursionError, ValueError) as error:
        raise CoverageError(f"invalid JSON in {path}: {error}") from error


def _require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CoverageError(f"{label} must be a JSON object")
    return value


def _require_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        raise CoverageError(
            f"{label} keys differ: missing={sorted(expected - actual)} "
            f"unexpected={sorted(actual - expected)}"
        )


def _require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise CoverageError(f"{label} must be a nonempty string")
    return value


def _require_int(value: Any, label: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise CoverageError(f"{label} must be an integer >= {minimum}")
    return value


def _reason(value: Any, label: str) -> str:
    reason = _require_string(value, label).strip()
    if len(reason) < 12:
        raise CoverageError(f"{label} must be a specific reviewed rationale")
    return reason


def _source_range(value: dict[str, Any], label: str) -> SourceRange:
    result = SourceRange(
        _require_int(value["start_line"], f"{label}.start_line", 1),
        _require_int(value["start_column"], f"{label}.start_column", 1),
        _require_int(value["end_line"], f"{label}.end_line", 1),
        _require_int(value["end_column"], f"{label}.end_column", 1),
    )
    if (result.end_line, result.end_column) < (result.start_line, result.start_column):
        raise CoverageError(f"{label} has an inverted source range")
    return result


def _relative_file(path: Any, label: str) -> str:
    value = _require_string(path, label)
    parsed = Path(value)
    if parsed.is_absolute() or ".." in parsed.parts or parsed.as_posix() != value:
        raise CoverageError(f"{label} must be a normalized repository-relative path")
    return value


def _validate_sha256(value: Any, label: str) -> str:
    digest = _require_string(value, label)
    if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise CoverageError(f"{label} must be lowercase SHA-256")
    return digest


def _parse_static_inventory(value: Any, label: str) -> dict[str, Any]:
    inventory = _require_object(value, label)
    _require_keys(inventory, STATIC_INVENTORY_KEYS, label)
    _require_int(inventory["count"], f"{label}.count", 1)
    _validate_sha256(inventory["sha256"], f"{label}.sha256")
    return inventory


def _parse_profile(
    value: Any,
    label: str,
    expected: dict[str, Any],
) -> dict[str, Any]:
    profile = _require_object(value, label)
    _require_keys(profile, set(expected) | {"fixtures"}, label)
    for key, expected_value in expected.items():
        if profile[key] != expected_value:
            raise CoverageError(
                f"{label}.{key} must be {expected_value!r}, found {profile[key]!r}"
            )
    fixtures = profile["fixtures"]
    if not isinstance(fixtures, list) or not fixtures:
        raise CoverageError(f"{label}.fixtures must be a nonempty array")
    normalized = [
        _relative_file(item, f"{label}.fixtures[{index}]")
        for index, item in enumerate(fixtures)
    ]
    if normalized != sorted(normalized):
        raise CoverageError(f"{label}.fixtures must be sorted")
    if len(normalized) != len(set(normalized)):
        raise CoverageError(f"{label}.fixtures contains duplicates")
    profile["fixtures"] = normalized
    return profile


def _parse_manifest(path: Path) -> dict[str, Any]:
    manifest = _require_object(_load_json(path, MANIFEST_LIMIT), "coverage manifest")
    _require_keys(manifest, TOP_LEVEL_KEYS, "coverage manifest")
    if manifest["schema"] != SCHEMA:
        raise CoverageError(f"coverage manifest schema must be {SCHEMA!r}")

    header = _require_object(manifest["header"], "coverage manifest.header")
    _require_keys(header, HEADER_KEYS, "coverage manifest.header")
    header["path"] = _relative_file(header["path"], "coverage manifest.header.path")
    _validate_sha256(header["sha256"], "coverage manifest.header.sha256")
    _require_int(header["byte_count"], "coverage manifest.header.byte_count", 1)
    _require_int(header["line_count"], "coverage manifest.header.line_count", 1)

    line_inventory = _require_object(
        manifest["line_inventory"], "coverage manifest.line_inventory"
    )
    _require_keys(
        line_inventory, LINE_INVENTORY_KEYS, "coverage manifest.line_inventory"
    )
    _require_int(
        line_inventory["executable_count"],
        "coverage manifest.line_inventory.executable_count",
        1,
    )
    _validate_sha256(
        line_inventory["sha256"], "coverage manifest.line_inventory.sha256"
    )
    _parse_static_inventory(
        manifest["function_inventory"], "coverage manifest.function_inventory"
    )
    _parse_static_inventory(
        manifest["branch_inventory"], "coverage manifest.branch_inventory"
    )

    profile = _parse_profile(
        manifest["profile"], "coverage manifest.profile", EXPECTED_PROFILE
    )

    simd = _require_object(
        manifest["simd_supplement"], "coverage manifest.simd_supplement"
    )
    _require_keys(simd, SIMD_SUPPLEMENT_KEYS, "coverage manifest.simd_supplement")
    simd_profile = _parse_profile(
        simd["profile"],
        "coverage manifest.simd_supplement.profile",
        EXPECTED_SIMD_PROFILE,
    )
    if not set(simd_profile["fixtures"]).issubset(profile["fixtures"]):
        raise CoverageError("SIMD supplement fixtures must be a subset of scalar fixtures")
    raw_ranges = simd["source_ranges"]
    if not isinstance(raw_ranges, list):
        raise CoverageError("coverage manifest.simd_supplement.source_ranges must be an array")
    parsed_ranges: list[tuple[int, int]] = []
    for index, raw_range in enumerate(raw_ranges):
        label = f"coverage manifest.simd_supplement.source_ranges[{index}]"
        source_scope = _require_object(raw_range, label)
        _require_keys(source_scope, SOURCE_SCOPE_KEYS, label)
        start_line = _require_int(source_scope["start_line"], f"{label}.start_line", 1)
        end_line = _require_int(source_scope["end_line"], f"{label}.end_line", start_line)
        parsed_ranges.append((start_line, end_line))
    if tuple(parsed_ranges) != EXPECTED_SIMD_SOURCE_RANGES:
        raise CoverageError(
            "coverage manifest SIMD source ranges differ from the reviewed x86_64 bodies"
        )
    simd["_source_ranges"] = tuple(parsed_ranges)
    simd_line_inventory = _require_object(
        simd["line_inventory"], "coverage manifest.simd_supplement.line_inventory"
    )
    _require_keys(
        simd_line_inventory,
        LINE_INVENTORY_KEYS,
        "coverage manifest.simd_supplement.line_inventory",
    )
    _require_int(
        simd_line_inventory["executable_count"],
        "coverage manifest.simd_supplement.line_inventory.executable_count",
        1,
    )
    _validate_sha256(
        simd_line_inventory["sha256"],
        "coverage manifest.simd_supplement.line_inventory.sha256",
    )
    _parse_static_inventory(
        simd["function_inventory"],
        "coverage manifest.simd_supplement.function_inventory",
    )
    _parse_static_inventory(
        simd["branch_inventory"],
        "coverage manifest.simd_supplement.branch_inventory",
    )

    line_entries = manifest["excluded_lines"]
    if not isinstance(line_entries, list):
        raise CoverageError("coverage manifest.excluded_lines must be an array")
    excluded_lines: dict[int, str] = {}
    for index, raw_entry in enumerate(line_entries):
        label = f"coverage manifest.excluded_lines[{index}]"
        entry = _require_object(raw_entry, label)
        _require_keys(entry, LINE_EXCLUSION_KEYS, label)
        line = _require_int(entry["line"], f"{label}.line", 1)
        if line in excluded_lines:
            raise CoverageError(f"duplicate excluded line coordinate: {line}")
        excluded_lines[line] = _reason(entry["reason"], f"{label}.reason")

    function_entries = manifest["excluded_functions"]
    if not isinstance(function_entries, list):
        raise CoverageError("coverage manifest.excluded_functions must be an array")
    excluded_functions: dict[SourceRange, str] = {}
    for index, raw_entry in enumerate(function_entries):
        label = f"coverage manifest.excluded_functions[{index}]"
        entry = _require_object(raw_entry, label)
        _require_keys(entry, FUNCTION_EXCLUSION_KEYS, label)
        source_range = _source_range(entry, label)
        if source_range in excluded_functions:
            raise CoverageError(f"duplicate excluded function coordinate: {source_range}")
        excluded_functions[source_range] = _reason(entry["reason"], f"{label}.reason")

    branch_entries = manifest["excluded_branches"]
    if not isinstance(branch_entries, list):
        raise CoverageError("coverage manifest.excluded_branches must be an array")
    excluded_branches: dict[BranchRecordDirection, str] = {}
    for index, raw_entry in enumerate(branch_entries):
        label = f"coverage manifest.excluded_branches[{index}]"
        entry = _require_object(raw_entry, label)
        _require_keys(entry, BRANCH_EXCLUSION_KEYS, label)
        direction = entry["direction"]
        if direction not in ("true", "false"):
            raise CoverageError(f"{label}.direction must be 'true' or 'false'")
        coordinate = BranchRecordDirection(
            _source_range(entry, label),
            _require_int(entry["file_id"], f"{label}.file_id"),
            _require_int(entry["expanded_file_id"], f"{label}.expanded_file_id"),
            _require_int(entry["kind"], f"{label}.kind"),
            _require_int(entry["occurrence"], f"{label}.occurrence"),
            direction,
        )
        if coordinate in excluded_branches:
            raise CoverageError(f"duplicate excluded branch coordinate: {coordinate}")
        excluded_branches[coordinate] = _reason(entry["reason"], f"{label}.reason")

    manifest["_excluded_lines"] = excluded_lines
    manifest["_excluded_functions"] = excluded_functions
    manifest["_excluded_branches"] = excluded_branches
    return manifest


def _validate_repository(manifest: dict[str, Any], repo_root: Path) -> tuple[Path, str]:
    header_meta = manifest["header"]
    header_path = (repo_root / header_meta["path"]).resolve()
    try:
        header_path.relative_to(repo_root.resolve())
    except ValueError as error:
        raise CoverageError("coverage header escapes the repository root") from error
    contents = _read_limited(header_path, max(header_meta["byte_count"], 1) + 1)
    if len(contents) != header_meta["byte_count"]:
        raise CoverageError(
            f"pinned header byte count changed: expected {header_meta['byte_count']}, actual {len(contents)}"
        )
    if not contents.endswith(b"\n"):
        raise CoverageError("pinned header must end with a newline")
    line_count = len(contents.splitlines())
    if line_count != header_meta["line_count"]:
        raise CoverageError(
            f"pinned header line count changed: expected {header_meta['line_count']}, actual {line_count}"
        )
    digest = hashlib.sha256(contents).hexdigest()
    if digest != header_meta["sha256"]:
        raise CoverageError(
            f"pinned header digest changed: expected {header_meta['sha256']}, actual {digest}"
        )

    fixture_glob = manifest["profile"]["fixture_glob"]
    actual_fixtures = sorted(
        path.relative_to(repo_root).as_posix()
        for path in repo_root.glob(fixture_glob)
        if path.is_file()
    )
    expected_fixtures = manifest["profile"]["fixtures"]
    if actual_fixtures != expected_fixtures:
        raise CoverageError(
            "coverage fixture inventory drifted\n"
            f"  missing from checkout: {sorted(set(expected_fixtures) - set(actual_fixtures))}\n"
            f"  missing from manifest: {sorted(set(actual_fixtures) - set(expected_fixtures))}"
        )
    return header_path, digest


def _metric(summary: dict[str, Any], name: str) -> RawMetric:
    value = _require_object(summary.get(name), f"llvm-cov summary.{name}")
    total = _require_int(value.get("count"), f"llvm-cov summary.{name}.count")
    covered = _require_int(value.get("covered"), f"llvm-cov summary.{name}.covered")
    if covered > total:
        raise CoverageError(f"llvm-cov summary.{name}.covered exceeds count")
    not_covered = value.get("notcovered")
    if not_covered is not None and _require_int(
        not_covered, f"llvm-cov summary.{name}.notcovered"
    ) != total - covered:
        raise CoverageError(f"llvm-cov summary.{name}.notcovered is inconsistent")
    percent = value.get("percent")
    if isinstance(percent, bool) or not isinstance(percent, (int, float)) or not math.isfinite(percent):
        raise CoverageError(f"llvm-cov summary.{name}.percent must be finite")
    metric = RawMetric(total, covered)
    if not math.isclose(float(percent), metric.percent, rel_tol=0.0, abs_tol=1e-9):
        raise CoverageError(f"llvm-cov summary.{name}.percent is inconsistent")
    return metric


def _coverage_file(export: Any, header_path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    root = _require_object(export, "llvm-cov export")
    _require_keys(root, {"data", "type", "version"}, "llvm-cov export")
    if root["type"] != "llvm.coverage.json.export":
        raise CoverageError("llvm-cov export type is unsupported")
    version = _require_string(root["version"], "llvm-cov export.version")
    version_match = re.fullmatch(r"([0-9]{1,9})\.[0-9]{1,9}\.[0-9]{1,9}", version)
    if version_match is None or int(version_match.group(1)) != SUPPORTED_EXPORT_MAJOR:
        raise CoverageError(
            f"llvm-cov export major version must be {SUPPORTED_EXPORT_MAJOR}, found {version!r}"
        )
    data = root.get("data")
    if not isinstance(data, list) or len(data) != 1:
        raise CoverageError("llvm-cov export must contain exactly one data record")
    record = _require_object(data[0], "llvm-cov export.data[0]")
    files = record.get("files")
    functions = record.get("functions")
    if not isinstance(files, list) or not isinstance(functions, list):
        raise CoverageError("llvm-cov export must contain files and functions arrays")
    target = header_path.resolve()
    matches: list[dict[str, Any]] = []
    for index, raw_file in enumerate(files):
        file_record = _require_object(raw_file, f"llvm-cov export.files[{index}]")
        filename = _require_string(file_record.get("filename"), f"llvm-cov export.files[{index}].filename")
        if Path(filename).resolve() == target:
            matches.append(file_record)
    if len(matches) != 1:
        raise CoverageError(f"llvm-cov export must contain exactly one pinned-header file, found {len(matches)}")
    return matches[0], [_require_object(item, "llvm-cov export function") for item in functions]


_REPORT_PERCENT = re.compile(r"^(?:0|[1-9]\d?|100)(?:\.\d+)?%$")


def _parse_report(path: Path) -> dict[str, RawMetric]:
    text = _decode_utf8(path, _read_limited(path, REPORT_LIMIT))
    total_lines = [line for line in text.splitlines() if line.startswith("TOTAL")]
    if len(total_lines) != 1:
        raise CoverageError("llvm-cov report must contain exactly one TOTAL row")
    fields = total_lines[0].split()
    if len(fields) != 13:
        raise CoverageError(f"unsupported llvm-cov TOTAL row: {total_lines[0]!r}")
    metric_fields = {
        "regions": (1, 2, 3),
        "functions": (4, 5, 6),
        "lines": (7, 8, 9),
        "branches": (10, 11, 12),
    }
    result: dict[str, RawMetric] = {}
    for name, (total_index, missed_index, percent_index) in metric_fields.items():
        try:
            if any(
                len(fields[index]) > MAX_JSON_NUMBER_CHARS
                for index in (total_index, missed_index, percent_index)
            ):
                raise ValueError
            total = int(fields[total_index])
            missed = int(fields[missed_index])
            percent_text = fields[percent_index]
            if _REPORT_PERCENT.fullmatch(percent_text) is None:
                raise ValueError
            displayed_percent = float(percent_text[:-1])
        except ValueError as error:
            raise CoverageError(f"invalid llvm-cov report {name} fields") from error
        if total < 0 or missed < 0 or missed > total:
            raise CoverageError(f"invalid llvm-cov report {name} counts")
        metric = RawMetric(total, total - missed)
        if not math.isfinite(displayed_percent) or abs(displayed_percent - metric.percent) > 0.0051:
            raise CoverageError(f"llvm-cov report {name} percentage is inconsistent")
        result[name] = metric
    return result


_LINE_ROW = re.compile(r"^\s*(\d+)\|([^|]*)\|")
_LINE_COUNT = re.compile(
    r"^(?:(?:0|[1-9]\d*)|(?:[1-9]\d{0,2}(?:,\d{3})+))"
    r"(?:\.\d+)?[kMGTPE]?$"
)


def _parse_line_view(path: Path, expected_line_count: int) -> dict[int, bool]:
    text = _decode_utf8(path, _read_limited(path, LINE_VIEW_LIMIT))
    physical_lines: dict[int, str] = {}
    for raw_line in text.splitlines():
        match = _LINE_ROW.match(raw_line)
        if match is None:
            continue
        line_number_text = match.group(1)
        if len(line_number_text) > MAX_JSON_NUMBER_CHARS:
            raise CoverageError("llvm-cov line-number token exceeds the input limit")
        try:
            line_number = int(line_number_text)
        except ValueError as error:
            raise CoverageError("invalid llvm-cov line number") from error
        if line_number in physical_lines:
            raise CoverageError(f"llvm-cov line view repeats top-level source line {line_number}")
        physical_lines[line_number] = match.group(2).strip()
    expected = set(range(1, expected_line_count + 1))
    if set(physical_lines) != expected:
        missing = sorted(expected - set(physical_lines))
        unexpected = sorted(set(physical_lines) - expected)
        raise CoverageError(
            f"llvm-cov line view does not contain the exact pinned header: "
            f"missing={missing[:8]} unexpected={unexpected[:8]}"
        )
    executable: dict[int, bool] = {}
    for line_number, count_text in physical_lines.items():
        if not count_text:
            continue
        if count_text == "?":
            raise CoverageError(f"llvm-cov line {line_number} has an unknown execution count")
        if len(count_text) > MAX_JSON_NUMBER_CHARS:
            raise CoverageError(
                f"llvm-cov execution-count token exceeds the input limit at line {line_number}"
            )
        if _LINE_COUNT.fullmatch(count_text) is None:
            raise CoverageError(
                f"unsupported llvm-cov execution count at line {line_number}: "
                f"{count_text!r}"
            )
        normalized = count_text.rstrip("kMGTPE").replace(",", "")
        try:
            count = Decimal(normalized)
        except InvalidOperation as error:
            raise CoverageError(
                f"unsupported llvm-cov execution count at line {line_number}: {count_text!r}"
            ) from error
        if not count.is_finite() or count < 0:
            raise CoverageError(
                f"unsupported llvm-cov execution count at line {line_number}: {count_text!r}"
            )
        executable[line_number] = count > 0
    return executable


def _validate_line_inventory(
    line_coverage: dict[int, bool], expected: dict[str, Any]
) -> None:
    canonical = "".join(f"{line_number}\n" for line_number in sorted(line_coverage))
    digest = hashlib.sha256(canonical.encode("ascii")).hexdigest()
    if len(line_coverage) != expected["executable_count"] or digest != expected["sha256"]:
        raise CoverageError(
            "llvm-cov mapped physical-line inventory drifted: "
            f"expected_count={expected['executable_count']} actual_count={len(line_coverage)} "
            f"expected_sha256={expected['sha256']} actual_sha256={digest}"
        )


def _canonical_inventory_digest(rows: list[Any]) -> str:
    encoded = (json.dumps(rows, separators=(",", ":"), ensure_ascii=True) + "\n").encode(
        "ascii"
    )
    return hashlib.sha256(encoded).hexdigest()


def _validate_static_inventory_value(
    rows: list[Any], expected: dict[str, Any], label: str
) -> None:
    digest = _canonical_inventory_digest(rows)
    if len(rows) != expected["count"] or digest != expected["sha256"]:
        raise CoverageError(
            f"{label} drifted: expected_count={expected['count']} actual_count={len(rows)} "
            f"expected_sha256={expected['sha256']} actual_sha256={digest}"
        )


def _function_inventory_rows(
    functions: dict[SourceRange, tuple[bool, tuple[str, ...]]],
) -> list[Any]:
    return [
        [
            coordinate.start_line,
            coordinate.start_column,
            coordinate.end_line,
            coordinate.end_column,
            list(values[1]),
        ]
        for coordinate, values in sorted(functions.items())
    ]


def _branch_inventory_rows(
    file_record: dict[str, Any],
    source_ranges: tuple[tuple[int, int], ...] | None = None,
) -> list[Any]:
    raw_branches = file_record.get("branches")
    if not isinstance(raw_branches, list):
        raise CoverageError("llvm-cov pinned-header record lacks branches")
    rows: list[Any] = []
    for index, branch in enumerate(raw_branches):
        if not isinstance(branch, list) or len(branch) != 9:
            raise CoverageError(f"llvm-cov branch {index} is malformed")
        static = [
            _require_int(branch[0], f"llvm-cov branch {index} start line", 1),
            _require_int(branch[1], f"llvm-cov branch {index} start column", 1),
            _require_int(branch[2], f"llvm-cov branch {index} end line", 1),
            _require_int(branch[3], f"llvm-cov branch {index} end column", 1),
            _require_int(branch[6], f"llvm-cov branch {index} file id"),
            _require_int(branch[7], f"llvm-cov branch {index} expanded file id"),
            _require_int(branch[8], f"llvm-cov branch {index} kind"),
        ]
        if (static[2], static[3]) < (static[0], static[1]):
            raise CoverageError(f"llvm-cov branch {index} has an inverted source range")
        if source_ranges is not None and not any(
            start <= static[0] <= static[2] <= end for start, end in source_ranges
        ):
            continue
        rows.append(static)
    return rows


def _source_functions(
    functions: Iterable[dict[str, Any]], header_path: Path
) -> dict[SourceRange, tuple[bool, tuple[str, ...]]]:
    grouped: dict[SourceRange, list[tuple[bool, str]]] = {}
    target = header_path.resolve()
    for index, function in enumerate(functions):
        filenames = function.get("filenames")
        regions = function.get("regions")
        if not isinstance(filenames, list) or not filenames or not isinstance(regions, list) or not regions:
            raise CoverageError(f"llvm-cov function {index} lacks filenames or regions")
        if Path(_require_string(filenames[0], f"llvm-cov function {index} filename")).resolve() != target:
            continue
        first = regions[0]
        if not isinstance(first, list) or len(first) < 5:
            raise CoverageError(f"llvm-cov function {index} has an invalid first region")
        source_range = SourceRange(
            _require_int(first[0], f"llvm-cov function {index} start line", 1),
            _require_int(first[1], f"llvm-cov function {index} start column", 1),
            _require_int(first[2], f"llvm-cov function {index} end line", 1),
            _require_int(first[3], f"llvm-cov function {index} end column", 1),
        )
        if (source_range.end_line, source_range.end_column) < (
            source_range.start_line,
            source_range.start_column,
        ):
            raise CoverageError(f"llvm-cov function {index} has an inverted source range")
        count = _require_int(function.get("count"), f"llvm-cov function {index} count")
        name = _require_string(function.get("name"), f"llvm-cov function {index} name")
        grouped.setdefault(source_range, []).append((count > 0, name))
    return {
        coordinate: (any(item[0] for item in values), tuple(sorted({item[1] for item in values})))
        for coordinate, values in grouped.items()
    }


def _validate_fixture_provenance(
    functions: Iterable[dict[str, Any]], expected_fixtures: Iterable[str]
) -> None:
    expected = {Path(path).name for path in expected_fixtures}
    observed: set[str] = set()
    for function in functions:
        name = function.get("name")
        if not isinstance(name, str) or ":" not in name:
            continue
        prefix = name.split(":", 1)[0]
        if prefix.endswith("_fixture.c"):
            observed.add(prefix)
    if observed != expected:
        raise CoverageError(
            "llvm-cov export fixture provenance differs from the manifest\n"
            f"  absent from export: {sorted(expected - observed)}\n"
            f"  unexpected in export: {sorted(observed - expected)}"
        )


def _branch_record_directions(
    file_record: dict[str, Any],
) -> dict[BranchRecordDirection, bool]:
    raw_branches = file_record.get("branches")
    if not isinstance(raw_branches, list):
        raise CoverageError("llvm-cov pinned-header record lacks branches")
    result: dict[BranchRecordDirection, bool] = {}
    occurrences: dict[tuple[SourceRange, int, int, int], int] = {}
    for index, branch in enumerate(raw_branches):
        if not isinstance(branch, list) or len(branch) != 9:
            raise CoverageError(f"llvm-cov branch {index} is malformed")
        source_range = SourceRange(
            _require_int(branch[0], f"llvm-cov branch {index} start line", 1),
            _require_int(branch[1], f"llvm-cov branch {index} start column", 1),
            _require_int(branch[2], f"llvm-cov branch {index} end line", 1),
            _require_int(branch[3], f"llvm-cov branch {index} end column", 1),
        )
        if (source_range.end_line, source_range.end_column) < (
            source_range.start_line,
            source_range.start_column,
        ):
            raise CoverageError(f"llvm-cov branch {index} has an inverted source range")
        true_count = _require_int(branch[4], f"llvm-cov branch {index} true count")
        false_count = _require_int(branch[5], f"llvm-cov branch {index} false count")
        file_id = _require_int(branch[6], f"llvm-cov branch {index} file id")
        expanded_file_id = _require_int(
            branch[7], f"llvm-cov branch {index} expanded file id"
        )
        kind = _require_int(branch[8], f"llvm-cov branch {index} kind")
        static_identity = (source_range, file_id, expanded_file_id, kind)
        occurrence = occurrences.get(static_identity, 0)
        occurrences[static_identity] = occurrence + 1
        for direction, covered in (("true", true_count > 0), ("false", false_count > 0)):
            coordinate = BranchRecordDirection(
                source_range,
                file_id,
                expanded_file_id,
                kind,
                occurrence,
                direction,
            )
            if coordinate in result:
                raise CoverageError(
                    f"llvm-cov branch record identity is duplicated: {coordinate}"
                )
            result[coordinate] = covered
    return result


def _format_ranges(values: Iterable[Any], limit: int = 12) -> str:
    ordered = sorted(values)
    shown = ", ".join(str(value) for value in ordered[:limit])
    if len(ordered) > limit:
        shown += f", ... ({len(ordered)} total)"
    return shown


def _accountable_metric(
    label: str,
    coverage: dict[Any, bool],
    exclusions: dict[Any, str],
) -> RawMetric:
    coordinates = set(coverage)
    if not coordinates:
        raise CoverageError(f"{label} coverage inventory is empty")
    exclusion_coordinates = set(exclusions)
    stale = exclusion_coordinates - {coordinate for coordinate, covered in coverage.items() if not covered}
    if stale:
        raise CoverageError(f"stale or invalid {label} exclusions: {_format_ranges(stale)}")
    uncovered = {coordinate for coordinate, covered in coverage.items() if not covered}
    unclassified = uncovered - exclusion_coordinates
    if unclassified:
        raise CoverageError(f"unclassified uncovered {label}: {_format_ranges(unclassified)}")
    in_scope = coordinates - exclusion_coordinates
    if not in_scope:
        raise CoverageError(f"{label} exclusions remove the entire coverage inventory")
    covered_in_scope = sum(coverage[coordinate] for coordinate in in_scope)
    metric = RawMetric(len(in_scope), covered_in_scope)
    if metric.covered != metric.total:
        raise CoverageError(
            f"in-scope {label} coverage is not 100%: {metric.covered}/{metric.total}"
        )
    return metric


def _raw_accountable_metric(
    label: str, raw: RawMetric, excluded_count: int
) -> RawMetric:
    if excluded_count > raw.total:
        raise CoverageError(f"{label} exclusions exceed the raw llvm-cov inventory")
    metric = RawMetric(raw.total - excluded_count, raw.covered)
    if metric.total <= 0 or metric.covered != metric.total:
        raise CoverageError(
            f"raw-accountable {label} coverage is not 100%: "
            f"{metric.covered}/{metric.total}"
        )
    return metric


def certify(
    *,
    repo_root: Path,
    manifest_path: Path,
    export_path: Path,
    report_path: Path,
    line_view_path: Path,
) -> CoverageResult:
    repo_root = repo_root.resolve()
    manifest = _parse_manifest(manifest_path)
    header_path, digest = _validate_repository(manifest, repo_root)
    export = _load_json(export_path, EXPORT_LIMIT)
    file_record, functions = _coverage_file(export, header_path)
    _validate_fixture_provenance(functions, manifest["profile"]["fixtures"])
    summary = _require_object(file_record.get("summary"), "llvm-cov pinned-header summary")
    raw = {name: _metric(summary, name) for name in ("regions", "functions", "lines", "branches")}
    report = _parse_report(report_path)
    if raw != report:
        raise CoverageError(f"llvm-cov export/report summaries differ: export={raw} report={report}")

    line_coverage = _parse_line_view(line_view_path, manifest["header"]["line_count"])
    _validate_line_inventory(line_coverage, manifest["line_inventory"])
    line_misses = sum(not covered for covered in line_coverage.values())
    if line_misses != raw["lines"].missed:
        raise CoverageError(
            "mapped physical-line misses differ from llvm-cov summary: "
            f"mapped={line_misses} raw={raw['lines'].missed}"
        )
    if len(line_coverage) < raw["lines"].total:
        raise CoverageError(
            "mapped physical-line inventory is smaller than the llvm-cov summary"
        )
    function_coverage = _source_functions(functions, header_path)
    if len(function_coverage) != raw["functions"].total:
        raise CoverageError(
            "source-level function grouping differs from llvm-cov summary: "
            f"grouped={len(function_coverage)} raw={raw['functions'].total}"
        )
    if sum(value[0] for value in function_coverage.values()) != raw["functions"].covered:
        raise CoverageError("source-level function execution differs from llvm-cov summary")
    _validate_static_inventory_value(
        _function_inventory_rows(function_coverage),
        manifest["function_inventory"],
        "scalar function inventory",
    )
    branch_coverage = _branch_record_directions(file_record)
    _validate_static_inventory_value(
        _branch_inventory_rows(file_record),
        manifest["branch_inventory"],
        "scalar ordered branch-record inventory",
    )
    branch_misses = sum(not covered for covered in branch_coverage.values())
    if branch_misses != raw["branches"].missed:
        raise CoverageError(
            "exported branch-record misses differ from llvm-cov summary: "
            f"records={branch_misses} raw={raw['branches'].missed}"
        )
    if len(branch_coverage) < raw["branches"].total:
        raise CoverageError(
            "exported branch-record direction inventory is smaller than the llvm-cov summary"
        )

    accountable_lines = _accountable_metric(
        "mapped physical lines", line_coverage, manifest["_excluded_lines"]
    )
    accountable_functions = _accountable_metric(
        "functions",
        {coordinate: value[0] for coordinate, value in function_coverage.items()},
        manifest["_excluded_functions"],
    )
    accountable_branches = _accountable_metric(
        "branch-record directions", branch_coverage, manifest["_excluded_branches"]
    )
    raw_accountable_lines = _raw_accountable_metric(
        "lines", raw["lines"], len(manifest["_excluded_lines"])
    )
    raw_accountable_branches = _raw_accountable_metric(
        "branches", raw["branches"], len(manifest["_excluded_branches"])
    )
    return CoverageResult(
        raw=raw,
        raw_accountable_lines=raw_accountable_lines,
        raw_accountable_branches=raw_accountable_branches,
        accountable_lines=accountable_lines,
        accountable_functions=accountable_functions,
        accountable_branches=accountable_branches,
        excluded_line_count=len(manifest["_excluded_lines"]),
        excluded_function_count=len(manifest["_excluded_functions"]),
        excluded_branch_count=len(manifest["_excluded_branches"]),
        fixture_count=len(manifest["profile"]["fixtures"]),
        header_sha256=digest,
    )


def _range_in_scope(
    source_range: SourceRange, scopes: tuple[tuple[int, int], ...]
) -> bool:
    return any(
        start <= source_range.start_line <= source_range.end_line <= end
        for start, end in scopes
    )


def certify_simd_supplement(
    *,
    repo_root: Path,
    manifest_path: Path,
    export_path: Path,
    report_path: Path,
    line_view_path: Path,
) -> SimdCoverageResult:
    repo_root = repo_root.resolve()
    manifest = _parse_manifest(manifest_path)
    header_path, _ = _validate_repository(manifest, repo_root)
    simd = manifest["simd_supplement"]
    scopes = simd["_source_ranges"]

    export = _load_json(export_path, EXPORT_LIMIT)
    file_record, functions = _coverage_file(export, header_path)
    _validate_fixture_provenance(functions, simd["profile"]["fixtures"])
    summary = _require_object(file_record.get("summary"), "llvm-cov pinned-header summary")
    raw = {name: _metric(summary, name) for name in ("regions", "functions", "lines", "branches")}
    report = _parse_report(report_path)
    if raw != report:
        raise CoverageError(
            f"SIMD llvm-cov export/report summaries differ: export={raw} report={report}"
        )

    all_lines = _parse_line_view(line_view_path, manifest["header"]["line_count"])
    unexpected_inactive = sorted(
        line_number
        for line_number in all_lines
        if any(start <= line_number <= end for start, end in SIMD_INACTIVE_SOURCE_RANGES)
    )
    if unexpected_inactive:
        raise CoverageError(
            "SIMD artifact activated a reviewed non-x86 implementation range: "
            f"{unexpected_inactive[:12]}"
        )
    scoped_lines = {
        line_number: covered
        for line_number, covered in all_lines.items()
        if any(start <= line_number <= end for start, end in scopes)
    }
    _validate_line_inventory(scoped_lines, simd["line_inventory"])

    all_functions = _source_functions(functions, header_path)
    scoped_functions = {
        coordinate: values
        for coordinate, values in all_functions.items()
        if _range_in_scope(coordinate, scopes)
    }
    _validate_static_inventory_value(
        _function_inventory_rows(scoped_functions),
        simd["function_inventory"],
        "x86_64 SIMD function inventory",
    )

    all_branches = _branch_record_directions(file_record)
    scoped_branches = {
        coordinate: covered
        for coordinate, covered in all_branches.items()
        if _range_in_scope(coordinate.source_range, scopes)
    }
    _validate_static_inventory_value(
        _branch_inventory_rows(file_record, scopes),
        simd["branch_inventory"],
        "x86_64 SIMD ordered branch-record inventory",
    )

    return SimdCoverageResult(
        raw=raw,
        scoped_lines=_accountable_metric("x86_64 SIMD lines", scoped_lines, {}),
        scoped_functions=_accountable_metric(
            "x86_64 SIMD functions",
            {coordinate: values[0] for coordinate, values in scoped_functions.items()},
            {},
        ),
        scoped_branch_directions=_accountable_metric(
            "x86_64 SIMD branch-record directions", scoped_branches, {}
        ),
        fixture_count=len(simd["profile"]["fixtures"]),
    )


def _metric_text(metric: RawMetric) -> str:
    return f"{metric.covered}/{metric.total} ({metric.percent:.2f}%)"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--export", dest="export_path", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--line-view", type=Path, required=True)
    parser.add_argument("--simd-export", type=Path, required=True)
    parser.add_argument("--simd-report", type=Path, required=True)
    parser.add_argument("--simd-line-view", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        result = certify(
            repo_root=args.repo_root,
            manifest_path=args.manifest,
            export_path=args.export_path,
            report_path=args.report,
            line_view_path=args.line_view,
        )
        simd_result = certify_simd_supplement(
            repo_root=args.repo_root,
            manifest_path=args.manifest,
            export_path=args.simd_export,
            report_path=args.simd_report,
            line_view_path=args.simd_line_view,
        )
    except CoverageError as error:
        print(f"Clay coverage certification failed: {error}", file=sys.stderr)
        return 1

    print(
        "Clay coverage certification passed: "
        f"raw_lines={_metric_text(result.raw['lines'])} "
        f"raw_functions={_metric_text(result.raw['functions'])} "
        f"raw_branches={_metric_text(result.raw['branches'])} "
        f"raw_regions={_metric_text(result.raw['regions'])}"
    )
    print(
        "scalar accountable coverage: "
        f"raw_accountable_lines={_metric_text(result.raw_accountable_lines)} "
        f"raw_accountable_branches={_metric_text(result.raw_accountable_branches)} "
        f"mapped_physical_lines={_metric_text(result.accountable_lines)} "
        f"functions={_metric_text(result.accountable_functions)} "
        f"branch_record_directions={_metric_text(result.accountable_branches)} "
        f"excluded_lines={result.excluded_line_count} "
        f"excluded_functions={result.excluded_function_count} "
        f"excluded_branch_directions={result.excluded_branch_count} "
        f"fixtures={result.fixture_count} header_sha256={result.header_sha256}"
    )
    print(
        "x86_64 SIMD scoped supplement: "
        f"mapped_physical_lines={_metric_text(simd_result.scoped_lines)} "
        f"functions={_metric_text(simd_result.scoped_functions)} "
        f"branch_record_directions={_metric_text(simd_result.scoped_branch_directions)} "
        f"fixtures={simd_result.fixture_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
