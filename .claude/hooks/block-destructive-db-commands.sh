#!/usr/bin/env bash
#
# block-destructive-db-commands.sh - Claude PreToolUse hook that blocks
# destructive database and volume commands from executing.
#
# Hook format (stdin): {"tool_name":"Bash","tool_input":{"command":"..."}}
# Exit 2 = block with warning message (printed to stdout as JSON)
# Exit 0 = allow command through
#
# Test cases (see bottom of file for runnable examples):
#
#   BLOCKED:
#     DROP TABLE users;
#     DROP DATABASE mydb;
#     TRUNCATE sessions;
#     DELETE FROM logs;          (no WHERE clause)
#     prisma migrate reset
#     prisma db push
#     docker-compose down -v
#     docker system prune --volumes
#     docker volume rm pgdata
#     rm -rf /data
#     rm -rf /docker-data/postgres
#     ssh host "psql -c 'DROP TABLE foo'"
#     docker exec db psql -c "DROP TABLE foo"
#
#   ALLOWED:
#     DELETE FROM logs WHERE created_at < NOW() - INTERVAL '30 days';
#     docker-compose down          (no -v flag)
#     docker ps
#     rm -rf /tmp/cache
#     prisma migrate dev
#     prisma migrate deploy
#

set -o pipefail

# ---------------------------------------------------------------------------
# extract_command
#
# Reads JSON from stdin and extracts .tool_input.command.
# Uses python3 when available for reliable JSON parsing; falls back to
# bash parameter expansion.
#
# Outputs the command string to stdout (empty string if not a Bash tool call).
# ---------------------------------------------------------------------------
extract_command() {
	local json=""
	local line

	while IFS= read -r line; do
		json+="$line"$'\n'
	done

	# Only process Bash tool invocations
	if [[ "$json" != *'"tool_name":"Bash"'* && \
		  "$json" != *'"tool_name": "Bash"'* ]]; then
		return 0
	fi

	# Prefer python3 for reliable JSON parsing
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

	# ---- Pure-bash fallback ---------------------------------------------------
	# Strip everything up to and including the first "command": occurrence
	local after="${json#*\"command\":}"

	# Skip optional single space (compact vs pretty JSON)
	after="${after# }"

	# Must now start with opening quote
	[[ "${after:0:1}" == '"' ]] || return 0
	after="${after:1}"	# remove opening "

	# Iterate characters, collect until unescaped closing quote
	local cmd="" i char prev=""
	for (( i=0; i<${#after}; i++ )); do
		char="${after:$i:1}"
		if [[ "$prev" == '\' ]]; then
			# Decode common JSON escape sequences
			case "$char" in
				n) cmd="${cmd%\\}"$'\n' ;;
				t) cmd="${cmd%\\}"$'\t' ;;
				'"') cmd="${cmd%\\}\"" ;;
				"\\") cmd="${cmd%\\}\\" ;;
				*) cmd+="$char" ;;
			esac
			prev="$char"
			continue
		fi
		if [[ "$char" == '"' ]]; then
			break	# end of string
		fi
		cmd+="$char"
		prev="$char"
	done

	printf '%s' "$cmd"
}

# ---------------------------------------------------------------------------
# block
#
# Print a Claude hook block response to stdout and exit 2.
# The harness surfaces this as a pre-execution warning to the user.
# ---------------------------------------------------------------------------
block() {
	local reason="$1"
	# Escape double-quotes in reason for JSON safety
	local safe_reason="${reason//\"/\\\"}"
	printf '{"decision":"block","reason":"%s"}' "$safe_reason"
	exit 2
}

# ---------------------------------------------------------------------------
# check_destructive_patterns
#
# Applies all pattern checks against the command string.
# Calls block() on first match — never returns on a blocked command.
# ---------------------------------------------------------------------------
check_destructive_patterns() {
	local cmd="$1"

	# Case-insensitive matching so lowercase SQL (drop table, truncate, etc.) is caught
	shopt -s nocasematch

	# ── DDL: DROP TABLE / DROP DATABASE ────────────────────────────────────
	# Catches bare SQL AND SQL nested inside ssh / docker exec payloads since
	# the full command string (including nested quotes) is checked as-is.
	if [[ "$cmd" =~ DROP[[:space:]]+(TABLE|DATABASE)([[:space:]]|;|$) ]]; then
		block "Blocked: DROP ${BASH_REMATCH[1]} is a destructive DDL operation. Use migrations to remove schema objects."
	fi

	# ── DDL: TRUNCATE ───────────────────────────────────────────────────────
	if [[ "$cmd" =~ TRUNCATE[[:space:]]+ ]]; then
		block "Blocked: TRUNCATE destroys all rows without a WHERE clause. Use targeted DELETE statements instead."
	fi

	# ── DML: DELETE FROM <table> without WHERE ─────────────────────────────
	# Strategy: match DELETE FROM <identifier>, then verify no WHERE exists
	# before the next semicolon (or end of input).
	if [[ "$cmd" =~ DELETE[[:space:]]+FROM[[:space:]]+[[:alnum:]_]+ ]]; then
		local stmt="${cmd#*DELETE}"
		stmt="${stmt%%;*}"
		if [[ "$stmt" != *WHERE* && "$stmt" != *where* ]]; then
			block "Blocked: DELETE FROM without a WHERE clause would erase all rows. Add a WHERE condition."
		fi
	fi

	# ── Prisma: migrate reset / db push ────────────────────────────────────
	if [[ "$cmd" =~ prisma[[:space:]]+(db[[:space:]]+push|migrate[[:space:]]+reset) ]]; then
		block "Blocked: '${BASH_REMATCH[1]}' drops and recreates the database schema. Use 'prisma migrate deploy' for safe migrations."
	fi

	# ── Docker: volume-destroying down -v ──────────────────────────────────
	# Matches: docker-compose down -v, docker compose down -v, docker down -v
	# The flag -v may appear anywhere after "down" on the command line.
	if [[ "$cmd" =~ (docker-compose|docker[[:space:]]compose)[[:space:]].*down ]] || \
	   [[ "$cmd" =~ docker[[:space:]].*[[:space:]]down[[:space:]] ]]; then
		# Check if -v appears as a standalone flag after "down"
		local after_down="${cmd#*down }"
		if [[ "$after_down" =~ (^|[[:space:]])-[[:alpha:]]*v([[:space:]]|$) || \
			  "$after_down" =~ (^|[[:space:]])--volumes([[:space:]]|$) ]]; then
			block "Blocked: 'docker ... down -v' removes named volumes, destroying persistent database data."
		fi
	fi

	if [[ "$cmd" =~ docker[[:space:]].*system[[:space:]]+prune.*--volumes ]]; then
		block "Blocked: 'docker system prune --volumes' removes all unused volumes including database data."
	fi

	if [[ "$cmd" =~ docker[[:space:]].*volume[[:space:]]+rm[[:space:]] ]]; then
		block "Blocked: 'docker volume rm' permanently deletes volume data."
	fi

	# ── Filesystem: rm -rf targeting data directories ──────────────────────
	# Matches absolute paths (/data, /docker-data, /postgres) AND relative
	# project-root-relative paths (data/, docker-data/, postgres/) since both
	# point to the same data from the project root.
	if [[ "$cmd" =~ rm[[:space:]].*-[[:alpha:]]*r[[:alpha:]]*f[[:space:]].*/(data|docker-data|postgres) || \
		  "$cmd" =~ rm[[:space:]].*-[[:alpha:]]*f[[:alpha:]]*r[[:space:]].*/(data|docker-data|postgres) || \
		  "$cmd" =~ rm[[:space:]].*-[[:alpha:]]*r[[:alpha:]]*f[[:space:]]+(data|docker-data|postgres)([[:space:]/]|$) || \
		  "$cmd" =~ rm[[:space:]].*-[[:alpha:]]*f[[:alpha:]]*r[[:space:]]+(data|docker-data|postgres)([[:space:]/]|$) ]]; then
		block "Blocked: 'rm -rf' targeting a data directory would permanently destroy database files."
	fi

	# ── Docker: volume prune ────────────────────────────────────────────────
	if [[ "$cmd" =~ docker[[:space:]].*volume[[:space:]]+prune ]]; then
		block "Blocked: 'docker volume prune' removes all unused volumes including database data."
	fi

	shopt -u nocasematch
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local cmd

	cmd=$(extract_command)

	# Nothing to check — not a Bash tool call or command is empty
	if [[ -z "$cmd" ]]; then
		exit 0
	fi

	check_destructive_patterns "$cmd"

	# No destructive pattern matched — allow
	exit 0
}

main "$@"

# =============================================================================
# MANUAL TEST CASES
# =============================================================================
# Run these to verify behavior (exit 2 = blocked, exit 0 = allowed):
#
# SHOULD BE BLOCKED (exit 2):
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"DROP TABLE users;"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"DROP DATABASE mydb;"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"TRUNCATE sessions;"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"DELETE FROM logs;"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"npx prisma migrate reset"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"npx prisma db push"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"docker-compose down -v"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"docker compose down -v --remove-orphans"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"docker system prune --volumes -f"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"docker volume rm pgdata"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /data"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /docker-data/postgres"}}' \
#     | bash block-destructive-db-commands.sh
#
#   # SSH edge case - DROP TABLE inside SSH payload
#   echo '{"tool_name":"Bash","tool_input":{"command":"ssh host \"psql -c DROP TABLE foo\""}}' \
#     | bash block-destructive-db-commands.sh
#
#   # docker exec edge case - DROP TABLE inside docker exec payload
#   echo '{"tool_name":"Bash","tool_input":{"command":"docker exec db psql -c DROP TABLE foo"}}' \
#     | bash block-destructive-db-commands.sh
#
# SHOULD BE ALLOWED (exit 0):
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"DELETE FROM logs WHERE created_at < NOW();"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"docker-compose down"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"docker ps"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/cache"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"npx prisma migrate deploy"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"npx prisma migrate dev"}}' \
#     | bash block-destructive-db-commands.sh
#
#   echo '{"tool_name":"Write","tool_input":{"file_path":"foo","content":"DROP TABLE"}}' \
#     | bash block-destructive-db-commands.sh
