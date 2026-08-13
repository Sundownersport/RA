#!/usr/bin/env python3
"""Unit tests for the deterministic MLP1 RetroArch asset bundle builder."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path, PurePosixPath


MODULE_PATH = Path(__file__).with_name("mlp1_asset_bundle.py")
SPEC = importlib.util.spec_from_file_location("mlp1_asset_bundle", MODULE_PATH)
assert SPEC and SPEC.loader
asset_bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(asset_bundle)


def write(path: Path, payload: bytes = b"payload") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


class AssetBundleTests(unittest.TestCase):
    @staticmethod
    def lock(**overrides: object) -> dict:
        base = {
            "schema_version": 1,
            "bundle_id": "test-assets",
            "platform": "mlp1",
            "source": {
                "id": "test-source",
                "source": "https://example.com/test.git",
                "commit": "0" * 40,
                "tree": "1" * 40,
                "commit_epoch": 123,
                "checkout": "workdir/src/test",
            },
            "subtrees": [
                {
                    "source_root": "ozone",
                    "output_root": "ozone",
                    "exclude": [],
                    "reason": "test",
                }
            ],
            "license_rules": [
                {
                    "match": "**/*.png",
                    "spdx": "CC-BY-4.0",
                    "work": "art",
                    "notice": "n",
                }
            ],
            "required_files": [],
        }
        base.update(overrides)
        return base

    # -- lock schema ------------------------------------------------------

    def test_rejects_unknown_schema_version(self) -> None:
        lock = self.lock(schema_version=2)
        with self.assertRaisesRegex(asset_bundle.BundleError, "unsupported lock schema"):
            asset_bundle.validate_lock(lock, Path("lock.json"))

    def test_rejects_duplicate_output_root(self) -> None:
        lock = self.lock()
        lock["subtrees"] = lock["subtrees"] + [dict(lock["subtrees"][0])]
        with self.assertRaisesRegex(asset_bundle.BundleError, "duplicate output_root"):
            asset_bundle.validate_lock(lock, Path("lock.json"))

    def test_rejects_escaping_relative_path(self) -> None:
        with self.assertRaises(asset_bundle.BundleError):
            asset_bundle.normalize_relative("../escape")

    # -- FAT32 safety -----------------------------------------------------

    def test_rejects_fat32_reserved_filename(self) -> None:
        with self.assertRaisesRegex(asset_bundle.BundleError, "reserved DOS filename"):
            asset_bundle.validate_bundle_path(PurePosixPath("ozone/png/AUX.png"))

    def test_rejects_trailing_space_component(self) -> None:
        with self.assertRaisesRegex(asset_bundle.BundleError, "FAT32-unsafe"):
            asset_bundle.validate_bundle_path(PurePosixPath("ozone/png /a.png"))

    def test_rejects_overlong_path(self) -> None:
        long_name = "a" * (asset_bundle.PATH_LIMIT_BYTES + 1)
        with self.assertRaisesRegex(asset_bundle.BundleError, "exceeds"):
            asset_bundle.validate_bundle_path(PurePosixPath(f"ozone/{long_name}.png"))

    def test_rejects_unexpected_extension(self) -> None:
        with self.assertRaisesRegex(asset_bundle.BundleError, "unsupported asset extension"):
            asset_bundle.validate_bundle_path(PurePosixPath("ozone/install.sh"))

    def test_accepts_spaces_inside_a_component(self) -> None:
        # Upstream names icons after console models; spaces are legal on FAT32.
        asset_bundle.validate_bundle_path(
            PurePosixPath("xmb/monochrome/png/Acorn - Risc PC.png")
        )

    # -- license classification -------------------------------------------

    def test_first_matching_rule_wins(self) -> None:
        rules = [
            {"match": "pkg/osd-font.ttf", "spdx": "A", "work": "w1", "notice": "n1"},
            {"match": "**/*.ttf", "spdx": "B", "work": "w2", "notice": "n2"},
        ]
        self.assertEqual(
            asset_bundle.classify(PurePosixPath("pkg/osd-font.ttf"), rules)["license"],
            "A",
        )
        self.assertEqual(
            asset_bundle.classify(PurePosixPath("ozone/bold.ttf"), rules)["license"],
            "B",
        )

    def test_rejects_unclassified_file(self) -> None:
        with self.assertRaisesRegex(asset_bundle.BundleError, "no license rule matches"):
            asset_bundle.classify(PurePosixPath("ozone/mystery.png"), [])

    # -- collection -------------------------------------------------------

    def test_excludes_named_subdirectories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout, staging = root / "src", root / "out"
            write(checkout / "ozone" / "png" / "cursor_border.png")
            write(checkout / "ozone" / "png" / "icons" / "2048.png")
            staging.mkdir()

            lock = self.lock()
            lock["subtrees"][0]["exclude"] = ["png/icons"]
            metadata = asset_bundle.collect_files(checkout, lock, staging)

            self.assertEqual(list(metadata), ["ozone/png/cursor_border.png"])
            self.assertFalse((staging / "ozone" / "png" / "icons").exists())

    def test_rejects_case_insensitive_collision(self) -> None:
        # Two subtrees rather than two files in one directory: the developer
        # host is usually case-insensitive itself, so a same-directory fixture
        # would collapse before collect_files ever saw both names.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout, staging = root / "src", root / "out"
            write(checkout / "ozone" / "check.png")
            write(checkout / "themes" / "Check.png")
            staging.mkdir()

            lock = self.lock()
            lock["subtrees"] = [
                {
                    "source_root": "ozone",
                    "output_root": "ozone",
                    "exclude": [],
                    "reason": "test",
                },
                {
                    "source_root": "themes",
                    "output_root": "Ozone",
                    "exclude": [],
                    "reason": "test",
                },
            ]
            with self.assertRaisesRegex(
                asset_bundle.BundleError, "case-insensitive collision"
            ):
                asset_bundle.collect_files(checkout, lock, staging)

    def test_rejects_missing_required_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout, staging = root / "src", root / "out"
            write(checkout / "ozone" / "cursor_border.png")
            staging.mkdir()

            lock = self.lock()
            lock["required_files"] = ["ozone/regular.ttf"]
            with self.assertRaisesRegex(
                asset_bundle.BundleError, "locked required files are absent"
            ):
                asset_bundle.collect_files(checkout, lock, staging)

    def test_rejects_empty_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout, staging = root / "src", root / "out"
            (checkout / "ozone").mkdir(parents=True)
            staging.mkdir()
            with self.assertRaisesRegex(asset_bundle.BundleError, "would be empty"):
                asset_bundle.collect_files(checkout, self.lock(), staging)

    # -- manifest round trip ----------------------------------------------

    def build_fixture(self, root: Path) -> tuple[Path, Path]:
        """Assemble a small bundle the way build_bundle does, minus the clone."""
        checkout, output = root / "src", root / "bundle"
        write(checkout / "ozone" / "cursor_border.png", b"cursor")
        write(checkout / "ozone" / "png" / "sidebar" / "settings.png", b"settings")
        output.mkdir(parents=True)

        lock = self.lock()
        lock["required_files"] = ["ozone/cursor_border.png"]
        lock_path = root / "lock.json"
        lock_path.write_text(json.dumps(lock), encoding="utf-8")

        metadata = asset_bundle.collect_files(checkout, lock, output)
        asset_bundle.write_notice(output, lock, metadata)
        manifest = asset_bundle.build_manifest(output, lock, lock_path, metadata)
        content_size = sum(p.stat().st_size for p in output.rglob("*") if p.is_file())
        (output / asset_bundle.MANIFEST_NAME).write_bytes(
            asset_bundle.serialize_manifest(manifest, content_size)
        )
        return lock_path, output

    def test_validates_a_freshly_built_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lock_path, output = self.build_fixture(Path(temporary))
            manifest = asset_bundle.validate_bundle(lock_path, output)
            self.assertEqual(manifest["file_count"], 3)  # 2 assets + NOTICE.md

    def test_validate_detects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lock_path, output = self.build_fixture(Path(temporary))
            (output / "ozone" / "cursor_border.png").write_bytes(b"cursed")
            with self.assertRaises(asset_bundle.BundleError):
                asset_bundle.validate_bundle(lock_path, output)

    def test_validate_detects_unrecorded_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lock_path, output = self.build_fixture(Path(temporary))
            write(output / "ozone" / "stray.png")
            with self.assertRaisesRegex(asset_bundle.BundleError, "unrecorded file"):
                asset_bundle.validate_bundle(lock_path, output)

    def test_validate_rejects_a_bundle_from_another_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path, output = self.build_fixture(root)
            other = json.loads(lock_path.read_text(encoding="utf-8"))
            other["required_files"] = []
            other_path = root / "other-lock.json"
            other_path.write_text(json.dumps(other), encoding="utf-8")
            with self.assertRaisesRegex(
                asset_bundle.BundleError, "different lock file"
            ):
                asset_bundle.validate_bundle(other_path, output)


if __name__ == "__main__":
    unittest.main()
