#!/usr/bin/env bash
#
# decide-retry.sh — glue between orchestrator and retry-policy skill
#
# Usage: decide-retry.sh <stage_result_json> <retry_count> <error_history_json>
#
# Applies the retry-policy skill decision tree: given a failed stage_result,
# the number of retries already attempted at the current model tier, and the
# per-tier error history, decides whether to retry the stage, escalate to a
# higher tier, or bail permanently.
#
# Environment:
#   RETRY_POLICY_BACKEND — unset or "claude": invoke retry-policy skill via Claude (default)
#                          "bash": bypass Claude and use the inline decision tree (for testing)
#
# Output (stdout):
#   {"action":"<retry|escalate|bail>",
#    "reason":"<string>",
#    "backoff_ms": N}   # present only when action==retry and error_kind==rate_limit
#
# Exit codes:
#   0 — action decided (skill or bash fallback)
#   1 — bad arguments or Claude invocation failure
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# _run_with_timeout <seconds> <command> [args...]
# Run a command with a wall-clock timeout.  Uses GNU timeout when available;
# falls back to direct execution on systems where timeout is not installed
# (e.g. macOS without coreutils).
# ---------------------------------------------------------------------------
_run_with_timeout() {
	local secs="$1"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@"
	else
		"$@"
	fi
}

# ---------------------------------------------------------------------------
# _next_model <model>
# Print the next escalation tier.  haiku→sonnet, sonnet/other→opus.
# ---------------------------------------------------------------------------
_next_model() {
	local model="$1"
	case "$model" in
		haiku) printf 'sonnet' ;;
		*)     printf 'opus'   ;;
	esac
}

# ---------------------------------------------------------------------------
# _max_retries <error_kind>
# Print the maximum same-tier retry count for the given error class.
# ---------------------------------------------------------------------------
_max_retries() {
	local error_kind="$1"
	case "$error_kind" in
		rate_limit)           printf '3' ;;
		no_structured_output) printf '1' ;;
		timeout)              printf '1' ;;
		structured_error)     printf '1' ;;
		# Known non-retriable errors: escalate or bail immediately.
		# Listed explicitly so new error_kinds don't silently inherit 0-retry
		# behaviour — add an entry here when extending the error_kind enum.
		max_turns_exhausted|quality_stall|double_timeout) printf '0' ;;
		# Unknown error_kind: fail closed — 0 retries causes immediate bail.
		# This prevents silent retries when the policy table has no entry for
		# an unrecognised class.
		*)                    printf '0' ;;
	esac
}

# ---------------------------------------------------------------------------
# _bash_retry_decide <stage_result_json> <retry_count> <error_history_json>
# Inline decision tree matching retry-policy SKILL.md.
# Prints action JSON to stdout; never calls claude.
# ---------------------------------------------------------------------------
_bash_retry_decide() {
	local stage_result="$1"
	local retry_count="$2"
	local error_history="$3"

	local error_kind model
	error_kind=$(printf '%s' "$stage_result" | jq -r '.error_kind // "null"')
	model=$(printf '%s' "$stage_result" | jq -r '.model // "haiku"')

	# Unretryable configuration/permission errors → bail immediately
	case "$error_kind" in
		permission_denied|schema_not_found|max_turns_exhausted_at_ceiling)
			local reason
			reason="${error_kind}: configuration error, retrying cannot fix this"
			printf '{"action":"bail","reason":"%s"}\n' "$reason"
			return 0
			;;
	esac

	# max_turns_exhausted at non-ceiling model → escalate immediately
	if [[ "$error_kind" == "max_turns_exhausted" ]]; then
		if [[ "$model" == "opus" ]]; then
			printf '%s\n' \
				'{"action":"bail","reason":"max_turns_exhausted: at opus ceiling, cannot escalate"}'
		else
			local next_model
			next_model=$(_next_model "$model")
			printf \
				'{"action":"escalate","reason":"max_turns_exhausted: escalating %s → %s"}\n' \
				"$model" "$next_model"
		fi
		return 0
	fi

	# quality_stall at non-ceiling model → escalate immediately
	if [[ "$error_kind" == "quality_stall" ]]; then
		if [[ "$model" == "opus" ]]; then
			printf '%s\n' \
				'{"action":"bail","reason":"quality_stall: at opus ceiling, cannot escalate"}'
		else
			printf '%s\n' \
				'{"action":"escalate","reason":"quality_stall: fix made no commits"}'
		fi
		return 0
	fi

	local max
	max=$(_max_retries "$error_kind")

	# Count prior failures of same error_kind at same model in error_history
	local history_count
	history_count=$(printf '%s' "$error_history" | \
		jq --arg m "$model" --arg ek "$error_kind" \
		   '[.[] | select(.model == $m and .error_kind == $ek)] | length')

	# Threshold exceeded or history shows same error at same model
	if (( retry_count >= max )) || (( history_count > 0 )); then
		if [[ "$model" == "opus" ]]; then
			local reason
			reason="${error_kind}: retry_count=${retry_count} meets threshold"
			reason+=" and at opus ceiling"
			printf '{"action":"bail","reason":"%s"}\n' "$reason"
		else
			local next_model reason
			next_model=$(_next_model "$model")
			reason="${error_kind}: retry_count=${retry_count} meets threshold"
			reason+="; escalating ${model} → ${next_model}"
			printf '{"action":"escalate","reason":"%s"}\n' "$reason"
		fi
		return 0
	fi

	# Retry — include backoff_ms for rate_limit errors
	if [[ "$error_kind" == "rate_limit" ]]; then
		local backoff_ms
		backoff_ms=$(( 30000 * (1 << retry_count) ))
		if (( backoff_ms > 120000 )); then
			backoff_ms=120000
		fi
		local reason
		reason="rate_limit: transient throttle, retry_count=${retry_count}"
		reason+=", waiting ${backoff_ms}ms"
		printf '{"action":"retry","reason":"%s","backoff_ms":%d}\n' \
			"$reason" "$backoff_ms"
	else
		local reason
		reason="${error_kind}: first retry at ${model}, retry_count=${retry_count}"
		printf '{"action":"retry","reason":"%s"}\n' "$reason"
	fi
}

# ---------------------------------------------------------------------------
# _claude_retry_decide <stage_result_json> <retry_count> <error_history_json>
# Live Claude skill invocation via /retry-policy.
# Prints action JSON to stdout; exits non-zero on invocation failure.
# ---------------------------------------------------------------------------
_claude_retry_decide() {
	local stage_result="$1"
	local retry_count="$2"
	local error_history="$3"

	local schema_file="$SCRIPT_DIR/schemas/retry-policy.json"
	local skill_file="$SCRIPT_DIR/../skills/retry-policy/SKILL.md"

	if [[ ! -f "$skill_file" ]]; then
		printf '%s: retry-policy SKILL.md not found: %s\n' \
			"$SCRIPT_NAME" "$skill_file" >&2
		return 1
	fi
	if [[ ! -f "$schema_file" ]]; then
		printf '%s: retry-policy schema not found: %s\n' \
			"$SCRIPT_NAME" "$schema_file" >&2
		return 1
	fi

	local schema_compact
	schema_compact=$(jq -c . "$schema_file" 2>&1) || {
		printf '%s: failed to compact schema: %s\n' "$SCRIPT_NAME" "$schema_compact" >&2
		return 1
	}

	local prompt
	prompt=$(printf '/retry-policy\n\nINPUTS:\nstage_result: %s\nretry_count: %s\nerror_history: %s\n' \
		"$stage_result" "$retry_count" "$error_history")

	local output rc
	output=$(_run_with_timeout "${CLAUDE_SKILL_TIMEOUT:-120}" \
		env -u CLAUDECODE claude -p "$prompt" \
		--dangerously-skip-permissions \
		--output-format json \
		--json-schema "$schema_compact" 2>&1)
	rc=$?

	if (( rc != 0 )); then
		printf '%s: claude invocation failed (exit %d): %s\n' \
			"$SCRIPT_NAME" "$rc" "$output" >&2
		return 1
	fi

	# Extract the structured payload from the claude output envelope.
	# Mirrors sg_extract_payload() in skill-golden-lib.sh and run_stage() in
	# implement-issue-orchestrator.sh — keep these in sync.
	local payload
	payload=$(printf '%s' "$output" | jq -c '
		.structured_output
		// (.result | if type == "string" then fromjson? else . end)
		// .
	' 2>/dev/null)

	if [[ -z "$payload" ]] || ! printf '%s' "$payload" \
		| jq -e '.action' >/dev/null 2>&1; then
		printf '%s: no valid action in claude output\n' "$SCRIPT_NAME" >&2
		return 1
	fi

	printf '%s\n' "$payload"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	[[ $# -ge 3 ]] || die \
		"usage: $SCRIPT_NAME <stage_result_json> <retry_count> <error_history_json>"

	local stage_result="$1"
	local retry_count="$2"
	local error_history="$3"

	if [[ "${RETRY_POLICY_BACKEND:-}" == "bash" ]]; then
		_bash_retry_decide "$stage_result" "$retry_count" "$error_history"
		return 0
	fi

	_claude_retry_decide "$stage_result" "$retry_count" "$error_history"
}

main "$@"
