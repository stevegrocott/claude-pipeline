#!/usr/bin/env bash
#
# rtk-rewrite.sh — PreToolUse Bash hook that rewrites verbose commands through RTK
# (Rust Token Killer) to reduce LLM token consumption.
#
# Hook input  (stdin): {"tool_name":"Bash","tool_input":{"command":"..."}}
# Hook output (stdout): {"tool_input":{"command":"rtk <original-cmd>"}}  — when rewriting
#                       (empty)                                            — when passing through
# Exit 0 always (never blocks).
#
# Guard conditions (hook no-ops when any are true):
#   1. RTK_ENABLED is not exactly "1"
#   2. rtk binary is not on PATH
#   3. Tool is not Bash
#   4. Command is parse-sensitive (piped to jq, gh, bats, or uses structured git output)
#   5. Command verb is not in the allowlist
#
# Allowlisted command verbs (safe for RTK truncation):
#   git status, git diff, ls, grep, find
#
# Setup:    brew install rtk  OR  curl -fsSL https://rtk.sh | sh
# Enable:   export RTK_ENABLED=1  (or set in shell profile)
# Rollback: unset RTK_ENABLED  (or set RTK_ENABLED=0)

set -o pipefail

# ---------------------------------------------------------------------------
# Configuration — sourced from platform.sh when available
# ---------------------------------------------------------------------------
_PLATFORM_SH="${CLAUDE_PROJECT_DIR:-.}/.claude/config/platform.sh"
if [[ -f "$_PLATFORM_SH" ]]; then
    # shellcheck source=/dev/null
    source "$_PLATFORM_SH"
fi

# ---------------------------------------------------------------------------
# RTK_ENABLED guard — exit immediately if opt-in flag is not set to 1
# ---------------------------------------------------------------------------
if [[ "${RTK_ENABLED:-0}" != "1" ]]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Binary presence guard — exit immediately if rtk is not installed
# ---------------------------------------------------------------------------
if ! command -v rtk > /dev/null 2>&1; then
    exit 0
fi

# ---------------------------------------------------------------------------
# read_input — consume stdin and return the full JSON payload
# ---------------------------------------------------------------------------
read_input() {
    local json=""
    local line
    # `|| [[ -n "$line" ]]` captures a final line lacking a trailing newline
    # (e.g. payloads emitted by printf), which a bare read would otherwise drop.
    while IFS= read -r line || [[ -n "$line" ]]; do
        json+="$line"$'\n'
    done
    printf '%s' "$json"
}

# ---------------------------------------------------------------------------
# extract_command — parse command string from Bash tool JSON
# Returns empty string for non-Bash tool calls.
# ---------------------------------------------------------------------------
extract_command() {
    local json="$1"

    # Only rewrite Bash tool invocations
    if [[ "$json" != *'"tool_name":"Bash"'* && \
          "$json" != *'"tool_name": "Bash"'* ]]; then
        return 0
    fi

    if command -v python3 > /dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    if d.get("tool_name") == "Bash":
        print(d.get("tool_input", {}).get("command", ""), end="")
except Exception:
    pass
' <<< "$json"
        return
    fi

    # Pure-bash fallback
    local after="${json#*\"command\":}"
    after="${after# }"
    [[ "${after:0:1}" == '"' ]] || return 0
    after="${after:1}"

    local cmd="" i char prev=""
    for (( i=0; i<${#after}; i++ )); do
        char="${after:$i:1}"
        if [[ "$prev" == '\' ]]; then
            case "$char" in
                n) cmd="${cmd%\\}"$'\n' ;;
                t) cmd="${cmd%\\}"$'\t' ;;
                '"') cmd="${cmd%\\}\"" ;;
                "\\") cmd="${cmd%\\}\\" ;;
                *) cmd+="$char" ;;
            esac
            prev=""
            continue
        fi
        [[ "$char" == '"' ]] && break
        cmd+="$char"
        prev="$char"
    done
    printf '%s' "$cmd"
}

# ---------------------------------------------------------------------------
# is_parse_sensitive — returns 0 (true) if the command output is parsed by
# other tools and must NOT be rewritten/truncated by RTK.
# ---------------------------------------------------------------------------
is_parse_sensitive() {
    local cmd="$1"
    [[ "$cmd" == *"| jq"*    ]] && return 0
    [[ "$cmd" == *"|jq"*     ]] && return 0
    [[ "$cmd" == *"| gh"*    ]] && return 0
    [[ "$cmd" == *"|gh"*     ]] && return 0
    [[ "$cmd" == *"| bats"*  ]] && return 0
    [[ "$cmd" == *"|bats"*   ]] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# rtk_prefix — returns the RTK-prefixed command if the leading verb is in
# the allowlist, otherwise returns empty string.
# Allowlist: git status, git diff, ls, grep, find
# ---------------------------------------------------------------------------
rtk_prefix() {
    local cmd="$1"
    # Trim leading whitespace
    local trimmed="${cmd#"${cmd%%[![:space:]]*}"}"

    case "$trimmed" in
        "git status"*)  printf 'rtk %s' "$cmd" ; return ;;
        "git diff"*)    printf 'rtk %s' "$cmd" ; return ;;
        "ls"*)          printf 'rtk %s' "$cmd" ; return ;;
        "grep"*)        printf 'rtk %s' "$cmd" ; return ;;
        "find"*)        printf 'rtk %s' "$cmd" ; return ;;
    esac
    # Not in allowlist — return empty to signal no rewrite
    return 0
}

# ---------------------------------------------------------------------------
# escape_json_string — minimal JSON string escaping for the rewritten command
# ---------------------------------------------------------------------------
escape_json_string() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    local json
    json=$(read_input)

    local cmd
    cmd=$(extract_command "$json")

    # Empty → non-Bash tool call or no command; pass through
    [[ -z "$cmd" ]] && exit 0

    # Parse-sensitive commands must not be rewritten
    is_parse_sensitive "$cmd" && exit 0

    # Compute RTK-prefixed command
    local rewritten
    rewritten=$(rtk_prefix "$cmd")

    # No rewrite for this command verb
    [[ -z "$rewritten" ]] && exit 0

    # Output modified tool_input JSON
    local escaped
    escaped=$(escape_json_string "$rewritten")
    printf '{"tool_input":{"command":"%s"}}' "$escaped"
}

main "$@"
