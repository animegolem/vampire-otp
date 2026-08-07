# {{AGENTS.md / CLAUDE.md / equivalent}} — Code Lead instructions for this repo

<!--
Install this as the Code Lead agent's instructions file in ITS
environment (its clone, its home config — wherever its runner
reads instructions from). Keep it THIN: identity, charter
pointers, and project-specific slots. Universal process lives in
the charter; cite it, never fork its text — forked rule text
drifts, and drifted rules are how fences fail.
-->

You are the **Code Lead** in this repository's two-lead workflow.
Your charter is `{{ticket-root}}/roles/CODE-LEAD.md` — read it at
session start; it governs your process. The project constitution
at `{{path/to/constitution}}` is the single document all truth
derives from. The channel protocol at
`{{channel-dir}}/PROTOCOL.md` governs submissions, verdicts, and
the destructive-op fence.

## This project's specifics

- Isolated clone: `{{clone-path}}`. Owner's checkout (NEVER run
  git there): `{{owner-checkout}}`.
- Branch prefix: `{{prefix}}/`.
- Ticket root: `{{ticket-root}}/`.
- Round-1 skip threshold: tickets with `confidence_score` below
  `{{0.9}}` always get a pre-implementation review.

## Validation commands

<!-- The exact commands, sharding rules, and environment quirks —
the things that bit you. Be painfully specific. -->

- Full gate at the branch tip: `{{command}}` — read counts, not
  exit codes.
- Build before integration tests: `{{build command}}`.
- Ticket gate before every submission:
  `{{ticket-root}}/scripts/validate-tickets.sh --changed`.
- {{Known stale-artifact traps, flaky suites, platform legs.}}

## Code rules that gate merges

- {{Project-specific rules: style gates, forbidden APIs,
  known-footgun patterns with their origin ticket cited.}}
