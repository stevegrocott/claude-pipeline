#!/usr/bin/env bash
#
# event-emit.sh — Append one structured JSON event to the run's event stream
#
# Usage: event-emit.sh '<json-event>'
#
# Validates the JSON event against schemas/pipeline-event.json using jq,
# then appends it as one JSONL line to ${LOG_DIR}/events.jsonl.
# Uses flock(1) for concurrent-safe writes; falls back to mkdir-based
# advisory locking when flock is unavailable (e.g. macOS without
# util-linux).
#
# Environment:
#   LOG_DIR   Directory where events.jsonl lives (required)
#
# Exit codes:
#   0   Event appended successfully
#   1   Schema validation failed (event NOT appended)
#   2   Usage / argument error
#   3   Environment / system error (LOG_DIR unset, unwritable, lock timeout)
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCHEMA_FILE="${SCRIPT_DIR}/schemas/pipeline-event.json"

_err() {
	printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
}

_validate_json() {
	local json="$1"
	if ! jq -e . <<< "$json" > /dev/null 2>&1; then
		_err "event is not valid JSON"
		return 1
	fi
}

_check_required() {
	local event="$1" schema="$2"
	local -a missing=()
	while IFS= read -r field; do
		[[ -n "$field" ]] && missing+=("$field")
	done < <(jq -r --argjson ev "$event" \
		'.required[]? | select(in($ev) | not)' \
		<<< "$schema" 2>/dev/null)
	if (( ${#missing[@]} > 0 )); then
		_err "schema validation failed: missing required field(s): ${missing[*]}"
		return 1
	fi
}

_check_event_enum() {
	local event="$1" schema="$2"
	local value in_enum

	value=$(jq -r '.event // empty' <<< "$event")
	[[ -z "$value" ]] && return 0  # absent — caught by _check_required

	in_enum=$(jq -r \
		--arg v "$value" \
		'.properties.event.enum
		| if . != null then (index($v) != null) else true end' \
		<<< "$schema" 2>/dev/null)

	if [[ "$in_enum" != "true" ]]; then
		_err "schema validation failed: \"event\" value \"$value\" not in enum"
		return 1
	fi
}

_check_oneof_required() {
	local event="$1" schema="$2"
	local event_type
	event_type=$(jq -r '.event // empty' <<< "$event")
	[[ -z "$event_type" ]] && return 0  # absent — caught by _check_required

	local -a missing=()
	while IFS= read -r field; do
		[[ -n "$field" ]] && missing+=("$field")
	done < <(jq -r --argjson ev "$event" --arg et "$event_type" \
		'.oneOf[]?
		| select(.properties.event.const == $et)
		| .required[]?
		| select(in($ev) | not)' \
		<<< "$schema" 2>/dev/null)

	if (( ${#missing[@]} > 0 )); then
		_err "schema validation failed: \"$event_type\" event" \
			"missing required field(s): ${missing[*]}"
		return 1
	fi
}

validate_event() {
	local event="$1"

	_validate_json "$event" || return 1

	if [[ ! -f "$SCHEMA_FILE" ]]; then
		_err "warning: schema not found at $SCHEMA_FILE;" \
			"skipping deep validation"
		return 0
	fi

	local schema
	schema=$(< "$SCHEMA_FILE")
	_check_required "$event" "$schema" || return 1
	_check_event_enum "$event" "$schema" || return 1
	_check_oneof_required "$event" "$schema" || return 1
}

# Seconds after which an orphaned break-mutex file is considered stale.
LOCK_STALE_AGE="${LOCK_STALE_AGE:-30}"

_drop_stale_break() {
	local file="$1"
	local mtime now
	[[ -e "$file" ]] || return 0
	mtime=$(stat -c %Y "$file" 2>/dev/null \
		|| stat -f %m "$file" 2>/dev/null) || return 0
	[[ "$mtime" =~ ^[0-9]+$ ]] || return 0
	printf -v now '%(%s)T' -1
	if (( now - mtime > LOCK_STALE_AGE )); then
		rm -f "$file" 2>/dev/null || true
	fi
}

_mkdir_locked_append() {
	local file="$1"
	local data="$2"
	local lockdir="${file}.lock"
	local pidfile="${lockdir}/pid"
	local break_mutex="${lockdir}.break"
	local attempts=0

	# The mutex is the O_EXCL (noclobber) create of the pidfile, NOT
	# mkdir: uutils coreutils' mkdir is not exclusive, so several racing
	# callers could all "win" it (issue #1151).  The subshell keeps
	# noclobber from leaking into the caller.
	while ! { mkdir -p "$lockdir" 2>/dev/null \
		&& (set -o noclobber; printf '%d\n' "$$" > "$pidfile") \
			2>/dev/null; }; do
		local lock_pid=""
		if [[ -f "$pidfile" ]]; then
			lock_pid=$(cat "$pidfile" 2>/dev/null) || true
		fi
		if [[ -n "$lock_pid" ]] \
			&& ! kill -0 "$lock_pid" 2>/dev/null; then
			# Only one waiter may break a stale lock, and it must
			# re-read the pid under the break mutex so it never
			# removes a lock re-acquired since it was sampled.
			if (set -o noclobber; : > "$break_mutex") 2>/dev/null; then
				local recheck_pid=""
				recheck_pid=$(cat "$pidfile" 2>/dev/null) || true
				if [[ "$recheck_pid" == "$lock_pid" ]] \
					&& ! kill -0 "$lock_pid" 2>/dev/null; then
					rm -f "$pidfile" 2>/dev/null || true
				fi
				rm -f "$break_mutex" 2>/dev/null || true
				continue
			fi
			# Another waiter holds the break mutex.  Drop it if its
			# holder died and left it behind, then fall through to back
			# off and count the attempt so a stuck mutex cannot spin.
			_drop_stale_break "$break_mutex"
		fi

		if (( attempts >= 10 )); then
			_err "timed out waiting for lock on $file"
			return 1
		fi
		sleep "0.$(( (RANDOM % 4) + 1 ))"
		(( attempts++ )) || true
	done

	printf '%s\n' "$data" >> "$file"
	local rc=$?
	rm -f "$pidfile" 2>/dev/null || true
	rmdir "$lockdir" 2>/dev/null || true
	return $rc
}

append_event() {
	local event="$1"
	local events_file="${LOG_DIR}/events.jsonl"

	if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
		_err "cannot create directory: $LOG_DIR"
		return 3
	fi

	if [[ "${EVENT_EMIT_LOCK_IMPL:-}" != "mkdir" ]] \
		&& command -v flock > /dev/null 2>&1; then
		(
			flock -x -w 10 9 || {
				_err "timed out waiting for lock on $events_file"
				exit 1
			}
			printf '%s\n' "$event" >&9
		) 9>> "$events_file"
	else
		# flock unavailable (e.g. macOS without util-linux)
		_mkdir_locked_append "$events_file" "$event"
	fi
}

main() {
	if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
		cat <<EOF
Usage: $SCRIPT_NAME '<json-event>'

Validate a JSON event against the pipeline-event schema and append it as
one JSONL line to \${LOG_DIR}/events.jsonl under flock.

Environment:
  LOG_DIR   Directory where events.jsonl lives (required)

Exit codes:
  0   Event appended successfully
  1   Schema validation failed
  2   Usage / argument error
  3   Environment / system error
EOF
		return 0
	fi

	if [[ $# -ne 1 ]]; then
		_err "expected 1 argument, got $#"
		_err "Usage: $SCRIPT_NAME '<json-event>'"
		return 2
	fi

	local event="$1"

	if [[ -z "${LOG_DIR:-}" ]]; then
		_err "LOG_DIR is not set"
		return 3
	fi

	validate_event "$event" || return 1
	append_event "$event" || return 3
}

main "$@"
