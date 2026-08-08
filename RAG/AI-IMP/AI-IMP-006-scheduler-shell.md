---
node_id: AI-IMP-006
tags:
  - IMP-LIST
  - Implementation
  - M1
  - scheduler
kanban_status: planned
depends_on: AI-IMP-001, AI-IMP-002
parent_epic: [[AI-EPIC-001-m1-heartbeat-and-court]]
confidence_score: 0.8
date_created: 2026-08-07
date_completed:
---

# AI-IMP-006-scheduler-shell

## Summary

Invariant 13 requires a per-resident stop that is not the power
cord, and §8.5 places its first slice in the M1 scheduler shell.
Implement the scheduler as the single admission authority
(invariant 8) in shell form — an admission API with no real
backends — carrying pause/stop as recorded court transitions.
Done-state: pause commits a transition event and admission is
demonstrably denied while paused; resumable pause and terminal
stop are distinct event types; resume restores admission.

### Out of Scope

Real jobs, resource_claims arithmetic, leases, fencing, budgets
(M2, A.5). Drain semantics beyond "no active work exists in a
shell" — active-work drain is M2's obligation.

### Design/Approach

`Scheduler.Admission` GenServer: `request_admission/1` returns
`{:ok, ref} | {:denied, reason}`; per-resident state machine
`running | paused | stopped` backed by court events
(`resident_paused{resumable: true}`, `resident_resumed`,
`resident_stopped{terminal: true}` — exact event names are the
Code Lead's to propose in round 1, distinctness is normative).
State rebuilds from the court on boot (the court is the truth; the
GenServer is a cache). Denials while paused are recorded
(`admission_denied{reason: paused}`) — denial has the same dignity
as grant. Terminal stop refuses resume permanently for that
resident.

### Files to Touch

`apps/scheduler/lib/scheduler/admission.ex`: new.
`apps/scheduler/mix.exs`: depend on court.
`apps/scheduler/test/admission_test.exs`: transition matrix, new.

### Implementation Checklist

<CRITICAL_RULE>
Before marking an item complete on the checklist MUST **stop** and **think**. Have you validated all aspects are **implemented** and **tested**?
</CRITICAL_RULE>

- [x] Admission API; grants recorded only in shell state (no job events yet), denials recorded as court events.
- [x] Pause commits a resumable transition event; subsequent admission denied + recorded.
- [x] Resume commits its event; admission restored.
- [x] Terminal stop commits a distinct event type; resume attempts fail and the refusal is recorded.
- [x] Boot-time state rebuild from court events; killed-and-restarted scheduler preserves paused/stopped state.
- [x] Full gate green at ticket tip.

### Acceptance Criteria

**Scenario:** §8.5 pause criteria at M1 scope.
**GIVEN** a running scheduler for resident R.
**WHEN** pause is issued.
**THEN** a recorded resumable transition exists and new admission for R is denied with a recorded denial.
**AND** after SIGKILL and restart the scheduler still denies R's admission.
**THEN** resume restores admission, and a terminal stop thereafter produces a distinct event whose resume attempts are refused.

### Issues Encountered

<!--
The comments under the 'Issues Encountered' heading are the only comments you MUST not remove
This section is filled out post work as you fill out the checklists.
You SHOULD document any issues encountered and resolved during the sprint.
You MUST document any failed implementations, blockers or missing tests.
-->

- M1 admission grants are deliberately ephemeral references held only by
  the caller. They are not persisted permits, jobs, claims, leases, or
  dispatch authority; those concepts remain fenced to M2.
- The scheduler cache is reconstructed from court transition events in
  `event_seq` order. A transition is appended before the cache changes,
  so process death cannot make the cache more authoritative than court.
- The round-one event names were retained: `resident_paused`,
  `resident_resumed`, `resident_stopped`, `admission_denied`, and
  `lifecycle_transition_denied`. Invalid recording context is rejected
  rather than inventing an unknown policy or resident.
