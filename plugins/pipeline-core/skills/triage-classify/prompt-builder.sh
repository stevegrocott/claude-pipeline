#!/usr/bin/env bash
#
# prompt-builder.sh — triage-classify golden test prompt builder
#
# Sourced by skill-golden.sh (and triage-validate.sh) to provide the
# build_prompt() function.  Must define exactly one function: build_prompt().
#
# build_prompt FIXTURE_BODY
#   Prints the full prompt that the triage classifier receives on stdout.
#   Kept verbatim with build_triage_prompt() in
#   implement-issue-orchestrator.sh — if you edit one, edit the other and
#   re-run the golden suite.
#

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
