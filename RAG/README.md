# VampireOTP RAG — canonical work-tracking and design-document tree

This directory is the file-based delivery substrate for the two-lead workflow.

- `AI-EPIC/` — feature epics owned by the Review Lead.
- `AI-IMP/` — implementation tickets cut from `SPEC-0001.md`.
- `AI-LOG/` — sitting handoff logs.
- `BRIEFS/` — Review Lead assignment briefs.
- `templates/` — mandatory ticket, brief, verdict, protocol, and instruction templates.
- `roles/` — operating charters for the Review Lead and Code Lead.
- `scripts/` — ticket validation, index generation, channel carrier, and workflow checks.

`INDEX.md` is generated; never edit it manually.

```sh
RAG/scripts/generate-index.sh
RAG/scripts/validate-tickets.sh
```

Application work remains blocked until `SPEC-0001.md` §7.2 is satisfied.
