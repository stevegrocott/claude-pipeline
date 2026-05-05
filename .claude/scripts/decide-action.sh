#!/usr/bin/env bash
#
# decide-action.sh — glue between orchestrator and escalation-policy skill
#
# Usage: decide-action.sh <stage_result_json> <history_json>
#
# Routes stage completion by composing two specialist decisions:
#   - decide-retry.sh         (retry-policy skill)    — retry vs escalate vs bail
#   - decide-model-fallback.sh (model-fallback skill) — next model on escalate
#
# Falls back to an inline bash decision tree on composition failure or when
# ESCALATION_POLICY_BACKEND=bash.
#
# Environment:
#   ESCALATION_POLICY_BACKEND — set to "bash" to bypass composition and use
#                               the inline decision tree directly
#   RETRY_POLICY_BACKEND      — forwarded to decide-retry.sh (default: bash)
#   MODEL_FALLBACK_BACKEND    — forwarded to decide-model-fallback.sh
#                               (default: bash)
#
# Output (stdout):
#   {"action":"<accept|escalate|bail|retry_same>",
#    "model":"<tier>",    # present only when action == "escalate"
#    "reason":"<string>"}
#
# Exit codes:
#   0 — action decided (composition or bash fallback)
#   1 — bad arguments
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# _next_model <model>
# Print the next escalation tier.  haiku→sonnet, sonnet/other→opus.
# Used by _bash_decide; model selection for the composition path is
# delegated to decide-model-fallback.sh.
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
# Prints action JSON to stdout; never calls external scripts.
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
# _valid_retry_schema <json>
# Return 0 if json has a valid retry-policy output schema.
# ---------------------------------------------------------------------------
_valid_retry_schema() {
	local json="$1"
	local action reason
	action=$(printf '%s' "$json" | jq -r '.action // empty' 2>/dev/null)
	reason=$(printf '%s' "$json" | jq -r '.reason // empty' 2>/dev/null)
	case "$action" in
		retry|escalate|bail) ;;
		*) return 1 ;;
	esac
	[[ -n "$reason" ]]
}

# ---------------------------------------------------------------------------
# _valid_fallback_schema <json>
# Return 0 if json has a valid model-fallback output schema.
# Uses != null rather than // empty to handle at_ceiling=false correctly:
# jq's // operator triggers on false as well as null.
# ---------------------------------------------------------------------------
_valid_fallback_schema() {
	local json="$1"
	printf '%s' "$json" | \
		jq -e '.at_ceiling != null' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _compose_decide <stage_result_json> <history_json>
# Delegate retry decisions to decide-retry.sh (retry-policy skill) and
# model upgrade decisions to decide-model-fallback.sh (model-fallback skill).
# Falls back to _bash_decide on composition failure.
# ---------------------------------------------------------------------------
_compose_decide() {
	local stage_result="$1"
	local history="$2"

	local status output_status error_kind model
	status=$(printf '%s' "$stage_result" | jq -r '.status')
	output_status=$(printf '%s' "$stage_result" \
		| jq -r '.output.status // "null"')
	error_kind=$(printf '%s' "$stage_result" | jq -r '.error_kind')
	model=$(printf '%s' "$stage_result" | jq -r '.model // "haiku"')

	# success + valid output + no error_kind → accept (no retry needed)
	if [[ "$status" == "success" ]] && \
	   [[ "$output_status" != "null" ]] && \
	   [[ "$output_status" != "error" ]] && \
	   [[ "$error_kind" == "null" ]]; then
		printf '%s\n' \
			'{"action":"accept","reason":"stage completed successfully with valid output"}'
		return 0
	fi

	# Derive retry_count from escalation history — count prior same-model
	# attempts recorded as from_model entries.
	local retry_count
	retry_count=$(printf '%s' "$history" | \
		jq --arg m "$model" \
		   '[.[] | select(.from_model == $m)] | length')

	# Delegate retry decision to decide-retry.sh (retry-policy skill).
	# Escalation history lacks per-error-kind records; pass an empty
	# error_history array so retry-policy uses retry_count for threshold
	# checks.  Defaults to bash backend unless RETRY_POLICY_BACKEND is set.
	local retry_out
	retry_out=$(
		RETRY_POLICY_BACKEND="${RETRY_POLICY_BACKEND:-bash}" \
		"$SCRIPT_DIR/decide-retry.sh" \
		"$stage_result" "$retry_count" '[]' \
		2>/dev/null
	) || true

	if ! _valid_retry_schema "$retry_out"; then
		printf \
			'%s: warning: retry-policy output invalid; using bash fallback\n' \
			"$SCRIPT_NAME" >&2
		_bash_decide "$stage_result" "$history"
		return 0
	fi

	local retry_action
	retry_action=$(printf '%s' "$retry_out" | jq -r '.action')

	case "$retry_action" in
		retry)
			# retry-policy wants same-tier retry; map to retry_same
			printf '%s' "$retry_out" | \
				jq -c '{action:"retry_same",reason:.reason}'
			return 0
			;;
		bail)
			printf '%s' "$retry_out" | \
				jq -c '{action:"bail",reason:.reason}'
			return 0
			;;
		escalate)
			# Delegate model selection to decide-model-fallback.sh.
			# Defaults to bash backend unless MODEL_FALLBACK_BACKEND is set.
			local retry_reason fallback_out
			retry_reason=$(printf '%s' "$retry_out" | jq -r '.reason')
			fallback_out=$(
				MODEL_FALLBACK_BACKEND="${MODEL_FALLBACK_BACKEND:-bash}" \
				"$SCRIPT_DIR/decide-model-fallback.sh" \
				"$stage_result" \
				2>/dev/null
			) || true

			if ! _valid_fallback_schema "$fallback_out"; then
				printf \
					'%s: warning: model-fallback output invalid; using bash fallback\n' \
					"$SCRIPT_NAME" >&2
				_bash_decide "$stage_result" "$history"
				return 0
			fi

			local at_ceiling next_model fallback_reason
			at_ceiling=$(printf '%s' "$fallback_out" \
				| jq -r '.at_ceiling')
			next_model=$(printf '%s' "$fallback_out" \
				| jq -r '.next_model')
			fallback_reason=$(printf '%s' "$fallback_out" \
				| jq -r '.reason')

			if [[ "$at_ceiling" == "true" || \
			      "$next_model" == "null" ]]; then
				printf '%s' "$fallback_out" | \
					jq -c '{action:"bail",reason:.reason}'
			else
				jq -cn \
					--arg model "$next_model" \
					--arg reason "$retry_reason; $fallback_reason" \
					'{action:"escalate",model:$model,reason:$reason}'
			fi
			return 0
			;;
	esac
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	[[ $# -ge 2 ]] \
		|| die "usage: $SCRIPT_NAME <stage_result_json> <history_json>"

	local stage_result="$1"
	local history="$2"

	# Kill-switch: bypass composition and use inline bash directly
	if [[ "${ESCALATION_POLICY_BACKEND:-}" == "bash" ]]; then
		_bash_decide "$stage_result" "$history"
		return 0
	fi

	# Delegate to retry-policy and model-fallback skills via composition
	_compose_decide "$stage_result" "$history"
}

main "$@"
