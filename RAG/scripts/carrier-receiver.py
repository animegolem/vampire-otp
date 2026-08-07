#!/usr/bin/env python3
"""Phase-C carrier -> Codex receiver.

This is tooling only. It contains no installer and never starts a managed
app-server daemon. Each delivery attempt owns one bounded stdio app-server
process. Application ACK remains exclusively the recipient agent's ack-file
ritual; this worker records transport/history facts but never ACKs an event.
"""

from __future__ import annotations

import argparse
from collections import deque
import json
import os
import queue
import random
import shlex
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import carrier as core
from validate_work_ledger import validate_ledger

WORKER_VERSION = "phase-c-r1"
DEFAULT_APP_SERVER = "codex app-server --listen stdio://"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _state_path(repo: Path, recipient: str) -> Path:
    ns = core.namespace_of(repo)
    key = core.hashlib.sha256(ns.encode()).hexdigest()[:16]
    return core.DB_DIR / "receiver" / key / f"{recipient}.json"


def _load_state(repo: Path, recipient: str) -> dict:
    path = _state_path(repo, recipient)
    if path.exists():
        try:
            return json.loads(path.read_text())
        except ValueError:
            core.die(f"corrupt receiver state {path}")
    return {
        "recipient": recipient,
        "namespace": core.namespace_of(repo),
        "worker_version": WORKER_VERSION,
        "detector": {"heartbeat": None, "last_error": None},
        "worker": {"heartbeat": None, "last_error": None, "retry_at": None},
        "target": None,
        "target_version": None,
        "liveness": {"fable_to_codex": 2, "codex_to_fable": 1},
        "ear_cadence_minutes": {
            "fable_to_codex": 5, "codex_to_fable": 60,
        },
        "delivery_degraded_after_minutes": {
            "fable_to_codex": 15, "codex_to_fable": 120,
        },
        "last_human_notice": None,
    }


def _save_state(repo: Path, recipient: str, state: dict) -> None:
    state["updated_at"] = utc_now()
    core.atomic_write(
        _state_path(repo, recipient),
        json.dumps(state, indent=2, sort_keys=True).encode())


def _touch_role(repo: Path, recipient: str, role: str,
                error: str | None = None, retry_at: str | None = None,
                target: str | None = None,
                target_version: str | None = None) -> None:
    state = _load_state(repo, recipient)
    state[role]["heartbeat"] = utc_now()
    state[role]["last_error"] = error
    if role == "worker":
        state[role]["retry_at"] = retry_at
    if target is not None:
        state["target"] = target
    if target_version is not None:
        state["target_version"] = target_version
    _save_state(repo, recipient, state)


def _carrier(repo: Path, *args: str, check: bool = True) -> dict | str:
    command = [
        sys.executable, str(Path(core.__file__).resolve()), *args,
        "--repo", str(repo),
    ]
    result = subprocess.run(
        command, text=True, capture_output=True, env=os.environ.copy())
    if check and result.returncode:
        raise RuntimeError(
            result.stderr.strip() or result.stdout.strip()
            or f"carrier exited {result.returncode}")
    output = result.stdout.strip()
    try:
        return json.loads(output)
    except ValueError:
        return output


class AppServerClient:
    def __init__(self, command: str, timeout: float,
                 heartbeat=None):
        self.command = shlex.split(command)
        self.timeout = timeout
        self.heartbeat = heartbeat
        self.process: subprocess.Popen | None = None
        self.lines: queue.Queue = queue.Queue()
        self.reader: threading.Thread | None = None
        self.stderr_lines = deque(maxlen=200)
        self.stderr_reader: threading.Thread | None = None
        self.next_id = 1
        self.notifications: list[dict] = []
        self._last_heartbeat = time.monotonic()

    def __enter__(self):
        self.process = subprocess.Popen(
            self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        assert self.process.stdout is not None
        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()
        self.stderr_reader = threading.Thread(
            target=self._read_stderr, daemon=True)
        self.stderr_reader.start()
        return self

    def __exit__(self, _type, _value, _traceback):
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)

    def _read_stdout(self) -> None:
        assert self.process is not None and self.process.stdout is not None
        for line in self.process.stdout:
            try:
                self.lines.put(json.loads(line))
            except ValueError:
                self.lines.put(RuntimeError(
                    f"invalid app-server JSON: {line!r}"))

    def _read_stderr(self) -> None:
        assert self.process is not None and self.process.stderr is not None
        for line in self.process.stderr:
            self.stderr_lines.append(line.rstrip())

    def _send(self, body: dict) -> None:
        assert self.process is not None and self.process.stdin is not None
        self.process.stdin.write(json.dumps(body, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def notify(self, method: str, params: dict) -> None:
        self._send({"method": method, "params": params})

    def _pulse(self) -> None:
        if self.heartbeat and time.monotonic() - self._last_heartbeat >= 25:
            self.heartbeat()
            self._last_heartbeat = time.monotonic()

    def _line(self, deadline: float) -> dict:
        assert self.process is not None
        while time.monotonic() < deadline:
            self._pulse()
            try:
                message = self.lines.get(
                    timeout=min(1.0, max(0, deadline - time.monotonic())))
                if isinstance(message, Exception):
                    raise message
                return message
            except queue.Empty:
                pass
            if self.process.poll() is not None and self.lines.empty():
                stderr = "\n".join(self.stderr_lines)
                raise RuntimeError(
                    f"app-server exited {self.process.returncode}: {stderr}")
        raise TimeoutError("app-server response bound exceeded")

    def request(self, method: str, params: dict,
                timeout: float | None = None) -> dict:
        request_id = self.next_id
        self.next_id += 1
        self._send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + (timeout or self.timeout)
        while True:
            message = self._line(deadline)
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(
                        f"{method} refused: {message['error']}")
                return message.get("result", {})
            if "method" in message:
                self.notifications.append(message)

    def next_notification(self, deadline: float) -> dict:
        if self.notifications:
            return self.notifications.pop(0)
        while True:
            message = self._line(deadline)
            if "method" in message:
                return message


def _thread_from(result: dict) -> dict:
    return result.get("thread", result)


def _find_delivery_turn(thread: dict, key: str) -> dict | None:
    marker = f"[carrier-delivery-key: {key}]"
    for turn in thread.get("turns", []):
        if marker in json.dumps(turn, sort_keys=True):
            return turn
    return None


def _prompt(confirmed: dict) -> str:
    lines = [
        f"[carrier-delivery-key: {confirmed['delivery_key']}]",
        "Durable carrier delivery. A wake is only a hint; process the exact "
        "artifact(s), reconcile the live channel, update WORK-LEDGER when the "
        "message creates work, then application-ACK with ack-file. This worker "
        "does not ACK for you.",
    ]
    for event in confirmed["events"]:
        lines.extend([
            "",
            f"## {event['classification']} carrier event",
            f"- event: {event['event_id']}",
            f"- digest: {event['digest']}",
            f"- round: {event['round']}",
            f"- artifact: {event['artifact_path']}",
            "",
            event["payload"],
        ])
    return "\n".join(lines)


def _fault(name: str) -> None:
    if os.environ.get("CARRIER_RECEIVER_FAULT_AT") == name:
        os._exit(97)


def _initialize(client: AppServerClient) -> None:
    client.request("initialize", {
        "clientInfo": {"name": "carrier-receiver", "version": WORKER_VERSION},
        "capabilities": {"experimentalApi": True},
    })
    client.notify("initialized", {})


def _verify_history(client: AppServerClient, target: str, key: str,
                    expected_turn_id: str | None = None) -> dict | None:
    result = client.request(
        "thread/read", {"threadId": target, "includeTurns": True})
    thread = _thread_from(result)
    if thread.get("id") != target:
        raise RuntimeError(
            f"wrong target in history response: {thread.get('id')!r}")
    turn = _find_delivery_turn(thread, key)
    if turn and expected_turn_id and turn.get("id") != expected_turn_id:
        raise RuntimeError(
            f"delivery key bound to wrong turn {turn.get('id')}")
    if turn and turn.get("status") == "completed":
        return turn
    return None


def deliver_once(repo: Path, recipient: str, direction: str, owner: str,
                 target: str, target_version: str, app_server_cmd: str,
                 timeout: float, retry_seconds: int) -> dict:
    _fault("before_claim")
    claim = _carrier(
        repo, "claim", "--recipient", recipient, "--direction", direction,
        "--owner", owner, "--lease-seconds", str(max(30, int(timeout) + 30)))
    if not isinstance(claim, dict) or not claim.get("claimed"):
        _touch_role(repo, recipient, "worker", target=target,
                    target_version=target_version)
        return {"worked": False, "reason": "no eligible event"}
    token = claim["claim_token"]
    _fault("after_claim")

    def renew():
        _carrier(
            repo, "renew", "--claim-token", token,
            "--lease-seconds", str(max(30, int(timeout) + 30)))
        _touch_role(repo, recipient, "worker", target=target,
                    target_version=target_version)

    try:
        with AppServerClient(app_server_cmd, timeout, heartbeat=renew) as client:
            _initialize(client)
            resumed = client.request("thread/resume", {"threadId": target})
            thread = _thread_from(resumed)
            if thread.get("id") != target:
                raise RuntimeError(
                    f"wrong target on resume: {thread.get('id')!r}")

            existing = _find_delivery_turn(thread, claim["delivery_key"])
            if existing and existing.get("status") == "completed":
                _carrier(
                    repo, "completed", "--claim-token", token,
                    "--target", target, "--target-version", target_version,
                    "--turn-id", existing["id"])
                _touch_role(repo, recipient, "worker", target=target,
                            target_version=target_version)
                return {
                    "worked": True, "recovered_from_history": True,
                    "delivery_key": claim["delivery_key"],
                    "turn_id": existing["id"],
                }
            if existing and existing.get("status") == "inProgress":
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    completed = _verify_history(
                        client, target, claim["delivery_key"],
                        existing.get("id"))
                    if completed:
                        _carrier(
                            repo, "completed", "--claim-token", token,
                            "--target", target,
                            "--target-version", target_version,
                            "--turn-id", completed["id"])
                        return {
                            "worked": True, "recovered_from_history": True,
                            "delivery_key": claim["delivery_key"],
                            "turn_id": completed["id"],
                        }
                    time.sleep(0.25)
                raise TimeoutError("existing delivery turn stayed in progress")

            confirmed = _carrier(
                repo, "confirm", "--claim-token", token)
            if not isinstance(confirmed, dict):
                raise RuntimeError("carrier confirm returned invalid output")
            _fault("before_turn_start")
            response = client.request("turn/start", {
                "threadId": target,
                "input": [{"type": "text", "text": _prompt(confirmed)}],
                "clientUserMessageId": claim["delivery_key"],
            })
            turn = response.get("turn", response)
            turn_id = turn.get("id")
            if not turn_id:
                raise RuntimeError("turn/start response omitted turn id")
            _fault("after_turn_acceptance")
            _carrier(
                repo, "accepted", "--claim-token", token,
                "--target", target, "--target-version", target_version,
                "--turn-id", turn_id)
            _fault("after_accept_record")

            saw_item = False
            saw_idle = False
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline and not (saw_item and saw_idle):
                notification = client.next_notification(deadline)
                method = notification.get("method")
                params = notification.get("params", {})
                if (method == "item/completed"
                        and params.get("threadId") == target
                        and params.get("turnId") == turn_id):
                    saw_item = True
                elif (method == "thread/status/changed"
                      and params.get("threadId") == target
                      and params.get("status", {}).get("type") == "idle"):
                    saw_idle = True
            if not saw_item or not saw_idle:
                raise TimeoutError(
                    f"completion oracle incomplete: item={saw_item} "
                    f"idle={saw_idle}")
            completed = _verify_history(
                client, target, claim["delivery_key"], turn_id)
            if not completed:
                raise RuntimeError(
                    "item+idle observed but exact delivery absent from "
                    "completed history")
            _carrier(
                repo, "completed", "--claim-token", token,
                "--target", target, "--target-version", target_version,
                "--turn-id", turn_id)
            _touch_role(repo, recipient, "worker", target=target,
                        target_version=target_version)
            return {
                "worked": True, "recovered_from_history": False,
                "delivery_key": claim["delivery_key"], "turn_id": turn_id,
                "saw_item_completed": saw_item, "saw_idle": saw_idle,
            }
    except BaseException as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        error = f"{type(exc).__name__}: {exc}"
        try:
            failed = _carrier(
                repo, "fail", "--claim-token", token, "--error", error,
                "--retry-seconds", str(retry_seconds))
            retry_at = failed.get("retry_at") if isinstance(failed, dict) else None
        except Exception as fail_exc:
            error += f"; fail-recording-error: {fail_exc}"
            retry_at = None
        _touch_role(repo, recipient, "worker", error=error,
                    retry_at=retry_at, target=target,
                    target_version=target_version)
        raise


def detect_once(repo: Path, recipient: str) -> dict:
    try:
        result = _carrier(repo, "sync")
        _touch_role(repo, recipient, "detector")
        return {"detected": True, "carrier": result}
    except Exception as exc:
        _touch_role(repo, recipient, "detector", error=str(exc))
        raise


def _age(ts: str | None, instant: datetime) -> float | None:
    if not ts:
        return None
    return max(0, (instant - datetime.fromisoformat(ts)).total_seconds())


def status(repo: Path, recipient: str, direction: str,
           ledger: Path | None, detector_cadence: int,
           worker_cadence: int) -> dict:
    instant = datetime.now(timezone.utc)
    state = _load_state(repo, recipient)
    delivery = core.delivery_status(repo, recipient, direction)
    work = validate_ledger(ledger, instant) if ledger else None
    detector_age = _age(state["detector"].get("heartbeat"), instant)
    worker_age = _age(state["worker"].get("heartbeat"), instant)
    heartbeats = {
        "detector": {
            **state["detector"], "age_seconds": detector_age,
            "healthy": detector_age is not None
            and detector_age <= 2 * detector_cadence,
        },
        "worker": {
            **state["worker"], "age_seconds": worker_age,
            "healthy": worker_age is not None
            and worker_age <= 2 * worker_cadence,
        },
    }
    oldest_age = _age(delivery["oldest_pending_ts"], instant)
    lane = "fable_to_codex" if direction == "outbox" else "codex_to_fable"
    delivery_threshold = (
        state["delivery_degraded_after_minutes"][lane] * 60)
    delivery_degraded = (
        oldest_age is not None and oldest_age > delivery_threshold)
    work_degraded = bool(
        work and (work["errors"] or work["warnings"]))
    heartbeat_degraded = not all(v["healthy"] for v in heartbeats.values())
    degraded = delivery_degraded or work_degraded or heartbeat_degraded
    return {
        "delivery_truth": {
            **delivery,
            "oldest_pending_age_seconds": oldest_age,
            "declared_ear_cadence_minutes":
                state["ear_cadence_minutes"][lane],
            "degraded_after_minutes":
                state["delivery_degraded_after_minutes"][lane],
            "degraded": delivery_degraded,
        },
        "work_disposition_scheduling_truth": work,
        "executor_task_lease": [
            {"work": row["work"], "task_id": row["task_id"],
             "lease": row["executor_lease"],
             "progress_at": row["progress_at"],
             "progress_age_seconds": row["progress_age_seconds"]}
            for row in (work["rows"] if work else [])
            if row["state"] == "started"
        ],
        "heartbeats": heartbeats,
        "target": {
            "id": state.get("target"),
            "version": state.get("target_version"),
        },
        "liveness_ladder": state["liveness"],
        "retry_error": state["worker"],
        "degraded": degraded,
        "degraded_before_human_notice": (
            degraded and state.get("last_human_notice") is None),
    }


def _common(parser):
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--recipient", default="codex")


def _work_options(parser):
    parser.add_argument("--direction", default="outbox",
                        choices=["inbox", "outbox"])
    parser.add_argument("--owner", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--target-version", required=True)
    parser.add_argument("--app-server-cmd", default=DEFAULT_APP_SERVER)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--retry-seconds", type=int, default=15)


def main() -> None:
    parser = argparse.ArgumentParser(prog="carrier-receiver")
    sub = parser.add_subparsers(dest="command", required=True)

    detect = sub.add_parser("detect-once")
    _common(detect)

    work = sub.add_parser("work-once")
    _common(work)
    _work_options(work)

    run_detector = sub.add_parser("run-detector")
    _common(run_detector)
    run_detector.add_argument("--poll-seconds", type=float, default=15)

    run_worker = sub.add_parser("run-worker")
    _common(run_worker)
    _work_options(run_worker)
    run_worker.add_argument("--idle-poll-seconds", type=float, default=5)
    run_worker.add_argument("--max-backoff-seconds", type=float, default=300)

    show = sub.add_parser("status")
    _common(show)
    show.add_argument("--direction", default="outbox",
                      choices=["inbox", "outbox"])
    show.add_argument("--work-ledger", type=Path)
    show.add_argument("--detector-cadence", type=int, default=15)
    show.add_argument("--worker-cadence", type=int, default=5)
    show.add_argument("--json", action="store_true")

    args = parser.parse_args()
    if args.command == "detect-once":
        result = detect_once(args.repo, args.recipient)
    elif args.command == "work-once":
        result = deliver_once(
            args.repo, args.recipient, args.direction, args.owner,
            args.target, args.target_version, args.app_server_cmd,
            args.timeout, args.retry_seconds)
    elif args.command == "run-detector":
        if args.poll_seconds <= 0:
            core.die("poll-seconds must be positive")
        while True:
            try:
                detect_once(args.repo, args.recipient)
            except Exception:
                pass
            time.sleep(args.poll_seconds)
    elif args.command == "run-worker":
        if args.idle_poll_seconds <= 0 or args.max_backoff_seconds <= 0:
            core.die("worker polling/backoff values must be positive")
        backoff = args.idle_poll_seconds
        while True:
            try:
                outcome = deliver_once(
                    args.repo, args.recipient, args.direction, args.owner,
                    args.target, args.target_version, args.app_server_cmd,
                    args.timeout, args.retry_seconds)
                backoff = args.idle_poll_seconds
                time.sleep(0 if outcome.get("worked") else
                           args.idle_poll_seconds)
            except Exception:
                time.sleep(backoff + random.uniform(
                    0, min(1.0, backoff * 0.1)))
                backoff = min(args.max_backoff_seconds, backoff * 2)
    else:
        result = status(
            args.repo, args.recipient, args.direction, args.work_ledger,
            args.detector_cadence, args.worker_cadence)
    print(json.dumps(result, indent=2, sort_keys=True))
    if args.command == "status" and result["degraded"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
