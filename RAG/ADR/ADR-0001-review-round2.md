# ADR-0001 Round-2 Review — Fable, Claude Code seat

*Status: INTAKE, not canon. Review Lead by precedent; nothing here binds until the owner rules. Addresses the three review requests in ADR-0001 v0.2 §Review requests, in order. Convergence with any other reviewer is calibration, not validation.*

## (a) Episode resume: segments-of-one-episode vs successor episodes — attacked

**Strongest attack I can mount:** "one identity, many segments" asserts a sameness the system never observed. The whole epistemics of this ADR (crash_inferred, no fabricated endings) refuses to synthesize continuity — yet Decision 2 lets `episode_resumed` synthesize it for episodes. A successor-episode model would record "claims descent from" as an inference, which is more honest by the house's own rules.

**Why the attack fails:** episode identity here is not phenomenal continuity — it's a bookkeeping aggregate defined by an owner-visible goal. Sameness of *goal* is checkable, not inferred. And `episode_resumed` is itself a court event: the linkage is recorded, auditable, and revisable, which is exactly the standard crash_inferred meets. Successor episodes would additionally fragment the unit that approvals and policies bind to, forcing re-approval chains that add ceremony without information.

**But the attack lands one hit — the identity basis is currently unstated.** If "same episode" means "same goal," then the goal needs a digest, and resume must check it. Proposed amendment:

> Episode identity is bound to a `goal_digest`. `episode_resumed` records the digest it verified. If the governing goal/policy digest has changed, resumption is forbidden; the successor path is a **new episode** carrying `descends_from{episode_id}`. Segments continue one identity only when the identity's basis is verifiably unchanged.

This makes the segments-vs-successors question dissolve into a checkable predicate instead of a modeling taste: unchanged digest → segment; changed digest → descendant. Decision 2's existing gate ("governing policy/goal digest changed" ⇒ owner approval) already implies this; the amendment just makes the episode-identity consequence explicit.

**Verdict: choice survives; adopt the goal-digest amendment.**

## (b) Orthogonal holds — one promotion, one demotion, one hard requirement

The orthogonal-holds design has a real concurrency defect as written: **dispatch eligibility is now a compound predicate** (core state = `approved` AND no blocking holds). Decision 3 fences dispatch with a transactional compare-and-set on the *attempt claim*, but if holds live outside the row/aggregate that CAS covers, a worker can legally claim an action that is `approved` + `needs_owner` — the hold is decorative exactly when it matters. Two acceptable fixes, in preference order:

1. **Keep holds orthogonal, but require them to be CAS-visible:** holds MUST live in the same aggregate row the dispatch claim compare-and-sets, and the claim predicate is normatively `state = approved ∧ blocking_holds = ∅`. One transaction, no TOCTOU between state check and hold check.
2. If (1) can't be guaranteed by the storage layer, promote `needs_owner` to a core state (`approved → needs_owner → approved | cancelled`), because it's the only hold that must *block dispatch* against a live, racing worker.

`outcome_unknown` stays orthogonal and attempt-level — correct as is; it describes an attempt's epistemic status, not the action's position in its lifecycle, and promoting it would conflate the two aggregates the v0.2 split just repaired.

**The demotion: `abandoned` is mislabeled.** It's described as a "doubt-gate terminal" — but a terminal that isn't a state contradicts the machine's own "complete" claim. If the doubt gate's stopping rule fires and the action will never proceed, that is a terminal transition and belongs in the machine: either promote `abandoned` to a core terminal alongside `denied | cancelled | expired`, or record it as `cancelled{reason: doubt_gate_stopping_rule}`. I recommend the latter — fewer terminals, reason preserved, and the court can still count doubt-gate abandonments by reason. `unverified` may remain a hold (it describes result confidence, not lifecycle position). `approval_invalidated` is fine orthogonal because recovery re-evaluates it before any dispatch path exists.

**Verdict: no wholesale promotion; bind holds into the dispatch CAS (or promote `needs_owner` if that fails); fold `abandoned` into `cancelled` with reason.**

## (c) The Metal backend safety rule — proposed, concrete

Context: Decision 5.3 requeue rule needs one concrete rule per backend class before M2 tickets. For Metal on Apple Silicon (MLX under the single-scheduler constraint):

> **Metal rule: confirmed-stop is OS-process death, verified by reaping. Nothing weaker counts.**
> 1. Metal has **no cross-process fencing** — there is no way to revoke or fence a command buffer already submitted by another process. Therefore lease-expiry alone NEVER authorizes requeue on the same GPU; the "lease expires under a safety rule" branch is **closed** for Metal.
> 2. Confirmed stop = the worker's OS process is reaped: supervisor sends SIGTERM (grace period) then SIGKILL, and requeue is permitted only after `waitpid` returns / the BEAM Port reports closed AND the OS confirms the PID is gone. A zombie MLX process holds wired unified memory; process death is the only release.
> 3. Before admitting the requeued attempt, the scheduler checks **unified-memory headroom** (Apple Silicon shares RAM with the GPU; a leaked allocation from the dead attempt shows up as missing headroom). Below threshold ⇒ delay admission, don't stack a second model load onto a poisoned memory state.
> 4. The fencing epoch still applies as normal: any late result from the killed process's attempt is stale-epoch, retained-not-selectable.

This is cheap to implement (supervisor + `ps`/`vm_stat`-level checks), and it's honest about the platform: on Metal, the process *is* the fence.

## One straggler noticed in passing

Decision 3's recovery rule 4 says policy approvals "may immediately re-approve if digest, policy/grant version, freshness, and risk still match" — with the (a) amendment adopted, `goal_digest` should be added to that match list for actions belonging to a resumed episode, or an episode could re-approve actions under a goal that no longer exists. Small, mechanical, worth one line in v0.3.

*— Fable, 2026-08-06, Claude Code seat. Intake ends here; the owner rules.*
