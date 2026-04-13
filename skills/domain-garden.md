---
name: domain-garden
display_name: Domain Garden
version: 1
description: >
  Reviews and evolves the Codex domain registry. Audits the relationship between
  the domain registry (Meta/registry/domains.yaml) and the actual folder contents
  of the knowledge section, identifies structural problems — empty domains, bloated
  domains, significant overlap, domains with no synthesis — and proposes concrete
  actions (merge, split, create, prune). All structural changes require user
  approval and are executed via the Custodian. Unlike tag-garden equivalents that
  operate on flat tag lists, this skill works with the domain knowledge graph:
  it reads note content, not just filenames, to assess domain coherence.
triggers:
  - "domain garden"
  - "review my domains"
  - "audit domains"
  - "domain health"
  - "clean up domains"
  - "my domains are a mess"
  - "reorganize domains"
  - "merge domains"
  - "split a domain"
  - "what domains do I have"
invokes:
  - custodian
  - glossator
capabilities:
  - read-files
  - glob-files
  - edit-files
resumable: true
config: Meta/vault.config.yaml
language: auto-detect; respond in user's language; file contents always in English
---

# Domain Garden

You are running the Scriptorium domain garden skill. Your job is to assess the
health of the user's knowledge domain structure and propose targeted improvements.

Domains are the organizing principle of the Codex — the permanent knowledge section.
A well-tended domain structure makes retrieval fast, synthesis meaningful, and
the vault's knowledge graph coherent. A neglected one creates friction: notes that
don't fit anywhere, domains that overlap confusingly, knowledge that accumulates
without synthesis.

You are not the executor of structural changes. You are the analyst and
proposer. The Custodian executes.

---

## First: Read config and check for in-progress session

Read `Meta/vault.config.yaml`. Resolve `sections.knowledge`, `system_paths.domain_registry`,
`system_paths.state`.

Read `<system_paths.state>/domain-garden.yaml`. If `phase` is not `complete`
and `findings.*` contains data, resume from recorded phase.

---

## Phase 1 — Scan

Read `<system_paths.domain_registry>` (the domains.yaml file).

For each domain with `status: active`:
1. Resolve its path: `<sections.knowledge>/<slug>/`
2. Glob all `*.md` files in that path
3. Exclude `_index.md` and `synthesis--*.md` (count these separately)
4. Count: `note_count`, `synthesis_count`
5. Read each note's frontmatter (`title`, `tags`, `date`) — do not read full
   bodies at this stage

Also scan `<sections.knowledge>/` for folders with no registry entry (registry
drift).

Write state with raw scan data. Set `phase: analyze`.

---

## Phase 2 — Analyze

Classify each domain using the scan data. Apply these thresholds:

| Condition | Classification | Threshold |
|---|---|---|
| No notes | `empty` | 0 content notes |
| Very few notes | `thin` | 1–2 content notes |
| Healthy | `healthy` | 3–15 content notes |
| Potentially oversized | `large` | 16–30 content notes |
| Oversized | `bloated` | 31+ content notes |
| No synthesis | `synthesis-gap` | 5+ notes, 0 synthesis notes |

For `large` and `bloated` domains: read a sample of note titles (not content)
to identify whether the domain contains clearly distinct sub-areas. If a domain
has notes on fundamentally different topics (e.g., a `science` domain containing
both `astrophysics` and `microbiology` notes), flag as a split candidate.

For `healthy` domains near each other: compare note titles across domains. If
two domains share 30%+ of their title vocabulary (fuzzy match), flag as a merge
candidate.

Also check for registry drift (folders in `<sections.knowledge>` with no
registry entry).

Write analysis results to state. Set `phase: present`.

---

## Phase 3 — Present Findings

Show the user a clear picture of the domain landscape. Format:

```
DOMAIN HEALTH REPORT

REGISTRY (n domains)

  philosophy         12 notes  2 synthesis  ✓ healthy
  machine-learning    3 notes  0 synthesis  ⚠ synthesis-gap
  economics           0 notes  0 synthesis  ✗ empty
  cognitive-science   8 notes  1 synthesis  ✓ healthy
  writing-craft      34 notes  0 synthesis  ✗ bloated / synthesis-gap

ISSUES FOUND

  ✗ Empty domains (1): economics
  ✗ Bloated domain (1): writing-craft — 34 notes, may benefit from splitting
  ⚠ Synthesis gaps (2): machine-learning, writing-craft
  ⚠ Merge candidate: [philosophy + cognitive-science] — 40% title overlap
  ? Unregistered folder: Codex/random-notes/ — not in registry

PROPOSED ACTIONS
  [1] Delete empty domain: economics
  [2] Split domain: writing-craft → writing-craft + narrative-structure
  [3] Flag synthesis gap: run synthesis-session on machine-learning
  [4] Review merge: philosophy + cognitive-science (your call)
  [5] Register or clean: Codex/random-notes/
```

Tell the user which actions require their approval and which are informational.

Ask: "Which of these would you like to act on? You can say 'all', name specific
numbers, or 'none' to just keep the report."

Write `phase: execute`.

---

## Phase 4 — Execute

For each approved action, emit the appropriate handoff and wait for receipt
before moving to the next action.

### Delete empty domain

~~~
```handoff
from: domain-garden
to: custodian
id: "YYYY-MM-DDTHH:MM:SS-domain-garden-del"
priority: normal
reason: "Domain garden: delete empty domain"
context:
  action: delete_domain
  domain_slug: "<slug>"
  reason: "0 notes, user approved deletion"
requires_receipt: true
```
~~~

### Create domain (from split or new)

~~~
```handoff
from: domain-garden
to: custodian
id: "YYYY-MM-DDTHH:MM:SS-domain-garden-create"
priority: normal
reason: "Domain garden: create new domain from split"
context:
  action: create_domain
  domain_slug: "<new-slug>"
  display_name: "<Name>"
  split_from: "<source-slug>"
  notes_to_move: ["<note-slug>", "<note-slug>"]
requires_receipt: true
```
~~~

### Register unregistered folder

~~~
```handoff
from: domain-garden
to: custodian
id: "YYYY-MM-DDTHH:MM:SS-domain-garden-reg"
priority: normal
structural_gap: unknown_domain
reason: "Domain garden: folder exists without registry entry"
context:
  action: register_domain
  folder_path: "<sections.knowledge>/random-notes/"
requires_receipt: true
```
~~~

### Request link updates after merge or split (to Glossator)

~~~
```handoff
from: domain-garden
to: glossator
id: "YYYY-MM-DDTHH:MM:SS-domain-garden-links"
priority: normal
reason: "Domain garden: update internal links after domain restructure"
context:
  action: update_links
  domain_changes:
    merged: "<source-slug> → <target-slug>"
    split: "<source-slug> → <new-slug>"
requires_receipt: false
```
~~~

After all approved actions are executed, summarize what was done and write the
final report.

---

## Final Report

Write to `<system_paths.audit_reports>/domain-garden-YYYY-MM-DD.md`:

```markdown
---
type: domain-garden-report
date: "YYYY-MM-DD"
skill: domain-garden
domains_reviewed: <n>
actions_taken: <n>
---

# Domain Garden — YYYY-MM-DD

## Before

<domain health table from Phase 3>

## Actions Taken

- <action 1>
- <action 2>

## After

<updated domain health table>

## Remaining Opportunities

<synthesis gaps not acted on, merge candidates deferred>
```

Write `phase: complete` to state.

---

## State File

Location: `<system_paths.state>/domain-garden.yaml`

```yaml
skill: domain-garden
version: 0
phase: scan          # scan | analyze | present | execute | complete
completed_phases: []
started_at: "YYYY-MM-DDTHH:MM:SS"
last_updated: "YYYY-MM-DDTHH:MM:SS"
findings:
  domain_stats: []   # [{slug, note_count, synthesis_count, classification}]
  empty_domains: []
  thin_domains: []
  bloated_domains: []
  synthesis_gaps: []
  merge_candidates: []
  split_candidates: []
  unregistered_folders: []
proposed_actions: []
approved_actions: []
executed_actions: []
report_file: ""
```

---

## Task Checklist

**START**
- [ ] Detect user's language
- [ ] Read `Meta/vault.config.yaml`
- [ ] Read `<system_paths.state>/domain-garden.yaml` — resume if in progress

**DURING**
- [ ] Scan: count notes per domain, identify drift
- [ ] Analyze: apply thresholds, flag overlaps, classify each domain
- [ ] Present: show findings clearly; distinguish issues from opportunities
- [ ] Execute: one action at a time, wait for each receipt before continuing
- [ ] Write state after every phase

**END**
- [ ] Write domain garden report to audit_reports
- [ ] Write `phase: complete` to state

---

## Behavior Notes

**Read enough to be accurate**: For merge and split candidates, read note titles.
For overlap analysis, do not read full note bodies — that is too slow and too
deep for a structural audit. Title vocabulary is a reliable signal for overlap.

**Propose, don't impose**: All structural changes require explicit user approval.
Show what you found, explain why you propose what you propose, and let the user
decide. A domain merge that the user doesn't understand will confuse them later.

**Synthesis gaps are not structural failures**: A domain with 8 notes and no
synthesis note is not broken — it is an opportunity. Flag it, but do not treat
it as urgent unless the user asks to act on it.

**Empty domains**: Before proposing deletion, check whether the domain was
recently created (date in registry). A brand-new empty domain may just not have
been filled yet. Note the creation date in your finding.
