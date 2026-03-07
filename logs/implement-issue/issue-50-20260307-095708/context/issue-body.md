## Context

The quality loop in `implement-issue-orchestrator.sh` runs simplify → review → fix per iteration with a convergence threshold of >50% repeated issues. While the loop is generally efficient (2 iterations observed for M-tasks in Issue #17, costing ~$2.35), three specific inefficiencies compound across tasks: the fix prompt includes ALL cumulative findings from every prior iteration (growing prompt size), the convergence threshold is too generous (50% repeats), and the simplify stage runs every iteration even when it made no changes in the prior iteration.

## Research Findings

**Files affected:**
- `.claude/scripts/implement-issue-orchestrator.sh` — `run_quality_loop` function (lines 971-1151), convergence detection (lines 1082-1101), fix prompt (lines 1128-1138), simplify stage (lines 997-1009)

**Current behavior:**

1. **Cumulative findings growth (lines 1122-1126):** The fix prompt builds cumulative findings from ALL prior iterations via `jq '[.[] | .issues[]? | .description] | unique | join("\n- ")'`. For a 4-iteration quality loop, this means iteration 4's fix prompt includes findings from iterations 1, 2, and 3 — even though iterations 1 and 2's findings were already fixed. This inflates prompt size and confuses the fix agent.

2. **Convergence threshold (line 1096):** `if (( repeat_ratio > 50 ))` — requires over half of current issues to be repeats before exiting. A 40% repeat ratio still triggers another full iteration (simplify + review + fix at ~$1.18 combined). Lowering to >33% would catch oscillating reviews earlier.

3. **Simplify always runs (lines 997-1009):** Even when the prior iteration's simplify reported "No changes to simplify" or "No changes". Each simplify invocation costs $0.11-0.24. For a 3-iteration loop, this wastes $0.22-0.48 on redundant simplify stages.

4. **Major-issue override (lines 1103-1111):** When review says "approved" but has major-severity issues, the verdict is overridden to "changes_requested". This is correct behavior but can trigger additional fix iterations that don't address the specific major issues.

**Evidence from Issue #17 quality loop (task-1):**
```
Iteration 1: Simplify ($0.24) + Review ($0.70) → 5 issues → Fix ($0.92)
Iteration 2: Simplify ($0.11) + Review ($0.99) → APPROVED
Total: $2.96 across 5 stages
```

**Desired behavior:**
- Limit cumulative findings in fix prompt to last 2 iterations (not all prior iterations)
- Lower convergence threshold from >50% to >33% repeat ratio
- Track simplify result and skip simplify on iteration N+1 if iteration N reported no changes
- When major-issue override triggers, include only the major issues in the fix prompt (not all issues)

## Evaluation

**Approach:** Tighten quality loop parameters and reduce redundant work

**Rationale:** The quality loop structure is sound and converges quickly in practice. These are incremental optimizations that reduce waste without changing the loop's architecture. Each change saves $0.10-0.50 per quality loop invocation, compounding across tasks and iterations.

**Risks:**
- Lower convergence threshold may exit too early on genuinely fixable issues — mitigated by PR review stage catching remaining issues
- Skipping simplify may miss new simplification opportunities after fix changes — mitigated by running simplify on the first iteration after a fix (only skipping consecutive no-op simplifies)

**Alternatives considered:**
- Remove simplify stage entirely — rejected because it catches real issues ($0.11-0.24 is cheap when it finds something)
- Remove convergence detection and rely only on max iterations — rejected because it wastes iterations when reviews oscillate

## Ownership Note

**This issue exclusively owns** the simplify-skip and cumulative-findings-cap changes. Issue #53 (fix-stage complexity hints) originally included these same tasks but they have been removed from #53 to avoid duplication. #53 focuses only on complexity hint passthrough to fix stages.

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(S)** Limit cumulative findings in quality loop fix prompt (lines 1122-1126) to the last 2 iterations by slicing the review history JSON with `[-2:]` before extracting descriptions
- [ ] `[bash-script-craftsman]` **(S)** Lower quality loop convergence threshold from >50% to >33% repeat ratio (line 1096)
- [ ] `[bash-script-craftsman]` **(S)** Track simplify stage result across iterations: if the prior iteration's simplify summary contains "No changes" or "no changes", skip simplify on the next iteration. Reset the skip flag after any fix stage runs.
- [ ] `[bash-script-craftsman]` **(S)** When major-issue override triggers (lines 1103-1111), filter the fix prompt to include only major-severity issues instead of all review issues
- [ ] `[default]` **(S)** Add BATS tests for cumulative findings truncation, convergence threshold, simplify skip logic, and major-issue filtering

## Acceptance Criteria

- [ ] AC1: Quality loop fix prompts include cumulative findings from only the last 2 iterations, not all prior iterations
- [ ] AC2: Quality loop exits when >33% of issues are repeats from prior iterations (was >50%)
- [ ] AC3: Simplify stage is skipped when prior iteration's simplify reported no changes
- [ ] AC4: Major-issue override passes only major-severity issues to the fix prompt
- [ ] AC5: All existing BATS tests pass and new tests cover the changes
