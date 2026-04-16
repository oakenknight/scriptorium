#!/usr/bin/env bash
# =============================================================================
# install.sh — Scriptorium deployment script for Claude Code
# =============================================================================
#
# Copies the Scriptorium system from the Scriptorium repository into a vault
# directory so that Claude Code can use it. Handles both fresh installs and
# upgrades while preserving vault content and user-created files.
#
# USAGE:
#   bash install.sh [<vault-path>] [--dry-run] [--force] [--help]
#
#   <vault-path>   Directory to deploy into. Defaults to the current
#                  working directory. Will be created if it does not exist.
#   --dry-run      Print what would be done without writing any files.
#   --force        On upgrades, also replace CLAUDE.md even if it has been
#                  modified. Default is to replace it (it is a system file).
#   --help         Print this help and exit.
#
# WHAT IT DEPLOYS:
#   System files (always written — these are Scriptorium source):
#     agents/<core-agent>.md     7 built-in agent definitions
#     skills/*.md                8 skill definitions + SCHEMA.md
#     coordination/              dispatcher.md + ledger-schema.yaml
#     CLAUDE.md                  Claude Code adapter / dispatcher entry point
#     .scriptorium/hooks/*.sh    Hook scripts (executable)
#     .claude/settings.json      Hook registration for Claude Code
#
#   Vault scaffold (written on fresh install; skipped if path already exists):
#     Atrium/_index.md           Section indexes
#     Codex/_index.md
#     Annals/_index.md
#     Cartulary/_index.md
#     Compendium/_index.md
#     Reliquary/_index.md
#     Meta/_index.md
#     Meta/vault.config.yaml     Section path config (single source of truth)
#     Meta/registry/domains.yaml Domain registry stub
#     Meta/ledger/session.yaml   Session ledger stub
#     Meta/state/*.yaml          Per-agent and per-skill state stubs
#     Meta/templates/*.md        Note templates
#
# WHAT IT NEVER TOUCHES ON UPGRADE:
#     Meta/vault.config.yaml     (user may have renamed sections)
#     Meta/registry/             (user's domain definitions)
#     Meta/ledger/               (active session history)
#     Meta/state/*.yaml          (in-progress skill state)
#     Meta/templates/            (user may have customized templates)
#     Atrium/, Codex/, Annals/, Cartulary/, Compendium/, Reliquary/
#                                (all vault content)
#     agents/<custom-agent>.md   (any file not in the core agent list)
#
# AFTER INSTALLATION:
#   cd <vault-path>
#   claude
#   Then say: "initialize the vault"
#
# =============================================================================

set -euo pipefail

# ─── Script location → repo root ─────────────────────────────────────────────
# This script lives at adapters/claude-code/install.sh inside the Scriptorium repo.
# We resolve the repo root as two levels up from this script's directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ─── Colour helpers ───────────────────────────────────────────────────────────
# Use tput if the terminal supports colours; otherwise emit plain text.
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
  BOLD=$(tput bold)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  RED=$(tput setaf 1)
  CYAN=$(tput setaf 6)
  DIM=$(tput dim 2>/dev/null || true)
  RESET=$(tput sgr0)
else
  BOLD="" GREEN="" YELLOW="" RED="" CYAN="" DIM="" RESET=""
fi

# ─── Output helpers ───────────────────────────────────────────────────────────
info()    { printf '%s  %s%s\n'          "   " "$*"            "$RESET"; }
ok()      { printf '%s✓ %s%s\n'  "$GREEN"  "$*"            "$RESET"; }
skip()    { printf '%s– %s%s\n'  "$DIM"    "$*"            "$RESET"; }
warn()    { printf '%s⚠ %s%s\n'  "$YELLOW" "$*"            "$RESET"; }
err()     { printf '%s✗ %s%s\n'  "$RED"    "$*"            "$RESET" >&2; }
header()  { printf '\n%s%s%s\n'  "$BOLD$CYAN" "$*"         "$RESET"; }
dryrun()  { printf '%s  [dry-run] %s%s\n' "$YELLOW" "$*"   "$RESET"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
VAULT_PATH=""
DRY_RUN=false
POSITIONAL=()

usage() {
  cat <<EOF
${BOLD}Usage:${RESET}
  bash install.sh [<vault-path>] [--dry-run] [--help]

${BOLD}Arguments:${RESET}
  <vault-path>   Directory to deploy Scriptorium into.
                 Defaults to the current working directory.
                 Will be created if it does not exist.
  --dry-run      Show what would happen without writing files.
  --help         Print this help and exit.

${BOLD}Examples:${RESET}
  bash install.sh ~/my-vault           # deploy to ~/my-vault
  bash install.sh                      # deploy to current directory
  bash install.sh ~/vault --dry-run    # preview without writing
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --help|-h)   usage; exit 0 ;;
    -*)          err "Unknown option: $arg"; echo; usage; exit 1 ;;
    *)           POSITIONAL+=("$arg") ;;
  esac
done

# Resolve vault path
if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  # Path was given — resolve to absolute, creating it if needed
  TARGET="${POSITIONAL[0]}"
  mkdir -p "$TARGET"
  VAULT_PATH="$(cd "$TARGET" && pwd)"
else
  # Default to current directory
  VAULT_PATH="$(pwd)"
fi

# ─── Dry-run notice ───────────────────────────────────────────────────────────
$DRY_RUN && printf '\n%s%s DRY RUN — no files will be written %s\n\n' \
  "$BOLD$YELLOW" "┌─" "─┐$RESET"

# ─── Repo integrity check ─────────────────────────────────────────────────────
# Verify that this script is running from a valid Scriptorium repo and that all
# source files it needs to deploy are present.
header "Checking repository integrity"

REQUIRED_REPO_FILES=(
  "agents/custodian.md"
  "agents/intake.md"
  "agents/quaestor.md"
  "agents/glossator.md"
  "agents/chronicler.md"
  "agents/archivist.md"
  "agents/oracle.md"
  "skills/SCHEMA.md"
  "skills/onboarding.md"
  "coordination/dispatcher.md"
  "coordination/ledger-schema.yaml"
  "hooks/protect-system-files.sh"
  "hooks/validate-frontmatter.sh"
  "hooks/validate-ledger.sh"
  "hooks/validate-state.sh"
  "hooks/notify.sh"
  "adapters/claude-code/CLAUDE.md"
  "adapters/claude-code/settings.json"
  "vault-template/Meta/vault.config.yaml"
)

MISSING_FILES=()
for f in "${REQUIRED_REPO_FILES[@]}"; do
  if [[ ! -f "${REPO_ROOT}/${f}" ]]; then
    MISSING_FILES+=("$f")
  fi
done

if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
  err "Repository is incomplete. Missing files:"
  for f in "${MISSING_FILES[@]}"; do
    err "  ${REPO_ROOT}/${f}"
  done
  err "The Scriptorium repository may be corrupt or this is not the repo root."
  exit 1
fi
ok "Repository looks intact (${REPO_ROOT})"

# ─── Detect fresh install vs upgrade ─────────────────────────────────────────
# A previous installation leaves agents/custodian.md in the vault.
INSTALL_TYPE="fresh"
if [[ -f "${VAULT_PATH}/agents/custodian.md" ]]; then
  INSTALL_TYPE="upgrade"
fi

header "Target vault: ${VAULT_PATH}"
if [[ "$INSTALL_TYPE" == "upgrade" ]]; then
  warn "Existing Scriptorium installation detected — running upgrade"
  info "System files will be replaced. Vault content and state will not be touched."
else
  info "No existing installation found — running fresh install"
fi

# ─── Helpers: copy with dry-run awareness ────────────────────────────────────
# cp_file <src> <dst>  — copy a single file, creating parent dirs as needed
cp_file() {
  local src="$1" dst="$2"
  if $DRY_RUN; then
    dryrun "cp ${src} → ${dst}"
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  fi
}

# cp_dir_contents <src-dir> <dst-dir>  — copy all files from src into dst
cp_dir_contents() {
  local src="$1" dst="$2"
  if $DRY_RUN; then
    dryrun "cp -r ${src}/ → ${dst}/"
  else
    mkdir -p "$dst"
    cp -r "${src}/." "$dst/"
  fi
}

# scaffold_file <src> <dst>  — copy only if dst does not exist
scaffold_file() {
  local src="$1" dst="$2"
  if [[ -e "$dst" ]]; then
    skip "$(basename "$dst") already exists — skipped"
  else
    cp_file "$src" "$dst"
    ok "Created $(basename "$dst")"
  fi
}

# scaffold_dir_contents <src-dir> <dst-dir>  — copy files that don't exist yet
scaffold_dir_contents() {
  local src="$1" dst="$2"
  local copied=0 skipped=0
  while IFS= read -r -d '' src_file; do
    local rel="${src_file#${src}/}"
    local dst_file="${dst}/${rel}"
    if [[ -e "$dst_file" ]]; then
      skipped=$((skipped + 1))
    else
      cp_file "$src_file" "$dst_file"
      copied=$((copied + 1))
    fi
  done < <(find "$src" -type f -print0)
  if [[ $copied -gt 0 ]]; then
    ok "${dst##*/}: ${copied} file(s) created"
  fi
  if [[ $skipped -gt 0 ]]; then
    skip "${dst##*/}: ${skipped} existing file(s) skipped"
  fi
}

# ─── 1. Core agents ───────────────────────────────────────────────────────────
header "Deploying core agents"
CORE_AGENTS=(custodian intake quaestor glossator chronicler archivist oracle)
for agent in "${CORE_AGENTS[@]}"; do
  src="${REPO_ROOT}/agents/${agent}.md"
  dst="${VAULT_PATH}/agents/${agent}.md"
  cp_file "$src" "$dst"
  ok "agents/${agent}.md"
done

# Preserve custom agents — any file in vault's agents/ that is not a core agent
# is left untouched. We do not delete or overwrite them.
if [[ -d "${VAULT_PATH}/agents" ]]; then
  CUSTOM_COUNT=0
  while IFS= read -r -d '' custom_file; do
    slug="$(basename "$custom_file" .md)"
    is_core=false
    for core in "${CORE_AGENTS[@]}"; do
      [[ "$slug" == "$core" ]] && { is_core=true; break; }
    done
    if ! $is_core; then
      skip "agents/${slug}.md — custom agent, preserved"
      CUSTOM_COUNT=$((CUSTOM_COUNT + 1))
    fi
  done < <(find "${VAULT_PATH}/agents" -name "*.md" -print0)
fi

# ─── 2. Skills ────────────────────────────────────────────────────────────────
header "Deploying skills"
while IFS= read -r -d '' skill_file; do
  rel="$(basename "$skill_file")"
  dst="${VAULT_PATH}/skills/${rel}"
  cp_file "$skill_file" "$dst"
  ok "skills/${rel}"
done < <(find "${REPO_ROOT}/skills" -name "*.md" -print0)

# ─── 3. Coordination ──────────────────────────────────────────────────────────
header "Deploying coordination"
for f in dispatcher.md ledger-schema.yaml; do
  cp_file "${REPO_ROOT}/coordination/${f}" "${VAULT_PATH}/coordination/${f}"
  ok "coordination/${f}"
done

# ─── 4. CLAUDE.md ─────────────────────────────────────────────────────────────
header "Deploying adapter"
CLAUDE_DST="${VAULT_PATH}/CLAUDE.md"
cp_file "${REPO_ROOT}/adapters/claude-code/CLAUDE.md" "$CLAUDE_DST"
ok "CLAUDE.md"

# ─── 5. Hook scripts ──────────────────────────────────────────────────────────
header "Deploying hooks"
HOOKS_DST="${VAULT_PATH}/.scriptorium/hooks"
$DRY_RUN || mkdir -p "$HOOKS_DST"

for sh_file in "${REPO_ROOT}"/hooks/*.sh; do
  basename_sh="$(basename "$sh_file")"
  dst="${HOOKS_DST}/${basename_sh}"
  cp_file "$sh_file" "$dst"
  $DRY_RUN || chmod +x "$dst"
  ok ".scriptorium/hooks/${basename_sh}"
done

# Also copy .hook.yaml metadata files (informational, not read at runtime)
for yaml_file in "${REPO_ROOT}"/hooks/*.hook.yaml; do
  basename_yaml="$(basename "$yaml_file")"
  cp_file "$yaml_file" "${HOOKS_DST}/${basename_yaml}"
  ok ".scriptorium/hooks/${basename_yaml}"
done

# ─── 6. settings.json → .claude/ ─────────────────────────────────────────────
# Claude Code reads project-level hooks from .claude/settings.json.
# The .scriptorium/settings.json in the source repo is the authored version;
# it gets deployed here to the location Claude Code actually reads.
header "Registering hooks with Claude Code"
CLAUDE_DIR="${VAULT_PATH}/.claude"
$DRY_RUN || mkdir -p "$CLAUDE_DIR"

SETTINGS_DST="${CLAUDE_DIR}/settings.json"
if [[ -f "$SETTINGS_DST" ]] && ! $DRY_RUN; then
  # Merge: if the file already exists, check whether it has user-added hooks.
  # For now we overwrite — all hooks in settings.json are Scriptorium-owned.
  # A future version could do a proper JSON merge.
  warn ".claude/settings.json already exists — replacing with Scriptorium hooks"
  warn "If you had custom hooks registered, re-add them after installation."
fi
cp_file "${REPO_ROOT}/adapters/claude-code/settings.json" "$SETTINGS_DST"
ok ".claude/settings.json"

# ─── 7. Vault scaffold (fresh install or missing pieces) ──────────────────────
header "Scaffolding vault structure"

if [[ "$INSTALL_TYPE" == "fresh" ]]; then
  info "Copying vault-template (all files)..."
  # Copy vault-template into the vault, skipping files that already exist.
  # This preserves any content the user may have put there before install.
  scaffold_dir_contents "${REPO_ROOT}/vault-template" "$VAULT_PATH"
else
  # Upgrade: only scaffold files that are genuinely missing.
  # Do NOT touch Meta/vault.config.yaml, state, ledger, registry, templates.
  # DO ensure the section directories and their _index.md files exist
  # in case the user created a vault manually without the scaffold.
  info "Checking for missing scaffold files..."

  SECTIONS=(Atrium Codex Annals Cartulary Compendium Reliquary Meta)
  for section in "${SECTIONS[@]}"; do
    src="${REPO_ROOT}/vault-template/${section}/_index.md"
    dst="${VAULT_PATH}/${section}/_index.md"
    if [[ ! -f "$dst" && -f "$src" ]]; then
      cp_file "$src" "$dst"
      ok "${section}/_index.md created"
    else
      skip "${section}/ already present"
    fi
  done

  # Ensure Meta subdirectories exist (agents write to them; they must be present)
  for subdir in ledger registry state templates; do
    target="${VAULT_PATH}/Meta/${subdir}"
    if [[ ! -d "$target" ]]; then
      $DRY_RUN || mkdir -p "$target"
      ok "Meta/${subdir}/ created"
    else
      skip "Meta/${subdir}/ already present"
    fi
  done

  # vault.config.yaml: scaffold only if missing (upgrade must not overwrite)
  config_dst="${VAULT_PATH}/Meta/vault.config.yaml"
  if [[ ! -f "$config_dst" ]]; then
    cp_file "${REPO_ROOT}/vault-template/Meta/vault.config.yaml" "$config_dst"
    ok "Meta/vault.config.yaml created"
  else
    skip "Meta/vault.config.yaml already present — not replaced"
  fi

  # State stubs: scaffold only the files that are missing (new skills added in
  # an upgrade may not have state stubs yet in an existing vault)
  state_src="${REPO_ROOT}/vault-template/Meta/state"
  state_dst="${VAULT_PATH}/Meta/state"
  NEW_STUBS=0
  for stub in "${state_src}"/*.yaml; do
    stub_name="$(basename "$stub")"
    if [[ ! -f "${state_dst}/${stub_name}" ]]; then
      cp_file "$stub" "${state_dst}/${stub_name}"
      NEW_STUBS=$((NEW_STUBS + 1))
    fi
  done
  [[ $NEW_STUBS -gt 0 ]] && ok "Meta/state: ${NEW_STUBS} new state stub(s) added"
  [[ $NEW_STUBS -eq 0 ]] && skip "Meta/state: all stubs present"
fi

# ─── 8. Write installation marker ─────────────────────────────────────────────
# Store the install timestamp and repo commit (if available) so future upgrades
# can report what version is currently deployed.
MARKER_PATH="${VAULT_PATH}/.scriptorium/version"
INSTALL_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPO_COMMIT="unknown"
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  REPO_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
fi

if ! $DRY_RUN; then
  cat > "$MARKER_PATH" <<EOF
installed_at: "${INSTALL_DATE}"
install_type: ${INSTALL_TYPE}
repo_root: "${REPO_ROOT}"
repo_commit: "${REPO_COMMIT}"
EOF
  ok ".scriptorium/version written"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
printf '\n%s%s%s\n' "$BOLD$GREEN" "─── Installation complete ───" "$RESET"
printf '\n'
printf '  Vault:        %s\n' "$VAULT_PATH"
printf '  Install type: %s\n' "$INSTALL_TYPE"
$DRY_RUN && printf '  %s(dry run — nothing was written)%s\n' "$YELLOW" "$RESET"
printf '\n'

if [[ "$INSTALL_TYPE" == "fresh" ]] || ! $DRY_RUN; then
  printf '%sNext steps:%s\n' "$BOLD" "$RESET"
  printf '\n'
  printf '  1. cd %s\n' "$VAULT_PATH"
  printf '  2. claude\n'
  printf '  3. Say: %s"initialize the vault"%s\n' "$CYAN" "$RESET"
  printf '\n'
  printf '  The onboarding skill will ask about your knowledge domains\n'
  printf '  and active projects, then create the full vault structure.\n'
  printf '\n'
fi

exit 0
