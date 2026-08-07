---
node_id: AI-IMP-005
tags:
  - IMP-LIST
  - Implementation
  - M1
  - projections
kanban_status: planned
depends_on: AI-IMP-002
parent_epic: [[AI-EPIC-001-m1-heartbeat-and-court]]
confidence_score: 0.8
date_created: 2026-08-07
date_completed:
---

# AI-IMP-005-projection-registry

## Summary

Projections have no machinery (§4.6, A.6). Implement the projection
registry events (`projection_created`, `projection_superseded`) and
the first real projection: `logs.txt`, a human-readable rendering of
the court with its own durable cursor, rebuildable from scratch.
Done-state: deleting `logs.txt` and its cursor then rebuilding
yields byte-identical output for the same committed prefix, and the
projection never claims source-truth (registry lineage recorded).

### Out of Scope

Prompt-assembly projections, note indexes, kanban-style views (M3+).
Any projection whose producer is a model — `logs.txt` is pure code.

### Design/Approach

`Runtime.Projections.Logs` consumer: reads events from the court in
`event_seq` order from its checkpoint cursor (cursor stored as a
small table or file — Code Lead's choice, but crash-safe: cursor
advances only after the rendered lines are durably appended),
renders one line per event (timestamp, seq, type, actor, terse
payload summary), appends to `logs.txt`. Registry: on first build
and on rebuild, append `projection_created` naming producer/version
and cursor; supersession on rebuild appends
`projection_superseded` for the prior version. Determinism:
rendering is a pure function of the event row — no wall-clock, no
locale.

### Files to Touch

`apps/runtime/lib/runtime/projections/logs.ex`: new.
`apps/runtime/lib/runtime/projections/cursor.ex`: checkpoint, new.
`apps/runtime/test/projections_test.exs`: rebuild determinism, cursor crash-safety, new.

### Implementation Checklist

<CRITICAL_RULE>
Before marking an item complete on the checklist MUST **stop** and **think**. Have you validated all aspects are **implemented** and **tested**?
</CRITICAL_RULE>

- [ ] Cursor: durable checkpoint advancing only after rendered output is durable; killed mid-batch re-renders without duplication or gaps.
- [ ] Renderer: pure function event-row → line; property test over envelope variants.
- [ ] `projection_created` on build with producer, version, cursor; `projection_superseded` on rebuild.
- [ ] Rebuild-from-zero equals incremental output byte-identically for the same prefix.
- [ ] Full gate green at ticket tip.

### Acceptance Criteria

**Scenario:** Projection loss is cheap.
**GIVEN** a court with 500 committed events and a built `logs.txt`.
**WHEN** `logs.txt` and its cursor are deleted and rebuild runs.
**THEN** the rebuilt file is byte-identical to the original.
**AND** the registry shows the new version superseding the old with intact lineage.
**THEN** killing the consumer mid-batch and restarting produces no duplicate and no missing lines.

### Issues Encountered

<!--
The comments under the 'Issues Encountered' heading are the only comments you MUST not remove
This section is filled out post work as you fill out the checklists.
You SHOULD document any issues encountered and resolved during the sprint.
You MUST document any failed implementations, blockers or missing tests.
-->
