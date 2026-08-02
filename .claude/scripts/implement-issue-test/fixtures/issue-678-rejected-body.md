<!-- pipeline-autocreated -->

## Context

PR #676 (issue #673) closed the drift between the parallel task wall-clock watchdog and the serial `implement-task` stage timeout by raising both to 1800s — but only for the S/M path. `get_stage_timeout()` still returns **3600s** for `implement*` stages when complexity is `L`, while the parallel watchdog uses the flat `MAX_TASK_WALL_TIME_SECS` (1800s) for every task regardless of size. An L task therefore gets 3600s serially and 1800s in parallel: exactly the bug just fixed, one size class up.

## Research Findings

The two limits are computed in different places and only the serial one is complexity-aware:

**Files affected:**
- `.claude/scripts/implement-issue-orchestrator.sh:276-297` — `get_stage_timeout()`; the `implement*|fix*` branch returns `3600` when `$2 == "L"`, else `1800`. This is the serial ceiling and is already complexity-aware.
- `.claude/scripts/implement-issue-orchestrator.sh:134` — `MAX_TASK_WALL_TIME_SECS="${MAX_TASK_WALL_TIME_SECS:-1800}"`, the in-source fallback for the parallel ceiling. Flat, no complexity input.
- `.claude/scripts/implement-issue-orchestrator.sh:6685-6700` — inside `execute_batch_parallel()`'s launch loop, `tsize=$(extract_task_size "$tdesc")` is already resolved per task (`extract_task_size`, line 4565, yields `S`/`M`/`L`/empty). The complexity needed for a per-task wall time is therefore already in scope at the launch site.
- `.claude/scripts/implement-issue-orchestrator.sh:6731-6737` — the watchdog subshell: `( sleep "${MAX_TASK_WALL_TIME_SECS}" && kill -- -"$_task_pid" )`. Uses the flat global, so an L task is SIGTERMed at 1800s.
- `.claude/scripts/implement-issue-orchestrator.sh:6745-6760, 6795-6800` — the "Task N TIMED OUT after Ns" log, the "wall-time limit Ns" launch log, and the result-collection timeout message all interpolate the same flat global; they must report whatever per-task value actually governed the kill or the logs will lie.
- `.claude/scripts/implement-issue-orchestrator.sh:6255-6262` — `run_task_in_worktree()` (the process the watchdog kills) sets `base_timeout=$(get_stage_timeout "implement-task-$task_id" "$task_size")`. For an L task the inner `claude` invocation is given 3600s while the outer watchdog fires at 1800s — the inner timeout is unreachable in parallel.
- `.claude/config/platform.sh:140-143` — the consumer-facing override, flat `1800` with a comment asserting it "matches the serial implement-one-task stage timeout". That claim is false for L. Note `sync.sh` treats `config/platform.sh` as a seed-once consumer config (`CONSUMER_CONFIG_FILES`, sync.sh:82), so a fix that lives *only* here never reaches the 8 already-seeded consumer repos; the orchestrator ships in the plugin bundle and does propagate.
- `plugins/pipeline-core/scripts/implement-issue-orchestrator.sh` — produced artifact. `.claude/scripts/implement-issue-test/test-bundle-parity.bats:58` fails unless `./sync.sh bundle` is re-run after editing the canonical orchestrator.

**Current behavior:** every parallel task is killed at `MAX_TASK_WALL_TIME_SECS` (1800s). An L task that needs up to its 3600s serial budget is SIGTERMed mid-run; no result file is written, so the launcher marks it `timeout`, `execute_batch_parallel` discards the whole batch, and every task in that batch is re-run serially — paying for the work twice, then finally granting the L task 3600s.

**Desired behavior:** the parallel wall clock for a task is never tighter than the serial stage timeout for that task's complexity. An L task gets >= 3600s in parallel; S/M/unsized tasks keep 1800s (no blanket increase that would leave a genuinely hung small task running an extra 30 minutes).

## Relevant Existing Tests

**Unit tests (bats):**
- `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:610-644` — the #673 drift guard. Three tests: serial timeout is 1800 for `implement-task-1` with **no** complexity arg; `MAX_TASK_WALL_TIME_SECS >= serial_timeout`; and a negative control proving 900 would fail. All three pass `""` as complexity, so the `L` branch of `get_stage_timeout` is never exercised — this is the coverage hole the issue names.
- `tests/timeout-budget.bats:191-208` — invariant (2b): `MAX_TASK_WALL_TIME_SECS >= get_stage_timeout("test-iter-*")` (1500). Extracts `^MAX_TASK_WALL_TIME_SECS=` and `get_stage_timeout()` from the orchestrator by `awk` range (lines 72-101). Any new helper function must either be self-contained or be added to that awk extraction list, and the variable must keep its `^MAX_TASK_WALL_TIME_SECS=` line-start form.
- `tests/watchdog-fd-inheritance.bats:67,105` — watchdog subshell semantics (pipe EOF, no orphaned `sleep`). Exercises the same code region being edited; must stay green.
- `.claude/scripts/implement-issue-test/test-bundle-parity.bats:58,99,114` — canonical vs bundled script parity and `bash -n` on the bundle.

**Coverage gaps:**
- No test asserts a complexity-aware parallel ceiling for `L` (the bug).
- No test asserts the watchdog actually *uses* the per-task value rather than the global (a helper could be added and left unwired and every existing test would still pass).
- Nothing asserts the log lines report the value that governed the kill.

## Evaluation

**Approach:** Add a `get_task_wall_time <complexity>` helper next to `get_stage_timeout` that returns `max(MAX_TASK_WALL_TIME_SECS, get_stage_timeout "implement-task" "$complexity")`, then wire it into `execute_batch_parallel`'s launch loop (where `tsize` is already computed) for the watchdog `sleep` and all three timeout log lines.

**Rationale:** Deriving the parallel ceiling from `get_stage_timeout` makes the invariant structural rather than a number two humans must remember to keep in sync — the class of bug that has now recurred twice cannot recur a third time when the L ceiling changes. Keeping `MAX_TASK_WALL_TIME_SECS` as a *floor* (not a replacement) preserves the operator env override, the `platform.sh` knob, and `tests/timeout-budget.bats`'s (2b) invariant unchanged. Putting the derivation in the orchestrator rather than `platform.sh` is what makes the fix reach already-seeded consumer repos, whose `platform.sh` is never re-synced.

**Risks:**
- Helper added but watchdog left on the flat global — the bug survives a green test suite. Mitigation: the new bats test must assert the wired value (grep the watchdog region for the per-task variable, or assert `get_task_wall_time L` is what the launcher interpolates), not merely that the helper returns 3600.
- Editing `.claude/scripts/implement-issue-orchestrator.sh` while the pipeline is running it can crash or stall the orchestrator (bash caches function bodies). Mitigation: implement via subagent/worktree, not a live in-place pipeline edit.
- Stale bundle: `plugins/pipeline-core/scripts/` must be regenerated with `./sync.sh bundle` or bundle-parity fails.
- `tests/timeout-budget.bats` sources functions by awk range pattern; a new function it does not extract will be undefined if that test ever calls it. Mitigation: add `get_task_wall_time` to the awk list only if the test needs it; keep the variable assignment at line start.
- Known limit (out of scope): the wall clock guarantees **one** full attempt, while `run_task_in_worktree` may loop up to `get_max_review_attempts` times. Parity with the single-attempt stage timeout is what #673 established; do not silently widen it here.

**Alternatives considered:**
- Raise `MAX_TASK_WALL_TIME_SECS` flat to 3600 — rejected: leaves a hung S/M parallel task burning an extra 30 minutes, and drifts again the moment the L branch changes.
- Lower `get_stage_timeout`'s L branch to 1800 — rejected: removes real capacity that L tasks need serially; fixes the comparison by deleting the feature.
- Assert the invariant only in a test and hard-code 3600 in `platform.sh` — rejected: `platform.sh` is seed-once, so existing consumers keep the flat 1800.

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(S)** RED first — extend the #673 drift guard to the complexity axis: parametrise the existing invariant test over `"" S M L`, assert `get_stage_timeout "implement-task-1" "L"` is 3600, and add a wiring assertion that the parallel watchdog region resolves a per-task wall time (not the flat global) for L. Confirm the L case FAILS against current code before any fix — `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:610-644`
- [ ] `[bash-script-craftsman]` **(M)** Add `get_task_wall_time()` beside `get_stage_timeout` returning `max(MAX_TASK_WALL_TIME_SECS, get_stage_timeout "implement-task" "$1")`, and wire it into the parallel launch loop so the watchdog `sleep`, the launch log, the TIMED-OUT log and the result-collection message all use the per-task value — `.claude/scripts/implement-issue-orchestrator.sh:276-297`, `.claude/scripts/implement-issue-orchestrator.sh:6685-6760`, `.claude/scripts/implement-issue-orchestrator.sh:6795-6800`
- [ ] `[default]` **(S)** Correct the now-false "matches the serial implement-one-task stage timeout" comment to describe the value as a floor beneath the complexity-derived ceiling — `.claude/config/platform.sh:140-143`
- [ ] `[default]` **(S)** Run `./sync.sh bundle` to regenerate `plugins/pipeline-core/scripts/implement-issue-orchestrator.sh`, then run `test-timeout-escalation.bats`, `tests/timeout-budget.bats`, `tests/watchdog-fd-inheritance.bats` and `test-bundle-parity.bats` green — `plugins/pipeline-core/scripts/implement-issue-orchestrator.sh`, `.claude/scripts/implement-issue-test/test-bundle-parity.bats:58`

## Acceptance Criteria

- [ ] AC1: For an `L`-complexity task, the parallel wall-clock limit applied by `execute_batch_parallel`'s watchdog is >= `get_stage_timeout "implement-task-N" "L"` (3600s) — `.claude/scripts/implement-issue-orchestrator.sh:6731-6737`
- [ ] AC2: For `S`, `M` and unsized tasks the parallel wall-clock limit is unchanged at 1800s (no blanket increase)
- [ ] AC3: `MAX_TASK_WALL_TIME_SECS` still functions as an operator override and as a floor — exporting a value above the derived ceiling raises the limit; `tests/timeout-budget.bats` invariant (2b) still passes
- [ ] AC4: `test-timeout-escalation.bats` asserts the invariant across `"" S M L`, and the `L` assertion is verified to FAIL against pre-fix code (RED evidence recorded in the PR)
- [ ] AC5: The three timeout log lines report the per-task limit that actually governed the kill, not the flat global
- [ ] AC6: `plugins/pipeline-core/scripts/implement-issue-orchestrator.sh` regenerated via `./sync.sh bundle`; `test-bundle-parity.bats` passes
- [ ] AC7: `.claude/config/platform.sh` comment no longer claims parity with the serial timeout

## References
- Parent Issue: #673
- PR/MR: #676
- Reviewer: @code-reviewer

