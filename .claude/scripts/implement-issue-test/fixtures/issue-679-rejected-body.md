<!-- pipeline-autocreated -->

## Context

PR #676 (issue #673) added a guard test asserting `MAX_TASK_WALL_TIME_SECS >= get_stage_timeout("implement-task-1")` — the parallel-task wall clock must never be tighter than the serial retry timeout, or a task that would succeed serially is killed in parallel and the whole batch re-runs. It also added a third "control" test meant to prove the guard actually discriminates. That control test compares two literals (`900 >= 1800`) and is unconditionally true, so it proves nothing about the guard or about what `platform.sh` resolves to.

## Research Findings

**How the value is actually resolved (the real config path):**

- `.claude/config/platform.sh:140` — `MAX_TASK_WALL_TIME_SECS="${MAX_TASK_WALL_TIME_SECS:-1800}"`
- `.claude/scripts/implement-issue-orchestrator.sh:134` — same in-source fallback, `${MAX_TASK_WALL_TIME_SECS:-1800}`
- `.claude/scripts/implement-issue-test/helpers/test-helper.bash:540-548` — `source_orchestrator_functions()` sources `$TEST_TMP/config/platform.sh` (a symlink to the copied real `platform.sh`, created at `helpers/test-helper.bash:88`) **before** sourcing the awk-extracted orchestrator body, whose `/^MAX_[A-Z_]+=/` rule (line 458) carries the orchestrator's own fallback. Production sourcing order is the same.
- Because **both** assignments use `${VAR:-default}`, a value pre-set in the environment survives the whole chain. Verified directly: `MAX_TASK_WALL_TIME_SECS=900 bash -c 'source .claude/config/platform.sh; echo $MAX_TASK_WALL_TIME_SECS'` → `900`. This is the override hook the control test should use.
- `get_stage_timeout()` at `.claude/scripts/implement-issue-orchestrator.sh:276-297` returns `1800` for `implement*` at non-`L` complexity — a pure function of its arguments, no config input.

**Files affected:**
- `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:629-641` — the tautological control test; the body to rewrite.
- `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:617-627` — the real invariant test whose comparison the control must exercise.
- `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:587-608` — the section comment block documenting sourcing order; must gain a note on the override path.

**Constraint discovered — re-sourcing in-process is unsafe.** `source_orchestrator_functions()` re-sources `model-config.sh`, which declares `readonly -a` arrays and `readonly` scalars (see the rationale comment at `helpers/test-helper.bash:44-58` and `234-260`). Calling it a second time inside a `@test` body that has already run `source "$MODEL_CONFIG_ARRAYS_FILE"` risks readonly-reassignment errors. The override re-source must therefore run in an **isolated subshell** (`run env MAX_TASK_WALL_TIME_SECS=900 bash -c '...'`, or a `( … )` subshell that re-sources only `platform.sh` plus the extracted config line), not in the test's own shell.

**Current behavior:** the control test hardcodes `drifted_value=900` and asserts `! (( 900 >= serial_timeout ))`. It never sets `MAX_TASK_WALL_TIME_SECS`, never re-sources anything, and would keep passing if the guard's comparison operator were inverted or if `platform.sh` stopped defining the variable at all.

**Desired behavior:** the control test presets `MAX_TASK_WALL_TIME_SECS=900` in the environment, re-runs the real sourcing path so the variable resolves to `900` through `platform.sh` + the orchestrator fallback, then runs the *same* comparison the guard test uses and asserts it reports a violation. Mutating the guard logic (e.g. flipping `>=` to `<=`) must break this test.

## Relevant Existing Tests

**Unit tests:**
- `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:609-615` — asserts the serial `implement-task-1` timeout is `1800` (issue #673 baseline).
- `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:617-627` — the real invariant: `MAX_TASK_WALL_TIME_SECS >= serial_timeout`, using the live sourced value.
- `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:629-641` — the tautological control (subject of this issue).
- `.claude/scripts/implement-issue-test/test-constants.bats:68-72` — `get_stage_timeout "implement-task-1"` returns `1800`.

**Consumer tests:** none — `MAX_TASK_WALL_TIME_SECS` is only asserted in `test-timeout-escalation.bats`; `.claude/scripts/implement-issue-orchestrator.sh:6733-6797` (the parallel watchdog that consumes it) has no direct test.

**E2E specs:** none (`TEST_E2E_CMD` unset; this is shell tooling).

**Coverage gaps:**
- Nothing verifies the invariant guard *discriminates* — a broken comparison would ship green.
- Nothing verifies that an environment-supplied `MAX_TASK_WALL_TIME_SECS` survives `platform.sh`'s `:-1800` default, i.e. that the config override path works at all.

## Evaluation

**Approach:** Extract the invariant comparison into a single shared assertion helper inside the bats file, then have the control test invoke that helper in a subshell where `MAX_TASK_WALL_TIME_SECS=900` was pre-set in the environment and the real config path re-sourced, asserting the helper reports a violation.

**Rationale:** A shared helper is what makes the control test non-tautological — both the guard test and the control drive the identical comparison, so any edit to the comparison logic changes both outcomes and the control fails loudly. Driving the value through `env MAX_TASK_WALL_TIME_SECS=900` + re-source exercises the same `${VAR:-default}` precedence production uses, so the test also pins the config-override contract. Running it in a subshell sidesteps the `readonly` re-source hazard already documented in the helper.

**Risks:**
- *Readonly clash on re-source* — mitigate by isolating in `run env … bash -c '…'`; assert on `$status`/`$output`, never re-source `model-config.sh` in the test's own shell.
- *Subshell swallowing setup state* — `$TEST_TMP`, `$MODEL_CONFIG_ARRAYS_FILE` and `cd "$TEST_TMP"` are exported/inherited, but `BATS_TEST_DIRNAME` must be passed explicitly if the subshell re-`load`s the helper; verify by asserting the subshell prints `resolved=900` before asserting the invariant verdict.
- *Over-coupling to helper internals* — keep the subshell script to the minimum sourcing needed (`platform.sh` + the orchestrator's `MAX_*` line) rather than re-running all of `source_orchestrator_functions`, if the full re-source proves fragile.

**Alternatives considered:**
- *Mutation-test the guard by editing `platform.sh` in `$TEST_TMP` (rewrite line 140 to `900`) and re-sourcing* — closer to the real drift scenario, but couples the test to a line number/text in `platform.sh` and breaks on any reformat; rejected in favour of the environment override, which uses the same `${:-}` seam by design.
- *Delete the control test entirely* — cheapest, but loses the discrimination signal that motivated it in #676; the guard would silently rot again. Rejected.
- *Move the comparison into a production function in the orchestrator and unit-test that* — cleanest long-term, but adds production surface for a test-only concern (YAGNI); rejected.

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(M)** Extract the invariant comparison into a single shared assertion helper used by both the guard test and the control test, then rewrite the control test to pre-set `MAX_TASK_WALL_TIME_SECS=900` in the environment, re-source the real config path in an isolated subshell (`run env MAX_TASK_WALL_TIME_SECS=900 bash -c '...'` — do NOT re-source `model-config.sh` in the test shell, see readonly hazard), assert the resolved value is `900`, and assert the shared helper reports a violation against that live value — `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:617-641`
- [ ] `[bash-script-craftsman]` **(S)** Update the section comment block to document the environment-override sourcing path (`${MAX_TASK_WALL_TIME_SECS:-1800}` in both `platform.sh:140` and `implement-issue-orchestrator.sh:134`) and why the control test must re-source in a subshell — `.claude/scripts/implement-issue-test/test-timeout-escalation.bats:587-608`

## Acceptance Criteria

- [ ] AC1: The control test in `.claude/scripts/implement-issue-test/test-timeout-escalation.bats` contains no hardcoded `drifted_value` literal compared against `serial_timeout`; the drifted value reaches the comparison via the environment → `platform.sh` → orchestrator-fallback sourcing chain.
- [ ] AC2: The control test asserts the resolved `MAX_TASK_WALL_TIME_SECS` is `900` after the override re-source, proving the `${VAR:-1800}` default did not clobber it.
- [ ] AC3: The guard test (`MAX_TASK_WALL_TIME_SECS (parallel) is not tighter than…`) and the control test both invoke the same shared comparison helper — the comparison expression appears exactly once in the file.
- [ ] AC4: Mutation check — temporarily inverting the comparison in the shared helper (`>=` → `<`) makes the control test FAIL. Record the observed failure output in the PR; revert the mutation before commit.
- [ ] AC5: `bats .claude/scripts/implement-issue-test/test-timeout-escalation.bats` passes in full (no readonly-reassignment errors from the added re-source), and `bats .claude/scripts/implement-issue-test/test-constants.bats` still passes.

## References
- Parent Issue: #673
- PR/MR: #676
- Reviewer: @code-reviewer

