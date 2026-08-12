#!/usr/bin/env python3
"""Build and validate the deterministic MLP1 RetroArch menu asset bundle.

RetroArch resolves every menu asset it draws -- Ozone's sprites and icons, the
TTF faces Ozone and the on-screen notification layer render with, and the
per-language CJK fallback faces -- under a single `assets_directory`. Leaf
historically shipped none of them, which left Ozone with no icons and RetroArch
falling back to its built-in 8x8 ASCII bitmap font.

This mirrors mlp1_shader_bundle.py: a pinned upstream checkout, a pruned copy
into an output tree, and a manifest recording upstream provenance, SHA-256 and
license classification for every installed file.
"""

from __future__ import annotations

import argparse
import fcntl
import fnmatch
import hashlib
import json
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path, PurePosixPath
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = REPO_ROOT / "asset-sources" / "mlp1-assets.lock.json"
DEFAULT_OUTPUT = REPO_ROOT / "output" / "mlp1" / "assets"
MANIFEST_NAME = "manifest.json"
NOTICE_NAME = "NOTICE.md"
GENERATED_NAMES = {MANIFEST_NAME, NOTICE_NAME}
GENERATED_LICENSE = "LicenseRef-Leaf-Bundle-Metadata"
# RetroArch reads these from an SD card that is FAT32 on every device we ship.
PATH_LIMIT_BYTES = 240
ALLOWED_EXTENSIONS = {".png", ".ttf", ".txt", ".md"}
DOS_RESERVED = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
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


def repo_relative(path: Path) -> str:
    """Record paths relative to the repo when possible, absolute otherwise."""
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def validate_lock(lock: dict[str, Any], lock_path: Path) -> None:
    if lock.get("schema_version") != 1:
        raise BundleError(f"unsupported lock schema: {lock.get('schema_version')}")
    for key in ("bundle_id", "platform"):
        if not isinstance(lock.get(key), str) or not lock[key]:
            raise BundleError(f"{lock_path}: {key} must be a non-empty string")

    source = lock.get("source")
    if not isinstance(source, dict):
        raise BundleError(f"{lock_path}: source must be an object")
    for key in ("id", "source", "commit", "tree", "checkout"):
        if not isinstance(source.get(key), str) or not source[key]:
            raise BundleError(f"{lock_path}: source.{key} must be a non-empty string")
    if not isinstance(source.get("commit_epoch"), int):
        raise BundleError(f"{lock_path}: source.commit_epoch must be an integer")

    subtrees = lock.get("subtrees")
    if not isinstance(subtrees, list) or not subtrees:
        raise BundleError(f"{lock_path}: subtrees must be a non-empty list")
    seen_outputs: set[str] = set()
    for subtree in subtrees:
        if not isinstance(subtree, dict):
            raise BundleError(f"{lock_path}: each subtree must be an object")
        for key in ("source_root", "output_root", "reason"):
            if not isinstance(subtree.get(key), str) or not subtree[key]:
                raise BundleError(
                    f"{lock_path}: subtree.{key} must be a non-empty string"
                )
        excludes = subtree.get("exclude", [])
        if not isinstance(excludes, list) or any(
            not isinstance(item, str) or not item for item in excludes
        ):
            raise BundleError(f"{lock_path}: subtree.exclude must be a list of strings")
        output_root = normalize_relative(str(subtree["output_root"])).as_posix()
        if output_root in seen_outputs:
            raise BundleError(f"{lock_path}: duplicate output_root {output_root}")
        seen_outputs.add(output_root)

    rules = lock.get("license_rules")
    if not isinstance(rules, list) or not rules:
        raise BundleError(f"{lock_path}: license_rules must be a non-empty list")
    for rule in rules:
        if not isinstance(rule, dict):
            raise BundleError(f"{lock_path}: each license rule must be an object")
        for key in ("match", "spdx", "work", "notice"):
            if not isinstance(rule.get(key), str) or not rule[key]:
                raise BundleError(
                    f"{lock_path}: license_rules.{key} must be a non-empty string"
                )

    required = lock.get("required_files", [])
    if not isinstance(required, list) or any(
        not isinstance(item, str) or not item for item in required
    ):
        raise BundleError(f"{lock_path}: required_files must be a list of strings")


def normalize_relative(value: str) -> PurePosixPath:
    path = PurePosixPath(value.replace("\\", "/"))
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise BundleError(f"unsafe relative path in lock: {value}")
    return path


def validate_fat_component(component: str, relative_path: PurePosixPath) -> None:
    if not component or component.endswith((" ", ".")):
        raise BundleError(f"FAT32-unsafe path component: {relative_path}")
    if any(ord(char) < 32 or char in '<>:"\\|?*' for char in component):
        raise BundleError(f"FAT32-unsafe path component: {relative_path}")
    if component.split(".", 1)[0].upper() in DOS_RESERVED:
        raise BundleError(f"reserved DOS filename in path: {relative_path}")


def validate_bundle_path(relative_path: PurePosixPath) -> None:
    encoded_length = len(relative_path.as_posix().encode("utf-8"))
    if encoded_length > PATH_LIMIT_BYTES:
        raise BundleError(
            f"path exceeds {PATH_LIMIT_BYTES} UTF-8 bytes ({encoded_length}): "
            f"{relative_path}"
        )
    for component in relative_path.parts:
        validate_fat_component(component, relative_path)
    suffix = relative_path.suffix.lower()
    if suffix not in ALLOWED_EXTENSIONS:
        raise BundleError(f"unsupported asset extension {suffix!r}: {relative_path}")


def prepare_source_locked(checkout: Path, source: dict[str, Any], fetch: bool) -> None:
    cloned = False
    if not checkout.exists():
        if not fetch:
            raise BundleError(f"asset source checkout does not exist: {checkout}")
        checkout.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [
                "git",
                "clone",
                "--no-checkout",
                "--filter=blob:none",
                str(source["source"]),
                str(checkout),
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip()
            raise BundleError(f"failed to clone asset source: {detail}")
        cloned = True
    if not (checkout / ".git").exists():
        raise BundleError(f"asset source is not a Git checkout: {checkout}")
    if not cloned and run_git(checkout, "status", "--porcelain"):
        raise BundleError(f"asset source checkout has local changes: {checkout}")

    commit = str(source["commit"])
    probe = subprocess.run(
        ["git", "-C", str(checkout), "cat-file", "-e", f"{commit}^{{commit}}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if probe.returncode:
        if not fetch:
            raise BundleError(f"locked asset commit is absent locally: {commit}")
        run_git(checkout, "fetch", "origin", commit)
    if run_git(checkout, "rev-parse", "HEAD") != commit:
        run_git(checkout, "checkout", "--detach", "--quiet", commit)
    if run_git(checkout, "status", "--porcelain"):
        raise BundleError(f"asset source checkout has local changes: {checkout}")
    if run_git(checkout, "rev-parse", "HEAD") != commit:
        raise BundleError("asset checkout did not resolve to the locked commit")
    if run_git(checkout, "rev-parse", "HEAD^{tree}") != str(source["tree"]):
        raise BundleError("asset checkout tree does not match the lock")
    if int(run_git(checkout, "show", "-s", "--format=%ct", "HEAD")) != source[
        "commit_epoch"
    ]:
        raise BundleError("asset checkout commit timestamp does not match the lock")


def prepare_source(checkout: Path, source: dict[str, Any], fetch: bool) -> None:
    """Prepare the pinned checkout without racing another bundle invocation."""
    checkout.parent.mkdir(parents=True, exist_ok=True)
    lock_path = checkout.parent / f".{checkout.name}.asset-bundle.lock"
    with lock_path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            prepare_source_locked(checkout, source, fetch)
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def materialize_subtrees(checkout: Path, lock: dict[str, Any]) -> None:
    """Populate the sparse checkout with exactly the subtrees the lock names.

    The clone is treeless, so the working tree is empty until the paths we care
    about are asked for by name. Sparse cone mode keeps the ~1 GB of wallpapers
    and per-platform packaging art out of the working tree entirely.
    """
    roots = sorted(
        {normalize_relative(str(sub["source_root"])).as_posix() for sub in lock["subtrees"]}
    )
    run_git(checkout, "sparse-checkout", "init", "--cone")
    run_git(checkout, "sparse-checkout", "set", *roots)
    run_git(checkout, "checkout", "--quiet", str(lock["source"]["commit"]))
    for root in roots:
        if not (checkout / root).is_dir():
            raise BundleError(
                f"subtree is absent at the locked commit: {root}"
            )


def classify(relative: PurePosixPath, rules: list[dict[str, Any]]) -> dict[str, str]:
    """Return the first matching license rule, or fail loudly.

    Failing on an unclassified file is the point: an upstream bump that adds a
    new kind of asset must be classified deliberately rather than shipped with
    a guessed license.
    """
    posix = relative.as_posix()
    for rule in rules:
        pattern = str(rule["match"])
        if fnmatch.fnmatch(posix, pattern) or (
            pattern.startswith("**/") and fnmatch.fnmatch(posix, pattern[3:])
        ):
            return {
                "license": rule["spdx"],
                "license_work": rule["work"],
                "license_notice": rule["notice"],
            }
    raise BundleError(
        f"no license rule matches {posix}; add one to the lock before shipping it"
    )


def collect_files(
    checkout: Path,
    lock: dict[str, Any],
    staging: Path,
) -> dict[str, dict[str, str]]:
    rules = list(lock["license_rules"])
    metadata: dict[str, dict[str, str]] = {}
    # FAT32 is case-insensitive, so two upstream files differing only in case
    # would silently collapse into one on the SD card. Upstream names icons
    # after console models ("Acorn - Risc PC.png"), which is exactly the shape
    # that drifts in case between contributors.
    folded: dict[str, str] = {}

    for subtree in lock["subtrees"]:
        source_root = checkout / normalize_relative(str(subtree["source_root"])).as_posix()
        output_root = normalize_relative(str(subtree["output_root"]))
        excluded = [
            normalize_relative(str(item)) for item in subtree.get("exclude", [])
        ]

        for path in sorted(source_root.rglob("*")):
            if not path.is_file():
                continue
            if path.is_symlink():
                raise BundleError(
                    f"symlink in asset source (FAT32 cannot carry it): {path}"
                )
            within = PurePosixPath(path.relative_to(source_root).as_posix())
            if any(
                within == item or item in within.parents for item in excluded
            ):
                continue
            relative = output_root / within
            validate_bundle_path(relative)
            if relative.as_posix() in metadata:
                raise BundleError(f"duplicate bundle path: {relative}")
            prior = folded.get(relative.as_posix().casefold())
            if prior is not None:
                raise BundleError(
                    f"FAT32 case-insensitive collision: {relative} and {prior}"
                )
            folded[relative.as_posix().casefold()] = relative.as_posix()

            destination = staging / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
            metadata[relative.as_posix()] = classify(relative, rules)

    if not metadata:
        raise BundleError("asset bundle would be empty")

    missing = [
        name
        for name in lock.get("required_files", [])
        if name not in metadata
    ]
    if missing:
        raise BundleError(
            "locked required files are absent from the built bundle: "
            + ", ".join(sorted(missing))
        )
    return metadata


def write_notice(staging: Path, lock: dict[str, Any], metadata: dict[str, dict[str, str]]) -> None:
    source = lock["source"]
    lines = [
        "# MLP1 RetroArch menu asset bundle notices",
        "",
        "Leaf assembles this bundle directly from the original upstream repository at",
        "the exact commit recorded in `manifest.json`. It does not redistribute copies",
        "taken from another firmware.",
        "",
        f"- URL: {source['source']}",
        f"- Commit: {source['commit']}",
        f"- Tree: {source['tree']}",
        f"- Repository license: {source.get('license_evidence_text', 'see COPYING')}",
        "",
        "## Included subtrees",
        "",
    ]
    for subtree in lock["subtrees"]:
        excludes = subtree.get("exclude", [])
        lines.append(f"### `{subtree['source_root']}`")
        lines.append("")
        lines.append(subtree["reason"])
        if excludes:
            lines.append("")
            lines.append("Excluded: " + ", ".join(f"`{item}`" for item in excludes))
        lines.append("")

    works: dict[tuple[str, str, str], int] = {}
    for row in metadata.values():
        key = (row["license_work"], row["license"], row["license_notice"])
        works[key] = works.get(key, 0) + 1

    lines.extend(["## Works and licenses", "", "| Work | License | Files |", "|---|---|---|"])
    for (work, spdx, _notice), count in sorted(works.items()):
        lines.append(f"| {work} | {spdx} | {count} |")
    lines.append("")
    for work, spdx, notice in sorted(works):
        lines.extend([f"**{work}** ({spdx}) - {notice}", ""])

    (staging / NOTICE_NAME).write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def build_manifest(
    staging: Path,
    lock: dict[str, Any],
    lock_path: Path,
    metadata: dict[str, dict[str, str]],
) -> dict[str, Any]:
    file_rows: list[dict[str, Any]] = []
    extension_counts: Counter[str] = Counter()
    installed_size = 0

    for path in sorted(
        (candidate for candidate in staging.rglob("*") if candidate.is_file()),
        key=lambda candidate: candidate.relative_to(staging).as_posix(),
    ):
        relative = path.relative_to(staging).as_posix()
        size = path.stat().st_size
        installed_size += size
        extension_counts[path.suffix.lower() or "(none)"] += 1
        row: dict[str, Any] = {
            "path": relative,
            "sha256": sha256_file(path),
            "size": size,
        }
        row.update(metadata.get(relative, {"license": GENERATED_LICENSE}))
        file_rows.append(row)

    extension_counts[".json"] += 1
    source = lock["source"]
    return {
        "schema_version": 1,
        "bundle_id": lock["bundle_id"],
        "platform": lock["platform"],
        "source": {
            "url": source["source"],
            "commit": source["commit"],
            "tree": source["tree"],
            "commit_epoch": source["commit_epoch"],
        },
        "lock": {
            "path": repo_relative(lock_path),
            "sha256": sha256_file(lock_path),
        },
        "generated_epoch": source["commit_epoch"],
        "subtrees": [
            {
                "source_root": subtree["source_root"],
                "output_root": subtree["output_root"],
                "exclude": list(subtree.get("exclude", [])),
            }
            for subtree in lock["subtrees"]
        ],
        "required_files": sorted(lock.get("required_files", [])),
        "file_count": len(file_rows),
        "installed_size_bytes": 0,
        "extension_counts": dict(sorted(extension_counts.items())),
        "files": file_rows,
    }


def serialize_manifest(manifest: dict[str, Any], content_size: int) -> bytes:
    """Settle installed_size_bytes, which includes the manifest's own length."""
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


def build_bundle(lock_path: Path, output: Path, fetch: bool) -> dict[str, Any]:
    lock = load_json(lock_path)
    validate_lock(lock, lock_path)

    checkout = REPO_ROOT / normalize_relative(str(lock["source"]["checkout"])).as_posix()
    prepare_source(checkout, lock["source"], fetch)
    verify_repository_license(checkout, lock["source"])
    materialize_subtrees(checkout, lock)

    staging = output.parent / f".{output.name}.staging"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    try:
        metadata = collect_files(checkout, lock, staging)
        write_notice(staging, lock, metadata)
        manifest = build_manifest(staging, lock, lock_path, metadata)
        content_size = sum(
            path.stat().st_size for path in staging.rglob("*") if path.is_file()
        )
        (staging / MANIFEST_NAME).write_bytes(
            serialize_manifest(manifest, content_size)
        )
        atomic_promote(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return manifest


def verify_repository_license(checkout: Path, source: dict[str, Any]) -> None:
    license_path_value = source.get("license_path")
    if not license_path_value:
        return
    license_path = checkout / normalize_relative(str(license_path_value)).as_posix()
    text = run_git(
        checkout,
        "show",
        f"{source['commit']}:{normalize_relative(str(license_path_value)).as_posix()}",
    )
    evidence = str(source.get("license_evidence_text", "")).casefold()
    if evidence and evidence not in text.casefold():
        raise BundleError(
            f"repository license evidence is stale in {license_path.name}: "
            f"expected to find {source['license_evidence_text']!r}"
        )


def validate_bundle(lock_path: Path, output: Path) -> dict[str, Any]:
    lock = load_json(lock_path)
    validate_lock(lock, lock_path)

    manifest_path = output / MANIFEST_NAME
    if not manifest_path.is_file():
        raise BundleError(f"missing asset bundle manifest: {manifest_path}")
    manifest = load_json(manifest_path)

    if manifest.get("bundle_id") != lock["bundle_id"]:
        raise BundleError("bundle_id does not match the lock")
    if manifest.get("platform") != lock["platform"]:
        raise BundleError("platform does not match the lock")
    if manifest.get("source", {}).get("commit") != lock["source"]["commit"]:
        raise BundleError("bundle was built from a different upstream commit")
    if manifest.get("lock", {}).get("sha256") != sha256_file(lock_path):
        raise BundleError("bundle was built from a different lock file")

    rows = manifest.get("files")
    if not isinstance(rows, list) or not rows:
        raise BundleError("manifest records no files")

    recorded = {str(row["path"]) for row in rows}
    on_disk = {
        path.relative_to(output).as_posix()
        for path in output.rglob("*")
        if path.is_file()
    }
    for extra in sorted(on_disk - recorded - GENERATED_NAMES):
        raise BundleError(f"unrecorded file in bundle: {extra}")
    for missing in sorted(recorded - on_disk):
        raise BundleError(f"manifest records a file that is absent: {missing}")

    installed_size = 0
    for row in rows:
        relative = PurePosixPath(str(row["path"]))
        path = output / relative
        if relative.name not in GENERATED_NAMES:
            validate_bundle_path(relative)
        size = path.stat().st_size
        if size != row["size"]:
            raise BundleError(f"size mismatch for {relative}")
        if sha256_file(path) != row["sha256"]:
            raise BundleError(f"sha256 mismatch for {relative}")
        if not row.get("license"):
            raise BundleError(f"unclassified file in manifest: {relative}")
        installed_size += size

    # The manifest is not one of its own rows, but it is part of what lands on
    # the SD card, so its length is folded into the recorded total.
    installed_size += manifest_path.stat().st_size

    missing_required = [
        name for name in lock.get("required_files", []) if name not in recorded
    ]
    if missing_required:
        raise BundleError(
            "bundle is missing files RetroArch needs: "
            + ", ".join(sorted(missing_required))
        )
    if installed_size != manifest.get("installed_size_bytes"):
        raise BundleError("installed_size_bytes does not match the bundle contents")
    return manifest


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build", help="build and validate the asset bundle")
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
    args = parse_args(argv if argv is not None else sys.argv[1:])
    try:
        if args.command == "build":
            manifest = build_bundle(
                args.lock.resolve(), args.output.resolve(), not args.no_fetch
            )
            manifest = validate_bundle(args.lock.resolve(), args.output.resolve())
            verb = "built"
        else:
            manifest = validate_bundle(args.lock.resolve(), args.output.resolve())
            verb = "validated"
        print(
            f"{verb} {manifest['file_count']} asset files "
            f"({manifest['installed_size_bytes']} bytes) at {args.output.resolve()}"
        )
    except BundleError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
