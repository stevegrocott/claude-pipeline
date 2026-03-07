## Context

The implement-issue pipeline's test loop wastes significant agent time and money (32% of total pipeline cost on average) due to three cascading root causes. During issue #558, the test loop cost $31.33 (57% of total). Agents spend up to 90 minutes trying to fix failures that are either environment issues, pre-existing problems, or unrelated to the PR.

## Root Cause 1: jest.setup.ts overrides service URLs with fake hosts

**Finding:** Services ARE running (Redis on :6379, PostgreSQL on :5432, backend on :30005) but `jest.setup.ts` deliberately overrides connection URLs:

```typescript
// jest.setup.ts line 270-273
process.env.REDIS_URL = 'redis://mock-redis:6379';      // ← fake host
process.env.REDIS_MAX_RETRIES = '1';
process.env.REDIS_RETRY_DELAY_MS = '100';
process.env.REDIS_CONNECTION_TIMEOUT_MS = '1000';
```

Integration tests that need real services are blocked by this override even when Docker containers are healthy. Tests named `.integration.test.ts` fail with connection errors because they're forced to connect to nonexistent `mock-redis:6379`.

**Fix:** This is project-specific (beegee-farm-3), not a pipeline template issue. But the pipeline should handle this gracefully — see Root Cause 3.

## Root Cause 2: `--changedSince` follows Jest dependency graph, pulling in unrelated tests

**Finding:** The orchestrator test command (line ~1318):
```bash
test_command="cd $safe_dir && npx jest --passWithNoTests --changedSince=$safe_branch"
```

Jest's `--changedSince` walks the **module dependency graph** — if a PR changes `CacheService.ts`, Jest finds ALL test files that import `CacheService` (directly or transitively) and runs them. This pulls in 20+ pre-existing test files alongside the 3-5 files the PR actually modified.

**Observed cascade (issue #558):**
- PR changed 3 files
- `--changedSince` pulled in 17 pre-existing test files
- Fix-test-quality spent $12+ and 36 minutes rewriting pre-existing code
- Same pattern repeated on issue #570 ($30.20 test cost)

**Observed cascade (issue #576):**
- Fix-tests-iter-2 fixed 4 failures, reported "all 53 tests pass" (only ran modified files)
- test-loop-iter-3 ran `--changedSince` → pulled in `CacheService.redis-client-initialization.test.ts` (25 failures) via dependency graph
- This test file wasn't modified by the PR — it imports a changed module

**Key insight:** The orchestrator already knows `--changedSince` is problematic — the validation stage (lines 1419-1423) explicitly uses `git diff` instead:
```bash
# Compute explicit changed-file list (three-dot merge-base diff, not
# Jest's --changedSince dependency graph)
changed_files=$(git -C "$loop_dir" diff "$BASE_BRANCH"...HEAD --name-only)
```

But the test execution stage still uses `--changedSince`.

**Fix:** Replace `--changedSince` with explicit test file paths from `git diff`. Passing file paths directly to Jest bypasses the dependency graph entirely.

## Root Cause 3: No pre-existing vs PR-introduced failure distinction

**Finding:** The orchestrator's convergence detection (lines 1358-1371) only tracks MD5 hashes of the complete failure set. It doesn't distinguish:
- Failures from test files changed in this PR (agent should fix)
- Failures from pre-existing test files pulled in by dependency graph (agent should ignore)
- Failures from environment issues like mock URLs (agent should skip)

The fix-agent prompt has no guidance about any of this:
```
"Fix ONLY the specific test failures listed below..."
```

Meanwhile, the validation prompt already has a pre-existing issues policy:
```
PRE-EXISTING ISSUES POLICY:
- If a test file has pre-existing quality issues NOT introduced by this PR, report 'passed'
```

**Fix:** Filter failures before dispatching to fix-agent. Only pass failures from PR-changed test files.

## Research Findings

### Jest CLI behavior confirmed

| Flag | Follows dependency graph? | Suitable? |
|------|--------------------------|-----------|
| `--changedSince=<branch>` | YES — walks imports | No |
| `--onlyChanged` / `-o` | YES — walks imports | No |
| `--findRelatedTests <files>` | YES — walks imports | No |
| `--lastCommit` | YES — walks imports | No |
| `jest path/to/test.ts` (explicit paths) | **NO** — runs only given files | **Yes** |
| `--testPathPattern=<regex>` | **NO** — matches file paths only | **Yes** |

There is NO Jest flag to disable the dependency graph. The only way to bypass it is passing explicit test file paths.

### Files affected
- `.claude/scripts/implement-issue-orchestrator.sh` — test command, fix-agent prompt, failure filtering
- `.claude/scripts/implement-issue-test/` — BATS tests for new behavior

## Evaluation

**Approach:** Replace `--changedSince` with a two-tier test strategy: (1) run explicitly changed test files first, (2) filter failures by PR scope before dispatching fix-agents.

**Rationale:** This addresses all three root causes at the pipeline level. Project-specific issues (like jest.setup.ts mock URLs) become irrelevant because the pipeline only runs and fixes test files that the PR actually changed. Pre-existing failures in pulled-in files never reach the fix-agent.

**Risks:**
- A PR might break a downstream test that it didn't modify. Mitigation: after PR-scoped tests pass, run full `--changedSince` as a non-blocking final check and report pre-existing failures as informational, not actionable.
- Some PRs add new source files without corresponding test files. Mitigation: the validate stage already catches missing test coverage.

**Alternatives considered:**
- Add `testPathIgnorePatterns` for `.integration.test.ts` — rejected because it only fixes one symptom (integration tests), not the broader cascade problem
- Require per-project jest config changes — rejected because the pipeline template should handle this centrally
- Add service health checks — rejected because it doesn't solve the dependency graph cascade

## Implementation Tasks

- [ ] `[default]` **(M)** Replace `--changedSince` with explicit changed-file test execution — in `run_test_loop()`, compute `changed_test_files=$(git diff "$BASE_BRANCH"...HEAD --name-only | grep -E '\.test\.[jt]sx?$|\.spec\.[jt]sx?$')` and pass them directly to Jest: `jest $changed_test_files`. Fall back to `--changedSince` only if no test files were directly changed. Also exclude `.integration.test.ts` files with a grep filter.
- [ ] `[default]` **(S)** Add pre-existing failure filtering to fix-agent dispatch — before building the fix prompt, compute which test files are PR-changed vs dependency-pulled. Only include failures from PR-changed test files in the `$failures` variable passed to the fix-agent. Log skipped pre-existing failures as informational.
- [ ] `[default]` **(S)** Add environment-awareness to fix-agent prompt — prepend: "If failures mention Redis/database connection errors, HTTP 500 from route handlers, or similar infrastructure issues, these are environment issues not code bugs. Skip these and note them as environment-dependent."
- [ ] `[default]` **(S)** Add non-blocking full-scope check after PR tests pass — after the PR-scoped test loop succeeds, optionally run `jest --changedSince=$BASE_BRANCH` once (no retry loop) and report any additional failures as a GitHub comment marked "Pre-existing failures (informational)" without blocking the pipeline.
- [ ] `[default]` **(S)** Update BATS tests — add test cases for: explicit file path test execution, integration test exclusion, pre-existing failure filtering, fallback to `--changedSince` when no test files changed

## Acceptance Criteria

- [ ] AC1: Test loop runs only explicitly changed test files (from `git diff`), not dependency-graph-expanded files
- [ ] AC2: `.integration.test.ts` files are excluded from the test loop
- [ ] AC3: Fix-agent only receives failures from PR-changed test files, not pre-existing failures
- [ ] AC4: Fix-agent prompt includes environment-failure guidance
- [ ] AC5: After PR tests pass, full-scope check runs once as informational (non-blocking)
- [ ] AC6: BATS tests pass with updated orchestrator behavior
- [ ] AC7: Pipeline test cost drops below 20% of total pipeline cost on average
