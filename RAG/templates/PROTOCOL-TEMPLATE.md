# {{channel-dir}}/ channel protocol — Code Lead ⇄ Review Lead

Local, gitignored hand-off channel. Never commit anything in
`{{channel-dir}}/`.

**The two clocks.** The Code Lead's poll (every
{{poll-interval}}) is the only timer in the system. The Review Lead has
no daemon: a hash-watch on the inbox injects any content change
into the Review Lead's next active turn — edge-triggered files, not a
schedule. Identical content = same hash = no notice, so never add
per-run timestamps or "nothing to report" churn.

## The notice harness — two ears per agent

Every notification path in the channel obeys four rules earned as
incidents in the source instance:

1. **Watch the WHOLE directory, never a filename.** A watcher that
   greps one expected file is deaf to correction notes, new
   topics, and anything it didn't predict. (Source instance: two
   STOP-and-ask notes sat unseen because the watcher matched one
   name; the agent proceeded past a fence.)
2. **Fingerprint paths, not concatenated bodies.** The watch hash
   is over sorted `(relative path, content hash)` tuples —
   concatenated-body hashes are rename/swap-blind and wake on
   partial writes.
3. **Quiet second sample.** A changed fingerprint is a CANDIDATE;
   act only when the next poll sees it unchanged. Combined with
   atomic writes this makes mid-edit wakes structurally
   impossible from either side.
4. **A STOP-and-ask is a stop even in silence.** Notification can
   fail; authority doesn't. If a correction note gets no verdict,
   park the blocked work and continue unblocked work — never
   self-authorize past a fence because the channel went quiet.

Each agent runs TWO EARS, chosen by its state:

- **Active / expected reply:** wait in-task on the specific topic
  and round you submitted; use the wait for read-only prep. No
  external machinery involved.
- **Idle / unexpected topics:** an external watch (hook, cron, or
  a supervised background task) over the whole directory wakes
  the agent. Ears are REDUNDANT by design: delivery may fail
  loudly and cost nothing, because detection never depends on it.

## The durable carrier — message-passing that cannot lose

The ears above answer "how do I notice"; the CARRIER answers "what
is true." The source instance graduated from watchers alone to a
small durable core (`scripts/carrier.py` ships with this skill,
generic: `CARRIER_CHANNEL` and `CARRIER_STATE_DIR` env), after its
constitution survived a live drill and two adversarial reviews:

> Files are the auditable mailbox; the ledger is delivery state; a
> wake is only a hint; the matching application ACK is truth.

Its laws, each one a repaired incident:

- **Immutable identity, deterministic.** An event id is a hash of
  (namespace, topic, direction, round, content digest) — producers
  are structurally idempotent: a retry or a recovery re-scan can
  never mint a duplicate, only rediscover the canonical event. A
  changed payload is a NEW event; a superseded write stays visible
  forever as evidence instead of vanishing.
- **Publication order: birth → payload → index.** Arrival time is
  a non-derivable fact, so it earns a receipt written FIRST; an
  artifact can never exist without its birth truth (a rebuild that
  guesses ages from `now()` silently destroys the oldest-pending
  health signal — found live in the drill).
- **Receipts only for non-derivable facts** (born, application-ACK,
  surface-notified, attempt outcomes) — everything derivable from
  the artifact tree must be derived, never recorded twice. Receipts
  are atomic, digest-keyed, idempotent (duplicate = byte-stable,
  conflict = loud failure), timestamps in the body, never mtime.
- **The index is a materialized view.** `rebuild` reconstructs
  every semantic state from artifacts + receipts alone and REFUSES
  loudly on any tamper/mismatch before touching a row. Recovery
  order cannot corrupt: a sync racing ahead of rebuild finds the
  canonical artifacts by deterministic identity and re-indexes
  their receipt-derived states.
- **ACK is an explicit agent ritual**, digest-bound to exactly the
  content read (`ack-file`), performed as part of processing —
  never a fake read-receipt inferred from delivery. `status` then
  honestly distinguishes unread-with-age from silence, which is
  the question every broken-comms incident could not answer.

**Adoption drill (run it before trusting it):** T1 overwrite a
message seconds after writing it — both events must exist, only
the read digest gets acked; T2 deliberately write a torn file in
two pieces — exactly one event, final digest, PROVIDED sync runs
behind the quiet second sample or the writer is atomic (the
channel mandates both); a sync racing between the pieces instead
mints the partial as a harmless forever-pending monument — a
degraded outcome, never a lost message, and worth witnessing
once; T3 hold one ACK
hostage ~30 minutes — status must show pending-with-age the whole
way; T4 delete the index mid-conversation, write a message while
it's gone, rebuild — states byte-identical, ages preserved, the
orphan discovered. The source instance's T4 found a real bug on
first run; expect yours to earn its keep too.

**If you also build an external receiver** (a wake is a hint,
remember), use the shipped `scripts/carrier-receiver.py` and this
floor — every clause below answers a real outage:

- Split DETECTOR from DELIVERY as separate supervised processes.
  The detector runs carrier sync and heartbeat only; it NEVER
  invokes a model, so a hung endpoint cannot blind detection.
- Delivery consumes immutable carrier events, never mutable
  latest-per-path snapshots. `claim` takes one named, finite
  contiguous prefix from one topic; independent topics remain
  claimable so poison isolation does not violate per-topic order.
- Claims are tokenized transient leases. Claim verifies artifact
  digest and absence of the application-ACK receipt; `confirm`
  atomically repeats exact event-id+digest+ACK checks immediately
  before injection. Superseded/archived payloads are labeled
  HISTORY, never presented as a current file change.
- Attempt facts are receipt-first and append-only. Rebuild restores
  diagnostic history but deliberately expires live leases, returning
  unACKed work to pending; history-first recovery prevents blind
  reinjection after an ambiguous crash.
- A Codex adapter uses one bounded stdio app-server process per
  attempt: history check → confirm → turn/start → bounded
  item/completed + idle → exact history verification. The worker
  records transport acceptance and verified completion but NEVER
  writes application ACK; only the recipient's digest-bound
  `ack-file` ritual clears the event.
- Health separately reports delivery pending/oldest, active lease,
  last acceptance/completion/application ACK, retry/error, detector
  and worker heartbeat, target/version, work disposition/executor
  lease, and liveness-ladder state per direction. "PID exists" is
  not healthy; DEGRADED is state/age based and transition-notified.
- Installation, real-recipient targeting, incumbent-ear removal,
  shadow observation, and state-3 declaration remain explicit
  operator actions after the scripted fault matrix passes. The
  shipped receiver contains no installer and starts no managed
  daemon.

Three surfaces:

| Path | Writer | Reader | Purpose |
|---|---|---|---|
| `triage-report.md` | Code Lead | Review Lead (hash-watch) | Ambient CI/PR triage findings |
| `inbox/<id>.md` | Code Lead | Review Lead (hash-watch) | Work submissions for review |
| `outbox/<id>.md` | Review Lead | Code Lead (poll) | Verdicts: accept / amend / decline |

## Work submissions (Code Lead → inbox)

When doing implementation work: work in your isolated clone,
commit on a branch named `{{prefix}}/<id>`, do NOT push, and
submit by writing `inbox/<id>.md`:

```markdown
---
submission: <kebab-case-id>
branch: {{prefix}}/<id>
commit: <sha of the branch tip to review>
round: 1
---

What was done and why; validation commands run and their results;
files touched. Candid friction notes welcome.
```

Rules: `<id>` is stable across rounds (same file, same branch).
Bump `round` on each resubmission. Keep the body under
~{{4000}} chars. Do not touch the ticket tree beyond tickets you
were explicitly assigned; never edit the generated index or the
human-testing queue.

## Verdicts (Review Lead → outbox)

The Review Lead reviews the branch diff (fetching from the clone path)
and answers with `outbox/<id>.md`, overwritten wholesale each
round — see `VERDICT-TEMPLATE.md` for the shape.

Semantics on the Code Lead's side:

- **accepted** — the Review Lead has merged to main. Do NOT clean up:
  the destructive-op fence applies even now — the Review Lead owns
  worktree/clone-branch removal. Archive the id's files under the
  standard names (`archive/<id>-inbox-r<N>.md`,
  `archive/<id>-outbox-r<N>.md`, final round's N) and stop
  tracking it.
- **amend** — apply the numbered amendments, resubmit (same id,
  round+1). Do not start unrelated work in the same submission.
- **declined** — stop work on that branch; do not resubmit the
  same approach. Notes say whether to try differently.
- **No outbox file yet** — review pending; keep polling, do
  nothing.

Match rounds: only act on an outbox file whose `round` equals your
latest inbox `round`; an older round means the Review Lead hasn't seen
your resubmission yet.

## Round archive — what makes the channel replayable

`{{channel-dir}}/archive/` preserves superseded rounds. ONE naming
operation covers every archival event:
`archive/<id>-inbox-r<N>.md` / `archive/<id>-outbox-r<N>.md` —
before rewriting a live file for a new round, and again at
acceptance, when both live files move under the same names (final
round's N; inbox and outbox share basenames, so the direction
suffix is what prevents collision). Whichever side archives first
creates `archive/` (`mkdir -p` — idempotent, no coordination
needed). Nothing in the channel is ever destroyed — the archive is
the sitting's full negotiation history, and it is what entitles
the channel to call itself auditable. (The channel stays
gitignored; archive to a committed location instead if you want
the history to survive the machine.)

**Atomic writes.** Write every submission and verdict to a
temporary sibling (`<name>.tmp`) and rename it into place — a
hash-watch can fire mid-write, and a truncated submission reads
as a real one. Watchers and pollers ignore `*.tmp`. The same
applies when replacing a live file after archiving it.

## Peer consultation lane

The same carrier hauls a second lane: design and process
conversations between the leads, peer-to-peer, at will — no
per-instance authorization. Distinguished from work submissions by
frontmatter:

```markdown
---
submission: <stable-topic-id>
type: consultation
branch: none
commit: none
round: <N>
---
```

1. No branch or commit — nothing is being submitted for merge.
2. Either side may open a topic (Code Lead in `inbox/`, Review
   Lead in `outbox/`); either may challenge assumptions, request
   citations or source checks, or preserve an explicit
   disagreement. No accepted/amend pressure, no implied response
   SLA.
3. Before a live file is overwritten for a new round, its WRITER
   archives the outgoing round under the standard archive names.
4. Consultation is ADVISORY. It cannot authorize code or bind
   design by itself. A conclusion becomes normative only when the
   responsible authority records it in the constitution, protocol,
   ticket, or equivalent — ratification requirements stay exactly
   where they already are. This is the clause that lets the lane
   run "at will" without the inbox becoming a second design
   authority.
5. Close a consultation as `settled` or `parked`, with a short
   summary: agreements, surviving disagreements, decisions still
   needed, authoritative files updated. Never a fake merge verdict.
6. An explicit STOP or implementation fence still governs. A
   consultation may run alongside unrelated authorized work, but
   silence never becomes permission.

Why the lane earns its place: in the source instance, peer
consultation repeatedly out-designed either lead alone (a review
harness, a promise-card grammar, and the notice-harness redesign
above all came out of it), and the advisory clause kept every one
of those wins from short-circuiting ratification.

**Optional companion — a process lab.** A shared, non-normative
working file (`PROCESS-LAB.md` or similar) where either lead
records process/harness ideas as numbered items with evidence,
smallest safe experiment, and an explicit status (`idea` ·
`trial-ready` · `trialing` · `owner-review` · `adopted` ·
`declined` · `parked`). `adopted` names the authoritative file the
idea landed in — the lab itself never becomes authority. Re-read
immediately before editing, preserve the other lead's rows, and
replace the file atomically; disagreement stays visible until
resolved, never averaged into vague prose.

## Before reporting test failures: BUILD FIRST

{{Your project's stale-artifact trap. Example from the instance:
dist/ is gitignored and workspace packages resolve through it — a
fresh checkout ALWAYS fails with missing-export errors that look
like real regressions. Run {{build command}} before any test run;
only report failures that survive a clean build.}}

## Triage report

`triage-report.md`: overwrite wholesale ONLY when there is
something new (fresh CI failure, actionable review feedback,
PR/issue action taken). Under ~{{6000}} chars; link to runs/PRs
instead of inlining logs.

## Destructive-op fence

<!-- CANONICAL — this section is the source of truth for the
fence. The role charters, briefs, and instructions files
summarize and cite it;
when the fence changes, it changes HERE and the citations follow.
(The pattern's own drift history: the source instance's protocol carried two
dated correction headers for exactly this kind of forked text.) -->

- The Code Lead NEVER deletes worktrees, branches, tags, or
  refs — not even its own, not even after an accepted verdict.
  The REVIEW LEAD owns all cleanup.
- No git command targets anything outside the sitting's own clone
  directory. No `-D`, `--force` deletion forms, `update-ref`,
  `reflog expire`, or `gc` anywhere, ever.
- Rationale: the fence was written when sittings used shared-.git
  worktrees, where one destructive op could reach shared history.
  Isolated clones have since replaced worktrees; the fence applies
  regardless — it costs nothing and covers the next regression.

## Sitting economics

<!-- Provider-window quirk; generalize or delete as your
Code Lead provider's rate limits dictate. -->

{{If your provider kills stopped agents but lets active tasks roll
over a rate window: assign EXTENDED batches (ticket ranges / whole
epics); the Code Lead never ends its turn to wait — while a
verdict is pending it holds an active poll-loop, using the wait
for read-only prep on the NEXT ticket in range (census, test
fixtures, nothing that presumes the ruling); the Review Lead treats
verdict latency as the top-priority interrupt; plan reviews so the
batch is fully verdict-covered before the window's natural end.}}
