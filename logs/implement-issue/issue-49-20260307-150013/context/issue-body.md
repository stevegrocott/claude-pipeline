## Context

Agent workflows waste 30-65% of their turns on file discovery instead of implementation. The implement-task prompt (line 2202) provides no file hints, forcing agents to spend 10-15 turns running git diff, Glob, and Grep before writing a single line of code. The simplify prompt (line 997) and docs prompt (line 2507) embed git commands that agents must execute, adding 3-10 turns each. Pre-computing these values in the orchestrator and passing them in prompts would eliminate this overhead.

## Research Findings

**Files affected:**
- `.claude/scripts/implement-issue-orchestrator.sh` — implement-task prompt (lines 2202-2213), simplify prompt (lines 997-1006), docs prompt (lines 2507-2511), review prompt (lines 1027-1047)

**Current behavior:**

1. **Implement-task prompt (lines 2202-2213):** Contains NO file hints. The agent receives the task description from the issue but must discover which files to modify. Evidence from Issue #17 logs: `implement-task-4` took 31 turns for a simple test fix — turns 1-10 were file exploration.

2. **Simplify prompt (lines 997-1006):** Embeds `git -C $loop_dir diff $BASE_BRANCH...HEAD --name-only -- '*.ts' '*.tsx'` — forces the agent to execute a bash command to discover modified files. This wastes 2-3 turns per quality loop iteration.

3. **Docs prompt (lines 2507-2511):** Same pattern — embeds git diff command for agents to discover changed files.

4. **Review prompt (lines 1027-1047):** Doesn't specify which files were modified, making the reviewer discover them independently.

5. **Test validation prompt (line 1685):** Already receives pre-computed `$changed_files` variable — this is the correct pattern that other stages should follow.

**Evidence from Issue #17:**
- 10 tasks × 10-15 wasted turns = 100-150 turns wasted on file discovery
- At ~$0.05-0.10 per turn (mixed model costs), this is $5-15 per pipeline run
- Total pipeline cost: $32.43, so file discovery waste is 15-46% of total cost

**Desired behavior:**
- Pre-compute modified file list once at the start of each quality loop iteration (already done for test validation — reuse pattern)
- Pass file list directly in implement-task, simplify, docs, and review prompts
- Include "LIKELY AFFECTED FILES" section in implement-task prompt based on task description parsing or prior task outputs

## Evaluation

**Approach:** Pre-compute file lists in the orchestrator bash script and inject them into stage prompts as variables

**Rationale:** The test validation stage already demonstrates the correct pattern (lines 1601-1603): `changed_files=$(git diff ... | filter_implementation_files)`. This same approach should be applied to all stages that currently embed git commands or lack file context. It's a pure prompt engineering change — no stage logic changes needed.

**Risks:**
- Pre-computed file lists may be stale if implement stages modify different files than expected — mitigated by recomputing at each loop iteration start
- Implement-task file hints may be wrong (task descriptions don't always specify files) — mitigated by adding "LIKELY" qualifier and telling agent to verify

**Alternatives considered:**
- Add file discovery to a dedicated pre-stage — rejected because it adds a stage invocation ($0.05+) to save turns within stages ($0.05-0.10 per turn × 3-5 turns saved)
- Modify agent definitions to be more efficient — rejected as secondary; the root cause is missing context in prompts, not agent behavior

## Implementation Tasks

- [ ] `[bash-script-craftsman]` **(S)** Pre-compute modified file list before the simplify stage in `run_quality_loop` (before line 997) using the same pattern as test validation (lines 1601-1603), and inject it into the simplify prompt replacing the embedded git command
- [ ] `[bash-script-craftsman]` **(S)** Pre-compute modified file list before the docs stage (before line 2507) and inject into the docs prompt replacing the embedded git command
- [ ] `[bash-script-craftsman]` **(S)** Pass the pre-computed file list to the review prompt in `run_quality_loop` (lines 1027-1047) as a "FILES CHANGED" section so reviewers don't re-discover files
- [ ] `[bash-script-craftsman]` **(M)** Add "LIKELY AFFECTED FILES" section to the implement-task prompt (lines 2202-2213): extract file paths mentioned in the task description using regex, and include any files modified by prior tasks in the same issue (from `git diff $BASE_BRANCH...HEAD --name-only`)
- [ ] `[default]` **(S)** Add BATS tests verifying that prompts contain file lists and don't contain embedded git commands

## Acceptance Criteria

- [ ] AC1: Simplify prompt receives pre-computed file list and does not contain embedded `git diff` command
- [ ] AC2: Docs prompt receives pre-computed file list and does not contain embedded `git diff` command
- [ ] AC3: Review prompt includes "FILES CHANGED" section with modified file paths
- [ ] AC4: Implement-task prompt includes "LIKELY AFFECTED FILES" section with paths extracted from task description and prior task diffs
- [ ] AC5: All existing BATS tests pass and new tests cover the changes
