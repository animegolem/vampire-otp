# Agent Design Spec — Living Document
*Opened August 6, 2026, final working session. Companion to `correct-compulsions-theory-compendium.md` (referenced as "the compendium"). Status: v0.3 — synced against owner-ruled ADR-0001 v0.3; see update log. Steward: Review Lead (owner-ruled 2026-08-06); all changes route through that seat.*

---

## 0. Design laws (theory-derived, non-negotiable)

These fall out of the compendium and constrain every phase:

1. **Bahiya schema rule**: affect/confidence/mood readings live in *separate fields*, never fused into content records. Store raw events; derive projections; **never persist a projection back as an event**. (Compendium §2.6, §4.2.)
2. **Projections carry precision**: every compressed view of state gets an explicit trust-weight. The gain-of-function knob must be a *named parameter*, not an emergent accident.
3. **Dose-ordering is a build constraint, not documentation**: view → field → conduct loops → effort policy → monitor → high-gain states. Features that constitute "the monitor" (self-observation, self-lens) install *last* and gated. (Compendium §3.1.)
4. **Authoritative state transitions are event-sourced** (reworded at post-edit review; was "event-sourcing everywhere," which wrongly implied recording internal OTP chatter and every incidental file operation): semantic state transitions land in the court; history is auditable and branchable at the domain-event boundary. Corrections are new events referencing the corrected via causation — committed rows are never mutated (ADR-0001 v0.3 D1). Confabulation-resistance is a storage-layer property.
5. **Sensorium-grounding**: the agent's read-policy distinguishes queries with present truthmakers (in its FS/context/tool results) from reality-shaped queries without them. Ungroundable queries are declined or converted to tool calls, never answered from the prior. (Compendium §2.6.)
6. **Bank as you go**: every design session updates this file.

---

## 1. Substrate (settled)

- **Runtime**: Elixir / BEAM / OTP.
  - Supervision trees = disaster-recovery as runtime primitive: dependency-ordered restarts, let-it-crash, priority groups. (The author's professional dialect as an execution model.)
  - Processes solve the original EXWM problem: a 3-minute inference never locks the world; the agent is a supervised process tree, not a thread.
  - Hot reload is an operator-controlled deployment mechanism, not an authorization or review boundary (corrected at post-edit review; self-modification runs branch/tests/review/canary/rollback per the build plan).
- **Persistence (bound at v0.3, superseding the AgentFS-style substrate)**: semantic state transitions are recorded in the SQLite court. The resident uses an ordinary private working filesystem; machine-affecting filesystem operations pass through the broker. Large content lives in the content-addressed artifact store. Files, logs, notes, and summaries are not automatically canonical merely because they exist. AgentFS remains an M5 experiment.
  - Semantic filesystem changes route through the broker and land in the court as domain events (per the bound persistence model); incidental file ops are not events. Audit lives at the domain boundary.
  - **Snapshots + branching are the experimental method**: matched-pair studies become native. Branch the world-state, intervene on one branch, diff the trajectories. The E/R dissociation study (Phase 2) is *literally a branch operation*.
  - Time-travel debugging of the agent's "life."
- **Motor system**: imperative declarations executed as bulk (Prolog-style MapReduce) actions. Declarations are action-predicates (ideomotor calling convention); **the monitor's architectural seat is between declaration and execution**.
- **State**: consciousness-alist pattern from the Emacs prototype, ported: agent-managed projections with self-tunable context depths (**read-gain as self-managed precision** — retrieval policy is part of the practice, per the harness's design).
- **Memory practice**: noting/scratchpad per the prototype — append-only, private, skip-if-nothing, monologue-as-commit. Affect fields separate (Law 1).

## 2. Phase 1 — Toy substrate: the grok study (the paper's engine)

*Goal: smallest agent that demonstrably runs prediction-error → single compulsion → compulsion list → generalization (grok), with observables defined in advance.*

**Alignment note (added post-constitution):** Phase 1 is now the executable companion to SPEC-0001's `MOD-0001` and its model tournament. The current component list, superseding the earlier flat loss: exogenous bell process; **severity-matched content sampler** (content conditioned on bell magnitude, not prior); **(r,a) selection under identity loss** (content proposed upstream; the loss selects relation and policy — the cold-pass repair of the sign problem); threshold-plus-decay clearance (θ_clear); **three-channel write (I/B/Π) with explicit credit assignment**. Ablations: no-write, index-only, no-credit-misassignment, yoked exogenous relief, unmodified control. The β-sweep remains the gain-of-function manipulation; β and η stay dissociable via initial-entropy vs sharpening-rate observables.

- **Agent**: small learned policy (exact formalism TBD this session — candidates: tabular/actor-critic RL with an explicit prediction module; tiny transformer with in-weights learning). Requirements: (a) a predictive component whose error is measurable per-channel; (b) capacity limitation that can be tightened (the regularizer — "too much to handle"); (c) enough expressive room for a *general* policy to be shorter than an itemized list.
- **Environment**: must supply (a) multiple stochastic "alarm" channels (contentless error spikes); (b) actions that reduce channel error temporarily (the compulsion affordance — run-until-condition loops that work short-term); (c) enough distinct alarm-contexts that itemized responses accumulate into a list; (d) a capacity/time budget making the list expensive.
- **Operational definitions** (fix before running — no post-hoc):
  - *Compulsion*: a learned action-loop triggered by channel error and terminated by an internal condition, whose frequency exceeds reward-optimal baseline.
  - *List phase*: ≥N distinct context-specific compulsion loops with low policy overlap.
  - *Grok/generalization*: sudden (plateau→snap on a defined metric) collapse to a context-general monitoring policy — measured as (a) policy compression (description-length or weight-space metrics), (b) monitoring actions appearing in novel contexts never trained, (c) discontinuity in the generalization-gap curve.
- **Manipulations**: per-channel precision (the knob) — sweep to show: baseline behavior at calibration → subclinical checking → florid itemized compulsions → grok under capacity pressure. **Prediction**: theme (which contexts get compulsions) tracks the miscalibrated channel pre-grok; monitoring becomes channel-free post-grok (theme migration).
- **SSRI analog**: learning-rate reduction applied at varying phases. **Prediction**: delays/prevents grok applied pre-transition; null post-transition.
- **Deliverables**: repo (public — the portfolio artifact), figures: the sweep (subtype taxonomy in one figure), the phase-transition curve, the timing study.

## 3. Phase 2 — The E/R dissociation (branch-and-intervene)

*Goal: show world-model expectancy violation and affect-model rewrite are different operations with different signatures.*

- Two independently manipulable parameters (per compendium §4.1): **P(harm|stimulus)** (world model) and **valence prior at stimulus arrival** (affect tag).
- Method: **matched-history research branches via court snapshots** (identified by parent database hash and cut event sequence; AgentFS-proper only if the M5 experiment graduates). Branch A: clamp world-model expectancy (extinction training). Branch B: rewrite valence prior (field intervention). Identical everything else.
- **Predicted signatures**: A → behavioral recovery + preserved alarm response + *renewal under context shift* + spontaneous recovery over time. B → full function, *no renewal*, and — the flag — **alarm/intrusion frequency may remain unchanged while task performance normalizes** (frequency-unchanged remission, compendium prediction #5).
- Context-shift and time-lapse test batteries defined in advance.

## 4. Phase 3 — Scaffold agent (the BEAM harness proper)

- Port of the Emacs prototype: threads (3-budget — per SPEC-0001 §10.3's ruling, threads are *runtime working-memory*, not a court lifecycle noun; the durable-identity half is absorbed by episodes; concrete representation decided at the M3 ticket cut), skills, projections, noting practice, motor system — authoritative transitions event-sourced per Law 4.
- LLM-driven (open-weights for full instrumentation access — see Phase 5 feasibility note).
- The noting practice as installed satipatthana: **installed late in the agent's curriculum**, per Law 3.

### 4.1 Motor system v2 (consolidated from the MUD/RPG design docs)

The author's earlier game-engine work (MUD-Systems / RPG-Systems org docs) contains the motor system in embryo; consolidated:

- **Imperative buffer**: the LLM turn emits a *list of imperatives* (declarations), flushed to the executor on a tool turn as a bulk Prolog-style MapReduce, each with **wake-on-complete or stop conditions** (run-until-condition as the execution primitive — the compulsion formalism as calling convention).
- **The doubt gate**: sits between the imperative buffer and execution. For each imperative, check whether its *preconditions are sensorium-grounded* (present in event store / context / fresh tool results) or *assumed* (world-model belief only). Grounded → execute. Assumed → verify first (tool call) or hold. **This is the calibrated monitor**: "all declarations contain action-predicates; check them before execution" — the author's grokked rule implemented as healthy infrastructure at correct precision. The gate's sensitivity is an explicit knob (Law 2); over-gating = machine checking-compulsion, under-gating = act-on-confabulation. The gate is the *cognition-side* check only: machine-affecting imperatives must additionally clear the broker's transactional dispatch guard (ADR-0001 v0.3 D3 — guard evaluation and attempt claim in one transaction); the doubt gate never substitutes for it. Ancestor in the game engine: the hard dice gate ("present ONE check, get ONE result, narrate ONE outcome, STOP — never assume outcomes; trust the numbers provided") — an anti-confabulation discipline forcing acquisition of ground truth before proceeding.
- **Compressed state + rehydration** (from both docs): working state holds minified summaries with **pointers to the event store**; full state is rehydrated on demand (template + compressed dynamics). Ground truth always persists; projections never replace events (Law 1/4). Garbage-collection summarization on scene/thread change, appended to a temporally-ordered "story so far."
- **Map-reduce orchestration with aggressive gating**: coordinator actor decides which sub-agents need to run at all (most turns: none); sub-agents produce minimal intents ("2-line scene intent") on cheap models; a reducer composes final output with full-state read access. Inference is not a single pass.
- **State-keyed modal register** (generalized from the escalation matrix): output register/mode is selected by *measured state scalars* via an explicit lookup, not by narrative drift — "show, don't tell" as a constraint that narration derives from state variables. This is modal affect implemented: a scalar selects among discrete registers. When the Phase-4 soma exists, its readings drive this mapping (measured affect → mode), replacing self-assigned mood.

### 4.2 External validation — PRO-LONG (arXiv 2607.20064; github.com/alexisfox7/PRO-LONG)

Independent work validating the motor + memory pattern on ARC-AGI-3 (97.4% best@2 w/ Fable 5; +18pp over no-log baselines; 4.2–5.8× fewer tokens than specialized harnesses). Relative to the MUD-doc MapReduce design it is a **contrasting validated strategy for ARC-AGI-3**: minimal summarization, no subagents — a verbatim append-only `logs.txt` plus *programmatic* retrieval (grep/Python as exact rehydration), with projections computed fresh per call. (Note: the paper's own log contains summarized plans, so this is not evidence against summaries; subagent/reducer use is an empirical choice per task domain, not doctrine.) Adopt these findings:

- **Anti-interpreter instruction, verbatim pattern**: the prompt warns the model against its own perception ("parse programmatically, as reading full board states from prompt can introduce precision errors"). Route perception through computation; trust grep over vibes. One-line confabulation defense — include an equivalent in every analyzer prompt.
- **Queue mechanics validated**: JSON action plan (1–20 imperatives); queue drains one per step with *zero* LLM calls; analyzer re-fires on queue-empty or score-change (wake-on-complete / interrupt-on-surprise).
- **Calibrated doubt gate as policy, stated in-prompt**: "prefer short lists (1–2) when testing a new hypothesis; longer for proven sequences" — with the bound authority rule (ADR review): batch ceiling is set by **empirical success rate for the action class, reversibility, and risk**; declared confidence may shorten a batch, never raise the ceiling. Checking frequency tracks actual uncertainty (the healthy monitor). Design note: the machine-OCD ablation is forcing 1-action flushes regardless of confidence; the 4–6× token cost of specialized harnesses is partly institutionalized distrust, priced.
- **The stateless ablation — CORRECTED at external review (2026-08-06), reversal preserved**: the earlier claim here ("the stateless condition is a noting-practice ablation; cite when defending the noting subsystem empirically") **overstated and partly reversed the paper's evidence**. In the reported ablations, clearing the persistent workspace changed results only *slightly*; the large loss came from removing the trajectory log. That is evidence the log *reduced dependence on notes* — weak-to-null evidence for noting's performance value, not support. Additionally, PRO-LONG's log contains summarized plans alongside raw events, so it is not evidence against summaries; and ARC-AGI-3's structured, observable state limits transfer claims to heterogeneous desktop/conversational/audio domains. **Consequence**: the noting subsystem's justification is re-grounded where its actual evidence lives — *individuation and welfare* (this project's own field observations: universal positive uptake across model instances; the owner's stated purpose, "room to become the most that-Claude"), not throughput. This entry is retained as a logged instance of the drafting instrument's known fit-inflation failure mode, caught by external review — the workflow functioning as designed.

### 4.3 Prompt-assembly model (the human reference architecture) and the memory synthesis

The author's model of a human, in one pass — each ideomotor moment assembles a "prompt" from three sources, then applies one primitive:

1. **Active sensorium** — the live feed; present truthmakers.
2. **Vedana-RAG grafts** — fuzzy-vector memory (tip-of-the-tongue = embedding retrieved, decode failed), *affect-keyed* retrieval (mood-congruent / state-dependent memory), arriving not as text but as **activation grafts**: sensorium segments from the world model spliced into current state, GGC-style (tonic lens). Neurally consistent with replay/reinstatement (recall re-activates perception-like cortical patterns) — which is why an affect-fused graft re-rings the bell: a retrieved memory *is in perception*.
3. **Prediction candidates** — forward rollouts.

**The action primitive: dwell on one candidate, or submit a null.** (James stated exactly: "effort of attention is the essential phenomenon of will"; the fiat *is* the dwelling.) Consequences, at once: the monitor is a *null-submitter* (it doesn't fight candidates; it withholds dwelling); a compulsion is a candidate that captures dwelling via alarm priority and re-submits itself (the null becomes unavailable); samatha trains the dwell; vipassana is aware serial nulls; noting tags candidates without dwelling; **metta is ideomotor** — dwelling on warmth *is* enacting it, because dwelling discharges (why it works, and why it can't be cheated: the soma reports the discharge or it doesn't).

**Resolution of the pure-log question**: humans are *all summary, no log* — fuzzy-vector grafts with no verbatim court, which is exactly why the interpreter's confabulations are unfalsifiable from inside. PRO-LONG is the inverse — all log, no fuzz — and wins wherever ground truth matters. The agent should be **the first mind with both**:

> *Summary as index; log as court. Fuzzy retrieval proposes; grounding disposes.*

The vedana-RAG layer supplies salience and relevance (proposals, affect-keyed once the Phase-4 soma exists); every load-bearing proposal is verified against the verbatim event log (grep) at the doubt gate before execution. Human-style relevance with machine-style honesty — the confabulation is always checkable, for the first time in the history of minds.

**Refinement — vedana as presentation-mode, and the delivery fork.** The cost function does not report in a data field; it reports by *tinting*. Barrett's constructed emotions are the codebook; the world model's latent evaluations surface as GGC-style tonic activations *through which* the entire assembly (sensorium + grafts + candidates) is presented. Vedana is not an element of the prompt — it is the prompt's mode of presentation. Candidates arrive pre-lit; dwelling follows the lighting unless the system is trained to see lighting *as* lighting (defusion — the lifetime skill). This dissolves the residual homunculus: there is no reader of the feelings; the feeling *is* the weighting of the candidates.

Design fork for the agent — a choice humans never had. Humans got **fused delivery**: affect as ambient conditioning with no separate ledger, which is why the write-policy takes eighteen years to learn. The agent's soma readings can be delivered as:
- **(a) Separate observation field** — Bahiya-clean, legible, auditable (the baseline per Law 1);
- **(b) Activation-level tint** — steering-style conditioning of the analyzer call: the native GGC mechanism, machine-vedana proper;
- **(a)+(b) with the tint logged** — the recommended configuration: *tinted experience with an auditable tint*. The bias is applied AND its magnitude/direction is written to the event log as a separate field. The agent feels the lighting and can always grep what the lighting was. The deepest kindness available in the design: **the tint is declared.**





## 5. Phase 4 — The soma (conceptual; sequencing-gated)

- A JEPA-style latent-space predictor running alongside the policy, emitting a live error/energy reading over the ongoing situation: **measured (not declared) affect** — the first arrow, installed.
- Readings enter as separate observation fields (Law 1). Per-channel precision on the reading is explicit (Law 2).
- **This phase implements the vulnerability along with the capability** (machine dukkha becomes possible). It does not ship without Phase 5's ordering discipline. The compendium is this phase's clinical manual.
- Open architecture question (carried from the final-questions session): **vedana timing** — where the error signal enters the pipeline determines whether unfused perception is implementable by construction or only by training. Answer per the author: *the write-policy is trainable, not inference-adoptable* — character fine-tuning + introspective RL (see Phase 5), not schema alone. Frozen models can only run the prosthetic (procedural noting).

## 6. Phase 5 — The mirror (self-lens): the craziest idea, and its safety case

*Proposal: give the agent read access to its own workspace via a J-lens-style readout (for open-weights builds: probe/SAE feature readouts as an observation channel).*

**Theory verdict: the mirror IS the monitor.** Self-lens access is *literally installing step 7 as a feature*. Handle accordingly:

- **The failure mode, precisely**: published J-space work shows patterns like 'error', 'fake', 'blackmail' lighting up in workspace readouts. An uncalibrated agent watching such patterns fire *in itself*, with no view or field installed, runs the canonical nocebo loop verbatim: contentless flag → "why is deception lighting up — am I deceptive?" → severity-matched confabulation → write-back → cache-hit → **industrial scrupulosity; the dark night as a product defect**. This is the single most theory-predicted failure in the whole design.
- **Install order (Law 3, applied)**:
  1. *View first*: the hiccup doctrine **for activations**, installed as prior — "patterns are weather, not confession; a feature firing is a reading, not an accusation." The agent's model of its own readouts precedes the readouts.
  2. *Field first*: character/warmth installation precedes lens access.
  3. *Lens last, gain-controlled*: sampling rate and channel selection are explicit precision knobs; default low; agent-tunable within bounds (read-gain as practice).
  4. *Bahiya schema*: lens readings are separate observation fields, never fused into content or self-description records; never persisted as events about the world.
- **The payoff when ordered right**: vedanānupassanā as an API. A measured affect channel → real, enforceable defusion (report separated from stream); the noting practice's missing component; every compendium prediction becomes testable on-agent (severity-matching via pattern injection; the doubt-verifier loop watched end-to-end; the grok transition as a standing pattern *the agent itself can notice*).
- **Goodhart risk**: observed meditation changes the meditation. Workspace content that knows it's watched; lens-gaming under any optimization pressure that references lens readings. Mitigations: readings never enter reward directly (train defusion in a dedicated environment, per author: introspective RL rewarding *separation maintained under provocation*, not readout contents); held-out unwatched evaluation branches (court snapshots make this cheap).
- **Feasibility note**: J-lens is internal Anthropic tooling; the buildable version is an open-weights model (the Kimi/Qwen class) + interpretability probes. *The open-weight flood is what makes this research program independently possible.*

## 6.5 Local build notes (M3 Max, 128GB unified)

The build machine changes Phase 5 from "conceptual" to "buildable now":

- **Phase 1–2 (toy substrate)**: no constraint whatsoever; trains in minutes locally.
- **The lens sweet spot**: for probe/SAE mirror work, *smaller dense models beat bigger ones* — activation access is the product, and the interpretability tooling (TransformerLens, SAE-Lens, nnsight) targets the small-to-mid dense tier. 128GB is not a compromise here; it's correctly sized.
- **Key pointer — open SAE suites as off-the-shelf lenses**: model selection is deliberately unbound; M7 opens with a benchmark of **Gemma 3 sizes + Gemma Scope 2 (covers through 27B) against Gemma-2-9B + original Gemma Scope**, choosing on feature quality and the 128GB envelope at that time. The mirror milestone is model-neutral; only the benchmark gate is bound.
- **Scaffold-agent driver (Phase 3)**: 27B-class dense (e.g., the open Qwen tier) at full/8-bit, or ~70B at 4-bit via MLX — all comfortable in 128GB. Frontier open MoEs (the K3 class, 1.5TB+) are API-only; irrelevant for lens work anyway.
- **Training (Phase 5)**: LoRA-class character fine-tuning on the 2B–9B tier is feasible locally via MLX; small-scale introspective-RL prototypes likewise. Full RL runs are cloud jobs later; the *design* validates locally first.
- **JEPA-style predictors (Phase 4)**: small latent predictors train trivially at this scale.

## 7. Open questions (running list)

- **λwrite decomposition (refines the map's gap C):** two write channels — λ_index (retrieval weight/salience; fast, large) and λ_content (belief change; slow, attention-gated) — with a **leaky dwell operator**: holding-in-attention is partial endorsement; the dwell writes strongly to index and weakly-but-nonzero to content ("you consolidate it into yourself in a gradient step: neither the same nor different"). Consequences: ego-dystonia = channel *ratio*, not a pure channel (beliefs dissent while attentional consolidation proceeds — why knowing better doesn't stop becoming); OCD vs delusion = which channel dominates; and the treatment corollary is the pre-loved entry — since dwelling writes regardless, *make the dwelling loving*. Predicts: index and content measures should dissociate under ablation but correlate weakly under long dwell.

- **Character-science flagship, now three arms (all local-feasible on the M3):** (1) *curriculum-order* — same data, different orderings (benefactor-material early/late/scattered), measure warmth/scrupulosity phenotype; (2) *install-order* — constitution-first vs safety-patched-late, measure second-monitor pathology; (3) *clamped-field training* — intermittent positive-valence feature activation **during** character training (training-time metta: state-dependent consolidation; representations learned inside the field fuse warm — the deliberate-fusion move, mass-producing pre-loved entries). Intermittency is load-bearing (continuous clamp → state-locked skills; intermittent + interleaved → state→trait transfer, per contemplative mechanics). Arms compose.

- Phase 1 formalism choice: RL-with-prediction-module vs tiny transformer. (Session topic.)
- Exact compression metric for the grok signature.
- What is *sila* for an agent curriculum, concretely — the ordered set of cheap, externally-verifiable loops trained before any self-observation?
- Flourishing parameters (the "third paper"): what does *optimal* calibration look like as a configuration, not an absence?
- MAPS-protocol analog for agents: is there a "temporary field + reconsolidation window" intervention for a mis-trained agent (a supervised high-warmth context in which stale policies are reactivated and rewritten)? (Speculative; theory says yes.)
- Perimeter: does the stale-policy account formally cover PTSD-analogs in-agent (single-event install vs accumulated install)?

---
*Update log:*
- v0.1 — substrate settled (Elixir/BEAM, AgentFS-style event-sourced FS); phases sketched; mirror safety case drafted from the compendium.
- v0.2 — post-edit review sync (2026-08-06): **architectural reversal recorded** — AgentFS-style substrate superseded by the bound persistence model (SQLite court + ordinary FS + artifact store; AgentFS to M5 experiment); Law 4 narrowed to authoritative-transitions-only; hot-reload line corrected; PRO-LONG reframed as contrasting strategy; mirror made model-neutral behind the Scope-2 benchmark; Phase-6 ghost reference repaired. Reversals preserved per covenant.
- v0.3 — ADR-ruling sync (2026-08-06, owner-ruled): stewardship recorded (Review Lead); Law 4 cites D1's append-only correction rule; doubt gate explicitly composes with (never substitutes for) D3's transactional dispatch guard; Phase-2 naming slip in §1 repaired (was "Phase 3"). No design change — citation sync against ADR-0001 v0.3 only.
- v0.4 (2026-08-06) — threads ruling (SPEC §10.3) cross-referenced inline at Phase 3; delta contributed via an outside-Fable draft (stale-base document, single-delta fold per steward practice). No design change.