#!/usr/bin/env bash
#
# decide-model-fallback.sh — glue between orchestrator and model-fallback
#
# Usage: decide-model-fallback.sh <stage_result_json>
#
# Given a failed stage_result, decides whether the next attempt should run
# at a higher model tier.  Inputs are read from .model and .error_kind on
# the stage_result; output is a JSON object describing the next-model
# decision and whether the model ceiling has been reached.
#
# Environment:
#   MODEL_FALLBACK_BACKEND — controls backend selection.
#     "bash"   — bypass skill invocation; use inline decision tree (testing).
#     "claude" — invoke model-fallback skill via Claude (default when unset).
#
# Output (stdout):
#   {"next_model": "<tier>"|null,
#    "at_ceiling": <bool>,
#    "reason": "<string>"}
#
# Exit codes:
#   0 — decision produced
#   1 — bad arguments
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

# Source model-config.sh for _next_model_up().  The file uses readonly
# arrays guarded by [[ -z "${_STAGE_PREFIXES+set}" ]], so re-sourcing in
# the same shell is idempotent.
# shellcheck source=./model-config.sh
. "$SCRIPT_DIR/model-config.sh"

# ---------------------------------------------------------------------------
# _is_upgrade_trigger <error_kind>
# Return 0 when error_kind is one of the recognised upgrade triggers, 1
# otherwise.  Conservative by design: unknown classes do not upgrade.
# ---------------------------------------------------------------------------
_is_upgrade_trigger() {
	# rate_limit is an upgrade trigger only after same-tier retry limits
	# are met — see retry-policy.  The orchestrator is responsible for
	# exhausting per-tier retries before calling this script.
	case "$1" in
		timeout|double_timeout|max_turns_exhausted|no_structured_output|\
		structured_error|rate_limit)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

# ---------------------------------------------------------------------------
# _bash_model_fallback <stage_result_json>
# Inline decision tree for the model-fallback skill.  Prints decision
# JSON to stdout; never calls claude.
# ---------------------------------------------------------------------------
_bash_model_fallback() {
	local stage_result="$1"

	local model error_kind
	model=$(printf '%s' "$stage_result" | jq -r '.model // "haiku"')
	error_kind=$(printf '%s' "$stage_result" \
		| jq -r '.error_kind // "null"')

	# Non-escalatable errors: a higher model cannot fix these regardless of
	# the current tier.  Must be checked before the opus ceiling test so
	# haiku/sonnet also return at_ceiling=true for these error kinds.
	case "$error_kind" in
		permission_denied|schema_not_found|\
		max_turns_exhausted_at_ceiling)
			local reason
			reason="${error_kind}: non-escalatable, no model can fix this"
			jq -nc --argjson next_model null \
				--arg reason "$reason" \
				--argjson at_ceiling true \
				'{next_model: $next_model, at_ceiling: $at_ceiling, reason: $reason}'
			return 0
			;;
	esac

	# At ceiling: opus has no higher tier to upgrade to.
	if [[ "$model" == "opus" ]]; then
		local reason
		reason="at opus ceiling: no higher tier available"
		jq -nc --argjson next_model null \
			--arg reason "$reason" \
			--argjson at_ceiling true \
			'{next_model: $next_model, at_ceiling: $at_ceiling, reason: $reason}'
		return 0
	fi

	# Recognised upgrade trigger: bump to the next tier up.
	if _is_upgrade_trigger "$error_kind"; then
		local next reason
		next=$(_next_model_up "$model")
		reason="${error_kind}: upgrading ${model} → ${next}"
		jq -nc --arg next_model "$next" \
			--arg reason "$reason" \
			--argjson at_ceiling false \
			'{next_model: $next_model, at_ceiling: $at_ceiling, reason: $reason}'
		return 0
	fi

	# Unrecognised error_kind: conservative no-upgrade.
	local reason
	reason="${error_kind}: not a recognised upgrade trigger, no-upgrade"
	jq -nc --argjson next_model null \
		--arg reason "$reason" \
		--argjson at_ceiling false \
		'{next_model: $next_model, at_ceiling: $at_ceiling, reason: $reason}'
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
# _claude_model_fallback <stage_result_json>
# Live Claude skill invocation via /model-fallback.
# Prints decision JSON to stdout; exits non-zero on invocation failure.
# ---------------------------------------------------------------------------
_claude_model_fallback() {
	local stage_result="$1"

	local schema_file="$SCRIPT_DIR/schemas/model-fallback-output.json"
	local skill_file="$SCRIPT_DIR/../skills/model-fallback/SKILL.md"

	if [[ ! -f "$skill_file" ]]; then
		printf '%s: model-fallback SKILL.md not found: %s\n' \
			"$SCRIPT_NAME" "$skill_file" >&2
		return 1
	fi
	if [[ ! -f "$schema_file" ]]; then
		printf '%s: model-fallback schema not found: %s\n' \
			"$SCRIPT_NAME" "$schema_file" >&2
		return 1
	fi

	local schema_compact
	schema_compact=$(jq -c . "$schema_file" 2>&1) || {
		printf '%s: failed to compact schema: %s\n' \
			"$SCRIPT_NAME" "$schema_compact" >&2
		return 1
	}

	local current_model error_kind
	current_model=$(printf '%s' "$stage_result" | jq -r '.model // "haiku"')
	error_kind=$(printf '%s' "$stage_result" | jq -r '.error_kind // "null"')

	local prompt
	prompt=$(printf '/model-fallback\n\nINPUTS:\ncurrent_model: %s\nerror_kind: %s\n' \
		"$current_model" "$error_kind")

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
		| jq -e 'has("next_model")' >/dev/null 2>&1; then
		printf '%s: no valid next_model in claude output\n' \
			"$SCRIPT_NAME" >&2
		return 1
	fi

	printf '%s\n' "$payload"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	[[ $# -ge 1 ]] \
		|| die "usage: $SCRIPT_NAME <stage_result_json>"

	local stage_result="$1"

	case "${MODEL_FALLBACK_BACKEND:-claude}" in
		bash)
			_bash_model_fallback "$stage_result"
			;;
		claude)
			_claude_model_fallback "$stage_result" \
				|| _bash_model_fallback "$stage_result"
			;;
		*)
			die "unknown MODEL_FALLBACK_BACKEND" \
				"'${MODEL_FALLBACK_BACKEND}'; valid values: bash, claude"
			;;
	esac
}

main "$@"
