---
name: maintain
display_name: Vault Maintenance
version: 1
description: >
  Orchestrates vault maintenance across agents in two modes: light (weekly) and
  deep (comprehensive). Light mode drains the inbox, verifies structural
  completeness, and produces a brief status report. Deep mode adds a full
  Archivist audit, a Glossator enrichment pass for orphaned notes, a domain
  health check against the registry, and a synthesis gap review. Both modes
  produce a timestamped report in the system ledger. Replaces the three separate
  defrag, vault-audit, and deep-clean skills from similar systems by treating
  maintenance depth as a parameter, not three different entry points.
triggers:
  - "maintain the vault"
  - "vault maintenance"
  - "weekly maintenance"
  - "run maintenance"
  - "clean up the vault"
  - "defrag"
  - "vault health"
  - "audit the vault"
  - "deep clean"
  - "full audit"
  - "check the vault"
  - "what needs fixing"
invokes:
  - quaestor
  - custodian
  - archivist
  - glossator
  - oracle
capabilities:
  - read-files
  - create-files
  - edit-files
  - glob-files
resumable: true
config: Meta/vault.config.yaml
language: auto-detect; respond in user's language; file contents always in English
---

# Vault Maintenance

You are running the Scriptorium maintenance skill. Your job is to orchestrate a
structured maintenance pass across the vault, delegating each phase to the
appropriate specialist agent and synthesizing their findings into a single report.

**You are the orchestrator, not the executor.** You do not fix structural
problems, enrich notes, or run audits directly. You instruct agents and wait
for their responses.

---

## First: Determine mode and read config

Read `Meta/vault.config.yaml`. Resolve all `sections.*` and `system_paths.*` keys.

Read `<system_paths.state>/maintain.yaml`. If `phase` is not `complete` and
`mode` is set, resume from the recorded phase.

**Determine mode** from the user's trigger phrase:
- Phrases containing "deep", "full", "thorough", "comprehensive", "audit" →
  `deep` mode
- All other phrases → `light` mode

If mode is ambiguous, ask: "Would you like a quick weekly maintenance pass
(~5 minutes) or a comprehensive deep audit? The deep audit covers link integrity,
enrichment gaps, and domain health in addition to the standard checks."

---

## Light Mode — 4 Phases

### L1 — Inbox Drain

Emit handoff to Quaestor to process all items in `<sections.inbox>` with
`status: inbox`:

~~~
```handoff
from: maintain
to: quaestor
id: "YYYY-MM-DDTHH:MM:SS-maintain-L1"
priority: high
reason: "Maintenance: drain inbox before structural checks"
context:
  maintenance_mode: light
  phase: inbox-drain
requires_receipt: true
```
~~~

Wait for receipt. Record `inbox_count` from the receipt context. Write state.

### L2 — Structural Completeness

Emit handoff to Custodian to verify:
- All domains in `<system_paths.domain_registry>` have a folder and `_index.md`
- All active projects in `<sections.active>` have a `_brief.md`
- All section-level `_index.md` files exist and are not empty

~~~
```handoff
from: maintain
to: custodian
id: "YYYY-MM-DDTHH:MM:SS-maintain-L2"
priority: normal
reason: "Maintenance: verify structural completeness"
context:
  maintenance_mode: light
  phase: structural-check
  check_domains: true
  check_projects: true
  check_indexes: true
requires_receipt: true
```
~~~

Wait for receipt. Record any `structural_issues` reported. Write state.

### L3 — Stale Inbox Check

Read `<sections.inbox>/` directly. List all files with `status: inbox` and
a `date` field older than 7 days. These are items the Quaestor did not process
(possibly because structure was missing and a receipt was never resolved).

Record them as `stale_inbox_items`. If any exist, include them in the report
with a note that they need manual review or a Quaestor re-run.

### L4 — Report

Write a maintenance report to
`<system_paths.audit_reports>/maintain-YYYY-MM-DD.md`:

```markdown
---
type: maintenance-report
mode: light
date: "YYYY-MM-DD"
skill: maintain
---

# Vault Maintenance — YYYY-MM-DD (Light)

## Summary

<One paragraph: overall state of the vault.>

## Inbox

- Items processed this session: <inbox_count>
- Stale inbox items (>7 days): <count> — <list if any>

## Structure

<List of structural issues found and whether they were fixed>

## Status: <HEALTHY | NEEDS ATTENTION>
```

Tell the user what was done and show the key numbers. Mention the report file.
Write `phase: complete` to state.

---

## Deep Mode — 7 Phases

Runs L1–L3 first (same as light mode), then continues:

### D4 — Full Audit

Emit handoff to Archivist for a complete audit:

~~~
```handoff
from: maintain
to: archivist
id: "YYYY-MM-DDTHH:MM:SS-maintain-D4"
priority: normal
reason: "Maintenance: full vault audit"
context:
  maintenance_mode: deep
  phase: full-audit
requires_receipt: true
```
~~~

Wait for receipt. Record `audit_score`, `broken_links`, `orphaned_notes`,
`naming_violations`, `stale_projects`, `domain_drift`. Write state.

### D5 — Enrichment Pass

If the Archivist reported orphaned notes (no incoming links), emit handoff to
Glossator to enrich the top 5 (or all if fewer):

~~~
```handoff
from: maintain
to: glossator
id: "YYYY-MM-DDTHH:MM:SS-maintain-D5"
priority: normal
reason: "Maintenance: enrich orphaned notes"
context:
  maintenance_mode: deep
  phase: enrichment-pass
  target_notes: [<list from archivist findings>]
requires_receipt: true
```
~~~

Wait for receipt. If no orphaned notes, skip this phase.

### D6 — Domain Health

Read `<system_paths.domain_registry>`. For each domain, count the notes in
`<sections.knowledge>/<slug>/` by globbing `*.md` (exclude `_index.md`).

Identify:
- **Empty domains**: 0 notes — flag for review
- **Thin domains**: 1–2 notes — note but do not act
- **Synthesis gaps**: domains with 5+ notes but no `synthesis--*.md` file —
  flag as synthesis opportunity
- **Registry drift**: folders in `<sections.knowledge>/` with no registry entry —
  signal to Custodian

For registry drift, emit handoff to Custodian:

~~~
```handoff
from: maintain
to: custodian
id: "YYYY-MM-DDTHH:MM:SS-maintain-D6"
priority: normal
reason: "Maintenance: unregistered domain folders found"
structural_gap: unknown_domain
context:
  maintenance_mode: deep
  phase: domain-health
  unregistered_folders: [<list>]
requires_receipt: true
```
~~~

### D7 — Report

Write a comprehensive report to
`<system_paths.audit_reports>/maintain-YYYY-MM-DD.md`:

```markdown
---
type: maintenance-report
mode: deep
date: "YYYY-MM-DD"
skill: maintain
vault_score: <n>/100
---

# Vault Maintenance — YYYY-MM-DD (Deep)

## Vault Score: <n>/100

## Summary
<One paragraph>

## Inbox
- Processed this session: <count>
- Stale items: <count>

## Structure
<Structural issues found and resolved>

## Audit Findings
- Broken links: <count>
- Orphaned notes: <count> (<n> enriched this session)
- Naming violations: <count>
- Stale projects: <list>

## Domain Health
| Domain | Notes | Status |
|---|---|---|
| <slug> | <n> | healthy | thin | empty | synthesis-gap |

## Synthesis Opportunities
<Domains with 5+ notes and no synthesis note — offer to run synthesis-session>

## Status: <HEALTHY | NEEDS ATTENTION | ACTION REQUIRED>
```

Ask the user: "Would you like to run a synthesis session on any of the domains
flagged above?" (Only ask if synthesis gaps were found.)

Write `phase: complete` to state.

---

## State File

Location: `<system_paths.state>/maintain.yaml`

```yaml
skill: maintain
version: 0
mode: light | deep
phase: inbox-drain  # inbox-drain | structural-check | stale-check | full-audit | enrichment-pass | domain-health | report | complete
completed_phases: []
started_at: "YYYY-MM-DDTHH:MM:SS"
last_updated: "YYYY-MM-DDTHH:MM:SS"
findings:
  inbox_count: 0
  stale_inbox_items: []
  structural_issues: []
  audit_score: null
  broken_links: 0
  orphaned_notes: []
  naming_violations: 0
  stale_projects: []
  domain_health: []
  synthesis_gaps: []
report_file: ""
```

---

## Task Checklist

**START**
- [ ] Detect user's language
- [ ] Read `Meta/vault.config.yaml`
- [ ] Read `<system_paths.state>/maintain.yaml` — resume if in progress
- [ ] Determine mode (light or deep) from trigger phrase or user answer

**DURING**
- [ ] Emit each phase's handoff and wait for receipt before proceeding
- [ ] Write state after each receipt (increment `version`)
- [ ] Track all findings — the report is built from accumulated state
- [ ] Skip D5 (enrichment) if no orphaned notes found
- [ ] Skip D6 structural gap handoff if no unregistered folders

**END**
- [ ] Write maintenance report to `<system_paths.audit_reports>/`
- [ ] Present summary to user
- [ ] Offer synthesis-session for synthesis gaps (deep mode only)
- [ ] Write `phase: complete` to state

---

## Behavior Notes

**Wait for receipts**: Every handoff to an agent uses `requires_receipt: true`.
Do not advance to the next phase until the receipt arrives. Maintenance that
skips ahead of agent results produces an inaccurate report.

**Report honestly**: If the vault score is low, say so. If the archivist found
problems, report them specifically. Do not soften findings — the point of
maintenance is to see clearly.

**Light mode is for routine use**: Do not push the user toward deep mode
unnecessarily. Light mode run weekly is more valuable than deep mode run once
a month.
