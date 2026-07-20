#!/usr/bin/env python3
"""Fail when pinned Clay public declarations and ZLAY's facade ledger diverge.

This is a deliberately small parser for the declaration forms used by the
pinned Clay 0.14 header. It inventories declarations; it does not validate C
ABI layout or prove behavioral parity.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
HEADER_PATH = Path("tests/oracle/clay.h")
MANIFEST_PATH = Path("tests/oracle/public_api_manifest.tsv")
FACADE_PATH = Path("src/facade_tests.zig")
ROOT_PATH = Path("src/root.zig")

SCHEMA = "zlay-clay-public-manifest-v2"
KINDS = (
    "type",
    "enum",
    "callback",
    "function",
    "implementation_function",
    "macro_support_function",
    "macro",
    "global",
)

PARSER_LIMITS = (
    "The extractor recognizes the lexical forms used by the pinned Clay 0.14 header, not arbitrary C.",
    "Public declarations are inventoried before '#endif // CLAY_HEADER'; implementation-only CLAY_WASM_EXPORT definitions are inventoried separately.",
    "Macros come from Clay's named Public Macro API block plus non-internal layout-declaration macros.",
    "Aggregate fields, enum members, C sizes, alignments, calling conventions, and behavior are outside this omission gate.",
)


class AuditError(RuntimeError):
    pass


@dataclass(frozen=True)
class Mapping:
    kind: str
    upstream: str
    native: str


@dataclass(frozen=True)
class Manifest:
    digest: str
    mappings: tuple[Mapping, ...]

    def entries(self, kind: str) -> tuple[Mapping, ...]:
        return tuple(mapping for mapping in self.mappings if mapping.kind == kind)


def _between(text: str, start: str, end: str) -> str:
    start_index = text.find(start)
    if start_index < 0:
        raise AuditError(f"parser boundary missing: {start!r}")
    start_index += len(start)
    end_index = text.find(end, start_index)
    if end_index < 0:
        raise AuditError(f"parser boundary missing: {end!r}")
    return text[start_index:end_index]


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def _strip_zig_line_comments(text: str) -> str:
    """Blank Zig line comments while preserving strings and line structure."""

    output: list[str] = []
    state = "code"
    index = 0
    while index < len(text):
        character = text[index]
        if state in ("string", "character"):
            output.append(character)
            if character == "\\" and index + 1 < len(text):
                index += 1
                output.append(text[index])
            elif (state == "string" and character == '"') or (
                state == "character" and character == "'"
            ):
                state = "code"
        elif character == "/" and index + 1 < len(text) and text[index + 1] == "/":
            while index < len(text) and text[index] != "\n":
                output.append(" ")
                index += 1
            if index < len(text):
                output.append("\n")
        else:
            output.append(character)
            if character == '"':
                state = "string"
            elif character == "'":
                state = "character"
        index += 1
    return "".join(output)


def _matching_brace(text: str, opening: int) -> int:
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise AuditError("unterminated typedef aggregate")


def _extract_aggregates(header: str) -> tuple[list[str], list[str]]:
    section = _between(header, "// Utility Structs", "// Function Forward Declarations")
    section = _strip_comments(section)
    pattern = re.compile(r"\btypedef\s+(struct|union|enum|CLAY_PACKED_ENUM)\b")
    types: list[str] = []
    enums: list[str] = []
    position = 0
    while match := pattern.search(section, position):
        kind = match.group(1)
        semicolon = section.find(";", match.end())
        if semicolon < 0:
            raise AuditError("unterminated typedef declaration")
        opening = section.find("{", match.end(), semicolon)
        if opening < 0:
            declaration = section[match.end() : semicolon]
            identifiers = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", declaration)
            if len(identifiers) < 2 or identifiers[-1] != identifiers[-2]:
                raise AuditError(f"unsupported forward typedef: {declaration.strip()!r}")
            name = identifiers[-1]
            position = semicolon + 1
        else:
            closing = _matching_brace(section, opening)
            semicolon = section.find(";", closing)
            if semicolon < 0:
                raise AuditError("unterminated aggregate alias")
            alias = section[closing + 1 : semicolon].strip()
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", alias):
                raise AuditError(f"unsupported aggregate alias: {alias!r}")
            name = alias
            position = semicolon + 1
        (enums if kind in ("enum", "CLAY_PACKED_ENUM") else types).append(name)
    return types, enums


def _extract_callbacks(header: str) -> list[str]:
    public_header = header[: header.index("#endif // CLAY_HEADER")]
    clean = _strip_comments(public_header)
    return re.findall(r"\(\s*\*\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\(", clean)


def _extract_exported_functions(section: str) -> list[str]:
    clean = _strip_comments(section)
    names: list[str] = []
    for match in re.finditer(r"\bCLAY_DLL_EXPORT\s+([^;]+);", clean, flags=re.DOTALL):
        declaration = match.group(1)
        name_match = re.search(r"\b(Clay__[A-Za-z0-9_]+|Clay_[A-Za-z0-9_]+)\s*\(", declaration)
        if name_match is None:
            raise AuditError(f"unsupported exported function declaration: {declaration.strip()!r}")
        names.append(name_match.group(1))
    return names


def _extract_macros(header: str) -> list[str]:
    macro_api = _between(header, "// Public Macro API", "static uint8_t CLAY__ELEMENT_DEFINITION_LATCH;")
    layout_api = _between(header, "// Publicly visible layout element macros", "#ifdef __cplusplus")
    define_pattern = re.compile(r"(?m)^#define\s+(CLAY[A-Za-z0-9_]*)\b")
    names = define_pattern.findall(macro_api)
    names.extend(
        name
        for name in define_pattern.findall(layout_api)
        if not name.startswith("CLAY__") and name != "CLAY_PACKED_ENUM"
    )
    return names


def _extract_implementation_only_functions(
    header: str,
    declared_functions: Iterable[str],
) -> list[str]:
    implementation = header[header.index("#endif // CLAY_HEADER") :]
    declared = set(declared_functions)
    names: list[str] = []
    for name in re.findall(r'\bCLAY_WASM_EXPORT\("([A-Za-z_][A-Za-z0-9_]*)"\)', implementation):
        if name not in declared and name not in names:
            names.append(name)
    return names


def extract_header_inventory(header: str) -> dict[str, list[str]]:
    if "#endif // CLAY_HEADER" not in header:
        raise AuditError("public header terminator missing")
    types, enums = _extract_aggregates(header)
    public_functions = _extract_exported_functions(
        _between(header, "// Public API functions", "// Internal API functions required by macros")
    )
    macro_support_functions = _extract_exported_functions(
        _between(header, "// Internal API functions required by macros", "#ifdef __cplusplus\n}")
    )
    implementation_functions = _extract_implementation_only_functions(
        header,
        (*public_functions, *macro_support_functions),
    )
    globals_section = _between(header, "// Internal API functions required by macros", "#ifdef __cplusplus\n}")
    globals_found = re.findall(
        r"(?m)^extern\s+[^;\n]+\s+(CLAY_[A-Z0-9_]+|Clay__[A-Za-z0-9_]+)\s*;",
        globals_section,
    )
    layout_default_section = _between(header, "// Utility Structs", "// Function Forward Declarations")
    globals_found = re.findall(
        r"(?m)^extern\s+[^;\n]+\s+(CLAY_[A-Z0-9_]+|Clay__[A-Za-z0-9_]+)\s*;",
        layout_default_section,
    ) + globals_found
    return {
        "type": types,
        "enum": enums,
        "callback": _extract_callbacks(header),
        "function": public_functions,
        "implementation_function": implementation_functions,
        "macro_support_function": macro_support_functions,
        "macro": _extract_macros(header),
        "global": globals_found,
    }


def load_manifest(path: Path) -> Manifest:
    digest: str | None = None
    schema: str | None = None
    mappings: list[Mapping] = []
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip("\n")
        if not line:
            continue
        if line.startswith("# schema\t"):
            if schema is not None:
                raise AuditError(f"{path}:{line_number}: duplicate manifest schema")
            schema = line.split("\t", 1)[1]
            continue
        if line.startswith("# clay.h-sha256\t"):
            if digest is not None:
                raise AuditError(f"{path}:{line_number}: duplicate clay.h digest")
            digest = line.split("\t", 1)[1]
            continue
        if line.startswith("#"):
            continue
        columns = line.split("\t")
        if len(columns) != 3:
            raise AuditError(f"{path}:{line_number}: expected kind, upstream, native TSV columns")
        kind, upstream, native = columns
        if kind not in KINDS:
            raise AuditError(f"{path}:{line_number}: unknown declaration kind {kind!r}")
        if not upstream or not native:
            raise AuditError(f"{path}:{line_number}: empty manifest field")
        mappings.append(Mapping(kind, upstream, native))
    if schema != SCHEMA:
        raise AuditError(f"manifest schema must be {SCHEMA!r}, found {schema!r}")
    if digest is None or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise AuditError("manifest must pin clay.h with a lowercase SHA-256 digest")
    seen: set[tuple[str, str]] = set()
    for mapping in mappings:
        key = (mapping.kind, mapping.upstream)
        if key in seen:
            raise AuditError(f"duplicate manifest declaration: {mapping.kind} {mapping.upstream}")
        seen.add(key)
    return Manifest(digest, tuple(mappings))


def _callback_name(signature: str) -> str:
    match = re.search(r"\(\s*\*\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", signature)
    if match is None:
        raise AuditError(f"callback manifest probe lacks a function-pointer declarator: {signature!r}")
    return match.group(1)


def compare_header_inventory(manifest: Manifest, actual: dict[str, list[str]]) -> None:
    for kind in KINDS:
        expected = [mapping.upstream for mapping in manifest.entries(kind)]
        if kind == "callback":
            expected = [_callback_name(signature) for signature in expected]
        if actual[kind] != expected:
            missing = [name for name in expected if name not in actual[kind]]
            unexpected = [name for name in actual[kind] if name not in expected]
            raise AuditError(
                f"pinned header {kind} inventory differs from manifest\n"
                f"  missing from header: {missing}\n"
                f"  missing from manifest: {unexpected}\n"
                f"  expected order: {expected}\n"
                f"  actual order:   {actual[kind]}"
            )


def _zig_ledger(source: str, name: str) -> tuple[tuple[str, str], ...]:
    source = _strip_zig_line_comments(source)
    match = re.search(
        rf"pub const {re.escape(name)}\s*=\s*\[_\][^{{]+\{{(.*?)\n\}};",
        source,
        flags=re.DOTALL,
    )
    if match is None:
        raise AuditError(f"facade ledger array missing: {name}")
    entries: list[tuple[str, str]] = []
    for line in match.group(1).splitlines():
        upstream = re.search(r'\.upstream\s*=\s*"([^"]+)"', line)
        native = re.search(r'\.native\s*=\s*"([^"]+)"', line)
        if upstream is None and native is None:
            continue
        if upstream is None or native is None:
            raise AuditError(f"unsupported multiline facade mapping in {name}: {line.strip()!r}")
        entries.append((upstream.group(1), native.group(1)))
    if len(entries) != len(set(entries)):
        raise AuditError(f"duplicate facade mapping in {name}")
    return tuple(entries)


def _manifest_pairs(manifest: Manifest, kinds: Iterable[str]) -> tuple[tuple[str, str], ...]:
    selected = set(kinds)
    return tuple(
        (mapping.upstream, mapping.native)
        for mapping in manifest.mappings
        if mapping.kind in selected
    )


def compare_facade_inventory(manifest: Manifest, facade_source: str, root_source: str) -> None:
    context = next(
        (mapping for mapping in manifest.entries("type") if mapping.upstream == "Clay_Context"),
        None,
    )
    if context != Mapping("type", "Clay_Context", "Context"):
        raise AuditError("Clay_Context must have the explicit native Context mapping")
    active_root_source = _strip_zig_line_comments(root_source)
    if re.search(
        r"(?m)^\s*pub\s+const\s+Context\s*=\s*engine\.Context\s*;\s*$",
        active_root_source,
    ) is None:
        raise AuditError("root facade no longer exports Context as engine.Context")

    expected_types = tuple(
        pair
        for pair in _manifest_pairs(manifest, ("type", "enum"))
        if pair[0] != "Clay_Context"
    )
    checks = (
        ("pinned_public_types", expected_types),
        ("pinned_public_callbacks", _manifest_pairs(manifest, ("callback",))),
        ("pinned_public_functions", _manifest_pairs(manifest, ("function",))),
        (
            "pinned_implementation_only_functions",
            _manifest_pairs(manifest, ("implementation_function",)),
        ),
        ("pinned_macro_support_functions", _manifest_pairs(manifest, ("macro_support_function",))),
        ("pinned_public_macros", _manifest_pairs(manifest, ("macro",))),
        ("pinned_public_globals", _manifest_pairs(manifest, ("global",))),
    )
    for ledger_name, expected in checks:
        actual = _zig_ledger(facade_source, ledger_name)
        if set(actual) != set(expected) or len(actual) != len(expected):
            missing = [pair for pair in expected if pair not in actual]
            unexpected = [pair for pair in actual if pair not in expected]
            raise AuditError(
                f"facade ledger {ledger_name} differs from manifest\n"
                f"  missing from facade: {missing}\n"
                f"  missing from manifest: {unexpected}"
            )


def audit_repository(repo_root: Path = REPO_ROOT) -> dict[str, int]:
    header_bytes = (repo_root / HEADER_PATH).read_bytes()
    header = header_bytes.decode("utf-8")
    manifest = load_manifest(repo_root / MANIFEST_PATH)
    actual_digest = hashlib.sha256(header_bytes).hexdigest()
    if actual_digest != manifest.digest:
        raise AuditError(
            f"pinned clay.h digest differs from manifest: expected {manifest.digest}, actual {actual_digest}"
        )
    inventory = extract_header_inventory(header)
    compare_header_inventory(manifest, inventory)
    compare_facade_inventory(
        manifest,
        (repo_root / FACADE_PATH).read_text(encoding="utf-8"),
        (repo_root / ROOT_PATH).read_text(encoding="utf-8"),
    )
    return {kind: len(inventory[kind]) for kind in KINDS}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--explain-limits",
        action="store_true",
        help="print the intentional parser/proof boundary after a successful audit",
    )
    args = parser.parse_args(argv)
    try:
        counts = audit_repository()
    except (AuditError, OSError, UnicodeError) as error:
        print(f"public API manifest audit failed: {error}", file=sys.stderr)
        return 1
    summary = " ".join(f"{kind}={counts[kind]}" for kind in KINDS)
    print(f"public API manifest audit passed: {summary}")
    if args.explain_limits:
        for limit in PARSER_LIMITS:
            print(f"limit: {limit}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
