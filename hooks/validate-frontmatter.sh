#!/usr/bin/env bash
# =============================================================================
# validate-frontmatter.sh
# =============================================================================
#
# WHAT IT DOES:
#   Runs after every Write tool call. For Markdown files written to vault
#   content sections, reads the written file from disk and validates:
#     (a) YAML frontmatter syntax
#     (b) Required schema fields for the Scriptorium note schema
#
#   Emits warnings (exit 1) for issues found. Never blocks (exit 0 or 1 only).
#
# SYNTAX CHECKS:
#   1. If frontmatter opens with ---, it must also close with ---
#   2. No hard tab characters in frontmatter (YAML requires spaces)
#   3. Unquoted values with embedded colon-space sequences (heuristic warning —
#      e.g., "key: value: with colon" — may break strict YAML parsers)
#
# SCHEMA CHECKS (required on all content notes):
#   - title    string
#   - type     string (must be a known Scriptorium type)
#   - date     string (must match YYYY-MM-DD format)
#   - status   string
#
# TYPE-SPECIFIC REQUIRED FIELDS:
#   type: reference  → also requires: source, author
#   type: meeting    → also requires: participants
#   type: synthesis  → also requires: topic, domain
#
# KNOWN TYPES (no additional fields beyond the base four):
#   inbox, note, journal, daily, review, project
#
# WHAT IT SKIPS:
#   - Non-.md files
#   - Structural filenames: _index.md, _brief.md, README.md, SCHEMA.md
#   - System directories: Meta/, .scriptorium/, agents/, skills/,
#     coordination/, adapters/, vault-template/
#   - Files with no frontmatter block (first line is not ---)
#   - Files that do not exist on disk (race condition safety)
#
# WHY ONLY PostToolUse WRITE (NOT EDIT):
#   Notes are created once with Write; their frontmatter is established at
#   creation time. Subsequent Edits modify note body content (link enrichment,
#   tagging) but do not alter frontmatter structure. Firing on Edit would be
#   noisy and redundant. Frontmatter captured incorrectly at creation time is
#   the failure mode this hook addresses.
#
# SELF-CONTAINED SCHEMA:
#   Required fields are defined in this script, not read from vault.config.yaml.
#   Hooks must be simple and portable — reading a YAML config from a hook
#   introduces a dependency that can break the hook during initialization.
#
# EXIT CODES:
#   0 — valid frontmatter, or file is out of scope (skipped)
#   1 — warn: syntax errors or missing required fields found
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
  SYSTEM_DIR=$(echo "$INPUT" | jq -r '.system_dir // empty')
else
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

SYSTEM_DIR="${SYSTEM_DIR:-.scriptorium}"

# ─── Scope check: Write tool, .md files only ─────────────────────────────────
[[ "$TOOL_NAME" == "Write" ]] || exit 0
[[ "$FILE_PATH" == *.md ]]   || exit 0
[[ -n "$FILE_PATH" ]]        || exit 0

# ─── Skip structural filenames ───────────────────────────────────────────────
# These files are Scriptorium infrastructure, not content notes.
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  _index.md|_brief.md|README.md|SCHEMA.md) exit 0 ;;
esac

# ─── Skip system directories ─────────────────────────────────────────────────
# Check for path components that identify system locations. We match both
# "/<dir>/" (path component) and "<dir>/" at the start (relative path) to
# handle paths regardless of whether they are absolute or relative.
for SYS_DIR in "Meta/" "${SYSTEM_DIR}/" "agents/" "skills/" "coordination/" \
               "adapters/" "vault-template/"; do
  if [[ "$FILE_PATH" == *"/${SYS_DIR}"* || "$FILE_PATH" == "${SYS_DIR}"* ]]; then
    exit 0
  fi
done

# ─── Read the file from disk ──────────────────────────────────────────────────
# PostToolUse fires after the Write completes, so the file is on disk.
[[ -f "$FILE_PATH" ]] || exit 0   # Safety: file might not exist in edge cases

CONTENT=$(cat "$FILE_PATH")

# Accumulate errors (hard) and warnings (soft) separately.
ERRORS=()
WARNINGS=()

# ─── Check for frontmatter block ─────────────────────────────────────────────
# Frontmatter must begin with --- on the very first line.
FIRST_LINE=$(printf '%s\n' "$CONTENT" | head -1)
if [[ "$FIRST_LINE" != "---" ]]; then
  # No frontmatter — not an error; the note may be a capture stub.
  # Quaestor adds frontmatter during filing.
  exit 0
fi

# ─── Extract frontmatter content ─────────────────────────────────────────────
# Collect all lines between the opening --- and the closing ---
# (the first occurrence of --- after line 1).
FRONTMATTER=$(printf '%s\n' "$CONTENT" | awk 'NR>1 { if (/^---$/) { exit } print }')

# Count closing --- markers after line 1
CLOSE_COUNT=$(printf '%s\n' "$CONTENT" | awk 'NR>1 && /^---$/ { count++ } END { print count+0 }')

# ─── Syntax check 1: frontmatter must be closed ───────────────────────────────
if [[ "$CLOSE_COUNT" -lt 1 ]]; then
  ERRORS+=("Frontmatter opened with '---' but no closing '---' found")
fi

# ─── Syntax check 2: no hard tab characters in frontmatter ───────────────────
# YAML forbids tabs; a tab in frontmatter will break any YAML parser.
if printf '%s\n' "$FRONTMATTER" | grep -qP '\t' 2>/dev/null; then
  # Perl regex available (most systems) — use it for tab detection
  ERRORS+=("Frontmatter contains hard tab character(s) — YAML requires spaces for indentation")
elif printf '%s\n' "$FRONTMATTER" | grep -q $'\t'; then
  # POSIX fallback for tab detection
  ERRORS+=("Frontmatter contains hard tab character(s) — YAML requires spaces for indentation")
fi

# ─── Syntax check 3: heuristic check for unquoted colon-in-value ─────────────
# A line like "key: value: something" can confuse YAML parsers.
# This check is a heuristic — it cannot be 100% accurate without a real YAML
# parser. It flags lines that look like "scalar-key: unquoted-value: more".
# Lines starting with quotes, block scalars (| >), or list markers are excluded.
while IFS= read -r LINE; do
  # Skip blank lines, comment lines, and list items
  [[ -z "${LINE// }" ]]        && continue
  [[ "$LINE" =~ ^[[:space:]]*# ]] && continue
  [[ "$LINE" =~ ^[[:space:]]*- ]] && continue
  # Skip lines where the value starts with a quote or block scalar indicator
  if echo "$LINE" | grep -qE '^[^:]+:[[:space:]]*["\'"'"'|>]'; then
    continue
  fi
  # Flag: key followed by value containing another ": " (colon-space)
  # Pattern: word-chars: non-empty-value-without-quotes that itself has ": "
  if echo "$LINE" | grep -qE '^[[:alnum:]_-]+:[[:space:]]+[^"'"'"'][^:]*:[[:space:]]'; then
    WARNINGS+=("Possible unquoted colon in frontmatter value (may break strict YAML parsers): ${LINE}")
  fi
done <<< "$FRONTMATTER"

# ─── Helper: test if a field key is present in frontmatter ───────────────────
# Matches "fieldname:" or "fieldname :" at the start of a line.
has_field() {
  local field="$1"
  printf '%s\n' "$FRONTMATTER" | grep -qE "^${field}[[:space:]]*:"
}

# ─── Helper: extract a field's scalar value from frontmatter ─────────────────
get_field() {
  local field="$1"
  printf '%s\n' "$FRONTMATTER" | \
    grep -E "^${field}[[:space:]]*:" | head -1 | \
    sed "s/^${field}[[:space:]]*:[[:space:]]*//" | \
    tr -d '"'"'" | \
    xargs  # trims leading/trailing whitespace
}

# ─── Schema check: required fields on all content notes ──────────────────────
for FIELD in title type date status; do
  if ! has_field "$FIELD"; then
    ERRORS+=("Missing required field: '${FIELD}'")
  fi
done

# ─── Schema check: type value must be a known type ───────────────────────────
if has_field "type"; then
  NOTE_TYPE=$(get_field "type" | tr '[:upper:]' '[:lower:]')
  case "$NOTE_TYPE" in
    inbox|note|reference|meeting|synthesis|journal|daily|review|project)
      # Known type — valid
      ;;
    *)
      WARNINGS+=("Unknown type value: '${NOTE_TYPE}' — expected one of: inbox, note, reference, meeting, synthesis, journal, daily, review, project")
      ;;
  esac

  # ─── Schema check: type-specific required fields ─────────────────────────
  case "$NOTE_TYPE" in
    reference)
      # Reference notes must cite their source and name the author.
      for FIELD in source author; do
        has_field "$FIELD" || ERRORS+=("type 'reference' requires field: '${FIELD}'")
      done
      ;;
    meeting)
      # Meeting notes must record who was present.
      has_field "participants" || ERRORS+=("type 'meeting' requires field: 'participants'")
      ;;
    synthesis)
      # Synthesis notes are scoped to a question and domain.
      for FIELD in topic domain; do
        has_field "$FIELD" || ERRORS+=("type 'synthesis' requires field: '${FIELD}'")
      done
      ;;
  esac
fi

# ─── Schema check: date format ────────────────────────────────────────────────
# date must look like YYYY-MM-DD (ISO 8601 date). We do not validate calendar
# correctness — just structural format.
if has_field "date"; then
  DATE_VAL=$(get_field "date")
  if ! printf '%s\n' "$DATE_VAL" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    WARNINGS+=("date value '${DATE_VAL}' does not match YYYY-MM-DD format")
  fi
fi

# ─── Report results ──────────────────────────────────────────────────────────
if [[ ${#ERRORS[@]} -gt 0 || ${#WARNINGS[@]} -gt 0 ]]; then
  echo "SCRIPTORIUM [validate-frontmatter]: Issues in ${BASENAME}"
  for MSG in "${ERRORS[@]}"; do
    echo "  ERROR: ${MSG}"
  done
  for MSG in "${WARNINGS[@]}"; do
    echo "  WARN:  ${MSG}"
  done
fi

# Exit 1 if there are hard errors; 0 if only warnings (or nothing).
[[ ${#ERRORS[@]} -gt 0 ]] && exit 1
exit 0
