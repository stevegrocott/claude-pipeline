#!/usr/bin/env bash
#
# decide-action.sh — glue between orchestrator and escalation-policy skill
#
# Usage: decide-action.sh <stage_result_json> <history_json>
#
# Invokes the escalation-policy skill via claude -p, validates output
# against the {action, model?, reason} schema, and echoes the chosen
# action JSON to stdout.  Falls back to an inline bash decision tree on
# schema failure or when ESCALATION_POLICY_BACKEND=bash.
#
# Environment:
#   ESCALATION_POLICY_BACKEND — set to "bash" to bypass skill invocation
#   DECIDE_TIMEOUT            — seconds for claude invocation (default: 120)
#
# Output (stdout):
#   {"action":"<accept|escalate|bail|retry_same>",
#    "model":"<tier>",    # present only when action == "escalate"
#    "reason":"<string>"}
#
# Exit codes:
#   0 — action decided (skill or bash fallback)
#   1 — bad arguments
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly DECIDE_TIMEOUT="${DECIDE_TIMEOUT:-120}"

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# _run_timed <seconds> <cmd> [args...]
# Run cmd with a timeout when the `timeout` utility is available; fall
# back to running cmd directly on systems (e.g. stock macOS) that lack it.
# ---------------------------------------------------------------------------
_run_timed() {
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
		haiku)  printf 'sonnet' ;;
		sonnet) printf 'opus'   ;;
		*)      printf 'opus'   ;;
	esac
}

# ---------------------------------------------------------------------------
# _bash_decide <stage_result_json> <history_json>
# Inline decision tree matching escalation-policy SKILL.md.
# Prints action JSON to stdout; never calls claude.
# ---------------------------------------------------------------------------
_bash_decide() {
	local stage_result="$1"
	local history="$2"

	local status output_status error_kind model
	status=$(printf '%s' "$stage_result" | jq -r '.status')
	output_status=$(printf '%s' "$stage_result" \
		| jq -r '.output.status // "null"')
	error_kind=$(printf '%s' "$stage_result" | jq -r '.error_kind')
	model=$(printf '%s' "$stage_result" | jq -r '.model // "haiku"')

	# success + valid output + no error_kind → accept
	if [[ "$status" == "success" ]] && \
	   [[ "$output_status" != "null" ]] && \
	   [[ "$output_status" != "error" ]] && \
	   [[ "$error_kind" == "null" ]]; then
		printf '%s\n' \
			'{"action":"accept","reason":"stage completed successfully with valid output"}'
		return 0
	fi

	# unrecoverable configuration or permission error → bail
	if [[ "$error_kind" == "permission_denied" || \
	      "$error_kind" == "schema_not_found" ]]; then
		printf \
			'{"action":"bail","reason":"%s: unrecoverable error"}\n' \
			"$error_kind"
		return 0
	fi

	# explicitly flagged as ceiling-exhausted → bail
	if [[ "$error_kind" == "max_turns_exhausted_at_ceiling" ]]; then
		printf '%s\n' \
			'{"action":"bail","reason":"max_turns_exhausted_at_ceiling: already at opus ceiling"}'
		return 0
	fi

	# already at opus → bail (cannot escalate further)
	if [[ "$model" == "opus" ]]; then
		printf '%s\n' \
			'{"action":"bail","reason":"at opus ceiling: cannot escalate further"}'
		return 0
	fi

	# rate_limit + no prior attempt at same model → retry_same
	if [[ "$error_kind" == "rate_limit" ]]; then
		local prior_count
		prior_count=$(printf '%s' "$history" | \
			jq --arg m "$model" \
			   '[.[] | select(.from_model == $m)] | length')
		if (( prior_count == 0 )); then
			printf '%s\n' \
				'{"action":"retry_same","reason":"rate_limit: transient throttle, retrying with same model"}'
			return 0
		fi
	fi

	# default: escalate to next tier
	local next_model reason
	next_model=$(_next_model "$model")
	reason="${error_kind:-unknown}: escalating from $model to $next_model"
	printf '{"action":"escalate","model":"%s","reason":"%s"}\n' \
		"$next_model" "$reason"
}

# ---------------------------------------------------------------------------
# _valid_schema <json>
# Return 0 if json has a valid action and non-empty reason.
# ---------------------------------------------------------------------------
_valid_schema() {
	local json="$1"
	local action reason
	action=$(printf '%s' "$json" | jq -r '.action // empty' 2>/dev/null)
	reason=$(printf '%s' "$json" | jq -r '.reason // empty' 2>/dev/null)

	case "$action" in
		accept|escalate|bail|retry_same) ;;
		*) return 1 ;;
	esac
	[[ -n "$reason" ]]
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	[[ $# -ge 2 ]] \
		|| die "usage: $SCRIPT_NAME <stage_result_json> <history_json>"

	local stage_result="$1"
	local history="$2"

	# Kill-switch: bypass skill and use inline bash directly
	if [[ "${ESCALATION_POLICY_BACKEND:-}" == "bash" ]]; then
		_bash_decide "$stage_result" "$history"
		return 0
	fi

	# Build prompt for the escalation-policy skill
	local prompt
	prompt="/escalation-policy"
	prompt+=$'\n'"stage_result: $stage_result"
	prompt+=$'\n'"escalation_history: $history"

	# Invoke the skill; a timeout or crash yields empty output which
	# fails validation and routes to the bash fallback.
	local skill_output
	skill_output=$(_run_timed "$DECIDE_TIMEOUT" \
		claude -p "$prompt" \
		2>/dev/null) || true

	# Validate schema; fall back to inline bash on failure
	if _valid_schema "$skill_output"; then
		printf '%s\n' "$skill_output"
	else
		printf '%s: warning: skill output failed schema validation; using bash fallback\n' \
			"$SCRIPT_NAME" >&2
		_bash_decide "$stage_result" "$history"
	fi
}

main "$@"
