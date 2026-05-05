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
#   RETRY_POLICY_BACKEND — set to "bash" to bypass skill invocation and use
#                          the inline decision tree directly (for testing)
#
# Output (stdout):
#   {"action":"<retry|escalate|bail>",
#    "reason":"<string>",
#    "backoff_ms": N}   # present only when action==retry and error_kind==rate_limit
#
# Exit codes:
#   0 — action decided (skill or bash fallback)
#   1 — bad arguments
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
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

	# TODO: implement live Claude skill invocation so the retry policy can be
	# driven by the full SKILL.md prompt without requiring RETRY_POLICY_BACKEND=bash.
	# Tracked in the follow-up issue for issue #212 (live skill invocation path).
	die "live retry-policy skill invocation not yet implemented;" \
		"use RETRY_POLICY_BACKEND=bash"
}

main "$@"
