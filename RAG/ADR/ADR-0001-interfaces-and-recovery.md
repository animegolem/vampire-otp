# ADR-0001 — Court, Artifact, Lifecycle, Inference-Job, and Action Contracts

*Status: v0.3 — OWNER-RULED 2026-08-06; consistency check SETTLED same day; Gate 2 COMPLETE. **DECISION HISTORY ONLY as of SPEC-0001 rev 0.5:** the normative text of Decisions 1–7 is incorporated whole into `SPEC-0001.md` Appendix A (§A.1–A.8), which is the sole binding home. This file preserves the decision history, reversals, and update log per covenant; amendments to the contracts happen in SPEC-0001, never here.*

*Ruled ticket boundary: heartbeat timings, GC intervals, database indexes, and the BLAKE3-vs-SHA256 benchmark are implementation-ticket decisions and do not return for constitutional ruling.*

## Context

Build Plan v0.3 binds the architecture; this ADR specifies the crash-state interfaces that gate implementation. v0.2 tightened v0.1's six contracts; v0.3 adds the four ruled amendments: episode identity invariants, the factorized action/attempt status model with a transactional dispatch guard, crash-safe two-phase artifact deletion, and process-confirmed Metal fencing with claim-based admission. No architectural choice changed.

## Decision 1 — Event envelope (v0.3: restored self-contained)

Every court event carries:

- `event_seq` — court-assigned monotonic integer at commit; the total order of the log.
- `event_id` — producer-minted ULID; globally unique; the idempotency anchor for re-scans and retries.
- `event_type`, `schema_version` — the event's name and the version of its payload schema.
- `occurred_at` / `recorded_at` — producer clock vs court commit clock; both kept because they legitimately differ.
- `actor` — the principal that caused the event (owner, resident, broker, worker id, recovery).
- `causation_id` — the `event_id` that directly caused this event; `correlation_id` — groups a causal family (batch, episode workflow).
- Lifecycle refs — `resident_id`, recording `incarnation_id`, and where relevant `session_id`, `episode_id`, `segment_id`, `window_id`, `tick_id`, `turn_id`.
- `payload` — domain content under the declared schema version.
- `artifact_refs` — algorithm-qualified content addresses this event references.

Domain events only. **Corrections are new events** that reference the corrected event via `causation_id`; committed rows are never mutated — no `UPDATE`, no `DELETE`, ever (v0.3, per review).

## Decision 2 — Lifecycle topology (v0.2 aggregates; v0.3 identity invariants)

- `resident_id` is the root; **every event belongs to exactly one recording `incarnation_id`**.
- **Sessions and episodes are durable aggregates** with *activity segments*. A segment occurs during exactly one incarnation and one session; an episode may have segments across several of each. Sessions and episodes are not globally nested in either direction.
- **Identity invariants (v0.3, ruled):** every segment has a stable `segment_id` plus a court-assigned `segment_n` unique within its episode; **at most one segment of an episode is active at a time**; resume is a compare-and-set from `interrupted`/`suspended` to `active`; a completed or abandoned episode can never be resumed; **the episode's `goal_digest` is immutable**. `episode_resumed{episode_id, segment_n, goal_digest}` records the digest it verified.
- **Changed goal ⇒ new episode**, linked with `supersedes_episode_id` or `derived_from_episode_id`. Owner approval governs undertaking the new goal — never rewriting the identity of the old one.
- Each `window_id`, `tick_id`, `turn_id` belongs to exactly one incarnation and, where relevant, one session/episode segment (carried from v0.2).
- Crash recording: the next boot emits **`incarnation_crash_inferred{orphan_incarnation_id}`** — never a synthesized `incarnation_ended`. The absent terminal event *is* the evidence; the inference is recorded as an inference.
- **Resuming cognition is not authority to resume machine effects.** `episode_resumed` by policy for low-risk, explicitly-resumable work after action reconciliation + freshness checks; owner approval required when the episode holds an unresolved non-idempotent action, its resume lease expired, or its risk class is owner-gated. Every subsequent action passes through the broker regardless.

## Decision 3 — Action status, approval, and dispatch (v0.3: factorized + transactional guard)

**Action envelope (immutable):** unchanged from v0.2 — `action_id`, `schema_version`, capability, operation, canonical arguments or `args_ref`, preconditions + freshness rules, risk class, reversibility, expected postcondition, compensation, timeout, `on_failure`, stable idempotency key, mandatory reconciliation strategy, and **`action_digest`** over every authority-relevant field. Any authority-relevant change ⇒ new digest ⇒ new approval.

**Approval:** references `action_id` **and** `action_digest`, plus approving principal, policy/grant version, creation time, expiry, and restart policy.

**Status model (v0.3, replaces v0.2's core-states-plus-holds — reversal preserved):**

```text
action.phase       = proposed | approved | active | resolved
action.resolution  = succeeded | failed | denied | cancelled | expired | abandoned | null (until resolved)
action.blockers    ⊆ {needs_owner, unverified, approval_blocked, ...}
attempt.state      = claimed | dispatched | succeeded | failed | outcome_unknown
```

- `outcome_unknown` is a core **attempt state**, not an action hold.
- `abandoned` is a terminal **resolution** reached by the doubt gate's stopping rule, reason recorded. (v0.2 modeled it as a hold — reversed.)
- `approval_invalidated` is an approval **event** that derives an `approval_blocked` blocker.

**Dispatch guard (normative, single predicate):** an action may dispatch only when (i) `action.phase = approved` and `action.resolution = null`, (ii) a currently valid approval binds its exact `action_digest`, (iii) its preconditions are fresh per their rules, (iv) `blockers = ∅`, (v) its batch is open, and (vi) no unresolved attempt forbids another attempt. **Guard evaluation and the attempt claim are one transaction:** phase, resolution, blockers, and the claim compare-and-set live in the same court aggregate row. Checking the guard and claiming the attempt as separate steps is non-conformant — that gap is precisely the race this decision exists to close.

**Dispatch:** each execution gets an `attempt_id`; retries keep action + idempotency key, new attempt.

**Recovery (normative):**
1. On restart, a `dispatched` attempt without a terminal event ⇒ `outcome_unknown`.
2. A **non-idempotent** `outcome_unknown` attempt is **never automatically retried**; it derives `needs_owner` with full context.
3. An idempotent unknown reconciles by key (⇒ `succeeded{reconciled: true}`) or retries per policy up to the doubt-gate stopping rule.
4. **Approval invalidation, not reversion:** recovery emits `approval_invalidated{reason: restart}`. Policy-granted low-risk approvals re-evaluate and may immediately re-approve if digest, policy/grant version, freshness, risk, **and — for actions within a resumed episode — the episode's `goal_digest`** (v0.3) still match. Owner approvals do not survive restart by default; never for stale, irreversible, high-risk, or `outcome_unknown` work.
5. Batches are correlations, not transactions; any non-idempotent `outcome_unknown` member halts further dispatch from that batch.

## Decision 4 — Artifact store (v0.3: two-phase deletion)

Content-addressed with **algorithm-qualified identifiers**; M1 default `sha256:<hex>` (BLAKE3 migration is an implementation-ticket benchmark per the ruled boundary).

**Reference resolution — externally stable states:** `available` | `tombstoned` | `missing` (⇒ `integrity_fault`), with **`deletion_pending`** as the durable transition state (v0.3).

**Durable publication:** staging file on the destination filesystem; write → fsync file → atomic rename → fsync containing directory → only then commit the referencing event.

**Two-phase deletion (v0.3, ruled):**
1. Commit `artifact_deletion_requested{authority, hash, reason, retention_policy_version}` — the artifact enters `deletion_pending`.
2. Delete the bytes; fsync the containing directory.
3. Commit `artifact_tombstoned` as completion.

Recovery: request + bytes present → retry deletion; request + bytes absent → commit the tombstone completion; bytes absent with neither request nor tombstone → `missing`/`integrity_fault`. The court can now never claim privacy-sensitive bytes are gone while they survive a crash, and never faces an unexplained absence it authorized.

**GC:** reachability + leases, unchanged from v0.2 — an orphan is collectable only when no live event, projection version, retained snapshot, or research branch references it; no active writer lease can still publish it; and it survived one complete mark pass after lease expiry. Grace bound `≥ max_writer_lease + 2 × gc_scan_interval` (interval values are implementation-ticket decisions). Snapshot manifests participate in the artifact root set. Privacy deletions use the two-phase protocol and do not wait for GC.

## Decision 5 — Inference jobs (v0.3: claims-based admission + generation fencing)

Job: `job_id`, **`resource_claims`** (v0.3 REVERSAL, replaces singular `resource_class`: a claim set — backend `metal|cpu|network`, `estimated_unified_memory_bytes`, threads, …; on unified-memory hardware admission is capacity arithmetic against real headroom, not category matching), `estimated_cost`, `deadline`, `priority_lane`, `cancellation` mode, **`request_ref`** (replacing `prompt_ref`: a normalized request artifact — model/weights digest, runtime + template versions, sampling params/seed, input artifact refs, output schema, context policy — reproducible *input provenance*, no promise of bit-identical output), `result_ref`(s). **Each execution carries `attempt_id`, `lease_id`, and `runtime_generation`** (v0.3).

**Generic lease rule (all backends — the floor, carried from v0.2):**
1. Heartbeat loss ⇒ attempt marked `suspect`; cancellation/termination sent.
2. Lease revoked with a **monotonically increasing fencing epoch**. For process-based runtimes, `runtime_generation` is that epoch's concrete implementation — monotonic per runtime start.
3. Requeue on the same constrained resource only after the worker is confirmed stopped or the lease expires under a backend-specific safety rule (Metal's rule below **closes the expiry branch entirely** for that backend).
4. Late results from stale epochs are **rejected as selectable results, retained as attempt artifacts** for audit.

**Metal rule (v0.3, ruled — the backend-specific safety rule for this machine, specializing the floor):**
1. Model compute runs in an **out-of-process runtime** (never inside an unkillable BEAM NIF when recovery depends on fencing it). Each runtime process/group carries a `runtime_generation`; every lease carries that generation.
2. After the missed-heartbeat threshold: all attempts on that runtime → `suspect`; stop new admission; request cooperative cancellation / SIGTERM.
3. After bounded termination grace: SIGKILL the process group.
4. Requeue onto Metal only after **confirmed stop — `waitpid` returns / the BEAM Port reports closed AND the OS confirms the PID is gone** — a replacement runtime starts at a higher generation, a health probe succeeds, **and** a unified-memory headroom check passes before re-admission (a leaked allocation from the dead attempt shows as missing headroom; below threshold ⇒ delay admission rather than stack a model load onto poisoned memory). **Lease expiry alone never authorizes Metal requeue — Metal has no cross-process fencing; the process is the fence.**
5. If death or health cannot be confirmed: mark the Metal resource unavailable; degrade to an allowed CPU/network route or surface the failure. Never requeue onto the suspect runtime merely because time passed.
6. Results carrying a stale `runtime_generation` are retained as attempt artifacts, never selectable.
7. **Shared failure domain:** one runtime hosting multiple jobs loses them together — all its active attempts go `suspect` as a unit; the scheduler accounts for this at admission.

Inference remains **retry-safe, not idempotent-by-construction** (reversal preserved from v0.2). All attempts preserved; explicit **`result_selected`** names the winner.

## Decision 6 — Projection registry (unchanged from v0.2)

`projection_created{projection_id, projection_type, schema_version, version, content_ref, source_refs | source_ranges[], producer request/model/prompt refs, cursor?, precision/trust, status}`; `projection_superseded` for supersession. Rolling views publish versioned materializations or cursor advances; sparse-citation projections list refs rather than faking a contiguous range. Projection content is never reasserted as source truth (Law 1); the registry records lineage and existence only.

## Decision 7 — Recovery oracle (v0.3: deletion clause)

Pass criterion: **replaying the maximal committed event prefix produces exactly the canonical derived state for that prefix; every externally ambiguous attempt is represented as `outcome_unknown`; every artifact reference resolves `available` or `tombstoned`, or is `deletion_pending` with its authorizing request event and resolves per Decision 4's recovery rules; no uncommitted state is invented.** ("Equals pre-kill state" remains rejected — pre-kill memory legitimately held work that never durably committed.) Broker-action recovery testing belongs to M2; M1 may include a synthetic action aggregate solely to exercise the court contract.

## Consequences

M1's SIGKILL test adopts Decision 7's oracle including the `deletion_pending` clause. M2's broker implements Decision 3 whole — the transactional dispatch guard is its first correctness obligation. The scheduler's first ticket lands `resource_claims` admission, `runtime_generation` fencing, and `result_selected`. The vampire's hour writes verdicts into episode terminal events. Track V audio rides Decision 4's two-phase deletion path.

*Update log: v0.1 — initial six contracts. v0.2 — eight review amendments (action/attempt split + digest-bound approvals; invalidation semantics; aggregate topology + crash_inferred; worker fencing + retry-safe framing + request_ref; three-state resolution + directory fsync; reachability GC + snapshot roots; full projection descriptors; corrected recovery oracle; SHA-256 qualified hashing). Reversals: "idempotent by construction" (D5), "strict nesting" (D2), "replay equals pre-kill" (D7). v0.3 — OWNER-RULED: episode identity invariants + immutable goal_digest (D2); factorized status model + transactional dispatch guard + goal_digest in re-approval matching (D3); two-phase deletion + deletion_pending (D4); Metal generation fencing + shared failure domain + out-of-process runtimes (D5); Decision 1 restored self-contained with append-only correction rule; round-2 review-request section retired (all three answered). New reversals preserved: "holds" model (D3, v0.2 → factorized v0.3); `resource_class` (D5, v0.2 → `resource_claims` v0.3). Consistency-check repairs (same day, Sol's mechanical check, six items, no design change): D3 guard gains explicit `phase = approved ∧ resolution = null` terms; D5 generic lease floor restored with `runtime_generation` named as the fencing epoch's process-runtime form; `request_ref` contents and Metal confirmed-stop evidence + headroom check restored; D2 window/tick/turn invariant restored; build-plan lines 72/99 + M4.5 tombstone shorthand synced. Second sweep (four build-plan adjacencies): scheduler paragraph → `resource_claims`; M1 whole-VM test scoped to synthetic action aggregate per D7 (real broker recovery = M2); M3 episode nesting rewritten in D2 segment terms; Gate 2 relabeled "ADR contracts ready" — closes the design gate only, implementation authority still requires DQ-002.*
