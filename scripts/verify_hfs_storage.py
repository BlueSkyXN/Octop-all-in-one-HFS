#!/usr/bin/env python3
"""Read-only verification of the Octop Hugging Face storage contract."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tomllib
from collections import defaultdict
from pathlib import Path
from typing import Any

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = REPOSITORY_ROOT / "hfs-dev.toml"
DEFAULT_CONFIG = REPOSITORY_ROOT / "config.toml"


class AuditError(RuntimeError):
    """Raised when the live storage contract cannot be read or is invalid."""


def _hf_json(*args: str) -> Any:
    command = ["hf", *args, "--json"]
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise AuditError("hf CLI is not installed or not on PATH") from exc
    if result.returncode != 0:
        detail = (
            (result.stderr or result.stdout or "unknown error").strip().splitlines()
        )
        raise AuditError(
            f"{' '.join(command[:-1])} failed: {detail[-1] if detail else 'unknown error'}"
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise AuditError(f"{' '.join(command[:-1])} returned invalid JSON") from exc


def _human_bytes(value: int) -> str:
    size = float(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TiB"


def _load_toml(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except FileNotFoundError as exc:
        raise AuditError(f"contract file not found: {path}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise AuditError(f"invalid TOML contract: {path}: {exc}") from exc


def _load_contract(manifest_path: Path, config_path: Path) -> tuple[str, str, str]:
    manifest = _load_toml(manifest_path)
    config = _load_toml(config_path)
    storage = config.get("storage")
    paths = config.get("paths")
    if not isinstance(storage, dict) or not isinstance(paths, dict):
        raise AuditError("config.toml must define [storage] and [paths]")

    space_id = str(manifest.get("space") or "").strip()
    bucket_id = str(storage.get("bucket") or "").strip()
    mount_path = str(storage.get("mount_path") or "").strip()
    if not space_id or not bucket_id or not mount_path.startswith("/"):
        raise AuditError(
            "storage contract is missing space, bucket, or absolute mount_path"
        )
    if storage.get("read_only") is not False:
        raise AuditError("Octop primary storage contract must be read-write")
    if str(paths.get("home") or "").rstrip("/") != mount_path.rstrip("/"):
        raise AuditError("paths.home must equal storage.mount_path")
    expected_octop_home = f"{mount_path.rstrip('/')}/.octop"
    if str(paths.get("octop_home") or "").rstrip("/") != expected_octop_home:
        raise AuditError(f"paths.octop_home must equal {expected_octop_home}")
    return space_id, bucket_id, mount_path


def _prefix_totals(files: list[dict[str, Any]]) -> list[tuple[str, int, int]]:
    totals: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for item in files:
        if item.get("type") != "file":
            continue
        path = str(item.get("path") or "")
        prefix = path.split("/", 1)[0] or "."
        totals[prefix][0] += 1
        totals[prefix][1] += int(item.get("size") or 0)
    return sorted(
        ((prefix, values[0], values[1]) for prefix, values in totals.items()),
        key=lambda row: (-row[2], row[0]),
    )


def audit(space_id: str, bucket_id: str, mount_path: str) -> int:
    space = _hf_json("spaces", "info", space_id)
    volumes = _hf_json("spaces", "volumes", "list", space_id)
    bucket = _hf_json("buckets", "info", bucket_id)
    files = _hf_json("buckets", "list", bucket_id, "-R")

    errors: list[str] = []
    warnings: list[str] = []

    if space.get("private") is not True:
        errors.append("Space is not private/protected")
    if bucket.get("private") is not True:
        errors.append("bucket is not private")

    mounted_here = [v for v in volumes if v.get("mount_path") == mount_path]
    expected = [
        v
        for v in mounted_here
        if v.get("type") == "bucket" and v.get("source") == bucket_id
    ]
    if len(expected) != 1:
        errors.append(
            f"expected exactly one {bucket_id} bucket volume at {mount_path}; found {len(expected)}"
        )
    elif expected[0].get("read_only") is not False:
        errors.append(f"bucket volume at {mount_path} is not read-write")
    if len(mounted_here) != 1:
        errors.append(
            f"mount path {mount_path} has {len(mounted_here)} configured volumes"
        )

    runtime = space.get("runtime") or {}
    stage = str(runtime.get("stage") or "UNKNOWN")
    if stage != "RUNNING":
        warnings.append(f"Space runtime stage is {stage}, not RUNNING")

    prefix_totals = _prefix_totals(files)
    cache_bytes = next(
        (size for prefix, _, size in prefix_totals if prefix == ".cache"), 0
    )
    if cache_bytes:
        warnings.append(
            f"persistent .cache still contains {_human_bytes(cache_bytes)}; runtime cache should use /tmp"
        )

    print("Storage contract")
    print(f"  space:  {space_id}")
    print(f"  stage:  {stage}")
    print(f"  sha:    {space.get('sha') or runtime.get('sha') or 'unknown'}")
    print(f"  bucket: {bucket_id}")
    print(f"  mount:  {mount_path}:rw")
    print(f"  size:   {_human_bytes(int(bucket.get('size') or 0))}")
    print(f"  files:  {int(bucket.get('total_files') or len(files))}")

    print("\nTop-level bucket usage")
    if prefix_totals:
        for prefix, count, size in prefix_totals:
            print(f"  {prefix:<24} {count:>6} files  {_human_bytes(size):>10}")
    else:
        print("  (empty)")

    if warnings:
        print("\nWarnings")
        for warning in warnings:
            print(f"  WARN: {warning}")
    if errors:
        print("\nErrors", file=sys.stderr)
        for error in errors:
            print(f"  ERROR: {error}", file=sys.stderr)
        return 1

    print("\nResult: storage mapping is valid")
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest", type=Path, default=DEFAULT_MANIFEST, help="HFS manifest"
    )
    parser.add_argument(
        "--config", type=Path, default=DEFAULT_CONFIG, help="storage contract"
    )
    parser.add_argument("--space", help="override Hugging Face Space ID")
    parser.add_argument("--bucket", help="override Hugging Face bucket ID")
    parser.add_argument("--mount", help="override expected container mount path")
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        contract_space, contract_bucket, contract_mount = _load_contract(
            args.manifest,
            args.config,
        )
        return audit(
            args.space or contract_space,
            args.bucket or contract_bucket,
            args.mount or contract_mount,
        )
    except AuditError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
