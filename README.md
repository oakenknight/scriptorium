# Scriptorium

**A multi-agent system for managing a personal knowledge vault in Obsidian.**

Seven specialists. One vault. You talk; they organize.

---

## What it is

A scriptorium was the room in a medieval monastery where manuscripts
were copied, annotated, cross-referenced, and archived. Not a library
(passive storage) — an active intellectual workspace where specialists
processed knowledge into durable, connected records.

Scriptorium applies that model to personal knowledge management. Raw
input arrives in any form — typed thoughts, voice notes, web clips,
meeting transcripts — and a team of agents processes it: capturing,
structuring, filing, linking, synthesizing, and maintaining. The vault
is the manuscript collection. The agents are the specialists who work it.

**The human never manually organizes files.** Agents own all filing,
moving, renaming, and linking.

---

## The agents

| Agent | Role |
|---|---|
| **Custodian** | Structural authority — creates folders, taxonomy, domain registry, and all Maps of Content. Always runs first when structure is missing. |
| **Intake** | Captures all raw input: typed text, voice transcriptions, web clips, emails. Converts to structured, frontmatter-complete notes. |
| **Quaestor** | Triage and routing — reads the Atrium, decides where each note goes, moves it there. Signals the Custodian when a destination doesn't exist. |
| **Glossator** | Enrichment — adds tags, wikilinks, context paragraphs to filed notes. Turns isolated notes into connected ones. |
| **Chronicler** | Time-anchored records — creates and formats meeting logs, journal entries, daily notes, and weekly reviews. Owns the Annals. |
| **Archivist** | Vault health — periodic audits for orphans, broken links, naming violations, stale projects. Reports; does not fix structural issues. |
| **Oracle** | Retrieval and synthesis — finds content across the vault, synthesizes across multiple notes, creates synthesis notes. |

---

## Skills

Skills are multi-step, stateful workflows that orchestrate sequences of
agent calls to complete longer tasks. Unlike agents (which handle single
reactive operations), skills run in the main conversation context and
preserve state across turns so they can be resumed in a later session.

| Skill | What it does |
|---|---|
| **onboarding** | Guided vault initialization — collects knowledge domains and active projects, then scaffolds the full vault structure via the Custodian. |
| **create-agent** | Interactive workflow for designing and writing a new custom agent file that conforms to the Scriptorium agent schema. |
| **manage-agent** | Lists, inspects, edits, and deletes custom agents. Core agents are read-only. |
| **transcribe** | Processes a recording or raw transcript through an interview — determines type, speakers, date, project — and routes the structured output to the right section. |
| **maintain** | Orchestrated vault maintenance in two modes: light (inbox drain + structural check) and deep (adds full audit, enrichment pass, domain health review). |
| **domain-garden** | Reviews the Codex domain structure — identifies empty, thin, bloated, and overlapping domains — and proposes merges, splits, and pruning. |
| **close-project** | Guides project closure through retrospective, knowledge extraction to the Codex, open item resolution, and archival. |
| **synthesis-session** | Guided, iterative synthesis conversation with the Oracle — scope a question, review retrieved material, shape a draft, file the result. |

Skills are defined in `skills/*.md`. Each skill stores its in-progress
state at `Meta/state/<skill-name>.yaml` and resumes automatically if
the session ends mid-workflow.

---

## The vault structure

```
Atrium/       Raw input: inbox, fleeting notes, daily captures
Codex/        Permanent knowledge notes, organized by domain
Annals/       Chronological records: meetings, journals, reviews
Cartulary/    Reference material: sources, highlights, web clips
Compendium/   Active projects and ongoing responsibilities
Reliquary/    Archive: completed projects, dormant work
Meta/         System: templates, indexes, agent state, registry
```

The structure encodes the *nature* of knowledge, not the user's current
life configuration. Domains in the Codex persist across projects and
life phases. The Compendium holds what is active; the Reliquary holds
what was. When a project ends, the Codex keeps what it taught you.

### Naming conventions

| Location | Pattern | Example |
|---|---|---|
| Codex notes | `title-slug.md` | `cathedral-thinking.md` |
| Annals records | `YYYY-MM-DD.type.md` | `2026-04-13.meeting.md` |
| Cartulary references | `author--title-slug.md` | `ahrens--smart-notes.md` |
| Atrium captures | `YYYY-MM-DD.inbox.md` | `2026-04-13.inbox.md` |
| Synthesis notes | `synthesis--topic-slug.md` | `synthesis--attention-and-focus.md` |
| Structural files | `_index.md`, `_brief.md` | (at folder root) |

---

## Coordination model

Agents communicate through structured `handoff` and `receipt` code
blocks emitted at the end of their responses. A dispatcher reads these
blocks and routes to the next agent.

```yaml
# A handoff block
handoff:
  from: quaestor
  to: custodian
  id: "2026-04-13T14:23:00-quaestor"
  priority: high
  structural_gap: unknown_domain
  context:
    suggested_domain: machine-learning
  requires_receipt: true
```

```yaml
# A receipt block
receipt:
  from: custodian
  to: quaestor
  for_handoff_id: "2026-04-13T14:23:00-quaestor"
  status: completed
  summary: "Domain 'machine-learning' created and registered"
```

The dispatcher tracks open receipts in `Meta/ledger/session.yaml`.
Structural gaps (missing folders, unknown domains) always route to the
Custodian and block content work until resolved.

---

## State persistence

Each agent and skill maintains a versioned YAML state file at
`Meta/state/<name>.yaml`. State files track the current phase, what
the agent is waiting for, and any in-progress data needed for resumption.

The dispatcher maintains a shared session ledger at
`Meta/ledger/session.yaml` — a rolling log of all handoffs and
receipts. This is the audit trail of coordination, not agent memory.

---

## Hooks

Shell scripts that run automatically before or after agent tool calls.
Deployed to `.scriptorium/hooks/` and registered in `.claude/settings.json`.

| Hook | When | What it does |
|---|---|---|
| **protect-system-files** | Before Write/Edit | Blocks writes to core source files (agents, skills, dispatcher, adapters, deployed hooks). Allows all runtime-mutable paths. |
| **validate-frontmatter** | After Write | Checks YAML syntax and required schema fields (title, type, date, status; plus type-specific extras for reference/meeting/synthesis notes). |
| **validate-ledger** | After Write/Edit | After session.yaml writes, verifies structural integrity of the handoff/receipt log: required keys, per-entry fields, enum values for type and status. |
| **validate-state** | After Write/Edit | After Meta/state/*.yaml writes, verifies required fields for skill resumption: identity field, version, phase, timestamps. |
| **notify** | Notification event | Desktop notification with "Scriptorium" branding via osascript (macOS) or notify-send (Linux). |

All hooks check for `jq` and fall back to `grep`/`sed` parsing if it is
not available. See `hooks/README.md` for per-hook check details and
instructions for adding new hooks.

---

## Repository structure

```
agents/
  custodian.md          Structural authority
  intake.md             Raw capture
  quaestor.md           Triage and routing
  glossator.md          Enrichment
  chronicler.md         Time-anchored records
  archivist.md          Vault health
  oracle.md             Retrieval and synthesis

skills/
  SCHEMA.md             Skill frontmatter schema reference
  onboarding.md
  create-agent.md
  manage-agent.md
  transcribe.md
  maintain.md
  domain-garden.md
  close-project.md
  synthesis-session.md

coordination/
  dispatcher.md         Routing rules, skill table, handoff protocol
  ledger-schema.yaml    Session ledger schema

hooks/
  *.sh                  Hook scripts (source — deployed by install.sh)
  *.hook.yaml           Hook metadata (event, trigger, script mapping)
  README.md             Hook reference for developers

vault-template/         Starter vault skeleton
  Atrium/_index.md
  Codex/_index.md
  Annals/_index.md
  Cartulary/_index.md
  Compendium/_index.md
  Reliquary/_index.md
  Meta/
    vault.config.yaml   Section path config (single source of truth)
    registry/domains.yaml
    ledger/session.yaml
    state/*.yaml        One stub per agent and skill (15 total)
    templates/          note, meeting, journal, review, brief, reference

adapters/
  claude-code/
    CLAUDE.md           Dispatcher entrypoint for Claude Code
    settings.json       Hook registration (source — deployed to .claude/)
    install.sh          Deployment script
```

---

## Getting started

```bash
bash path/to/brainoff/adapters/claude-code/install.sh ~/my-vault
cd ~/my-vault
claude
```

Then say: **"initialize the vault"**

The onboarding skill walks you through your knowledge domains and active
projects, then the Custodian builds the full vault structure. After that,
every session starts with the dispatcher loaded and hooks active.

To preview what the installer will do without writing anything:

```bash
bash path/to/brainoff/adapters/claude-code/install.sh ~/my-vault --dry-run
```

To update an existing vault to a newer version of Scriptorium, run the
same command again. The installer detects the existing installation,
replaces system files, and preserves all vault content and state.

---

## Design principles

**Structure encodes kind, not context.** The Codex organizes by what
type of knowledge something is, not what project it belongs to. A note
about attention spans goes in `Codex/cognitive-science/` whether you
captured it during a work project or a personal reading phase.

**Structural gaps block content work.** If a destination path doesn't
exist, the Custodian creates it before any note is filed there. No
agent improvises paths.

**Agents do one thing well.** Intake captures; it does not file.
Quaestor files; it does not enrich. Glossator enriches; it does not
synthesize. Clear boundaries make the system debuggable.

**Receipts close loops.** When an agent is blocked waiting for
structure, it says so explicitly and waits for a receipt. Implicit
dependencies cause silent failures. Explicit receipts catch them.

**Skills run in the conversation; agents run as subprocesses.** Multi-step
workflows (onboarding, project closure, synthesis sessions) need to
preserve state across turns and loop back on user feedback. Agents handle
single reactive operations. The distinction keeps each layer simple.

**The Oracle synthesizes; other agents do not.** Only the Oracle
creates new synthesis notes from accumulated knowledge. Other agents
can flag synthesis opportunities; only the Oracle produces them.
