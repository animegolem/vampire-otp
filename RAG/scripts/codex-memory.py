#!/usr/bin/env python3
"""Codex turn-log memory using stable lifecycle-hook fields.

`capture` is a UserPromptSubmit hook. `stop` is a Stop hook that only queues
the exchange and launches a detached drain. `drain` writes one exact JSON
exchange and one git commit. `inject` is a SessionStart hook that returns a
bounded handoff plus git-log tail.

The memory repository is deliberately separate from project canon.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_payload() -> dict:
    try:
        value = json.load(sys.stdin)
    except (ValueError, OSError):
        return {}
    return value if isinstance(value, dict) else {}


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
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


def token(*parts: str) -> str:
    raw = "\0".join(parts).encode()
    return hashlib.sha256(raw).hexdigest()[:24]


def safe_component(value: str) -> str:
    clean = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-.")
    return clean[:80] or token(value)


def stage_path(root: Path, session_id: str, turn_id: str) -> Path:
    return root / ".codex-memory" / "staged" / f"{token(session_id, turn_id)}.json"


def is_noise(prompt: str) -> bool:
    stripped = prompt.strip()
    if not stripped:
        return True
    if stripped.startswith(("<heartbeat>", "[SYSTEM NOTIFICATION", "<task-notification>")):
        return True
    ignored = os.environ.get("MEMLOG_IGNORED_PROMPTS", "scan the channel")
    return stripped in {item.strip() for item in ignored.split("||") if item.strip()}


@contextmanager
def exclusive(root: Path):
    root.mkdir(parents=True, exist_ok=True)
    lock_path = root / ".codex-memory.lock"
    with lock_path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def capture(root: Path, payload: dict) -> int:
    if os.environ.get("CODEX_MEMORY_GUARD"):
        return 0
    session_id = str(payload.get("session_id") or "")
    turn_id = str(payload.get("turn_id") or "")
    prompt = payload.get("prompt")
    if not session_id or not turn_id or not isinstance(prompt, str):
        return 0
    atomic_json(stage_path(root, session_id, turn_id), {
        "captured_at": utc_now(),
        "cwd": payload.get("cwd"),
        "model": payload.get("model"),
        "prompt": prompt,
        "session_id": session_id,
        "turn_id": turn_id,
    })
    return 0


def spawn_drain(root: Path) -> None:
    if os.environ.get("CODEX_MEMORY_NO_SPAWN"):
        return
    env = os.environ.copy()
    env["CODEX_MEMORY_GUARD"] = "1"
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "drain", str(root)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
        start_new_session=True,
        close_fds=True,
    )


def stop(root: Path, payload: dict) -> int:
    if os.environ.get("CODEX_MEMORY_GUARD"):
        return 0
    session_id = str(payload.get("session_id") or "")
    turn_id = str(payload.get("turn_id") or "")
    response = payload.get("last_assistant_message")
    if not session_id or not turn_id or not isinstance(response, str):
        return 0
    staged = stage_path(root, session_id, turn_id)
    try:
        prompt_record = json.loads(staged.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError, OSError):
        return 0
    prompt = prompt_record.get("prompt")
    if not isinstance(prompt, str):
        return 0
    if is_noise(prompt):
        staged.unlink(missing_ok=True)
        return 0
    record = {
        "assistant": response,
        "completed_at": utc_now(),
        "cwd": prompt_record.get("cwd") or payload.get("cwd"),
        "model": prompt_record.get("model") or payload.get("model"),
        "session_id": session_id,
        "turn_id": turn_id,
        "user": prompt,
    }
    queue_path = root / ".codex-memory" / "queue" / f"{utc_now()}-{token(session_id, turn_id)}.json"
    atomic_json(queue_path, record)
    staged.unlink(missing_ok=True)
    spawn_drain(root)
    return 0


def run(command: list[str], *, cwd: Path, input_text: str | None = None,
        env: dict | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        command, cwd=cwd, input=input_text, text=True, capture_output=True,
        env=env, check=check, timeout=180,
    )


def init_repo(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    if not (root / ".git").is_dir():
        run(["git", "init", "-q"], cwd=root)
    run(["git", "config", "user.name", "Codex Turn Memory"], cwd=root)
    run(["git", "config", "user.email", "codex-memory@local"], cwd=root)
    exclude = root / ".git" / "info" / "exclude"
    existing = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
    additions = [entry for entry in (".codex-memory/", ".codex-memory.lock")
                 if entry not in existing.splitlines()]
    if additions:
        with exclude.open("a", encoding="utf-8") as handle:
            if existing and not existing.endswith("\n"):
                handle.write("\n")
            handle.write("\n".join(additions) + "\n")


def fallback_subject(user: str) -> str:
    line = " ".join(user.split())
    if len(line) > 118:
        line = line[:115].rstrip() + "..."
    return line or "Recorded a Codex exchange"


def clean_subject(value: str, user: str) -> str:
    line = " ".join(value.splitlines()).strip().strip('"`')
    line = re.sub(r"\s+", " ", line)
    if len(line) > 160:
        line = line[:157].rstrip() + "..."
    return line or fallback_subject(user)


def summarize(root: Path, record: dict) -> str:
    user = record["user"]
    assistant = record["assistant"]
    prompt = (
        "Summarize this exchange as one past-tense sentence for a memory-log "
        "commit subject. Lead with what the user said, asked, or decided; aim "
        "under 120 characters. Output only the sentence.\n\n"
        f"USER:\n{user[:3000]}\n\nASSISTANT:\n{assistant[:2000]}\n"
    )
    custom = os.environ.get("MEMLOG_SUMMARIZER_CMD")
    if custom:
        try:
            result = run(shlex.split(custom), cwd=root, input_text=prompt)
            return clean_subject(result.stdout, user)
        except (OSError, subprocess.SubprocessError):
            return fallback_subject(user)
    model = os.environ.get("MEMLOG_MODEL")
    codex = shutil.which("codex")
    if not model or not codex:
        return fallback_subject(user)
    env = os.environ.copy()
    env["CODEX_MEMORY_GUARD"] = "1"
    output_file = root / ".codex-memory" / "summary.txt"
    command = [
        codex, "exec", "--ephemeral", "--ignore-rules",
        "--skip-git-repo-check", "--sandbox", "read-only",
        "--model", model, "--output-last-message", str(output_file), "-",
    ]
    try:
        run(command, cwd=root, input_text=prompt, env=env)
        value = output_file.read_text(encoding="utf-8")
        output_file.unlink(missing_ok=True)
        return clean_subject(value, user)
    except (OSError, subprocess.SubprocessError):
        output_file.unlink(missing_ok=True)
        return fallback_subject(user)


def drain(root: Path) -> int:
    with exclusive(root):
        init_repo(root)
        queue = root / ".codex-memory" / "queue"
        for item in sorted(queue.glob("*.json")) if queue.is_dir() else []:
            try:
                record = json.loads(item.read_text(encoding="utf-8"))
                session_id = str(record["session_id"])
                turn_id = str(record["turn_id"])
                if not isinstance(record["user"], str) or not isinstance(record["assistant"], str):
                    raise ValueError("exchange text must be strings")
                dest = root / "exchanges" / safe_component(session_id) / f"{safe_component(turn_id)}.json"
                atomic_json(dest, record)
                relative = dest.relative_to(root)
                run(["git", "add", "--", str(relative)], cwd=root)
                changed = run(["git", "diff", "--cached", "--quiet"], cwd=root, check=False)
                if changed.returncode:
                    subject = summarize(root, record)
                    run(["git", "commit", "-q", "-m", subject], cwd=root)
                item.unlink()
            except Exception as exc:  # retain queue item for the next drain
                atomic_json(root / ".codex-memory" / "last-error.json", {
                    "at": utc_now(), "error": str(exc), "queue_file": str(item),
                })
                return 1
        (root / ".codex-memory" / "last-error.json").unlink(missing_ok=True)
    return 0


def latest_handoff(directory: Path | None) -> tuple[str, str] | None:
    if directory is None or not directory.is_dir():
        return None
    files = list(directory.glob("*.md"))
    if not files:
        return None
    path = max(files, key=lambda candidate: candidate.stat().st_mtime_ns)
    return path.name, path.read_text(encoding="utf-8")


def inject(root: Path, payload: dict, handoff_dir: Path | None, count: int,
           sources: set[str]) -> int:
    if os.environ.get("CODEX_MEMORY_GUARD"):
        return 0
    if str(payload.get("source") or "") not in sources:
        return 0
    sections: list[str] = []
    handoff = latest_handoff(handoff_dir)
    if handoff:
        sections.append(f"## Latest session handoff — {handoff[0]}\n\n{handoff[1].rstrip()}")
    if (root / ".git").is_dir():
        result = run(
            ["git", "log", f"-n{count}", "--date=format:%Y-%m-%d %H:%M",
             "--format=%ad  %s"], cwd=root, check=False,
        )
        if result.stdout.strip():
            sections.append(
                f"## Codex turn-log memory (newest first, last {count} exchanges)\n\n"
                "Each line indexes one exact JSON exchange. Retrieve older detail with "
                f"`git -C {root} log` and `git -C {root} show`.\n\n{result.stdout.strip()}"
            )
    if sections:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": "\n\n".join(sections),
            }
        }, ensure_ascii=False))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="codex-memory")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("capture", "stop", "drain"):
        command = sub.add_parser(name)
        command.add_argument("memlog", type=Path)
    inject_parser = sub.add_parser("inject")
    inject_parser.add_argument("memlog", type=Path)
    inject_parser.add_argument("--handoff-dir", type=Path)
    inject_parser.add_argument("--count", type=int, default=40)
    inject_parser.add_argument(
        "--sources", default="startup,resume,clear,compact",
        help="comma-separated SessionStart sources",
    )
    args = parser.parse_args()
    root = args.memlog.expanduser().resolve()
    if args.command == "capture":
        return capture(root, read_payload())
    if args.command == "stop":
        return stop(root, read_payload())
    if args.command == "drain":
        return drain(root)
    sources = {value.strip() for value in args.sources.split(",") if value.strip()}
    handoff_dir = args.handoff_dir.expanduser().resolve() if args.handoff_dir else None
    return inject(root, read_payload(), handoff_dir, args.count, sources)


if __name__ == "__main__":
    raise SystemExit(main())
