---
node_id: AI-IMP-007
tags:
  - IMP-LIST
  - Implementation
  - M1
  - recovery
kanban_status: planned
depends_on: AI-IMP-002, AI-IMP-003, AI-IMP-004, AI-IMP-005, AI-IMP-006
parent_epic: [[AI-EPIC-001-m1-heartbeat-and-court]]
confidence_score: 0.7
date_created: 2026-08-07
date_completed:
---

# AI-IMP-007-recovery-oracle

## Summary

M1's reason to exist: prove recovery (§6.2, §8.2, A.7). Build the
A.7 oracle as an automated test harness and run it against a
synthetic action aggregate (owner-ruled 2026-08-07: included; A.7
explicitly permits it to exercise the court contract before M2).
Done-state: supervised-child kill tests and whole-VM SIGKILL tests
pass the full A.7 criterion — replay of the maximal committed
prefix yields exactly the canonical derived state, dispatched-
without-terminal attempts surface as `outcome_unknown`, every
artifact reference resolves per A.4, and nothing uncommitted is
invented.

### Out of Scope

Real broker/dispatch machinery (M2 implements A.3 whole). The
synthetic aggregate is disposable scaffolding — mark its modules
clearly; M2 replaces it.

### Design/Approach

Synthetic aggregate: `Court.Synthetic.Action` writing real court
events shaped like A.3's families (proposed → approved → attempt
claimed → dispatched → terminal | *nothing*) with `actor:
worker/synthetic`, exercising artifact refs on some events. Derived
state: a pure fold over events (action phases, attempt states,
artifact resolutions, lifecycle facts, scheduler state) — this fold
IS the oracle's "canonical derived state" and doubles as the
replay implementation. Harness: (a) child-kill — `Process.exit(:kill)`
on Writer/consumers mid-load, assert committed events all survive
and fold is reachable; (b) VM-kill — run the app as a child OS
process (mix run / release script), drive load over stdio or a
driver script, `kill -9`, restart, run fold, assert A.7 verbatim
including the `deletion_pending` clause (A.8: the SIGKILL test
adopts it) and at least one dispatched-no-terminal synthetic
attempt represented as `outcome_unknown`. Cuts parameterized over
publication phases, deletion phases, and mid-append.

### Files to Touch

`apps/court/lib/court/synthetic/action.ex`: disposable aggregate, new.
`apps/court/lib/court/replay.ex`: canonical fold, new.
`apps/court/test/recovery/child_kill_test.exs`: new.
`apps/court/test/recovery/vm_kill_test.exs`: OS-process harness, new.
`scripts/` or `apps/court/priv/`: kill-harness driver, new.

### Implementation Checklist

<CRITICAL_RULE>
Before marking an item complete on the checklist MUST **stop** and **think**. Have you validated all aspects are **implemented** and **tested**?
</CRITICAL_RULE>

- [ ] Synthetic action aggregate writing real envelope events, including artifact-bearing and dispatched-no-terminal cases; modules marked disposable-for-M2.
- [ ] `Court.Replay.fold/1`: pure, deterministic derived state over any committed prefix; property: fold(prefix) invariant under re-fold.
- [ ] Child-kill tests: Writer and projection consumers killed under load; no committed loss; cursor recovery clean (005's guarantee re-proven under this harness).
- [ ] VM-kill harness: app as separate OS process, driven load, `kill -9` at parameterized cuts (mid-append, between artifact publication steps, between deletion phases).
- [ ] Post-restart assertions: A.7 verbatim — exact canonical derived state, `outcome_unknown` represented, artifact refs resolve available/tombstoned/deletion_pending-with-request, nothing invented, crash inference present (004).
- [ ] Full gate green at ticket tip; epic FR checklist updated; wave closes.

### Acceptance Criteria

**Scenario:** The vampire survives the night.
**GIVEN** the umbrella under synthetic load with artifacts publishing, a deletion mid-phase, and a dispatched synthetic attempt in flight.
**WHEN** the OS process is killed with SIGKILL and the application restarts.
**THEN** replaying the maximal committed prefix yields exactly the canonical derived state for that prefix.
**AND** the in-flight attempt is represented as `outcome_unknown`, not failed, not replayed.
**AND** every artifact reference resolves `available`, `tombstoned`, or `deletion_pending` with its authorizing request.
**AND** the orphan incarnation carries a crash inference and no synthesized ending.
**THEN** the full gate and the entire M1 suite pass on the merge commit.

### Issues Encountered

<!--
The comments under the 'Issues Encountered' heading are the only comments you MUST not remove
This section is filled out post work as you fill out the checklists.
You SHOULD document any issues encountered and resolved during the sprint.
You MUST document any failed implementations, blockers or missing tests.
-->
