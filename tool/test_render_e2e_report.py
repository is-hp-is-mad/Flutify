"""Unit tests for tool/render_e2e_report.py."""

import json
import tempfile
import unittest
from pathlib import Path

from tool import render_e2e_report as sut


def _write_sample_e2e_dir(root: Path, *, all_passed: bool = True) -> None:
    metrics = {
        "platform": "windows",
        "osVersion": "Windows 11",
        "releaseTag": "v0.18.1-selftest",
        "appVersion": "0.18.1-selftest",
        "totalDurationMs": 2400,
        "frameCount": 12,
        "screenshotCount": 3,
        "phases": [
            {"phase": "startup", "startMs": 0, "endMs": 600},
            {"phase": "home_feed", "startMs": 600, "endMs": 1400},
            {"phase": "theme_hyper_dark_dynamic", "startMs": 1400, "endMs": 2400},
        ],
        "frames": [
            {
                "tMs": i * 200,
                "buildMs": 2.5 + (i % 3) * 0.8,
                "rasterMs": 3.0 + (i % 4) * 1.1,
                "totalMs": 6.5 + (i % 4) * 2.5,
                "vsyncOverheadMs": 0.4,
                "phase": "home_feed" if i >= 3 else "startup",
                "rssMb": 140.0 + i * 1.2,
            }
            for i in range(12)
        ],
        "screenshots": [
            {
                "index": i + 1,
                "file": f"screenshots/shot_000{i + 1}.png",
                "tMs": (i + 1) * 300,
                "phase": "home_feed",
                "width": 1280,
                "height": 720,
            }
            for i in range(3)
        ],
    }
    report = {
        "platform": "windows",
        "releaseTag": "v0.18.1-selftest",
        "appVersion": "0.18.1-selftest",
        "allPassed": all_passed,
        "passed": 2 if all_passed else 1,
        "failed": 0 if all_passed else 1,
        "totalDurationMs": 2400,
        "performance": {
            "frameCount": 12,
            "avgBudgetFps": 95.2,
            "p50FrameMs": 9.0,
            "p95FrameMs": 14.0,
            "maxFrameMs": 14.0,
            "jankOver16ms": 0,
            "jankOver33ms": 0,
            "peakRssMb": 153.2,
        },
        "errors": [] if all_passed else ["Simulated failure"],
        "checks": [
            {
                "name": "home_feed",
                "passed": True,
                "durationMs": 800,
                "detail": "Home chips and scroll ok",
            },
            {
                "name": "themes_matrix",
                "passed": all_passed,
                "durationMs": 1000,
                "detail": "Liquid + Hyper themes ok" if all_passed else "Failed theme check",
            },
        ],
    }
    (root / "metrics.json").write_text(json.dumps(metrics), encoding="utf-8")
    (root / "report.json").write_text(json.dumps(report), encoding="utf-8")


class RenderE2EReportTest(unittest.TestCase):
    def test_generates_markdown_summary_without_optional_deps(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            _write_sample_e2e_dir(out_dir, all_passed=True)
            metrics, report = sut.load_e2e_data(out_dir)
            md = sut.render_summary_markdown(out_dir, metrics, report)
            text = md.read_text(encoding="utf-8")
            self.assertIn("Flutify Self-Test E2E Report — WINDOWS", text)
            self.assertIn("PASS", text)
            self.assertIn("`home_feed`", text)
            self.assertIn("`themes_matrix`", text)

    def test_summary_includes_upgrade_receipt_when_present(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            _write_sample_e2e_dir(out_dir, all_passed=True)
            (out_dir / "upgrade_result.json").write_text(
                json.dumps(
                    {
                        "upgradedViaSettings": True,
                        "previousVersionCode": 2404001,
                        "previousVersionName": "0.0.21",
                        "newVersionCode": 2414001,
                        "newVersionName": "0.0.22",
                    }
                ),
                encoding="utf-8",
            )
            metrics, report = sut.load_e2e_data(out_dir)
            md = sut.render_summary_markdown(out_dir, metrics, report)
            text = md.read_text(encoding="utf-8")
            self.assertIn("Settings Self-Test Upgrade", text)
            self.assertIn("2404001", text)
            self.assertIn("2414001", text)

    @unittest.skipUnless(sut.HAS_MATPLOTLIB, "Requires matplotlib")
    def test_generates_png_chart_and_markdown_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            _write_sample_e2e_dir(out_dir, all_passed=True)
            exit_code = sut.main([str(out_dir), "--fail-on-error"])
            self.assertEqual(exit_code, 0)

            png = out_dir / "performance_curve.png"
            md = out_dir / "summary.md"
            self.assertTrue(png.is_file())
            self.assertGreater(png.stat().st_size, 5000)
            self.assertEqual(png.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")

            text = md.read_text(encoding="utf-8")
            self.assertIn("Flutify Self-Test E2E Report — WINDOWS", text)
            self.assertIn("PASS", text)

    @unittest.skipUnless(sut.HAS_MATPLOTLIB, "Requires matplotlib")
    def test_fail_on_error_returns_nonzero_after_writing_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            _write_sample_e2e_dir(out_dir, all_passed=False)
            exit_code = sut.main([str(out_dir), "--fail-on-error"])
            self.assertEqual(exit_code, 1)
            self.assertTrue((out_dir / "performance_curve.png").is_file())
            self.assertIn(
                "Simulated failure",
                (out_dir / "summary.md").read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
