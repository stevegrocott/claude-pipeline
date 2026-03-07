## Context

Analysis of recent pipeline runs (issues #558, #570, #576, #20) reveals the test loop consumes 32-57% of total pipeline cost. Three high-impact inefficiencies cause 60-120 minutes of waste per run: redundant double test execution, complexity-tier model override on test stages, and missing early exit for config-only changes.

## Research Findings

### Data from Recent Runs

| Issue | Test Cost | Total Cost | Test % | Test Iterations | Timeouts |
|-------|-----------|------------|--------|-----------------|----------|
| #558 | $31.33 | $55.06 | 57% | 9/10 | 3 (1hr each) |
| #570 | $30.20 | $54.91 | 55% | ? | ? |
| #576 | ~$15 | ~$30 | ~50% | 3+ | 1 |
| #20 (claude-pipeline) | ~$8 | ~$15 | ~53% | 3 | 1 |

### Root Cause 1: Double Test Execution Per Iteration

The test loop runs TWO Claude stages per iteration that BOTH execute the full test suite:

1. **test-loop-iter-N** (line ~1381): "Run the test suite... report pass/fail"
2. **test-validate-iter-N** (line ~1525): "Run the test suite... validate comprehensiveness"

The validation stage re-runs the same tests then analyzes code quality. Over 10 max iterations, this doubles test execution time (50-100 min wasted).

### Root Cause 2: Complexity Override Promotes Test Stages to Opus

`model-config.sh` maps complexity hints to tiers:
```
S → standard (sonnet), M → advanced (opus), L → advanced (opus)
```

This applies to ALL stages including test execution (line ~1381):
```bash
test_result=$(run_stage "test-loop-iter-..." ... "$loop_complexity")
```

Running tests doesn't require deep reasoning — Haiku can parse test output just as well. An M-complexity task makes every test iteration use Opus ($0.15/1k tokens) instead of Haiku ($0.008/1k tokens).

### Root Cause 3: Config-Only Changes Run Full Pipeline

The orchestrator detects config-only scope and skips tests (line ~1306), but still runs:
- Implementation stage (with nothing to implement)
- Quality loop (reviewing config changes like code)
- PR review loop

A `.env.example` or `package.json` version bump should skip to PR creation (~5 min vs 30-60 min).

**Files affected:**
- `.claude/scripts/implement-issue-orchestrator.sh` — test loop merging, config-only early exit
- `.claude/scripts/model-config.sh` — prevent complexity override on light-tier stages

**Current behavior:** Tests run twice per iteration; Opus used for test execution on M/L tasks; config-only changes run full pipeline.
**Desired behavior:** Tests run once per iteration with inline validation; test execution always uses Haiku; config-only changes skip to PR.

## Evaluation

**Approach:** Three targeted fixes: (1) merge test execution + validation into single stage, (2) prevent complexity override on light-tier stages, (3) add config-only early exit after parse_issue.

**Rationale:** These are the top 3 inefficiencies by measured impact. Each is independent and can be implemented/tested separately. Combined savings: 60-120 min per run, 50-70% cost reduction on test-heavy issues.

**Risks:**
- Merging test + validate could miss quality issues caught by separate validation. Mitigation: the merged prompt still validates — it just doesn't re-execute tests.
- Config-only early exit might miss edge cases where config changes need testing. Mitigation: only skip when ALL changed files match config patterns (no .ts/.tsx/.js files).

**Alternatives considered:**
- Parallel test runners (jest + bats) — rejected for this issue because savings are smaller (5-10 min) and adds complexity; good follow-up issue
- Draft PR mode — rejected for this issue because it's a UX improvement not an efficiency fix; good follow-up
- Parallel stages (PR creation during test loop) — rejected because it requires significant refactoring; good follow-up

## Implementation Tasks

- [ ] `[default]` **(M)** Merge test execution and validation into single stage — in `run_test_loop()`, replace the separate test-loop-iter and test-validate-iter stages with a single combined stage. The prompt should: (1) run the test suite once, (2) report pass/fail with failure details, (3) validate test comprehensiveness for changed files, (4) return both test results and validation findings in one structured response. Update the corresponding JSON schema if needed. Remove the separate validation stage call.
- [ ] `[default]` **(S)** Prevent complexity override on light-tier stages — in `model-config.sh`, modify `resolve_model()` to skip the complexity-to-tier override when the stage's default tier is "light". Test execution, parsing, and validation stages should always use their default tier regardless of task complexity. This ensures test stages use Haiku even for M/L complexity tasks.
- [ ] `[default]` **(S)** Add config-only early exit after parse_issue — after task extraction, if `detect_change_scope` returns "config", skip implement/quality/test stages and jump directly to PR creation. Add a GitHub comment: "Config-only changes detected — skipping to PR creation." Ensure the branch has commits before creating the PR.
- [ ] `[default]` **(S)** Update BATS tests — add test cases for: (1) merged test+validate stage produces combined output, (2) light-tier stages ignore complexity override, (3) config-only scope triggers early exit to PR stage

## Acceptance Criteria

- [ ] AC1: Test loop runs test suite exactly ONCE per iteration (not twice)
- [ ] AC2: Test execution stages use Haiku model regardless of task complexity
- [ ] AC3: Config-only changes (no .ts/.tsx/.js files) skip implement/quality/test and go directly to PR
- [ ] AC4: BATS tests pass with all changes
- [ ] AC5: Pipeline test cost drops below 25% of total cost on average
