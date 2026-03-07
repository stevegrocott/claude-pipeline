## Context

Spend analysis of pipeline logs reveals the test loop in `implement-issue-orchestrator.sh` consumes ~30% of total pipeline cost due to excessive iterations and validation-driven churn. Issue #17 spent $9.69 USD across 5 test iterations when tests passed on iteration 2 — the remaining 3 iterations were validation quality fixes at $1.47-2.15 each.

## Research Findings

**Files affected:**
- ``.claude/scripts/implement-issue-orchestrator.sh`` — test loop (`run_test_loop`, lines 1467-1857), convergence detection (lines 1767-1780), fix prompts (lines 1782-1792)
- ``.claude/scripts/model-config.sh`` — model selection for test/fix stages

**Current behavior:**
- `MAX_TEST_ITERATIONS=10` but observed max is 5 iterations — 50% headroom is wasteful
- Test convergence detection requires 3 identical failure signatures before exiting (line 1772) — allows 2 wasted iterations
- Validation-driven test loops create repeating cycles: tests pass → validation finds quality issues → fix cycle → tests pass → validation finds different quality issues → repeat
- Fix prompts for test quality (lines 1829-1846) lack scope constraints, causing agents to over-refactor test files
- Environment errors (Redis/DB connections) trigger fix agent dispatch despite the advisory ENVIRONMENT NOTE (line 1782)

**Evidence from Issue #17 logs:**
```
test-loop-iter-1: Tests FAILED (7 failures: 1 code + 6 environment) → fix ($2.57)
test-loop-iter-2: Tests PASSED → validation FAILED → fix ($1.47)
test-loop-iter-3: Tests PASSED → validation FAILED → fix ($2.15)
test-loop-iter-4: Tests PASSED → validation FAILED → fix ($1.96)
test-loop-iter-5: Tests PASSED (stalled)
```

**Desired behavior:**
- Lower `MAX_TEST_ITERATIONS` to 7 (safety margin above observed max of 5)
- Reduce test convergence threshold from 3 to 2 identical failure signatures
- Add explicit scope constraint to validation fix prompts ("only fix issues in PR-changed test files")
- Skip fix agent dispatch when all failures are environment-related (detect Redis/DB/HTTP 500 patterns)
- Cap validation-driven fix iterations separately from test failure iterations (e.g., max 2 validation fixes)

## Evaluation

**Approach:** Tighten test loop constants and add scope constraints to fix prompts

**Rationale:** The test loop structure is sound but constants are too generous. Reducing iteration caps and adding prompt constraints addresses the root causes without restructuring the loop. The convergence detection and environment error filtering are additive improvements that don't change the flow.

**Risks:**
- Lowering MAX_TEST_ITERATIONS could cause legitimate failures to exit early — mitigated by convergence detection catching repeating failures regardless
- Tighter validation scope may miss real quality issues — mitigated by PR review stage catching issues post-merge

**Alternatives considered:**
- Separate test execution from validation into independent loops — rejected because the combined stage (STEP 1 + STEP 2) saves a stage invocation per iteration
- Remove validation entirely — rejected because it catches hollow assertions and missing tests

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(S)** Lower `MAX_TEST_ITERATIONS` from 10 to 7 and reduce test convergence threshold from 3 to 2 identical failures in `implement-issue-orchestrator.sh` (lines 29, 1772)
- [ ] `[bash-script-craftsman]` **(S)** Add a `MAX_VALIDATION_FIX_ITERATIONS=2` constant and separate counter to cap validation-driven fix cycles independently from test failure fixes in `run_test_loop` (lines 1829-1846)
- [ ] `[bash-script-craftsman]` **(M)** Add environment error detection function that checks failure descriptions for Redis/DB/HTTP 500 patterns and skips fix agent dispatch when all failures are environment-related (around lines 1729-1765)
- [ ] `[bash-script-craftsman]` **(S)** Add explicit scope constraint to test validation fix prompt: "Only fix quality issues in test files that correspond to PR-changed implementation files" (line 1846 fix prompt)
- [ ] `[default]` **(S)** Update BATS tests to cover new constants and environment error detection logic

## Acceptance Criteria

- [ ] AC1: `MAX_TEST_ITERATIONS` is 7 and convergence threshold is 2
- [ ] AC2: Validation-driven fixes are capped at 2 iterations independently from test failure fixes
- [ ] AC3: Fix agent is not dispatched when all test failures match environment error patterns (Redis, DB, HTTP 500)
- [ ] AC4: Validation fix prompts include explicit scope constraint limiting fixes to PR-changed files
- [ ] AC5: All existing BATS tests pass and new tests cover the changes
