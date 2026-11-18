import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../core/constants/app_info.dart';

/// 单个 E2E 检查项的结果。
class E2ECheckResult {
  final String name;
  final bool passed;
  final int durationMs;
  final String detail;

  const E2ECheckResult({
    required this.name,
    required this.passed,
    required this.durationMs,
    this.detail = '',
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'passed': passed,
    'durationMs': durationMs,
    'detail': detail,
  };
}

/// E2E 自测性能统计与报告落盘器（生成 `metrics.json`、`e2e.log`、`report.json` 与 `DONE`）。
class E2EReportWriter {
  E2EReportWriter._();

  static double round2(double v) => (v * 100).roundToDouble() / 100.0;

  static Map<String, dynamic> computeSummary({
    required List<Map<String, dynamic>> frameSamples,
    required double currentRssMb,
  }) {
    if (frameSamples.isEmpty) {
      return {
        'frameCount': 0,
        'avgFps': 0.0,
        'p50FrameMs': 0.0,
        'p95FrameMs': 0.0,
        'maxFrameMs': 0.0,
        'jankOver16ms': 0,
        'jankOver33ms': 0,
        'peakRssMb': round2(currentRssMb),
      };
    }
    final totals = [
      for (final f in frameSamples) (f['totalMs'] as num).toDouble(),
    ]..sort();
    final avgTotal = totals.reduce((a, b) => a + b) / totals.length;
    final p50 = totals[(totals.length * 0.5).floor().clamp(0, totals.length - 1)];
    final p95 = totals[(totals.length * 0.95).floor().clamp(0, totals.length - 1)];
    final maxMs = totals.last;
    final jank16 = totals.where((v) => v > 16.67).length;
    final jank33 = totals.where((v) => v > 33.33).length;
    final peakRss = frameSamples
        .map((f) => (f['rssMb'] as num).toDouble())
        .reduce(math.max);
    return {
      'frameCount': totals.length,
      'avgBudgetFps': round2(
        avgTotal > 0 ? math.min(120.0, 1000.0 / avgTotal) : 0.0,
      ),
      'p50FrameMs': round2(p50),
      'p95FrameMs': round2(p95),
      'maxFrameMs': round2(maxMs),
      'jankOver16ms': jank16,
      'jankOver33ms': jank33,
      'peakRssMb': round2(peakRss),
    };
  }

  static Future<void> writeAll({
    required Directory outDir,
    required int totalDurationMs,
    required List<Map<String, dynamic>> frameSamples,
    required List<Map<String, dynamic>> screenshots,
    required List<String> screenshotErrors,
    required List<Map<String, dynamic>> phaseSpans,
    required List<String> logLines,
    required List<String> capturedErrors,
    required List<E2ECheckResult> results,
    required double currentRssMb,
  }) async {
    final metrics = {
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'releaseTag': AppInfo.releaseTag,
      'appVersion': AppInfo.displayVersion,
      'totalDurationMs': totalDurationMs,
      'frameCount': frameSamples.length,
      'screenshotCount': screenshots.length,
      'screenshotErrors': screenshotErrors,
      'phases': phaseSpans,
      'frames': frameSamples,
      'screenshots': screenshots,
    };
    await File(
      p.join(outDir.path, 'metrics.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(metrics));

    if (logLines.isNotEmpty) {
      await File(
        p.join(outDir.path, 'e2e.log'),
      ).writeAsString('${logLines.join('\n')}\n');
    }

    final summary = computeSummary(
      frameSamples: frameSamples,
      currentRssMb: currentRssMb,
    );
    final passedCount = results.where((r) => r.passed).length;
    final failedCount = results.length - passedCount;

    final report = {
      'platform': Platform.operatingSystem,
      'releaseTag': AppInfo.releaseTag,
      'appVersion': AppInfo.displayVersion,
      'allPassed': failedCount == 0 && results.isNotEmpty,
      'passed': passedCount,
      'failed': failedCount,
      'totalDurationMs': totalDurationMs,
      'performance': summary,
      'errors': capturedErrors,
      'checks': [for (final r in results) r.toJson()],
    };
    await File(
      p.join(outDir.path, 'report.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));

    await File(
      p.join(outDir.path, 'DONE'),
    ).writeAsString(failedCount == 0 ? 'ok\n' : 'fail\n');
  }
}
