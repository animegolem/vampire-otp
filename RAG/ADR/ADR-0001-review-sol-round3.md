# ADR-0001 v0.2 — Cross-Model Re-review

**Reviewed:** August 6, 2026  
**Scope:** ADR-0001 v0.2 and Agent Design Spec v0.2  
**Disposition:** Approve with four required amendments; no further architectural review required

## Ruling

ADR-0001 v0.2 incorporates the prior review in substance and preserves the important reversals honestly. The architecture passes. The revised lifecycle topology, digest-bound approvals, dispatch attempts, worker fencing, three-state artifact resolution, reachability GC, request artifacts, projection descriptors, and recovery oracle are the right contracts for M1–M3.

Four narrow amendments remain before the owner marks Gate 2 complete. They define missing transition invariants; none changes the chosen architecture. Once incorporated, a mechanical consistency check is sufficient—I do not need another full design round.

## 1. Approve one episode with many segments, with identity invariants

The chosen semantics are better than creating a successor episode after every crash. A crash is an interruption in execution, not necessarily a change of goal, and keeping one `episode_id` makes the complete trajectory easy to retrieve.

Add these invariants:

- every segment has a stable `segment_id` plus a court-assigned `segment_n` unique within the episode;
- at most one segment of an episode may be active at a time;
- resume uses a compare-and-set from `interrupted`/`suspended` to `active`;
- a completed or abandoned episode can never be resumed;
- the episode's `goal_digest` is immutable.

That last point sharpens the current owner-approval rule: if the goal digest changed, owner approval must not mutate the existing episode into a different goal. Open a new episode and link it with `supersedes_episode_id` or `derived_from_episode_id`. Owner approval governs undertaking the new goal, not rewriting the identity of the old one.

Sessions and episodes should not be described as one containing the other globally. A segment occurs during one recording incarnation and one session; an episode may have segments across several of each.

## 2. Keep a factorized model, but reclassify the “holds”

Do not promote every hold into one flat core state machine. That creates a state explosion because an action may simultaneously lack a valid approval, need owner attention, and contain an unknown attempt. The instinct to model orthogonal concerns is right, but the present list mixes different kinds of thing.

Use three dimensions:

```text
action.phase       = proposed | approved | active | resolved
action.resolution  = succeeded | failed | denied | cancelled | expired | abandoned | null
action.blockers    = {needs_owner, unverified, approval_invalidated, ...}

attempt.state      = claimed | dispatched | succeeded | failed | outcome_unknown
```

Therefore:

- `outcome_unknown` is a core **attempt state**, not an action hold;
- `needs_owner` and `unverified` are action blockers;
- `approval_invalidated` is an approval event that derives an approval blocker;
- `abandoned` is a terminal action resolution, not a doubt-gate hold.

Define one dispatch guard normatively: an action may dispatch only when its digest has a currently valid approval, all required preconditions are fresh, it has no blocking condition, its batch is open, and no unresolved attempt forbids another attempt. This gives the broker one auditable predicate rather than scattered prohibitions.

## 3. Add crash-safe tombstone transitions

Artifact publication is now crash-safe, but deletion still has a cross-store crash window. If the bytes are deleted before `artifact_tombstoned` commits, recovery sees an unexplained missing artifact. If the tombstone commits before deletion, a crash can leave privacy-sensitive bytes behind while the court claims they are gone.

Use a two-phase deletion protocol:

1. commit `artifact_deletion_requested` with authority, hash, reason, and retention-policy version;
2. delete the bytes and durably sync the containing directory;
3. commit `artifact_tombstoned` as completion.

Add the transient resolution `deletion_pending`. On recovery:

- request + bytes present → retry deletion;
- request + bytes absent → commit the tombstone completion;
- bytes absent with neither request nor tombstone → `missing`/`integrity_fault`.

The externally stable states may remain `available | tombstoned | missing`; `deletion_pending` is the durable transition state that makes those claims honest under `SIGKILL`.

## 4. Bind the Metal fencing rule and inference attempts

For Metal-backed MLX/llama.cpp workers on this machine, use an out-of-process runtime. Do not run model compute inside an unkillable BEAM NIF if scheduler recovery depends on fencing it.

Concrete rule:

1. Each runtime process/process-group has a `runtime_generation`; every lease carries that generation and every job execution has an `attempt_id`.
2. After the configured missed-heartbeat threshold, mark all attempts on that runtime `suspect`, stop new admission, and request cooperative cancellation/`SIGTERM`.
3. After a bounded termination grace, send `SIGKILL` to the process group.
4. Do not requeue onto Metal until the OS process monitor confirms exit, a replacement runtime starts with a higher generation, and a health probe succeeds.
5. If death or health cannot be confirmed, mark the Metal resource unavailable. Degrade to an allowed CPU/network route or surface the failure; never requeue onto the suspect runtime merely because time passed.
6. Results carrying a stale runtime generation are retained as artifacts but cannot be selected.

If one runtime process hosts multiple jobs, loss of that runtime makes all of its active attempts suspect. The scheduler must account for this shared failure domain.

The job schema should therefore explicitly add `attempt_id`, `runtime_generation`, and `lease_id`. I also recommend changing singular `resource_class` to `resource_claims`, or pairing it with at least `estimated_unified_memory_bytes`: Metal, CPU, and unified memory are not independent resources on the M3, so a single label is insufficient for safe concurrent admission.

## Minor drafting repairs

- Decision 1 should be self-contained rather than “unchanged from v0.1.” Restore the field semantics in the current normative text and state that corrections occur through new events, never `UPDATE`/`DELETE` of court rows.
- In Design §1, the E/R dissociation is called “Phase 3” in the branching bullet; it is Phase 2.
- The rest of the prior synchronization audit now passes: the v0.2 header, incidental-file boundary, Phase 3 wording, empirical batch ceiling, and Phase-6 references are all repaired.

## Gate 2 disposition

The architecture and ADR direction are approved. Gate 2 becomes complete when the owner rules on ADR-0001 with the four amendments above incorporated:

1. segment identity and immutable episode goal;
2. factorized action/attempt status plus the dispatch guard;
3. two-phase crash-safe artifact deletion;
4. process-confirmed Metal fencing with inference attempt/generation identifiers.

After that, release M1–M3. Any remaining choices—heartbeat timings, GC interval, exact database indexes, or whether BLAKE3 later beats SHA-256 in a benchmark—belong in implementation tickets and should not hold the build.
