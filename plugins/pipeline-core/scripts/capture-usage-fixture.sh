#!/usr/bin/env bash
#
# capture-usage-fixture.sh — Capture a real claude.ai usage API response
#
# Hits the (private) usage endpoint that Sneaky Penguin and similar menu-bar
# apps poll, saves the JSON to the test fixtures directory, and prints the
# bucket field names so we can map them to the menu-bar's display labels
# (Session 5h / All-models Weekly / Sonnet / Extra Usage).
#
# Why: the proactive-usage-polling design needs the real field names from
# this endpoint before we can implement usage_for_model(). Don't guess.
#
# Required input (env var, prompt, or file):
#   CLAUDE_USAGE_SESSION_KEY        sessionKey cookie from claude.ai
#   CLAUDE_USAGE_SESSION_KEY_FILE   alternative: path to file containing key (0600)
#   CLAUDE_USAGE_ORG_ID             organization UUID
#
# Output:
#   .claude/scripts/implement-issue-test/fixtures/usage-response.json
#
# Usage:
#   .claude/scripts/capture-usage-fixture.sh                     # interactive prompts
#   CLAUDE_USAGE_SESSION_KEY=sk-ant-... CLAUDE_USAGE_ORG_ID=uuid \
#     .claude/scripts/capture-usage-fixture.sh                   # fully scripted
#
# Security notes:
#   - The sessionKey is a long-lived bearer-equivalent for your claude.ai
#     account. This script reads it once into a local variable and passes it
#     to curl via -H (header — not visible in /proc/PID/cmdline) instead of
#     -b (cookie file path or inline). The key value is never echoed, never
#     logged, never written to status.json, never appears in the saved
#     fixture (the response itself contains usage data only).
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$SCRIPT_DIR/implement-issue-test/fixtures/usage-response.json"

err() { printf 'error: %s\n' "$*" >&2; }

command -v curl >/dev/null 2>&1 || { err "curl required"; exit 2; }
command -v jq >/dev/null 2>&1 || { err "jq required"; exit 2; }

# Source the runtime module so we share its env-var > file resolution
# (_session_key_value) — keeps both paths in sync if it ever grows.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/claude-usage.sh"

# --- session key (env var > file > prompt) ---------------------------------

session_key=""
if ! session_key=$(_session_key_value 2>/dev/null) || [[ -z "$session_key" ]]; then
    printf 'Paste sessionKey (input hidden, starts with sk-ant-sid01-): ' >&2
    # -s suppresses echo; -r preserves backslashes in the value.
    IFS= read -rs session_key
    printf '\n' >&2
fi

if [[ -z "$session_key" ]]; then
    err "no sessionKey provided"
    exit 2
fi

# Cheap sanity check — don't log the value, just confirm shape.
if [[ ! "$session_key" =~ ^sk-ant- ]]; then
    err "sessionKey doesn't start with 'sk-ant-' — wrong cookie?"
    err "(get it from claude.ai DevTools → Application → Cookies → sessionKey)"
    exit 2
fi

# --- org id (env var > prompt) ---------------------------------------------

org_id="${CLAUDE_USAGE_ORG_ID:-}"
if [[ -z "$org_id" ]]; then
    printf 'Organization UUID: ' >&2
    IFS= read -r org_id
fi

if [[ -z "$org_id" ]]; then
    err "no org_id provided"
    err "(find it in DevTools → Network tab on claude.ai — any /api/organizations/{uuid}/ request)"
    exit 2
fi

# --- fetch -----------------------------------------------------------------

url="https://claude.ai/api/organizations/${org_id}/usage"
printf 'Fetching: %s\n' "$url" >&2

http_status=0
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

http_status=$(curl -sS \
    --connect-timeout 5 \
    --max-time 15 \
    -o "$body_file" \
    -w '%{http_code}' \
    -H "Cookie: sessionKey=${session_key}" \
    -H "Accept: application/json" \
    "$url" 2>&1) || {
    err "curl failed: $http_status"
    exit 1
}

if [[ "$http_status" != "200" ]]; then
    err "HTTP $http_status from $url"
    err "first 200 bytes of response body:"
    head -c 200 "$body_file" >&2
    printf '\n' >&2
    exit 1
fi

if ! jq empty "$body_file" 2>/dev/null; then
    err "response is not valid JSON"
    err "first 200 bytes:"
    head -c 200 "$body_file" >&2
    printf '\n' >&2
    exit 1
fi

# --- save fixture ----------------------------------------------------------

mkdir -p "$(dirname "$FIXTURE")"
jq . "$body_file" > "$FIXTURE"
printf 'Saved fixture: %s (%d bytes)\n' "$FIXTURE" "$(wc -c < "$FIXTURE" | tr -d ' ')" >&2

# --- summarize field structure --------------------------------------------

printf '\n' >&2
printf 'Top-level field names:\n' >&2
jq -r 'keys[]' "$FIXTURE" | sed 's/^/  /' >&2

printf '\nBucket-shaped fields (objects with a numeric utilization or limit):\n' >&2
jq -r '
  paths(type == "object" and (
    has("utilization_pct") or has("usage") or has("limit") or
    has("remaining") or has("resets_at") or has("reset_at")
  )) | join(".")
' "$FIXTURE" 2>/dev/null | sed 's/^/  /' >&2 || true

printf '\nReset timestamps found:\n' >&2
jq -r '
  paths(type == "string") as $p |
  getpath($p) as $v |
  select($p[-1] | test("reset"; "i")) |
  "  \($p | join(\".\")) = \($v)"
' "$FIXTURE" 2>/dev/null >&2 || true

printf '\n' >&2
printf 'Next: paste this fixture (or just the field names) so the design can\n' >&2
printf 'map each bucket to a model in the v3 polling proposal.\n' >&2
