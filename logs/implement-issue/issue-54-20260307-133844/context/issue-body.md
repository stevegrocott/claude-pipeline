## Context

Pipeline logs reveal four recurring error patterns that cause pipeline failures or wasted computation: missing structured output (~5% of stages), cascading timeouts on complex tasks, fallback model configuration edge cases, and the hard exit (exit 2) in test convergence vs soft break in quality convergence creating inconsistent recovery behavior. These patterns are individually handled but lack coordinated recovery strategies.

## Research Findings

**Files affected:**
- `.claude/scripts/implement-issue-orchestrator.sh` — structured output handling (lines 926-949), timeout handling (lines 854-865), convergence detection (quality: lines 1082-1101, test: lines 1767-1780), error logging
- `.claude/scripts/batch-orchestrator.sh` — circuit breaker (lines 638-653), error propagation
- `.claude/scripts/model-config.sh` — fallback model ceiling (line 188)

**Current behavior:**

**Pattern 1: Missing structured output (5% occurrence)**
- Fallback wraps `.result` as generic `{status: "success", summary: .result}` (line 936-944)
- Loses field-specific data needed by downstream stages
- Log message is generic: "No structured output from $stage_name" — doesn't capture the actual output for debugging
- Issue #17: 11 warnings in 223 log lines

**Pattern 2: Cascading timeouts**
- Issue #20: 4 consecutive implement tasks timed out (exit 124)
- No adaptive behavior: same timeout used for retry, same model, same prompt
- No early-exit heuristic: if 2+ consecutive tasks timeout, the issue is likely too complex for the model/timeout combination
- Salvage attempt only checks `.structured_output` (line 856) — could also try `.result` (same fallback pattern as missing structured output)

**Pattern 3: Inconsistent convergence exit behavior**
- Quality loop convergence: soft break, marks `loop_approved=true` (line 1098-1099) — allows pipeline to continue
- Test loop convergence: hard `exit 2` with state `test_convergence_failure` (line 1779) — terminates entire pipeline
- PR review convergence: hard `exit 2` with state `max_iterations_pr_review` (line 2609)
- Inconsistency means test convergence kills the pipeline even when quality loop and PR would have succeeded

**Pattern 4: Error message quality**
- "No structured output" doesn't log what WAS received
- Timeout errors don't log partial output length
- Convergence failures don't summarize which specific failures repeated
- Makes post-mortem debugging from logs difficult

**Evidence from logs:**
- Issue #20 run 1: "No structured output from implement-task-1" × 2 attempts, no useful diagnostic
- Issue #20 run 2: Exit code 124 on 4/5 tasks, no output salvage possible
- Issue #22: PR stage succeeded but `pr_number: null` — downstream code hit `exit 1` (line 2564)

**Desired behavior:**
- Log the first 500 characters of actual output when structured output extraction fails
- Apply timeout salvage to `.result` text (not just `.structured_output`) before declaring timeout failure
- Make test loop convergence a soft exit (like quality loop) instead of hard `exit 2`, allowing PR creation and docs stages to still run
- Add cascade detection: if 2+ consecutive stages timeout, log warning and optionally skip remaining tasks of same complexity

## Evaluation

**Approach:** Improve error diagnostics and make convergence behavior consistent across loops

**Rationale:** The error handling architecture is mature but inconsistent. Making convergence behavior uniform (soft exits) and improving error diagnostics are low-risk changes that improve both completion rate and debuggability. The cascade detection is a new heuristic but defaults to warning-only (no automatic behavior change).

**Risks:**
- Soft test convergence exit may allow incomplete pipelines to create PRs — mitigated by PR review stage catching quality issues
- Logging partial output could expose sensitive data — mitigated by truncating to 500 characters and logging to local file only (not issue comments)

**Alternatives considered:**
- Make all convergence hard exits — rejected because it reduces completion rate for no quality benefit (PR review catches issues)
- Add automatic model escalation on convergence — rejected because convergence means the issue is fundamentally unfixable by the agent, not a model capability problem

## Dependencies

- **Depends on #51** — #51 adds the hard cap on MAX_TEST_ITERATIONS. This issue's Task 3 (soft convergence exit) builds on top of #51's hard cap — the soft exit replaces the hard `exit 2` that #51 retains but caps. Implement #51 first so the hard cap exists, then this issue changes convergence from hard to soft exit.
- **Depends on #52** — #52 adds general structured output recovery. This issue's Task 2 (timeout `.result` fallback) extends #52's recovery pattern to the specific timeout case. Implement #52 first so the general fallback exists, then this issue applies the same pattern to timeout handling.

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(S)** Add diagnostic logging in structured output fallback (after line 947): log first 500 characters of raw output and output byte count when both `.structured_output` and `.result` extraction fail
- [ ] `[bash-script-craftsman]` **(S)** Apply `.result` fallback to timeout handling (lines 854-865): after checking `.structured_output`, try `.result` text wrapping (same as lines 936-944) before declaring timeout failure
- [ ] `[bash-script-craftsman]` **(M)** Change test loop convergence from hard `exit 2` to soft break (like quality loop): set `loop_complete=true`, log the convergence failure, but allow pipeline to continue to docs/PR/complete stages. Update `set_final_state` to `test_convergence_soft_exit` to distinguish from hard failures
- [ ] `[bash-script-craftsman]` **(S)** Add cascade timeout detection: track consecutive stage timeouts in `run_stage`; after 2+ consecutive timeouts, log warning with suggestion to increase timeout or reduce task complexity. No automatic behavior change — informational only
- [ ] `[bash-script-craftsman]` **(S)** Add convergence failure summary to test and quality loop exit messages: include the specific failure descriptions that repeated, not just the count
- [ ] `[default]` **(S)** Add BATS tests for diagnostic logging, timeout `.result` fallback, and soft test convergence exit behavior

## Acceptance Criteria

- [ ] AC1: When structured output extraction fails, the log includes the first 500 characters of raw output and byte count
- [ ] AC2: Timeout handling attempts `.result` text wrapping before declaring failure
- [ ] AC3: Test loop convergence uses soft exit (pipeline continues to docs/PR stages) instead of `exit 2`
- [ ] AC4: Consecutive stage timeouts (2+) produce a warning log entry with timeout count and stage names
- [ ] AC5: Convergence exit messages include specific repeated failure descriptions
- [ ] AC6: All existing BATS tests pass and new tests cover the changes
