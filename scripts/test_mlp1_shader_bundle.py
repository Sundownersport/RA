#!/usr/bin/env python3
"""Unit tests for the deterministic MLP1 shader bundle builder."""

from __future__ import annotations

import concurrent.futures
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path, PurePosixPath


MODULE_PATH = Path(__file__).with_name("mlp1_shader_bundle.py")
SPEC = importlib.util.spec_from_file_location("mlp1_shader_bundle", MODULE_PATH)
assert SPEC and SPEC.loader
shader_bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shader_bundle)


class ShaderBundleTests(unittest.TestCase):
    @staticmethod
    def git(repository: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repository), *args],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return result.stdout.strip()

    @staticmethod
    def lock() -> dict:
        return {
            "schema_version": 2,
            "selection": "unused.json",
            "sources": [
                {
                    "id": "test-source",
                    "source": "https://example.com/test.git",
                    "commit": "0" * 40,
                    "tree": "1" * 40,
                    "commit_epoch": 123,
                    "source_root": ".",
                    "output_root": "leaf-bundled/test",
                }
            ],
        }

    @classmethod
    def sources(cls, root: Path) -> dict:
        source_lock = cls.lock()["sources"][0]
        return {
            "test-source": {
                "lock": source_lock,
                "checkout": root,
                "root": root,
                "output_root": PurePosixPath("leaf-bundled/test"),
            }
        }

    @staticmethod
    def selection(path: str, evidence: str) -> dict:
        return {
            "path_limit_bytes": 240,
            "allowed_extensions": [".glsl", ".glslp"],
            "presets": [
                {
                    "path": path,
                    "group": "test",
                    "license": "LicenseRef-Public-Domain",
                    "license_provenance": "embedded",
                    "license_evidence_path": evidence,
                    "license_evidence_text": "public domain",
                    "qualification": "static-only",
                }
            ],
        }

    def test_parses_shader_and_texture_dependencies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            shader = Path(temporary) / "preset.glslp"
            shader.write_text(
                'shaders = "1"\n'
                'shader0 = "pass.glsl"\n'
                'textures = "LUT"\n'
                'LUT = "images/lut.png"\n',
                encoding="utf-8",
            )
            self.assertEqual(
                shader_bundle.parse_dependencies(
                    shader, PurePosixPath("group/preset.glslp")
                ),
                [
                    PurePosixPath("group/images/lut.png"),
                    PurePosixPath("group/pass.glsl"),
                ],
            )

    def test_resolves_parent_path_within_source(self) -> None:
        self.assertEqual(
            shader_bundle.resolve_dependency(
                PurePosixPath("group/preset.glslp"), "../shared/pass.glsl"
            ),
            PurePosixPath("shared/pass.glsl"),
        )

    def test_rejects_dependency_escape(self) -> None:
        with self.assertRaises(shader_bundle.BundleError):
            shader_bundle.resolve_dependency(
                PurePosixPath("preset.glslp"), "../outside.glsl"
            )

    def test_rejects_fat32_reserved_filename(self) -> None:
        with self.assertRaises(shader_bundle.BundleError):
            shader_bundle.validate_bundle_path(
                PurePosixPath("leaf-bundled/CON.glsl"),
                240,
                {".glsl"},
            )

    def test_rejects_updater_owned_source_output_root(self) -> None:
        lock = self.lock()
        lock["sources"][0]["output_root"] = "shaders_glsl/test"
        with tempfile.TemporaryDirectory() as temporary:
            lock_path = Path(temporary) / "lock.json"
            with self.assertRaisesRegex(
                shader_bundle.BundleError,
                "output root must remain under leaf-bundled",
            ):
                shader_bundle.validate_lock(lock, lock_path)

    def test_serializes_concurrent_checkout_preparation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            source.mkdir()
            self.git(source, "init", "--quiet")
            self.git(source, "config", "user.email", "tests@example.com")
            self.git(source, "config", "user.name", "Shader Bundle Tests")
            fixture = source / "fixture.glsl"
            fixture.write_text("// first\n", encoding="utf-8")
            self.git(source, "add", "fixture.glsl")
            self.git(source, "commit", "--quiet", "-m", "first")
            first_commit = self.git(source, "rev-parse", "HEAD")
            fixture.write_text("// second\n", encoding="utf-8")
            self.git(source, "commit", "--quiet", "-am", "second")
            second_commit = self.git(source, "rev-parse", "HEAD")
            source_lock = {
                "source": str(source),
                "commit": second_commit,
                "tree": self.git(source, "rev-parse", "HEAD^{tree}"),
                "commit_epoch": int(
                    self.git(source, "show", "-s", "--format=%ct", "HEAD")
                ),
            }
            self.git(source, "checkout", "--detach", "--quiet", first_commit)

            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
                futures = [
                    executor.submit(
                        shader_bundle.prepare_source,
                        source,
                        source_lock,
                        False,
                    )
                    for _ in range(4)
                ]
                for future in futures:
                    future.result()

            self.assertEqual(self.git(source, "rev-parse", "HEAD"), second_commit)
            self.assertTrue(
                (source.parent / ".source.shader-bundle.lock").exists()
            )

    def test_fresh_no_checkout_clone_populates_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            remote = root / "remote"
            remote.mkdir()
            self.git(remote, "init", "--quiet")
            self.git(remote, "config", "user.email", "tests@example.com")
            self.git(remote, "config", "user.name", "Shader Bundle Tests")
            (remote / "fixture.glsl").write_text("// shader\n", encoding="utf-8")
            self.git(remote, "add", "fixture.glsl")
            self.git(remote, "commit", "--quiet", "-m", "fixture")
            source_lock = {
                "source": str(remote),
                "commit": self.git(remote, "rev-parse", "HEAD"),
                "tree": self.git(remote, "rev-parse", "HEAD^{tree}"),
                "commit_epoch": int(
                    self.git(remote, "show", "-s", "--format=%ct", "HEAD")
                ),
            }
            checkout = root / "checkout"

            shader_bundle.prepare_source(checkout, source_lock, True)

            self.assertEqual(
                (checkout / "fixture.glsl").read_text(encoding="utf-8"),
                "// shader\n",
            )
            self.assertEqual(self.git(checkout, "status", "--porcelain"), "")

    def test_rejects_missing_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "preset.glslp").write_text(
                'shaders = "1"\nshader0 = "missing.glsl"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                shader_bundle.BundleError, "missing shader dependency"
            ):
                shader_bundle.collect_files(
                    self.sources(source),
                    self.selection("preset.glslp", "missing.glsl"),
                    self.lock(),
                )

    def test_rejects_missing_license_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "preset.glslp").write_text(
                'shaders = "1"\nshader0 = "pass.glsl"\n',
                encoding="utf-8",
            )
            (source / "pass.glsl").write_text("// no notice\n", encoding="utf-8")
            with self.assertRaisesRegex(
                shader_bundle.BundleError, "expected license evidence is absent"
            ):
                shader_bundle.collect_files(
                    self.sources(source),
                    self.selection("preset.glslp", "pass.glsl"),
                    self.lock(),
                )

    def test_rejects_case_insensitive_collision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "group").mkdir()
            (source / "group" / "Preset.glslp").write_text(
                'shaders = "1"\nshader0 = "pass.glsl"\n',
                encoding="utf-8",
            )
            (source / "group" / "preset.glslp").write_text(
                'shaders = "1"\nshader0 = "pass.glsl"\n',
                encoding="utf-8",
            )
            (source / "group" / "pass.glsl").write_text(
                "// License: Public domain\n", encoding="utf-8"
            )
            selection = {
                "path_limit_bytes": 240,
                "allowed_extensions": [".glsl", ".glslp"],
                "presets": [
                    {
                        "path": "group/Preset.glslp",
                        "group": "one",
                        "license": "LicenseRef-Public-Domain",
                        "license_provenance": "embedded",
                        "license_evidence_path": "group/pass.glsl",
                        "license_evidence_text": "public domain",
                        "qualification": "static-only",
                    },
                    {
                        "path": "group/preset.glslp",
                        "group": "two",
                        "license": "LicenseRef-Public-Domain",
                        "license_provenance": "embedded",
                        "license_evidence_path": "group/pass.glsl",
                        "license_evidence_text": "public domain",
                        "qualification": "static-only",
                    },
                ],
            }
            with self.assertRaises(shader_bundle.BundleError):
                shader_bundle.collect_files(
                    self.sources(source),
                    selection,
                    self.lock(),
                )

    def test_collects_from_source_specific_output_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "preset.glslp").write_text(
                'shaders = "1"\nshader0 = "pass.glsl"\n',
                encoding="utf-8",
            )
            (source / "pass.glsl").write_text(
                "// License: Public domain\n",
                encoding="utf-8",
            )
            files, presets = shader_bundle.collect_files(
                self.sources(source),
                self.selection("preset.glslp", "pass.glsl"),
                self.lock(),
            )
            self.assertEqual(
                set(files),
                {
                    PurePosixPath("leaf-bundled/test/preset.glslp"),
                    PurePosixPath("leaf-bundled/test/pass.glsl"),
                },
            )
            self.assertEqual(
                presets[0]["path"],
                "leaf-bundled/test/preset.glslp",
            )
            self.assertEqual(
                files[PurePosixPath("leaf-bundled/test/pass.glsl")][
                    "source_path"
                ],
                "pass.glsl",
            )

    def test_accepts_repository_scoped_license_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "preset.glslp").write_text(
                'shaders = "1"\nshader0 = "pass.glsl"\n',
                encoding="utf-8",
            )
            (source / "pass.glsl").write_text("// shader\n", encoding="utf-8")
            (source / "LICENSE").write_text("MIT License\n", encoding="utf-8")
            selection = self.selection("preset.glslp", "LICENSE")
            selection["presets"][0]["license_evidence_scope"] = "repository"
            selection["presets"][0]["license_evidence_text"] = "MIT License"
            files, _ = shader_bundle.collect_files(
                self.sources(source),
                selection,
                self.lock(),
            )
            self.assertEqual(len(files), 2)

    def test_aggregate_qualification_uses_weakest_preset(self) -> None:
        self.assertEqual(
            shader_bundle.aggregate_qualification(
                [
                    {"qualification": "recommended"},
                    {"qualification": "loads"},
                ]
            ),
            "loads",
        )

    def test_aggregate_qualification_rejects_empty_selection(self) -> None:
        with self.assertRaisesRegex(shader_bundle.BundleError, "empty preset list"):
            shader_bundle.aggregate_qualification([])

    def test_writes_thin_recommendation_with_parameter_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            rows = shader_bundle.write_recommendations(
                output,
                {
                    "presets": [
                        {
                            "path": "leaf-recommended/subtle.glslp",
                            "display_name": "Subtle",
                            "description": "A tuned test preset.",
                            "reference": "leaf-bundled/scanlines/base.glslp",
                            "parameters": {"DARKNESS": "0.25"},
                            "intended_systems": ["FC"],
                            "constraints": ["Test note."],
                        }
                    ]
                },
                123,
            )
            self.assertEqual(rows[0]["qualification"], "recommended")
            self.assertEqual(
                (output / "leaf-recommended" / "subtle.glslp").read_text(
                    encoding="utf-8"
                ),
                '#reference "../leaf-bundled/scanlines/base.glslp"\n'
                'DARKNESS = "0.25"\n',
            )


if __name__ == "__main__":
    unittest.main()
