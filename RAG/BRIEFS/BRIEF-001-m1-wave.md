# Assignment: M1 wave 1 — AI-IMP-001 · 002 · 003 · 004 · 005 · 006 · 007

Review Lead → Code Lead, 2026-08-07. One sitting, 7 tickets, one
domain: the M1 heartbeat-and-court slice — umbrella, court,
artifacts, lifecycle, projections, scheduler shell, recovery
oracle (SPEC-VampOTP rev 0.7 §6.2, §8.2, Appendix A). Manage
your own subagents as you see fit; the protocol in
`.relay/PROTOCOL.md` governs (isolated clone, branch
`codex/m1-wave-1`, inbox submission, atomic commit per ticket,
destructive-op fence: you never delete worktrees/branches/refs —
the Review Lead owns cleanup).

## Round 1 is a PRE-IMPLEMENTATION REVIEW — no code

No rulings post-date these tickets — they were cut hours after
rev 0.7 was ratified and pushed (`8e4ec32`). Verify anyway: every
ticket claim against the ratified constitution (especially A.1–A.7
verbatim clauses), report corrections with citations, and propose
concrete choices where tickets delegate them (ULID library, cursor
storage, event-type names in 006 — distinctness is normative,
names are yours to propose). AI-IMP-001 is trivial and may skip to
build — say so in the round-1 submission.

## The tickets (in build order)

1. **RAG/AI-IMP/AI-IMP-001-umbrella-scaffold.md** — the five §6.1
   apps + gate green on skeleton. Builds first: everything else
   lives inside it.
2. **RAG/AI-IMP/AI-IMP-002-court-event-envelope.md** — A.1
   envelope, single writer, append-only enforced mechanically.
   The keystone; 003–006 all write through it.
3. **RAG/AI-IMP/AI-IMP-003-artifact-store.md** — durable
   publication + two-phase deletion + resolution states (A.4).
4. **RAG/AI-IMP/AI-IMP-004-lifecycle-boot-events.md** — boot,
   clean terminal, crash inference (A.2). May interleave with 003/005.
5. **RAG/AI-IMP/AI-IMP-005-projection-registry.md** — registry
   events + rebuildable `logs.txt` cursor projection (A.6).
6. **RAG/AI-IMP/AI-IMP-006-scheduler-shell.md** — admission
   authority shell + invariant-13 pause/stop transitions (§8.5 M1
   scope).
7. **RAG/AI-IMP/AI-IMP-007-recovery-oracle.md** — synthetic
   aggregate + child-kill + VM-SIGKILL harness against A.7
   verbatim. Closes the epic.

## Normative supplement (binding)

- **§6.1**: app names `court`, `runtime`, `scheduler`, `broker`,
  `driver` are constitutional — build all five even though
  `broker`/`driver` stay empty shells this wave.
- **A.1**: corrections are new events; committed rows are never
  mutated — enforcement must be mechanical (triggers + API shape),
  not convention. The `actor` sub-role convention
  `resident/<fork-label>` is reserved in 002 (DQ-007 consequence);
  document it, build nothing on it.
- **A.7/A.8**: the SIGKILL test adopts the oracle including the
  `deletion_pending` clause; "equals pre-kill state" is a rejected
  criterion — do not build it.
- **ecto-process-boundaries (settled consultation, now
  ticket-binding):** one Repo, under `court`; all appends through
  the single writer; typed APIs only across app boundaries; no
  cross-boundary bang-functions returning raw changesets.
- **15b (rev 0.7)** touches nothing in this wave — no affect
  machinery exists yet. If you find a seam that seems to want it,
  STOP and say so rather than building toward it.

## Fences

- Domain fence: umbrella code (`mix.exs`, `config/`, `apps/**`)
  and its tests; the seven assigned ticket files (checklists +
  Issues Encountered only).
- Do NOT touch: `RAG/SPEC-VampOTP.md`, `RAG/DESIGN-QUEUE.md`,
  `RAG/INDEX.md` (generated), `RAG/HUMAN-TESTING.md`, `care/**`,
  `RAG/AI-LOG/**`, role charters, this brief.
- Reserved identifiers: tickets AI-IMP-001–010 (008–010 are wave
  slack — unspent unless the Review Lead cuts them), court
  migrations 0001–0010, initial `schema_version: 1` per event
  type, **no ports** (M1 binds no sockets — if you believe you
  need one, STOP and say so in a submission; do not take one).
- Validation: `set -o pipefail` on every chain;
  `mix format --check-formatted && mix compile --warnings-as-errors && mix test`
  at the tip — read counts, not exit codes; report the failed line
  if any exists; compile before any integration run;
  `RAG/scripts/validate-tickets.sh --changed` clean before
  submitting.

## Report contents (each round)

Per PROTOCOL.md, plus: test counts for every suite you ran
(per-app and total), the kill-harness matrix actually executed in
007 (which cuts, how many runs), your ULID/cursor/event-name
choices with one-line rationales, and candid friction notes — they
feed the wave retro.
