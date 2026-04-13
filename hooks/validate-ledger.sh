#!/usr/bin/env bash
# =============================================================================
# validate-ledger.sh
# =============================================================================
#
# WHAT IT DOES:
#   Fires after every Write or Edit on Meta/ledger/session.yaml. Validates the
#   structural integrity of Scriptorium's session ledger — the live record of
#   all agent handoffs and receipts. A structurally malformed ledger causes
#   silent coordination failures: the dispatcher reads a corrupt structure and
#   either misroutes agents or fails to resolve in-flight receipt chains.
#
# WHY THIS HOOK IS UNIQUE TO SCRIPTORIUM:
#   The session ledger is an active runtime artifact that multiple agents write
#   to concurrently (every handoff and receipt is logged). No other hook in the
#   system validates coordination infrastructure — other hooks focus on content
#   files. This hook fills that gap.
#
# SCOPE:
#   Only fires on: Meta/ledger/session.yaml
#   Skips archive files (Meta/ledger/archive-*.yaml) intentionally — archives
#   are written by the ledger rotation logic, which is responsible for their
#   structural correctness. Validating them on every write would be redundant
#   and noisy.
#
# WHAT IT CHECKS:
#   Top-level structure:
#     1. File is not empty
#     2. max_entries field present and numeric
#     3. open_receipts field present
#     4. entries field present
#
#   open_receipts entries (if any):
#     Each entry must have: id, from, to, waiting_since
#
#   entries list entries (if any):
#     Each entry must have: timestamp, type, from, to, id, status
#     - type must be "handoff" or "receipt"
#     - status must be "open" or "resolved"
#
# PARSING APPROACH:
#   This hook does not invoke a YAML parser — it uses awk and grep to walk the
#   indented YAML structure. This is intentional: hooks must work without
#   external dependencies. The ledger's structure is well-defined and shallow
#   (max 2 levels of nesting), making line-oriented parsing reliable.
#
#   The parser works by:
#     - Extracting the block under each top-level key using awk
#     - Walking each list item (lines starting with "  - ") as an entry boundary
#     - Grepping within each accumulated entry block for required field keys
#
# EXIT CODES:
#   0 — valid structure, or file is out of scope
#   1 — warn: structural issues found (does not block the write — the ledger
#       write already completed; this is a post-hoc integrity signal)
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

# ─── Scope check: Write or Edit on session.yaml only ─────────────────────────
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

[[ -n "$FILE_PATH" ]] || exit 0

# Decompose path to identify Meta/ledger/session.yaml precisely.
# We match by the three trailing components: grandparent=Meta, parent=ledger,
# basename=session.yaml. This avoids false matches from similarly-named files
# elsewhere in the vault.
BASENAME=$(basename "$FILE_PATH")
PARENT=$(basename "$(dirname "$FILE_PATH")")
GRANDPARENT=$(basename "$(dirname "$(dirname "$FILE_PATH")")")

if [[ "$BASENAME" != "session.yaml" || \
      "$PARENT"   != "ledger"       || \
      "$GRANDPARENT" != "Meta" ]]; then
  exit 0
fi

# ─── Read the ledger file from disk ──────────────────────────────────────────
[[ -f "$FILE_PATH" ]] || exit 0

CONTENT=$(cat "$FILE_PATH")
ERRORS=()

# ─── Check 1: File is not empty ──────────────────────────────────────────────
STRIPPED=$(printf '%s' "$CONTENT" | tr -d '[:space:]')
if [[ -z "$STRIPPED" ]]; then
  echo "SCRIPTORIUM [validate-ledger]: session ledger is empty"
  exit 1
fi

# ─── Check 2: max_entries is present and numeric ─────────────────────────────
if ! printf '%s\n' "$CONTENT" | grep -qE '^max_entries[[:space:]]*:[[:space:]]*[0-9]+'; then
  ERRORS+=("'max_entries' field is missing or its value is not a positive integer")
fi

# ─── Check 3: open_receipts field is present ─────────────────────────────────
if ! printf '%s\n' "$CONTENT" | grep -qE '^open_receipts[[:space:]]*:'; then
  ERRORS+=("'open_receipts' field is missing")
fi

# ─── Check 4: entries field is present ───────────────────────────────────────
if ! printf '%s\n' "$CONTENT" | grep -qE '^entries[[:space:]]*:'; then
  ERRORS+=("'entries' field is missing")
fi

# ─── Helper: extract a YAML block under a top-level key ──────────────────────
# Reads from the line after "key:" until the next top-level key (line that
# starts with a letter, not a space) or end of file.
# Usage: extract_block "open_receipts"
extract_block() {
  local key="$1"
  printf '%s\n' "$CONTENT" | awk -v k="^${key}[[:space:]]*:" \
    'found && /^[a-zA-Z_]/ { exit }
     found { print }
     $0 ~ k { found=1 }'
}

# ─── Helper: validate a list of YAML objects for required fields ──────────────
# Walks a block of YAML list items (entries starting with "  - ").
# For each item, checks that all required fields are present.
# Reports errors into the ERRORS array (global via nameref or direct).
# Usage: validate_entries_block <block_text> <section_name> <required_fields...>
validate_entries_block() {
  local block="$1"
  local section="$2"
  shift 2
  local required_fields=("$@")

  # If the block is empty or the section was declared as an inline empty list [],
  # there are no entries to validate.
  [[ -z "${block// }" ]] && return
  printf '%s\n' "$CONTENT" | grep -qE "^${section}[[:space:]]*:[[:space:]]*\[\]" && return

  local entry_num=0
  local current_entry=""

  while IFS= read -r LINE; do
    if [[ "$LINE" =~ ^[[:space:]]{1,2}-[[:space:]] ]]; then
      # This line starts a new list item. Validate the previous one first.
      if [[ -n "$current_entry" ]]; then
        entry_num=$((entry_num + 1))
        for FIELD in "${required_fields[@]}"; do
          if ! printf '%s\n' "$current_entry" | grep -qE "${FIELD}[[:space:]]*:"; then
            ERRORS+=("${section}[${entry_num}]: missing required field '${FIELD}'")
          fi
        done
      fi
      current_entry="$LINE"
    elif [[ "$LINE" =~ ^[[:space:]] ]]; then
      # Continuation line of the current item (indented deeper)
      current_entry+=$'\n'"$LINE"
    fi
  done <<< "$block"

  # Validate the final item (loop ends without triggering the boundary check)
  if [[ -n "$current_entry" ]]; then
    entry_num=$((entry_num + 1))
    for FIELD in "${required_fields[@]}"; do
      if ! printf '%s\n' "$current_entry" | grep -qE "${FIELD}[[:space:]]*:"; then
        ERRORS+=("${section}[${entry_num}]: missing required field '${FIELD}'")
      fi
    done
  fi
}

# ─── Check 5: Validate open_receipts entries ─────────────────────────────────
# Each open receipt represents a handoff that has been sent but whose receipt
# has not yet arrived. Required fields: id, from, to, waiting_since.
RECEIPTS_BLOCK=$(extract_block "open_receipts")
validate_entries_block "$RECEIPTS_BLOCK" "open_receipts" id from to waiting_since

# ─── Check 6: Validate entries ───────────────────────────────────────────────
# Each entry is a logged handoff or receipt. Required: timestamp, type, from,
# to, id, status. Additionally, type and status have constrained enum values.
ENTRIES_BLOCK=$(extract_block "entries")
validate_entries_block "$ENTRIES_BLOCK" "entries" timestamp type from to id status

# ─── Check 7: Enum validation for entries.type and entries.status ─────────────
# Walk the entries block again to check enum values.
# (done after the required-field check so field-missing errors are reported first)
if [[ -n "${ENTRIES_BLOCK// }" ]]; then
  ENTRY_NUM=0
  CURRENT_ENTRY=""

  while IFS= read -r LINE; do
    if [[ "$LINE" =~ ^[[:space:]]{1,2}-[[:space:]] ]]; then
      if [[ -n "$CURRENT_ENTRY" ]]; then
        ENTRY_NUM=$((ENTRY_NUM + 1))

        # Check type enum: must be "handoff" or "receipt"
        TYPE_VAL=$(printf '%s\n' "$CURRENT_ENTRY" | \
          grep -E '^[[:space:]]*type[[:space:]]*:' | head -1 | \
          sed 's/.*type[[:space:]]*:[[:space:]]*//' | tr -d '"'"'" | xargs)
        if [[ -n "$TYPE_VAL" ]] && \
           [[ "$TYPE_VAL" != "handoff" && "$TYPE_VAL" != "receipt" ]]; then
          ERRORS+=("entries[${ENTRY_NUM}]: 'type' must be 'handoff' or 'receipt', got '${TYPE_VAL}'")
        fi

        # Check status enum: must be "open" or "resolved"
        STATUS_VAL=$(printf '%s\n' "$CURRENT_ENTRY" | \
          grep -E '^[[:space:]]*status[[:space:]]*:' | head -1 | \
          sed 's/.*status[[:space:]]*:[[:space:]]*//' | tr -d '"'"'" | xargs)
        if [[ -n "$STATUS_VAL" ]] && \
           [[ "$STATUS_VAL" != "open" && "$STATUS_VAL" != "resolved" ]]; then
          ERRORS+=("entries[${ENTRY_NUM}]: 'status' must be 'open' or 'resolved', got '${STATUS_VAL}'")
        fi
      fi
      CURRENT_ENTRY="$LINE"
    elif [[ "$LINE" =~ ^[[:space:]] ]]; then
      CURRENT_ENTRY+=$'\n'"$LINE"
    fi
  done <<< "$ENTRIES_BLOCK"

  # Final entry enum check
  if [[ -n "$CURRENT_ENTRY" ]]; then
    ENTRY_NUM=$((ENTRY_NUM + 1))
    TYPE_VAL=$(printf '%s\n' "$CURRENT_ENTRY" | \
      grep -E '^[[:space:]]*type[[:space:]]*:' | head -1 | \
      sed 's/.*type[[:space:]]*:[[:space:]]*//' | tr -d '"'"'" | xargs)
    if [[ -n "$TYPE_VAL" ]] && \
       [[ "$TYPE_VAL" != "handoff" && "$TYPE_VAL" != "receipt" ]]; then
      ERRORS+=("entries[${ENTRY_NUM}]: 'type' must be 'handoff' or 'receipt', got '${TYPE_VAL}'")
    fi

    STATUS_VAL=$(printf '%s\n' "$CURRENT_ENTRY" | \
      grep -E '^[[:space:]]*status[[:space:]]*:' | head -1 | \
      sed 's/.*status[[:space:]]*:[[:space:]]*//' | tr -d '"'"'" | xargs)
    if [[ -n "$STATUS_VAL" ]] && \
       [[ "$STATUS_VAL" != "open" && "$STATUS_VAL" != "resolved" ]]; then
      ERRORS+=("entries[${ENTRY_NUM}]: 'status' must be 'open' or 'resolved', got '${STATUS_VAL}'")
    fi
  fi
fi

# ─── Report results ──────────────────────────────────────────────────────────
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "SCRIPTORIUM [validate-ledger]: Structural issues in session.yaml"
  for MSG in "${ERRORS[@]}"; do
    echo "  - ${MSG}"
  done
  exit 1
fi

exit 0
