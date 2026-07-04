---
name: implement-issue
description: Use when given an issue number/key and base branch to implement end-to-end
argument-hint: "[issue-number] [base-branch]"
inputs:
  - name: issue_number
    type: string
    required: true
    description: Issue number or key (e.g. "123" or "KIN-123")
  - name: base_branch
    type: string
    required: true
    description: Base branch to branch from and target for the PR
outputs:
  - name: pr_url
    type: url
    description: Pull request created upon successful completion
  - name: status_json
    type: file
    description: Final orchestrator status snapshot at logs/implement-issue/issue-N-timestamp/status.json
side_effects:
  - creates_git_branch
  - creates_pull_request
  - writes_logs: logs/implement-issue/issue-<N>-<ts>/
composes: []
failure_modes:
  - id: orchestrator_exit_1
    mitigation: check stage logs in logs/implement-issue/issue-N-timestamp/stages/ for the failing stage
  - id: orchestrator_exit_2
    mitigation: reduce task complexity or split the issue into smaller tasks
  - id: orchestrator_exit_3
    mitigation: verify --issue and --branch arguments are correct and the issue exists
---

# Implement Issue

End-to-end issue implementation — reads plan from issue tracker, implements with quality gates.

**Announce at start:** "Using implement-issue to run orchestrator for #$ISSUE against $BRANCH"

**Arguments:**
- `$1` — Issue number or key (required, e.g., "123" or "KIN-123")
- `$2` — Base branch name (required)

## Invocation

Immediately launch the orchestrator:

```bash
.claude/scripts/implement-issue-orchestrator.sh \
  --issue $ISSUE_NUMBER \
  --branch $BASE_BRANCH
```

Or with explicit agent override:

```bash
.claude/scripts/implement-issue-orchestrator.sh \
  --issue $ISSUE_NUMBER \
  --branch $BASE_BRANCH \
  --agent bulletproof-frontend-developer
```

## Monitoring

Check progress via status.json:

```bash
jq . status.json
```

Watch live:

```bash
watch -n 5 'jq -c "{state,stage:.current_stage,task:.current_task,quality:.quality_iterations}" status.json'
```

## Stages

| Stage | Agent | Description |
|-------|-------|-------------|
| parse-issue | default | read issue body, extract implementation tasks |
| validate-plan | default | verify referenced files/patterns still exist |
| triage | default (Haiku) | classify route: `fast-path` (surgical, test-only) or `full` (default) — see handle-issues SKILL for the six criteria |
| implement | per-task | execute each task from GH issue task list |
| task-review | spec-reviewer | verify task achieved goal |
| fix | per-task | address review findings |
| test | default | run test suite |
| review | code-reviewer | internal code review |
| pr | default | create/update PR |
| spec-review | spec-reviewer | verify PR achieves issue goals |
| code-review | code-reviewer | final code quality check |
| complete | default | post summary |

## Schemas

Located in `.claude/scripts/schemas/implement-issue-*.json`

## Logging

Logs written to `logs/implement-issue/issue-N-timestamp/`:
- `orchestrator.log` — main log
- `stages/` — per-stage Claude output
- `context/` — parsed outputs (tasks.json, etc.)
- `status.json` — final status snapshot

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success, PR created and approved |
| 1 | Error during a stage |
| 2 | Max iterations exceeded |
| 3 | Configuration/argument error |

If the orchestrator is killed mid-stage, the EXIT trap rewrites `state="running"` in `status.json` to `interrupted_during_<stage>` (e.g., `interrupted_during_merge_pr`) so the exit point is observable rather than masked by the recovery path in `batch-orchestrator.sh`.

## Integration

Called by `handle-issues` via `batch-orchestrator.sh`.
