#!/usr/bin/env python3
"""Parse RetroArch performance replies and write an MLP1 shader report."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
from pathlib import Path
from typing import Any


PERF_PREFIX = "GET_PERF_INFO "
INTEGER_FIELDS = {
    "ready",
    "samples",
    "frames",
    "dropped",
    "audio_ready",
    "audio_samples",
}
FLOAT_FIELDS = {
    "fps",
    "frame_time_p95_ms",
    "deviation_pct",
    "audio_underrun_pct",
    "audio_blocking_pct",
}


def parse_perf_info(text: str) -> dict[str, float | int]:
    """Return fields from the MLP1 GET_PERF_INFO command reply."""
    reply = ""
    for line in text.splitlines():
        candidate = line.strip().removeprefix("reply=")
        if candidate.startswith(PERF_PREFIX):
            reply = candidate
            break
    if not reply:
        return {}

    values: dict[str, float | int] = {}
    for key, raw in re.findall(r"([a-z0-9_]+)=([-+]?[0-9]+(?:\.[0-9]+)?)", reply):
        if key in INTEGER_FIELDS:
            values["dropped_frames" if key == "dropped" else key] = int(raw)
        elif key in FLOAT_FIELDS:
            values[key] = float(raw)
    return values


def read_temperatures(path: Path) -> dict[str, float]:
    temperatures: dict[str, float] = {}
    if not path.is_file():
        return temperatures
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            temperatures[fields[0]] = int(fields[1]) / 1000.0
        except ValueError:
            continue
    return temperatures


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_report(args: argparse.Namespace) -> tuple[dict[str, Any], bool]:
    shader_manifest = json.loads(args.shader_manifest.read_text(encoding="utf-8"))
    retroarch_build = json.loads(
        args.retroarch_build_manifest.read_text(encoding="utf-8")
    )
    baseline = parse_perf_info(
        args.baseline.read_text(encoding="utf-8", errors="replace")
    )
    sample_rows = []
    for path in sorted(args.samples.glob("sample-*.txt")):
        values = parse_perf_info(path.read_text(encoding="utf-8", errors="replace"))
        values["sample"] = path.stem
        sample_rows.append(values)

    complete = [
        row
        for row in sample_rows
        if row.get("ready") == 1
        and {
            "fps",
            "frame_time_p95_ms",
            "dropped_frames",
            "audio_underrun_pct",
        }
        <= set(row)
    ]
    expected_samples = max(1, args.duration_seconds // args.sample_interval_seconds)
    minimum_samples = min(3, expected_samples)
    failures = []
    if len(complete) < minimum_samples:
        failures.append(
            f"only {len(complete)} complete statistics samples; "
            f"{minimum_samples} required"
        )

    metrics: dict[str, Any] = {
        "sample_count": len(complete),
        "expected_sample_count": expected_samples,
    }
    if complete:
        final = complete[-1]
        metrics.update(
            {
                "average_fps": float(final["fps"]),
                "snapshot_average_fps": round(
                    statistics.fmean(float(row["fps"]) for row in complete), 3
                ),
                "median_fps": round(
                    statistics.median(float(row["fps"]) for row in complete), 3
                ),
                "minimum_fps": min(float(row["fps"]) for row in complete),
                "maximum_frame_time_p95_ms": max(
                    float(row["frame_time_p95_ms"]) for row in complete
                ),
                "maximum_frame_time_deviation_pct": max(
                    float(row.get("deviation_pct", 0.0))
                    for row in complete
                ),
                "maximum_dropped_frames": max(
                    int(row["dropped_frames"]) for row in complete
                ),
                "dropped_frames_during_sample_window": max(
                    0,
                    int(final["dropped_frames"])
                    - int(baseline.get("dropped_frames", 0)),
                ),
                "maximum_audio_underrun_pct": max(
                    float(row["audio_underrun_pct"]) for row in complete
                ),
                "maximum_audio_blocking_pct": max(
                    float(row.get("audio_blocking_pct", 0.0))
                    for row in complete
                ),
            }
        )
        if metrics["average_fps"] < 59.0:
            failures.append(f"average FPS is {metrics['average_fps']}, below 59.0")
        if not any(int(row.get("audio_ready", 0)) == 1 for row in complete):
            failures.append("RetroArch did not provide audio buffer statistics")

    log_text = args.log.read_text(encoding="utf-8", errors="replace")
    log_failures = [
        line
        for line in log_text.splitlines()
        if re.search(
            r"(shader|glsl).*(failed|failure|compile error|link error)"
            r"|failed to (compile|link)"
            r"|\b(xrun|underrun)\b",
            line,
            flags=re.IGNORECASE,
        )
    ]
    if log_failures:
        failures.append("runtime log contains shader or audio failure markers")

    before = read_temperatures(args.temperature_before)
    after = read_temperatures(args.temperature_after)
    temperature_delta = {
        key: round(after[key] - before[key], 3)
        for key in sorted(before.keys() & after.keys())
    }

    report = {
        "schema_version": 1,
        "platform": "mlp1",
        "display_mode": args.display_mode,
        "requested_refresh_hz": args.requested_refresh_hz,
        "bfi": "on" if args.bfi == 1 else "off",
        "warmup_seconds": args.warmup_seconds,
        "duration_seconds": args.duration_seconds,
        "sample_interval_seconds": args.sample_interval_seconds,
        "preset": args.preset,
        "core": args.core,
        "content_class": args.content_class,
        "content_name": args.content_name,
        "content_source": "device-provided-read-only",
        "shader_source": shader_manifest["source"],
        "shader_sources": shader_manifest.get(
            "sources",
            [shader_manifest["source"]],
        ),
        "shader_bundle_id": shader_manifest["bundle_id"],
        "retroarch_build": {
            "version": retroarch_build["retroarch_version"],
            "commit": retroarch_build["commit"],
            "build_profile": retroarch_build["build_profile"],
            "patches_applied": retroarch_build["patches_applied"],
            "binary_sha256": sha256(args.retroarch_binary),
        },
        "metrics": metrics,
        "temperatures_c": {
            "before": before,
            "after": after,
            "delta": temperature_delta,
        },
        "samples": sample_rows,
        "baseline": baseline,
        "log_failure_lines": log_failures,
        "qualification": "pass" if not failures else "fail",
        "failure_reasons": failures,
    }
    return report, not failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--shader-manifest", type=Path, required=True)
    parser.add_argument("--retroarch-build-manifest", type=Path, required=True)
    parser.add_argument("--retroarch-binary", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--temperature-before", type=Path, required=True)
    parser.add_argument("--temperature-after", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--preset", required=True)
    parser.add_argument("--core", required=True)
    parser.add_argument("--content-class", required=True)
    parser.add_argument("--content-name", required=True)
    parser.add_argument("--display-mode", required=True)
    parser.add_argument("--requested-refresh-hz", type=int, required=True)
    parser.add_argument("--bfi", type=int, choices=(0, 1), required=True)
    parser.add_argument("--warmup-seconds", type=int, required=True)
    parser.add_argument("--duration-seconds", type=int, required=True)
    parser.add_argument("--sample-interval-seconds", type=int, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report, passed = build_report(args)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    metrics = report["metrics"]
    print(
        f"{report['qualification']}: samples={metrics['sample_count']} "
        f"average_fps={metrics.get('average_fps', 'n/a')} "
        f"dropped={metrics.get('maximum_dropped_frames', 'n/a')} "
        f"underrun={metrics.get('maximum_audio_underrun_pct', 'n/a')}"
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
