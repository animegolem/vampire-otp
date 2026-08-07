#!/usr/bin/env bash
# memory-log-commit.sh — turn-log memory: one git commit per exchange.
#
# Wired as a Stop hook (async). Each time the assistant finishes a
# turn, the session transcript (append-only jsonl) is copied into a
# dedicated memory repo and committed; the commit message is ONE
# sentence, written by a small model, focused on what the user said.
# Because the transcript is append-only, each commit's DIFF is the
# verbatim exchange: `git log --oneline` is the index, `git show`
# is total recall. This replaces compaction — the loss is uniform
# and known (one line per exchange) instead of invisible, and
# everything is timestamped, attributed, and inspectable.
#
# Notification-only turns (background task events, local commands)
# earn no line: the copy is refreshed but not committed, so their
# content rides silently into the next real commit's diff.
#
# BELL_GUARD: the summarizer runs `claude -p`, which executes the
# user's global hooks in its own session; the guard makes bell/watch
# dispatchers exit instead of reacting to the summarizer itself.
#
# Usage (hook command): memory-log-commit.sh <memlog-dir>
# Env: MEMLOG_MODEL (default haiku).
set -euo pipefail

MEMLOG="${1:?usage: memory-log-commit.sh <memlog-dir>}"
MODEL="${MEMLOG_MODEL:-haiku}"

payload="$(cat)"
tp="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
[ -n "$tp" ] && [ -f "$tp" ] && [ -n "$sid" ] || exit 0

mkdir -p "$MEMLOG"
cd "$MEMLOG"
[ -d .git ] || git init -q

dest="session-${sid}.jsonl"
if [ -f "$dest" ] && cmp -s "$tp" "$dest"; then
  exit 0
fi
old_lines=0
[ -f "$dest" ] && old_lines="$(wc -l < "$dest" | tr -d ' ')"
cp "$tp" "$dest"

# The delta since the last committed copy is what we summarize.
tail_json="$(tail -n +"$((old_lines + 1))" "$dest")"

extract_last() { # $1 = user|assistant
  printf '%s\n' "$tail_json" | jq -rs --arg role "$1" '
    [.[] | select(.type == $role)
         | .message.content
         | if type == "array"
           then (map(select(.type? == "text") | .text // empty) | join(" "))
           else tostring end
         | select(length > 0)] | last // empty' 2>/dev/null || true
}

user_text="$(extract_last user)"
case "$user_text" in
  "" | "[SYSTEM NOTIFICATION"* | "<task-notification>"* | \
  "<local-command"* | "<command-name>"* | "Caveat: the messages below"*)
    exit 0 ;;
esac

assistant_text="$(extract_last assistant)"
excerpt="USER: $(printf '%.2000s' "$user_text")

ASSISTANT: $(printf '%.1500s' "$assistant_text")"

line=""
if command -v claude >/dev/null 2>&1; then
  line="$( { printf '%s\n\n%s' \
      'Summarize this exchange as ONE past-tense sentence for a memory log (aim under 120 characters). Lead with what the USER said, asked, or decided. Output only the sentence - no quotes, no preamble.' \
      "$excerpt"; } \
    | BELL_GUARD=1 claude -p --model "$MODEL" 2>/dev/null \
    | head -1 | tr -d '\n')" || true
fi
[ -n "$line" ] || line="$(printf '%.100s' "$user_text" | tr '\n' ' ')"

git add -A
git commit -qm "$line" || true
