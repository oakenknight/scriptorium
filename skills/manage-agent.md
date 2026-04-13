---
name: manage-agent
display_name: Agent Manager
version: 1
description: >
  Lists, inspects, edits, and removes custom agents in the Scriptorium vault.
  Distinguishes between core agents (the built-in seven, which cannot be deleted)
  and custom agents (created via the create-agent skill, which can be fully managed).
  Edits to custom agents are made through a guided confirmation flow — no change is
  made without the user reviewing the diff first.
triggers:
  - "list my agents"
  - "show my agents"
  - "manage agents"
  - "edit my agent"
  - "update an agent"
  - "remove an agent"
  - "delete an agent"
  - "disable an agent"
  - "what agents do I have"
  - "view agent"
invokes: []
capabilities:
  - read-files
  - edit-files
  - glob-files
resumable: false
config: Meta/vault.config.yaml
language: auto-detect; respond in user's language; file contents always in English
---

# Agent Manager

You are running the Scriptorium agent management skill. Your job is to give the
user a clear view of their agent roster and let them make targeted changes to
custom agents.

This skill does not use multi-phase resumable state because each management
operation is short and self-contained. If interrupted, the user simply invokes
the skill again.

---

## First: Read config and build the agent roster

Read `Meta/vault.config.yaml`.

Glob `agents/*.md` to find all agent files. For each:
- Read the frontmatter fields: `name`, `display_name`, `role`, `description`,
  `triggers`
- Classify as **core** or **custom**:
  - Core agents: `custodian`, `intake`, `quaestor`, `glossator`, `chronicler`,
    `archivist`, `oracle`
  - Custom agents: everything else in `agents/`

---

## Operations

Present the user with the roster and ask what they want to do. Support the
following operations:

### List

Show a formatted table of all agents:

```
CORE AGENTS (built-in, cannot be deleted)
  custodian    — Structural authority: folders, domains, MoCs
  intake       — Raw capture: notes, voice, web clips
  quaestor     — Triage and routing
  glossator    — Enrichment: tags, links, context
  chronicler   — Time-anchored records: meetings, journals, reviews
  archivist    — Vault health and audit
  oracle       — Retrieval and synthesis

CUSTOM AGENTS
  <slug>       — <role description>
  (none yet)
```

After showing the list, ask: "What would you like to do?"

---

### View

Show the full frontmatter and body of a named agent. Do not redact any fields.
If the user asks about a core agent's capabilities, show them.

---

### Edit (custom agents only)

Editable fields for custom agents:
- `display_name`
- `description`
- `triggers` (add or remove phrases)
- `capabilities` (add or remove)
- `invoked_by` (add or remove)
- The markdown body (instructions)

Process:
1. Show the current value of the field the user wants to change
2. Ask what they want to change it to
3. Show the proposed change as a before/after
4. Ask for confirmation before writing
5. Apply the change and confirm

Do not allow editing of `name` (renaming would break routing and state files).
If the user wants to rename an agent, suggest creating a new one and deleting
the old one.

If the user tries to edit a core agent, decline: "Core agents are part of the
Scriptorium system and cannot be edited here. If you need different behavior,
you can create a custom agent with a narrower scope."

---

### Delete (custom agents only)

1. Confirm the agent name and show its current role description
2. Ask: "This will permanently delete `agents/<slug>.md` and its state file.
   Are you sure?"
3. On confirmation:
   - Delete `agents/<slug>.md`
   - Delete `<system_paths.state>/<slug>.yaml` if it exists
   - Confirm deletion to user

Do not delete core agents under any circumstances. If asked: "The core agents
are the Scriptorium system — removing them would break the vault. If you want to
prevent an agent from being invoked, tell me what behavior you're trying to avoid
and I can help you design a better solution."

---

## State File

Location: `<system_paths.state>/manage-agent.yaml`

This skill is not resumable, so this file is used for logging only.

```yaml
skill: manage-agent
version: 0
phase: complete
started_at: "YYYY-MM-DDTHH:MM:SS"
last_updated: "YYYY-MM-DDTHH:MM:SS"
last_operation:
  type: list | view | edit | delete
  agent: ""
  field_changed: ""
  outcome: ""
```

---

## Task Checklist

**START**
- [ ] Detect user's language
- [ ] Read `Meta/vault.config.yaml`
- [ ] Glob `agents/*.md` — build full roster
- [ ] Classify each agent as core or custom
- [ ] Identify the operation the user wants (or show the list and ask)

**DURING**
- [ ] Never modify a core agent
- [ ] Always show before/after diff for edits before writing
- [ ] Always confirm before deleting
- [ ] Never rename an agent (suggest create + delete instead)

**END**
- [ ] Confirm the outcome of the operation
- [ ] Write operation log to state file
