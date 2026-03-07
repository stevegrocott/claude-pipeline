## Context

Pipeline completion rate is undermined by four failure modes: missing structured output (~5% of stages), cascading timeouts on complex tasks, PR number extraction failures blocking completion, and no graduated retry strategy. Issue #20 had 4 consecutive timeout failures and Issue #22 stalled because PR creation returned null for `pr_number`.

## Research Findings

**Files affected:**
- ``.claude/scripts/implement-issue-orchestrator.sh`` — structured output fallback (lines 926-949), timeout handling (lines 854-865), PR creation and number extraction (lines ~2540-2564), task retry logic
- ``.claude/scripts/batch-orchestrator.sh`` — circuit breaker (line 42, lines 638-653), rate limit blocking (lines 520-555)

**Current behavior:**
- Structured output fallback (lines 936-944) wraps `.result` as `{status: "success", summary: .result}` but loses field-specific data (e.g., `pr_number`, `tasks`, `branch`). ~5% of stages hit this fallback (11 warnings in 223 log lines for Issue #17).
- Task retry is hard-coded at 2 attempts with no backoff or model escalation between retries
- PR number extraction failure causes `exit 1` (line 2564) with no recovery — Issue #22 status shows `pr_number: null`
- Batch rate limit handling blocks the entire batch thread with synchronous `sleep` (line 751) — no parallel processing of other issues during wait
- No graduated timeout increase: a stage that times out at 1800s retries with the same 1800s timeout

**Evidence from logs:**
- Issue #20: 4/5 implement tasks timed out (exit 124), no output salvage possible
- Issue #22: PR created but `pr_number: null` in status.json, `find-mr.sh` recovery attempted but failed
- Issue #17: 11 structured output fallback warnings across 26 stages

**Desired behavior:**
- Add field-aware structured output recovery that extracts known fields (`pr_number`, `branch`, `tasks`) from `.result` text via regex patterns
- Implement graduated retry with model escalation: attempt 1 with original model, attempt 2 with next model up
- Add PR number recovery via `gh pr list --head <branch>` when structured output lacks `pr_number`
- Add a 20% timeout increase on retry (e.g., 1800s → 2160s) for stages that timed out

## Evaluation

**Approach:** Improve recovery mechanisms at each failure point without changing the pipeline flow

**Rationale:** The pipeline architecture is sound — failures happen at the edges (output parsing, timeout boundaries, field extraction). Targeted recovery at each point yields the highest completion rate improvement with minimal risk.

**Risks:**
- Regex-based field extraction from `.result` text is fragile — mitigated by only using it as last resort after structured output and jq fallback both fail
- Timeout increase on retry could mask genuinely too-complex tasks — mitigated by keeping max retries at 2

**Alternatives considered:**
- Restructure pipeline to checkpoint after each stage — rejected because the status.json already provides checkpointing; the issue is recovery logic not checkpoint availability
- Switch all stages to opus to prevent timeouts — rejected because it increases cost 10x for mechanical stages

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(M)** Add field-aware structured output recovery in `run_stage` (after line 944) that extracts `pr_number`, `branch`, and `tasks` from `.result` text using regex patterns when `.structured_output` is missing
- [ ] `[bash-script-craftsman]` **(S)** Add PR number recovery fallback in the PR creation section (around line 2560): if `pr_number` is null after stage completes, run `gh pr list --head "$BRANCH" --json number -q '.[0].number'` to recover it
- [ ] `[bash-script-craftsman]` **(S)** Implement graduated retry for task implementation: on first failure, retry with `_next_model_up` model and 20% increased timeout in the task retry loop
- [ ] `[bash-script-craftsman]` **(S)** Add timeout escalation in `run_stage`: when a stage times out (exit 124) and is retried, increase timeout by 20% on the retry attempt
- [ ] `[default]` **(S)** Add BATS tests for PR number recovery, graduated retry model escalation, and timeout escalation logic

## Acceptance Criteria

- [ ] AC1: When `.structured_output` is missing but `.result` contains recognizable field values, they are extracted and used (at minimum `pr_number` and `branch`)
- [ ] AC2: PR creation stage recovers `pr_number` via `gh pr list` when structured output lacks it
- [ ] AC3: Failed task retries use the next model up (haiku→sonnet, sonnet→opus) on second attempt
- [ ] AC4: Timed-out stages get a 20% longer timeout on retry
- [ ] AC5: All existing BATS tests pass and new tests cover recovery logic
