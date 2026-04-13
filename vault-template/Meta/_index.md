---
type: index
path: Meta/
last_updated: YYYY-MM-DD
custodian_version: 1
---

# Meta

> System infrastructure: templates, indexes, agent state, and
> registry. This section is agent-facing — you do not need to
> browse it manually. Agents read and write here; you interact
> with the vault through them.

## Contents

- `registry/` — domain registry and system configuration
  - `domains.yaml` — canonical list of Codex domains (Custodian)
- `state/` — per-agent state files (each agent reads/writes its own)
  - `custodian.yaml`
  - `intake.yaml`
  - `quaestor.yaml`
  - `glossator.yaml`
  - `chronicler.yaml`
  - `archivist.yaml`
  - `oracle.yaml`
- `ledger/` — coordination audit trail
  - `session.yaml` — rolling handoff/receipt log (dispatcher)
  - `audit-YYYY-MM-DD.md` — Archivist health reports
- `templates/` — note templates (used by agents)
  - `note.md`
  - `meeting.md`
  - `journal.md`
  - `weekly-review.md`
  - `project-brief.md`
  - `reference.md`
