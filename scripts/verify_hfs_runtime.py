#!/usr/bin/env python3
"""Verify the official release pins and HFS guards without credentials or remote calls."""

from __future__ import annotations

import argparse
import importlib.metadata as metadata
import json
import os
import sqlite3
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

PACKAGES = {
    "harness": "octop-harness",
    "gateway": "octop-gateway",
    "memory": "octop-memory",
    "browser": "octop-browser",
}


def verify_installation() -> dict[str, object]:
    source_ref = os.environ["OCTOP_HFS_UPSTREAM_REF"]
    assert Path("/app/.octop-upstream-ref").read_text().strip() == source_ref
    assert metadata.version("octop") == os.environ["OCTOP_HFS_UPSTREAM_VERSION"]
    expected = dict(
        part.split("=", 1) for part in os.environ["OCTOP_HFS_COMPONENT_VERSIONS"].split(";")
    )
    assert expected.keys() == PACKAGES.keys()
    installed: dict[str, str] = {}
    for key, name in PACKAGES.items():
        version = metadata.version(name)
        assert version == expected[key], (name, version, expected[key])
        installed[name] = version
    return {
        "octop_version": metadata.version("octop"),
        "octop_sha": source_ref,
        "components": installed,
    }


def verify_gateway_import() -> None:
    from octop_gateway.channels.feishu import FeishuChannel, FeishuConfig

    assert FeishuChannel.__name__ == "FeishuChannel"
    assert FeishuConfig.__name__ == "FeishuConfig"


def verify_desktop_routes() -> None:
    from octop.api.app import build_app
    from octop.config import OctopConfig

    server = SimpleNamespace(
        services=None,
        config=OctopConfig(enable_dashboard=False, enable_api_docs=False),
        app_runtime=None,
    )
    paths = build_app(server).openapi()["paths"]
    assert any(path.startswith("/api/agents") for path in paths)
    assert not any(path.startswith("/api/desktop") for path in paths)


def verify_workspace_guard() -> None:
    from octop.infra.agents.workspace.dir import (
        default_agent_workspace_dir,
        resolve_workspace_host_path,
    )
    from octop.infra.utils.paths import PathLayout

    with tempfile.TemporaryDirectory(prefix="octop-hfs-contract-") as tmp:
        root = Path(tmp)
        persistent = root / "data"
        outside = root / "outside"
        with patch.dict(os.environ, {"OCTOP_PERSISTENT_ROOT": str(persistent)}):
            for ensure in (False, True):
                try:
                    default_agent_workspace_dir(PathLayout(outside), "test", ensure=ensure)
                except ValueError:
                    pass
                else:
                    raise AssertionError("workspace guard accepted an ephemeral home")
                assert not outside.exists()
            assert (
                resolve_workspace_host_path(str(persistent / "workspace"))
                == (persistent / "workspace").resolve()
            )
            assert default_agent_workspace_dir(PathLayout(persistent / ".octop"), "test").is_dir()


def database_summary() -> dict[str, object]:
    path = Path(os.environ["OCTOP_HOME"]) / "octop.db"
    if not path.is_file():
        return {"exists": False}
    with sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True, timeout=10) as conn:
        integrity = [row[0] for row in conn.execute("PRAGMA quick_check")]
        assert integrity == ["ok"], "SQLite integrity check failed"
        tables = {
            row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        counts = {
            name: conn.execute(f'SELECT count(*) FROM "{name}"').fetchone()[0]
            for name in (
                "users",
                "agents",
                "channels",
                "threads",
                "thread_messages",
                "knowledge_bases",
            )
            if name in tables
        }
        version = (
            conn.execute("SELECT version FROM _schema_version").fetchone()[0]
            if "_schema_version" in tables
            else None
        )
    return {"exists": True, "quick_check": "ok", "schema_version": version, "row_counts": counts}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database-summary", action="store_true")
    args = parser.parse_args()
    report = verify_installation()
    verify_workspace_guard()
    verify_desktop_routes()
    verify_gateway_import()
    report["synthetic_regressions"] = "official-release-guards"
    if args.database_summary:
        report["database"] = database_summary()
    print("[hfs-verification] " + json.dumps(report, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
