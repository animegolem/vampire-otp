#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TICKETS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$TICKETS_DIR/.." && pwd)"
errors=0

required=(
  "AGENTS.md"
  "CLAUDE.md"
  "RAG/README.md"
  "RAG/DESIGN-QUEUE.md"
  "RAG/HUMAN-TESTING.md"
  "RAG/INDEX.md"
  "RAG/roles/CODE-LEAD.md"
  "RAG/roles/REVIEW-LEAD.md"
  "RAG/scripts/codex-memory.py"
  "RAG/scripts/codex-relay-wake.py"
  "RAG/scripts/test-codex-runtime.py"
  "RAG/templates/CODEX-HOOKS.json"
  "RAG/templates/CODEX-RELAY-WAKE.plist"
  ".relay/PROTOCOL.md"
)

for path in "${required[@]}"; do
  if [[ ! -f "$ROOT_DIR/$path" ]]; then
    echo "$path: ERROR required workflow file missing"
    errors=$((errors + 1))
  fi
done

for directory in RAG/AI-EPIC RAG/AI-IMP RAG/AI-LOG RAG/BRIEFS \
                 .relay/inbox .relay/outbox .relay/archive; do
  if [[ ! -d "$ROOT_DIR/$directory" ]]; then
    echo "$directory: ERROR required workflow directory missing"
    errors=$((errors + 1))
  fi
done

for file in "$ROOT_DIR/AGENTS.md" "$ROOT_DIR/CLAUDE.md" \
            "$ROOT_DIR/.relay/PROTOCOL.md"; do
  if [[ -f "$file" ]] && rg -q '\{\{[^}]+\}\}' "$file"; then
    echo "${file#"$ROOT_DIR"/}: ERROR unfilled template placeholder"
    errors=$((errors + 1))
  fi
done

if ! git -C "$ROOT_DIR" check-ignore -q .relay/PROTOCOL.md; then
  echo ".gitignore: ERROR .relay/ is not ignored"
  errors=$((errors + 1))
fi
if ! git -C "$ROOT_DIR" check-ignore -q standup/soul-note-to-the-next-fable.md; then
  echo ".gitignore: ERROR standup/ private handoff is not ignored"
  errors=$((errors + 1))
fi

bash -n "$SCRIPT_DIR/approve-loc-review.sh" \
        "$SCRIPT_DIR/channel-carrier.sh" \
        "$SCRIPT_DIR/channel-scan.sh" \
        "$SCRIPT_DIR/codex-relay-watch.sh" \
        "$SCRIPT_DIR/generate-index.sh" \
        "$SCRIPT_DIR/memory-log-commit.sh" \
        "$SCRIPT_DIR/memory-log-inject.sh" \
        "$SCRIPT_DIR/test-codex-relay-watch.sh" \
        "$SCRIPT_DIR/validate-tickets.sh" \
        "$SCRIPT_DIR/validate-workflow.sh"
python3 -c "from pathlib import Path; [compile(path.read_text(encoding='utf-8'), str(path), 'exec') for path in [Path('$SCRIPT_DIR/carrier.py'), Path('$SCRIPT_DIR/carrier-receiver.py'), Path('$SCRIPT_DIR/codex-memory.py'), Path('$SCRIPT_DIR/codex-relay-wake.py'), Path('$SCRIPT_DIR/test-carrier-adoption.py'), Path('$SCRIPT_DIR/test-codex-runtime.py'), Path('$SCRIPT_DIR/validate-work-ledger.py')]]"

"$SCRIPT_DIR/validate-tickets.sh"

if [[ ! -f "$ROOT_DIR/RAG/SPEC-0001.md" ]]; then
  echo "SPEC-0001.md: NOTICE Review Lead/owner landing remains an implementation fence"
fi

if git -C "$ROOT_DIR" rev-parse --verify --quiet HEAD >/dev/null; then
  if [[ ! -d /Users/golem/git/VampireOTP-code-lead/.git ]]; then
    echo "Code Lead clone: ERROR canonical history exists but isolated clone is missing"
    errors=$((errors + 1))
  fi
else
  echo "Code Lead clone: NOTICE deferred until the first canonical commit"
fi

echo "----"
echo "validate-workflow: $errors error(s)"
[[ $errors -gt 0 ]] && exit 2
exit 0
