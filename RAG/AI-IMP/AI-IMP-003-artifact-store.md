---
node_id: AI-IMP-003
tags:
  - IMP-LIST
  - Implementation
  - M1
  - artifacts
kanban_status: planned
depends_on: AI-IMP-002
parent_epic: [[AI-EPIC-001-m1-heartbeat-and-court]]
confidence_score: 0.8
date_created: 2026-08-07
date_completed:
---

# AI-IMP-003-artifact-store

## Summary

Large content needs a home outside event payloads (§4.2, A.4).
Implement the content-addressed artifact store: `sha256:<hex>`
identifiers, the durable publication sequence (staging write →
fsync file → atomic rename → fsync directory → only then the
referencing event may commit), reference resolution over the four
ruled states, and two-phase deletion with its recovery rules.
Done-state: the A.4 recovery table is fully test-covered, including
crash cuts between every phase of publication and deletion.

### Out of Scope

GC mark/sweep (reachability rules are recorded; implementation is a
later ticket — M4.5 retention era). BLAKE3 benchmark (ruled an
implementation-ticket decision for a later wave). Privacy policy
decisions — this ticket builds mechanism only.

### Design/Approach

`Court.Artifacts` module (inside the court app — artifacts and
events share the durability boundary; ecto-process-boundaries: one
Repo). Store root from config; sharded dirs by hash prefix.
`publish/2` performs the full durability sequence and returns the
qualified ref; the API couples publication to reference — an event
carrying `artifact_refs` may only commit if each ref resolves
`available` (checked in the writer's append path). Resolution:
`available | tombstoned | missing | deletion_pending` — the two
event-backed states derive from court events
(`artifact_deletion_requested`, `artifact_tombstoned`); `missing`
is bytes absent with no authorizing chain ⇒ integrity_fault.
Two-phase deletion per A.4 verbatim, with recovery: request+bytes →
retry delete; request+no-bytes → commit tombstone; no-request+no-
bytes → missing. Crash cuts simulated by running each phase as a
separately invokable step in tests.

### Files to Touch

`apps/court/lib/court/artifacts.ex`: store + publication, new.
`apps/court/lib/court/artifacts/resolution.ex`: state model, new.
`apps/court/lib/court/writer.ex`: refs-resolve-available check on append.
`apps/court/priv/repo/migrations/0002_artifact_deletion_events.exs`: only if event tables need support beyond `events` (prefer none — deletion phases are ordinary court events).
`apps/court/test/**`: publication, resolution, deletion, crash-cut tests, new.

### Implementation Checklist

<CRITICAL_RULE>
Before marking an item complete on the checklist MUST **stop** and **think**. Have you validated all aspects are **implemented** and **tested**?
</CRITICAL_RULE>

- [x] `publish/2`: staging file on destination filesystem, write → fsync → rename → dir fsync, returns `sha256:<hex>` ref; content round-trips.
- [x] Writer append rejects an event whose artifact_refs contain a non-`available` ref.
- [x] `resolve/1` returns the four ruled states per the A.4 derivation.
- [x] Two-phase deletion: `delete_requested/2` commits the request event (state → deletion_pending); `complete_deletion/1` removes bytes, fsyncs dir, commits `artifact_tombstoned`.
- [x] Recovery function covering all three A.4 recovery rows, test-driven per row.
- [x] Crash-cut tests: process killed between publication steps never yields a referencing event without durable bytes; killed between deletion phases always converges per A.4 on recovery.
- [x] Full gate green at ticket tip.

### Acceptance Criteria

**Scenario:** Deletion interrupted between phases.
**GIVEN** an artifact with a committed `artifact_deletion_requested` and bytes still on disk.
**WHEN** recovery runs after a simulated crash.
**THEN** the bytes are deleted and `artifact_tombstoned` commits.
**AND** resolution reports `tombstoned` with the full authorizing chain.
**THEN** an artifact with bytes absent and no authorizing chain resolves `missing` and surfaces integrity_fault.

### Issues Encountered

- No migration 0002 was needed: requests and tombstones are ordinary schema-1
  court events, as preferred by the ticket.
- Deletion targets live in event payloads rather than `artifact_refs`; otherwise
  the Writer's availability gate would correctly reject the tombstone that
  completes a pending deletion. The tombstone instead carries the request's
  `event_id` as `causation_id`.
- Recovery and concurrent retries need semantic idempotency, so request and
  tombstone check-plus-append operations execute as typed commands inside the
  single Writer transaction rather than as query-then-append caller sequences.
- Publication of an already-present final file re-verifies its digest and
  re-syncs the directory. This repairs the legitimate recovery case where a
  prior process died after rename but before directory fsync.

<!--
The comments under the 'Issues Encountered' heading are the only comments you MUST not remove
This section is filled out post work as you fill out the checklists.
You SHOULD document any issues encountered and resolved during the sprint.
You MUST document any failed implementations, blockers or missing tests.
-->
