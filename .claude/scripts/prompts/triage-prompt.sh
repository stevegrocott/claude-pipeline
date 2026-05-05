#!/usr/bin/env bash
#
# triage-prompt.sh — build_prompt() for the triage classifier
#
# Defines a single function with no external dependencies. Source this file
# wherever a triage prompt is needed.
#
# ─── Prompt File Convention ───────────────────────────────────────────────────
# Each file in this directory follows the pattern:
#
#   prompts/<stage>-prompt.sh
#
# Rules for skill/pipeline authors adding a new stage prompt:
#   1. Name the file  prompts/<stage>-prompt.sh  (e.g. implement-prompt.sh)
#   2. Define exactly one function — build_prompt() — with no global side-effects
#   3. Accept stage-specific arguments as positional parameters ($1, $2, …)
#   4. Declare no globals; output the prompt text to stdout via cat <<HEREDOC
#   5. Source the file once from the orchestrator, before first use:
#        # shellcheck source=prompts/<stage>-prompt.sh
#        source "$SCRIPT_DIR/prompts/<stage>-prompt.sh"
#
# This keeps all stage prompt logic isolated from the orchestrator and easy to
# unit-test independently.
# ──────────────────────────────────────────────────────────────────────────────

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
