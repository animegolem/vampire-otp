---
node_id: AI-IMP-004
tags:
  - IMP-LIST
  - Implementation
  - M1
  - lifecycle
kanban_status: planned
depends_on: AI-IMP-002
parent_epic: [[AI-EPIC-001-m1-heartbeat-and-court]]
confidence_score: 0.85
date_created: 2026-08-07
date_completed:
---

# AI-IMP-004-lifecycle-boot-events

## Summary

Nothing records that the resident exists or that a boot happened.
Implement A.2's lifecycle roots: durable `resident_id`
(installation identity), per-boot `incarnation_id`, boot/terminal
events, and crash inference — on boot, any prior incarnation
without a clean terminal event gets `incarnation_crash_inferred`,
never a synthesized ending (invariant 6). Done-state: boot → kill
→ reboot produces exactly one crash-inference event naming the
orphan, and a clean shutdown produces a terminal event and no
inference.

### Out of Scope

Sessions, episodes, segments, windows, ticks, turns (M3 — envelope
columns exist from 002; no aggregate logic here). Pause/stop
transitions (006).

### Design/Approach

`Runtime.Lifecycle` GenServer in the runtime app, started early in
its supervision tree: reads-or-mints `resident_id` (persistent term
in the court: first boot appends `resident_created`), mints ULID
`incarnation_id`, appends `incarnation_started`, then scans for
orphans: incarnations with a start and no terminal
(`incarnation_ended` | prior `incarnation_crash_inferred` naming
them) → append `incarnation_crash_inferred{orphan_incarnation_id}`
with `actor: recovery`. Clean shutdown appends `incarnation_ended`
from the terminate callback (best-effort — a missed terminate IS
the crash signal, by design). Idempotent by event_id derivation so
a recovery re-scan cannot double-infer.

### Files to Touch

`apps/runtime/lib/runtime/lifecycle.ex`: new.
`apps/runtime/mix.exs`: depend on court app.
`apps/runtime/test/lifecycle_test.exs`: boot/clean/crash matrix, new.

### Implementation Checklist

<CRITICAL_RULE>
Before marking an item complete on the checklist MUST **stop** and **think**. Have you validated all aspects are **implemented** and **tested**?
</CRITICAL_RULE>

- [x] First boot appends `resident_created` + `incarnation_started`; second boot appends only `incarnation_started` for the new id.
- [x] Clean stop appends `incarnation_ended` for its own incarnation.
- [x] Boot-after-crash appends exactly one `incarnation_crash_inferred` naming the orphan; the inference is `actor: recovery` and typed as inference, not ending.
- [x] Re-running the orphan scan is a no-op (idempotent event_id).
- [x] Multi-orphan case: N unclean prior incarnations → N inference events, one each.
- [x] Full gate green at ticket tip.

### Acceptance Criteria

**Scenario:** Whole-VM crash and reboot.
**GIVEN** an incarnation started and its process killed without terminate.
**WHEN** the application boots again.
**THEN** the new incarnation starts and exactly one `incarnation_crash_inferred` names the orphan.
**AND** no `incarnation_ended` exists for the orphan.
**THEN** booting a third time adds no further inference for that orphan.

### Issues Encountered

- The round-1 verdict rejected deterministic ULID derivation. Crash inference,
  resident creation, starts, and endings therefore use semantic
  check-plus-append commands inside the single Writer transaction; a repeated
  or concurrent scan returns the one previously committed event.
- Minting an incarnation in `Lifecycle.init/1` would misclassify an ordinary
  supervised child restart as a machine boot. `Runtime.BootIdentity` mints once
  per BEAM and the application freezes that value into the child spec; a kill
  and restart test proves the start remains singular.
- `terminate/2` records a terminal only for supervisor shutdown reasons. An
  arbitrary clean child exit can be restarted and is not evidence that the
  whole incarnation ended.
- Court migrations now run before `Court.Writer` becomes available. This keeps
  the dependency-ordered Runtime boot from racing an uninitialized event table
  in a fresh checkout.

<!--
The comments under the 'Issues Encountered' heading are the only comments you MUST not remove
This section is filled out post work as you fill out the checklists.
You SHOULD document any issues encountered and resolved during the sprint.
You MUST document any failed implementations, blockers or missing tests.
-->
