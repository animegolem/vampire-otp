#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$(mktemp -d -t vampireotp-codex-watch.XXXXXX)"
WATCH_PID=""

cleanup() {
  if [[ -n "$WATCH_PID" ]] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  find "$FIXTURE" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.relay/outbox" "$FIXTURE/.relay/state" \
         "$FIXTURE/RAG/scripts" "$FIXTURE/bin"

carrier_stub="$FIXTURE/RAG/scripts/channel-carrier.sh"
codex_stub="$FIXTURE/bin/codex"

printf '%s\n' '#!/bin/bash' 'echo "sync: test"' > "$carrier_stub"
printf '%s\n' '#!/bin/bash' \
  'printf "%s\n" "$@" > "$VAMPIREOTP_OWNER_REPO/.relay/state/fake-codex.argv"' \
  > "$codex_stub"
chmod +x "$carrier_stub" "$codex_stub"

watch_env=(
  "VAMPIREOTP_OWNER_REPO=$FIXTURE"
  "CODEX_RELAY_CODEX_BIN=$codex_stub"
  "CODEX_RELAY_THREAD_ID=thread-test"
  "CODEX_RELAY_POLL_SECONDS=1"
  "CODEX_RELAY_RETRY_SECONDS=1"
)

env "${watch_env[@]}" "$SCRIPT_DIR/codex-relay-watch.sh" --baseline >/dev/null
env "${watch_env[@]}" "$SCRIPT_DIR/codex-relay-watch.sh" --watch \
  >"$FIXTURE/watch.out" 2>"$FIXTURE/watch.err" &
WATCH_PID=$!

sleep 2
printf '%s\n' 'settled relay payload' > "$FIXTURE/.relay/outbox/test.md"

for _ in {1..12}; do
  [[ -f "$FIXTURE/.relay/state/fake-codex.argv" ]] && break
  sleep 1
done

argv="$FIXTURE/.relay/state/fake-codex.argv"
[[ -f "$argv" ]] || {
  echo "watcher test: FAIL — no Codex wake" >&2
  exit 1
}
arg_one="$(sed -n '1p' "$argv")"
arg_two="$(sed -n '2p' "$argv")"
arg_three="$(sed -n '3p' "$argv")"
arg_four="$(sed -n '4p' "$argv")"
[[ "$arg_one" == "exec" && "$arg_two" == "resume" && \
   "$arg_three" == "thread-test" && "$arg_four" == "scan the channel" ]] || {
  echo "watcher test: FAIL — wrong Codex invocation" >&2
  sed -n '1,8p' "$argv" >&2
  exit 1
}
[[ "$(wc -l < "$argv" | tr -d ' ')" == "4" ]] || {
  echo "watcher test: FAIL — unexpected wake arguments" >&2
  sed -n '1,8p' "$argv" >&2
  exit 1
}
[[ ! -f "$FIXTURE/.relay/state/codex-relay-watch/pending-wake" ]] || {
  echo "watcher test: FAIL — successful wake left pending marker" >&2
  exit 1
}

echo "watcher test: PASS — settled change invoked exact thread once"
