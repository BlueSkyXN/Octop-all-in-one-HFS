#!/usr/bin/env python3
"""Verify pinned packages and offline behavior without credentials or remote calls."""

from __future__ import annotations

import argparse
import asyncio
import importlib.metadata as metadata
import json
import os
import sqlite3
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

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
    refs = dict(part.split("=", 1) for part in os.environ["OCTOP_HFS_COMPONENT_REFS"].split(";"))
    assert refs.keys() == PACKAGES.keys()
    installed: dict[str, object] = {}
    for key, name in PACKAGES.items():
        dist = metadata.distribution(name)
        info = json.loads(dist.read_text("direct_url.json") or "{}")
        assert info.get("url") == f"https://github.com/BlueSkyXN/{name}.git", name
        assert info.get("vcs_info", {}).get("commit_id") == refs[key], name
        installed[name] = {"version": dist.version, "sha": refs[key], "source": info["url"]}
    return {
        "octop_version": metadata.version("octop"),
        "octop_sha": source_ref,
        "components": installed,
    }


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


async def verify_feishu() -> None:
    from octop_gateway.channels.feishu import FeishuChannel, FeishuConfig
    from octop_gateway.channels.feishu_card import StreamCardSession
    from octop_gateway.models import MessageEvent
    from octop_harness.mcp import mcp_args_model

    from octop.infra.gateway.process.turn_budget import (
        TurnBudgetOutcome,
        TurnBudgetSpec,
        consume_turn_stream,
    )

    async def noop(message):
        yield MessageEvent.completed()

    def payload(mid, mention="", group=False):
        return {
            "message_id": mid,
            "chat_id": "oc_synthetic",
            "chat_type": "group" if group else "p2p",
            "message_type": "text",
            "content": '{"text":"synthetic"}',
            "sender": {"sender_id": "ou_synthetic"},
            "mentions": [{"key": "@_user_1", "open_id": mention, "name": "test"}]
            if mention
            else [],
        }

    args_model = mcp_args_model("synthetic", {"properties": {"args": {"type": "object"}}})
    assert args_model.model_validate({"args": {"id": "test"}}).args == {"id": "test"}
    assert args_model.model_validate({"args": '{"id":"test"}'}).args == {"id": "test"}
    channel = FeishuChannel(noop, FeishuConfig())
    channel._bot_open_id = "ou_bot"
    for mention in ("all", "ou_other"):
        assert not channel.parse_inbound(payload("om_gate", mention, True)).metadata[
            "bot_mentioned"
        ]
    assert channel.parse_inbound(payload("om_bot", "ou_bot", True)).metadata["bot_mentioned"]
    channel._bot_open_id = None
    assert not channel.parse_inbound(payload("om_unknown", "ou_bot", True)).metadata[
        "bot_mentioned"
    ]
    add = AsyncMock(side_effect=["r1", "r2"])
    remove = AsyncMock()
    with (
        patch.object(channel, "_add_reaction", add),
        patch.object(channel, "_remove_reaction", remove),
    ):
        merged = channel.merge_inbound(
            [channel.parse_inbound(payload("om_1")), channel.parse_inbound(payload("om_2"))]
        )
        await channel.handle_inbound(merged)
    assert [call.args for call in remove.await_args_list] == [("om_1", "r1"), ("om_2", "r2")]

    class FakeCardClient:
        async def create_card(self, card):
            return "card_synthetic"

        async def update_card(self, card_id, card, sequence):
            pass

        async def close_card(self, card_id, sequence, summary):
            pass

    card = StreamCardSession(
        http_provider=AsyncMock(),
        token_provider=AsyncMock(return_value="synthetic"),
        deliver=AsyncMock(),
        locale="zh",
        client_factory=lambda *_args: FakeCardClient(),
    )
    await card.start()

    async def failed(message):
        yield MessageEvent.delta("partial")
        yield MessageEvent.error_event("synthetic failure")
        yield MessageEvent.completed()

    channel = FeishuChannel(failed, FeishuConfig(stream_card=True))
    with (
        patch.object(channel, "_start_card", AsyncMock(return_value=card)),
        patch.object(channel, "_add_reaction", AsyncMock(return_value=None)),
    ):
        await channel.handle_inbound(payload("om_card"))
    assert card.state.terminal == "error"
    assert card.state.display_text() == "partial"
    assert card._flusher is None
    assert await card.close("done") == []
    assert card.state.terminal == "error"

    closed = asyncio.Event()
    cancelled = []

    async def blocked():
        try:
            yield MessageEvent.text("synthetic")
            await asyncio.Event().wait()
        finally:
            closed.set()

    outcome = TurnBudgetOutcome()
    events = [
        event
        async for event in consume_turn_stream(
            blocked(),
            spec=TurnBudgetSpec(0.05, 0.01),
            agent_id="synthetic",
            thread_id="synthetic",
            locale="en",
            cancel=lambda: cancelled.append(True),
            outcome=outcome,
        )
    ]
    assert outcome.timed_out and cancelled == [True] and closed.is_set()
    assert any(event.error for event in events)


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
    asyncio.run(verify_feishu())
    report["synthetic_regressions"] = "passed"
    if args.database_summary:
        report["database"] = database_summary()
    print("[hfs-verification] " + json.dumps(report, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
