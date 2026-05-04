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
# Prompt builder — kept verbatim with build_triage_prompt() in
# implement-issue-orchestrator.sh; edit both together and re-run.
# =============================================================================

# shellcheck disable=SC2329  # called indirectly as a string arg to sg_run_manifest
build_prompt() {
	local issue_body="$1"
	cat <<TRIAGE_PROMPT
You are the triage classifier for an issue-implementation pipeline. Classify
the GitHub issue below into one of two routes:

  "fast-path" — surgical, test-only, well-specified change. Pipeline runs:
                branch -> implement -> commit -> PR -> squash-merge. Skips
                test loop, code review, deploy verify, docs.
  "full"      — default. Runs the full verification pipeline.

Be CONSERVATIVE. False negatives (missing a fast-path opportunity) cost time.
False positives (skipping verification when it was needed) cost quality. Bias
hard toward "full" whenever uncertain.

Check ALL SIX criteria. Every criterion must be true for "fast-path". If ANY
criterion is false, route is "full".

CRITERIA:

1. test_only_scope — All file paths in the issue's Implementation Tasks
   section match: tests/**, playwright/**, **/*.spec.ts, **/*.test.ts,
   **/*.e2e.ts. Any reference to apps/, packages/, src/, or migration files
   disqualifies.

2. surgical_size — Estimated diff under 30 lines net, across no more than
   3 files.

3. established_pattern — The change applies a pattern that already exists in
   the codebase. Identify the pattern as a grep-able regex and place it in
   "established_pattern_grep". The shell wrapper will run \`git grep -lE\` and
   verify >= 3 matching files. Set to null if you cannot identify one
   specific regex (this criterion then fails).

4. precise_specification — Issue body has an "## Implementation Tasks"
   section AND each task names specific file paths AND (line numbers OR
   exact code snippets).

5. benign_failure_mode — Worst outcome of a wrong change is "a test still
   fails" or "a test skips" — NOT "production breaks", "data corrupts", or
   "users see incorrect behavior". Test files always pass; production code
   never passes.

6. no_security_concerns — Skip fast-path for: auth flows, RBAC, encryption,
   secret handling, input validation, CORS, CSP, session management, token
   handling. Auth tests deserve review even if test-only.

CONFIDENCE: high (all criteria clearly evaluated) | medium (some criteria
required inference) | low (vague issue). If confidence is medium or low,
route MUST be "full".

OUTPUT: schema-enforced JSON with route, criteria.{test_only_scope,
surgical_size, established_pattern, precise_specification,
benign_failure_mode, no_security_concerns}.{passed, reason},
established_pattern_grep, confidence, disqualifying_criterion, summary,
status.

ISSUE BODY:
<<<
${issue_body}
>>>
TRIAGE_PROMPT
}

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
