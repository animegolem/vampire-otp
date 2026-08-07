#!/usr/bin/env python3
"""Run the four carrier adoption drills in an isolated temporary repo."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
CARRIER = SCRIPT_DIR / "carrier.py"
SCANNER = SCRIPT_DIR / "channel-scan.sh"


def live_message(topic: str, body: str) -> str:
    return (
        "---\n"
        f"submission: {topic}\n"
        "type: consultation\n"
        "branch: none\n"
        "commit: none\n"
        "round: 1\n"
        "---\n\n"
        f"{body}\n"
    )


def run_carrier(repo: Path, state: Path, *args: str, check: bool = True):
    env = os.environ.copy()
    env["CARRIER_CHANNEL"] = ".relay"
    env["CARRIER_STATE_DIR"] = str(state)
    result = subprocess.run(
        [sys.executable, str(CARRIER), *args, "--repo", str(repo)],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    if check and result.returncode:
        raise RuntimeError(
            f"carrier {' '.join(args)} failed ({result.returncode}): "
            f"{result.stderr or result.stdout}"
        )
    return result


def rows(db_path: Path, topic: str | None = None):
    with sqlite3.connect(db_path) as conn:
        if topic is None:
            return conn.execute(
                "SELECT event_id, topic, digest, created_ts, state "
                "FROM events ORDER BY event_id"
            ).fetchall()
        return conn.execute(
            "SELECT event_id, topic, digest, created_ts, state "
            "FROM events WHERE topic=? ORDER BY created_ts", (topic,)
        ).fetchall()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="vampireotp-carrier-") as temp:
        root = Path(temp)
        repo = root / "repo"
        state = root / "state"
        inbox = repo / ".relay" / "inbox"
        outbox = repo / ".relay" / "outbox"
        archive = repo / ".relay" / "archive"
        for directory in (inbox, outbox, archive):
            directory.mkdir(parents=True, exist_ok=True)
        db_path = state / "index.db"

        # T1: an overwritten live file produces two immutable events; only the
        # digest actually acknowledged becomes acked.
        t1 = inbox / "t1.md"
        t1.write_text(live_message("t1", "first payload"))
        run_carrier(repo, state, "sync")
        first_digest = digest(t1)
        t1.write_text(live_message("t1", "second payload"))
        run_carrier(repo, state, "sync")
        second_digest = digest(t1)
        run_carrier(repo, state, "ack-file", "--file", str(t1))
        t1_rows = rows(db_path, "t1")
        assert len(t1_rows) == 2, t1_rows
        states_by_digest = {row[2]: row[4] for row in t1_rows}
        assert states_by_digest[first_digest] == "pending", states_by_digest
        assert states_by_digest[second_digest] == "acked", states_by_digest
        print("T1 PASS — superseded digest preserved; current digest alone acked")

        # T2: scanner starts while a file is torn, observes the second sample
        # change, waits for quiet, then registers exactly the final digest.
        t2 = inbox / "t2.md"
        final_t2 = live_message("t2", "payload completed after partial write")
        split_at = final_t2.index("payload") + 3
        t2.write_text(final_t2[:split_at])
        scan_env = os.environ.copy()
        scan_env["VAMPIREOTP_OWNER_REPO"] = str(repo)
        scanner = subprocess.Popen(
            [str(SCANNER), "--once"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=scan_env,
        )
        time.sleep(0.35)
        with t2.open("a") as handle:
            handle.write(final_t2[split_at:])
        scan_stdout, scan_stderr = scanner.communicate(timeout=10)
        assert scanner.returncode == 0, (
            scanner.returncode,
            scan_stdout,
            scan_stderr,
        )
        t2_rows = rows(repo / ".relay" / "state" / "index.db", "t2")
        assert len(t2_rows) == 1, t2_rows
        assert t2_rows[0][2] == digest(t2), t2_rows
        print("T2 PASS — quiet second sample admitted only the final digest")

        # The scanner deliberately owns a repo-local state directory. Continue
        # the remaining drills against that same materialized index.
        state = repo / ".relay" / "state"
        db_path = state / "index.db"

        # T3: simulate a 31-minute hostage ACK by aging the born receipt in the
        # throwaway fixture, rebuilding, and checking the pending age report.
        t3 = inbox / "t3.md"
        t3.write_text(live_message("t3", "leave this unread"))
        run_carrier(repo, state, "sync")
        t3_row = rows(db_path, "t3")[0]
        born = repo / ".relay" / "carrier" / "receipts" / f"{t3_row[0]}.born.json"
        receipt = json.loads(born.read_text())
        receipt["ts"] = (datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat()
        born.write_text(json.dumps(receipt, indent=1))
        run_carrier(repo, state, "rebuild")
        status = run_carrier(repo, state, "status", check=False)
        assert status.returncode == 1, status.stdout
        t3_line = next(line for line in status.stdout.splitlines() if line.strip().startswith("t3 "))
        assert "unacked 31m" in t3_line, t3_line
        print("T3 PASS — pending age remains visible while ACK is withheld")

        # T4: delete only the derivable index, publish while it is absent, then
        # rebuild and prove prior semantic rows retain state and birth time.
        before = {row[0]: row[2:] for row in rows(db_path)}
        db_path.unlink()
        t4 = inbox / "t4.md"
        t4.write_text(live_message("t4", "published while index is absent"))
        run_carrier(repo, state, "sync")
        run_carrier(repo, state, "rebuild")
        after_rows = rows(db_path)
        after = {row[0]: row[2:] for row in after_rows}
        for event_id, semantic in before.items():
            assert after[event_id] == semantic, (event_id, semantic, after[event_id])
        assert any(row[1] == "t4" for row in after_rows), after_rows
        print("T4 PASS — index rebuilt from artifacts/receipts with ages and states preserved")

    print("carrier adoption drill: 4/4 passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
