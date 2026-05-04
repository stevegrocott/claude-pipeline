#!/usr/bin/env bash
#
# triage-validate.sh
#
# Real-Claude golden tests for the triage classifier prompt. Asks the live
# Haiku model to classify each fixture in implement-issue-test/fixtures/triage/
# and compares the returned route against the expected outcome encoded in
# the manifest below.
#
# WHY THIS EXISTS (vs the bats mock tests):
#   - test-surgical-fast-path.bats locks down the *shell logic* around the
#     classifier (kill switch, confidence demotion, grep verification, status
#     bookkeeping). It mocks the model — so it can't catch prompt regressions.
#   - This script locks down the *prompt itself*. If a Haiku update or a
#     prompt edit causes the model to flip a fixture's route, this is how
#     we find out before shipping.
#
# RUN CADENCE (READ BEFORE TOUCHING):
#   - Cost:    ~10 fixtures x 1 Haiku call = ~$0.05–$0.10 per run.
#   - Latency: ~5–15s per fixture, ~60–150s total wall clock.
#   - Run BEFORE merging changes to:
#       * .claude/scripts/implement-issue-orchestrator.sh
#         (build_triage_prompt, run_triage_stage, schema)
#       * .claude/scripts/schemas/implement-issue-triage.json
#       * .claude/scripts/model-config.sh (triage tier)
#   - Run MONTHLY as a regression sweep against model drift.
#   - Run after upgrading the Haiku tier model in model-config.sh.
#
# DO NOT AUTO-UPDATE FIXTURES OR EXPECTATIONS.
#   If a fixture flips, that is signal — investigate before changing the
#   manifest. The manifest is the contract; flips mean the prompt or the
#   model changed behavior, and that needs a human decision.
#
# Usage:
#   .claude/scripts/triage-validate.sh                  # run all fixtures
#   .claude/scripts/triage-validate.sh issue-2836       # run one fixture
#   TRIAGE_MODEL=sonnet .claude/scripts/triage-validate.sh   # override model
#
# Exit codes:
#   0 — all fixtures classified as expected
#   1 — one or more fixtures flipped
#   2 — environment / setup error (claude CLI missing, jq missing, etc.)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/implement-issue-test/fixtures/triage"
SCHEMA_FILE="$SCRIPT_DIR/schemas/implement-issue-triage.json"
TRIAGE_MODEL="${TRIAGE_MODEL:-haiku}"

# Propagate legacy CLAUDE_CLI to the library variable (lib default: "claude").
: "${SG_CLAUDE_CLI:=${CLAUDE_CLI:-claude}}"

# shellcheck source=skill-golden-lib.sh
source "$SCRIPT_DIR/skill-golden-lib.sh"

# =============================================================================
# MANIFEST: fixture -> expected_route[:expected_disqualifying_criterion]
# =============================================================================
#
# Format: "fixture_basename|expected_route|expected_dq_or_*"
#   expected_dq is checked only when route is "full". Use "*" to accept any
#   reason (the route alone is the contract). Use a specific name when the
#   prompt should pinpoint a particular criterion (e.g. auth-test must fail
#   on no_security_concerns specifically — no other reason is acceptable).
#
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

# Build the same prompt the orchestrator uses. Kept verbatim with
# build_triage_prompt() in implement-issue-orchestrator.sh — if you edit one,
# edit the other and re-run this script.
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

sg_check_setup "$FIXTURE_DIR" "$SCHEMA_FILE" || exit 2
sg_run_manifest "$FIXTURE_DIR" "$SCHEMA_FILE" "$TRIAGE_MODEL" \
	build_prompt "${1:-}" "${MANIFEST[@]}"
exit $?
