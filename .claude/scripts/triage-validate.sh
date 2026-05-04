#!/usr/bin/env bash
#
# triage-validate.sh — golden tests for the triage classifier prompt
#
# Usage:
#   triage-validate.sh [<fixture-basename>]
#   TRIAGE_MODEL=sonnet triage-validate.sh
#
# Exit codes: 0 all passed, 1 one or more flipped, 2 setup error.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/implement-issue-test/fixtures/triage"
SCHEMA_FILE="$SCRIPT_DIR/schemas/implement-issue-triage.json"
TRIAGE_MODEL="${TRIAGE_MODEL:-haiku}"

# Propagate legacy CLAUDE_CLI to the library variable (lib default: "claude").
: "${SG_CLAUDE_CLI:=${CLAUDE_CLI:-claude}}"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/skill-golden-lib.sh"

# =============================================================================
# Manifest: fixture -> expected_route|expected_disqualifying_criterion
# Use "*" to accept any criterion; name a specific criterion to pin it.
# =============================================================================

MANIFEST=(
	"issue-2836|fast-path|*"
	"issue-2837|fast-path|*"
	"issue-2838|fast-path|*"
	"issue-2839|fast-path|*"
	"issue-2752|full|test_only_scope"
	"issue-2754|full|test_only_scope"
	"issue-2776|full|test_only_scope"
	"issue-auth-test|full|no_security_concerns"
	"issue-vague|full|precise_specification"
	"issue-novel-pattern|full|established_pattern"
)

# =============================================================================
# Prompt builder
# =============================================================================

# shellcheck source=prompts/triage-prompt.sh
source "$SCRIPT_DIR/prompts/triage-prompt.sh"

# =============================================================================
# Argument parsing
# =============================================================================

filter=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--)
			shift
			break
			;;
		-*)
			printf '%s: unknown option: %s\n' "${0##*/}" "$1" >&2
			exit 2
			;;
		*)
			filter="$1"
			shift
			;;
	esac
done

# =============================================================================
# Dispatch
# =============================================================================

sg_check_setup "$FIXTURE_DIR" "$SCHEMA_FILE" || exit 2
sg_run_manifest "$FIXTURE_DIR" "$SCHEMA_FILE" "$TRIAGE_MODEL" \
	build_prompt "$filter" "${MANIFEST[@]}"
exit $?
