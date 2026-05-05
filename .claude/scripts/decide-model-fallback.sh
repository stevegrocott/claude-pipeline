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
#   MODEL_FALLBACK_BACKEND — set to "bash" to bypass skill invocation and
#                            use the inline decision tree directly (for
#                            testing).  No live skill exists yet, so this
#                            is currently the only supported backend.
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
	case "$1" in
		timeout|max_turns_exceeded|max_turns|context_length_exceeded)
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

	# At ceiling: opus has no higher tier to upgrade to.
	if [[ "$model" == "opus" ]]; then
		local reason
		reason="at opus ceiling: no higher tier available"
		printf '{"next_model":null,"at_ceiling":true,"reason":"%s"}\n' \
			"$reason"
		return 0
	fi

	# Recognised upgrade trigger: bump to the next tier up.
	if _is_upgrade_trigger "$error_kind"; then
		local next reason
		next=$(_next_model_up "$model")
		reason="${error_kind}: upgrading ${model} → ${next}"
		printf \
			'{"next_model":"%s","at_ceiling":false,"reason":"%s"}\n' \
			"$next" "$reason"
		return 0
	fi

	# Unrecognised error_kind: conservative no-upgrade.
	local reason
	reason="${error_kind}: not a recognised upgrade trigger, no-upgrade"
	printf '{"next_model":null,"at_ceiling":false,"reason":"%s"}\n' \
		"$reason"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	[[ $# -ge 1 ]] \
		|| die "usage: $SCRIPT_NAME <stage_result_json>"

	local stage_result="$1"

	# Kill-switch: bypass skill and use inline bash directly.  The live
	# skill invocation path is not yet implemented; the bash backend is
	# the only supported route until the model-fallback SKILL.md lands.
	if [[ "${MODEL_FALLBACK_BACKEND:-bash}" == "bash" ]]; then
		_bash_model_fallback "$stage_result"
		return 0
	fi

	# TODO: implement live Claude skill invocation once the model-fallback
	# skill exists.  Until then, fall through to the bash backend so the
	# orchestrator can rely on a deterministic decision.
	_bash_model_fallback "$stage_result"
}

main "$@"
