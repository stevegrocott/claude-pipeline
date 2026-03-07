## Context

Analysis of 6 completed pipeline runs on beegee-farm-3 (issues #556, #558, #559, #564, #567, #570) reveals the test cascade burned ~50% of total pipeline cost. The original #17 focused on pipeline fixes, but deeper analysis shows **the root cause is the test suite itself**, not just the pipeline's scope controls.

**Lesson from #15:** Issue #15 (model-config wire-up) was closed without a PR because the template repo's BATS test suite couldn't verify the integration — tests expected model-config but the test helper didn't source it. We fixed this in PR #18, but it exposed a broader problem: **32 of 474 BATS tests (7%) are broken**, most testing an architecture that no longer exists.

**Pipeline Benchmark (6 runs, 29 tasks):**

| Issue | Tasks | Sizes | Impl Cost | Test Cost | Total | Test % |
|-------|-------|-------|-----------|-----------|-------|--------|
| #556 | 3 | M,M,S | $11.53 | $0.00 | $13.09 | 0% |
| #558 | 6 | S×5,M | $14.86 | $31.33 | $54.55 | 57% |
| #559 | 4 | S×3,M | $10.21 | $1.12 | $30.75 | 4% |
| #564 | 9 | S×6,M×2,L | $27.13 | $23.65 | $106.03 | 22% |
| #567 | 3 | S×3 | $4.86 | $0.00 | $7.00 | 0% |
| #570 | 4 | S×4 | $5.91 | $30.20 | $54.67 | 55% |
| **Total** | **29** | | **$74.50** | **$86.30** | **$266.09** | **32%** |

Per-task implementation benchmarks:
- **S-size**: $0.63–$4.79 (avg ~$2.06), 2–10 min
- **M-size**: $2.88–$10.85 (avg ~$5.10), 7–22 min
- **L-size**: $4.42, 10 min (1 data point)

## Root Cause Analysis

### Why the test cascade happens

During issue #558, the pipeline's test loop used `--changedSince=main` which pulls in ALL tests importing modified modules via Jest's dependency graph. This included **17 pre-existing test files** alongside the 3 files created by #558.

When tests passed (iter 6+), **test-validate kept flagging pre-existing quality issues** in those 17 files:
- Tautological tests (assert mock returns what you told it to return)
- Unfailable try/catch (both paths contain passing assertions)
- 60% skipped test suites (`it.skip` everywhere)
- Accept-any-status-code assertions (200, 401, 404, 500 all pass)
- Inline logic duplication (test duplicates implementation, tests itself)
- Tests that silently pass without data

**fix-test-quality then spent $12+ and 36 minutes rewriting these pre-existing files** — work unrelated to the issue being implemented. This is the cascade.

### The fix is the tests, not (only) the pipeline

If pre-existing test files were clean, test-validate would find nothing to flag, and the cascade wouldn't happen **regardless of pipeline scope controls**. Pipeline scope controls are defense-in-depth, not the primary fix.

### BATS test suite is also stale

The orchestrator's own BATS tests have 32 failures from 3 categories:

| Category | Files | Failures | Root Cause |
|----------|-------|----------|------------|
| Stale architecture | test-integration.bats, test-status-functions.bats | 18 | Tests reference worktree stages, research/evaluate/plan stages, setup schemas, `set_worktree_info` — none of which exist in current orchestrator |
| Missing bats-assert | test-argument-parsing.bats, test-stage-runner.bats | 7 | Tests use `fail` command from bats-assert library which isn't loaded |
| Rate-limit detection | test-rate-limit.bats | 5 | String matching logic doesn't match current `detect_rate_limit` implementation |
| Misc | test-comment-helpers.bats, test-constants.bats | 2 | REPO constant not extracted by awk helper |

**15 of 50 integration tests (30%)** test an old orchestrator architecture (worktree-based, with research→evaluate→plan stages). These should be rewritten for the current GH-Issue→parse→implement→test→review→PR flow.

## Implementation Tasks

### Priority 1: BATS test suite cleanup (claude-pipeline — highest ROI for pipeline reliability)

- [ ] `[default]` **(M)** Rewrite `test-integration.bats` for current orchestrator architecture — remove all worktree/setup/research/evaluate/plan stage tests. Replace with tests for current flow: parse-issue→implement (self-review)→quality-loop→test-loop→docs→pr→pr-review→complete. Should test: parse-issue schema, implement-task schema, test-loop flow, quality-loop flow, PR creation flow. Target: 0 failures.
- [ ] `[default]` **(S)** Fix `test-argument-parsing.bats` — replace `fail` commands with BATS-native `[ "$status" -ne 0 ]` or `[[ ... ]] || return 1` patterns. Alternatively, add bats-assert as a test dependency. Target: 0 failures.
- [ ] `[default]` **(S)** Fix `test-status-functions.bats` — remove `set_worktree_info` tests (function no longer exists), update `init_status` test to match current status.json schema (no setup/research/evaluate/plan stages). Target: 0 failures.
- [ ] `[default]` **(S)** Fix `test-rate-limit.bats` — update `detect_rate_limit` tests to match current implementation's string matching logic. 5 tests expect case-insensitive substring matching that the implementation doesn't provide. Either fix tests to match implementation, or fix implementation to match test expectations. Target: 0 failures.
- [ ] `[default]` **(S)** Fix `test-comment-helpers.bats` — ensure REPO constant is extracted by `source_orchestrator_functions()` awk filter, or mock it in test setup. Target: 0 failures.

### Priority 2: Pipeline timeout and scope controls (defense-in-depth)

- [ ] `[default]` **(S)** Fix timeout-as-success bug in `run_stage()` callers — when `run_stage()` returns `{"status":"error","error":"timeout"}`, callers check `.result` (null) not `.status`. In test loop: null ≠ "failed" falls through to test-validate. In PR review: null ≠ "approved" triggers fix cycle with empty feedback. Add helper `is_stage_timeout()` and handle explicitly.
- [ ] `[default]` **(S)** Add scope constraints to fix-tests prompt — change to: "Fix ONLY the specific test failures listed below. Do NOT rewrite test files, introduce new dependencies, or modify pre-existing test code. Only fix the failing assertions."
- [ ] `[default]` **(S)** Add scope enforcement to test-validate — compute explicit file list via `git diff $BASE_BRANCH...HEAD --name-only` (not `--changedSince` dependency graph). Pass to validate prompt as "ONLY validate tests for these specific files." Add: "If a test file has pre-existing quality issues NOT introduced by this PR, report 'passed' and note them separately."
- [ ] `[default]` **(S)** Add stage-type-based timeouts — replace flat `STAGE_TIMEOUT=3600` with `get_stage_timeout()`: test/docs/pr→600s, task-review/test-validate→900s, implement/fix→1800s, pr-review→1800s.
- [ ] `[default]` **(S)** Add branch verification before commits — `verify_on_feature_branch()` checks `git rev-parse --abbrev-ref HEAD` matches expected branch before fix stages.

### Priority 3: Project test quality (beegee-farm-3 — prevents cascade at source)

_Note: This should be a separate issue on beegee-farm-3, not implemented here. Listed for completeness._

Pre-existing test files that triggered the cascade in #558 (all in beegee-farm-3):
- `scenario-pandl-force-refresh.test.ts` — tautological mock assertions
- `CostGenerationService.test.ts` — tests inline logic, not the service
- `CacheServiceMemoryFixed.integration.test.ts` — unfailable try/catch
- `CacheService.redis-client-initialization.test.ts` — 60% skipped
- `farmConfiguration.test.ts` — accept-any-status-code
- `CacheService.type-safety.test.ts` — tautological
- `ClimateServices.ac-validation.test.ts` — silently passes without data
- `FinancialMetricsService.test.ts` — diagnostic tests, not behavioral

## Acceptance Criteria

- [ ] AC1: All 474+ BATS tests pass (0 failures) after Priority 1 cleanup
- [ ] AC2: test-integration.bats tests reflect current orchestrator architecture (parse→implement→test→review→PR)
- [ ] AC3: Stage timeout produces explicit failure handling (not fall-through)
- [ ] AC4: fix-tests and test-validate prompts include scope constraints
- [ ] AC5: Stage timeouts are type-based (10 min for light, 30 min for heavy)
- [ ] AC6: Feature branch verification runs before fix stages
- [ ] AC7: Measured projection: test cascade cost drops ~40% from scope constraints; drops to near-zero when combined with project test cleanup (Priority 3)
