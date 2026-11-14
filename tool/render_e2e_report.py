"""Render Flutify self-test E2E performance curve PNG and Markdown summary.

Reads `metrics.json` and `report.json` produced by `E2ERunner` inside an output
directory and generates:
  - `performance_curve.png`: 3-panel time-series chart (FPS, Frame Timings, RSS)
    with shaded test-phase spans and summary KPI header.
  - `summary.md`: Markdown report detailing performance metrics and per-feature
    PASS/FAIL results.

Usage:
  python tool/render_e2e_report.py <e2e_output_dir> [--fail-on-error]
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any

try:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt  # noqa: E402
    from matplotlib.patches import Patch  # noqa: E402

    HAS_MATPLOTLIB = True
except ImportError:  # pragma: no cover - optional in vanilla CI unit-test job
    matplotlib = None  # type: ignore[assignment]
    plt = None  # type: ignore[assignment]
    Patch = None  # type: ignore[assignment]
    HAS_MATPLOTLIB = False


PHASE_COLORS = [
    "#3b82f6",
    "#8b5cf6",
    "#06b6d4",
    "#10b981",
    "#f59e0b",
    "#ec4899",
    "#6366f1",
    "#14b8a6",
    "#f97316",
    "#84cc16",
]


def load_e2e_data(out_dir: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    """Load metrics.json and report.json from an E2E output directory."""
    metrics_path = out_dir / "metrics.json"
    report_path = out_dir / "report.json"
    if not metrics_path.is_file():
        raise FileNotFoundError(f"Missing metrics.json at {metrics_path}")
    metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
    if report_path.is_file():
        report = json.loads(report_path.read_text(encoding="utf-8"))
    else:
        report = {
            "platform": metrics.get("platform", "unknown"),
            "releaseTag": metrics.get("releaseTag", ""),
            "appVersion": metrics.get("appVersion", ""),
            "allPassed": False,
            "passed": 0,
            "failed": 0,
            "totalDurationMs": metrics.get("totalDurationMs", 0),
            "performance": {},
            "errors": ["Missing report.json"],
            "checks": [],
        }
    return metrics, report


def _rolling_mean(values: list[float], window: int = 7) -> list[float]:
    if not values:
        return []
    out: list[float] = []
    half = window // 2
    for i in range(len(values)):
        lo = max(0, i - half)
        hi = min(len(values), i + half + 1)
        out.append(sum(values[lo:hi]) / (hi - lo))
    return out


def compute_perf_summary(
    metrics: dict[str, Any], report: dict[str, Any]
) -> dict[str, float | int]:
    """Compute fallback performance stats when report.performance is sparse."""
    perf = dict(report.get("performance") or {})
    frames = metrics.get("frames") or []
    totals = sorted(float(f.get("totalMs", 0.0)) for f in frames)
    rss_values = [float(f.get("rssMb", 0.0)) for f in frames if f.get("rssMb")]

    def percentile(sorted_vals: list[float], p: float) -> float:
        if not sorted_vals:
            return 0.0
        idx = min(
            len(sorted_vals) - 1,
            max(0, int(math.ceil(p * len(sorted_vals)) - 1)),
        )
        return sorted_vals[idx]

    count = int(perf.get("frameCount", len(totals)))
    avg_total = (sum(totals) / len(totals)) if totals else 0.0
    avg_fps = float(
        perf.get(
            "avgBudgetFps",
            min(120.0, 1000.0 / avg_total) if avg_total > 0 else 0.0,
        )
    )
    return {
        "frameCount": count,
        "avgBudgetFps": round(avg_fps, 2),
        "p50FrameMs": round(float(perf.get("p50FrameMs", percentile(totals, 0.50))), 2),
        "p95FrameMs": round(float(perf.get("p95FrameMs", percentile(totals, 0.95))), 2),
        "maxFrameMs": round(
            float(perf.get("maxFrameMs", totals[-1] if totals else 0.0)), 2
        ),
        "jankOver16ms": int(
            perf.get("jankOver16ms", sum(1 for v in totals if v > 16.67))
        ),
        "jankOver33ms": int(
            perf.get("jankOver33ms", sum(1 for v in totals if v > 33.33))
        ),
        "peakRssMb": round(
            float(perf.get("peakRssMb", max(rss_values) if rss_values else 0.0)), 2
        ),
    }


def _short_phase_label(name: str) -> str:
    if name.startswith("theme_"):
        return name.removeprefix("theme_").replace("_", " ")
    return name.replace("_", " ")


def _shade_phases(ax: Any, phases: list[dict[str, Any]], label_top: bool = False) -> None:
    for idx, ph in enumerate(phases):
        start_s = float(ph.get("startMs", 0)) / 1000.0
        end_s = float(ph.get("endMs", start_s * 1000)) / 1000.0
        if end_s <= start_s:
            continue
        color = PHASE_COLORS[idx % len(PHASE_COLORS)]
        ax.axvspan(start_s, end_s, color=color, alpha=0.075, lw=0)
        if label_top and (end_s - start_s) >= 0.45:
            mid = (start_s + end_s) / 2.0
            ax.text(
                mid,
                0.96,
                _short_phase_label(str(ph.get("phase", ""))),
                transform=ax.get_xaxis_transform(),
                ha="center",
                va="top",
                fontsize=6.5,
                rotation=20,
                color="#334155",
                alpha=0.85,
                clip_on=True,
            )


def render_chart(
    out_dir: Path, metrics: dict[str, Any], report: dict[str, Any]
) -> Path:
    """Plot 3-panel FPS, Frame Timings, and RSS performance curve to PNG."""
    if not HAS_MATPLOTLIB:
        raise RuntimeError(
            "matplotlib is required to render performance_curve.png "
            "(install with: pip install matplotlib)"
        )
    frames = metrics.get("frames") or []
    phases = metrics.get("phases") or []
    perf = compute_perf_summary(metrics, report)

    t_sec = [float(f.get("tMs", 0.0)) / 1000.0 for f in frames]
    build_ms = [float(f.get("buildMs", 0.0)) for f in frames]
    raster_ms = [float(f.get("rasterMs", 0.0)) for f in frames]
    total_ms = [float(f.get("totalMs", 0.0)) for f in frames]
    rss_mb = [float(f.get("rssMb", 0.0)) for f in frames]
    budget_fps = [
        min(120.0, 1000.0 / max(ms, 0.5)) if ms > 0 else 120.0 for ms in total_ms
    ]
    smooth_fps = _rolling_mean(budget_fps, window=9)

    fig, axes = plt.subplots(
        3,
        1,
        figsize=(14, 9.2),
        sharex=True,
        gridspec_kw={"height_ratios": [1.05, 1.2, 0.85], "hspace": 0.20},
    )
    fig.patch.set_facecolor("#ffffff")

    platform = str(report.get("platform") or metrics.get("platform") or "unknown")
    app_ver = str(report.get("appVersion") or metrics.get("appVersion") or "")
    rel_tag = str(report.get("releaseTag") or metrics.get("releaseTag") or "")
    passed = int(report.get("passed", 0))
    failed = int(report.get("failed", 0))
    total_checks = passed + failed
    status_text = "PASS" if report.get("allPassed") else f"FAIL ({failed} failed)"
    shot_count = int(metrics.get("screenshotCount", len(metrics.get("screenshots") or [])))
    dur_s = float(metrics.get("totalDurationMs", 0)) / 1000.0

    title = (
        f"Flutify E2E Performance Profile — {platform.upper()} "
        f"({app_ver} / {rel_tag or 'self-test'}) — {status_text} "
        f"[{passed}/{total_checks} checks, {dur_s:.1f}s, {shot_count} screenshots]"
    )
    subtitle = (
        f"Frames: {perf['frameCount']} | Avg Budget FPS: {perf['avgBudgetFps']} | "
        f"P50: {perf['p50FrameMs']} ms | P95: {perf['p95FrameMs']} ms | "
        f"Max: {perf['maxFrameMs']} ms | Jank >16.7ms: {perf['jankOver16ms']} | "
        f"Peak RSS: {perf['peakRssMb']} MB"
    )
    fig.suptitle(title, fontsize=12.5, fontweight="bold", y=0.975, color="#0f172a")
    fig.text(0.5, 0.942, subtitle, ha="center", fontsize=9.2, color="#475569")

    max_t = max(t_sec[-1] if t_sec else 1.0, dur_s, 1.0)
    for idx, ax in enumerate(axes):
        ax.set_facecolor("#f8fafc")
        ax.grid(True, linestyle="--", alpha=0.45, color="#cbd5e1")
        ax.set_xlim(0.0, max_t)
        _shade_phases(ax, phases, label_top=(idx == 0))

    # Panel 1: FPS curve
    ax_fps = axes[0]
    if t_sec:
        ax_fps.plot(t_sec, budget_fps, color="#93c5fd", linewidth=0.8, alpha=0.55, label="Instant budget FPS")
        ax_fps.plot(t_sec, smooth_fps, color="#2563eb", linewidth=1.8, label="Rolling budget FPS (9f)")
    ax_fps.axhline(60.0, color="#16a34a", linestyle=":", linewidth=1.1, label="60 FPS target")
    ax_fps.axhline(30.0, color="#f59e0b", linestyle=":", linewidth=1.0, label="30 FPS floor")
    ax_fps.set_ylabel("Budget FPS")
    ax_fps.set_ylim(0, 158)
    ax_fps.legend(loc="lower left", ncol=4, fontsize=8, framealpha=0.88)

    # Panel 2: Build / Raster / Total frame durations
    ax_ms = axes[1]
    if t_sec:
        ax_ms.plot(t_sec, total_ms, color="#ef4444", linewidth=1.25, label="Total span (ms)")
        ax_ms.plot(t_sec, build_ms, color="#0ea5e9", linewidth=1.0, alpha=0.85, label="UI build (ms)")
        ax_ms.plot(t_sec, raster_ms, color="#8b5cf6", linewidth=1.0, alpha=0.85, label="Raster (ms)")
    ax_ms.axhline(16.67, color="#16a34a", linestyle="--", linewidth=1.0, label="16.67 ms (60Hz)")
    ax_ms.axhline(33.33, color="#dc2626", linestyle="--", linewidth=0.9, alpha=0.75, label="33.33 ms (30Hz)")
    p99_cap = max(
        40.0,
        statistics.quantiles(total_ms, n=100)[-1] * 1.15 if len(total_ms) >= 20 else (max(total_ms) * 1.15 if total_ms else 40.0),
    )
    ax_ms.set_ylim(0, min(p99_cap, max(total_ms or [40.0]) * 1.1 + 5.0))
    ax_ms.set_ylabel("Frame Time (ms)")
    ax_ms.legend(loc="upper right", ncol=5, fontsize=8, framealpha=0.88)

    # Panel 3: Process RSS memory
    ax_mem = axes[2]
    if t_sec and any(v > 0 for v in rss_mb):
        ax_mem.fill_between(t_sec, rss_mb, color="#10b981", alpha=0.18)
        ax_mem.plot(t_sec, rss_mb, color="#059669", linewidth=1.6, label="Process RSS (MB)")
        mem_min = max(0.0, min(rss_mb) * 0.9)
        mem_max = max(rss_mb) * 1.12
        if mem_max > mem_min:
            ax_mem.set_ylim(mem_min, mem_max)
    else:
        ax_mem.text(0.5, 0.5, "RSS memory unavailable", ha="center", va="center", transform=ax_mem.transAxes)
    ax_mem.set_ylabel("Memory (MB)")
    ax_mem.set_xlabel("Elapsed Time (s)")
    if t_sec and any(v > 0 for v in rss_mb):
        ax_mem.legend(loc="upper left", fontsize=8, framealpha=0.88)

    # Bottom phase legend when there are phases
    phase_patches = []
    seen_names: set[str] = set()
    for idx, ph in enumerate(phases):
        name = _short_phase_label(str(ph.get("phase", "")))
        if not name or name in seen_names:
            continue
        seen_names.add(name)
        phase_patches.append(
            Patch(facecolor=PHASE_COLORS[idx % len(PHASE_COLORS)], alpha=0.35, label=name)
        )
    if phase_patches:
        fig.legend(
            handles=phase_patches[:12],
            loc="lower center",
            ncol=min(6, len(phase_patches)),
            fontsize=7.5,
            frameon=False,
            bbox_to_anchor=(0.5, 0.005),
        )
        fig.subplots_adjust(top=0.90, bottom=0.11, left=0.065, right=0.98)
    else:
        fig.subplots_adjust(top=0.90, bottom=0.07, left=0.065, right=0.98)

    chart_path = out_dir / "performance_curve.png"
    fig.savefig(chart_path, dpi=160)
    plt.close(fig)
    return chart_path


def render_summary_markdown(
    out_dir: Path, metrics: dict[str, Any], report: dict[str, Any]
) -> Path:
    """Write human-readable Markdown report summary.md."""
    perf = compute_perf_summary(metrics, report)
    platform = str(report.get("platform") or metrics.get("platform") or "unknown")
    all_passed = bool(report.get("allPassed"))
    passed = int(report.get("passed", 0))
    failed = int(report.get("failed", 0))
    dur_s = float(report.get("totalDurationMs", metrics.get("totalDurationMs", 0))) / 1000.0
    shots = int(metrics.get("screenshotCount", len(metrics.get("screenshots") or [])))

    lines = [
        f"# Flutify Self-Test E2E Report — {platform.upper()}",
        "",
        f"- **Status**: {'PASS' if all_passed else 'FAIL'} ({passed} passed, {failed} failed)",
        f"- **Version**: `{report.get('appVersion', '')}` (`{report.get('releaseTag', '')}`)",
        f"- **Duration**: {dur_s:.2f} s",
        f"- **Screenshots (0.3s cadence)**: {shots}",
    ]
    upgrade_file = out_dir / "upgrade_result.json"
    if upgrade_file.is_file():
        try:
            up = json.loads(upgrade_file.read_text(encoding="utf-8"))
            if up.get("upgradedViaSettings"):
                seed_note = (
                    f" (seeded from `{up['seededFromTag']}`)"
                    if up.get("seededFromTag")
                    else ""
                )
                lines.append(
                    f"- **Settings Self-Test Upgrade**: PASS (`{up.get('previousVersionName', '')}` "
                    f"[{up.get('previousVersionCode')}] -> `{up.get('newVersionName', '')}` "
                    f"[{up.get('newVersionCode')}]){seed_note}"
                )
            elif up.get("initialSeed"):
                lines.append(
                    f"- **Settings Self-Test Upgrade**: Initial seed `{up.get('targetTag', '')}` "
                    f"[{up.get('newVersionCode')}] retained on persistent box for next upgrade"
                )
            elif up.get("alreadyUpToDate"):
                lines.append(
                    f"- **Settings Self-Test Upgrade**: Already at `{up.get('targetTag', '')}` "
                    f"[{up.get('newVersionCode')}]"
                )
        except Exception:
            pass
    lines.extend([
        "",
        "## Performance Summary",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| Frames recorded | {perf['frameCount']} |",
        f"| Avg budget FPS | {perf['avgBudgetFps']} |",
        f"| P50 frame time | {perf['p50FrameMs']} ms |",
        f"| P95 frame time | {perf['p95FrameMs']} ms |",
        f"| Max frame time | {perf['maxFrameMs']} ms |",
        f"| Jank (>16.67 ms) | {perf['jankOver16ms']} |",
        f"| Severe jank (>33.33 ms) | {perf['jankOver33ms']} |",
        f"| Peak RSS memory | {perf['peakRssMb']} MB |",
        "",
        "## Feature & Theme Checks",
        "",
        "| Check | Status | Duration (ms) | Detail |",
        "|---|---|---|---|",
    ])
    for chk in report.get("checks") or []:
        name = str(chk.get("name", ""))
        status = "PASS" if chk.get("passed") else "FAIL"
        duration = int(chk.get("durationMs", 0))
        detail = str(chk.get("detail", "")).replace("|", "\\|").replace("\n", " ")
        lines.append(f"| `{name}` | {status} | {duration} | {detail} |")

    errors = report.get("errors") or []
    if errors:
        lines.extend(["", "## Unhandled Errors", ""])
        for err in errors:
            lines.append(f"- `{err}`")

    lines.append("")
    summary_path = out_dir / "summary.md"
    summary_path.write_text("\n".join(lines), encoding="utf-8")
    return summary_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Render Flutify E2E charts and summary")
    parser.add_argument("output_dir", type=Path, help="Directory with metrics.json and report.json")
    parser.add_argument(
        "--fail-on-error",
        action="store_true",
        help="Exit non-zero if report.allPassed is false",
    )
    args = parser.parse_args(argv)

    metrics, report = load_e2e_data(args.output_dir)
    chart_path = render_chart(args.output_dir, metrics, report)
    summary_path = render_summary_markdown(args.output_dir, metrics, report)
    print(f"Generated {chart_path} and {summary_path}")

    if args.fail_on_error and not bool(report.get("allPassed")):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
