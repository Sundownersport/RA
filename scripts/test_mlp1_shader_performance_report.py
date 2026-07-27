#!/usr/bin/env python3
"""Tests for MLP1 RetroArch performance-reply parsing."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("mlp1_shader_performance_report.py")
SPEC = importlib.util.spec_from_file_location("mlp1_shader_performance_report", MODULE_PATH)
assert SPEC and SPEC.loader
performance_report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(performance_report)


class PerformanceReportTests(unittest.TestCase):
    def test_parses_retroarch_performance_reply(self) -> None:
        values = performance_report.parse_perf_info(
            """
            result=ok
            reply=GET_PERF_INFO ready=1 fps=59.980 frame_time_p95_ms=16.670 deviation_pct=0.420 samples=2048 frames=3601 dropped=1 audio_ready=1 audio_samples=2048 audio_underrun_pct=0.000 audio_blocking_pct=0.250
            """
        )
        self.assertEqual(
            values,
            {
                "ready": 1,
                "fps": 59.98,
                "frame_time_p95_ms": 16.67,
                "deviation_pct": 0.42,
                "samples": 2048,
                "frames": 3601,
                "dropped_frames": 1,
                "audio_ready": 1,
                "audio_samples": 2048,
                "audio_underrun_pct": 0.0,
                "audio_blocking_pct": 0.25,
            },
        )

    def test_ignores_unrelated_text(self) -> None:
        self.assertEqual(
            performance_report.parse_perf_info("Leaf shader test"),
            {},
        )


if __name__ == "__main__":
    unittest.main()
