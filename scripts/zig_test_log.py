#!/usr/bin/env python3
"""Strictly parse successful Zig test-runner logs for proof artifacts."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Final


_RECORD: Final[re.Pattern[str]] = re.compile(
    r"([1-9][0-9]*)/([1-9][0-9]*) (.+)\.\.\.(OK|SKIP)"
)
_ALL_PASSED: Final[re.Pattern[str]] = re.compile(r"All ([1-9][0-9]*) tests passed\.")
_COUNTED: Final[re.Pattern[str]] = re.compile(
    r"(0|[1-9][0-9]*) passed; (0|[1-9][0-9]*) skipped; 0 failed\."
)


class ZigTestLogError(ValueError):
    """Raised when a captured Zig test log is not exact successful evidence."""


@dataclass(frozen=True)
class ZigTestRecord:
    index: int
    total: int
    name: str
    status: str


@dataclass(frozen=True)
class ZigTestLogSummary:
    total: int
    passed: int
    skipped: int
    skipped_names: tuple[str, ...]
    records: tuple[ZigTestRecord, ...]
    byte_count: int
    sha256: str
    text: str


def _reject_invalid_name(name: str, label: str) -> None:
    has_control = any(
        ord(character) < 0x20 or ord(character) == 0x7F for character in name
    )
    if name != name.strip() or has_control:
        raise ZigTestLogError(f"{label} has an invalid test name")


def validate_zig_test_log(
    data: bytes,
    label: str,
    *,
    allowed_skips: tuple[str, ...],
) -> ZigTestLogSummary:
    """Return bound log metadata after exact success and skip-policy validation."""

    if len(set(allowed_skips)) != len(allowed_skips):
        raise ZigTestLogError(f"{label} allowed-skip policy contains duplicates")
    for allowed_skip in allowed_skips:
        _reject_invalid_name(allowed_skip, label)

    if not data.endswith(b"\n"):
        raise ZigTestLogError(f"{label} is not newline terminated")
    if b"\r" in data:
        raise ZigTestLogError(f"{label} contains non-canonical carriage returns")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ZigTestLogError(f"{label} is not UTF-8") from exc

    lines = text.splitlines()
    if len(lines) < 2:
        raise ZigTestLogError(f"{label} has no test records")

    record_lines = lines[:-1]
    total = len(record_lines)
    records: list[ZigTestRecord] = []
    names: set[str] = set()
    passed = 0
    skipped_names: list[str] = []
    for expected_index, line in enumerate(record_lines, 1):
        match = _RECORD.fullmatch(line)
        if match is None:
            raise ZigTestLogError(f"{label} has an invalid test record")
        index_text = match.group(1)
        declared_total_text = match.group(2)
        name = match.group(3)
        status = match.group(4)
        if index_text != str(expected_index) or declared_total_text != str(total):
            raise ZigTestLogError(f"{label} test numbering is not contiguous")
        _reject_invalid_name(name, label)
        if name in names:
            raise ZigTestLogError(f"{label} contains duplicate test name {name!r}")
        names.add(name)
        records.append(ZigTestRecord(expected_index, total, name, status))
        if status == "OK":
            passed += 1
        else:
            skipped_names.append(name)

    skipped = len(skipped_names)
    summary = lines[-1]
    all_passed = _ALL_PASSED.fullmatch(summary)
    counted = _COUNTED.fullmatch(summary)
    if all_passed is not None:
        if all_passed.group(1) != str(total) or passed != total or skipped != 0:
            raise ZigTestLogError(
                f"{label} all-passed summary differs from its records"
            )
    elif counted is not None:
        if counted.group(1) != str(passed) or counted.group(2) != str(skipped):
            raise ZigTestLogError(
                f"{label} counted summary differs from its records"
            )
    else:
        raise ZigTestLogError(f"{label} has an invalid success summary")

    if passed == 0:
        raise ZigTestLogError(f"{label} has no passing tests")
    if tuple(skipped_names) != allowed_skips:
        raise ZigTestLogError(
            f"{label} skipped tests differ: expected {allowed_skips!r}, "
            f"found {tuple(skipped_names)!r}"
        )

    return ZigTestLogSummary(
        total=total,
        passed=passed,
        skipped=skipped,
        skipped_names=tuple(skipped_names),
        records=tuple(records),
        byte_count=len(data),
        sha256=hashlib.sha256(data).hexdigest(),
        text=text,
    )
