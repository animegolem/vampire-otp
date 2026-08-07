---
node_id: AI-EPIC-001
tags:
  - EPIC
  - AI
  - M1
  - court
  - recovery
date_created: 2026-08-07
date_completed:
kanban_status: in-progress
ai_imp_spawned: AI-IMP-001 … AI-IMP-007
---

# AI-EPIC-001-m1-heartbeat-and-court

## Problem Statement/Feature Scope

Nothing exists. SPEC-VampOTP rev 0.7 is ratified and the project
has a canonical commit, but no application: no umbrella, no court,
no recovery guarantee. Every later capability (broker, sessions,
noting, voice) depends on one property this epic must prove first:
the resident's authoritative record survives process death and
whole-VM interruption without inventing uncommitted history
(invariants 1, 2, 5, 6; §8.2).

## Proposed Solution(s)

Build M1 per §6.2: the Elixir umbrella with supervised apps
`court`, `runtime`, `scheduler`, `broker`, `driver` (§6.1); the
SQLite court with the A.1 event envelope behind a single writer
process (ecto-process-boundaries settled position: `event_seq`
race-free by construction); the content-addressed artifact store
with durable publication and A.4 two-phase deletion; lifecycle boot
events with crash inference (A.2); the projection registry and the
`logs.txt` cursor projection (A.6); a scheduler shell carrying the
invariant-13 pause/stop recorded transitions at M1 scope; and the
A.7 recovery oracle exercised by SIGKILL tests over a synthetic
action aggregate (owner-ruled 2026-08-07: aggregate included).
The Code Lead builds the range from BRIEF-001 in the isolated
clone; the Review Lead reviews per charter and merges.

## Path(s) Not Taken

Real broker actions and the doubt gate (M2). Sessions, warm start,
noting, decompression (M3). Voice Track V (deferred to the M2 cut —
owner-ruled 2026-08-07). Real inference dispatch — the scheduler is
a shell. AgentFS. Any consciousness-block/org-surface work (DQ-007/
DQ-008 ride the amendment cycle first).

## Success Metrics

- Full application gate green at wave close: `mix format
  --check-formatted && mix compile --warnings-as-errors && mix test`.
- §8.2 acceptance demonstrated by automated tests: replay of the
  maximal committed event prefix yields exactly its canonical
  derived state; a killed supervised child loses no committed
  events; a killed VM invents nothing; every artifact reference
  resolves under the ruled state model.
- §8.5 M1-scope pause criteria: pause commits a recorded
  transition; admission denied while paused; resumable vs terminal
  are distinct event types.
- Wave completed within ticket range AI-IMP-001–007 without
  unreserved identifier grabs.

## Requirements

### Functional Requirements

- [ ] FR-1: Umbrella scaffold with the five §6.1 apps, supervision
      trees, and the full CI gate passing on the skeleton. (AI-IMP-001)
- [ ] FR-2: Court schema + A.1 envelope, append-only enforced, one
      writer process, `actor` sub-role convention reserved. (AI-IMP-002)
- [ ] FR-3: Artifact store: content-addressed publication with the
      durability sequence; two-phase deletion with recovery rules. (AI-IMP-003)
- [ ] FR-4: Lifecycle boot events: `resident_id`/`incarnation_id`,
      clean terminal events, `incarnation_crash_inferred` on orphan
      detection. (AI-IMP-004)
- [ ] FR-5: Projection registry events + `logs.txt` rebuildable
      cursor projection. (AI-IMP-005)
- [ ] FR-6: Scheduler shell with pause/stop recorded transitions and
      admission denial while paused. (AI-IMP-006)
- [ ] FR-7: A.7 recovery oracle: synthetic action aggregate,
      supervised-child kill test, whole-VM SIGKILL test. (AI-IMP-007)

### Non-Functional Requirements

- `--warnings-as-errors` clean at every ticket tip.
- No `UPDATE`/`DELETE` ever reaches a committed event row (A.1);
  enforcement is mechanical (triggers and API shape), not
  convention.
- Artifact publication order (write → fsync → rename → dir fsync →
  referencing event) is enforced by the API, not by caller
  discipline.
- Tests are deterministic; kill-based tests use OS-level process
  boundaries, not timing luck.
- Reserved identifiers for this wave: tickets AI-IMP-001–010,
  court migrations 0001–0010, initial `schema_version: 1` per event
  type, no ports (M1 binds no sockets — a needed port is a STOP).

## Implementation Breakdown

2026-08-07 — wave cut (Review Lead), assigned whole to the Code
Lead as BRIEF-001: AI-IMP-001 (scaffold) → AI-IMP-002 (court) →
AI-IMP-003 (artifacts), AI-IMP-004 (lifecycle), AI-IMP-005
(projections) in any order after 002 → AI-IMP-006 (scheduler shell)
→ AI-IMP-007 (recovery oracle, closes the epic). AI-IMP-008–010
reserved unspent for wave slack.
