#!/usr/bin/env python3
"""One-shot carrier-to-Codex CLI wake for a launchd filesystem event.

The filesystem event is only a wake hint. This helper quiet-samples sorted
path/SHA-256 tuples, persists a pending marker, runs carrier sync, and sends a
fixed prompt through `codex exec resume`. It never reads channel bodies into
the prompt and never writes an application ACK.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(value, indent=2, sort_keys=True) + "\n"
    fd, temp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass


def collect(repo: Path, watched: list[str]) -> list[Path]:
    found: set[Path] = set()
    for raw in watched:
        candidate = (repo / raw).resolve() if not Path(raw).is_absolute() else Path(raw).resolve()
        if candidate.is_dir():
            found.update(path for path in candidate.rglob("*.md") if path.is_file())
        elif candidate.is_file():
            found.add(candidate)
    return sorted(found, key=lambda path: str(path))


def fingerprint(repo: Path, watched: list[str]) -> tuple[str, list[dict]]:
    rows: list[dict] = []
    for path in collect(repo, watched):
        try:
            relative = str(path.relative_to(repo))
        except ValueError:
            relative = str(path)
        rows.append({
            "path": relative,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    encoded = json.dumps(rows, separators=(",", ":"), sort_keys=True).encode()
    return hashlib.sha256(encoded).hexdigest(), rows


def quiet_fingerprint(repo: Path, watched: list[str], quiet_seconds: float,
                      attempts: int) -> tuple[str, list[dict]]:
    prior = fingerprint(repo, watched)
    for _ in range(attempts):
        if quiet_seconds:
            time.sleep(quiet_seconds)
        current = fingerprint(repo, watched)
        if current == prior:
            return current
        prior = current
    raise RuntimeError("watched files did not reach a quiet second sample")


def load_json(path: Path) -> dict | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else None
    except (FileNotFoundError, ValueError, OSError):
        return None


def run(command: list[str], repo: Path) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=repo, text=True, capture_output=True)


def run_once(args: argparse.Namespace) -> int:
    repo = args.repo.expanduser().resolve()
    state_dir = args.state_dir.expanduser().resolve()
    delivered_path = state_dir / "delivered.json"
    pending_path = state_dir / "pending.json"
    current_hash, rows = quiet_fingerprint(
        repo, args.watch, args.quiet_seconds, args.quiet_attempts,
    )
    delivered = load_json(delivered_path) or {}
    pending = load_json(pending_path)

    if args.probe:
        print(json.dumps({
            "current_fingerprint": current_hash,
            "delivered_fingerprint": delivered.get("fingerprint"),
            "pending": pending,
            "watched": rows,
        }, indent=2, sort_keys=True))
        return 0
    if args.prime:
        atomic_json(delivered_path, {
            "fingerprint": current_hash, "primed_at": utc_now(), "watched": rows,
        })
        pending_path.unlink(missing_ok=True)
        return 0
    if not pending and delivered.get("fingerprint") == current_hash:
        return 0

    target = pending if pending and pending.get("fingerprint") == current_hash else {
        "fingerprint": current_hash,
        "first_seen_at": utc_now(),
        "watched": rows,
    }
    target["attempted_at"] = utc_now()
    target["attempts"] = int(target.get("attempts", 0)) + 1
    atomic_json(pending_path, target)

    carrier_command = [
        sys.executable, str(args.carrier_script.expanduser().resolve()),
        "sync", "--repo", str(repo),
    ]
    synced = run(carrier_command, repo)
    if synced.returncode:
        target["last_error"] = synced.stderr.strip() or synced.stdout.strip() or "carrier sync failed"
        atomic_json(pending_path, target)
        print(target["last_error"], file=sys.stderr)
        return 1

    wake_command = [
        *shlex.split(args.codex_command), "exec", "resume", args.thread_id,
        args.prompt,
    ]
    woke = run(wake_command, repo)
    if woke.returncode:
        target["last_error"] = woke.stderr.strip() or woke.stdout.strip() or "Codex wake failed"
        atomic_json(pending_path, target)
        print(target["last_error"], file=sys.stderr)
        return 1

    atomic_json(delivered_path, {
        "delivered_at": utc_now(),
        "fingerprint": current_hash,
        "watched": rows,
    })
    pending_path.unlink(missing_ok=True)
    after_hash, _ = quiet_fingerprint(
        repo, args.watch, args.quiet_seconds, args.quiet_attempts,
    )
    if after_hash != current_hash:
        # A new version arrived during the resumed turn. A nonzero exit asks
        # launchd's SuccessfulExit=false policy to immediately schedule another
        # bounded one-shot attempt; no resident poller is needed.
        atomic_json(pending_path, {
            "fingerprint": after_hash,
            "first_seen_at": utc_now(),
            "attempts": 0,
            "reason": "changed-during-delivery",
        })
        return 75
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="codex-relay-wake")
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--thread-id", required=True)
    parser.add_argument("--carrier-script", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--codex-command", default="codex")
    parser.add_argument("--prompt", default="scan the channel")
    parser.add_argument(
        "--watch", action="append",
        help="relative file or directory; repeatable (default: .codex/outbox)",
    )
    parser.add_argument("--quiet-seconds", type=float, default=0.35)
    parser.add_argument("--quiet-attempts", type=int, default=8)
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--prime", action="store_true")
    args = parser.parse_args()
    args.watch = args.watch or [".codex/outbox"]
    try:
        return run_once(args)
    except Exception as exc:
        print(f"codex-relay-wake: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
