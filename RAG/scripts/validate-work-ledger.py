#!/usr/bin/env python3
"""Validate the owner-signed WORK-LEDGER execution handshake."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

STATES = {
    "offered", "received", "scheduled", "started",
    "blocked", "parked", "done",
}
HEADER = [
    "work", "assignee", "state", "since", "progress_at",
    "next_actor", "evidence / trigger",
]
TASK_RE = re.compile(r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b")
BASE_RE = re.compile(r"\bbase\s+`?[0-9a-f]{7,40}`?", re.IGNORECASE)
ACTOR_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def _cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def _iso(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timezone is required")
    return parsed


def parse_live_table(text: str) -> tuple[list[dict], list[str]]:
    lines = text.splitlines()
    errors: list[str] = []
    try:
        live = lines.index("## Live")
    except ValueError:
        return [], ["missing `## Live` section"]
    header_at = next(
        (i for i in range(live + 1, len(lines))
         if lines[i].lstrip().startswith("| work |")), None)
    if header_at is None:
        return [], ["missing live table header"]
    header = _cells(lines[header_at])
    if header != HEADER:
        errors.append(
            f"live table header must be {HEADER!r}; found {header!r}")
    rows = []
    for lineno in range(header_at + 2, len(lines)):
        line = lines[lineno]
        if not line.startswith("|"):
            break
        cells = _cells(line)
        if len(cells) != len(HEADER):
            errors.append(
                f"line {lineno + 1}: expected {len(HEADER)} cells, "
                f"found {len(cells)}")
            continue
        rows.append(dict(zip(HEADER, cells), _line=lineno + 1))
    return rows, errors


def validate_ledger(path: Path, instant: datetime | None = None) -> dict:
    instant = instant or datetime.now(timezone.utc)
    rows, errors = parse_live_table(path.read_text())
    warnings: list[str] = []
    normalized = []
    seen = set()

    for row in rows:
        line = row["_line"]
        work = row["work"]
        state = row["state"]
        evidence = row["evidence / trigger"]
        if not work:
            errors.append(f"line {line}: work id is empty")
        elif work in seen:
            errors.append(f"line {line}: duplicate live work id {work!r}")
        seen.add(work)
        if state not in STATES:
            errors.append(f"line {line}: illegal state {state!r}")
        actor = row["next_actor"]
        if not actor or not ACTOR_RE.fullmatch(actor):
            errors.append(
                f"line {line}: next_actor must name exactly one actor")
        if not row["assignee"]:
            errors.append(f"line {line}: assignee is empty")
        if not row["since"]:
            errors.append(f"line {line}: since is empty")

        task_match = TASK_RE.search(evidence)
        progress = None
        progress_age = None
        lease_state = None
        if row["progress_at"]:
            try:
                progress = _iso(row["progress_at"])
                progress_age = max(0, (instant - progress).total_seconds())
            except ValueError as exc:
                errors.append(
                    f"line {line}: invalid progress_at: {exc}")

        if state == "scheduled":
            if not task_match or "start" not in evidence.lower() or \
                    "scope" not in evidence.lower():
                errors.append(
                    f"line {line}: scheduled evidence needs task id, "
                    "start, and scope")
        elif state == "started":
            required = (
                task_match,
                "clone" in evidence.lower(),
                "branch" in evidence.lower(),
                "base" in evidence.lower() and BASE_RE.search(evidence),
                "first" in evidence.lower() and
                ("command" in evidence.lower() or
                 "source-verification" in evidence.lower()),
            )
            if not all(required):
                errors.append(
                    f"line {line}: started evidence needs task id, clone, "
                    "branch, base SHA, and first-command timestamp")
            if progress is None:
                errors.append(
                    f"line {line}: started row requires progress_at")
                lease_state = "missing"
            elif progress_age > 45 * 60:
                errors.append(
                    f"line {line}: EXECUTOR DOWN; progress_at is "
                    f"{int(progress_age // 60)}m old")
                lease_state = "down"
            elif progress_age > 30 * 60:
                warnings.append(
                    f"line {line}: lease renewal overdue; progress_at is "
                    f"{int(progress_age // 60)}m old")
                lease_state = "overdue"
            else:
                lease_state = "alive"
        elif state in ("blocked", "parked"):
            if not evidence:
                errors.append(
                    f"line {line}: {state} row needs fact/trigger evidence")
        elif state == "received" and progress_age is not None and \
                progress_age > 15 * 60:
            errors.append(
                f"line {line}: UNOWNED WORK; received is unresolved >15m")
        elif state == "done":
            errors.append(
                f"line {line}: done rows belong in History, not Live")

        normalized.append({
            "work": work,
            "assignee": row["assignee"],
            "state": state,
            "since": row["since"],
            "progress_at": row["progress_at"] or None,
            "progress_age_seconds": progress_age,
            "executor_lease": lease_state,
            "next_actor": actor,
            "task_id": task_match.group(0) if task_match else None,
            "evidence": evidence,
            "line": line,
        })

    return {
        "path": str(path),
        "valid": not errors,
        "errors": errors,
        "warnings": warnings,
        "live_count": len(normalized),
        "rows": normalized,
    }


def main() -> None:
    parser = argparse.ArgumentParser(prog="validate-work-ledger")
    parser.add_argument("ledger", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    result = validate_ledger(args.ledger)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        for error in result["errors"]:
            print(f"ERROR: {error}")
        for warning in result["warnings"]:
            print(f"WARNING: {warning}")
        if result["valid"]:
            print(f"WORK-LEDGER valid: {result['live_count']} live row(s)")
    sys.exit(0 if result["valid"] else 1)


if __name__ == "__main__":
    main()
