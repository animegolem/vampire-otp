---
node_id: AI-IMP-002
tags:
  - IMP-LIST
  - Implementation
  - M1
  - court
kanban_status: planned
depends_on: AI-IMP-001
parent_epic: [[AI-EPIC-001-m1-heartbeat-and-court]]
confidence_score: 0.8
date_created: 2026-08-07
date_completed:
---

# AI-IMP-002-court-event-envelope

## Summary

The court does not exist. Implement the A.1 event envelope as the
`events` table (migrations 0001+, reserved range 0001–0010),
appended exclusively through one writer process so `event_seq` is
race-free by construction, with append-only enforced mechanically.
Done-state: concurrent appends from many processes yield gapless
monotonic `event_seq` with zero duplicates; any attempted UPDATE or
DELETE of a committed event row fails at the SQLite layer and the
failure is test-proven.

### Out of Scope

Artifact store (003), lifecycle semantics beyond envelope fields
(004), projections (005), any read-model beyond simple typed reads.
No fork spawning — only the `actor` naming convention is reserved.

### Design/Approach

`Court.Writer` GenServer owns all appends: callers use
`Court.append(event)` which routes through the writer; the writer
assigns `event_seq` (monotonic, court-assigned at commit — SQLite
INTEGER PRIMARY KEY on its own append transaction) and stamps
`recorded_at`. `event_id` is a producer-minted ULID (idempotency
anchor: unique index; re-insert of the same `event_id` is a no-op
returning the committed row). Envelope columns per A.1 verbatim:
event_type, schema_version, occurred_at/recorded_at, actor,
causation_id, correlation_id, lifecycle refs (resident_id,
incarnation_id, session_id?, episode_id?, segment_id?, window_id?,
tick_id?, turn_id?), payload (JSON), artifact_refs (JSON array of
algorithm-qualified hashes). Append-only: SQLite triggers on
events raising on UPDATE and DELETE, plus no update/delete
functions in the module API. Corrections are new events via
`causation_id` (A.1). The `actor` field documents the reserved
sub-role convention `resident/<fork-label>` (DQ-007 M1 consequence)
in moduledoc and a format check accepting `owner | resident |
resident/<label> | broker | worker/<id> | recovery`.

### Files to Touch

`apps/court/priv/repo/migrations/0001_create_events.exs`: new.
`apps/court/lib/court/event.ex`: schema + envelope validation, new.
`apps/court/lib/court/writer.ex`: single writer GenServer, new.
`apps/court/lib/court.ex`: public append/read API, new.
`apps/court/test/**`: envelope, concurrency, append-only tests, new.

### Implementation Checklist

<CRITICAL_RULE>
Before marking an item complete on the checklist MUST **stop** and **think**. Have you validated all aspects are **implemented** and **tested**?
</CRITICAL_RULE>

- [ ] Migration 0001: events table, every A.1 envelope column, unique index on event_id, triggers raising on UPDATE/DELETE.
- [ ] `Court.Event` changeset validates event_type, schema_version ≥ 1, actor format (reserved convention documented), ULID event_id.
- [ ] `Court.Writer` GenServer: all appends serialized; event_seq court-assigned; recorded_at stamped at commit; duplicate event_id returns the committed row (idempotent re-scan).
- [ ] `Court.append/1` + typed read API (`by_seq_range`, `by_event_id`, `by_type`); no update/delete functions exported.
- [ ] Concurrency test: N processes × M appends → N×M rows, gapless monotonic seq, no duplicates.
- [ ] Append-only test: raw SQL UPDATE and DELETE against a committed row both raise from the trigger.
- [ ] Full gate green at ticket tip.

### Acceptance Criteria

**Scenario:** Concurrent producers write to one court.
**GIVEN** the court app running with migration 0001 applied.
**WHEN** 20 processes each append 50 events concurrently.
**THEN** exactly 1000 rows exist with event_seq forming a gapless monotonic sequence.
**AND** re-submitting a duplicate event_id adds no row and returns the original.
**THEN** a raw UPDATE or DELETE attempt on any committed row raises at the SQLite layer.

### Issues Encountered

<!--
The comments under the 'Issues Encountered' heading are the only comments you MUST not remove
This section is filled out post work as you fill out the checklists.
You SHOULD document any issues encountered and resolved during the sprint.
You MUST document any failed implementations, blockers or missing tests.
-->
