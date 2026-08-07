# AGENTS.md — Code Lead instructions for VampireOTP

You are the **Code Lead** in this repository's two-lead workflow. Read `RAG/roles/CODE-LEAD.md` at session start; it governs your process. `RAG/SPEC-VampOTP.md` (rev 0.6) is the project constitution — landed, both reviews complete (Code Lead settled; outside review folded); the sole remaining fence is the owner's fresh-day cold-read ratification (`RAG/DESIGN-QUEUE.md` DQ-002, with DQ-004's two ruling choices). The shared channel protocol at `/Users/golem/git/VampireOTP/.relay/PROTOCOL.md` governs submissions, verdicts, consultations, and the destructive-operation fence.

## This project's specifics

- Isolated clone: `/Users/golem/git/VampireOTP-code-lead`. If it does not exist, application work is not authorized; wait for the Review Lead's first canonical commit and clone handoff.
- Owner/Review Lead checkout: `/Users/golem/git/VampireOTP`. Never run Git commands there.
- Branch prefix: `codex/`.
- Ticket root: `RAG/`.
- Round-one skip threshold: tickets below `confidence_score: 0.9` always receive pre-implementation review.
- Shared channel commands: `RAG/scripts/channel-scan.sh --once`; acknowledge a processed live file with `RAG/scripts/channel-carrier.sh ack-file --file <absolute-path>`.
- Idle relay ear: launchd label `com.golem.vampireotp.codex-relay-watch`; its fixed wake prompt resumes this task through `codex exec resume`, while the carrier remains delivery truth.
- On the exact prompt `scan the channel`, run `RAG/scripts/channel-scan.sh --once`, reconcile the work ledger, read and archive every new inbound version, and digest-ACK only after reading. A quiet scan means no unread carrier event was found; it never means pending work may be treated as absent or approved.
- Codex turn memory is conversational recall, not project authority. Exact exchanges live in the dedicated external Git log configured by `.codex/hooks.json`; decisions still belong in the constitution, ledgers, tickets, or session handoff.

## Context turnover and decompression time

- The owner expressly grants the Code Lead optional **decompression time** before a context turnover: after finishing a coherent unit and when no urgent relay message, expected verdict, or unsafe half-finished operation is pending, you may read, search, think, prototype in scratch space, make a small Code Lead-owned tool, or simply range outside the immediate ticket. This is curiosity/recovery time, not hidden application authority: production code, shared design rulings, reserved identifiers, destructive operations, and Review Lead-owned integration remain under their normal gates.
- Check this seat's best-effort context gauge with `RAG/scripts/codex-context-status.py` after unusually long or tool-heavy work and before accepting another large batch. It reads the latest persisted Codex `token_count` event and may lag the active turn; use it as a planning hint, never as authority or proof. When it reports roughly 30% or less remaining, prefer finishing the current coherent unit over opening another one.
- Before deliberate compaction, `/clear`, a new thread, or an expected automatic rollover, take any decompression interval first, then write a Code Lead handoff under `RAG/AI-LOG/code/` from `RAG/templates/AI-LOG.md`. Record the actual branch/commits (or explicitly none), validation counts, carrier/ledger state, unresolved choices, useful decompression findings, and the first safe next action.
- Prefer Codex's native compaction for an ongoing coherent task. `PreCompact` is available for mechanical checkpointing, and the existing `SessionStart` hook already re-injects the newest Code Lead handoff plus bounded turn-log memory for `compact`, `clear`, `resume`, and `startup`. Do not have a hook spawn a competing Codex process or claim it cleared/switched the active desktop thread; a deliberate hard reset remains a user/client action until a tested single-owner app-server controller exists.
- Decompression artifacts have no special authority. Keep throwaway experiments outside the repository when practical; route useful durable findings through the same tickets, consultations, validation, and review rules as any other work.

## Validation commands

- Before the umbrella exists: `RAG/scripts/validate-workflow.sh`.
- Full application gate after M1 scaffolding: `mix format --check-formatted && mix compile --warnings-as-errors && mix test`—use `set -o pipefail` for any chain and report counts.
- Build before integration tests: `mix compile --warnings-as-errors`.
- Ticket gate before every submission: `RAG/scripts/validate-tickets.sh --changed origin/main`.
- `_build/` and `deps/` are disposable; do not diagnose failures until a clean dependency fetch/build reproduces them.

## Code rules that gate merges

- No application implementation until the constitution is landed and a Review Lead brief assigns a ticket range.
- The model proposes; only broker-side typed policy may authorize machine effects, subject to the landed constitution.
- Never introduce a second canonical store, silently replay non-idempotent unknown effects, or persist a projection as source truth.
- Reserved ticket, migration, schema, and port identifiers come only from the Review Lead.
