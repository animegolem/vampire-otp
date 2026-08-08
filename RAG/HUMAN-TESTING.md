# Human-testing queue

The Review Lead appends landed work that needs an owner feel pass. Only the owner checks items off.

## 2026-08-08 — permission-fence mitigations + tooling-wave feel pass

Context: in auto mode, the session classifier fenced the whole
cross-session-messaging surface (settings hook wiring, Codex
delegation of the same edit, even a headless `claude -p` test).
Owner switched to manual mode and the blocked items landed same day —
the list below is what remains the owner's, plus feel passes on what
shipped.

- [ ] **Decide the standing permission policy** for the messaging
  surface before returning to auto mode. Recommended: keep auto mode
  but add a narrow allow rule to `.claude/settings.local.json` so the
  doorbell tooling operates without classifier involvement:
  `{ "permissions": { "allow": ["Bash(claude -p*)"] } }`
  (explicit allow rules are checked before the classifier). The
  alternative — staying on manual — costs a prompt per action while
  the owner is away.
- [ ] **Feel pass: wake-note injection.** Next `/clear` (or cold
  start) should show the seat's baton plus live wake state (HEAD,
  channel unacked, note age/drift). Judge signal-to-noise.
- [ ] **Feel pass: the bell.** `ping-owner.sh` now speaks the settled
  contract (`--reason blocker|approval|stale-carrier|test`,
  `--dedup-key`, 60-min dedup window, argv-passed osascript). Judge
  whether reasons/dedup feel right from the receiving end.
- [ ] **Feel pass: relay doorbell.** launchd job
  `com.vampireotp.relay-doorbell` watches `.relay/inbox` and rings the
  RL seat via a headless `claude -p` child + SendMessage (3-min
  debounce; hint-layer only — carrier stays truth, watchdog stays
  backstop). Verify it rings when Sol's round 2 lands, and that the
  haiku-child cost per ring is acceptable.
- [ ] **Parked conversation (owner-raised 2026-08-08):** policy for
  persisting seat state and having automation open it — the wake-note
  pattern works, but the owner wanted to think about the general
  shape. Related: filing an upstream feature request for public
  documentation of the messaging-socket wire format (undocumented as
  of CC 2.1.226; researched, not needed for the SendMessage-based
  doorbell).
