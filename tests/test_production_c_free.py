#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts/check_production_c_free.sh"


class ProductionCFreeAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.repo = root / "repo"
        self.outside = root / "outside"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "src").mkdir()
        self.outside.mkdir()
        self.script = self.repo / "scripts/check_production_c_free.sh"
        self.script.write_text(SCRIPT_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        self.source = self.repo / "src/root.zig"
        self.source.write_text("pub const value: u8 = 1;\n", encoding="utf-8")

    def run_audit(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(self.script)],
            cwd=self.outside,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_gate_is_independent_of_the_callers_working_directory(self) -> None:
        result = self.run_audit()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_c_import_is_rejected_from_the_script_owned_source_root(self) -> None:
        self.source.write_text('const c = @cImport(@cInclude("clay.h"));\n', encoding="utf-8")
        result = self.run_audit()
        self.assertEqual(1, result.returncode)
        self.assertIn("production Zig sources must remain free", result.stderr)

    def test_empty_source_inventory_fails_closed(self) -> None:
        self.source.unlink()
        result = self.run_audit()
        self.assertEqual(1, result.returncode)
        self.assertIn("found no Zig sources", result.stderr)


if __name__ == "__main__":
    unittest.main()
