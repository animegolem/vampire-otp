#!/usr/bin/env bash
# memory-log-inject.sh — re-entry context after a deliberate /clear.
#
# Wired as a SessionStart hook (matcher "clear"; the script also
# checks source itself). Injects two things as additionalContext:
# the newest session-handoff log (in-flight work state — the
# turn-log replaces the compaction SUMMARY, never the handoff), and
# the tail of the turn-log memory (`git log` one-liners from the
# memory repo, newest first). Older memory is deliberately not
# pushed: it is retrieved on demand (`git -C <memlog> log/show`) —
# memory as a place you go, not a thing pushed at you.
#
# Usage (hook command):
#   memory-log-inject.sh <memlog-dir> [handoff-dir] [n-lines]
set -euo pipefail

MEMLOG="${1:?usage: memory-log-inject.sh <memlog-dir> [handoff-dir] [n]}"
HANDOFF_DIR="${2:-}"
N="${3:-40}"

payload="$(cat)"
src="$(printf '%s' "$payload" | jq -r '.source // empty')"
[ "$src" = "clear" ] || exit 0

ctx=""
if [ -n "$HANDOFF_DIR" ] && [ -d "$HANDOFF_DIR" ]; then
  latest="$(ls -t "$HANDOFF_DIR"/*.md 2>/dev/null | head -1 || true)"
  if [ -n "$latest" ]; then
    ctx="## Latest session handoff — $(basename "$latest")

$(cat "$latest")

"
  fi
fi

if [ -d "$MEMLOG/.git" ]; then
  log="$(git -C "$MEMLOG" log --format='%ad  %s' \
    --date=format:'%Y-%m-%d %H:%M' -n "$N" 2>/dev/null || true)"
  if [ -n "$log" ]; then
    ctx="${ctx}## Turn-log memory (newest first, last $N exchanges)

Each line is one exchange; the verbatim record is that commit's
diff in $MEMLOG (git log / git show).

$log"
  fi
fi

[ -n "$ctx" ] || exit 0
jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
