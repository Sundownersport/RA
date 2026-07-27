#!/usr/bin/env python3
"""Aggregate MLP1 shader performance reports into a qualification matrix."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


def build_matrix(root: Path, expected_cases: int) -> tuple[dict[str, Any], bool]:
    reports = [
        json.loads(path.read_text(encoding="utf-8"))
        for path in sorted(root.glob("*/*/report.json"))
    ]
    failures = [
        {
            "preset": report.get("preset"),
            "core": report.get("core"),
            "content_class": report.get("content_class"),
            "display_mode": report.get("display_mode"),
            "bfi": report.get("bfi"),
            "reasons": report.get("failure_reasons", []),
        }
        for report in reports
        if report.get("qualification") != "pass"
    ]
    if len(reports) != expected_cases:
        failures.append(
            {
                "reason": (
                    f"found {len(reports)} reports; expected {expected_cases}"
                )
            }
        )

    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for report in reports:
        grouped[str(report["preset"])].append(report)

    presets = []
    for preset, rows in sorted(grouped.items()):
        presets.append(
            {
                "preset": preset,
                "case_count": len(rows),
                "qualification": (
                    "pass"
                    if all(row["qualification"] == "pass" for row in rows)
                    else "fail"
                ),
                "minimum_average_fps": min(
                    float(row["metrics"]["average_fps"]) for row in rows
                ),
                "maximum_frame_time_p95_ms": max(
                    float(row["metrics"]["maximum_frame_time_p95_ms"])
                    for row in rows
                ),
                "maximum_dropped_frames_during_sample_window": max(
                    int(row["metrics"]["dropped_frames_during_sample_window"])
                    for row in rows
                ),
                "maximum_audio_underrun_pct": max(
                    float(row["metrics"]["maximum_audio_underrun_pct"])
                    for row in rows
                ),
                "display_modes": sorted(
                    {
                        f"{row['display_mode']} BFI={row['bfi']}"
                        for row in rows
                    }
                ),
                "content_classes": sorted(
                    {str(row["content_class"]) for row in rows}
                ),
            }
        )

    builds = {
        json.dumps(report["retroarch_build"], sort_keys=True)
        for report in reports
    }
    sources = {
        json.dumps(
            report.get("shader_sources", [report["shader_source"]]),
            sort_keys=True,
        )
        for report in reports
    }
    if len(builds) > 1:
        failures.append({"reason": "reports used different RetroArch builds"})
    if len(sources) > 1:
        failures.append({"reason": "reports used different shader source pins"})

    matrix = {
        "schema_version": 1,
        "platform": "mlp1",
        "protocol": {
            "measurement_seconds": 60,
            "warmup_seconds": 10,
            "sample_interval_seconds": 15,
            "acceptance_average_fps": 59.0,
        },
        "expected_case_count": expected_cases,
        "report_count": len(reports),
        "qualification": "pass" if not failures else "fail",
        "failures": failures,
        "retroarch_build": json.loads(next(iter(builds))) if len(builds) == 1 else None,
        "shader_sources": (
            json.loads(next(iter(sources))) if len(sources) == 1 else None
        ),
        "shader_source": (
            json.loads(next(iter(sources)))[0] if len(sources) == 1 else None
        ),
        "presets": presets,
    }
    return matrix, not failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix-root", type=Path, required=True)
    parser.add_argument("--expected-cases", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    matrix, passed = build_matrix(args.matrix_root, args.expected_cases)
    args.output.write_text(
        json.dumps(matrix, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"{matrix['qualification']}: reports={matrix['report_count']}/"
        f"{matrix['expected_case_count']} presets={len(matrix['presets'])}"
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
