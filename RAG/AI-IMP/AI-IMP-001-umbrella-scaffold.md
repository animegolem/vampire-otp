---
node_id: AI-IMP-001
tags:
  - IMP-LIST
  - Implementation
  - M1
  - scaffold
kanban_status: planned
depends_on:
parent_epic: [[AI-EPIC-001-m1-heartbeat-and-court]]
confidence_score: 0.9
date_created: 2026-08-07
date_completed:
---

# AI-IMP-001-umbrella-scaffold

## Summary

No application exists. Create the Elixir umbrella `vampire_otp` at
the repo root with the five supervised apps ruled in §6.1 —
`court`, `runtime`, `scheduler`, `broker`, `driver` — each an OTP
application with a (mostly empty) supervision tree, plus shared
config and the SQLite dependency wired into `court` only
(ecto-process-boundaries settled position: one Repo, under court).
Done-state: a fresh clone runs `mix format --check-formatted && mix
compile --warnings-as-errors && mix test` green from the umbrella
root, and `Application.started_applications/0` shows all five apps
under test.

### Out of Scope

Any real event schema (AI-IMP-002), artifact code (003), lifecycle
events (004), projections (005), scheduler semantics (006). No
deps beyond ecto_sqlite3/ecto and a ULID library; no HTTP, no
sockets.

### Design/Approach

Standard `mix new vampire_otp --umbrella`; `apps/<name>` via
`mix new --sup`. `court` takes `{:ecto_sqlite3, ...}` and owns the
Repo (database file path from config, per-env; test env uses a tmp
path). Formatter configured umbrella-wide. `.gitignore` already
covers `_build/`/`deps/`. Keep generated skeletons minimal — delete
sample code that would rot.

### Files to Touch

`mix.exs`, `config/*.exs`: umbrella + per-env config, new.
`apps/court/**`, `apps/runtime/**`, `apps/scheduler/**`,
`apps/broker/**`, `apps/driver/**`: generated apps, new.
`apps/court/lib/court/repo.ex`: Repo module, new.

### Implementation Checklist

<CRITICAL_RULE>
Before marking an item complete on the checklist MUST **stop** and **think**. Have you validated all aspects are **implemented** and **tested**?
</CRITICAL_RULE>

- [x] Generate umbrella `vampire_otp` at repo root; five `--sup` apps per §6.1 naming.
- [x] Add ecto_sqlite3 + ecto to `court`; define `Court.Repo`; per-env database config (test uses isolated tmp file per run).
- [x] Add a ULID dependency to `court` (Code Lead's choice; name it in the submission).
- [x] Configure umbrella-wide formatter; run `mix format`.
- [x] Remove generated sample modules/tests that assert nothing real; add one boot test per app asserting the supervisor starts.
- [x] Full gate green: `mix format --check-formatted && mix compile --warnings-as-errors && mix test`.

### Acceptance Criteria

**Scenario:** Fresh checkout build.
**GIVEN** a clean clone at this ticket's commit with deps fetched.
**WHEN** the full gate command runs from the umbrella root.
**THEN** format check, compile with warnings-as-errors, and tests all pass.
**AND** the test suite asserts all five §6.1 apps start under supervision.

### Issues Encountered

- The first formatter run referenced a nonexistent `Ecto.Migration.Formatter`
  plugin. Removing that speculative plugin restored the standard
  `import_deps`-based formatter configuration; the exact full gate then passed.
- The harness patch helper initially targeted the owner checkout despite the
  shell workdir. The newly created scaffold files were moved immediately into
  the isolated Code Lead clone before validation or commit; no pre-existing
  owner-checkout file was overwritten.

<!--
The comments under the 'Issues Encountered' heading are the only comments you MUST not remove
This section is filled out post work as you fill out the checklists.
You SHOULD document any issues encountered and resolved during the sprint.
You MUST document any failed implementations, blockers or missing tests.
-->
