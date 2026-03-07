## Context

Pipeline performance analysis shows the test loop is the slowest compound stage, consuming 1.16 hours (4,190s) in Issue #17 — comparable to the entire implement phase (1.27 hours for 10 tasks). Fix-quality stages within the test loop escalate from 1 turn to 50 turns across iterations, with per-turn latency of ~19s (vs ~11s for implement stages). The quality loop is efficient (2 iterations, ~654s) but fix stages use opus ($0.92-2.15 per fix) even for S-complexity tasks.

## Research Findings

**Files affected:**
- `.claude/scripts/implement-issue-orchestrator.sh` — quality loop fix prompt (lines 1128-1138), test loop fix prompt (lines 1829-1846)
- `.claude/scripts/model-config.sh` — stage-to-tier mapping (lines 41-63), complexity override (lines 75-82)

**Current behavior:**
- Quality loop fix stages (line 1143) pass `$loop_complexity` but it may not reach `run_stage` as the complexity parameter for model selection — needs verification
- Test loop fix-quality stages (line 1846 `fix-test-quality-iter-$test_iteration`) are missing the complexity parameter entirely — always defaults to the implement agent's model (opus)
- `should_run_quality_loop` (lines 1199-1215) correctly skips S-tasks, but when quality loop DOES run for M/L tasks, the fix stage doesn't use complexity-based model selection

**Performance data from Issue #17:**
| Stage | Duration | Turns | Model | Cost |
|-------|----------|-------|-------|------|
| fix-test-quality-iter-4 | 969.5s | 50 | opus | $1.96 |
| fix-test-quality-iter-3 | 407.3s | 39 | opus | $2.15 |
| fix-review-task-1-iter-1 | 125.2s | 26 | opus | $0.92 |
| review-task-1-iter-2 | 317.2s | 23 | sonnet | $0.99 |

**Desired behavior:**
- Pass complexity hint to quality loop fix stages so S-complexity uses haiku, M uses sonnet, L uses opus
- Pass complexity hint to test loop fix-quality stages

## Evaluation

**Approach:** Add complexity-based model selection to fix stages in both quality and test loops

**Rationale:** The fix stages are the most expensive per-iteration cost. Routing them through `resolve_model` with complexity hints applies the existing model-config infrastructure that's already used for implement stages but is bypassed for fix stages.

**Risks:**
- Using haiku for S-complexity fixes may miss subtle issues — mitigated by the review stage catching remaining issues on next iteration

**Alternatives considered:**
- Remove simplify stage entirely — rejected because it produces measurable value ($0.11-0.24 per run, often catches imports/formatting)

## Dependencies

- **Depends on #48** — #48 builds the complexity hint parsing infrastructure (`resolve_model` with complexity parameter). This issue extends it to fix stages specifically.
- **Does NOT overlap with #50** — simplify-skip and cumulative-findings-cap changes are owned exclusively by #50. This issue focuses only on complexity hints for fix-stage model selection.

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(S)** Verify and fix `$loop_complexity` passthrough to the fix stage in `run_quality_loop` (line 1143) — ensure it reaches `run_stage` as the complexity parameter for model selection
- [ ] `[bash-script-craftsman]` **(S)** Pass complexity hint to test loop fix-quality stages (line 1846 `fix-test-quality-iter-$test_iteration`) — currently missing complexity parameter
- [ ] `[default]` **(S)** Add BATS tests for complexity passthrough to fix stages in both quality and test loops

## Acceptance Criteria

- [ ] AC1: Quality loop fix stages receive and use the complexity hint for model selection (verified via log output "Complexity: S/M/L")
- [ ] AC2: Test loop fix-quality stages receive complexity hint for model selection
- [ ] AC3: All existing BATS tests pass and new tests cover the changes
