#!/usr/bin/env python3
"""Fail closed when the ZL-202 certification DAG loses proof integrity.

This checker deliberately validates the small, marker-delimited orchestration
block in ``build.zig`` rather than attempting to parse all Zig syntax.  The
markers make the evidence-sensitive surface explicit, while balanced-delimiter
extraction and exact dependency checks prevent nearby build changes from being
mistaken for certification gates.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import NoReturn


BEGIN_MARKER = "// BEGIN AARCH64 HASH CERTIFICATION CONTRACT"
END_MARKER = "// END AARCH64 HASH CERTIFICATION CONTRACT"


class ContractError(RuntimeError):
    """Raised when build.zig no longer satisfies the certification contract."""


def _fail(message: str) -> NoReturn:
    raise ContractError(message)


def _require_once(text: str, pattern: str, label: str, *, flags: int = 0) -> re.Match[str]:
    matches = list(re.finditer(pattern, text, flags))
    if len(matches) != 1:
        _fail(f"{label}: expected exactly one match, found {len(matches)}")
    return matches[0]


def _matching_delimiter(text: str, opening: int, left: str, right: str) -> int:
    """Return the matching delimiter while ignoring Zig strings/comments."""

    if opening >= len(text) or text[opening] != left:
        _fail(f"internal parser error: expected {left!r} at offset {opening}")

    depth = 0
    state = "code"
    index = opening
    while index < len(text):
        character = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""

        if state == "line-comment":
            if character == "\n":
                state = "code"
        elif state == "string":
            if character == "\\":
                index += 1
            elif character == '"':
                state = "code"
        elif state == "character":
            if character == "\\":
                index += 1
            elif character == "'":
                state = "code"
        elif character == "/" and following == "/":
            state = "line-comment"
            index += 1
        elif character == '"':
            state = "string"
        elif character == "'":
            state = "character"
        elif character == left:
            depth += 1
        elif character == right:
            depth -= 1
            if depth == 0:
                return index

        index += 1

    _fail(f"unterminated {left}{right} pair at offset {opening}")


def _strip_line_comments(text: str) -> str:
    """Blank Zig line comments without changing offsets or quoted strings."""

    result = list(text)
    state = "code"
    index = 0
    while index < len(text):
        character = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "string":
            if character == "\\":
                index += 1
            elif character == '"':
                state = "code"
        elif state == "character":
            if character == "\\":
                index += 1
            elif character == "'":
                state = "code"
        elif character == '"':
            state = "string"
        elif character == "'":
            state = "character"
        elif character == "/" and following == "/":
            while index < len(text) and text[index] != "\n":
                result[index] = " "
                index += 1
            continue
        index += 1
    return "".join(result)


def _curly_depths(text: str) -> list[int]:
    """Return curly-brace depth before each character offset in Zig-like source."""

    depths = [0] * (len(text) + 1)
    depth = 0
    state = "code"
    escaped = False
    for index, character in enumerate(text):
        depths[index] = depth
        following = text[index + 1] if index + 1 < len(text) else ""

        if state == "line-comment":
            if character == "\n":
                state = "code"
            continue
        if state in ("string", "character"):
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif (state == "string" and character == '"') or (
                state == "character" and character == "'"
            ):
                state = "code"
            continue
        if character == "/" and following == "/":
            state = "line-comment"
        elif character == '"':
            state = "string"
        elif character == "'":
            state = "character"
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth < 0:
                _fail("unexpected closing brace while checking statement depth")

    depths[len(text)] = depth
    if depth != 0:
        _fail("unbalanced braces while checking statement depth")
    return depths


def _is_direct_top_level_statement(
    text: str,
    offset: int,
    depths: list[int] | None = None,
) -> bool:
    """Return whether offset begins an unconditional statement in this block."""

    if depths is None:
        depths = _curly_depths(text)
    if depths[offset] != 0:
        return False
    previous = offset - 1
    while previous >= 0 and text[previous].isspace():
        previous -= 1
    return previous < 0 or text[previous] in ";}"


def _require_top_level_once(
    text: str,
    pattern: str,
    label: str,
    *,
    flags: int = 0,
) -> re.Match[str]:
    match = _require_once(text, pattern, label, flags=flags)
    if not _is_direct_top_level_statement(text, match.start()):
        _fail(f"{label}: must be an active top-level statement")
    return match


def _extract_if(text: str, start: int, label: str) -> tuple[str, str, int]:
    match = re.search(r"\bif\s*\(", text[start:])
    if match is None:
        _fail(f"{label}: missing if condition")
    open_paren = start + match.end() - 1
    close_paren = _matching_delimiter(text, open_paren, "(", ")")
    open_brace = close_paren + 1
    while open_brace < len(text) and text[open_brace].isspace():
        open_brace += 1
    if open_brace >= len(text) or text[open_brace] != "{":
        _fail(f"{label}: condition is not followed by a block")
    close_brace = _matching_delimiter(text, open_brace, "{", "}")
    return text[open_paren + 1 : close_paren], text[open_brace + 1 : close_brace], close_brace


def _extract_else(text: str, if_close: int, label: str) -> tuple[str, int]:
    index = if_close + 1
    while index < len(text) and text[index].isspace():
        index += 1
    if not text.startswith("else", index):
        _fail(f"{label}: missing required else branch")
    after_else = index + len("else")
    if after_else < len(text) and (text[after_else].isalnum() or text[after_else] == "_"):
        _fail(f"{label}: malformed else branch")
    index = after_else
    while index < len(text) and text[index].isspace():
        index += 1
    if index >= len(text) or text[index] != "{":
        _fail(f"{label}: else must contain a block")
    close_brace = _matching_delimiter(text, index, "{", "}")
    return text[index + 1 : close_brace], close_brace


def _extract_contract(source: str) -> str:
    begin_matches = list(
        re.finditer(rf"(?m)^[ \t]*{re.escape(BEGIN_MARKER)}[ \t]*$", source)
    )
    end_matches = list(re.finditer(rf"(?m)^[ \t]*{re.escape(END_MARKER)}[ \t]*$", source))
    if len(begin_matches) != 1:
        _fail(f"contract start marker must occur exactly once as a full line: {BEGIN_MARKER}")
    if len(end_matches) != 1:
        _fail(f"contract end marker must occur exactly once as a full line: {END_MARKER}")
    begin = begin_matches[0].end()
    end = end_matches[0].start()
    if end <= begin:
        _fail("contract markers are reversed")
    return source[begin:end]


def _require_build_options(source: str) -> None:
    options = {
        "aarch64_evidence_out": "aarch64-evidence-out",
        "aarch64_provenance": "aarch64-provenance",
        "aarch64_runner_record": "aarch64-runner-record",
    }
    for variable, option in options.items():
        _require_once(
            source,
            rf"const\s+{variable}\s*=\s*b\.option\(\s*\[\]const\s+u8\s*,\s*\"{option}\"\s*,",
            f"required -D{option} build option",
            flags=re.DOTALL,
        )


def _require_embedded_build_hash(source: str) -> None:
    _require_once(
        source,
        r"const\s+embedded_build_zig_sha256\s*=\s*blk:\s*\{\s*"
        r"var\s+digest:\s*\[std\.crypto\.hash\.sha2\.Sha256\.digest_length\]u8\s*=\s*undefined\s*;\s*"
        r"std\.crypto\.hash\.sha2\.Sha256\.hash\(\s*@embedFile\(\"build\.zig\"\)\s*,\s*&digest\s*,\s*\.\{\}\s*\)\s*;\s*"
        r"break\s+:blk\s+std\.fmt\.bytesToHex\(\s*digest\s*,\s*\.lower\s*\)\s*;\s*\}\s*;",
        "compile-time embedded build.zig SHA-256",
        flags=re.DOTALL,
    )


def _require_outer_guard(condition: str) -> None:
    normalized = " ".join(condition.split())
    expected = (
        "builtin.target.cpu.arch == .aarch64 and "
        "target.result.cpu.arch == .aarch64 and "
        "target.query.isNative() and optimize == .Debug"
    )
    if normalized != expected:
        _fail(f"certification host/target/native/Debug guard differs; found {normalized!r}")


def _require_fresh_runs(success: str) -> None:
    declarations = (
        (
            "run_native_aarch64_host",
            r"const\s+run_native_aarch64_host\s*=\s*b\.addRunArtifact\(native_aarch64_host_checker\)\s*;",
        ),
        (
            "run_aarch64_header_checker",
            r"const\s+run_aarch64_header_checker\s*=\s*b\.addRunArtifact\(header_checker\)\s*;",
        ),
        (
            "run_aarch64_manifest_tests",
            r"const\s+run_aarch64_manifest_tests\s*=\s*b\.addRunArtifact\(ordinary_manifest_tests\)\s*;",
        ),
        (
            "run_aarch64_module_tests",
            r"const\s+run_aarch64_module_tests\s*=\s*b\.addRunArtifact\(module_tests\)\s*;",
        ),
        (
            "run_aarch64_hash_c",
            r"const\s+run_aarch64_hash_c\s*=\s*b\.addRunArtifact\(hash_default_c_oracle\)\s*;",
        ),
        (
            "run_aarch64_hash_zig",
            r"const\s+run_aarch64_hash_zig\s*=\s*b\.addRunArtifact\(hash_default_zig_oracle\)\s*;",
        ),
        (
            "run_aarch64_hash_compare",
            r"const\s+run_aarch64_hash_compare\s*=\s*b\.addRunArtifact\(compare_oracles\)\s*;",
        ),
    )
    positions: list[int] = []
    for variable, pattern in declarations:
        match = _require_top_level_once(success, pattern, f"fresh {variable}")
        positions.append(match.start())
        _require_top_level_once(
            success,
            rf"\b{variable}\.has_side_effects\s*=\s*true\s*;",
            f"side-effecting {variable}",
        )
    if positions != sorted(positions):
        _fail("fresh certification runs are not declared in contract order")

    writer = _require_top_level_once(
        success,
        r"const\s+capture_evidence\s*=\s*b\.addSystemCommand\(\s*&\.\{(?P<command>.*?)\}\s*\)\s*;",
        "fresh final evidence writer",
        flags=re.DOTALL,
    )
    if writer.start() <= positions[-1]:
        _fail("final evidence writer must be declared after the fresh comparator")
    command = writer.group("command")
    if re.fullmatch(
        r'\s*"python3"\s*,\s*"-B"\s*,\s*'
        r'"scripts/aarch64_hash_evidence\.py"\s*,\s*"capture"\s*,\s*'
        r'"--repo-root"\s*,\s*b\.pathFromRoot\(\s*"\."\s*\)\s*,\s*'
        r'"--output"\s*,\s*aarch64_evidence_out\.\?\s*,\s*'
        r'"--header"\s*,?\s*',
        command,
        re.DOTALL,
    ) is None:
        _fail("final evidence writer command arguments differ")
    _require_top_level_once(
        success,
        r"\bcapture_evidence\.has_side_effects\s*=\s*true\s*;",
        "side-effecting final evidence writer",
    )


def _require_source_snapshot(success: str) -> None:
    snapshot = _require_top_level_once(
        success,
        r"const\s+capture_source_snapshot\s*=\s*b\.addSystemCommand\(\s*&\.\{(?P<command>.*?)\}\s*\)\s*;",
        "pre-gate source snapshot command",
        flags=re.DOTALL,
    )
    command = snapshot.group("command")
    string_tokens = re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', command)
    expected_tokens = [
        "python3",
        "-B",
        "scripts/aarch64_hash_evidence.py",
        "snapshot",
        "--repo-root",
        ".",
        "--expected-build-zig-sha256",
        "--output",
    ]
    if string_tokens != expected_tokens:
        _fail(
            "pre-gate source snapshot command tokens differ; "
            f"expected {expected_tokens!r}, found {string_tokens!r}"
        )
    _require_once(
        command,
        r'"--repo-root"\s*,\s*b\.pathFromRoot\("\."\)',
        "snapshot repository-root binding",
    )
    _require_once(
        command,
        r'"--expected-build-zig-sha256"\s*,\s*embedded_build_zig_sha256\[0\.\.\]',
        "snapshot embedded build.zig digest binding",
    )
    _require_top_level_once(
        success,
        r"\bcapture_source_snapshot\.has_side_effects\s*=\s*true\s*;",
        "side-effecting source snapshot",
    )
    output = _require_top_level_once(
        success,
        r"const\s+certification_source_snapshot\s*=\s*capture_source_snapshot\.addOutputFileArg\(\s*"
        r'"aarch64-certification-input-snapshot\.json"\s*,?\s*\)\s*;',
        "generated certification source snapshot",
        flags=re.DOTALL,
    )
    if snapshot.start() >= output.start():
        _fail("source snapshot output must be declared after its command")


def _require_runner_preflight(success: str) -> None:
    preflight = _require_top_level_once(
        success,
        r"const\s+capture_runner_preflight\s*=\s*b\.addSystemCommand\(\s*&\.\{(?P<command>.*?)\}\s*\)\s*;",
        "pre-gate runner provenance command",
        flags=re.DOTALL,
    )
    command = preflight.group("command")
    string_tokens = re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', command)
    expected_tokens = [
        "python3",
        "-B",
        "scripts/aarch64_hash_evidence.py",
        "runner-preflight",
        "--provenance",
    ]
    if string_tokens != expected_tokens:
        _fail(
            "pre-gate runner provenance command tokens differ; "
            f"expected {expected_tokens!r}, found {string_tokens!r}"
        )
    if re.fullmatch(
        r'\s*"python3"\s*,\s*"-B"\s*,\s*'
        r'"scripts/aarch64_hash_evidence\.py"\s*,\s*'
        r'"runner-preflight"\s*,\s*"--provenance"\s*,?\s*',
        command,
        re.DOTALL,
    ) is None:
        _fail("pre-gate runner provenance command contains unexpected arguments")

    bindings = _require_top_level_once(
        success,
        r"capture_runner_preflight\.addFileArg\(\s*\.\{\s*\.cwd_relative\s*=\s*aarch64_provenance\.\?\s*\}\s*\)\s*;\s*"
        r"capture_runner_preflight\.addArg\(\s*\"--runner-record\"\s*\)\s*;\s*"
        r"capture_runner_preflight\.addFileArg\(\s*\.\{\s*\.cwd_relative\s*=\s*aarch64_runner_record\.\?\s*\}\s*\)\s*;\s*"
        r"capture_runner_preflight\.addArg\(\s*\"--output\"\s*\)\s*;",
        "runner provenance/record/output bindings",
        flags=re.DOTALL,
    )
    if preflight.start() >= bindings.start():
        _fail("runner preflight bindings must follow their command")

    _require_top_level_once(
        success,
        r"\bcapture_runner_preflight\.has_side_effects\s*=\s*true\s*;",
        "side-effecting runner preflight",
    )
    output = _require_top_level_once(
        success,
        r"const\s+certification_runner_preflight\s*=\s*capture_runner_preflight\.addOutputFileArg\(\s*"
        r'"aarch64-runner-preflight\.json"\s*,?\s*\)\s*;',
        "generated runner preflight record",
        flags=re.DOTALL,
    )
    if bindings.start() >= output.start():
        _fail("runner preflight output must be declared after its input bindings")

    calls = re.findall(
        r"\bcapture_runner_preflight\.(addFileArg|addArg|addOutputFileArg)\s*\(",
        success,
    )
    expected_calls = [
        "addFileArg",
        "addArg",
        "addFileArg",
        "addArg",
        "addOutputFileArg",
    ]
    if calls != expected_calls:
        _fail(
            "runner preflight argument/output calls differ; "
            f"expected {expected_calls!r}, found {calls!r}"
        )


def _require_outputs_and_comparator(success: str) -> None:
    _require_top_level_once(
        success,
        r"const\s+native_aarch64_host_output\s*=\s*run_native_aarch64_host\.captureStdOut\(\s*\.\{\s*\.basename\s*=\s*\"aarch64-cert-native-host\.txt\"\s*,\s*\}\s*\)\s*;",
        "fresh native-host trace capture",
        flags=re.DOTALL,
    )
    _require_top_level_once(
        success,
        r"const\s+aarch64_manifest_tests_log\s*=\s*run_aarch64_manifest_tests\.captureStdErr\(\s*\.\{\s*\.basename\s*=\s*\"aarch64-cert-manifest-tests\.log\"\s*,\s*\}\s*\)\s*;",
        "fresh ordinary-manifest test log capture",
        flags=re.DOTALL,
    )
    _require_top_level_once(
        success,
        r"const\s+aarch64_module_tests_log\s*=\s*run_aarch64_module_tests\.captureStdErr\(\s*\.\{\s*\.basename\s*=\s*\"aarch64-cert-module-tests\.log\"\s*,\s*\}\s*\)\s*;",
        "fresh module test log capture",
        flags=re.DOTALL,
    )
    _require_top_level_once(
        success,
        r"const\s+aarch64_hash_c_output\s*=\s*run_aarch64_hash_c\.captureStdOut\(",
        "fresh C trace capture",
    )
    _require_top_level_once(
        success,
        r"const\s+aarch64_hash_zig_output\s*=\s*run_aarch64_hash_zig\.captureStdOut\(",
        "fresh Zig trace capture",
    )
    comparator_matches = list(
        re.finditer(
            r"run_aarch64_hash_compare\.addFileArg\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*;",
            success,
        )
    )
    depths = _curly_depths(success)
    if any(
        not _is_direct_top_level_statement(success, match.start(), depths)
        for match in comparator_matches
    ):
        _fail("fresh comparator inputs must be active top-level statements")
    comparator_args = [match.group(1) for match in comparator_matches]
    if comparator_args != ["aarch64_hash_c_output", "aarch64_hash_zig_output"]:
        _fail(
            "fresh comparator inputs must be exactly C then Zig certification outputs; "
            f"found {comparator_args!r}"
        )


def _require_dependency_dag(success: str) -> None:
    dependency_matches = list(
        re.finditer(
            r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\.step\.dependOn\(\s*&([A-Za-z_][A-Za-z0-9_]*)\.step\s*\)\s*;\s*$",
            success,
        )
    )
    depths = _curly_depths(success)
    if any(
        not _is_direct_top_level_statement(success, match.start(1), depths)
        for match in dependency_matches
    ):
        _fail("certification dependency DAG contains a non-top-level edge")
    dependencies = [(match.group(1), match.group(2)) for match in dependency_matches]
    expected = [
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
    ]
    if dependencies != expected:
        _fail(f"certification dependency DAG differs; expected {expected!r}, found {dependencies!r}")

    top_level_matches = list(
        re.finditer(
            r"(?m)^\s*(aarch64_hash_certify_step)\.dependOn\(\s*&([A-Za-z_][A-Za-z0-9_]*)\.step\s*\)\s*;\s*$",
            success,
        )
    )
    if any(
        not _is_direct_top_level_statement(success, match.start(1), depths)
        for match in top_level_matches
    ):
        _fail("final writer dependency must be an active top-level statement")
    top_level = [match.group(2) for match in top_level_matches]
    if top_level != ["capture_evidence"]:
        _fail(f"final writer must be the exclusive successful top-level dependency; found {top_level!r}")


def _require_failure_branch(
    branch: str,
    *,
    variable: str,
    dependency: str,
    message: str,
    label: str,
) -> None:
    _require_top_level_once(
        branch,
        rf"const\s+{variable}\s*=\s*b\.addFail\(\s*\"{re.escape(message)}\"\s*,?\s*\)\s*;",
        f"{label} fail step",
        flags=re.DOTALL,
    )
    dependency_matches = list(
        re.finditer(
            r"(aarch64_hash_certify_step)\.dependOn\(\s*&([A-Za-z_][A-Za-z0-9_]*)\.step\s*\)\s*;",
            branch,
        )
    )
    depths = _curly_depths(branch)
    if any(
        not _is_direct_top_level_statement(branch, match.start(1), depths)
        for match in dependency_matches
    ):
        _fail(f"{label} dependency must be an active top-level statement")
    dependencies = [match.group(2) for match in dependency_matches]
    if dependencies != [dependency]:
        _fail(f"{label} dependency differs; expected {[dependency]!r}, found {dependencies!r}")


def _require_global_certify_dependencies(source: str) -> None:
    dependencies = re.findall(
        r"aarch64_hash_certify_step\.dependOn\(\s*&([A-Za-z_][A-Za-z0-9_]*)\.step\s*\)\s*;",
        source,
    )
    expected = ["capture_evidence", "missing_evidence_inputs", "non_native_aarch64"]
    if dependencies != expected:
        _fail(
            "global aarch64-hash-certify dependencies differ; "
            f"expected {expected!r}, found {dependencies!r}"
        )


def _require_exact_capture_calls(
    success: str,
    constructor: re.Match[str],
) -> list[str]:
    expected = [
        ("addFileArg", r'\s*b\.path\(\s*"tests/oracle/clay\.h"\s*\)\s*'),
        ("addArg", r'\s*"--source-snapshot"\s*'),
        ("addFileArg", r"\s*certification_source_snapshot\s*"),
        ("addArg", r'\s*"--c-trace"\s*'),
        ("addFileArg", r"\s*aarch64_hash_c_output\s*"),
        ("addArg", r'\s*"--zig-trace"\s*'),
        ("addFileArg", r"\s*aarch64_hash_zig_output\s*"),
        ("addArg", r'\s*"--native-host-trace"\s*'),
        ("addFileArg", r"\s*native_aarch64_host_output\s*"),
        ("addArg", r'\s*"--runner-preflight"\s*'),
        ("addFileArg", r"\s*certification_runner_preflight\s*"),
        ("addArg", r'\s*"--module-tests-log"\s*'),
        ("addFileArg", r"\s*aarch64_module_tests_log\s*"),
        ("addArg", r'\s*"--ordinary-manifest-tests-log"\s*'),
        ("addFileArg", r"\s*aarch64_manifest_tests_log\s*"),
        (
            "addArgs",
            r'\s*&\.\{\s*'
            r'"--zig-exe"\s*,\s*b\.graph\.zig_exe\s*,\s*'
            r'"--optimize"\s*,\s*@tagName\(\s*optimize\s*\)\s*,\s*'
            r'"--target-triple"\s*,\s*target\.result\.zigTriple\(\s*b\.allocator\s*\)\s*'
            r'catch\s+@panic\(\s*"OOM"\s*\)\s*,\s*'
            r'"--target-arch"\s*,\s*@tagName\(\s*target\.result\.cpu\.arch\s*\)\s*,\s*'
            r'"--target-os"\s*,\s*@tagName\(\s*target\.result\.os\.tag\s*\)\s*,\s*'
            r'"--target-abi"\s*,\s*@tagName\(\s*target\.result\.abi\s*\)\s*,\s*'
            r'"--target-endian"\s*,\s*@tagName\(\s*target\.result\.cpu\.arch\.endian\(\s*\)\s*\)\s*,\s*'
            r'"--target-cpu-model"\s*,\s*target\.result\.cpu\.model\.name\s*,\s*'
            r'"--c-oracle-exe"\s*,?\s*\}\s*',
        ),
        ("addFileArg", r"\s*hash_default_c_oracle\.getEmittedBin\(\s*\)\s*"),
        ("addArg", r'\s*"--zig-oracle-exe"\s*'),
        ("addFileArg", r"\s*hash_default_zig_oracle\.getEmittedBin\(\s*\)\s*"),
        ("addArg", r'\s*"--comparator-exe"\s*'),
        ("addFileArg", r"\s*compare_oracles\.getEmittedBin\(\s*\)\s*"),
        ("addArg", r'\s*"--module-tests-exe"\s*'),
        ("addFileArg", r"\s*module_tests\.getEmittedBin\(\s*\)\s*"),
        ("addArg", r'\s*"--ordinary-manifest-tests-exe"\s*'),
        ("addFileArg", r"\s*ordinary_manifest_tests\.getEmittedBin\(\s*\)\s*"),
        ("addArg", r'\s*"--native-host-guard-exe"\s*'),
        ("addFileArg", r"\s*native_aarch64_host_checker\.getEmittedBin\(\s*\)\s*"),
        ("addArg", r'\s*"--header-checker-exe"\s*'),
        ("addFileArg", r"\s*header_checker\.getEmittedBin\(\s*\)\s*"),
    ]

    matches = list(
        re.finditer(
            r"\bcapture_evidence\.(addArg|addArgs|addFileArg)\s*\(",
            success,
        )
    )
    depths = _curly_depths(success)
    calls: list[tuple[str, str]] = []
    statements: list[str] = []
    for match in matches:
        if match.start() <= constructor.end():
            _fail("final capture argument call precedes its constructor")
        if not _is_direct_top_level_statement(success, match.start(), depths):
            _fail("final capture argument calls must be active top-level statements")
        open_paren = match.end() - 1
        close_paren = _matching_delimiter(success, open_paren, "(", ")")
        statement_end = close_paren + 1
        while statement_end < len(success) and success[statement_end].isspace():
            statement_end += 1
        if statement_end >= len(success) or success[statement_end] != ";":
            _fail("final capture argument call is not a complete statement")
        calls.append((match.group(1), success[open_paren + 1 : close_paren]))
        statements.append(success[match.start() : statement_end + 1])

    if len(calls) != len(expected):
        _fail(
            "final capture argument call count differs; "
            f"expected {len(expected)}, found {len(calls)}"
        )
    for index, ((method, arguments), (expected_method, argument_pattern)) in enumerate(
        zip(calls, expected, strict=True),
        start=1,
    ):
        if method != expected_method or re.fullmatch(
            argument_pattern,
            arguments,
            re.DOTALL,
        ) is None:
            _fail(f"final capture argument call {index} differs")
    return statements


def _require_cli_bindings(success: str) -> None:
    patterns = {
        "--output": r'"--output"\s*,\s*aarch64_evidence_out\.\?',
        "--header": r'"--header"[\s\S]*?capture_evidence\.addFileArg\(b\.path\("tests/oracle/clay\.h"\)\)\s*;',
        "--source-snapshot": r'capture_evidence\.addArg\("--source-snapshot"\)\s*;\s*capture_evidence\.addFileArg\(certification_source_snapshot\)\s*;',
        "--runner-preflight": r'capture_evidence\.addArg\("--runner-preflight"\)\s*;\s*capture_evidence\.addFileArg\(certification_runner_preflight\)\s*;',
        "--module-tests-log": r'capture_evidence\.addArg\("--module-tests-log"\)\s*;\s*capture_evidence\.addFileArg\(aarch64_module_tests_log\)\s*;',
        "--ordinary-manifest-tests-log": r'capture_evidence\.addArg\("--ordinary-manifest-tests-log"\)\s*;\s*capture_evidence\.addFileArg\(aarch64_manifest_tests_log\)\s*;',
        "--c-trace": r'capture_evidence\.addArg\("--c-trace"\)\s*;\s*capture_evidence\.addFileArg\(aarch64_hash_c_output\)\s*;',
        "--zig-trace": r'capture_evidence\.addArg\("--zig-trace"\)\s*;\s*capture_evidence\.addFileArg\(aarch64_hash_zig_output\)\s*;',
        "--native-host-trace": r'capture_evidence\.addArg\("--native-host-trace"\)\s*;\s*capture_evidence\.addFileArg\(native_aarch64_host_output\)\s*;',
        "--zig-exe": r'"--zig-exe"\s*,\s*b\.graph\.zig_exe',
        "--optimize": r'"--optimize"\s*,\s*@tagName\(optimize\)',
        "--target-triple": r'"--target-triple"\s*,\s*target\.result\.zigTriple\(b\.allocator\)',
        "--target-arch": r'"--target-arch"\s*,\s*@tagName\(target\.result\.cpu\.arch\)',
        "--target-os": r'"--target-os"\s*,\s*@tagName\(target\.result\.os\.tag\)',
        "--target-abi": r'"--target-abi"\s*,\s*@tagName\(target\.result\.abi\)',
        "--target-endian": r'"--target-endian"\s*,\s*@tagName\(target\.result\.cpu\.arch\.endian\(\)\)',
        "--target-cpu-model": r'"--target-cpu-model"\s*,\s*target\.result\.cpu\.model\.name',
        "--c-oracle-exe": r'"--c-oracle-exe"[\s\S]*?capture_evidence\.addFileArg\(hash_default_c_oracle\.getEmittedBin\(\)\)\s*;',
        "--zig-oracle-exe": r'capture_evidence\.addArg\("--zig-oracle-exe"\)\s*;\s*capture_evidence\.addFileArg\(hash_default_zig_oracle\.getEmittedBin\(\)\)\s*;',
        "--comparator-exe": r'capture_evidence\.addArg\("--comparator-exe"\)\s*;\s*capture_evidence\.addFileArg\(compare_oracles\.getEmittedBin\(\)\)\s*;',
        "--module-tests-exe": r'capture_evidence\.addArg\("--module-tests-exe"\)\s*;\s*capture_evidence\.addFileArg\(module_tests\.getEmittedBin\(\)\)\s*;',
        "--ordinary-manifest-tests-exe": r'capture_evidence\.addArg\("--ordinary-manifest-tests-exe"\)\s*;\s*capture_evidence\.addFileArg\(ordinary_manifest_tests\.getEmittedBin\(\)\)\s*;',
        "--native-host-guard-exe": r'capture_evidence\.addArg\("--native-host-guard-exe"\)\s*;\s*capture_evidence\.addFileArg\(native_aarch64_host_checker\.getEmittedBin\(\)\)\s*;',
        "--header-checker-exe": r'capture_evidence\.addArg\("--header-checker-exe"\)\s*;\s*capture_evidence\.addFileArg\(header_checker\.getEmittedBin\(\)\)\s*;',
    }
    capture_constructor = _require_top_level_once(
        success,
        r"const\s+capture_evidence\s*=\s*b\.addSystemCommand\(\s*&\.\{(?P<command>.*?)\}\s*\)\s*;",
        "final capture command for CLI bindings",
        flags=re.DOTALL,
    )
    capture_command = capture_constructor.group("command")
    _require_once(
        capture_command,
        r'"--repo-root"\s*,\s*b\.pathFromRoot\("\."\)',
        "--repo-root CLI binding",
    )
    for option, pattern in patterns.items():
        _require_once(success, pattern, f"{option} CLI binding", flags=re.DOTALL)
    capture_statements = _require_exact_capture_calls(success, capture_constructor)
    if '"--provenance"' in capture_command or any(
        '"--provenance"' in statement for statement in capture_statements
    ):
        _fail("final capture must consume the runner preflight, not provenance directly")


def check_build_contract(source: str) -> None:
    """Validate the marker-delimited AArch64 certification build contract."""

    active_source = _strip_line_comments(source)
    _require_build_options(active_source)
    _require_embedded_build_hash(active_source)
    _require_once(
        active_source,
        r"const\s+aarch64_hash_certify_step\s*=\s*b\.step\(\s*\"aarch64-hash-certify\"\s*,",
        "global aarch64-hash-certify build step",
        flags=re.DOTALL,
    )
    contract = _strip_line_comments(_extract_contract(source))
    _require_top_level_once(
        contract,
        r"const\s+aarch64_hash_certify_step\s*=\s*b\.step\(\s*\"aarch64-hash-certify\"\s*,",
        "aarch64-hash-certify build step",
        flags=re.DOTALL,
    )

    step = contract.index("const aarch64_hash_certify_step")
    outer_condition, outer_body, outer_close = _extract_if(
        contract, step, "certification host guard"
    )
    _require_outer_guard(outer_condition)

    inner_anchor = outer_body.find("if (aarch64_evidence_out")
    if inner_anchor < 0:
        _fail("missing required evidence-output/provenance/runner-record guard")
    if not _is_direct_top_level_statement(outer_body, inner_anchor):
        _fail("evidence-output/provenance/runner-record guard must be active and top-level")
    inner_condition, success, inner_close = _extract_if(
        outer_body, inner_anchor, "evidence option guard"
    )
    normalized_inner = " ".join(inner_condition.split())
    expected_inner = (
        "aarch64_evidence_out != null and aarch64_provenance != null and "
        "aarch64_runner_record != null"
    )
    if normalized_inner != expected_inner:
        _fail(
            "evidence output/provenance/runner-record guard differs; "
            f"found {normalized_inner!r}"
        )

    _require_source_snapshot(success)
    _require_runner_preflight(success)
    _require_fresh_runs(success)
    _require_outputs_and_comparator(success)
    _require_dependency_dag(success)
    _require_cli_bindings(success)

    missing_inputs, inner_else_close = _extract_else(
        outer_body, inner_close, "missing evidence inputs"
    )
    _require_failure_branch(
        missing_inputs,
        variable="missing_evidence_inputs",
        dependency="missing_evidence_inputs",
        message=(
            "aarch64-hash-certify requires -Daarch64-evidence-out, -Daarch64-provenance, "
            "and -Daarch64-runner-record"
        ),
        label="missing evidence inputs",
    )
    if outer_body[inner_else_close + 1 :].strip():
        _fail("unexpected active code follows the missing-input failure branch")

    non_native, outer_else_close = _extract_else(
        contract, outer_close, "non-native or non-Debug certification"
    )
    _require_failure_branch(
        non_native,
        variable="non_native_aarch64",
        dependency="non_native_aarch64",
        message=(
            "aarch64-hash-certify requires Debug with a native target query on an AArch64 "
            "build host; cross-target, emulated, translated, or non-Debug execution is not "
            "certification"
        ),
        label="non-native or non-Debug certification",
    )
    if contract[outer_else_close + 1 :].strip():
        _fail("unexpected active code follows the non-native/non-Debug failure branch")
    _require_global_certify_dependencies(active_source)


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_file", nargs="?", type=Path, default=Path("build.zig"))
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        source = args.build_file.read_text(encoding="utf-8")
        check_build_contract(source)
    except (OSError, UnicodeError, ContractError) as error:
        print(f"AArch64 hash build contract FAILED: {error}", file=sys.stderr)
        return 1
    print(f"AArch64 hash build contract OK: {args.build_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
