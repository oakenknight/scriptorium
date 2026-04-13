#!/usr/bin/env bash
# =============================================================================
# validate-state.sh
# =============================================================================
#
# WHAT IT DOES:
#   Fires after every Write or Edit on any file in Meta/state/. Validates that
#   the state file contains all required structural fields for the Scriptorium
#   state protocol. State files are the resumption mechanism for all 8 skills
#   — a malformed state file causes a skill to silently restart from Phase 1,
#   discarding whatever progress the user made in a previous session.
#
# WHY THIS HOOK IS UNIQUE TO SCRIPTORIUM:
#   Scriptorium has 8 resumable skills, each with a state file that drives
#   multi-session continuity. No reference system has resumable skills, so no
#   reference equivalent exists. This hook provides fast feedback when an agent
#   writes a state file with missing or malformed fields — before the user ends
#   the session and loses their position.
#
# SCOPE:
#   Only fires on: Meta/state/*.yaml
#   Skips empty files (initial stubs before first use).
#
# WHAT IT CHECKS:
#   Identity (one of these must be present):
#     - skill    string — for skill state files (onboarding, maintain, etc.)
#     - agent    string — for agent state files (custodian, oracle, etc.)
#
#   Required on all state files:
#     - version       must be a non-negative integer (incremented on each write)
#     - phase         must be a non-empty string (current workflow position)
#     - started_at    must match YYYY-MM-DDTHH:MM:SS (ISO 8601 datetime)
#     - last_updated  must match YYYY-MM-DDTHH:MM:SS (ISO 8601 datetime)
#
#   Warnings (not errors):
#     - started_at or last_updated values that don't match the expected format
#     - phase field that is present but empty
#
# DESIGN DECISION — ERRORS VS WARNINGS:
#   Missing required fields → exit 1 (error): the file is structurally broken
#   and resumption will fail.
#   Timestamp format mismatch → warning only: a non-standard timestamp will
#   not prevent the skill from running; it just makes the record harder to
#   parse in reports. We warn without blocking.
#
# EMPTY FILE HANDLING:
#   The vault-template ships with pre-populated empty stub state files. When
#   an agent first writes to a state file, the stub may be empty initially.
#   Empty files are silently skipped — they are pre-initialization stubs, not
#   broken files.
#
# EXIT CODES:
#   0 — valid structure, or file is out of scope or empty
#   1 — warn: required fields missing or malformed
# =============================================================================

set -uo pipefail

# ─── jq detection ─────────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=true
else
  HAS_JQ=false
fi

# ─── Read the full hook payload from stdin ────────────────────────────────────
INPUT=$(cat)

# ─── Extract fields from JSON payload ────────────────────────────────────────
if $HAS_JQ; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
  FILE_PATH=$(echo "$INPUT" | jq -r '.args.file_path // empty')
else
  TOOL_NAME=$(echo "$INPUT" | \
    grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | \
    sed 's/"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
  FILE_PATH=$(echo "$INPUT" | \
    grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | \
    sed 's/"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
fi

# ─── Scope check: Write or Edit on Meta/state/*.yaml only ────────────────────
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

[[ -n "$FILE_PATH" ]] || exit 0
[[ "$FILE_PATH" == *.yaml ]] || exit 0

# Match exactly: ...Meta/state/<filename>.yaml
BASENAME=$(basename "$FILE_PATH")
PARENT=$(basename "$(dirname "$FILE_PATH")")
GRANDPARENT=$(basename "$(dirname "$(dirname "$FILE_PATH")")")

if [[ "$PARENT" != "state" || "$GRANDPARENT" != "Meta" ]]; then
  exit 0
fi

# ─── Read the state file from disk ───────────────────────────────────────────
[[ -f "$FILE_PATH" ]] || exit 0

CONTENT=$(cat "$FILE_PATH")

# Skip empty stub files silently. Stubs are zero-byte or whitespace-only files
# that ship in vault-template before an agent has written to them for the
# first time.
STRIPPED=$(printf '%s' "$CONTENT" | tr -d '[:space:]')
[[ -z "$STRIPPED" ]] && exit 0

ERRORS=()
WARNINGS=()

# ─── Check: identity field ───────────────────────────────────────────────────
# Every state file must declare what skill or agent it belongs to. This is the
# primary key for log correlation and resumption lookup.
HAS_SKILL=$(printf '%s\n' "$CONTENT" | grep -cE '^skill[[:space:]]*:' || true)
HAS_AGENT=$(printf '%s\n' "$CONTENT" | grep -cE '^agent[[:space:]]*:' || true)

if [[ "$HAS_SKILL" -eq 0 && "$HAS_AGENT" -eq 0 ]]; then
  ERRORS+=("Missing identity field: state file must have a 'skill' or 'agent' key at the top level")
fi

# ─── Check: required structural fields ───────────────────────────────────────
for FIELD in version phase started_at last_updated; do
  if ! printf '%s\n' "$CONTENT" | grep -qE "^${FIELD}[[:space:]]*:"; then
    ERRORS+=("Missing required field: '${FIELD}'")
  fi
done

# ─── Check: version is a non-negative integer ────────────────────────────────
# version increments on every write; a non-numeric version means a write
# collision or a script error in the agent.
if printf '%s\n' "$CONTENT" | grep -qE '^version[[:space:]]*:'; then
  VERSION_RAW=$(printf '%s\n' "$CONTENT" | \
    grep -E '^version[[:space:]]*:' | head -1 | \
    sed 's/^version[[:space:]]*:[[:space:]]*//' | tr -d '"'"'" | xargs)
  if ! printf '%s\n' "$VERSION_RAW" | grep -qE '^[0-9]+$'; then
    ERRORS+=("Field 'version' value '${VERSION_RAW}' is not a non-negative integer")
  fi
fi

# ─── Check: phase is not empty ───────────────────────────────────────────────
# An empty phase field would cause the skill to not know where it is.
if printf '%s\n' "$CONTENT" | grep -qE '^phase[[:space:]]*:'; then
  PHASE_RAW=$(printf '%s\n' "$CONTENT" | \
    grep -E '^phase[[:space:]]*:' | head -1 | \
    sed 's/^phase[[:space:]]*:[[:space:]]*//' | tr -d '"'"'" | xargs)
  if [[ -z "$PHASE_RAW" ]]; then
    WARNINGS+=("Field 'phase' is empty — expected a phase name such as 'scope', 'draft', 'complete'")
  fi
fi

# ─── Check: timestamp format on started_at and last_updated ──────────────────
# Format: YYYY-MM-DDTHH:MM:SS (ISO 8601, no timezone suffix expected here)
# Empty/null values are allowed (pre-initialization state files).
TS_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$'

for TS_FIELD in started_at last_updated; do
  if printf '%s\n' "$CONTENT" | grep -qE "^${TS_FIELD}[[:space:]]*:"; then
    TS_RAW=$(printf '%s\n' "$CONTENT" | \
      grep -E "^${TS_FIELD}[[:space:]]*:" | head -1 | \
      sed "s/^${TS_FIELD}[[:space:]]*:[[:space:]]*//" | tr -d '"'"'" | xargs)

    # Allow explicitly empty values — these are pre-init stubs
    [[ -z "$TS_RAW" || "$TS_RAW" == '""' || "$TS_RAW" == "''" ]] && continue

    if ! printf '%s\n' "$TS_RAW" | grep -qE "$TS_PATTERN"; then
      WARNINGS+=("Field '${TS_FIELD}' value '${TS_RAW}' does not match YYYY-MM-DDTHH:MM:SS format")
    fi
  fi
done

# ─── Report results ──────────────────────────────────────────────────────────
if [[ ${#ERRORS[@]} -gt 0 || ${#WARNINGS[@]} -gt 0 ]]; then
  echo "SCRIPTORIUM [validate-state]: Issues in ${BASENAME}"
  for MSG in "${ERRORS[@]}"; do
    echo "  ERROR: ${MSG}"
  done
  for MSG in "${WARNINGS[@]}"; do
    echo "  WARN:  ${MSG}"
  done
fi

[[ ${#ERRORS[@]} -gt 0 ]] && exit 1
exit 0
