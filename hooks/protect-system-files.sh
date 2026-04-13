#!/usr/bin/env bash
# =============================================================================
# protect-system-files.sh
# =============================================================================
#
# WHAT IT DOES:
#   Runs before every Write or Edit tool call. Compares the target file path
#   against the list of Scriptorium source files that must never be overwritten
#   after deployment. Blocks protected paths with exit 2. Passes everything
#   else silently with exit 0.
#
# WHAT IT PROTECTS:
#   Source files (never written at runtime):
#     agents/<core-agent>.md    — the 7 built-in agent definitions
#     skills/*.md               — all skill definition files
#     skills/SCHEMA.md          — the skill schema reference
#     coordination/dispatcher.md
#     coordination/ledger-schema.yaml
#     adapters/**               — all platform adapter files
#     vault-template/**         — the starter vault skeleton
#     .scriptorium/hooks/*.sh   — deployed hook scripts (cannot overwrite themselves)
#     .scriptorium/settings.json
#
# WHAT IT EXPLICITLY ALLOWS (runtime-mutable):
#   Meta/ledger/               — session ledger, written by dispatcher
#   Meta/registry/             — domain registry, written by Custodian
#   Meta/state/                — per-agent and per-skill state, written by agents
#   Meta/templates/            — note templates, created by Custodian
#   Meta/vault.config.yaml     — written during onboarding, stable after
#   Atrium/, Codex/, Annals/   — vault content sections
#   Cartulary/, Compendium/, Reliquary/
#   agents/<custom-agent>.md   — new custom agents created by the create-agent skill
#                                (new files, not overwrites of core agents)
#
# NOTE ON BASH TOOL:
#   This hook only intercepts Write and Edit tool calls. The Bash tool is not
#   intercepted here — parsing arbitrary shell commands reliably for path
#   extraction is outside the scope of this hook. Agents are expected to
#   follow their behavioral constraints and not run destructive shell commands
#   against source files directly.
#
# EXIT CODES:
#   0 — allow the operation
#   2 — block: the target is a protected source file
# =============================================================================

set -uo pipefail

# ─── jq detection ─────────────────────────────────────────────────────────────
# Use jq if available for reliable JSON parsing. Fall back to grep/sed if not.
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=true
else
  HAS_JQ=false
fi

# ─── Read the full hook payload from stdin ────────────────────────────────────
INPUT=$(cat)

# ─── Extract fields from the JSON payload ────────────────────────────────────
if $HAS_JQ; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
  FILE_PATH=$(echo "$INPUT" | jq -r '.args.file_path // empty')
  SYSTEM_DIR=$(echo "$INPUT" | jq -r '.system_dir // empty')
else
  # Fallback: grep the raw JSON for each field.
  # These patterns work for simple string values without escaped characters,
  # which covers all valid file paths.
  TOOL_NAME=$(echo "$INPUT" | \
    grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | \
    sed 's/"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  FILE_PATH=$(echo "$INPUT" | \
    grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | \
    sed 's/"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  SYSTEM_DIR=$(echo "$INPUT" | \
    grep -o '"system_dir"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | \
    sed 's/"system_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
fi

# Default system directory if the payload doesn't specify one.
SYSTEM_DIR="${SYSTEM_DIR:-.scriptorium}"

# ─── Scope check ──────────────────────────────────────────────────────────────
# Only act on Write and Edit. Any other tool falls through silently.
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

# If no file path was extracted (malformed payload), pass silently.
# This hook should never block due to a parsing failure on its own part.
[[ -z "$FILE_PATH" ]] && exit 0

# ─── Path decomposition ───────────────────────────────────────────────────────
# Extract the filename and the immediate parent directory name. Used by the
# path-pattern checks below.
BASENAME=$(basename "$FILE_PATH")
PARENT_DIR=$(basename "$(dirname "$FILE_PATH")")

# ─── Helper: emit block message and exit 2 ───────────────────────────────────
block() {
  local reason="$1"
  echo "SCRIPTORIUM [protect-system-files]: Write blocked — ${reason}"
  echo "  Path:   ${FILE_PATH}"
  echo "  Reason: This file is part of the Scriptorium source layer and must"
  echo "          not be modified at runtime. If this was intentional (e.g.,"
  echo "          updating a skill during development), edit the file directly"
  echo "          outside the vault environment."
  exit 2
}

# ─── Check 1: Core agent definitions ─────────────────────────────────────────
# The 7 built-in agents must never be overwritten. Custom agents created by
# the create-agent skill land in agents/<new-slug>.md — those are new files and
# are explicitly allowed. We protect only the known core agent filenames.
#
# Custom agents can be freely written (they are new files not on this list).
# The manage-agent skill can edit custom agents — also allowed.
if [[ "$PARENT_DIR" == "agents" && "$BASENAME" == *.md ]]; then
  SLUG="${BASENAME%.md}"
  case "$SLUG" in
    custodian|intake|quaestor|glossator|chronicler|archivist|oracle)
      block "core agent definition (${BASENAME})" ;;
  esac
fi

# ─── Check 2: All skill definitions ──────────────────────────────────────────
# skills/ is entirely read-only after deployment. The create-agent skill writes
# to agents/, not skills/, so there is no legitimate runtime write to skills/.
if [[ "$PARENT_DIR" == "skills" ]]; then
  case "$BASENAME" in
    *.md|SCHEMA.md)
      block "skill definition (${BASENAME})" ;;
  esac
fi

# ─── Check 3: Coordination source files ──────────────────────────────────────
# The dispatcher and ledger schema are the coordination layer — never runtime-
# written. The session ledger itself lives in Meta/ledger/, not here.
if [[ "$PARENT_DIR" == "coordination" ]]; then
  case "$BASENAME" in
    dispatcher.md|ledger-schema.yaml)
      block "coordination source file (${BASENAME})" ;;
  esac
fi

# ─── Check 4: Deployed hook scripts and settings ─────────────────────────────
# Hooks must not overwrite themselves during a session. The system_dir value
# from the JSON payload determines the actual deployed directory name, so this
# check is not hardcoded to ".scriptorium".
#
# Match pattern: any path whose components include <system_dir>/hooks/*.sh
if [[ "$FILE_PATH" == *"/${SYSTEM_DIR}/hooks/"* && "$BASENAME" == *.sh ]]; then
  block "deployed hook script (${BASENAME})"
fi
if [[ "$FILE_PATH" == *"/${SYSTEM_DIR}/settings.json" ]]; then
  block "hook registration settings"
fi

# ─── Check 5: Adapter source files ───────────────────────────────────────────
# The adapters/ directory contains platform-specific deployment scripts.
# These are source files, not runtime outputs.
if [[ "$FILE_PATH" == *"/adapters/"* ]]; then
  block "platform adapter"
fi

# ─── Check 6: Vault template skeleton ────────────────────────────────────────
# vault-template/ is the source for the onboarding scaffold. It is never
# modified at runtime — the Custodian writes into the live vault, not here.
if [[ "$FILE_PATH" == *"/vault-template/"* ]]; then
  block "vault template source"
fi

# ─── All checks passed: allow the operation ───────────────────────────────────
exit 0
