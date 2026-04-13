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

Each agent maintains a versioned YAML state file at
`Meta/state/<agent>.yaml`. State files track what the agent last did,
what it is waiting for (pending receipts), and agent-specific memory
(known domains for the Custodian, routing log for the Quaestor, etc.).

The dispatcher maintains a shared session ledger at
`Meta/ledger/session.yaml` — a rolling log of all handoffs and
receipts. This is the audit trail of coordination, not agent memory.

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

coordination/
  dispatcher.md         Routing rules and handoff protocol
  ledger-schema.yaml    Session ledger schema

vault-template/         Starter vault skeleton
  Atrium/_index.md
  Codex/_index.md
  Annals/_index.md
  Cartulary/_index.md
  Compendium/_index.md
  Reliquary/_index.md
  Meta/
    _index.md
    registry/domains.yaml
    ledger/session.yaml
    state/<agent>.yaml  (one per agent, initialized empty)
    templates/          (note, meeting, journal, review, brief, reference)

adapters/
  claude-code/CLAUDE.md Claude Code dispatcher entrypoint
```

---

## Getting started

1. Copy `vault-template/` into your Obsidian vault root.
2. Place the system directory (or a reference to it) where your
   agent platform can find the agent files.
3. For Claude Code: copy `adapters/claude-code/CLAUDE.md` to your
   vault root as `CLAUDE.md`, and update the agent file paths.
4. Start a session. If the vault has no structure, the Custodian
   initializes it automatically.
5. Talk to the dispatcher. It routes your requests to the right agent.

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

**The Oracle synthesizes; other agents do not.** Only the Oracle
creates new synthesis notes from accumulated knowledge. Other agents
can flag synthesis opportunities; only the Oracle produces them.
