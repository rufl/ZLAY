#!/usr/bin/env python3
"""Fail closed when the non-certifying AArch64 QEMU lane drifts.

The lane is deliberately marker-delimited and separate from native AArch64
certification. This checker pins its fresh runtime source pre-gate, static
AArch64 build target, QEMU executor, four emulated runs, host comparator,
supplemental report, header gate, and missing-QEMU failure branch.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import NoReturn


BEGIN_MARKER = "// BEGIN AARCH64 HASH QEMU CONTRACT"
END_MARKER = "// END AARCH64 HASH QEMU CONTRACT"

REPORT_MESSAGE = (
    "oracle-emulation identity=hash-default target=aarch64-linux-musl "
    "cpu=baseline executor=qemu-aarch64 qemu_cpu=max "
    "lines=18 bytes=426 sha256="
    "68b1ce5dfef146735d34889f337fa3f73a597b0511a5fc511f9e399d263dc787 "
    "certification=false physical_machine_proof=false backlog_closed=false"
)

COMPARATOR_REPORT_MESSAGE = (
    "oracle-emulation identity={s} target=aarch64-linux-musl "
    "cpu=baseline executor=qemu-aarch64 qemu_cpu=max "
    "lines={d} bytes={d} sha256={s} certification=false "
    "physical_machine_proof=false backlog_closed=false"
)

SOURCE_CONTRACT_FILES = (
    "build.zig",
    "build.zig.zon",
    "src/allocation_discipline_tests.zig",
    "src/audit_regression_tests.zig",
    "src/context.zig",
    "src/debug.zig",
    "src/debug_inspector_tests.zig",
    "src/declaration_order_tests.zig",
    "src/deep_render_tests.zig",
    "src/exit_transition_tests.zig",
    "src/facade_tests.zig",
    "src/geometry.zig",
    "src/globals.zig",
    "src/hash.zig",
    "src/integration_tests.zig",
    "src/layout.zig",
    "src/paragraph_provider.zig",
    "src/profile.zig",
    "src/public_metadata_tests.zig",
    "src/renderer.zig",
    "src/root.zig",
    "src/scroll.zig",
    "src/text.zig",
    "src/transition.zig",
    "src/types.zig",
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

QEMU_RUNS = {
    "run_aarch64_qemu_module_tests": "aarch64_qemu_module_tests",
    "run_aarch64_qemu_manifest_tests": "aarch64_qemu_manifest_tests",
    "run_aarch64_qemu_c": "aarch64_qemu_c_oracle",
    "run_aarch64_qemu_zig": "aarch64_qemu_zig_oracle",
}

SUCCESS_DEPENDENCIES = {"run_aarch64_qemu_report"}

REPORT_DEPENDENCIES = (
    "run_header_checker",
    "run_aarch64_qemu_module_tests",
    "run_aarch64_qemu_manifest_tests",
    "run_aarch64_qemu_compare",
)

PRE_GATE_COMPILE_STEPS = (
    "aarch64_qemu_module_tests",
    "aarch64_qemu_manifest_tests",
    "aarch64_qemu_c_oracle",
    "aarch64_qemu_zig_oracle",
    "aarch64_qemu_comparator",
)

FORBIDDEN_LANE_PATTERNS = {
    "certification/evidence/provenance identifier": (
        r"\b(?:aarch64|run|capture|validate|import|runner|native)"
        r"[A-Za-z0-9_]*(?:certif|evidence|provenance|host_guard|native_host)"
        r"[A-Za-z0-9_]*\b"
    ),
    "native certification step": r"\baarch64_hash_certify_step\b",
    "evidence output": r"\baarch64_evidence(?:_out)?\b",
    "runner provenance": r"\baarch64_provenance\b|--provenance",
    "runner record": r"\baarch64_runner_record\b|--runner-record",
    "evidence writer": r"\bcapture_evidence\b|aarch64_hash_evidence\.py",
    "runner preflight": r"\brunner_preflight\b|runner-preflight",
    "source snapshot": r"\bsource_snapshot\b|source-snapshot",
    "native host guard": (
        r"\bnative_aarch64_host\b|\bnative_host_guard\b|"
        r"check_native_aarch64_host"
    ),
}


class ContractError(RuntimeError):
    """Raised when the QEMU lane no longer satisfies its proof contract."""


def _fail(message: str) -> NoReturn:
    raise ContractError(message)


def _require_once(
    text: str, pattern: str, label: str, *, flags: int = 0
) -> re.Match[str]:
    matches = list(re.finditer(pattern, text, flags))
    if len(matches) != 1:
        _fail(f"{label}: expected exactly one match, found {len(matches)}")
    return matches[0]


def _matching_delimiter(text: str, opening: int, left: str, right: str) -> int:
    if opening >= len(text) or text[opening] != left:
        _fail(f"internal parser error: expected {left!r} at offset {opening}")

    depth = 0
    state = "code"
    escaped = False
    index = opening
    while index < len(text):
        character = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "line-comment":
            if character == "\n":
                state = "code"
        elif state in ("string", "character"):
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif (state == "string" and character == '"') or (
                state == "character" and character == "'"
            ):
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
    result = list(text)
    state = "code"
    escaped = False
    index = 0
    while index < len(text):
        character = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state in ("string", "character"):
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif (state == "string" and character == '"') or (
                state == "character" and character == "'"
            ):
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
    depths = [0] * (len(text) + 1)
    depth = 0
    state = "code"
    escaped = False
    index = 0
    while index < len(text):
        depths[index] = depth
        character = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "line-comment":
            if character == "\n":
                state = "code"
        elif state in ("string", "character"):
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif (state == "string" and character == '"') or (
                state == "character" and character == "'"
            ):
                state = "code"
        elif character == "/" and following == "/":
            state = "line-comment"
            index += 1
        elif character == '"':
            state = "string"
        elif character == "'":
            state = "character"
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth < 0:
                _fail("unexpected closing brace while checking QEMU lane depth")
        index += 1
    depths[len(text)] = depth
    if depth != 0:
        _fail("unbalanced braces while checking QEMU lane depth")
    return depths


def _is_top_level(text: str, offset: int, depths: list[int] | None = None) -> bool:
    depths = depths or _curly_depths(text)
    if depths[offset] != 0:
        return False
    previous = offset - 1
    while previous >= 0 and text[previous].isspace():
        previous -= 1
    return previous < 0 or text[previous] in ";}"


def _require_top_level_once(
    text: str, pattern: str, label: str, *, flags: int = 0
) -> re.Match[str]:
    match = _require_once(text, pattern, label, flags=flags)
    if not _is_top_level(text, match.start()):
        _fail(f"{label}: must be an active top-level statement")
    return match


def _extract_lane(source: str) -> str:
    starts = list(
        re.finditer(rf"(?m)^[ \t]*{re.escape(BEGIN_MARKER)}[ \t]*$", source)
    )
    ends = list(re.finditer(rf"(?m)^[ \t]*{re.escape(END_MARKER)}[ \t]*$", source))
    if len(starts) != 1:
        _fail(f"QEMU lane start marker must occur exactly once: {BEGIN_MARKER}")
    if len(ends) != 1:
        _fail(f"QEMU lane end marker must occur exactly once: {END_MARKER}")
    if ends[0].start() <= starts[0].end():
        _fail("QEMU lane markers are reversed")
    return source[starts[0].end() : ends[0].start()]


def _require_embedded_build_source(active_source: str) -> None:
    _require_top_level_once(
        active_source,
        r"const\s+embedded_build_zig_source\s*=\s*"
        r"@embedFile\(\s*\"build\.zig\"\s*\)\s*;",
        "raw embedded build.zig source for the QEMU pre-gate",
    )


def _require_source_pre_gate(success: str) -> None:
    dependency_chain = "".join(
        rf"{step}\.step\.dependOn\(\s*"
        r"&capture_aarch64_qemu_source_contract\.step\s*\)\s*;\s*"
        for step in PRE_GATE_COMPILE_STEPS
    )
    chain = (
        r"const\s+write_aarch64_qemu_embedded_build\s*=\s*"
        r"b\.addWriteFiles\(\s*\)\s*;\s*"
        r"const\s+aarch64_qemu_embedded_build_zig\s*=\s*"
        r"write_aarch64_qemu_embedded_build\.add\(\s*"
        r'"aarch64-qemu-embedded-build\.zig"\s*,\s*'
        r"embedded_build_zig_source\s*,?\s*\)\s*;\s*"
        r"const\s+capture_aarch64_qemu_source_contract\s*=\s*"
        r"b\.addSystemCommand\(\s*&\.\{\s*"
        r'"python3"\s*,\s*"-B"\s*,\s*'
        r'"scripts/aarch64_hash_qemu_report\.py"\s*,\s*'
        r'"source-contract"\s*,\s*"--repo-root"\s*,\s*'
        r'b\.pathFromRoot\(\s*"\."\s*\)\s*,\s*'
        r'"--expected-build-zig-source"\s*,?\s*\}\s*\)\s*;\s*'
        r"capture_aarch64_qemu_source_contract\.addFileArg\(\s*"
        r"aarch64_qemu_embedded_build_zig\s*\)\s*;\s*"
        r"capture_aarch64_qemu_source_contract\.has_side_effects\s*=\s*"
        r"true\s*;\s*"
        r"const\s+aarch64_qemu_source_contract\s*=\s*"
        r"capture_aarch64_qemu_source_contract\.captureStdOut\(\s*\.\{\s*"
        r"\.basename\s*=\s*\"aarch64-qemu-source-contract\.sha256\"\s*,?\s*"
        r"\}\s*\)\s*;\s*"
        + dependency_chain
    )
    _require_top_level_once(
        success,
        chain,
        "fresh source-contract pre-gate and compile-step dependencies",
        flags=re.DOTALL,
    )
    capture_uses = len(
        re.findall(r"\bcapture_aarch64_qemu_source_contract\.", success)
    )
    if capture_uses != 8:
        _fail(
            "source-contract pre-gate operation count differs; "
            f"expected 8, found {capture_uses}"
        )
    if len(re.findall(r"\bwrite_aarch64_qemu_embedded_build\.", success)) != 1:
        _fail("QEMU pre-gate must generate exactly one embedded build.zig file")
    embedded_file_uses = len(
        re.findall(r"\baarch64_qemu_embedded_build_zig\b", success)
    )
    if embedded_file_uses != 2:
        _fail(
            "generated embedded build.zig binding count differs; "
            f"expected 2, found {embedded_file_uses}"
        )
    if len(re.findall(r"\bembedded_build_zig_source\b", success)) != 1:
        _fail("QEMU pre-gate must consume the raw embedded build.zig exactly once")
    for forbidden in (
        "embedded_build_zig_sha256",
        "--expected-build-zig-sha256",
    ):
        if forbidden in success:
            _fail(f"QEMU pre-gate contains obsolete digest binding {forbidden!r}")
    source_uses = len(re.findall(r"\baarch64_qemu_source_contract\b", success))
    if source_uses != 2:
        _fail(
            "source-contract output binding count differs; "
            f"expected 2, found {source_uses}"
        )


def _extract_qemu_branches(lane: str) -> tuple[str, str]:
    branch = _require_top_level_once(
        lane,
        r"if\s*\(\s*qemu_aarch64\s*\)\s*\|\s*qemu_exe\s*\|\s*\{",
        "resolved qemu-aarch64 branch",
    )
    open_brace = branch.end() - 1
    close_brace = _matching_delimiter(lane, open_brace, "{", "}")
    success = lane[open_brace + 1 : close_brace]

    index = close_brace + 1
    while index < len(lane) and lane[index].isspace():
        index += 1
    if not lane.startswith("else", index):
        _fail("resolved qemu-aarch64 branch is missing its fail-closed else")
    index += len("else")
    while index < len(lane) and lane[index].isspace():
        index += 1
    if index >= len(lane) or lane[index] != "{":
        _fail("missing-QEMU else must contain a block")
    else_close = _matching_delimiter(lane, index, "{", "}")
    missing = lane[index + 1 : else_close]
    if lane[else_close + 1 :].strip():
        _fail("unexpected active code follows the missing-QEMU branch")
    return success, missing


def _require_artifacts(lane: str) -> None:
    target = (
        r"const\s+aarch64_qemu_target\s*=\s*b\.resolveTargetQuery\(\.\{\s*"
        r"\.cpu_arch\s*=\s*\.aarch64\s*,\s*"
        r"\.cpu_model\s*=\s*\.baseline\s*,\s*"
        r"\.os_tag\s*=\s*\.linux\s*,\s*"
        r"\.abi\s*=\s*\.musl\s*,\s*\}\s*\)\s*;"
    )
    _require_top_level_once(lane, target, "pinned AArch64 baseline/Linux/musl target", flags=re.DOTALL)

    patterns = {
        "pinned ZLAY root module": (
            r"const\s+aarch64_qemu_zlay\s*=\s*b\.createModule\(\.\{\s*"
            r"\.root_source_file\s*=\s*b\.path\(\"src/root\.zig\"\)\s*,\s*"
            r"\.target\s*=\s*aarch64_qemu_target\s*,\s*"
            r"\.optimize\s*=\s*\.Debug\s*,\s*\}\s*\)\s*;"
        ),
        "static root test artifact": (
            r"const\s+aarch64_qemu_module_tests\s*=\s*b\.addTest\(\.\{\s*"
            r"\.name\s*=\s*\"zlay-aarch64-qemu-module-tests\"\s*,\s*"
            r"\.root_module\s*=\s*aarch64_qemu_zlay\s*,\s*\}\s*\)\s*;\s*"
            r"aarch64_qemu_module_tests\.linkage\s*=\s*\.static\s*;"
        ),
        "static manifest test artifact": (
            r"const\s+aarch64_qemu_manifest_tests\s*=\s*b\.addTest\(\.\{\s*"
            r"\.name\s*=\s*\"zlay-aarch64-qemu-manifest-tests\"\s*,\s*"
            r"\.root_module\s*=\s*b\.createModule\(\.\{\s*"
            r"\.root_source_file\s*=\s*b\.path\(\"tests/oracle/ordinary_manifest\.zig\"\)\s*,\s*"
            r"\.target\s*=\s*aarch64_qemu_target\s*,\s*"
            r"\.optimize\s*=\s*\.Debug\s*,\s*\}\s*\)\s*,\s*\}\s*\)\s*;\s*"
            r"aarch64_qemu_manifest_tests\.linkage\s*=\s*\.static\s*;"
        ),
        "pinned C module": (
            r"const\s+aarch64_qemu_c_module\s*=\s*b\.createModule\(\.\{\s*"
            r"\.target\s*=\s*aarch64_qemu_target\s*,\s*"
            r"\.optimize\s*=\s*\.Debug\s*,\s*"
            r"\.link_libc\s*=\s*true\s*,\s*\}\s*\)\s*;\s*"
            r"aarch64_qemu_c_module\.addIncludePath\(b\.path\(\"tests/oracle\"\)\)\s*;\s*"
            r"aarch64_qemu_c_module\.addCSourceFile\(\.\{\s*"
            r"\.file\s*=\s*b\.path\(\"tests/oracle/hash_default_fixture\.c\"\)\s*,\s*"
            r"\.flags\s*=\s*&\.\{\"-std=c99\"\}\s*,\s*\}\s*\)\s*;"
        ),
        "static C oracle": (
            r"const\s+aarch64_qemu_c_oracle\s*=\s*b\.addExecutable\(\.\{\s*"
            r"\.name\s*=\s*\"zlay-aarch64-qemu-hash-clay\"\s*,\s*"
            r"\.root_module\s*=\s*aarch64_qemu_c_module\s*,\s*"
            r"\.linkage\s*=\s*\.static\s*,\s*\}\s*\)\s*;"
        ),
        "static Zig oracle": (
            r"const\s+aarch64_qemu_zig_oracle\s*=\s*b\.addExecutable\(\.\{\s*"
            r"\.name\s*=\s*\"zlay-aarch64-qemu-hash-zig\"\s*,\s*"
            r"\.root_module\s*=\s*b\.createModule\(\.\{\s*"
            r"\.root_source_file\s*=\s*b\.path\(\"tests/oracle/hash_default_fixture\.zig\"\)\s*,\s*"
            r"\.target\s*=\s*aarch64_qemu_target\s*,\s*"
            r"\.optimize\s*=\s*\.Debug\s*,\s*"
            r"\.imports\s*=\s*&\.\{\.\{\s*\.name\s*=\s*\"zlay\"\s*,\s*"
            r"\.module\s*=\s*aarch64_qemu_zlay\s*\}\}\s*,\s*\}\s*\)\s*,\s*"
            r"\.linkage\s*=\s*\.static\s*,\s*\}\s*\)\s*;"
        ),
        "static host comparator": (
            r"const\s+aarch64_qemu_comparator\s*=\s*b\.addExecutable\(\.\{\s*"
            r"\.name\s*=\s*\"zlay-aarch64-qemu-hash-compare\"\s*,\s*"
            r"\.root_module\s*=\s*b\.createModule\(\.\{\s*"
            r"\.root_source_file\s*=\s*b\.path\(\"tests/oracle/compare\.zig\"\)\s*,\s*"
            r"\.target\s*=\s*b\.graph\.host\s*,\s*"
            r"\.optimize\s*=\s*\.Debug\s*,\s*\}\s*\)\s*,\s*"
            r"\.linkage\s*=\s*\.static\s*,\s*\}\s*\)\s*;"
        ),
    }
    for label, pattern in patterns.items():
        _require_top_level_once(lane, pattern, label, flags=re.DOTALL)

    linkages = re.findall(r"\.linkage\s*=\s*\.[A-Za-z0-9_]+", lane)
    if linkages != [".linkage = .static"] * 5:
        _fail(f"QEMU lane linkage pins differ; found {linkages!r}")
    optimizations = re.findall(r"\.optimize\s*=\s*\.[A-Za-z0-9_]+", lane)
    if optimizations != [".optimize = .Debug"] * 5:
        _fail(f"QEMU lane optimization pins differ; found {optimizations!r}")


def _require_step_and_resolver(lane: str) -> None:
    _require_top_level_once(
        lane,
        r"const\s+aarch64_hash_qemu_step\s*=\s*b\.step\(\s*"
        r"\"aarch64-hash-qemu\"\s*,\s*"
        r"\"Execute the AArch64 hash contract and native tests under QEMU user mode without certification\"\s*,?\s*\)\s*;",
        "AArch64 hash QEMU step",
        flags=re.DOTALL,
    )
    _require_top_level_once(
        lane,
        r"const\s+qemu_aarch64\s*=\s*b\.findProgram\(\s*&\.\{\s*"
        r"\"qemu-aarch64\"\s*\}\s*,\s*&\.\{\s*\}\s*\)\s*catch\s+null\s*;",
        "resolved qemu-aarch64 executable",
        flags=re.DOTALL,
    )


def _require_qemu_runs(success: str) -> None:
    for run_variable, artifact in QEMU_RUNS.items():
        _require_top_level_once(
            success,
            rf"const\s+{run_variable}\s*=\s*b\.addSystemCommand\(\s*&\.\{{\s*"
            rf"qemu_exe\s*,\s*\"-cpu\"\s*,\s*\"max\"\s*,?\s*\}}\s*\)\s*;",
            f"{run_variable} qemu-aarch64 -cpu max executor",
            flags=re.DOTALL,
        )
        _require_top_level_once(
            success,
            rf"{run_variable}\.addFileArg\(\s*{artifact}\.getEmittedBin\(\)\s*\)\s*;",
            f"{run_variable} exact artifact",
        )
        _require_top_level_once(
            success,
            rf"{run_variable}\.has_side_effects\s*=\s*true\s*;",
            f"{run_variable} forced fresh execution",
        )
        _require_top_level_once(
            success,
            rf"{run_variable}\.expectExitCode\(\s*0\s*\)\s*;",
            f"{run_variable} exit-zero contract",
        )

    qemu_commands = re.findall(
        r"\bb\.addSystemCommand\(\s*&\.\{\s*qemu_exe\s*,\s*"
        r'"-cpu"\s*,\s*"max"\s*,?\s*\}\s*\)',
        success,
        re.DOTALL,
    )
    if len(qemu_commands) != 4:
        _fail("QEMU success branch must contain exactly four pinned QEMU executions")
    if len(re.findall(r"\bb\.addSystemCommand\s*\(", success)) != 6:
        _fail(
            "QEMU success branch must contain a source pre-gate, "
            "four executions, and one reporter command"
        )
    if len(re.findall(r"\bb\.addRunArtifact\s*\(", success)) != 1:
        _fail("QEMU success branch must use addRunArtifact only for the host comparator")

    outputs = {
        "aarch64_qemu_c_output": (
            "run_aarch64_qemu_c",
            "hash-default-clay-oracle.txt",
        ),
        "aarch64_qemu_zig_output": (
            "run_aarch64_qemu_zig",
            "hash-default-zig-oracle.txt",
        ),
    }
    for output, (run_variable, basename) in outputs.items():
        _require_top_level_once(
            success,
            rf"const\s+{output}\s*=\s*{run_variable}\.captureStdOut\(\s*\.\{{\s*"
            rf"\.basename\s*=\s*\"{re.escape(basename)}\"\s*,?\s*\}}\s*\)\s*;",
            f"{output} exact stdout capture",
            flags=re.DOTALL,
        )

    logs = {
        "aarch64_qemu_module_tests_log": (
            "run_aarch64_qemu_module_tests",
            "aarch64-qemu-module-tests.log",
        ),
        "aarch64_qemu_manifest_tests_log": (
            "run_aarch64_qemu_manifest_tests",
            "aarch64-qemu-manifest-tests.log",
        ),
    }
    for output, (run_variable, basename) in logs.items():
        _require_top_level_once(
            success,
            rf"const\s+{output}\s*=\s*{run_variable}\.captureStdErr\(\s*\.\{{\s*"
            rf"\.basename\s*=\s*\"{re.escape(basename)}\"\s*,?\s*\}}\s*\)\s*;",
            f"{output} exact stderr capture",
            flags=re.DOTALL,
        )
        uses = len(re.findall(rf"\b{output}\b", success))
        if uses != 2:
            _fail(f"{output} binding count differs; expected 2, found {uses}")

    expected_uses = {
        "run_aarch64_qemu_module_tests": 5,
        "run_aarch64_qemu_manifest_tests": 5,
        "run_aarch64_qemu_c": 4,
        "run_aarch64_qemu_zig": 4,
    }
    for variable, expected in expected_uses.items():
        found = len(re.findall(rf"\b{variable}\.", success))
        if found != expected:
            _fail(f"{variable} operation count differs; expected {expected}, found {found}")


def _require_comparator(success: str) -> None:
    _require_top_level_once(
        success,
        r"const\s+run_aarch64_qemu_compare\s*=\s*"
        r"b\.addRunArtifact\(\s*aarch64_qemu_comparator\s*\)\s*;",
        "host comparator run",
    )
    chain = (
        r"run_aarch64_qemu_compare\.has_side_effects\s*=\s*true\s*;\s*"
        r"run_aarch64_qemu_compare\.addFileArg\(\s*aarch64_qemu_c_output\s*\)\s*;\s*"
        r"run_aarch64_qemu_compare\.addFileArg\(\s*aarch64_qemu_zig_output\s*\)\s*;\s*"
        r"run_aarch64_qemu_compare\.addArg\(\s*\"--qemu-aarch64-report\"\s*\)\s*;\s*"
        r"run_aarch64_qemu_compare\.expectStdErrEqual\(\s*\""
        + re.escape(REPORT_MESSAGE)
        + r"\\n\"\s*,?\s*\)\s*;\s*"
        r"run_aarch64_qemu_compare\.expectExitCode\(\s*0\s*\)\s*;"
    )
    _require_top_level_once(
        success,
        chain,
        "exact C/Zig AArch64 comparator inputs, mode, report, and exit",
        flags=re.DOTALL,
    )
    uses = len(re.findall(r"\brun_aarch64_qemu_compare\.", success))
    if uses != 7:
        _fail(f"host comparator operation count differs; expected 7, found {uses}")


def _require_reporter(success: str) -> None:
    chain = (
        r"const\s+run_aarch64_qemu_report\s*=\s*b\.addSystemCommand\(\s*&\.\{\s*"
        r'"python3"\s*,\s*"-B"\s*,\s*"scripts/aarch64_hash_qemu_report\.py"\s*,\s*'
        r'"report"\s*,\s*'
        r'"--repo-root"\s*,\s*b\.pathFromRoot\(\s*"\."\s*\)\s*,\s*'
        r'"--qemu"\s*,\s*qemu_exe\s*,\s*'
        r'"--zig"\s*,\s*b\.graph\.zig_exe\s*,\s*'
        r'"--c-trace"\s*,?\s*\}\s*\)\s*;\s*'
        r"run_aarch64_qemu_report\.addFileArg\(\s*aarch64_qemu_c_output\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addArg\(\s*\"--zig-trace\"\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addFileArg\(\s*aarch64_qemu_zig_output\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addArg\(\s*\"--module-tests-log\"\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addFileArg\(\s*aarch64_qemu_module_tests_log\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addArg\(\s*\"--manifest-tests-log\"\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addFileArg\(\s*aarch64_qemu_manifest_tests_log\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addArg\(\s*\"--c-executable\"\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addFileArg\(\s*aarch64_qemu_c_oracle\.getEmittedBin\(\)\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addArg\(\s*\"--zig-executable\"\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addFileArg\(\s*aarch64_qemu_zig_oracle\.getEmittedBin\(\)\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addArg\(\s*\"--module-tests-executable\"\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addFileArg\(\s*aarch64_qemu_module_tests\.getEmittedBin\(\)\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addArg\(\s*\"--manifest-tests-executable\"\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addFileArg\(\s*aarch64_qemu_manifest_tests\.getEmittedBin\(\)\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addArg\(\s*\"--expected-source-file\"\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.addFileArg\(\s*aarch64_qemu_source_contract\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.has_side_effects\s*=\s*true\s*;\s*"
        r"run_aarch64_qemu_report\.step\.dependOn\(\s*&run_header_checker\.step\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.step\.dependOn\(\s*&run_aarch64_qemu_module_tests\.step\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.step\.dependOn\(\s*&run_aarch64_qemu_manifest_tests\.step\s*\)\s*;\s*"
        r"run_aarch64_qemu_report\.step\.dependOn\(\s*&run_aarch64_qemu_compare\.step\s*\)\s*;"
    )
    _require_top_level_once(
        success,
        chain,
        "exact supplemental QEMU identity reporter and proof predecessors",
        flags=re.DOTALL,
    )
    uses = len(re.findall(r"\brun_aarch64_qemu_report\.", success))
    if uses != 23:
        _fail(f"QEMU reporter operation count differs; expected 23, found {uses}")


def _require_dependencies(success: str, active_source: str) -> None:
    matches = list(
        re.finditer(
            r"(?m)^\s*(aarch64_hash_qemu_step)\.dependOn\(\s*&([A-Za-z_][A-Za-z0-9_]*)\.step\s*\)\s*;\s*$",
            success,
        )
    )
    depths = _curly_depths(success)
    if any(not _is_top_level(success, match.start(1), depths) for match in matches):
        _fail("QEMU success dependencies must be active top-level statements")
    dependencies = [match.group(2) for match in matches]
    if len(dependencies) != len(SUCCESS_DEPENDENCIES) or set(dependencies) != SUCCESS_DEPENDENCIES:
        _fail(
            "QEMU success dependencies differ; "
            f"expected {sorted(SUCCESS_DEPENDENCIES)!r}, found {dependencies!r}"
        )

    global_dependencies = re.findall(
        r"aarch64_hash_qemu_step\.dependOn\(\s*&([A-Za-z_][A-Za-z0-9_]*)\.step\s*\)\s*;",
        active_source,
    )
    expected_global = SUCCESS_DEPENDENCIES | {"missing_qemu_aarch64"}
    if (
        len(global_dependencies) != len(expected_global)
        or set(global_dependencies) != expected_global
    ):
        _fail(
            "global AArch64 QEMU dependencies differ; "
            f"expected {sorted(expected_global)!r}, found {global_dependencies!r}"
        )


def _require_missing_qemu(missing: str) -> None:
    pattern = (
        r"\s*const\s+missing_qemu_aarch64\s*=\s*b\.addFail\(\s*"
        r"\"aarch64-hash-qemu requires qemu-aarch64; this optional emulation lane is not certification\"\s*,?\s*"
        r"\)\s*;\s*"
        r"aarch64_hash_qemu_step\.dependOn\(\s*&missing_qemu_aarch64\.step\s*\)\s*;\s*"
    )
    if re.fullmatch(pattern, missing, re.DOTALL) is None:
        _fail("missing qemu-aarch64 branch must fail explicitly and exclusively")


def _require_proof_separation(lane: str) -> None:
    for label, pattern in FORBIDDEN_LANE_PATTERNS.items():
        if re.search(pattern, lane):
            _fail(f"QEMU lane references forbidden {label}")


def _require_compare_contract(compare_source: str) -> None:
    _require_once(
        compare_source,
        r"if\s*\(\s*args\.len\s*!=\s*3\s+and\s+args\.len\s*!=\s*4\s*\)\s*"
        r"return\s+error\.InvalidArguments\s*;",
        "comparator three-or-four argument contract",
    )
    _require_once(
        compare_source,
        r"const\s+ReportMode\s*=\s*enum\s*\{\s*none\s*,\s*target\s*,\s*qemu_aarch64\s*\}\s*;",
        "comparator QEMU report mode",
    )
    _require_once(
        compare_source,
        r"std\.mem\.eql\(\s*u8\s*,\s*args\[3\]\s*,\s*\"--qemu-aarch64-report\"\s*\)\s*\)\s*"
        r"\.qemu_aarch64",
        "comparator explicit QEMU CLI mode",
        flags=re.DOTALL,
    )
    _require_once(
        compare_source,
        r"if\s*\(\s*report_mode\s*==\s*\.qemu_aarch64\s+and\s+"
        r"!std\.mem\.eql\(\s*u8\s*,\s*entry\.identity\s*,\s*\"hash-default\"\s*\)\s*\)\s*\{\s*"
        r"return\s+error\.InvalidQemuAarch64Identity\s*;\s*\}",
        "comparator pinned hash-default identity",
        flags=re.DOTALL,
    )
    _require_once(
        compare_source,
        r"const\s+contract_arch\s*:\s*std\.Target\.Cpu\.Arch\s*=\s*"
        r"if\s*\(\s*report_mode\s*==\s*\.qemu_aarch64\s*\)\s*\.aarch64\s*else\s*builtin\.target\.cpu\.arch\s*;",
        "comparator explicit AArch64 contract selection",
        flags=re.DOTALL,
    )
    _require_once(
        compare_source,
        r'"' + re.escape(COMPARATOR_REPORT_MESSAGE) + r'\\n"\s*,\s*\.\{\s*'
        r"entry\.identity\s*,\s*contract\.line_count\s*,\s*"
        r"contract\.byte_count\s*,\s*contract\.sha256_hex\s*,?\s*\}",
        "comparator conservative QEMU report",
        flags=re.DOTALL,
    )
    for forbidden in (
        "certification=true",
        "physical_machine_proof=true",
        "backlog_closed=true",
    ):
        if forbidden in compare_source:
            _fail(f"comparator contains forbidden QEMU proof claim {forbidden!r}")
    if "source_contract_sha256" in compare_source or "args[4]" in compare_source:
        _fail("comparator must not consume the runtime source-contract pre-gate")


def check_qemu_contract(build_source: str, compare_source: str) -> None:
    """Validate the complete static, non-certifying AArch64 QEMU lane."""

    active_source = _strip_line_comments(build_source)
    raw_lane = _extract_lane(build_source)
    lane = _strip_line_comments(raw_lane)

    _require_once(
        active_source,
        r"const\s+aarch64_hash_qemu_step\s*=\s*b\.step\(\s*\"aarch64-hash-qemu\"\s*,",
        "global AArch64 hash QEMU step",
        flags=re.DOTALL,
    )
    if "aarch64_qemu_source_contract_sha256" in active_source:
        _fail("QEMU source identity must be computed by the runtime pre-gate")
    _require_embedded_build_source(active_source)
    _require_artifacts(lane)
    _require_step_and_resolver(lane)
    success, missing = _extract_qemu_branches(lane)
    _require_source_pre_gate(success)
    _require_qemu_runs(success)
    _require_comparator(success)
    _require_reporter(success)
    _require_dependencies(success, active_source)
    _require_missing_qemu(missing)
    _require_proof_separation(lane)
    _require_compare_contract(compare_source)


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_file", nargs="?", type=Path, default=Path("build.zig"))
    parser.add_argument(
        "--compare-file",
        type=Path,
        default=Path("tests/oracle/compare.zig"),
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        build_source = args.build_file.read_text(encoding="utf-8")
        compare_source = args.compare_file.read_text(encoding="utf-8")
        check_qemu_contract(build_source, compare_source)
    except (OSError, UnicodeError, ContractError) as error:
        print(f"AArch64 hash QEMU contract FAILED: {error}", file=sys.stderr)
        return 1
    print(
        f"AArch64 hash QEMU contract OK: {args.build_file} + {args.compare_file}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
