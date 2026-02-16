---
name: implement-issue
description: Use when given a GitHub issue number and base branch to implement end-to-end
argument-hint: "[issue-number] [base-branch]"
---

# Implement Issue

End-to-end issue implementation — reads plan from GitHub Issue, implements with quality gates.

**Announce at start:** "Using implement-issue to run orchestrator for #$ISSUE against $BRANCH"

**Arguments:**
- `$1` — GitHub issue number (required)
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
| parse-issue | default | read GH issue body, extract implementation tasks |
| validate-plan | default | verify referenced files/patterns still exist |
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

## Integration

Called by `handle-issues` via `batch-orchestrator.sh`.
