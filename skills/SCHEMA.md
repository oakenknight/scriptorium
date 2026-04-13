# Scriptorium Skill Frontmatter Schema

Version: 1
This file is the canonical reference for skill frontmatter. All skills in `skills/`
must conform to it. Any field not listed here is invalid.

---

## Field reference

```yaml
---
name: <string>
display_name: <string>
version: <integer>
description: <string>
triggers: <list of strings>
invokes: <list of agent name strings>
capabilities: <list of capability enum values>
resumable: <boolean>
config: Meta/vault.config.yaml
language: <string>
---
```

### `name`
Type: string (lowercase, hyphenated slug)
Required: yes

The skill's unique identifier. Used as:
- The routing key in the dispatcher
- The state file name: `Meta/state/<name>.yaml`
- The filename: `skills/<name>.md`

Must be unique across all skills and agents.

### `display_name`
Type: string
Required: yes

Human-readable name shown in output and reports.
Examples: "Vault Onboarding", "Domain Garden", "Project Closure"

### `version`
Type: integer (starts at 1)
Required: yes

Version of this skill definition file. Increment when the skill's
workflow changes in a way that would break in-progress state files.
When version is incremented, existing state files for this skill
should be discarded or migrated.

### `description`
Type: string (one paragraph, YAML block scalar `>`)
Required: yes

What this skill does and why it exists as a skill rather than a
single agent invocation. Should answer: what multi-step flow does
this orchestrate? Which agents does it coordinate?

### `triggers`
Type: list of strings
Required: yes

User phrases the dispatcher matches to invoke this skill.
Checked before the agent routing table — skills take priority.
At least 3 triggers required. Include common variations.

### `invokes`
Type: list of agent name strings
Required: yes (may be empty list `[]` for self-contained skills)

The agent names this skill may hand off to during its workflow.
Used by the dispatcher to pre-validate that invoked agents exist.
Valid values: custodian, intake, quaestor, glossator, chronicler,
archivist, oracle, and any registered custom agent slugs.

### `capabilities`
Type: list of enum strings
Required: yes (may be empty list `[]`)

File operations the skill may perform *directly* (outside of agent
delegation). If an operation is not listed, delegate it to an agent.

Valid values:
- `read-files`    — read any file in the vault or system directory
- `create-files`  — create new files
- `edit-files`    — modify existing files
- `glob-files`    — list files matching a pattern
- `move-files`    — move or rename files

### `resumable`
Type: boolean
Required: yes

Whether this skill writes progress to `Meta/state/<name>.yaml` and
can be resumed if interrupted mid-session.

`true`: the skill reads its state file at start and resumes from
the recorded phase if an in-progress run exists.

`false`: the skill starts fresh every invocation. State file is
written only for logging, not resumption.

### `config`
Type: string (fixed value)
Required: yes
Value: always `Meta/vault.config.yaml`

Signals to the dispatcher and any reader that this skill resolves
all vault paths through the config file, never by hardcoding names.

### `language`
Type: string (fixed rule)
Required: yes
Value: always `auto-detect; respond in user's language; file contents always in English`

Documents the language handling rule. Skills detect the user's
language from their first message and maintain it throughout.
Vault file content (frontmatter, filenames, folder names) is
always written in English regardless of session language.

---

## State file schema (per-skill)

Every resumable skill maintains a state file at `Meta/state/<name>.yaml`.

Required fields:

```yaml
skill: <name>            # matches the skill's name field
version: <integer>       # incremented on every write (starts at 0)
phase: <string>          # current phase slug (e.g. "domains", "complete")
completed_phases: []     # list of phase slugs already finished
started_at: <ISO string> # when this run began
last_updated: <ISO string>
```

Additional fields are skill-specific. See each skill file for its
full state schema.

---

## Relationship to agents

Skills are not agents. The differences:

| | Agent | Skill |
|---|---|---|
| Invocation | Dispatcher routes user phrase | Dispatcher routes user phrase (priority) |
| Scope | Atomic, single-shot | Multi-step, stateful |
| State | `Meta/state/<agent>.yaml` | `Meta/state/<skill>.yaml` |
| Handoffs | Emits to other agents | Emits to agents and waits for receipts |
| Body | System prompt for one role | Workflow instructions for orchestration |
| Resumable | No (always fresh) | Yes, if `resumable: true` |
