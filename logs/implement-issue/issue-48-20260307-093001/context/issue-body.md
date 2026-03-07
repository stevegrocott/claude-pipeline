## Context

The pipeline's model selection system (`model-config.sh`) has blind spots where expensive models are used for simple tasks. Two concrete gaps: `fix-acceptance-test` stages fall through to opus (advanced) because the stage name doesn't match any prefix in `_stage_to_tier`, and `fix-e2e` stages always use sonnet regardless of task complexity because no complexity hint is passed. PR review also uses a flat two-tier model (haiku < 20 lines, sonnet ≥ 20 lines) without leveraging complexity hints.

## Research Findings

**Files affected:**
- `.claude/scripts/model-config.sh` — `_stage_to_tier` function (lines 41-63), `_STAGE_PREFIXES` array (lines 95-97)
- `.claude/scripts/implement-issue-orchestrator.sh` — `fix-e2e` call (line 2390), `fix-acceptance-test` call (line 2477), `get_pr_review_config` (lines 1186-1198)

**Current behavior:**

1. **`fix-acceptance-test` defaults to opus:** Stage name "fix-acceptance-test" is matched by `_match_stage_prefix` against the prefix list. The list includes "acceptance-test" (11 chars) and "fix" (3 chars). Since prefixes are ordered longest-first, "acceptance-test" doesn't match "fix-acceptance-test" (not a prefix), and "fix" does match. But "fix" maps to `standard` (sonnet). However, if the prefix matching fails entirely (returns empty), `resolve_model` defaults to `advanced` (opus) at line 150. The actual behavior depends on whether "fix" correctly matches — needs verification.

2. **`fix-e2e` ignores complexity:** Line 2390 calls `run_stage "fix-e2e" ... "$AGENT"` with no 5th argument (complexity). The stage defaults to `standard` (sonnet) regardless of whether the task is S/M/L complexity. For S-complexity tasks, this could use haiku instead.

3. **PR review is flat:** `get_pr_review_config` (lines 1186-1198) uses hardcoded model overrides (`haiku` for <20 lines, `sonnet` for ≥20 lines). This bypasses the complexity system entirely. Diffs of 20-50 lines that are trivial (rename, import reorder) get sonnet when haiku would suffice.

**Cost impact from Issue #17:**
- Review stages: $0.70-0.99 per invocation (sonnet)
- Fix stages: $0.92-2.15 per invocation (opus/sonnet)
- Haiku equivalent: ~$0.05-0.15 per invocation

**Desired behavior:**
- Verify and fix `fix-acceptance-test` prefix matching to correctly resolve to `standard` tier
- Pass complexity hint to `fix-e2e` stage so S-complexity tasks use haiku
- Extend PR review scaling with an intermediate tier for trivial diffs (e.g., <50 lines with no new functions → haiku)

## Evaluation

**Approach:** Fix prefix matching gaps, add missing complexity forwarding, and refine PR review model selection

**Rationale:** The model-config system is well-designed but has edge cases where the wrong model is selected. These are targeted fixes to existing infrastructure, not architectural changes. Each fix is independently valuable and independently testable.

**Risks:**
- Using haiku for fix-e2e on S-complexity tasks may produce lower-quality fixes — mitigated by the E2E verify stage (sonnet) catching remaining issues
- Adding complexity to PR review selection could reduce review quality for borderline diffs — mitigated by keeping sonnet as default for ≥50 lines

**Alternatives considered:**
- Remove all agent-hardcoded models — rejected because agents like code-reviewer intentionally use sonnet for quality assurance
- Always use opus for fixes — rejected because it's 10x more expensive than haiku for mechanical fixes

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(S)** Verify `fix-acceptance-test` prefix matching in `_match_stage_prefix` and add explicit `fix-acceptance*` case to `_stage_to_tier` if needed (model-config.sh lines 41-63, 95-97)
- [ ] `[bash-script-craftsman]` **(S)** Pass complexity hint (`$task_size` or `$loop_complexity`) as 5th argument to `fix-e2e` `run_stage` call in `implement-issue-orchestrator.sh` (line 2390)
- [ ] `[bash-script-craftsman]` **(M)** Refine `get_pr_review_config` to use three tiers: <20 lines → haiku/300s/1 iter, 20-50 lines → haiku/600s/1 iter, 50-200 lines → sonnet/900s/2 iter, >200 lines → sonnet/1800s/2 iter (lines 1186-1198)
- [ ] `[default]` **(S)** Add BATS tests for prefix matching of `fix-acceptance-test`, complexity forwarding to fix-e2e, and the new PR review tier thresholds

## Acceptance Criteria

- [ ] AC1: `fix-acceptance-test` resolves to `standard` (sonnet) tier, not `advanced` (opus), verified via `resolve_model` output
- [ ] AC2: `fix-e2e` stage receives complexity hint and uses haiku for S-complexity tasks (verified via log output "Complexity: S")
- [ ] AC3: PR review uses haiku for diffs 20-50 lines with 1 iteration and 600s timeout
- [ ] AC4: All existing BATS tests pass and new tests cover the changes
