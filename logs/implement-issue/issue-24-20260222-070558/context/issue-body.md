## Context

When the PR creation stage returns a `.result` string instead of `.structured_output` JSON, the orchestrator's fallback wraps it as `{status: "success", summary: ...}` — which has no `pr_number` field. The orchestrator then proceeds with `pr_number=null`, causing the entire PR review loop to fail (`gh pr comment null` errors, reviewer gets "PR #null" prompts and returns `changes_requested`, triggering a wasteful fix loop).

This was observed during issue #22 implementation: the PR stage returned `.result` text, the fallback produced a synthetic payload without `pr_number`, and the pipeline entered an infinite fix loop until manually stopped.

## Research Findings

**Files affected:**
- `.claude/scripts/implement-issue-orchestrator.sh` — PR number extraction (line ~2104) and missing validation (line ~2112)
- `.claude/scripts/schemas/implement-issue-pr.json` — `pr_number` is defined but not required

**Current behavior:**
1. `run_stage("pr", ...)` returns `{status: "success", summary: "..."}` (fallback, no `pr_number`)
2. Line 2104: `pr_number=$(jq -r '.pr_number')` → `null`
3. Line 2112: `log "PR #null created/updated"` — no validation
4. Line 2148+: Review loop prompts reviewer with "Review PR #null" → reviewer returns `changes_requested` → fix loop begins → wasted cycles

**Desired behavior:**
1. After extracting `pr_number`, validate it's a positive integer
2. If missing/null, recover by querying `gh pr list --head <branch> --json number`
3. If still not found, fail cleanly with a clear error instead of entering a broken review loop

## Evaluation

**Approach:** Add PR number validation with `gh pr list` recovery fallback after extraction, and make `pr_number` required in the JSON schema.

**Rationale:** The structured_output fallback is a general mechanism that can't know about stage-specific fields like `pr_number`. The fix should be at the consumer side (PR stage handling) where we can validate and recover. Making `pr_number` required in the schema will also pressure the Claude agent to return it, reducing fallback frequency.

**Risks:**
- `gh pr list` could return multiple PRs for the same branch — mitigated by taking the first result (most recent)
- Making `pr_number` required could cause schema validation failures — mitigated by the existing fallback mechanism

**Alternatives considered:**
- Enriching the generic fallback to include stage-specific fields — rejected because the fallback mechanism is intentionally generic
- Parsing PR number from the `.result` text with regex — rejected because fragile and unreliable

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(S)** Add PR number validation and recovery in `create_and_review_pr()` — after line 2104, add: (1) validate `pr_number` is a positive integer, (2) if null/missing, query `gh pr list --head "$branch" --state open --json number --jq '.[0].number'` to recover, (3) if still null, log error and exit cleanly. Also make `pr_number` required in `implement-issue-pr.json` schema.
- [ ] `[bash-script-craftsman]` **(S)** Add BATS tests for PR number recovery — test cases: (1) pr_number extracted from structured_output normally, (2) pr_number missing triggers `gh pr list` recovery, (3) both missing triggers clean error exit, (4) non-integer pr_number triggers recovery

## Acceptance Criteria

- [ ] AC1: When `run_stage("pr")` returns structured output with valid `pr_number`, flow is unchanged
- [ ] AC2: When `run_stage("pr")` returns fallback without `pr_number`, orchestrator recovers via `gh pr list` and proceeds with correct PR number
- [ ] AC3: When both structured output and `gh pr list` fail to provide a PR number, orchestrator exits cleanly with a descriptive error (not an infinite loop)
- [ ] AC4: All existing BATS tests continue to pass, plus new tests for PR number recovery
- [ ] AC5: `pr_number` is required in `implement-issue-pr.json` schema
