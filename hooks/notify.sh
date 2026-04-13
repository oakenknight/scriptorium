#!/usr/bin/env bash
# =============================================================================
# notify.sh
# =============================================================================
#
# WHAT IT DOES:
#   Fires on Notification events from the Claude Code platform. Sends a
#   desktop notification with "Scriptorium" as the application title, so the
#   user can identify the source of the notification without reading the full
#   message text.
#
# INPUT FORMAT (JSON on stdin):
#   {
#     "message": "The text to display in the notification body"
#   }
#
#   The "title" field from the payload is intentionally ignored — we always
#   use "Scriptorium" as the title for consistent branding. If the platform
#   includes a title override, it is discarded.
#
# PLATFORM SUPPORT:
#   macOS  — osascript (AppleScript, built-in, no dependencies)
#   Linux  — notify-send (requires libnotify-bin; gracefully degrades if absent)
#   Other  — falls back to stderr output so the message is not silently lost
#
# MESSAGE SANITIZATION:
#   The message content is sanitized before passing to osascript to prevent
#   shell injection via a crafted message payload. Specifically:
#     - Double quotes are replaced with single quotes
#     - Backslashes are replaced with forward slashes
#     - Message is truncated to 200 characters (desktop notifications are brief)
#   This is a conservative sanitization; it trades some display fidelity for
#   safety (a " in the message would break the AppleScript string boundary).
#
# FAILURE BEHAVIOR:
#   All platform calls use "|| true" so a failed notification never causes
#   this hook to exit non-zero. Notification failures are non-fatal — the
#   session continues regardless.
#
# EXIT CODES:
#   0 — always (notification events are advisory; failure is non-fatal)
# =============================================================================

set -uo pipefail

# Application name — used as notification title on all platforms.
# This is the only place the app name appears; change it here to rebrand.
APP_NAME="Scriptorium"

# ─── jq detection ─────────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=true
else
  HAS_JQ=false
fi

# ─── Read the full hook payload from stdin ────────────────────────────────────
INPUT=$(cat)

# ─── Extract message from payload ────────────────────────────────────────────
if $HAS_JQ; then
  MESSAGE=$(echo "$INPUT" | jq -r '.message // empty')
else
  # Fallback grep extraction. This works for messages without embedded quotes;
  # messages with escaped JSON sequences may be partially mangled but that is
  # acceptable — the notification is still more useful than silence.
  MESSAGE=$(echo "$INPUT" | \
    grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | \
    sed 's/"message"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
fi

# Nothing to notify if message is empty.
[[ -z "$MESSAGE" ]] && exit 0

# ─── Sanitize message for safe shell embedding ────────────────────────────────
# osascript embeds the message in an AppleScript string literal delimited by
# double quotes. Any double quote in the message would break the string
# boundary and potentially execute arbitrary AppleScript.
# Strategy: replace " with ' (benign substitution), \ with / (prevents escape
# sequences), and cap length to 200 characters.
SAFE_MESSAGE=$(printf '%s' "$MESSAGE" | \
  tr '"' "'"  | \
  tr '\\' '/' | \
  head -c 200)

# ─── Platform detection and notification dispatch ────────────────────────────
OS=$(uname -s 2>/dev/null || echo "unknown")

case "$OS" in
  Darwin)
    # macOS: use osascript (AppleScript) — available on all macOS installs.
    # The "display notification" command shows a banner in Notification Center.
    # "with title" sets the app name shown in the notification header.
    osascript \
      -e "display notification \"${SAFE_MESSAGE}\" with title \"${APP_NAME}\"" \
      2>/dev/null || true
    ;;

  Linux)
    if command -v notify-send >/dev/null 2>&1; then
      # notify-send is the standard Linux desktop notification tool.
      # Package: libnotify-bin (Debian/Ubuntu) or libnotify (Fedora/Arch).
      notify-send \
        --app-name="$APP_NAME" \
        --expire-time=5000 \
        "$APP_NAME" \
        "$SAFE_MESSAGE" \
        2>/dev/null || true
    else
      # notify-send not available — print to stderr so the message is visible
      # in the terminal session even without desktop notification support.
      printf '%s: %s\n' "$APP_NAME" "$MESSAGE" >&2
    fi
    ;;

  *)
    # Unknown platform (FreeBSD, WSL without notification daemon, etc.).
    # Fall back to stderr so the message is not silently lost.
    printf '%s: %s\n' "$APP_NAME" "$MESSAGE" >&2
    ;;
esac

# Notification events always exit 0 — a failed notification is never a reason
# to interrupt the session or retry the tool call.
exit 0
