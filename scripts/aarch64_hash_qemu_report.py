#!/usr/bin/env python3
"""Snapshot and report supplemental AArch64 QEMU execution identity."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import struct
import subprocess
from collections.abc import Sequence

from zig_test_log import ZigTestLogError, ZigTestLogSummary, validate_zig_test_log


SCHEMA = "zlay.aarch64-hash-qemu.v1"
UPSTREAM_COMMIT = "e6cc36941ab2af5d81107617039d6f527a1c660b"
EXPECTED_HEADER_SHA256 = "54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728"
EXPECTED_TRACE_LINES = 18
EXPECTED_TRACE_BYTES = 426
EXPECTED_TRACE_SHA256 = "68b1ce5dfef146735d34889f337fa3f73a597b0511a5fc511f9e399d263dc787"
MAX_INPUT_BYTES = 16 * 1024 * 1024
MAX_EXECUTABLE_BYTES = 128 * 1024 * 1024
MODULE_ALLOWED_SKIPS = (
    "hash.test.textWithConfig matches pinned x86_64 default C oracle vectors",
)
MANIFEST_ALLOWED_SKIPS: tuple[str, ...] = ()
SOURCE_PREFIX_FILES = (
    "build.zig",
    "build.zig.zon",
)
SOURCE_SUFFIX_FILES = (
    "scripts/aarch64_hash_qemu_report.py",
    "scripts/check_aarch64_hash_qemu_contract.py",
    "scripts/zig_test_log.py",
    "tests/test_aarch64_hash_qemu_contract.py",
    "tests/test_aarch64_hash_qemu_report.py",
    "tests/oracle/check_header.zig",
    "tests/oracle/clay.h",
    "tests/oracle/compare.zig",
    "tests/oracle/hash_default_fixture.c",
    "tests/oracle/hash_default_fixture.zig",
    "tests/oracle/ordinary_manifest.zig",
)


class ReportError(ValueError):
    pass


def _read_bounded(
    path: pathlib.Path,
    label: str,
    limit: int = MAX_INPUT_BYTES,
) -> bytes:
    try:
        with path.open("rb") as source:
            data = source.read(limit + 1)
    except OSError as exc:
        raise ReportError(f"cannot read {label}: {path}") from exc
    if len(data) > limit:
        raise ReportError(f"{label} exceeds {limit} bytes: {path}")
    return data


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _validate_trace(data: bytes, label: str) -> None:
    if len(data) != EXPECTED_TRACE_BYTES:
        raise ReportError(
            f"{label} byte count is {len(data)}, expected {EXPECTED_TRACE_BYTES}"
        )
    if not data.endswith(b"\n"):
        raise ReportError(f"{label} is not newline terminated")
    if len(data.splitlines()) != EXPECTED_TRACE_LINES:
        raise ReportError(
            f"{label} line count is {len(data.splitlines())}, expected {EXPECTED_TRACE_LINES}"
        )
    digest = _sha256(data)
    if digest != EXPECTED_TRACE_SHA256:
        raise ReportError(
            f"{label} SHA-256 is {digest}, expected {EXPECTED_TRACE_SHA256}"
        )


def _validate_zig_test_log(
    data: bytes,
    label: str,
    allowed_skips: tuple[str, ...],
) -> ZigTestLogSummary:
    try:
        return validate_zig_test_log(data, label, allowed_skips=allowed_skips)
    except ZigTestLogError as exc:
        raise ReportError(str(exc)) from exc


def _validate_static_aarch64_elf(data: bytes, label: str) -> None:
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ReportError(f"{label} is not an ELF executable")
    if data[4] != 2 or data[5] != 1 or data[6] != 1:
        raise ReportError(f"{label} is not little-endian ELF64")
    if struct.unpack_from("<H", data, 16)[0] != 2:
        raise ReportError(f"{label} is not an ET_EXEC executable")
    if struct.unpack_from("<H", data, 18)[0] != 183:
        raise ReportError(f"{label} is not an AArch64 ELF")
    if struct.unpack_from("<I", data, 20)[0] != 1:
        raise ReportError(f"{label} has an invalid ELF version")
    entry_address = struct.unpack_from("<Q", data, 24)[0]
    program_offset = struct.unpack_from("<Q", data, 32)[0]
    elf_header_size = struct.unpack_from("<H", data, 52)[0]
    program_entry_size = struct.unpack_from("<H", data, 54)[0]
    program_count = struct.unpack_from("<H", data, 56)[0]
    if elf_header_size != 64:
        raise ReportError(f"{label} has an invalid ELF-header size")
    if program_entry_size != 56:
        raise ReportError(f"{label} has an invalid program-header size")
    if program_count == 0 or program_offset < elf_header_size:
        raise ReportError(f"{label} has no valid program-header table")
    end = program_offset + program_entry_size * program_count
    if end > len(data):
        raise ReportError(f"{label} program headers exceed the file")

    has_load_segment = False
    entry_is_executable = False
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        program_type, flags = struct.unpack_from("<II", data, offset)
        file_offset, virtual_address = struct.unpack_from("<QQ", data, offset + 8)
        file_size, memory_size = struct.unpack_from("<QQ", data, offset + 32)
        if program_type == 3:
            raise ReportError(f"{label} is dynamically linked (PT_INTERP present)")
        if program_type == 2:
            raise ReportError(f"{label} is dynamically linked (PT_DYNAMIC present)")
        if program_type != 1:
            continue
        if file_size == 0 or memory_size == 0 or file_size > memory_size:
            raise ReportError(f"{label} has an invalid PT_LOAD segment")
        if file_offset + file_size > len(data):
            raise ReportError(f"{label} PT_LOAD bytes exceed the file")
        has_load_segment = True
        if flags & 0x1 and virtual_address <= entry_address < virtual_address + file_size:
            entry_is_executable = True

    if not has_load_segment:
        raise ReportError(f"{label} has no non-empty PT_LOAD segment")
    if not entry_is_executable:
        raise ReportError(f"{label} entry point is not in an executable PT_LOAD segment")


def _tool_version(executable: pathlib.Path, argument: str, label: str) -> str:
    try:
        completed = subprocess.run(
            [str(executable), argument],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ReportError(f"cannot query {label} version: {executable}") from exc
    try:
        lines = completed.stdout.decode("utf-8", errors="strict").splitlines()
    except UnicodeDecodeError as exc:
        raise ReportError(f"{label} version output is not UTF-8") from exc
    if not lines:
        raise ReportError(f"{label} version output is empty")
    first_line = lines[0]
    if label == "QEMU":
        match = re.fullmatch(
            r"qemu-aarch64 version ([0-9][0-9A-Za-z.+~-]*)(?: .*)?",
            first_line,
        )
        if match is None:
            raise ReportError(f"unexpected QEMU version line: {first_line!r}")
        return match.group(1)
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", first_line) is None:
        raise ReportError(f"unexpected Zig version line: {first_line!r}")
    return first_line


def _source_paths(repo_root: pathlib.Path) -> tuple[pathlib.Path, ...]:
    paths = [repo_root / relative for relative in SOURCE_PREFIX_FILES]
    paths.extend(
        sorted(path for path in (repo_root / "src").rglob("*.zig") if path.is_file())
    )
    paths.extend(repo_root / relative for relative in SOURCE_SUFFIX_FILES)
    return tuple(paths)


def _source_contract(repo_root: pathlib.Path) -> tuple[int, str, str]:
    paths = _source_paths(repo_root)
    hasher = hashlib.sha256()
    header_digest = ""
    for path in paths:
        relative = path.relative_to(repo_root).as_posix()
        data = _read_bounded(path, f"source {relative}")
        hasher.update(relative.encode("utf-8"))
        hasher.update(b"\0")
        hasher.update(data)
        hasher.update(b"\0")
        if relative == "tests/oracle/clay.h":
            header_digest = _sha256(data)
    if not header_digest:
        raise ReportError("pinned Clay header is absent from the source contract")
    if header_digest != EXPECTED_HEADER_SHA256:
        raise ReportError(
            f"pinned Clay header SHA-256 is {header_digest}, "
            f"expected {EXPECTED_HEADER_SHA256}"
        )
    return len(paths), hasher.hexdigest(), header_digest


def create_source_contract(
    repo_root: pathlib.Path,
    expected_build_zig_source: pathlib.Path,
) -> str:
    """Bind live lane sources to the already-compiled build runner."""

    repo_root = repo_root.resolve(strict=True)
    live_build_source = _read_bounded(repo_root / "build.zig", "live build.zig")
    compiled_build_source = _read_bounded(
        expected_build_zig_source,
        "build.zig embedded in the compiled build runner",
    )
    if live_build_source != compiled_build_source:
        raise ReportError(
            f"live build.zig SHA-256 is {_sha256(live_build_source)}, "
            "but the compiled build runner embedded "
            f"{_sha256(compiled_build_source)}"
        )
    return _source_contract(repo_root)[1]


def _read_expected_source_file(path: pathlib.Path) -> str:
    data = _read_bounded(path, "pre-gate source contract")
    if re.fullmatch(rb"[0-9a-f]{64}\n", data) is None:
        raise ReportError(
            "pre-gate source contract must be 64 lowercase hex characters "
            "followed by one newline"
        )
    return data[:-1].decode("ascii")


def create_report(
    repo_root: pathlib.Path,
    qemu: pathlib.Path,
    zig: pathlib.Path,
    c_trace_path: pathlib.Path,
    zig_trace_path: pathlib.Path,
    module_tests_log_path: pathlib.Path,
    manifest_tests_log_path: pathlib.Path,
    c_executable_path: pathlib.Path,
    zig_executable_path: pathlib.Path,
    module_tests_executable_path: pathlib.Path,
    manifest_tests_executable_path: pathlib.Path,
    expected_source_sha256: str,
) -> str:
    qemu = qemu.resolve(strict=True)
    zig = zig.resolve(strict=True)
    for label, executable in (("QEMU", qemu), ("Zig", zig)):
        if any(character.isspace() for character in str(executable)):
            raise ReportError(f"resolved {label} path contains whitespace")

    c_trace = _read_bounded(c_trace_path, "C trace")
    zig_trace = _read_bounded(zig_trace_path, "Zig trace")
    _validate_trace(c_trace, "C trace")
    _validate_trace(zig_trace, "Zig trace")
    if c_trace != zig_trace:
        raise ReportError("C and Zig traces differ")

    module_tests_log = _read_bounded(module_tests_log_path, "module-tests log")
    manifest_tests_log = _read_bounded(manifest_tests_log_path, "manifest-tests log")
    module_tests = _validate_zig_test_log(
        module_tests_log,
        "module-tests log",
        MODULE_ALLOWED_SKIPS,
    )
    manifest_tests = _validate_zig_test_log(
        manifest_tests_log,
        "manifest-tests log",
        MANIFEST_ALLOWED_SKIPS,
    )

    qemu_bytes = _read_bounded(qemu, "QEMU executable", MAX_EXECUTABLE_BYTES)
    zig_bytes = _read_bounded(zig, "Zig executable", MAX_EXECUTABLE_BYTES)
    c_executable = _read_bounded(
        c_executable_path, "C executable", MAX_EXECUTABLE_BYTES
    )
    zig_executable = _read_bounded(
        zig_executable_path, "Zig executable artifact", MAX_EXECUTABLE_BYTES
    )
    module_tests_executable = _read_bounded(
        module_tests_executable_path,
        "module-tests executable artifact",
        MAX_EXECUTABLE_BYTES,
    )
    manifest_tests_executable = _read_bounded(
        manifest_tests_executable_path,
        "manifest-tests executable artifact",
        MAX_EXECUTABLE_BYTES,
    )
    _validate_static_aarch64_elf(c_executable, "C executable")
    _validate_static_aarch64_elf(zig_executable, "Zig executable artifact")
    _validate_static_aarch64_elf(
        module_tests_executable, "module-tests executable artifact"
    )
    _validate_static_aarch64_elf(
        manifest_tests_executable, "manifest-tests executable artifact"
    )

    source_count, source_digest, header_digest = _source_contract(
        repo_root.resolve(strict=True)
    )
    if not re.fullmatch(r"[0-9a-f]{64}", expected_source_sha256):
        raise ReportError("expected source SHA-256 must be 64 lowercase hex characters")
    if source_digest != expected_source_sha256:
        raise ReportError(
            f"live source SHA-256 is {source_digest}, "
            f"embedded build contract expected {expected_source_sha256}"
        )
    qemu_version = _tool_version(qemu, "--version", "QEMU")
    zig_version = _tool_version(zig, "version", "Zig")
    return (
        f"qemu-execution schema={SCHEMA} identity=hash-default "
        f"execution=emulated executor={qemu} "
        f"qemu_version={qemu_version} qemu_sha256={_sha256(qemu_bytes)} "
        f"zig_executable={zig} zig_version={zig_version} "
        f"zig_sha256={_sha256(zig_bytes)} "
        "target=aarch64-linux-musl arch=aarch64 os=linux abi=musl endian=little "
        "target_cpu=baseline qemu_cpu=max optimize=Debug linkage=static "
        f"upstream_commit={UPSTREAM_COMMIT} clay_header_sha256={header_digest} "
        f"source_files={source_count} source_sha256={source_digest} "
        f"c_executable_sha256={_sha256(c_executable)} "
        f"zig_executable_sha256={_sha256(zig_executable)} "
        f"module_tests_executable_sha256={_sha256(module_tests_executable)} "
        f"manifest_tests_executable_sha256={_sha256(manifest_tests_executable)} "
        f"module_tests_total={module_tests.total} "
        f"module_tests_passed={module_tests.passed} "
        f"module_tests_skipped={module_tests.skipped} "
        f"module_tests_log_sha256={module_tests.sha256} "
        f"manifest_tests_total={manifest_tests.total} "
        f"manifest_tests_passed={manifest_tests.passed} "
        f"manifest_tests_skipped={manifest_tests.skipped} "
        f"manifest_tests_log_sha256={manifest_tests.sha256} "
        f"lines={EXPECTED_TRACE_LINES} bytes={EXPECTED_TRACE_BYTES} "
        f"trace_sha256={EXPECTED_TRACE_SHA256} certification=false "
        "physical_machine_proof=false backlog_closed=false"
    )


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    source_parser = subparsers.add_parser("source-contract")
    source_parser.add_argument("--repo-root", type=pathlib.Path, required=True)
    source_parser.add_argument(
        "--expected-build-zig-source", type=pathlib.Path, required=True
    )

    report_parser = subparsers.add_parser("report")
    report_parser.add_argument("--repo-root", type=pathlib.Path, required=True)
    report_parser.add_argument("--qemu", type=pathlib.Path, required=True)
    report_parser.add_argument("--zig", type=pathlib.Path, required=True)
    report_parser.add_argument("--c-trace", type=pathlib.Path, required=True)
    report_parser.add_argument("--zig-trace", type=pathlib.Path, required=True)
    report_parser.add_argument("--module-tests-log", type=pathlib.Path, required=True)
    report_parser.add_argument("--manifest-tests-log", type=pathlib.Path, required=True)
    report_parser.add_argument("--c-executable", type=pathlib.Path, required=True)
    report_parser.add_argument("--zig-executable", type=pathlib.Path, required=True)
    report_parser.add_argument(
        "--module-tests-executable", type=pathlib.Path, required=True
    )
    report_parser.add_argument(
        "--manifest-tests-executable", type=pathlib.Path, required=True
    )
    report_parser.add_argument(
        "--expected-source-file", type=pathlib.Path, required=True
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        if args.command == "source-contract":
            print(
                create_source_contract(
                    args.repo_root,
                    args.expected_build_zig_source,
                )
            )
            return 0
        report = create_report(
            args.repo_root,
            args.qemu,
            args.zig,
            args.c_trace,
            args.zig_trace,
            args.module_tests_log,
            args.manifest_tests_log,
            args.c_executable,
            args.zig_executable,
            args.module_tests_executable,
            args.manifest_tests_executable,
            _read_expected_source_file(args.expected_source_file),
        )
    except ReportError as exc:
        raise SystemExit(f"aarch64 QEMU report rejected: {exc}") from exc
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
