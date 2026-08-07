#!/bin/bash

set -euo pipefail
umask 077

OWNER_REPO="${VAMPIREOTP_OWNER_REPO:-/Users/golem/git/VampireOTP}"
CHANNEL_DIR="$OWNER_REPO/.relay"
STATE_DIR="$CHANNEL_DIR/state/codex-relay-watch"
CARRIER="$OWNER_REPO/RAG/scripts/channel-carrier.sh"
CODEX_BIN="${CODEX_RELAY_CODEX_BIN:-/opt/homebrew/bin/codex}"
THREAD_ID="${CODEX_RELAY_THREAD_ID:-}"
POLL_SECONDS="${CODEX_RELAY_POLL_SECONDS:-5}"
RETRY_SECONDS="${CODEX_RELAY_RETRY_SECONDS:-15}"
MODE="${1:---watch}"

case "$MODE" in
  --watch|--baseline|--probe) ;;
  *) echo "usage: $0 [--watch|--baseline|--probe]" >&2; exit 2 ;;
esac

for value in "$POLL_SECONDS" "$RETRY_SECONDS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "poll and retry intervals must be positive integers" >&2
    exit 2
  }
done

[[ -d "$CHANNEL_DIR/outbox" ]] || {
  echo "missing relay outbox: $CHANNEL_DIR/outbox" >&2
  exit 2
}
[[ -x "$CARRIER" ]] || {
  echo "missing carrier wrapper: $CARRIER" >&2
  exit 2
}
[[ -x "$CODEX_BIN" ]] || {
  echo "missing Codex CLI: $CODEX_BIN" >&2
  exit 2
}

mkdir -p "$STATE_DIR"
BASELINE="$STATE_DIR/fingerprint.tsv"
PENDING="$STATE_DIR/pending-wake"
LOCK="$STATE_DIR/lock"

fingerprint() {
  {
    find "$CHANNEL_DIR/outbox" -type f -name '*.md' ! -name '*.tmp' -print
    for extra in "$CHANNEL_DIR/triage-report.md" \
                 "$CHANNEL_DIR/PROCESS-LAB.md" \
                 "$CHANNEL_DIR/ISSUES.md" \
                 "$CHANNEL_DIR/OBSERVATIONS.md"; do
      if [[ -f "$extra" ]]; then
        printf '%s\n' "$extra"
      fi
    done
  } | LC_ALL=C sort | while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    relative="${path#"$CHANNEL_DIR"/}"
    digest="$(shasum -a 256 "$path" | awk '{print $1}')"
    printf '%s\t%s\n' "$relative" "$digest"
  done
}

stable_sample() {
  local destination="$1"
  local first second
  first="$(mktemp "$STATE_DIR/sample.XXXXXX")"
  second="$(mktemp "$STATE_DIR/sample.XXXXXX")"
  while true; do
    fingerprint > "$first"
    sleep "$POLL_SECONDS"
    fingerprint > "$second"
    if cmp -s "$first" "$second"; then
      mv "$second" "$destination"
      rm -f "$first"
      return
    fi
  done
}

mark_pending() {
  local sample="$1"
  local digest temporary
  digest="$(shasum -a 256 "$sample" | awk '{print $1}')"
  temporary="$(mktemp "$STATE_DIR/pending.XXXXXX")"
  printf '%s\n' "$digest" > "$temporary"
  mv "$temporary" "$PENDING"
}

wake_codex() {
  [[ -n "$THREAD_ID" ]] || {
    echo "CODEX_RELAY_THREAD_ID is required for delivery" >&2
    return 2
  }

  "$CARRIER" sync
  "$CODEX_BIN" exec resume "$THREAD_ID" "scan the channel"
}

if [[ "$MODE" == "--probe" ]]; then
  probe="$(mktemp "$STATE_DIR/probe.XXXXXX")"
  fingerprint > "$probe"
  echo "thread: ${THREAD_ID:-unset}"
  echo "codex: $CODEX_BIN"
  echo "current: $(shasum -a 256 "$probe" | awk '{print $1}')"
  if [[ -f "$BASELINE" ]]; then
    echo "baseline: $(shasum -a 256 "$BASELINE" | awk '{print $1}')"
  else
    echo "baseline: unset"
  fi
  [[ -f "$PENDING" ]] && echo "pending wake: $(<"$PENDING")" || echo "pending wake: none"
  rm -f "$probe"
  exit 0
fi

initial="$(mktemp "$STATE_DIR/initial.XXXXXX")"
stable_sample "$initial"

if [[ "$MODE" == "--baseline" ]]; then
  mv "$initial" "$BASELINE"
  rm -f "$PENDING"
  echo "baseline installed: $(shasum -a 256 "$BASELINE" | awk '{print $1}')"
  exit 0
fi

if ! mkdir "$LOCK" 2>/dev/null; then
  echo "watcher already running: $LOCK" >&2
  rm -f "$initial"
  exit 3
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

if [[ ! -f "$BASELINE" ]]; then
  mv "$initial" "$BASELINE"
else
  if ! cmp -s "$initial" "$BASELINE"; then
    mv "$initial" "$BASELINE"
    mark_pending "$BASELINE"
  else
    rm -f "$initial"
  fi
fi

while true; do
  if [[ -f "$PENDING" ]]; then
    if wake_codex; then
      rm -f "$PENDING"
    else
      echo "Codex wake failed; retrying in ${RETRY_SECONDS}s" >&2
      sleep "$RETRY_SECONDS"
      continue
    fi
  fi

  candidate="$(mktemp "$STATE_DIR/candidate.XXXXXX")"
  fingerprint > "$candidate"
  if cmp -s "$candidate" "$BASELINE"; then
    rm -f "$candidate"
    sleep "$POLL_SECONDS"
    continue
  fi

  quiet="$(mktemp "$STATE_DIR/quiet.XXXXXX")"
  sleep "$POLL_SECONDS"
  fingerprint > "$quiet"
  if cmp -s "$candidate" "$quiet"; then
    mv "$quiet" "$BASELINE"
    mark_pending "$BASELINE"
  fi
  rm -f "$candidate" "$quiet"
done
