#!/usr/bin/env python3
"""Build and validate the deterministic MLP1 RetroArch GLSL shader bundle."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = REPO_ROOT / "shader-sources" / "mlp1-glsl.lock.json"
DEFAULT_OUTPUT = REPO_ROOT / "output" / "mlp1" / "shaders"
DEPENDENCY_KEYS = {"lut", "overlay", "texture"}
DOS_RESERVED = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
}
REFERENCE_RE = re.compile(r'^\s*#reference\s+["\']([^"\']+)["\']', re.MULTILINE)
INCLUDE_RE = re.compile(r'^\s*#include\s+["\']([^"\']+)["\']', re.MULTILINE)
ASSIGNMENT_RE = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^#;\r\n]+))",
    re.MULTILINE,
)
QUALIFICATION_ORDER = {
    "static-only": 0,
    "loads": 1,
    "recommended": 2,
}


class BundleError(RuntimeError):
    """An actionable bundle build or validation failure."""


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise BundleError(f"missing JSON input: {path}") from exc
    except json.JSONDecodeError as exc:
        raise BundleError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise BundleError(f"expected a JSON object in {path}")
    return data


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(path: Path) -> str:
    return sha256_file(path)


def run_git(source: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(source), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise BundleError(f"git {' '.join(args)} failed in {source}: {detail}")
    return result.stdout.strip()


def locked_sources(lock: dict[str, Any]) -> list[dict[str, Any]]:
    if lock.get("schema_version") == 1:
        return [
            {
                "id": "libretro-glsl-shaders",
                "source": lock.get("source"),
                "commit": lock.get("commit"),
                "tree": lock.get("tree"),
                "commit_epoch": lock.get("commit_epoch"),
                "checkout": "workdir/src/glsl-shaders",
                "source_root": ".",
                "output_root": "leaf-bundled",
            }
        ]
    sources = lock.get("sources")
    if lock.get("schema_version") != 2 or not isinstance(sources, list) or not sources:
        raise BundleError(f"unsupported lock schema: {lock.get('schema_version')}")
    return sources


def source_manifest_rows(lock: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "id": str(source["id"]),
            "url": str(source["source"]),
            "commit": str(source["commit"]),
            "tree": str(source["tree"]),
            "commit_epoch": int(source["commit_epoch"]),
        }
        for source in locked_sources(lock)
    ]


def primary_source_manifest(lock: dict[str, Any]) -> dict[str, Any]:
    return source_manifest_rows(lock)[0]


def bundle_epoch(lock: dict[str, Any]) -> int:
    return max(int(source["commit_epoch"]) for source in locked_sources(lock))


def source_by_id(lock: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {str(source["id"]): source for source in locked_sources(lock)}


def preset_source_id(preset: dict[str, Any], lock: dict[str, Any]) -> str:
    sources = locked_sources(lock)
    return str(preset.get("source", sources[0]["id"]))


def preset_output_path(
    preset: dict[str, Any],
    lock: dict[str, Any],
) -> PurePosixPath:
    source = source_by_id(lock).get(preset_source_id(preset, lock))
    if not source:
        raise BundleError(
            f"selected preset references unknown source "
            f"{preset_source_id(preset, lock)!r}"
        )
    return normalize_source_path(
        (
            normalize_source_path(str(source["output_root"]))
            / normalize_source_path(str(preset["path"]))
        ).as_posix()
    )


def metadata_source_rows(data: dict[str, Any]) -> list[dict[str, Any]]:
    rows = data.get("shader_sources")
    if isinstance(rows, list):
        return rows
    row = data.get("shader_source")
    return [row] if isinstance(row, dict) else []


def validate_metadata_sources(
    data: dict[str, Any],
    lock: dict[str, Any],
    source_ids: set[str],
    label: str,
) -> None:
    expected = [
        row
        for row in source_manifest_rows(lock)
        if str(row["id"]) in source_ids
    ]
    actual = metadata_source_rows(data)
    normalized_actual = [
        {
            "id": str(row.get("id", expected[0]["id"] if len(expected) == 1 else "")),
            "url": row.get("url"),
            "commit": row.get("commit"),
            "tree": row.get("tree"),
            "commit_epoch": row.get("commit_epoch", expected[index]["commit_epoch"])
            if index < len(expected)
            else row.get("commit_epoch"),
        }
        for index, row in enumerate(actual)
    ]
    if normalized_actual != expected:
        raise BundleError(f"{label} shader sources do not match the source lock")


def validate_lock(lock: dict[str, Any], lock_path: Path) -> Path:
    required = {"schema_version", "selection"}
    missing = sorted(required - set(lock))
    if missing:
        raise BundleError(f"{lock_path} is missing keys: {', '.join(missing)}")
    seen_ids: set[str] = set()
    seen_outputs: set[str] = set()
    for index, source in enumerate(locked_sources(lock)):
        source_required = {
            "id",
            "source",
            "commit",
            "tree",
            "commit_epoch",
            "source_root",
            "output_root",
        }
        source_missing = sorted(source_required - set(source))
        if source_missing:
            raise BundleError(
                f"lock source {index} is missing keys: {', '.join(source_missing)}"
            )
        source_id = str(source["id"])
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", source_id):
            raise BundleError(f"invalid lock source id: {source_id!r}")
        if source_id in seen_ids:
            raise BundleError(f"duplicate lock source id: {source_id}")
        seen_ids.add(source_id)
        if not str(source["source"]).startswith(("https://", "git@")):
            raise BundleError(f"invalid lock source URL for {source_id}")
        if not re.fullmatch(r"[0-9a-f]{40}", str(source["commit"])):
            raise BundleError(f"{source_id} commit must be a full lowercase SHA-1")
        if not re.fullmatch(r"[0-9a-f]{40}", str(source["tree"])):
            raise BundleError(f"{source_id} tree must be a full lowercase SHA-1")
        if (
            not isinstance(source["commit_epoch"], int)
            or source["commit_epoch"] < 0
        ):
            raise BundleError(
                f"{source_id} commit_epoch must be a non-negative integer"
            )
        if str(source["source_root"]) not in {"", "."}:
            normalize_source_path(str(source["source_root"]))
        output_root = normalize_source_path(str(source["output_root"])).as_posix()
        if PurePosixPath(output_root).parts[0] != "leaf-bundled":
            raise BundleError(
                f"{source_id} output root must remain under leaf-bundled "
                "so RetroArch's updater-owned shaders_glsl tree cannot overwrite it"
            )
        if output_root.casefold() in seen_outputs:
            raise BundleError(f"duplicate source output root: {output_root}")
        seen_outputs.add(output_root.casefold())
        checkout = source.get("checkout", f"workdir/src/{source_id}")
        checkout_path = REPO_ROOT / str(checkout)
        try:
            checkout_path.resolve().relative_to(REPO_ROOT.resolve())
        except ValueError as exc:
            raise BundleError(
                f"{source_id} checkout must remain inside retroarch-builds"
            ) from exc
        if source.get("license_path"):
            normalize_source_path(str(source["license_path"]))
            if not str(source.get("license_evidence_text", "")).strip():
                raise BundleError(
                    f"{source_id} repository license lacks evidence text"
                )
    selection_path = REPO_ROOT / str(lock["selection"])
    try:
        selection_path.resolve().relative_to(REPO_ROOT.resolve())
    except ValueError as exc:
        raise BundleError("selection path must remain inside retroarch-builds") from exc
    return selection_path


def validate_selection(
    selection: dict[str, Any],
    selection_path: Path,
    lock: dict[str, Any],
) -> None:
    required = {
        "schema_version",
        "bundle_id",
        "platform",
        "policy_version",
        "installed_size_limit_bytes",
        "path_limit_bytes",
        "allowed_extensions",
        "presets",
    }
    missing = sorted(required - set(selection))
    if missing:
        raise BundleError(f"{selection_path} is missing keys: {', '.join(missing)}")
    if selection["schema_version"] != 1:
        raise BundleError(f"unsupported selection schema: {selection['schema_version']}")
    if selection["platform"] != "mlp1":
        raise BundleError("selection platform must be mlp1")
    if not isinstance(selection["presets"], list) or not selection["presets"]:
        raise BundleError("selection must contain at least one preset")
    seen: set[str] = set()
    for index, preset in enumerate(selection["presets"]):
        if not isinstance(preset, dict):
            raise BundleError(f"preset {index} must be an object")
        missing_preset = {
            "path",
            "group",
            "license",
            "license_provenance",
            "license_evidence_path",
            "license_evidence_text",
            "qualification",
        } - set(preset)
        if missing_preset:
            raise BundleError(
                f"preset {index} is missing keys: {', '.join(sorted(missing_preset))}"
            )
        path = normalize_source_path(str(preset["path"]))
        source_id = preset_source_id(preset, lock)
        if source_id not in source_by_id(lock):
            raise BundleError(
                f"selected preset references unknown source {source_id!r}: {path}"
            )
        if path.suffix.lower() != ".glslp":
            raise BundleError(f"selected preset is not .glslp: {path}")
        license_id = str(preset["license"]).strip()
        if not license_id or license_id.casefold() in {
            "unknown",
            "noassertion",
            "license-ref-unknown",
        }:
            raise BundleError(f"selected preset has an unknown license: {path}")
        for key in (
            "license_provenance",
            "license_evidence_path",
            "license_evidence_text",
            "qualification",
        ):
            if not str(preset[key]).strip():
                raise BundleError(f"selected preset has an empty {key}: {path}")
        if str(preset["qualification"]) not in QUALIFICATION_ORDER:
            raise BundleError(
                f"selected preset has an invalid qualification "
                f"{preset['qualification']!r}: {path}"
            )
        folded = preset_output_path(preset, lock).as_posix().casefold()
        if folded in seen:
            raise BundleError(
                f"duplicate selected preset output path: "
                f"{preset_output_path(preset, lock)}"
            )
        seen.add(folded)

    qualification = aggregate_qualification(selection["presets"])
    report_value = selection.get("qualification_report")
    if qualification != "static-only" and not report_value:
        raise BundleError(
            "device-qualified presets require a qualification_report"
        )
    if report_value:
        report_path, report = load_qualification_report(selection)
        report_presets = {
            str(row.get("path", "")): str(row.get("qualification", ""))
            for row in report.get("presets", [])
            if isinstance(row, dict)
        }
        expected_presets = {
            preset_output_path(row, lock).as_posix(): str(row["qualification"])
            for row in selection["presets"]
            if str(row["qualification"]) != "static-only"
        }
        if report_presets != expected_presets:
            raise BundleError(
                f"qualification report preset state does not match selection: "
                f"{report_path}"
            )


def load_qualification_report(
    selection: dict[str, Any],
) -> tuple[Path, dict[str, Any]]:
    value = selection.get("qualification_report")
    if not value:
        raise BundleError("selection does not declare a qualification report")
    report_path = REPO_ROOT / str(value)
    try:
        report_path.resolve().relative_to(REPO_ROOT.resolve())
    except ValueError as exc:
        raise BundleError(
            "qualification report path must remain inside retroarch-builds"
        ) from exc
    report = load_json(report_path)
    if report.get("schema_version") != 1 or report.get("platform") != "mlp1":
        raise BundleError(f"invalid MLP1 qualification report: {report_path}")
    build = report.get("retroarch_build")
    if not isinstance(build, dict) or not {
        "version",
        "commit",
        "build_profile",
    } <= set(build):
        raise BundleError(
            f"qualification report lacks exact RetroArch build metadata: {report_path}"
        )
    return report_path, report


# Sized for the in-game picker's caption area on a 720x960 panel, not for prose.
RECOMMENDATION_DESCRIPTION_MAX = 160
RECOMMENDATION_CONSTRAINT_MAX = 160
RECOMMENDATION_CONSTRAINTS_MAX = 6


def load_released_aliases(
    selection: dict[str, Any], selection_path: Path
) -> dict[str, dict[str, Any]]:
    """Aliases already shipped to users, pinned by reference target and tuning.

    A saved automatic preset references a recommendation **by path**, so once an
    alias is released its path, its reference target, and its parameter values
    are API. Retuning one in place silently changes a look a user chose and
    saved. A material change gets a new alias path instead; the old one stays
    loadable for at least one stable release.
    """
    entries = selection.get("released_aliases", [])
    if not isinstance(entries, list):
        raise BundleError(f"{selection_path}: released_aliases must be a list")
    released: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise BundleError(f"released alias {index} must be an object")
        missing = sorted({"path", "reference", "parameters", "released_in"} - set(entry))
        if missing:
            raise BundleError(
                f"released alias {index} is missing keys: {', '.join(missing)}"
            )
        alias = normalize_source_path(str(entry["path"])).as_posix()
        if alias in released:
            raise BundleError(f"duplicate released alias: {alias}")
        if not isinstance(entry["parameters"], dict):
            raise BundleError(f"released alias {alias}: parameters must be an object")
        released[alias] = entry
    return released


def validate_released_aliases(
    recommendations: dict[str, Any] | None,
    released: dict[str, dict[str, Any]],
) -> None:
    current = {
        normalize_source_path(str(row["path"])).as_posix(): row
        for row in (recommendations or {}).get("presets", [])
    }
    for alias, entry in sorted(released.items()):
        row = current.get(alias)
        if row is None:
            raise BundleError(
                f"released alias {alias} is no longer generated. It was shipped in "
                f"{entry['released_in']} and saved presets may still reference it; "
                "keep it loadable for at least one stable release."
            )
        reference = normalize_source_path(str(row["reference"])).as_posix()
        if reference != normalize_source_path(str(entry["reference"])).as_posix():
            raise BundleError(
                f"released alias {alias} changed its reference target "
                f"({entry['reference']} -> {reference}). Introduce a new alias path "
                "instead; users' saved presets point at this one."
            )
        expected = {str(k): str(v) for k, v in entry["parameters"].items()}
        actual = {str(k): str(v) for k, v in row["parameters"].items()}
        if expected != actual:
            raise BundleError(
                f"released alias {alias} changed its tuning. Introduce a new alias "
                "path instead; users' saved presets point at this one."
            )


def validate_recommendation_text(
    alias: str, description: Any, constraints: Any
) -> None:
    """Bound the strings the in-game picker renders.

    These reach a handheld screen through a fixed buffer, so an over-long value
    must fail the build rather than be silently truncated on device.
    """
    if not isinstance(description, str) or not description.strip():
        raise BundleError(f"{alias}: description must be a non-empty string")
    if len(description) > RECOMMENDATION_DESCRIPTION_MAX:
        raise BundleError(
            f"{alias}: description exceeds "
            f"{RECOMMENDATION_DESCRIPTION_MAX} characters"
        )
    if not isinstance(constraints, list):
        raise BundleError(f"{alias}: constraints must be a list")
    if len(constraints) > RECOMMENDATION_CONSTRAINTS_MAX:
        raise BundleError(
            f"{alias}: more than {RECOMMENDATION_CONSTRAINTS_MAX} constraints"
        )
    for constraint in constraints:
        if not isinstance(constraint, str) or not constraint.strip():
            raise BundleError(f"{alias}: each constraint must be a non-empty string")
        if len(constraint) > RECOMMENDATION_CONSTRAINT_MAX:
            raise BundleError(
                f"{alias}: a constraint exceeds "
                f"{RECOMMENDATION_CONSTRAINT_MAX} characters"
            )


def load_recommendations(
    selection: dict[str, Any],
    lock: dict[str, Any],
) -> tuple[Path | None, dict[str, Any] | None]:
    value = selection.get("recommendations")
    if not value:
        return None, None
    path = REPO_ROOT / str(value)
    try:
        path.resolve().relative_to(REPO_ROOT.resolve())
    except ValueError as exc:
        raise BundleError(
            "recommendations path must remain inside retroarch-builds"
        ) from exc
    data = load_json(path)
    if data.get("schema_version") != 1 or data.get("platform") != "mlp1":
        raise BundleError(f"invalid MLP1 recommendation metadata: {path}")
    rows = data.get("presets")
    if not isinstance(rows, list) or not rows:
        raise BundleError("recommendation metadata must contain presets")

    selected = {
        preset_output_path(row, lock).as_posix(): row
        for row in selection["presets"]
    }
    referenced_source_ids: set[str] = set()
    seen: set[str] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise BundleError(f"recommendation {index} must be an object")
        required = {
            "path",
            "display_name",
            "description",
            "reference",
            "parameters",
            "intended_systems",
            "qualification",
            "performance",
            "visual_review",
            "constraints",
        }
        missing = required - set(row)
        if missing:
            raise BundleError(
                f"recommendation {index} is missing keys: "
                f"{', '.join(sorted(missing))}"
            )
        alias = normalize_source_path(str(row["path"]))
        if (
            alias.suffix.lower() != ".glslp"
            or not alias.parts
            or alias.parts[0] != "leaf-recommended"
        ):
            raise BundleError(
                f"recommended preset must be under leaf-recommended: {alias}"
            )
        folded = alias.as_posix().casefold()
        if folded in seen:
            raise BundleError(f"duplicate recommended preset path: {alias}")
        seen.add(folded)

        reference = normalize_source_path(str(row["reference"])).as_posix()
        selected_row = selected.get(reference)
        if not selected_row:
            raise BundleError(
                f"recommendation references an unselected preset: {reference}"
            )
        if str(selected_row["qualification"]) != "recommended":
            raise BundleError(
                f"recommendation reference is not qualified recommended: {reference}"
            )
        referenced_source_ids.add(preset_source_id(selected_row, lock))
        if row["qualification"] != "recommended":
            raise BundleError(f"recommendation is not qualified: {alias}")

        validate_recommendation_text(
            alias.as_posix(), row["description"], row["constraints"]
        )
        systems = row["intended_systems"]
        if not isinstance(systems, list) or not systems:
            raise BundleError(f"recommendation has no intended systems: {alias}")
        parameters = row["parameters"]
        if not isinstance(parameters, dict):
            raise BundleError(f"recommendation parameters must be an object: {alias}")
        for key, value in parameters.items():
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", str(key)):
                raise BundleError(f"invalid recommendation parameter {key!r}: {alias}")
            if not re.fullmatch(r"-?[0-9]+(?:\.[0-9]+)?", str(value)):
                raise BundleError(
                    f"invalid recommendation parameter value {value!r}: {alias}"
                )
        performance = row["performance"]
        if (
            not isinstance(performance, dict)
            or float(performance.get("minimum_average_fps", 0.0)) < 59.0
        ):
            raise BundleError(
                f"recommendation does not meet the 59 FPS performance gate: {alias}"
            )
        visual = row["visual_review"]
        if not isinstance(visual, dict) or visual.get("status") != "pass":
            raise BundleError(f"recommendation lacks passed visual review: {alias}")
    validate_metadata_sources(
        data,
        lock,
        referenced_source_ids,
        "recommendation",
    )
    return path, data


def prepare_source_locked(source: Path, lock: dict[str, Any], fetch: bool) -> None:
    cloned = False
    if not source.exists():
        if not fetch:
            raise BundleError(f"shader source checkout does not exist: {source}")
        source.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            ["git", "clone", "--no-checkout", str(lock["source"]), str(source)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip()
            raise BundleError(f"failed to clone shader source: {detail}")
        cloned = True
    if not (source / ".git").exists():
        raise BundleError(f"shader source is not a Git checkout: {source}")
    if not cloned and run_git(source, "status", "--porcelain"):
        raise BundleError(f"shader source checkout has local changes: {source}")

    commit = str(lock["commit"])
    probe = subprocess.run(
        ["git", "-C", str(source), "cat-file", "-e", f"{commit}^{{commit}}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if probe.returncode:
        if not fetch:
            raise BundleError(f"locked shader commit is absent locally: {commit}")
        run_git(source, "fetch", "--depth=1", "origin", commit)
    if cloned or run_git(source, "rev-parse", "HEAD") != commit:
        run_git(source, "checkout", "--detach", "--quiet", commit)
    if run_git(source, "status", "--porcelain"):
        raise BundleError(f"shader source checkout has local changes: {source}")
    if run_git(source, "rev-parse", "HEAD") != commit:
        raise BundleError("shader checkout did not resolve to the locked commit")
    if run_git(source, "rev-parse", "HEAD^{tree}") != str(lock["tree"]):
        raise BundleError("shader checkout tree does not match the lock")
    if int(run_git(source, "show", "-s", "--format=%ct", "HEAD")) != lock["commit_epoch"]:
        raise BundleError("shader checkout commit timestamp does not match the lock")


def prepare_source(source: Path, lock: dict[str, Any], fetch: bool) -> None:
    """Prepare one pinned checkout without racing another bundle invocation."""
    source.parent.mkdir(parents=True, exist_ok=True)
    lock_path = source.parent / f".{source.name}.shader-bundle.lock"
    with lock_path.open("a+", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        try:
            prepare_source_locked(source, lock, fetch)
        finally:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)


def prepare_sources(
    lock: dict[str, Any],
    primary_override: Path | None,
    fetch: bool,
) -> dict[str, dict[str, Any]]:
    prepared: dict[str, dict[str, Any]] = {}
    for index, source_lock in enumerate(locked_sources(lock)):
        source_id = str(source_lock["id"])
        checkout = (
            primary_override
            if index == 0 and primary_override is not None
            else REPO_ROOT
            / str(source_lock.get("checkout", f"workdir/src/{source_id}"))
        )
        prepare_source(checkout, source_lock, fetch)
        source_root_value = str(source_lock["source_root"])
        source_root = (
            checkout
            if source_root_value in {"", "."}
            else checkout / normalize_source_path(source_root_value).as_posix()
        )
        if not source_root.is_dir():
            raise BundleError(
                f"{source_id} source root does not exist at the locked commit: "
                f"{source_root_value}"
            )
        license_path_value = source_lock.get("license_path")
        if license_path_value:
            license_path = checkout / normalize_source_path(
                str(license_path_value)
            ).as_posix()
            if not license_path.is_file():
                raise BundleError(
                    f"{source_id} repository license is missing: {license_path_value}"
                )
            evidence = str(source_lock["license_evidence_text"])
            if evidence.casefold() not in license_path.read_text(
                encoding="utf-8"
            ).casefold():
                raise BundleError(
                    f"{source_id} repository license evidence is stale"
                )
        prepared[source_id] = {
            "lock": source_lock,
            "checkout": checkout,
            "root": source_root,
            "output_root": normalize_source_path(
                str(source_lock["output_root"])
            ),
        }
    return prepared


def normalize_source_path(value: str) -> PurePosixPath:
    value = value.strip().replace("\\", "/")
    path = PurePosixPath(value)
    if not value or path.is_absolute():
        raise BundleError(f"dependency path must be relative: {value!r}")
    parts: list[str] = []
    for part in path.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not parts:
                raise BundleError(f"dependency escapes the shader source: {value}")
            parts.pop()
        else:
            parts.append(part)
    if not parts:
        raise BundleError(f"dependency does not name a file: {value!r}")
    return PurePosixPath(*parts)


def resolve_dependency(base: PurePosixPath, value: str) -> PurePosixPath:
    return normalize_source_path((base.parent / value).as_posix())


def parse_dependencies(path: Path, relative_path: PurePosixPath) -> list[PurePosixPath]:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise BundleError(f"shader file is not UTF-8: {relative_path}") from exc

    dependencies = []
    for pattern in (REFERENCE_RE, INCLUDE_RE):
        dependencies.extend(
            resolve_dependency(relative_path, match.group(1))
            for match in pattern.finditer(text)
        )
    assignments: dict[str, str] = {}
    for match in ASSIGNMENT_RE.finditer(text):
        value = next(group for group in match.groups()[1:] if group is not None).strip()
        assignments[match.group(1)] = value

    for key, value in assignments.items():
        lowered = key.lower()
        if re.fullmatch(r"shader\d+", lowered):
            dependencies.append(resolve_dependency(relative_path, value))
        elif lowered in DEPENDENCY_KEYS:
            dependencies.append(resolve_dependency(relative_path, value))

    texture_names = assignments.get("textures", "")
    for texture_name in texture_names.split(";"):
        texture_name = texture_name.strip()
        if not texture_name:
            continue
        if texture_name not in assignments:
            raise BundleError(
                f"{relative_path}: textures lists {texture_name!r} without a value"
            )
        dependencies.append(resolve_dependency(relative_path, assignments[texture_name]))

    unique: dict[str, PurePosixPath] = {}
    for dependency in dependencies:
        unique[dependency.as_posix()] = dependency
    return [unique[key] for key in sorted(unique)]


def validate_fat_component(component: str, relative_path: PurePosixPath) -> None:
    if not component or component.endswith((" ", ".")):
        raise BundleError(f"FAT32-unsafe path component: {relative_path}")
    if any(ord(char) < 32 or char in '<>:"\\|?*' for char in component):
        raise BundleError(f"FAT32-unsafe path component: {relative_path}")
    stem = component.split(".", 1)[0].upper()
    if stem in DOS_RESERVED:
        raise BundleError(f"reserved DOS filename in path: {relative_path}")


def validate_bundle_path(
    relative_path: PurePosixPath,
    path_limit_bytes: int,
    allowed_extensions: set[str],
) -> None:
    encoded_length = len(relative_path.as_posix().encode("utf-8"))
    if encoded_length > path_limit_bytes:
        raise BundleError(
            f"path exceeds {path_limit_bytes} UTF-8 bytes ({encoded_length}): {relative_path}"
        )
    for component in relative_path.parts:
        validate_fat_component(component, relative_path)
    suffix = relative_path.suffix.lower()
    if suffix not in allowed_extensions:
        raise BundleError(f"unsupported shader bundle extension {suffix!r}: {relative_path}")


def load_patches(
    selection: dict[str, Any],
    selection_path: Path,
    lock: dict[str, Any],
) -> list[dict[str, Any]]:
    """Validate the optional `patches` block.

    A patch exists only to carry a fix Leaf needs before upstream ships it. It
    is pinned by the sha256 of the file BEFORE and AFTER the change, so an
    advancing source lock that touches the same file fails the build loudly
    instead of silently mis-applying or silently no-op'ing.
    """
    patches = selection.get("patches", [])
    if not isinstance(patches, list):
        raise BundleError(f"{selection_path}: patches must be a list")
    known_sources = {str(row["id"]) for row in locked_sources(lock)}
    seen: set[str] = set()
    for index, patch in enumerate(patches):
        if not isinstance(patch, dict):
            raise BundleError(f"patch {index} must be an object")
        missing = sorted(
            {
                "id",
                "source_id",
                "path",
                "patch_file",
                "pre_sha256",
                "post_sha256",
                "reason",
                "upstream_status",
            }
            - set(patch)
        )
        if missing:
            raise BundleError(
                f"patch {index} is missing keys: {', '.join(missing)}"
            )
        patch_id = str(patch["id"])
        if patch_id in seen:
            raise BundleError(f"duplicate patch id: {patch_id}")
        seen.add(patch_id)
        if str(patch["source_id"]) not in known_sources:
            raise BundleError(f"patch {patch_id}: unknown source_id")
        for key in ("pre_sha256", "post_sha256"):
            digest = str(patch[key])
            if len(digest) != 64 or any(
                character not in "0123456789abcdef" for character in digest
            ):
                raise BundleError(f"patch {patch_id}: {key} must be a sha256 hex digest")
        if str(patch["pre_sha256"]) == str(patch["post_sha256"]):
            raise BundleError(f"patch {patch_id}: pre and post hashes are identical")
        if not str(patch["reason"]).strip():
            raise BundleError(f"patch {patch_id}: reason must not be empty")
        normalize_source_path(str(patch["path"]))
        patch_path = normalize_source_path(str(patch["patch_file"]))
        resolved = (selection_path.parent.parent / patch_path.as_posix()).resolve()
        try:
            resolved.relative_to(selection_path.parent.parent.resolve())
        except ValueError as exc:
            raise BundleError(f"patch {patch_id}: patch_file escapes the repository") from exc
        if not resolved.is_file():
            raise BundleError(f"patch {patch_id}: patch file is missing: {patch_path}")
    return patches


def apply_unified_diff(original: bytes, diff_text: str) -> bytes:
    """Apply a unified diff. Deliberately strict: context must match exactly.

    Correctness does not rest on this function -- the caller verifies the result
    against a pinned post-image hash -- but a strict applier fails at the hunk
    rather than producing something that merely hashes differently.
    """
    newline = b"\r\n" if original.count(b"\r\n") else b"\n"
    lines = original.split(newline)
    diff_lines = diff_text.splitlines()
    result = list(lines)
    offset = 0
    index = 0
    while index < len(diff_lines):
        line = diff_lines[index]
        if not line.startswith("@@"):
            index += 1
            continue
        header = re.match(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", line)
        if not header:
            raise BundleError(f"malformed hunk header: {line}")
        start = int(header.group(1)) - 1
        index += 1
        cursor = start + offset
        while index < len(diff_lines) and not diff_lines[index].startswith("@@"):
            body = diff_lines[index]
            if body.startswith("\\"):
                index += 1
                continue
            marker, text = body[:1], body[1:]
            if marker == " ":
                if cursor >= len(result) or result[cursor] != text.encode():
                    raise BundleError(f"patch context mismatch at line {cursor + 1}")
                cursor += 1
            elif marker == "-":
                if cursor >= len(result) or result[cursor] != text.encode():
                    raise BundleError(f"patch removal mismatch at line {cursor + 1}")
                del result[cursor]
                offset -= 1
            elif marker == "+":
                result.insert(cursor, text.encode())
                cursor += 1
                offset += 1
            elif body == "":
                cursor += 1
            else:
                raise BundleError(f"unsupported patch line: {body!r}")
            index += 1
    return newline.join(result)


def materialize_patches(
    patches: list[dict[str, Any]],
    sources: dict[str, dict[str, Any]],
    selection_path: Path,
    workdir: Path,
) -> dict[tuple[str, str], dict[str, Any]]:
    """Produce patched copies keyed by (source_id, source-relative path)."""
    applied: dict[tuple[str, str], dict[str, Any]] = {}
    for patch in patches:
        patch_id = str(patch["id"])
        source_id = str(patch["source_id"])
        relative = normalize_source_path(str(patch["path"]))
        source = sources[source_id]
        original_path = source["root"] / relative.as_posix()
        if not original_path.is_file():
            raise BundleError(f"patch {patch_id}: target is missing: {relative}")
        original = original_path.read_bytes()
        actual_pre = hashlib.sha256(original).hexdigest()
        if actual_pre != str(patch["pre_sha256"]):
            raise BundleError(
                f"patch {patch_id}: target no longer matches pre_sha256 "
                f"(expected {patch['pre_sha256']}, found {actual_pre}). "
                "The source lock moved under this patch; re-check whether it is "
                "still needed and re-pin it."
            )
        patch_file = (
            selection_path.parent.parent
            / normalize_source_path(str(patch["patch_file"])).as_posix()
        )
        patched = apply_unified_diff(
            original, patch_file.read_text(encoding="utf-8")
        )
        actual_post = hashlib.sha256(patched).hexdigest()
        if actual_post != str(patch["post_sha256"]):
            raise BundleError(
                f"patch {patch_id}: result does not match post_sha256 "
                f"(expected {patch['post_sha256']}, produced {actual_post})"
            )
        destination = workdir / patch_id / relative.as_posix()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(patched)
        applied[(source_id, relative.as_posix())] = {
            "path": destination,
            "patch_id": patch_id,
            "patch_sha256": sha256_file(patch_file),
            "pre_sha256": str(patch["pre_sha256"]),
            "post_sha256": actual_post,
            "reason": str(patch["reason"]),
            "upstream_status": str(patch["upstream_status"]),
        }
    return applied


# Detected from file content. "unlabelled" is not a license, it is the absence
# of one, and it is handled separately.
LICENSE_MARKERS: tuple[tuple[str, str], ...] = (
    ("GPL-3.0-or-later", "version 3 of the License"),
    ("GPL-2.0-or-later", "either version 2 of the License"),
    ("MIT", "Permission is hereby granted, free of charge"),
    ("LicenseRef-Public-Domain", "public domain"),
)

# A file may be redistributed under a preset's declared license when its own
# license is at least as permissive. Keys are the file's detected license.
# CC0-1.0 is the formal public-domain dedication; a file whose header says
# "public domain" and a preset declaring CC0-1.0 are the same statement.
PERMISSIVE = ("LicenseRef-Public-Domain", "CC0-1.0")
LICENSE_COMPATIBLE_UNDER: dict[str, frozenset[str]] = {
    "LicenseRef-Public-Domain": frozenset(
        {*PERMISSIVE, "MIT", "GPL-2.0-or-later", "GPL-3.0-or-later"}
    ),
    "CC0-1.0": frozenset(
        {*PERMISSIVE, "MIT", "GPL-2.0-or-later", "GPL-3.0-or-later"}
    ),
    "MIT": frozenset({"MIT", "GPL-2.0-or-later", "GPL-3.0-or-later"}),
    "GPL-2.0-or-later": frozenset({"GPL-2.0-or-later", "GPL-3.0-or-later"}),
    "GPL-3.0-or-later": frozenset({"GPL-3.0-or-later"}),
}


def detect_file_license(path: Path) -> str | None:
    """Return the license a file declares, or None when it declares nothing."""
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    folded = text.casefold()
    for name, marker in LICENSE_MARKERS:
        if marker.casefold() in folded:
            return name
    return None


def load_license_acknowledgements(
    selection: dict[str, Any], selection_path: Path
) -> list[dict[str, Any]]:
    entries = selection.get("license_acknowledgements", [])
    if not isinstance(entries, list):
        raise BundleError(f"{selection_path}: license_acknowledgements must be a list")
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise BundleError(f"license acknowledgement {index} must be an object")
        missing = sorted({"path_prefix", "license", "reason"} - set(entry))
        if missing:
            raise BundleError(
                f"license acknowledgement {index} is missing keys: {', '.join(missing)}"
            )
        if not str(entry["reason"]).strip():
            raise BundleError(
                f"license acknowledgement {index}: reason must not be empty"
            )
        normalize_source_path(str(entry["path_prefix"]))
    return entries


def acknowledged_license(
    source_path: str, acknowledgements: list[dict[str, Any]]
) -> dict[str, Any] | None:
    for entry in acknowledgements:
        if source_path.startswith(str(entry["path_prefix"])):
            return entry
    return None


# Only source files are expected to carry a notice. A .glslp preset is a config
# file and a .png is an asset; neither can hold one, and their licensing follows
# the preset's declared license and its evidence path.
NOTICE_REQUIRED_SUFFIXES = frozenset({".glsl"})


def validate_file_licenses(
    files: dict[PurePosixPath, dict[str, Any]],
    acknowledgements: list[dict[str, Any]],
) -> list[dict[str, str]]:
    """Check every file entering the bundle against its preset's declared license.

    The per-preset `license_evidence_path` check validates one file per preset.
    This walks the whole dependency closure, which is where a silent aggregate
    license change would otherwise come from: one v3 dependency under a v2+
    preset relicenses the bundle and nothing would say so.
    """
    rows: list[dict[str, str]] = []
    for output_relative in sorted(files, key=lambda item: item.as_posix()):
        record = files[output_relative]
        declared = str(record["license"])
        source_path = str(record["source_path"])
        detected = detect_file_license(record["copy_from"])

        if detected is None:
            entry = acknowledged_license(source_path, acknowledgements)
            if entry is not None:
                effective = str(entry["license"])
                note = f"acknowledged: {entry['reason']}"
            elif output_relative.suffix.lower() in NOTICE_REQUIRED_SUFFIXES:
                raise BundleError(
                    f"{source_path} carries no license notice and is not covered by a "
                    "license_acknowledgements entry. Record why it may be "
                    "redistributed, or drop the preset that pulls it in."
                )
            else:
                # Config or asset: follows the preset, whose own evidence path is
                # validated separately.
                effective = declared
                note = "follows the preset"
        else:
            effective = detected
            note = "declared in file"

        allowed = LICENSE_COMPATIBLE_UNDER.get(effective)
        if allowed is None:
            raise BundleError(f"{source_path}: unhandled license {effective}")
        if declared not in allowed:
            raise BundleError(
                f"{source_path} is {effective} but its preset declares {declared}. "
                "Redistributing it would change the bundle's effective license."
            )
        rows.append(
            {
                "path": output_relative.as_posix(),
                "source_path": source_path,
                "effective_license": effective,
                "preset_license": declared,
                "basis": note,
            }
        )
    return rows


def collect_files(
    sources: dict[str, dict[str, Any]],
    selection: dict[str, Any],
    lock: dict[str, Any],
    patched: dict[tuple[str, str], dict[str, Any]] | None = None,
) -> tuple[dict[PurePosixPath, dict[str, Any]], list[dict[str, Any]]]:
    patched = patched or {}
    path_limit = int(selection["path_limit_bytes"])
    allowed_extensions = {
        str(extension).lower() for extension in selection["allowed_extensions"]
    }
    files: dict[PurePosixPath, dict[str, Any]] = {}
    preset_rows: list[dict[str, Any]] = []

    for preset in selection["presets"]:
        source_id = preset_source_id(preset, lock)
        source = sources[source_id]
        source_root = source["root"]
        checkout = source["checkout"]
        source_lock = source["lock"]
        preset_path = normalize_source_path(str(preset["path"]))
        preset_output = preset_output_path(preset, lock)
        preset_rows.append(
            {
                "path": preset_output.as_posix(),
                "group": str(preset["group"]),
                "qualification": str(preset["qualification"]),
                "license": str(preset["license"]),
                "source_id": source_id,
            }
        )
        pending = [preset_path]
        visited: set[PurePosixPath] = set()
        while pending:
            relative_path = pending.pop()
            if relative_path in visited:
                continue
            visited.add(relative_path)
            source_path = source_root / relative_path.as_posix()
            try:
                source_path.resolve().relative_to(source_root.resolve())
            except ValueError as exc:
                raise BundleError(f"source path escapes checkout: {relative_path}") from exc
            if not source_path.is_file():
                raise BundleError(f"missing shader dependency: {relative_path}")
            if source_path.is_symlink():
                raise BundleError(f"symlinks are not allowed in the bundle: {relative_path}")
            if source_path.stat().st_size == 0:
                raise BundleError(f"empty shader dependency: {relative_path}")
            output_relative = source["output_root"] / relative_path
            validate_bundle_path(output_relative, path_limit, allowed_extensions)

            metadata = {
                "license": str(preset["license"]),
                "license_provenance": str(preset["license_provenance"]),
                "license_evidence_path": str(preset["license_evidence_path"]),
                "source_id": source_id,
                "source_url": str(source_lock["source"]),
                "source_commit": str(source_lock["commit"]),
                "source_tree": str(source_lock["tree"]),
                "source_path": source_path.relative_to(checkout).as_posix(),
            }
            patch = patched.get((source_id, relative_path.as_posix()))
            if patch:
                # A patched file is no longer the upstream file, and the manifest
                # must say so wherever that file's provenance is recorded.
                metadata["patch_id"] = patch["patch_id"]
                metadata["patch_sha256"] = patch["patch_sha256"]
                metadata["source_sha256"] = patch["pre_sha256"]
            record: dict[str, Any] = {
                **metadata,
                "copy_from": patch["path"] if patch else source_path,
                "source_epoch": int(source_lock["commit_epoch"]),
            }
            existing = files.get(output_relative)
            if existing and {
                key: value
                for key, value in existing.items()
                if key not in {"copy_from", "source_epoch"}
            } != metadata:
                raise BundleError(
                    f"conflicting provenance metadata for shared dependency: "
                    f"{output_relative}"
                )
            files[output_relative] = record
            pending.extend(parse_dependencies(source_path, relative_path))

        evidence_path = normalize_source_path(str(preset["license_evidence_path"]))
        evidence_scope = str(preset.get("license_evidence_scope", "dependency"))
        if evidence_scope == "dependency":
            if evidence_path not in visited:
                raise BundleError(
                    f"{preset_path}: license evidence is outside its dependency closure: "
                    f"{evidence_path}"
                )
            evidence_file = source_root / evidence_path.as_posix()
        elif evidence_scope == "repository":
            evidence_file = checkout / evidence_path.as_posix()
            try:
                evidence_file.resolve().relative_to(checkout.resolve())
            except ValueError as exc:
                raise BundleError(
                    f"{preset_path}: repository license evidence escapes checkout"
                ) from exc
        else:
            raise BundleError(
                f"{preset_path}: unsupported license evidence scope "
                f"{evidence_scope!r}"
            )
        if not evidence_file.is_file():
            raise BundleError(
                f"{preset_path}: license evidence file is missing: {evidence_path}"
            )
        evidence_text = evidence_file.read_text(encoding="utf-8")
        expected_notice = str(preset["license_evidence_text"])
        if expected_notice.casefold() not in evidence_text.casefold():
            raise BundleError(
                f"{preset_path}: expected license evidence is absent from {evidence_path}"
            )

    casefold_paths: dict[str, PurePosixPath] = {}
    for output_relative in files:
        folded = output_relative.as_posix().casefold()
        existing = casefold_paths.get(folded)
        if existing and existing != output_relative:
            raise BundleError(
                f"case-insensitive path collision: {existing} and {output_relative}"
            )
        casefold_paths[folded] = output_relative
    return files, preset_rows


def write_notice(
    destination: Path,
    lock: dict[str, Any],
    sources: dict[str, dict[str, Any]],
    files: dict[PurePosixPath, Any],
) -> None:
    lines = [
        "# MLP1 RetroArch GLSL shader bundle notices",
        "",
        "Leaf assembles this bundle directly from the original upstream repositories",
        "listed below. It does not redistribute copies taken from another firmware.",
        "",
        "Original upstream sources:",
        "",
    ]
    for source in locked_sources(lock):
        lines.extend(
            [
                f"## {source['id']}",
                "",
                f"- URL: {source['source']}",
                f"- Commit: `{source['commit']}`",
                f"- Tree: `{source['tree']}`",
                f"- License evidence: "
                f"`{source.get('license_path', 'embedded per-file notices')}`",
                "",
            ]
        )
        license_path_value = source.get("license_path")
        if license_path_value:
            license_path = sources[str(source["id"])]["checkout"] / str(
                license_path_value
            )
            lines.extend(
                [
                    "```text",
                    license_path.read_text(encoding="utf-8").rstrip(),
                    "```",
                    "",
                ]
            )
    lines.extend(
        [
            "Bundled files and their original source paths:",
            "",
        ]
    )
    lines.extend(
        f"- `{path.as_posix()}` ← `{files[path]['source_id']}:"
        f"{files[path]['source_path']}`"
        for path in sorted(files, key=lambda item: item.as_posix())
    )
    lines.append("")
    destination.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def write_recommendations(
    output: Path,
    recommendations: dict[str, Any],
    generated_epoch: int,
) -> list[dict[str, Any]]:
    rows = []
    readme_lines = [
        "Leaf recommended shaders for MLP1",
        "",
        "These presets are optional and are never enabled automatically.",
        "Each one references a tested preset in ../leaf-bundled/.",
        "",
    ]
    for row in recommendations["presets"]:
        alias = normalize_source_path(str(row["path"]))
        reference = normalize_source_path(str(row["reference"]))
        relative_reference = posixpath.relpath(
            reference.as_posix(),
            start=alias.parent.as_posix(),
        )
        lines = [f'#reference "{relative_reference}"']
        for key, value in sorted(row["parameters"].items()):
            lines.append(f'{key} = "{value}"')
        lines.append("")

        destination = output / alias.as_posix()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text("\n".join(lines), encoding="utf-8", newline="\n")
        destination.chmod(0o644)
        os.utime(destination, (generated_epoch, generated_epoch))
        rows.append(
            {
                "path": alias.as_posix(),
                "group": "leaf-recommended",
                "qualification": "recommended",
                "license": "LicenseRef-Leaf-Bundle-Metadata",
                "display_name": str(row["display_name"]),
                "reference": reference.as_posix(),
                "intended_systems": list(row["intended_systems"]),
                "description": str(row["description"]),
                "constraints": [str(value) for value in row["constraints"]],
            }
        )
        systems = ", ".join(str(value) for value in row["intended_systems"])
        readme_lines.extend(
            [
                str(row["display_name"]),
                f"  {row['description']}",
                f"  Intended systems: {systems}",
            ]
        )
        for constraint in row["constraints"]:
            readme_lines.append(f"  Note: {constraint}")
        readme_lines.append("")

    readme = output / "leaf-recommended" / "README.txt"
    readme.write_text("\n".join(readme_lines), encoding="utf-8", newline="\n")
    readme.chmod(0o644)
    os.utime(readme, (generated_epoch, generated_epoch))
    return rows


def aggregate_qualification(presets: Iterable[dict[str, Any]]) -> str:
    qualifications = [str(preset["qualification"]) for preset in presets]
    if not qualifications:
        raise BundleError("cannot aggregate qualification for an empty preset list")
    return min(qualifications, key=QUALIFICATION_ORDER.__getitem__)


def write_readme(
    destination: Path,
    qualification: str,
    has_recommendations: bool,
) -> None:
    if qualification == "static-only":
        qualification_note = (
            "Presets marked static-only are candidates and remain outside "
            "leaf-recommended until they are qualified on MLP1 hardware."
        )
    elif qualification == "loads":
        qualification_note = (
            "Every preset passed the MLP1 load, compile, render, menu, state, "
            "clear/reapply, relaunch, and clean-quit checks."
        )
    else:
        qualification_note = (
            "Every preset passed the MLP1 load checks and recommended-performance "
            "qualification."
        )
    browser_note = (
        "Start with leaf-recommended/, or browse the qualified leaf-bundled/ tree."
        if has_recommendations
        else "Browse these presets from RetroArch's shader menu under leaf-bundled/."
    )
    destination.write_text(
        "\n".join(
            [
                "Leaf RetroArch GLSL shaders for MLP1",
                "",
                browser_note,
                "No shader is enabled automatically.",
                "",
                "This initial set passed deterministic source, dependency, license,",
                "manifest, and filesystem validation.",
                qualification_note,
                "",
            ]
        ),
        encoding="utf-8",
        newline="\n",
    )


def build_manifest(
    output: Path,
    lock: dict[str, Any],
    lock_path: Path,
    selection: dict[str, Any],
    selection_path: Path,
    preset_rows: list[dict[str, Any]],
    recommended_rows: list[dict[str, Any]],
    recommendations_path: Path | None,
    recommendations: dict[str, Any] | None,
    file_metadata: dict[str, dict[str, str]],
    patches: dict[tuple[str, str], dict[str, Any]] | None = None,
    license_rows: list[dict[str, str]] | None = None,
) -> dict[str, Any]:
    file_rows = []
    extension_counts: Counter[str] = Counter()
    installed_size = 0
    for path in sorted(
        (candidate for candidate in output.rglob("*") if candidate.is_file()),
        key=lambda candidate: candidate.relative_to(output).as_posix(),
    ):
        relative = path.relative_to(output).as_posix()
        source_metadata = file_metadata.get(relative)
        size = path.stat().st_size
        installed_size += size
        extension_counts[path.suffix.lower() or "(none)"] += 1
        row: dict[str, Any] = {
            "path": relative,
            "sha256": sha256_file(path),
            "size": size,
        }
        if source_metadata:
            row.update(source_metadata)
        else:
            row["license"] = "LicenseRef-Leaf-Bundle-Metadata"
        file_rows.append(row)

    extension_counts[".json"] += 1
    all_preset_rows = preset_rows + recommended_rows
    # Anything not byte-identical to its upstream source is declared here, so a
    # reader never has to diff the bundle against the pin to discover it.
    patch_rows = [
        {
            "id": entry["patch_id"],
            "source_id": source_id,
            "source_path": relative,
            "patch_sha256": entry["patch_sha256"],
            "pre_sha256": entry["pre_sha256"],
            "post_sha256": entry["post_sha256"],
            "reason": entry["reason"],
            "upstream_status": entry["upstream_status"],
        }
        for (source_id, relative), entry in sorted(
            (patches or {}).items(), key=lambda item: item[1]["patch_id"]
        )
    ]
    manifest = {
        "schema_version": 2,
        "bundle_id": selection["bundle_id"],
        "platform": selection["platform"],
        "source": {
            key: value
            for key, value in primary_source_manifest(lock).items()
            if key != "id"
        },
        "sources": source_manifest_rows(lock),
        "lock": {
            "path": lock_path.relative_to(REPO_ROOT).as_posix(),
            "sha256": sha256_json(lock_path),
        },
        "selection": {
            "path": selection_path.relative_to(REPO_ROOT).as_posix(),
            "sha256": sha256_json(selection_path),
            "policy_version": selection["policy_version"],
        },
        "generated_epoch": bundle_epoch(lock),
        "qualification": aggregate_qualification(all_preset_rows),
        "preset_count": len(all_preset_rows),
        "standard_preset_count": len(preset_rows),
        "recommended_preset_count": len(recommended_rows),
        "installed_size_bytes": 0,
        "extension_counts": dict(sorted(extension_counts.items())),
        "presets": sorted(all_preset_rows, key=lambda row: row["path"]),
        "patches": patch_rows,
        "license_audit": license_rows or [],
        "files": file_rows,
    }
    if recommendations_path and recommendations:
        manifest["recommendations"] = {
            "path": recommendations_path.relative_to(REPO_ROOT).as_posix(),
            "sha256": sha256_json(recommendations_path),
            "qualification_id": recommendations["qualification_id"],
        }
    if selection.get("qualification_report"):
        report_path, report = load_qualification_report(selection)
        validate_metadata_sources(
            report,
            lock,
            {
                preset_source_id(row, lock)
                for row in selection["presets"]
                if str(row["qualification"]) != "static-only"
            },
            "qualification report",
        )
        manifest["qualification_report"] = {
            "path": report_path.relative_to(REPO_ROOT).as_posix(),
            "sha256": sha256_json(report_path),
        }
        manifest["retroarch_build"] = report["retroarch_build"]
        manifest["qualification_device"] = report["device"]
    return manifest


def serialize_manifest(manifest: dict[str, Any], content_size: int) -> bytes:
    previous_size = -1
    while manifest["installed_size_bytes"] != previous_size:
        previous_size = manifest["installed_size_bytes"]
        payload = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
        manifest["installed_size_bytes"] = content_size + len(payload)
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")


def atomic_promote(staging: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    backup = output.parent / f".{output.name}.previous"
    if backup.exists():
        shutil.rmtree(backup)
    if output.exists():
        output.rename(backup)
    try:
        staging.rename(output)
    except Exception:
        if backup.exists() and not output.exists():
            backup.rename(output)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def build_bundle(
    lock_path: Path,
    source: Path | None,
    output: Path,
    fetch: bool,
) -> dict[str, Any]:
    lock = load_json(lock_path)
    selection_path = validate_lock(lock, lock_path)
    selection = load_json(selection_path)
    validate_selection(selection, selection_path, lock)
    recommendations_path, recommendations = load_recommendations(selection, lock)
    validate_released_aliases(
        recommendations, load_released_aliases(selection, selection_path)
    )
    patches = load_patches(selection, selection_path, lock)
    sources = prepare_sources(lock, source, fetch)
    generated_epoch = bundle_epoch(lock)

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=f".{output.name}.build-", dir=output.parent
    ) as temporary:
        # Patched copies live only for this build; the fetched checkout is never
        # edited in place, so a later build without the patch is unaffected.
        patched = materialize_patches(
            patches, sources, selection_path, Path(temporary) / "patched"
        )
        files, preset_rows = collect_files(sources, selection, lock, patched)
        acknowledgements = load_license_acknowledgements(selection, selection_path)
        license_rows = validate_file_licenses(files, acknowledgements)
        staging = Path(temporary) / output.name
        staging.mkdir()
        metadata_by_output_path: dict[str, dict[str, str]] = {}
        for relative_path in sorted(files, key=lambda item: item.as_posix()):
            record = files[relative_path]
            source_path = record["copy_from"]
            destination = staging / relative_path.as_posix()
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_path, destination)
            destination.chmod(0o644)
            os.utime(
                destination,
                (record["source_epoch"], record["source_epoch"]),
            )
            metadata_by_output_path[relative_path.as_posix()] = {
                key: value
                for key, value in record.items()
                if key not in {"copy_from", "source_epoch"}
            }

        recommended_rows = (
            write_recommendations(staging, recommendations, generated_epoch)
            if recommendations
            else []
        )
        write_notice(staging / "NOTICE.md", lock, sources, files)
        write_readme(
            staging / "README.txt",
            aggregate_qualification(selection["presets"] + recommended_rows),
            bool(recommended_rows),
        )
        for metadata_file in (staging / "NOTICE.md", staging / "README.txt"):
            metadata_file.chmod(0o644)
            os.utime(metadata_file, (generated_epoch, generated_epoch))

        manifest = build_manifest(
            staging,
            lock,
            lock_path,
            selection,
            selection_path,
            preset_rows,
            recommended_rows,
            recommendations_path,
            recommendations,
            metadata_by_output_path,
            patched,
            license_rows,
        )
        manifest_path = staging / "manifest.json"
        content_size = sum(row["size"] for row in manifest["files"])
        manifest_payload = serialize_manifest(manifest, content_size)
        if len(manifest_payload) + content_size > int(
            selection["installed_size_limit_bytes"]
        ):
            raise BundleError(
                f"bundle is {len(manifest_payload) + content_size} bytes, above the "
                f"{selection['installed_size_limit_bytes']}-byte limit"
            )
        manifest_path.write_bytes(manifest_payload)
        manifest_path.chmod(0o644)
        os.utime(manifest_path, (generated_epoch, generated_epoch))
        validate_bundle(lock_path, staging)
        atomic_promote(staging, output)
    return manifest


def validate_output_dependencies(output: Path, manifest: dict[str, Any]) -> None:
    listed = {str(row["path"]) for row in manifest["files"]}
    for preset in manifest["presets"]:
        preset_path = PurePosixPath(str(preset["path"]))
        pending = [preset_path]
        visited: set[PurePosixPath] = set()
        while pending:
            relative_path = pending.pop()
            if relative_path in visited:
                continue
            visited.add(relative_path)
            if relative_path.as_posix() not in listed:
                raise BundleError(f"manifest omits shader dependency: {relative_path}")
            path = output / relative_path.as_posix()
            if not path.is_file():
                raise BundleError(f"bundle omits shader dependency: {relative_path}")
            pending.extend(parse_dependencies(path, relative_path))


def validate_bundle(lock_path: Path, output: Path) -> dict[str, Any]:
    lock = load_json(lock_path)
    selection_path = validate_lock(lock, lock_path)
    selection = load_json(selection_path)
    validate_selection(selection, selection_path, lock)
    recommendations_path, recommendations = load_recommendations(selection, lock)
    recommended_rows = recommendations["presets"] if recommendations else []
    manifest_path = output / "manifest.json"
    validate_bundle_path(
        PurePosixPath("manifest.json"),
        int(selection["path_limit_bytes"]),
        {".json"},
    )
    manifest = load_json(manifest_path)

    expected_scalar = {
        "schema_version": 2,
        "bundle_id": selection["bundle_id"],
        "platform": selection["platform"],
        "generated_epoch": bundle_epoch(lock),
        "preset_count": len(selection["presets"]) + len(recommended_rows),
        "standard_preset_count": len(selection["presets"]),
        "recommended_preset_count": len(recommended_rows),
        "qualification": aggregate_qualification(
            selection["presets"] + recommended_rows
        ),
    }
    for key, expected in expected_scalar.items():
        if manifest.get(key) != expected:
            raise BundleError(
                f"manifest {key} is {manifest.get(key)!r}, expected {expected!r}"
            )
    for key, expected in {
        key: value
        for key, value in primary_source_manifest(lock).items()
        if key != "id"
    }.items():
        if manifest.get("source", {}).get(key) != expected:
            raise BundleError(f"manifest source.{key} does not match the lock")
    if manifest.get("sources") != source_manifest_rows(lock):
        raise BundleError("manifest sources do not match the lock")
    if manifest.get("lock", {}).get("sha256") != sha256_json(lock_path):
        raise BundleError("manifest lock hash is stale")
    if manifest.get("selection", {}).get("sha256") != sha256_json(selection_path):
        raise BundleError("manifest selection hash is stale")
    expected_recommendations = (
        {
            "path": recommendations_path.relative_to(REPO_ROOT).as_posix(),
            "sha256": sha256_json(recommendations_path),
            "qualification_id": recommendations["qualification_id"],
        }
        if recommendations_path and recommendations
        else None
    )
    if manifest.get("recommendations") != expected_recommendations:
        raise BundleError("manifest recommendation metadata is stale")
    if selection.get("qualification_report"):
        report_path, report = load_qualification_report(selection)
        validate_metadata_sources(
            report,
            lock,
            {
                preset_source_id(row, lock)
                for row in selection["presets"]
                if str(row["qualification"]) != "static-only"
            },
            "qualification report",
        )
        if manifest.get("qualification_report") != {
            "path": report_path.relative_to(REPO_ROOT).as_posix(),
            "sha256": sha256_json(report_path),
        }:
            raise BundleError("manifest qualification report metadata is stale")
        if manifest.get("retroarch_build") != report["retroarch_build"]:
            raise BundleError("manifest RetroArch qualification build is stale")
        if manifest.get("qualification_device") != report["device"]:
            raise BundleError("manifest qualification device metadata is stale")

    file_rows = manifest.get("files")
    if not isinstance(file_rows, list) or not file_rows:
        raise BundleError("manifest files must be a non-empty array")
    listed_paths: set[str] = set()
    installed_size = 0
    extension_counts: Counter[str] = Counter()
    casefold_paths: dict[str, str] = {}
    allowed_extensions = {
        str(extension).lower() for extension in selection["allowed_extensions"]
    } | {".json"}
    for row in file_rows:
        if not isinstance(row, dict) or not {"path", "sha256", "size"} <= set(row):
            raise BundleError("manifest contains an invalid file row")
        relative_path = normalize_source_path(str(row["path"]))
        validate_bundle_path(
            relative_path,
            int(selection["path_limit_bytes"]),
            allowed_extensions,
        )
        relative = relative_path.as_posix()
        folded = relative.casefold()
        if folded in casefold_paths:
            raise BundleError(
                f"case-insensitive manifest collision: {casefold_paths[folded]} and {relative}"
            )
        casefold_paths[folded] = relative
        listed_paths.add(relative)
        path = output / relative
        if not path.is_file() or path.is_symlink():
            raise BundleError(f"manifest file is missing or invalid: {relative}")
        if path.stat().st_size == 0:
            raise BundleError(f"manifest file is empty: {relative}")
        if path.stat().st_size != row["size"]:
            raise BundleError(f"size mismatch: {relative}")
        if sha256_file(path) != row["sha256"]:
            raise BundleError(f"hash mismatch: {relative}")
        installed_size += path.stat().st_size
        extension_counts[path.suffix.lower() or "(none)"] += 1

    actual_paths = {
        path.relative_to(output).as_posix()
        for path in output.rglob("*")
        if path.is_file()
    }
    expected_paths = listed_paths | {"manifest.json"}
    if actual_paths != expected_paths:
        missing = sorted(expected_paths - actual_paths)
        extra = sorted(actual_paths - expected_paths)
        raise BundleError(f"bundle coverage mismatch; missing={missing}, extra={extra}")
    allowed_directories = {
        parent.as_posix()
        for relative in expected_paths
        for parent in PurePosixPath(relative).parents
        if parent.as_posix() != "."
    }
    for path in output.rglob("*"):
        relative = path.relative_to(output).as_posix()
        if path.is_symlink():
            raise BundleError(f"bundle contains a symlink: {relative}")
        if path.is_dir() and relative not in allowed_directories:
            raise BundleError(f"bundle contains an unexpected directory: {relative}")
    installed_size += manifest_path.stat().st_size
    extension_counts[".json"] += 1
    if installed_size != manifest.get("installed_size_bytes"):
        raise BundleError("manifest installed_size_bytes is stale")
    if dict(sorted(extension_counts.items())) != manifest.get("extension_counts"):
        raise BundleError("manifest extension_counts is stale")
    if installed_size > int(selection["installed_size_limit_bytes"]):
        raise BundleError("bundle exceeds its installed size policy")

    expected_standard_presets = {
        preset_output_path(row, lock).as_posix()
        for row in selection["presets"]
    }
    expected_recommended_presets = {
        normalize_source_path(str(row["path"])).as_posix()
        for row in recommended_rows
    }
    expected_presets = expected_standard_presets | expected_recommended_presets
    manifest_preset_rows = manifest.get("presets", [])
    manifest_presets = {str(row["path"]) for row in manifest_preset_rows}
    if manifest_presets != expected_presets:
        raise BundleError("manifest preset list does not match selection")
    expected_qualification = {
        preset_output_path(row, lock).as_posix(): str(row["qualification"])
        for row in selection["presets"]
    }
    expected_qualification.update(
        {
            normalize_source_path(str(row["path"])).as_posix(): str(
                row["qualification"]
            )
            for row in recommended_rows
        }
    )
    if {
        str(row["path"]): str(row.get("qualification", ""))
        for row in manifest_preset_rows
    } != expected_qualification:
        raise BundleError("manifest preset qualifications do not match selection")
    validate_output_dependencies(output, manifest)
    return manifest


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build", help="build and validate the shader bundle")
    build.add_argument(
        "--source",
        type=Path,
        default=None,
        help="override the primary source checkout (legacy compatibility)",
    )
    build.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    build.add_argument(
        "--no-fetch",
        action="store_true",
        help="do not clone or fetch the locked source commit",
    )

    validate = subparsers.add_parser("validate", help="validate an existing bundle")
    validate.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        if args.command == "build":
            manifest = build_bundle(
                args.lock.resolve(),
                args.source.resolve() if args.source else None,
                args.output.resolve(),
                not args.no_fetch,
            )
            print(
                f"built {manifest['preset_count']} presets "
                f"({manifest['installed_size_bytes']} bytes) at {args.output.resolve()}"
            )
        else:
            manifest = validate_bundle(args.lock.resolve(), args.output.resolve())
            print(
                f"validated {manifest['preset_count']} presets "
                f"({manifest['installed_size_bytes']} bytes) at {args.output.resolve()}"
            )
    except BundleError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
