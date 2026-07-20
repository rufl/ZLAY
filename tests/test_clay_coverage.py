#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import check_clay_coverage as coverage  # noqa: E402


def metric(total: int, covered: int) -> dict[str, int | float]:
    return {
        "count": total,
        "covered": covered,
        "notcovered": total - covered,
        "percent": 100.0 if total == 0 else covered * 100.0 / total,
    }


class ClayCoverageCertificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        (self.repo / "tests/oracle").mkdir(parents=True)
        self.header = self.repo / "tests/oracle/clay.h"
        self.header.write_text(
            "// synthetic header\n"
            "int covered(int value) {\n"
            "    return value ? 1 : 0;\n"
            "}\n",
            encoding="utf-8",
        )
        self.fixture = self.repo / "tests/oracle/example_fixture.c"
        self.fixture.write_text("int main(void) { return 0; }\n", encoding="utf-8")
        header_bytes = self.header.read_bytes()
        self.manifest = {
            "schema": coverage.SCHEMA,
            "header": {
                "path": "tests/oracle/clay.h",
                "sha256": hashlib.sha256(header_bytes).hexdigest(),
                "byte_count": len(header_bytes),
                "line_count": 4,
            },
            "line_inventory": {
                "executable_count": 3,
                "sha256": hashlib.sha256(b"2\n3\n4\n").hexdigest(),
            },
            "function_inventory": {"count": 1, "sha256": "0" * 64},
            "branch_inventory": {"count": 1, "sha256": "0" * 64},
            "profile": {
                **copy.deepcopy(coverage.EXPECTED_PROFILE),
                "fixtures": ["tests/oracle/example_fixture.c"],
            },
            "simd_supplement": {
                "profile": {
                    **copy.deepcopy(coverage.EXPECTED_SIMD_PROFILE),
                    "fixtures": ["tests/oracle/example_fixture.c"],
                },
                "source_ranges": [
                    {"start_line": start, "end_line": end}
                    for start, end in coverage.EXPECTED_SIMD_SOURCE_RANGES
                ],
                "line_inventory": {
                    "executable_count": 1,
                    "sha256": "0" * 64,
                },
                "function_inventory": {"count": 1, "sha256": "0" * 64},
                "branch_inventory": {"count": 1, "sha256": "0" * 64},
            },
            "excluded_lines": [],
            "excluded_functions": [],
            "excluded_branches": [
                {
                    "start_line": 3,
                    "start_column": 12,
                    "end_line": 3,
                    "end_column": 17,
                    "file_id": 0,
                    "expanded_file_id": 0,
                    "kind": 4,
                    "occurrence": 0,
                    "direction": "false",
                    "reason": "Synthetic unreachable branch direction",
                }
            ],
        }
        self.export = {
            "type": "llvm.coverage.json.export",
            "version": "3.1.0",
            "data": [
                {
                    "files": [
                        {
                            "filename": str(self.header.resolve()),
                            "branches": [[3, 12, 3, 17, 1, 0, 0, 0, 4]],
                            "summary": {
                                "regions": metric(2, 2),
                                "functions": metric(1, 1),
                                "lines": metric(3, 3),
                                "branches": metric(2, 1),
                            },
                        }
                    ],
                    "functions": [
                        {
                            "name": "example_fixture.c:covered",
                            "count": 1,
                            "filenames": [str(self.header.resolve())],
                            "regions": [[2, 1, 4, 2, 1, 0, 0, 0]],
                        }
                    ],
                }
            ]
        }
        self.line_view = (
            "    1|       |// synthetic header\n"
            "    2|      1|int covered(int value) {\n"
            "    3|      1|    return value ? 1 : 0;\n"
            "    4|      1|}\n"
        )
        file_record, functions = coverage._coverage_file(self.export, self.header)
        function_rows = coverage._function_inventory_rows(
            coverage._source_functions(functions, self.header)
        )
        branch_rows = coverage._branch_inventory_rows(file_record)
        self.manifest["function_inventory"] = {
            "count": len(function_rows),
            "sha256": coverage._canonical_inventory_digest(function_rows),
        }
        self.manifest["branch_inventory"] = {
            "count": len(branch_rows),
            "sha256": coverage._canonical_inventory_digest(branch_rows),
        }
        self.paths = {
            "manifest": self.repo / "manifest.json",
            "export": self.repo / "export.json",
            "report": self.repo / "report.txt",
            "line_view": self.repo / "lines.txt",
        }

    def write_inputs(self) -> None:
        self.paths["manifest"].write_text(
            json.dumps(self.manifest, sort_keys=True), encoding="utf-8"
        )
        self.paths["export"].write_text(
            json.dumps(self.export, sort_keys=True), encoding="utf-8"
        )
        summary = self.export["data"][0]["files"][0]["summary"]
        values: list[str] = ["TOTAL"]
        for name in ("regions", "functions", "lines", "branches"):
            current = summary[name]
            values.extend(
                (
                    str(current["count"]),
                    str(current["notcovered"]),
                    f"{current['percent']:.2f}%",
                )
            )
        self.paths["report"].write_text(" ".join(values) + "\n", encoding="utf-8")
        self.paths["line_view"].write_text(self.line_view, encoding="utf-8")

    def certify(self) -> coverage.CoverageResult:
        self.write_inputs()
        return coverage.certify(
            repo_root=self.repo,
            manifest_path=self.paths["manifest"],
            export_path=self.paths["export"],
            report_path=self.paths["report"],
            line_view_path=self.paths["line_view"],
        )

    def test_valid_accountable_contract_passes_with_separate_raw_metrics(self) -> None:
        result = self.certify()
        self.assertEqual(coverage.RawMetric(2, 1), result.raw["branches"])
        self.assertEqual(coverage.RawMetric(1, 1), result.accountable_branches)
        self.assertEqual(coverage.RawMetric(3, 3), result.accountable_lines)
        self.assertEqual(coverage.RawMetric(1, 1), result.accountable_functions)

    def test_fixture_inventory_addition_fails_closed(self) -> None:
        (self.repo / "tests/oracle/unmapped_fixture.c").write_text(
            "int main(void) { return 0; }\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(coverage.CoverageError, "fixture inventory drifted"):
            self.certify()

    def test_same_size_header_mutation_breaks_the_digest_pin(self) -> None:
        original = self.header.read_text(encoding="utf-8")
        self.header.write_text(original.replace("synthetic", "synthEtic"), encoding="utf-8")
        with self.assertRaisesRegex(coverage.CoverageError, "header digest changed"):
            self.certify()

    def test_export_must_prove_every_manifest_fixture_executed(self) -> None:
        self.export["data"][0]["functions"][0]["name"] = "other_fixture.c:covered"
        with self.assertRaisesRegex(
            coverage.CoverageError, "export fixture provenance differs"
        ):
            self.certify()

    def test_uncovered_line_requires_an_exact_disposition(self) -> None:
        self.line_view = self.line_view.replace("    3|      1|", "    3|      0|")
        self.export["data"][0]["files"][0]["summary"]["lines"] = metric(3, 2)
        with self.assertRaisesRegex(
            coverage.CoverageError, "unclassified uncovered mapped physical lines: 3"
        ):
            self.certify()

    def test_covered_line_makes_an_exception_stale(self) -> None:
        self.manifest["excluded_lines"] = [
            {"line": 3, "reason": "No longer genuinely uncovered"}
        ]
        with self.assertRaisesRegex(
            coverage.CoverageError, "stale or invalid mapped physical lines exclusions"
        ):
            self.certify()

    def test_exceptions_cannot_remove_an_entire_coverage_inventory(self) -> None:
        for line in (2, 3, 4):
            self.line_view = self.line_view.replace(
                f"    {line}|      1|", f"    {line}|      0|"
            )
        self.export["data"][0]["files"][0]["summary"]["lines"] = metric(3, 0)
        self.manifest["excluded_lines"] = [
            {"line": line, "reason": "Synthetic reviewed unreachable line"}
            for line in (2, 3, 4)
        ]
        with self.assertRaisesRegex(
            coverage.CoverageError, "exclusions remove the entire coverage inventory"
        ):
            self.certify()

    def test_uncovered_branch_direction_requires_an_exact_disposition(self) -> None:
        self.manifest["excluded_branches"] = []
        with self.assertRaisesRegex(
            coverage.CoverageError, "unclassified uncovered branch-record directions"
        ):
            self.certify()

    def test_covered_branch_direction_makes_an_exception_stale(self) -> None:
        self.export["data"][0]["files"][0]["branches"][0][5] = 1
        self.export["data"][0]["files"][0]["summary"]["branches"] = metric(2, 2)
        with self.assertRaisesRegex(
            coverage.CoverageError,
            "stale or invalid branch-record directions exclusions",
        ):
            self.certify()

    def test_uncovered_function_requires_an_exact_disposition(self) -> None:
        self.export["data"][0]["functions"][0]["count"] = 0
        self.export["data"][0]["files"][0]["summary"]["functions"] = metric(1, 0)
        with self.assertRaisesRegex(coverage.CoverageError, "unclassified uncovered functions"):
            self.certify()

    def test_zero_count_per_translation_unit_copy_does_not_hide_covered_definition(
        self,
    ) -> None:
        duplicate = copy.deepcopy(self.export["data"][0]["functions"][0])
        duplicate["count"] = 0
        self.export["data"][0]["functions"].append(duplicate)
        result = self.certify()
        self.assertEqual(coverage.RawMetric(1, 1), result.accountable_functions)

    def test_export_and_report_summary_drift_fails_closed(self) -> None:
        self.write_inputs()
        self.paths["report"].write_text(
            "TOTAL 2 1 50.00% 1 0 100.00% 3 0 100.00% 2 1 50.00%\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(coverage.CoverageError, "export/report summaries differ"):
            coverage.certify(
                repo_root=self.repo,
                manifest_path=self.paths["manifest"],
                export_path=self.paths["export"],
                report_path=self.paths["report"],
                line_view_path=self.paths["line_view"],
            )

    def test_report_percentage_requires_finite_percent_grammar(self) -> None:
        for invalid in ("nan%", "100.00"):
            with self.subTest(invalid=invalid):
                self.write_inputs()
                report = self.paths["report"].read_text(encoding="utf-8")
                self.paths["report"].write_text(
                    report.replace("100.00%", invalid, 1), encoding="utf-8"
                )
                with self.assertRaisesRegex(
                    coverage.CoverageError, "invalid llvm-cov report regions fields"
                ):
                    coverage.certify(
                        repo_root=self.repo,
                        manifest_path=self.paths["manifest"],
                        export_path=self.paths["export"],
                        report_path=self.paths["report"],
                        line_view_path=self.paths["line_view"],
                    )

    def test_export_percentage_must_match_covered_count(self) -> None:
        self.export["data"][0]["files"][0]["summary"]["regions"]["percent"] = 99.0
        with self.assertRaisesRegex(
            coverage.CoverageError, "summary.regions.percent is inconsistent"
        ):
            self.certify()

    def test_profile_drift_fails_closed(self) -> None:
        self.manifest["profile"]["language_standard"] = "c11"
        with self.assertRaisesRegex(coverage.CoverageError, "language_standard must be 'c99'"):
            self.certify()

    def test_simd_profile_drift_fails_closed(self) -> None:
        self.manifest["simd_supplement"]["profile"]["architecture"] = "aarch64"
        with self.assertRaisesRegex(
            coverage.CoverageError, "architecture must be 'x86_64'"
        ):
            self.certify()

    def test_export_type_and_major_version_are_pinned(self) -> None:
        self.export["type"] = "llvm.coverage.json.other"
        with self.assertRaisesRegex(coverage.CoverageError, "type is unsupported"):
            self.certify()

        self.export["type"] = "llvm.coverage.json.export"
        self.export["version"] = "4.0.0"
        with self.assertRaisesRegex(coverage.CoverageError, "major version must be 3"):
            self.certify()

    def test_covered_branch_record_rekeying_breaks_static_inventory(self) -> None:
        self.export["data"][0]["files"][0]["branches"][0][8] = 5
        with self.assertRaisesRegex(
            coverage.CoverageError, "scalar ordered branch-record inventory drifted"
        ):
            self.certify()

    def test_duplicate_json_keys_are_rejected(self) -> None:
        path = self.repo / "duplicate.json"
        path.write_text('{"schema": 1, "schema": 2}', encoding="utf-8")
        with self.assertRaisesRegex(coverage.CoverageError, "duplicate JSON key"):
            coverage._load_json(path, 1024)

    def test_non_finite_json_numbers_are_rejected(self) -> None:
        for constant in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(constant=constant):
                path = self.repo / "non-finite.json"
                path.write_text(f'{{"value": {constant}}}', encoding="utf-8")
                with self.assertRaisesRegex(
                    coverage.CoverageError, "non-finite JSON number"
                ):
                    coverage._load_json(path, 1024)

        overflow = self.repo / "overflow.json"
        overflow.write_text('{"value": 1e10000}', encoding="utf-8")
        with self.assertRaisesRegex(coverage.CoverageError, "non-finite value"):
            coverage._load_json(overflow, 1024)

    def test_pathological_json_number_tokens_are_rejected_cleanly(self) -> None:
        path = self.repo / "huge-number.json"
        path.write_text(
            '{"value": ' + "1" * (coverage.MAX_JSON_NUMBER_CHARS + 1) + "}",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(coverage.CoverageError, "integer token exceeds"):
            coverage._load_json(path, 1024)

    def test_inverted_function_source_range_is_rejected(self) -> None:
        self.export["data"][0]["functions"][0]["regions"][0][2:4] = [1, 1]
        with self.assertRaisesRegex(coverage.CoverageError, "inverted source range"):
            self.certify()

    def test_inverted_branch_source_range_is_rejected(self) -> None:
        self.export["data"][0]["files"][0]["branches"][0][2:4] = [2, 1]
        with self.assertRaisesRegex(coverage.CoverageError, "inverted source range"):
            self.certify()

    def test_bounded_reader_rejects_oversized_input(self) -> None:
        path = self.repo / "oversized.bin"
        path.write_bytes(b"12345")
        with self.assertRaisesRegex(coverage.CoverageError, "exceeds the 4-byte input limit"):
            coverage._read_limited(path, 4)

    def test_line_view_must_cover_the_exact_header(self) -> None:
        self.line_view = self.line_view.replace("    4|      1|}\n", "")
        with self.assertRaisesRegex(coverage.CoverageError, "exact pinned header"):
            self.certify()

    def test_line_view_rejects_non_llvm_count_spellings(self) -> None:
        for invalid in ("nan", "inf", "-1", "1e3"):
            with self.subTest(invalid=invalid):
                original = self.line_view
                self.line_view = self.line_view.replace("    2|      1|", f"    2|{invalid:>7}|")
                with self.assertRaisesRegex(
                    coverage.CoverageError, "unsupported llvm-cov execution count"
                ):
                    self.certify()
                self.line_view = original

    def test_pathological_line_view_number_tokens_are_rejected_cleanly(self) -> None:
        huge = "1" * (coverage.MAX_JSON_NUMBER_CHARS + 1)
        self.line_view = self.line_view.replace("    1|", f"{huge}|")
        with self.assertRaisesRegex(coverage.CoverageError, "line-number token exceeds"):
            self.certify()

    def test_line_view_accepts_grouped_and_scaled_llvm_counts(self) -> None:
        self.line_view = self.line_view.replace("    2|      1|", "    2|  1,234|")
        self.line_view = self.line_view.replace("    3|      1|", "    3|   1.5k|")
        self.certify()

    def test_blanking_an_uncovered_line_cannot_remove_it_from_scope(self) -> None:
        self.line_view = self.line_view.replace("    3|      1|", "    3|       |")
        self.export["data"][0]["files"][0]["summary"]["lines"] = metric(3, 2)
        with self.assertRaisesRegex(
            coverage.CoverageError, "mapped physical-line inventory drifted"
        ):
            self.certify()

    def test_mapped_line_misses_must_match_the_raw_summary(self) -> None:
        self.export["data"][0]["files"][0]["summary"]["lines"] = metric(3, 2)
        with self.assertRaisesRegex(
            coverage.CoverageError,
            "mapped physical-line misses differ from llvm-cov summary",
        ):
            self.certify()

    def test_duplicate_branch_record_miss_cannot_hide_behind_covered_coordinate(
        self,
    ) -> None:
        branch = self.export["data"][0]["files"][0]["branches"][0]
        branch[5] = 1
        duplicate = copy.deepcopy(branch)
        duplicate[5] = 0
        self.export["data"][0]["files"][0]["branches"].append(duplicate)
        self.export["data"][0]["files"][0]["summary"]["branches"] = metric(4, 3)
        branch_rows = coverage._branch_inventory_rows(
            self.export["data"][0]["files"][0]
        )
        self.manifest["branch_inventory"] = {
            "count": len(branch_rows),
            "sha256": coverage._canonical_inventory_digest(branch_rows),
        }
        self.manifest["excluded_branches"] = []
        with self.assertRaisesRegex(
            coverage.CoverageError,
            "unclassified uncovered branch-record directions",
        ):
            self.certify()


class ClaySimdCoverageCertificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        (self.repo / "tests/oracle").mkdir(parents=True)
        self.header = self.repo / "tests/oracle/clay.h"
        self.header.write_text(
            "".join(f"// synthetic line {line}\n" for line in range(1, 2039)),
            encoding="utf-8",
        )
        fixture_path = self.repo / "tests/oracle/example_fixture.c"
        fixture_path.write_text("int main(void) { return 0; }\n", encoding="utf-8")
        header_bytes = self.header.read_bytes()

        self.export = {
            "type": "llvm.coverage.json.export",
            "version": "3.1.0",
            "data": [
                {
                    "files": [
                        {
                            "filename": str(self.header.resolve()),
                            "branches": [[1475, 1, 1475, 2, 1, 1, 0, 0, 4]],
                            "summary": {
                                "regions": metric(1, 1),
                                "functions": metric(1, 1),
                                "lines": metric(1, 1),
                                "branches": metric(2, 2),
                            },
                        }
                    ],
                    "functions": [
                        {
                            "name": "example_fixture.c:simd_body",
                            "count": 1,
                            "filenames": [str(self.header.resolve())],
                            "regions": [[1475, 1, 1475, 2, 1, 0, 0, 0]],
                        }
                    ],
                }
            ],
        }
        file_record, functions = coverage._coverage_file(self.export, self.header)
        scoped_functions = coverage._source_functions(functions, self.header)
        function_rows = coverage._function_inventory_rows(scoped_functions)
        branch_rows = coverage._branch_inventory_rows(
            file_record, coverage.EXPECTED_SIMD_SOURCE_RANGES
        )
        self.manifest = {
            "schema": coverage.SCHEMA,
            "header": {
                "path": "tests/oracle/clay.h",
                "sha256": hashlib.sha256(header_bytes).hexdigest(),
                "byte_count": len(header_bytes),
                "line_count": 2038,
            },
            "line_inventory": {"executable_count": 1, "sha256": "0" * 64},
            "function_inventory": {"count": 1, "sha256": "0" * 64},
            "branch_inventory": {"count": 1, "sha256": "0" * 64},
            "profile": {
                **copy.deepcopy(coverage.EXPECTED_PROFILE),
                "fixtures": ["tests/oracle/example_fixture.c"],
            },
            "simd_supplement": {
                "profile": {
                    **copy.deepcopy(coverage.EXPECTED_SIMD_PROFILE),
                    "fixtures": ["tests/oracle/example_fixture.c"],
                },
                "source_ranges": [
                    {"start_line": start, "end_line": end}
                    for start, end in coverage.EXPECTED_SIMD_SOURCE_RANGES
                ],
                "line_inventory": {
                    "executable_count": 1,
                    "sha256": hashlib.sha256(b"1475\n").hexdigest(),
                },
                "function_inventory": {
                    "count": len(function_rows),
                    "sha256": coverage._canonical_inventory_digest(function_rows),
                },
                "branch_inventory": {
                    "count": len(branch_rows),
                    "sha256": coverage._canonical_inventory_digest(branch_rows),
                },
            },
            "excluded_lines": [],
            "excluded_functions": [],
            "excluded_branches": [],
        }
        self.line_view = "".join(
            f"{line:5d}|{'1' if line == 1475 else '':>8}|// synthetic line {line}\n"
            for line in range(1, 2039)
        )
        self.manifest_path = self.repo / "manifest.json"
        self.export_path = self.repo / "export.json"
        self.report_path = self.repo / "report.txt"
        self.line_view_path = self.repo / "lines.txt"

    def certify(self) -> coverage.SimdCoverageResult:
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")
        self.export_path.write_text(json.dumps(self.export), encoding="utf-8")
        summary = self.export["data"][0]["files"][0]["summary"]
        values: list[str] = ["TOTAL"]
        for name in ("regions", "functions", "lines", "branches"):
            current = summary[name]
            values.extend(
                (
                    str(current["count"]),
                    str(current["notcovered"]),
                    f"{current['percent']:.2f}%",
                )
            )
        self.report_path.write_text(" ".join(values) + "\n", encoding="utf-8")
        self.line_view_path.write_text(self.line_view, encoding="utf-8")
        return coverage.certify_simd_supplement(
            repo_root=self.repo,
            manifest_path=self.manifest_path,
            export_path=self.export_path,
            report_path=self.report_path,
            line_view_path=self.line_view_path,
        )

    def test_exact_x86_64_simd_scope_passes(self) -> None:
        result = self.certify()
        self.assertEqual(coverage.RawMetric(1, 1), result.scoped_lines)
        self.assertEqual(coverage.RawMetric(1, 1), result.scoped_functions)
        self.assertEqual(coverage.RawMetric(2, 2), result.scoped_branch_directions)

    def test_aarch64_helper_mapping_at_first_line_fails_closed(self) -> None:
        self.line_view = self.line_view.replace(
            f"{1528:5d}|{'':>8}|", f"{1528:5d}|{'1':>8}|"
        )
        with self.assertRaisesRegex(
            coverage.CoverageError, "activated a reviewed non-x86 implementation range"
        ):
            self.certify()

    def test_blanked_simd_line_cannot_leave_the_scoped_inventory(self) -> None:
        self.line_view = self.line_view.replace(
            f"{1475:5d}|{'1':>8}|", f"{1475:5d}|{'':>8}|"
        )
        with self.assertRaisesRegex(
            coverage.CoverageError, "mapped physical-line inventory drifted"
        ):
            self.certify()

    def test_missed_simd_line_fails_accountable_coverage(self) -> None:
        self.line_view = self.line_view.replace(
            f"{1475:5d}|{'1':>8}|", f"{1475:5d}|{'0':>8}|"
        )
        with self.assertRaisesRegex(
            coverage.CoverageError, "unclassified uncovered x86_64 SIMD lines"
        ):
            self.certify()

    def test_missing_simd_function_breaks_the_static_inventory(self) -> None:
        provenance_only = copy.deepcopy(self.export["data"][0]["functions"][0])
        provenance_only["regions"][0][0] = 1
        provenance_only["regions"][0][2] = 1
        self.export["data"][0]["functions"] = [provenance_only]
        with self.assertRaisesRegex(
            coverage.CoverageError, "x86_64 SIMD function inventory drifted"
        ):
            self.certify()

    def test_simd_branch_removal_or_rekey_breaks_the_static_inventory(self) -> None:
        branch = self.export["data"][0]["files"][0]["branches"][0]
        self.export["data"][0]["files"][0]["branches"] = []
        with self.assertRaisesRegex(
            coverage.CoverageError, "x86_64 SIMD ordered branch-record inventory drifted"
        ):
            self.certify()

        branch[8] = 5
        self.export["data"][0]["files"][0]["branches"] = [branch]
        with self.assertRaisesRegex(
            coverage.CoverageError, "x86_64 SIMD ordered branch-record inventory drifted"
        ):
            self.certify()


if __name__ == "__main__":
    unittest.main()
