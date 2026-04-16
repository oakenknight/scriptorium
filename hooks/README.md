# Scriptorium Hooks

Shell hooks that run automatically before or after agent tool calls to guard
the system and validate vault state. Written for the Claude Code platform;
hook scripts are portable shell and can be adapted to other platforms.

---

## Overview

Hooks are the integrity layer between agent actions and the vault. They do not
implement agent logic — they check that the outputs of agent actions conform
to Scriptorium's structural contracts. A hook that fires on every Write and
passes silently costs nothing. A hook that catches a malformed state file
before the user ends the session saves that user's progress.

Every hook follows the same contract:

- Reads a JSON payload from stdin
- Extracts `tool_name`, `args.file_path`, and `system_dir`
- Exits 0 to allow, 1 to warn, 2 to block (PreToolUse only)
- Exits 0 silently when the operation is out of scope
- Never crashes — all error paths produce exit 0 rather than leaving the tool
  call in an undefined state

---

## Hook Reference

### `protect-system-files`

**Event**: PreToolUse — Write, Edit  
**Exit codes**: 0 allow, 2 block

Prevents agents from overwriting core source files at runtime. The distinction
between source (never written at runtime) and runtime-mutable (written by
agents during normal operation) is the most critical rule in this system — a
hook that is too broad breaks agents; one that is too narrow fails to protect
the system.

**Protected paths** (any write to these is blocked):

| Path pattern | Reason |
|---|---|
| `agents/custodian.md` (and 6 other core agents) | Core agent definitions — never overwritten |
| `skills/*.md` | All skill definitions — read-only after deployment |
| `coordination/dispatcher.md` | Routing rules — never modified at runtime |
| `coordination/ledger-schema.yaml` | Schema reference — never modified at runtime |
| `adapters/**` | Platform adapter scripts |
| `vault-template/**` | Starter vault skeleton — not the live vault |
| `.scriptorium/hooks/*.sh` | Deployed hooks — cannot overwrite themselves |
| `.scriptorium/settings.json` | Hook registration |

**Explicitly allowed** (these are runtime-mutable and must not be blocked):

- `Meta/ledger/` — session ledger and archives
- `Meta/registry/` — domain registry
- `Meta/state/` — all agent and skill state files
- `Meta/templates/` — note templates created by the Custodian
- `Meta/vault.config.yaml` — written during onboarding
- All vault content sections: Atrium, Codex, Annals, Cartulary, Compendium, Reliquary
- New custom agent files in `agents/` (files not on the core agent list)

**Note on Bash tool**: This hook only intercepts Write and Edit. It does not
parse Bash commands — agents are expected to follow their behavioral
constraints and not run destructive shell commands against source files.

---

### `validate-frontmatter`

**Event**: PostToolUse — Write  
**Exit codes**: 0 valid/skip, 1 warn

After a Markdown file is written to a vault content section, reads the file
from disk and validates its YAML frontmatter against the Scriptorium schema.

**Syntax checks**:

1. If frontmatter opens with `---`, it must also close with `---`
2. No hard tab characters in frontmatter (YAML requires spaces)
3. Unquoted values containing `: ` (colon-space) sequences (heuristic warning)

**Required fields on all content notes**:

| Field | Constraint |
|---|---|
| `title` | any string |
| `type` | must be a known type (see below) |
| `date` | must match `YYYY-MM-DD` |
| `status` | any string |

**Type-specific required fields**:

| type | Additional required fields |
|---|---|
| `reference` | `source`, `author` |
| `meeting` | `participants` |
| `synthesis` | `topic`, `domain` |

**Known types** (no extra fields): `inbox`, `note`, `journal`, `daily`, `review`, `project`

**Files skipped** (not content notes):
- Non-`.md` files
- `_index.md`, `_brief.md`, `README.md`, `SCHEMA.md`
- Files in system directories: `Meta/`, `.scriptorium/`, `agents/`, `skills/`,
  `coordination/`, `adapters/`, `vault-template/`
- Files with no frontmatter block (first line is not `---`)

**Why Write only (not Edit)**: Notes are created once with Write; frontmatter
is established at creation time. Subsequent Edits modify note body content
(link enrichment, tagging) but do not alter the frontmatter structure.

---

### `validate-ledger`

**Event**: PostToolUse — Write, Edit  
**Exit codes**: 0 valid/skip, 1 warn

After `Meta/ledger/session.yaml` is written, validates the structural integrity
of Scriptorium's coordination ledger. A malformed ledger causes silent
coordination failures — the dispatcher reads a corrupt structure and misroutes
agents or fails to resolve in-flight receipt chains.

**Scope**: Only fires on `Meta/ledger/session.yaml`. Archive files
(`Meta/ledger/archive-*.yaml`) are skipped — they are written by the rotation
logic, which is responsible for their correctness.

**Top-level checks**:
- File is not empty
- `max_entries` is present and numeric
- `open_receipts` field is present
- `entries` field is present

**open_receipts entry fields** (each open receipt must have all four):
- `id` — unique handoff identifier
- `from` — sending agent
- `to` — receiving agent
- `waiting_since` — timestamp when the receipt was opened

**entries entry fields** (each logged event must have all six):
- `timestamp` — when the event was logged
- `type` — must be `handoff` or `receipt`
- `from` — sending agent
- `to` — receiving agent
- `id` — handoff identifier (receipts reference the handoff id)
- `status` — must be `open` or `resolved`

---

### `validate-state`

**Event**: PostToolUse — Write, Edit  
**Exit codes**: 0 valid/skip, 1 warn

After any file in `Meta/state/` is written, validates that the state file
contains all required fields for the Scriptorium state protocol. State files
are the resumption mechanism for all 8 skills — a file with a missing `phase`
or non-numeric `version` causes the skill to silently restart from Phase 1.

**Scope**: Only fires on `Meta/state/*.yaml`. Skips empty files (pre-init stubs
from `vault-template`).

**Required fields**:

| Field | Type | Constraint |
|---|---|---|
| `skill` or `agent` | string | At least one identity field must be present |
| `version` | integer | Non-negative integer; incremented on every write |
| `phase` | string | Non-empty; identifies the current workflow position |
| `started_at` | string | Must match `YYYY-MM-DDTHH:MM:SS` |
| `last_updated` | string | Must match `YYYY-MM-DDTHH:MM:SS` |

Missing required fields → error (exit 1)  
Timestamp format mismatch → warning only (the skill still runs; records are
just harder to correlate in reports)

---

### `notify`

**Event**: Notification  
**Exit codes**: 0 always

Sends a desktop notification when the Scriptorium system needs user attention.
Always uses "Scriptorium" as the application title — the `title` field in the
notification payload is intentionally ignored.

**Platform support**:
- macOS — `osascript` (built-in, no dependencies required)
- Linux — `notify-send` (requires `libnotify-bin`; falls back to stderr)
- Other — stderr output (message is not silently lost)

**Message sanitization**: Double quotes are replaced with single quotes and
backslashes with forward slashes before embedding in the AppleScript call.
Message is truncated to 200 characters.

---

## Deployment

Hooks live in `hooks/` in the Scriptorium source repository. The Claude Code
adapter deploys them to `.scriptorium/hooks/` inside the vault root alongside
`settings.json`. Scripts run relative to the vault root, so
`.scriptorium/hooks/` in `settings.json` is a relative path from the vault.

```
<vault-root>/
  .scriptorium/
    hooks/
      protect-system-files.sh
      validate-frontmatter.sh
      validate-ledger.sh
      validate-state.sh
      notify.sh
    settings.json     ← hook registration
```

The `.hook.yaml` files in `hooks/` are metadata for the Scriptorium source
repository (used to describe hooks and match them to their scripts). They are
not read by Claude Code at runtime — `settings.json` is the platform's
registration file.

---

## How to Disable a Hook

To disable a hook without deleting it, remove or comment out its entry in
`.scriptorium/settings.json` in the vault. The script file can remain — it
simply will not be invoked.

Example: to disable `validate-frontmatter` while keeping everything else,
remove its entry from the `PostToolUse` array in `settings.json`.

Do not delete the script file from `.scriptorium/hooks/` — if you reinstall
or update Scriptorium, the deploy step will restore it, and you will need to
disable it again from `settings.json`.

---

## How to Add a New Hook

1. **Write the shell script** in `hooks/<name>.sh` following the conventions
   of existing hooks:
   - Comment block at the top explaining what, why, and exit codes
   - jq detection with grep/sed fallback
   - Read stdin into `INPUT`
   - Extract `tool_name`, `args.file_path`, `system_dir` from the payload
   - Scope check at the top — exit 0 for anything out of scope
   - Exit 0 silently on unexpected errors (never crash)

2. **Write a `.hook.yaml` file** in `hooks/<name>.hook.yaml`:
   ```yaml
   name: <slug>
   description: <one line>
   script: <name>.sh
   triggers:
     - event: before-tool-use | after-tool-use | on-notification
       match-tool: [write, edit, bash]   # omit for on-notification
   ```

3. **Register the hook** in `adapters/claude-code/settings.json` by adding an
   entry to the appropriate event array (`PreToolUse`, `PostToolUse`, or
   `Notification`).

4. **Deploy**: copy the new `.sh` file to `.scriptorium/hooks/` in the vault,
   and update `.scriptorium/settings.json`.

---

## Exit Code Reference

| Code | Meaning | When to use |
|---|---|---|
| 0 | Pass / out of scope | Default — allow the operation |
| 1 | Soft warn | Issue found but operation proceeds; message surfaces to agent |
| 2 | Hard block | Operation rejected entirely; only valid in PreToolUse hooks |

PostToolUse hooks cannot block (the tool already ran) — they should only
use exit 0 or 1. Using exit 2 in a PostToolUse hook is undefined behavior on
the Claude Code platform and may cause unexpected session interruption.
