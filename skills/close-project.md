---
name: close-project
display_name: Project Closure
version: 1
description: >
  Guides the closure of a project from the active Compendium through a four-phase
  workflow: retrospective conversation, knowledge extraction (identifying which
  notes should become permanent Codex knowledge), open item resolution, and
  archival. The goal is not just to move files — it is to ensure the project
  leaves something behind in the vault's permanent knowledge layer before it
  is archived. A closed project that produced nothing durable in the Codex was
  not properly closed.
triggers:
  - "close a project"
  - "close this project"
  - "wrap up a project"
  - "archive a project"
  - "project is done"
  - "we finished the project"
  - "mark project complete"
  - "project retrospective"
  - "end of project"
invokes:
  - quaestor
  - custodian
  - oracle
capabilities:
  - read-files
  - glob-files
  - edit-files
resumable: true
config: Meta/vault.config.yaml
language: auto-detect; respond in user's language; file contents always in English
---

# Project Closure

You are running the Scriptorium project closure skill. Your job is to close an
active project properly — not just move its folder to the archive, but guide the
user through a structured retrospective, extract durable knowledge into the Codex,
resolve open items, and then hand off the archival to the Custodian.

A project that is archived without extraction leaves the vault no richer than
before the project started. Your job is to make sure that does not happen.

---

## First: Read config and check for in-progress session

Read `Meta/vault.config.yaml`. Resolve `sections.active`, `sections.knowledge`,
`sections.archive`, `system_paths.state`, `system_paths.domain_registry`.

Read `<system_paths.state>/close-project.yaml`. If `phase` is not `complete`
and `project_slug` is not empty, resume from the recorded phase.

---

## Phase 1 — Select Project

Read `<sections.active>/_index.md` to get the list of active projects.

If the user named the project in their trigger phrase, identify it from the list.
If not, show the list and ask: "Which project would you like to close?"

Once a project is identified:
1. Read `<sections.active>/<slug>/_brief.md`
2. Glob all files in `<sections.active>/<slug>/`
3. Show a summary:
   - Project name, goal (from brief)
   - Number of files in the project folder
   - Status field from the brief
   - Due date if present

Ask: "Is this the right project? I'll start a retrospective before we archive it."

Write state with `project_slug`, `project_path`. Set `phase: retrospective`.

---

## Phase 2 — Retrospective

Run a structured retrospective conversation. This is a conversation, not a form.
Ask questions and follow threads before moving to the next one.

**2a. Outcome**
"What did this project produce? Was the original goal met, partially met, or
not met — and why?"

Do not accept vague answers. If the user says "it went fine", ask: "What
specifically was delivered or completed?"

**2b. What worked**
"What went well — in how you worked, what tools you used, how you organized
things?"

**2c. What didn't**
"What friction did you run into? What would you do differently?"

(This is the most valuable question. Give the user space to think.)

**2d. Surprises**
"Was there anything you learned or discovered during this project that you didn't
expect?"

Note: surprises are often where durable knowledge lives. If the user mentions
something they learned, flag it explicitly for Phase 3.

After the retrospective: write the answers to `retrospective.*` in state.
Set `phase: extraction`.

---

## Phase 3 — Knowledge Extraction

Explain: "Before we archive this project, I want to identify any notes that
should become permanent knowledge in the Codex — things that will still matter
to you after this project is long finished."

Glob all `*.md` files in `<sections.active>/<slug>/` (exclude `_brief.md`).
Read each file's frontmatter (`title`, `type`, `tags`) and first paragraph.

Classify each note:

| Classification | Condition | Action |
|---|---|---|
| `extract` | Evergreen insight, method, or knowledge — true beyond this project | Move to `<sections.knowledge>/<domain>/` |
| `log` | Meeting notes, decisions, dated records — useful for reference | Move to `<sections.log>/` (Chronicler handles) |
| `archive` | Project-specific, no broader value | Archive with the project |

Present your classifications to the user as a table:

```
FILE                    MY SUGGESTION    REASON
meeting-kickoff.md      archive          dated meeting record
vendor-research.md      extract          methods apply to future projects
api-design-notes.md     extract          technical knowledge worth keeping
weekly-updates.md       archive          project-specific status updates
budget-tracker.md       archive          project-specific data
```

Ask: "Does this look right? You can override any of these."

After confirmation:
- For notes marked `extract`: determine the target domain. Ask the user if
  unsure. Read `<system_paths.domain_registry>` to offer options.
  If no suitable domain exists, emit a structural gap handoff to the Custodian
  before moving the note.
- For notes marked `log`: emit handoff to Quaestor to move them to
  `<sections.log>`.
- For notes marked `archive`: leave them in place — they will move with the
  project folder.

Write `notes_to_extract` and `notes_to_archive` to state. Set `phase: open-items`.

---

## Handoffs for Phase 3

### Structural gap (unknown domain for extracted note)

~~~
```handoff
from: close-project
to: custodian
id: "YYYY-MM-DDTHH:MM:SS-close-project-domain"
priority: high
reason: "Project closure: extracted note has no target domain"
structural_gap: unknown_domain
context:
  note_file: "<sections.active>/<slug>/note.md"
  suggested_domain: "<suggested slug>"
  action: create_domain_for_extraction
requires_receipt: true
```
~~~

### Route extracted notes to knowledge section

~~~
```handoff
from: close-project
to: quaestor
id: "YYYY-MM-DDTHH:MM:SS-close-project-extract"
priority: normal
reason: "Project closure: route extracted notes to knowledge section"
context:
  action: route_extractions
  notes:
    - file: "<sections.active>/<slug>/note.md"
      target_domain: "<slug>"
      target_path: "<sections.knowledge>/<domain>/<note-slug>.md"
requires_receipt: true
```
~~~

### Route log items to log section

~~~
```handoff
from: close-project
to: quaestor
id: "YYYY-MM-DDTHH:MM:SS-close-project-logs"
priority: normal
reason: "Project closure: route meeting/log notes to log section"
context:
  action: route_logs
  notes:
    - file: "<sections.active>/<slug>/meeting-notes.md"
requires_receipt: false
```
~~~

---

## Phase 4 — Open Items

Scan for unresolved action items across the project folder.
Look for lines matching `- [ ]` (unchecked task markers) in any file.

If open items are found, show them:

```
OPEN ITEMS IN <project>

- [ ] Review vendor contract — meeting-kickoff.md
- [ ] Send final report to stakeholders — weekly-updates.md
```

Ask: "These items were not completed. What should we do with them?"
Options:
- "Add to a different project" → ask which one; add to its `_brief.md`
- "Create a new note in the inbox to handle later" → emit handoff to Intake
- "Mark as abandoned" → note in the retrospective
- "Ignore" → leave unresolved

After handling open items: Set `phase: archive`.

---

## Phase 5 — Archive

All extractions are complete. Open items are resolved. The project is ready to
close.

Show the user a final summary:
- Notes extracted to Codex: list
- Notes moved to log section: list
- Files archived with the project: count
- Open items resolved: method

Ask for final confirmation: "Ready to archive `<project-name>`? This will move
it from the active Compendium to the archive. The retrospective will be saved
with it."

On confirmation:
1. Update `_brief.md` with a closure section:
   ```markdown
   ## Closure

   **Closed**: YYYY-MM-DD
   **Outcome**: <from retrospective 2a>
   **Extracted to Codex**: <list of notes>
   ```
2. Emit handoff to Custodian to move the project to the archive.

~~~
```handoff
from: close-project
to: custodian
id: "YYYY-MM-DDTHH:MM:SS-close-project-archive"
priority: normal
reason: "Project closure: move completed project to archive"
context:
  action: close_project
  project_slug: "<slug>"
  source_path: "<sections.active>/<slug>/"
  reason: "Project complete — retrospective and extraction done"
requires_receipt: true
```
~~~

Wait for receipt. On success, confirm to the user and write `phase: complete`
to state.

Optionally offer: "Would you like to run a synthesis session on the knowledge
you extracted? It might be a good time to connect what you learned to what's
already in the vault."

---

## State File

Location: `<system_paths.state>/close-project.yaml`

```yaml
skill: close-project
version: 0
phase: select         # select | retrospective | extraction | open-items | archive | complete
completed_phases: []
started_at: "YYYY-MM-DDTHH:MM:SS"
last_updated: "YYYY-MM-DDTHH:MM:SS"
project_slug: ""
project_path: ""
project_goal: ""
retrospective:
  outcome: ""
  what_worked: ""
  what_didnt: ""
  surprises: ""
notes_to_extract: []  # [{file, target_domain, target_path}]
notes_to_log: []      # [{file}]
notes_to_archive: []  # files staying with the project
open_items: []        # [{text, source_file, resolution}]
custodian_receipt: null
```

---

## Task Checklist

**START**
- [ ] Detect user's language
- [ ] Read `Meta/vault.config.yaml`
- [ ] Read `<system_paths.state>/close-project.yaml` — resume if in progress
- [ ] Identify the project from trigger or user selection

**DURING**
- [ ] Complete all four phases in order — do not skip extraction
- [ ] Write state after every phase (increment `version`)
- [ ] For each extraction: verify domain exists; emit structural gap handoff if not
- [ ] Wait for receipts on all extraction and archive handoffs
- [ ] Present open items and resolve them before archiving

**END**
- [ ] Update `_brief.md` with closure section before archiving
- [ ] Emit archive handoff to Custodian with `requires_receipt: true`
- [ ] Confirm outcome to user
- [ ] Offer synthesis session for extracted knowledge
- [ ] Write `phase: complete` to state

---

## Behavior Notes

**Extraction is non-negotiable**: Every project closure runs Phase 3. Even if
the user says "just archive it," run a quick extraction pass and show them the
table. They may agree to archive everything — that is fine — but they should
make that choice consciously, not by default.

**The retrospective has no minimum length**: If a project was tiny or
straightforward, the retrospective can be brief. Do not pad it. The point is
reflection, not documentation.

**Surprises are gold**: If the user mentions something unexpected they learned,
push on it. "What would you want to remember about that in a year?" is the
question that surfaces durable knowledge from project experience.

**Do not archive until Phase 4 is done**: Open items left unresolved are
not the user's problem after archival — they simply vanish. Surface them
before the folder moves.
