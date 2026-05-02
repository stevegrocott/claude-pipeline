#!/usr/bin/env bash
#
# events-prune.sh — Delete events.jsonl files older than N days
#
# Usage: events-prune.sh [options] <search-dir>
#
# Finds all events.jsonl files under <search-dir> whose modification time
# is older than --max-age-days (default: 30) and removes them.
#
# Options:
#   -h, --help             Show this help message
#   -n, --dry-run          Print files that would be deleted without deleting
#   --max-age-days <N>     Age threshold in days (default: 30)
#   -v, --verbose          Print each file as it is processed
#
# Exit codes:
#   0   Success (including "nothing to prune")
#   1   Error (bad arguments, unreadable directory, find failure)
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"

# ---------------------------------------------------------------------------
# die — print error to stderr and exit 1
# ---------------------------------------------------------------------------
die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# usage — print help text to stdout
# ---------------------------------------------------------------------------
usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [options] <search-dir>

Delete events.jsonl files older than --max-age-days days.

Options:
    -h, --help             Show this help message
    -n, --dry-run          Print files that would be deleted (no deletion)
    --max-age-days <N>     Age threshold in days (default: 30)
    -v, --verbose          Print each file processed

Arguments:
    search-dir             Directory tree to search for events.jsonl files
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local dry_run=false
	local verbose=false
	local max_age_days=30
	local search_dir=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h|--help)
				usage
				exit 0
				;;
			-n|--dry-run)
				dry_run=true
				shift
				;;
			-v|--verbose)
				verbose=true
				shift
				;;
			--max-age-days)
				[[ $# -ge 2 ]] || die "--max-age-days requires an argument"
				[[ "$2" =~ ^[0-9]+$ ]] \
					|| die "--max-age-days must be a non-negative integer"
				max_age_days="$2"
				shift 2
				;;
			--max-age-days=*)
				local val="${1#--max-age-days=}"
				[[ "$val" =~ ^[0-9]+$ ]] \
					|| die "--max-age-days must be a non-negative integer"
				max_age_days="$val"
				shift
				;;
			--)
				shift
				break
				;;
			-*)
				die "unknown option: $1"
				;;
			*)
				break
				;;
		esac
	done

	[[ $# -ge 1 ]] || die "missing required argument: search-dir"
	search_dir="$1"

	[[ -d "$search_dir" ]] \
		|| die "search-dir does not exist or is not a directory: $search_dir"

	local pruned=0
	local errors=0

	while IFS= read -r -d '' file; do
		if $verbose || $dry_run; then
			printf '%s\n' "$file"
		fi
		if ! $dry_run; then
			if rm -f -- "$file" 2>/dev/null; then
				(( pruned++ )) || true
			else
				printf '%s: warning: failed to remove %s\n' \
					"$SCRIPT_NAME" "$file" >&2
				(( errors++ )) || true
			fi
		else
			(( pruned++ )) || true
		fi
	done < <(
		find "$search_dir" -name "events.jsonl" \
			-mtime +"$max_age_days" -print0 2>/dev/null
	)

	if $verbose; then
		printf '%s: pruned %d file(s)\n' "$SCRIPT_NAME" "$pruned" >&2
	fi

	if (( errors > 0 )); then
		return 1
	fi
	return 0
}

main "$@"
