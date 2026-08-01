#!/usr/bin/env python3

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import check_public_api_manifest as audit  # noqa: E402


class PublicApiManifestAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.header = (REPO_ROOT / audit.HEADER_PATH).read_text(encoding="utf-8")
        cls.manifest = audit.load_manifest(REPO_ROOT / audit.MANIFEST_PATH)

    def test_checked_in_header_and_facade_inventory_match(self) -> None:
        self.assertEqual(
            {
                "type": 45,
                "enum": 19,
                "callback": 7,
                "function": 34,
                "implementation_function": 1,
                "macro_support_function": 8,
                "macro": 26,
                "global": 3,
            },
            audit.audit_repository(REPO_ROOT),
        )

    def test_new_public_function_requires_manifest_mapping(self) -> None:
        mutated = self.header.replace(
            "// Internal API functions required by macros",
            "CLAY_DLL_EXPORT void Clay_NewPublicOperation(void);\n\n"
            "// Internal API functions required by macros",
            1,
        )
        inventory = audit.extract_header_inventory(mutated)
        self.assertIn("Clay_NewPublicOperation", inventory["function"])
        with self.assertRaisesRegex(audit.AuditError, "missing from manifest"):
            audit.compare_header_inventory(self.manifest, inventory)

    def test_new_public_macro_requires_manifest_mapping(self) -> None:
        mutated = self.header.replace(
            "static uint8_t CLAY__ELEMENT_DEFINITION_LATCH;",
            "#define CLAY_NEW_PUBLIC_MACRO(value) (value)\n\n"
            "static uint8_t CLAY__ELEMENT_DEFINITION_LATCH;",
            1,
        )
        inventory = audit.extract_header_inventory(mutated)
        self.assertIn("CLAY_NEW_PUBLIC_MACRO", inventory["macro"])
        with self.assertRaisesRegex(audit.AuditError, "missing from manifest"):
            audit.compare_header_inventory(self.manifest, inventory)

    def test_new_implementation_only_export_requires_manifest_mapping(self) -> None:
        mutated = self.header.replace(
            "#endif // CLAY_IMPLEMENTATION",
            'CLAY_WASM_EXPORT("Clay_NewImplementationOnly")\n'
            "void Clay_NewImplementationOnly(void) {}\n\n"
            "#endif // CLAY_IMPLEMENTATION",
            1,
        )
        inventory = audit.extract_header_inventory(mutated)
        self.assertIn("Clay_NewImplementationOnly", inventory["implementation_function"])
        with self.assertRaisesRegex(audit.AuditError, "missing from manifest"):
            audit.compare_header_inventory(self.manifest, inventory)

    def test_commented_out_facade_mapping_is_not_counted(self) -> None:
        facade = (REPO_ROOT / audit.FACADE_PATH).read_text(encoding="utf-8")
        root = (REPO_ROOT / audit.ROOT_PATH).read_text(encoding="utf-8")
        active = '    .{ .upstream = "Clay_String", .native = "String" },'
        self.assertIn(active, facade)
        mutated = facade.replace(active, f"    // {active.strip()}", 1)
        with self.assertRaisesRegex(audit.AuditError, "missing from facade"):
            audit.compare_facade_inventory(self.manifest, mutated, root)

    def test_commented_out_root_context_export_is_not_counted(self) -> None:
        facade = (REPO_ROOT / audit.FACADE_PATH).read_text(encoding="utf-8")
        root = (REPO_ROOT / audit.ROOT_PATH).read_text(encoding="utf-8")
        active = "pub const Context = engine.Context;"
        self.assertIn(active, root)
        mutated = root.replace(active, f"// {active}", 1)
        with self.assertRaisesRegex(audit.AuditError, "no longer exports Context"):
            audit.compare_facade_inventory(self.manifest, facade, mutated)

    def test_duplicate_manifest_metadata_is_rejected(self) -> None:
        manifest_text = (REPO_ROOT / audit.MANIFEST_PATH).read_text(encoding="utf-8")
        schema_line = f"# schema\t{audit.SCHEMA}"
        self.assertIn(schema_line, manifest_text)
        with tempfile.TemporaryDirectory() as scratch_dir:
            path = Path(scratch_dir) / "manifest.tsv"
            path.write_text(
                manifest_text.replace(schema_line, f"{schema_line}\n{schema_line}", 1),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(audit.AuditError, "duplicate manifest schema"):
                audit.load_manifest(path)


if __name__ == "__main__":
    unittest.main()
