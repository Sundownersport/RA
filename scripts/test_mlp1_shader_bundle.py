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


class ShaderPatchTests(unittest.TestCase):
    """The local-patch fallback: pinned by hash on both sides.

    The point of these tests is that a patch can never silently do the wrong
    thing. If the source moves under it, or the diff produces anything other
    than the pinned result, the build must fail rather than ship a file nobody
    reviewed.
    """

    PRE = b"one\ntwo\nthree\n"
    DIFF = (
        "--- a/x.glsl\n"
        "+++ b/x.glsl\n"
        "@@ -1,3 +1,4 @@\n"
        " one\n"
        "+inserted\n"
        " two\n"
        " three\n"
    )

    def test_applies_a_unified_diff(self) -> None:
        result = shader_bundle.apply_unified_diff(self.PRE, self.DIFF)
        self.assertEqual(result, b"one\ninserted\ntwo\nthree\n")

    def test_preserves_crlf_line_endings(self) -> None:
        crlf = self.PRE.replace(b"\n", b"\r\n")
        result = shader_bundle.apply_unified_diff(crlf, self.DIFF)
        self.assertEqual(result, b"one\r\ninserted\r\ntwo\r\nthree\r\n")

    def test_rejects_context_mismatch(self) -> None:
        with self.assertRaises(shader_bundle.BundleError):
            shader_bundle.apply_unified_diff(b"one\nCHANGED\nthree\n", self.DIFF)

    def _patch_entry(self, root: Path, **overrides: object) -> dict[str, object]:
        import hashlib

        source_dir = root / "checkout"
        (source_dir / "shaders").mkdir(parents=True, exist_ok=True)
        target = source_dir / "shaders" / "x.glsl"
        target.write_bytes(self.PRE)
        patch_file = root / "shader-sources" / "patches" / "x.patch"
        patch_file.parent.mkdir(parents=True, exist_ok=True)
        patch_file.write_text(self.DIFF, encoding="utf-8")
        post = hashlib.sha256(b"one\ninserted\ntwo\nthree\n").hexdigest()
        entry: dict[str, object] = {
            "id": "x-patch",
            "source_id": "src",
            "path": "shaders/x.glsl",
            "patch_file": "shader-sources/patches/x.patch",
            "pre_sha256": hashlib.sha256(self.PRE).hexdigest(),
            "post_sha256": post,
            "reason": "test",
            "upstream_status": "test",
        }
        entry.update(overrides)
        return entry

    def _materialize(self, root: Path, entry: dict[str, object]) -> dict:
        sources = {
            "src": {
                "root": root / "checkout",
                "checkout": root / "checkout",
                "output_root": PurePosixPath("leaf-bundled"),
                "lock": {},
            }
        }
        return shader_bundle.materialize_patches(
            [entry],
            sources,
            root / "shader-sources" / "selection.json",
            root / "work",
        )

    def test_materializes_and_verifies_the_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            applied = self._materialize(root, self._patch_entry(root))
            record = applied[("src", "shaders/x.glsl")]
            self.assertEqual(record["patch_id"], "x-patch")
            self.assertEqual(
                Path(record["path"]).read_bytes(), b"one\ninserted\ntwo\nthree\n"
            )

    def test_rejects_a_moved_source(self) -> None:
        """The lock advancing under a patch must fail loudly, not mis-apply."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            entry = self._patch_entry(root)
            (root / "checkout" / "shaders" / "x.glsl").write_bytes(b"one\ntwo\nfour\n")
            with self.assertRaises(shader_bundle.BundleError) as caught:
                self._materialize(root, entry)
            self.assertIn("pre_sha256", str(caught.exception))

    def test_rejects_an_unexpected_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            entry = self._patch_entry(root, post_sha256="0" * 64)
            with self.assertRaises(shader_bundle.BundleError) as caught:
                self._materialize(root, entry)
            self.assertIn("post_sha256", str(caught.exception))

    def test_rejects_a_no_op_patch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            entry = self._patch_entry(root)
            entry["post_sha256"] = entry["pre_sha256"]
            selection = {"schema_version": 1, "patches": [entry]}
            lock = {"sources": [{"id": "src"}]}
            (root / "shader-sources").mkdir(parents=True, exist_ok=True)
            with self.assertRaises(shader_bundle.BundleError):
                shader_bundle.load_patches(
                    selection, root / "shader-sources" / "selection.json", lock
                )


if __name__ == "__main__":
    unittest.main()


class LicenseGuardTests(unittest.TestCase):
    """Walks the whole dependency closure, not one evidence file per preset.

    The case this exists for: a single GPLv3 dependency under a GPL-2.0-or-later
    preset silently relicenses the whole bundle. The per-preset evidence check
    cannot see it, because it only ever looks at one nominated file.
    """

    GPL3 = "/*\n under the terms of the GNU General Public License\n version 3 of the License\n*/\n"
    GPL2 = "/*\n under the terms of the GNU General Public License\n either version 2 of the License, or (at your option)\n*/\n"
    PD = "// License: Public domain\n"
    NONE = "#version 110\nvoid main() {}\n"

    def _files(self, root: Path, name: str, body: str, declared: str) -> dict:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
        return {
            PurePosixPath(f"leaf-bundled/{name}"): {
                "license": declared,
                "source_path": name,
                "copy_from": path,
            }
        }

    def test_accepts_a_file_matching_its_preset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = self._files(root, "a.glsl", self.GPL2, "GPL-2.0-or-later")
            rows = shader_bundle.validate_file_licenses(files, [])
            self.assertEqual(rows[0]["effective_license"], "GPL-2.0-or-later")
            self.assertEqual(rows[0]["basis"], "declared in file")

    def test_rejects_gplv3_under_a_gplv2_preset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = self._files(root, "a.glsl", self.GPL3, "GPL-2.0-or-later")
            with self.assertRaises(shader_bundle.BundleError) as caught:
                shader_bundle.validate_file_licenses(files, [])
            self.assertIn("effective license", str(caught.exception))

    def test_rejects_gpl_under_a_permissive_preset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = self._files(root, "a.glsl", self.GPL2, "MIT")
            with self.assertRaises(shader_bundle.BundleError):
                shader_bundle.validate_file_licenses(files, [])

    def test_accepts_permissive_under_a_gpl_preset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = self._files(root, "a.glsl", self.PD, "GPL-2.0-or-later")
            rows = shader_bundle.validate_file_licenses(files, [])
            self.assertEqual(rows[0]["effective_license"], "LicenseRef-Public-Domain")

    def test_treats_cc0_and_public_domain_as_the_same_statement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = self._files(root, "a.glsl", self.PD, "CC0-1.0")
            rows = shader_bundle.validate_file_licenses(files, [])
            self.assertEqual(rows[0]["preset_license"], "CC0-1.0")

    def test_rejects_an_unlabelled_source_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = self._files(root, "a.glsl", self.NONE, "GPL-2.0-or-later")
            with self.assertRaises(shader_bundle.BundleError) as caught:
                shader_bundle.validate_file_licenses(files, [])
            self.assertIn("no license notice", str(caught.exception))

    def test_accepts_an_acknowledged_unlabelled_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = self._files(root, "fam/a.glsl", self.NONE, "GPL-2.0-or-later")
            rows = shader_bundle.validate_file_licenses(
                files,
                [{"path_prefix": "fam/", "license": "GPL-2.0-or-later", "reason": "why"}],
            )
            self.assertTrue(rows[0]["basis"].startswith("acknowledged:"))

    def test_an_acknowledgement_cannot_launder_a_conflicting_license(self) -> None:
        """Acknowledging covers a missing notice, never a stated one."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = self._files(root, "fam/a.glsl", self.GPL3, "GPL-2.0-or-later")
            with self.assertRaises(shader_bundle.BundleError):
                shader_bundle.validate_file_licenses(
                    files,
                    [
                        {
                            "path_prefix": "fam/",
                            "license": "GPL-2.0-or-later",
                            "reason": "why",
                        }
                    ],
                )

    def test_config_and_asset_files_need_no_notice(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = self._files(root, "a.glslp", "shaders = 1\n", "MIT")
            rows = shader_bundle.validate_file_licenses(files, [])
            self.assertEqual(rows[0]["basis"], "follows the preset")

    def test_rejects_an_acknowledgement_without_a_reason(self) -> None:
        selection = {
            "license_acknowledgements": [
                {"path_prefix": "fam/", "license": "MIT", "reason": "  "}
            ]
        }
        with self.assertRaises(shader_bundle.BundleError):
            shader_bundle.load_license_acknowledgements(selection, Path("sel.json"))


class ReleasedAliasTests(unittest.TestCase):
    """A released alias is API.

    Users' saved automatic presets reference a recommendation by path, so
    retuning one in place silently changes a look they chose. A material change
    must arrive as a new alias path, and the old path must keep working.
    """

    def _recs(self, reference="leaf-bundled/a.glslp", parameters=None):
        return {
            "presets": [
                {
                    "path": "leaf-recommended/x.glslp",
                    "reference": reference,
                    "parameters": parameters if parameters is not None else {"GAMMA": "2.2"},
                }
            ]
        }

    def _released(self, **overrides):
        entry = {
            "path": "leaf-recommended/x.glslp",
            "reference": "leaf-bundled/a.glslp",
            "parameters": {"GAMMA": "2.2"},
            "released_in": "2026-09-01",
        }
        entry.update(overrides)
        return {entry["path"]: entry}

    def test_accepts_an_unchanged_alias(self) -> None:
        shader_bundle.validate_released_aliases(self._recs(), self._released())

    def test_rejects_a_changed_reference_target(self) -> None:
        with self.assertRaises(shader_bundle.BundleError) as caught:
            shader_bundle.validate_released_aliases(
                self._recs(reference="leaf-bundled/b.glslp"), self._released()
            )
        self.assertIn("new alias path", str(caught.exception))

    def test_rejects_retuned_parameters(self) -> None:
        with self.assertRaises(shader_bundle.BundleError) as caught:
            shader_bundle.validate_released_aliases(
                self._recs(parameters={"GAMMA": "2.6"}), self._released()
            )
        self.assertIn("changed its tuning", str(caught.exception))

    def test_rejects_a_dropped_alias(self) -> None:
        with self.assertRaises(shader_bundle.BundleError) as caught:
            shader_bundle.validate_released_aliases(
                {"presets": []}, self._released()
            )
        self.assertIn("no longer generated", str(caught.exception))

    def test_a_new_alias_alongside_the_old_one_is_fine(self) -> None:
        recs = self._recs()
        recs["presets"].append(
            {
                "path": "leaf-recommended/x-v2.glslp",
                "reference": "leaf-bundled/b.glslp",
                "parameters": {"GAMMA": "2.6"},
            }
        )
        shader_bundle.validate_released_aliases(recs, self._released())

    def test_rejects_a_duplicate_released_entry(self) -> None:
        entry = {
            "path": "leaf-recommended/x.glslp",
            "reference": "leaf-bundled/a.glslp",
            "parameters": {},
            "released_in": "2026-09-01",
        }
        with self.assertRaises(shader_bundle.BundleError):
            shader_bundle.load_released_aliases(
                {"released_aliases": [entry, dict(entry)]}, Path("sel.json")
            )


class RecommendationMetadataTests(unittest.TestCase):
    def test_description_and_constraint_bounds_are_sane(self) -> None:
        self.assertGreater(shader_bundle.RECOMMENDATION_DESCRIPTION_MAX, 40)
        self.assertGreater(shader_bundle.RECOMMENDATION_CONSTRAINT_MAX, 40)
        self.assertGreaterEqual(shader_bundle.RECOMMENDATION_CONSTRAINTS_MAX, 3)

    def test_shipped_metadata_is_within_bounds(self) -> None:
        """The real metadata must satisfy the limits the picker relies on."""
        import json

        path = MODULE_PATH.parent.parent / "shader-sources" / "mlp1-recommended.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        for row in data["presets"]:
            self.assertTrue(row["description"].strip(), row["path"])
            self.assertLessEqual(
                len(row["description"]),
                shader_bundle.RECOMMENDATION_DESCRIPTION_MAX,
                row["path"],
            )
            self.assertLessEqual(
                len(row["constraints"]),
                shader_bundle.RECOMMENDATION_CONSTRAINTS_MAX,
                row["path"],
            )
            for constraint in row["constraints"]:
                self.assertTrue(constraint.strip(), row["path"])
                self.assertLessEqual(
                    len(constraint),
                    shader_bundle.RECOMMENDATION_CONSTRAINT_MAX,
                    row["path"],
                )

    def test_rejects_an_over_long_description(self) -> None:
        with self.assertRaises(shader_bundle.BundleError) as caught:
            shader_bundle.validate_recommendation_text(
                "leaf-recommended/x.glslp",
                "x" * (shader_bundle.RECOMMENDATION_DESCRIPTION_MAX + 1),
                [],
            )
        self.assertIn("description exceeds", str(caught.exception))

    def test_rejects_an_empty_description(self) -> None:
        with self.assertRaises(shader_bundle.BundleError):
            shader_bundle.validate_recommendation_text(
                "leaf-recommended/x.glslp", "   ", []
            )

    def test_rejects_an_over_long_constraint(self) -> None:
        with self.assertRaises(shader_bundle.BundleError) as caught:
            shader_bundle.validate_recommendation_text(
                "leaf-recommended/x.glslp",
                "fine",
                ["y" * (shader_bundle.RECOMMENDATION_CONSTRAINT_MAX + 1)],
            )
        self.assertIn("constraint exceeds", str(caught.exception))

    def test_rejects_too_many_constraints(self) -> None:
        with self.assertRaises(shader_bundle.BundleError):
            shader_bundle.validate_recommendation_text(
                "leaf-recommended/x.glslp",
                "fine",
                ["c"] * (shader_bundle.RECOMMENDATION_CONSTRAINTS_MAX + 1),
            )

    def test_rejects_an_empty_constraint(self) -> None:
        with self.assertRaises(shader_bundle.BundleError):
            shader_bundle.validate_recommendation_text(
                "leaf-recommended/x.glslp", "fine", ["ok", " "]
            )
