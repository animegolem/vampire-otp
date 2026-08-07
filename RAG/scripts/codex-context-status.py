#!/usr/bin/env python3
"""Report best-effort context usage from a persisted Codex rollout.

Codex exposes live token usage to its client, but not as a model-callable tool in
this harness. The desktop app persists equivalent ``token_count`` events in the
thread rollout. This helper reads the newest such event without modifying the
session.

The rollout format is not a stable hook API, so this is an operator aid rather
than an authorization or rollover trigger. It can also lag an active turn.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import sys


@dataclass(frozen=True)
class ContextStatus:
    thread_id: str
    rollout: str
    observed_at: str | None
    used_tokens: int
    context_window: int

    @property
    def remaining_tokens(self) -> int:
        return max(0, self.context_window - self.used_tokens)

    @property
    def used_percent(self) -> float:
        return 100 * self.used_tokens / self.context_window

    @property
    def remaining_percent(self) -> float:
        return 100 * self.remaining_tokens / self.context_window


def find_rollout(sessions_root: Path, thread_id: str) -> Path:
    candidates = list(sessions_root.rglob(f"*{thread_id}*.jsonl"))
    if not candidates:
        raise FileNotFoundError(
            f"no rollout for thread {thread_id!r} under {sessions_root}"
        )
    return max(candidates, key=lambda path: path.stat().st_mtime_ns)


def read_status(rollout: Path, thread_id: str) -> ContextStatus:
    latest: tuple[str | None, dict] | None = None
    with rollout.open(encoding="utf-8") as handle:
        for raw_line in handle:
            try:
                record = json.loads(raw_line)
            except (TypeError, ValueError):
                continue
            payload = record.get("payload") if isinstance(record, dict) else None
            if (
                record.get("type") == "event_msg"
                and isinstance(payload, dict)
                and payload.get("type") == "token_count"
                and isinstance(payload.get("info"), dict)
            ):
                latest = (record.get("timestamp"), payload["info"])
    if latest is None:
        raise ValueError(f"no token_count event found in {rollout}")

    observed_at, info = latest
    usage = info.get("last_token_usage")
    if not isinstance(usage, dict):
        raise ValueError("latest token_count event has no last_token_usage object")
    used_tokens = usage.get("total_tokens")
    context_window = info.get("model_context_window")
    if not isinstance(used_tokens, int) or not isinstance(context_window, int):
        raise ValueError("latest token_count event has invalid token counts")
    if used_tokens < 0 or context_window <= 0:
        raise ValueError("latest token_count event has nonsensical token counts")

    return ContextStatus(
        thread_id=thread_id,
        rollout=str(rollout),
        observed_at=observed_at if isinstance(observed_at, str) else None,
        used_tokens=used_tokens,
        context_window=context_window,
    )


def main() -> int:
    parser = argparse.ArgumentParser(prog="codex-context-status")
    parser.add_argument(
        "--thread-id",
        default=os.environ.get("CODEX_THREAD_ID"),
        help="Codex thread id (default: CODEX_THREAD_ID)",
    )
    parser.add_argument(
        "--sessions-root",
        type=Path,
        default=Path.home() / ".codex" / "sessions",
    )
    parser.add_argument(
        "--rollout",
        type=Path,
        help="read this rollout directly (primarily for diagnostics/tests)",
    )
    parser.add_argument("--json", action="store_true", dest="as_json")
    args = parser.parse_args()

    if not args.thread_id:
        parser.error("--thread-id is required when CODEX_THREAD_ID is unset")
    try:
        rollout = args.rollout or find_rollout(args.sessions_root, args.thread_id)
        status = read_status(rollout, args.thread_id)
    except (OSError, ValueError) as exc:
        print(f"codex-context-status: {exc}", file=sys.stderr)
        return 1

    if args.as_json:
        output = {
            **asdict(status),
            "remaining_tokens": status.remaining_tokens,
            "used_percent": round(status.used_percent, 2),
            "remaining_percent": round(status.remaining_percent, 2),
            "best_effort": True,
        }
        print(json.dumps(output, sort_keys=True))
    else:
        print(
            f"context: {status.used_tokens:,} / {status.context_window:,} tokens "
            f"({status.used_percent:.1f}% used, "
            f"{status.remaining_percent:.1f}% remaining)"
        )
        print(f"observed: {status.observed_at or 'unknown'}")
        print("note: best-effort persisted event; may lag the active turn")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
