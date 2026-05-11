---
name: explore
description: Turn a vague idea or bug observation into a fully-planned issue with research, evaluation, implementation tasks, and acceptance criteria
argument-hint: "<description of idea or problem>"
inputs:
  - name: description
    type: string
    required: true
    description: Vague idea, bug observation, or feature request to research and plan
outputs:
  - name: issue_url
    type: url
    description: GitHub issue URL created and ready for /implement-issue
side_effects:
  - creates_github_issue
  - writes_log: logs/explore/explore-<issue>-<ts>/status.json
composes:
  - mcp-tools
failure_modes:
  - id: gh_api_unauthorized
    mitigation: surface the gh auth error to the operator, do not retry
  - id: vague_input_unanswered
    mitigation: ask 1-2 AskUserQuestion clarifications then proceed; do not block indefinitely
---

# Explore

## Overview

Turn a vague idea, bug observation, or feature request into a fully-researched, implementation-ready issue. This is Phase 1 of a two-phase workflow where issues are the single source of truth.

**Phase 1 (this skill):** idea → research → evaluate → plan → issue
**Phase 2 (`/implement-issue`):** GH issue → parse tasks → implement → test → review → PR

**Announce at start:** "Using explore to investigate and plan: $DESCRIPTION"

## Process

### Step 1: Understand the Idea

Refine the vague input into concrete requirements:
- Ask 1-2 clarifying questions if the description is too vague (use AskUserQuestion)
- If the description is specific enough, proceed without questions
- Identify: what's wrong / what's wanted, who's affected, what success looks like

### Step 2: Research the Codebase

**Framework/library documentation (use Context7 first):**
- `context7.resolve_library_id` → `context7.get_library_docs` for framework API docs
- Fall back to web search only if Context7 doesn't have the library or is unavailable
- See `mcp-tools` skill for full decision matrix

**Code structure and patterns (use Serena for structural queries):**
- Use Serena for class hierarchies, method signatures, call graphs
- Use Grep/Glob for text-based file search and discovery

**Document findings:**
- Identify affected files, services, components
- Document current behaviour vs desired behaviour
- Note architectural patterns to follow

**Context Checkpoint (Optional):** If the research phase read many files or generated extensive tool output, consider writing a concise research summary to a temp file and suggesting `/clear` before evaluation. The evaluation and planning phases only need the summary, not the raw exploration context. Use `/create-session-summary` if checkpointing.

### Step 3: Evaluate Approaches

Determine the best implementation strategy:
- Propose 2-3 approaches with trade-offs
- Select recommended approach with rationale
- Identify risks and mitigations
- Note alternatives considered and why rejected

### Step 4: Generate Implementation Plan

Break the chosen approach into implementable tasks:
- Each task specifies an agent type (see Task Format below)
- Tasks are ordered by dependency (data layer first, then presentation)
- Each task is a single logical unit of work
- Each task should target 5-30 minutes of subagent execution time
- If a task requires reading more than 3 files or modifying more than 2 files, split it
- Add a complexity hint: `- [ ] \`[agent]\` **(S)** Description` where S=small (~5 min), M=medium (~15 min), L=large (~30 min)
- **Parseable format required:** Every task line in `## Implementation Tasks` MUST begin with `- [ ] \`[agent-name]\``. Prose lines such as "Task 1: Do something" are **silently skipped** by the orchestrator — no error is raised and no warning is emitted; the task simply never executes.
- Frontend and backend changes in the same task should be split — backend first (data layer), then frontend (presentation)
- **E2E tests (REQUIRED for UI changes):** If `TEST_E2E_CMD` is configured in `.claude/config/platform.sh`, include an E2E task for ANY issue touching user-visible UI — CSS, components, layouts, forms, navigation, visual regressions. This is NOT optional for UI work.
  `- [ ] \`[playwright-test-developer]\` **(S)** Write Playwright E2E test for [flow description]`
  E2E tasks reference the `playwright-testing` skill and come after all implementation tasks so the feature exists before the test runs.
  **When to include:** Changes to components, pages, hooks, CSS, layouts, forms, navigation, or any file matching `FRONTEND_PATH_PATTERNS`.
  **When to skip:** Backend-only changes, config changes, documentation, CI/CD scripts.
  **Task descriptions must specify:** The page/component under test, the user action to perform, and the expected visual/behavioral outcome.
- Include acceptance criteria for the overall issue

### Step 5: Create Issue

**Before creating the issue, ask the user which epic to parent it under** using `AskUserQuestion`. Look up open epics in the project to offer relevant options. For Precis/KIKS, all issues must sit under KIKS-410 (the Precis initiative) within an appropriate epic. Present the most likely epics as options based on the research context (e.g., if the work is UI-related, suggest "KIKS-546 UI Enhancements").

**Deploy Verification section (optional):** Include a `## Deploy Verification` section if the issue involves environment-specific bugs or requires deployment testing. This section guides the deploy-verify stage by specifying target environment, health endpoint, and custom verification logic. Include this for bugs that only reproduce in test/staging/production but not locally.

Create the issue using the platform wrapper with `--parent` set to the chosen epic:

```bash
PLATFORM_DIR=".claude/scripts/platform"
"$PLATFORM_DIR/create-issue.sh" --title "$TITLE" --parent "$EPIC_KEY" --body "$(cat <<'EOF'
## Context
[What was discovered and why it matters — 2-3 sentences]

## Research Findings
[Codebase exploration results]

**Files affected:**
- `path/to/file.ts` — [what needs changing]
- `path/to/other.ts` — [what needs changing]

**Current behavior:** [what happens now]
**Desired behavior:** [what should happen]

## Evaluation
**Approach:** [chosen approach — 1 sentence]
**Rationale:** [why this approach — 2-3 sentences]

**Risks:**
- [risk 1 + mitigation]
- [risk 2 + mitigation]

**Alternatives considered:**
- [alternative 1] — rejected because [reason]
- [alternative 2] — rejected because [reason]

## Implementation Tasks
- [ ] `[agent-name]` **(S)** Description of task 1 — `src/services/auth.ts:L45-80`
- [ ] `[agent-name]` **(M)** Description of task 2 — `src/components/Dashboard.tsx:L120-155`
- [ ] `[agent-name]` **(L)** Description of task 3 — `src/api/users.ts:L30-65`
- [ ] `[default]` **(S)** Description of general task (e.g., tests, config) — `tests/unit/auth.test.ts:L10-40`
- [ ] `[playwright-test-developer]` **(S)** Write E2E test for [user flow] (if TEST_E2E_CMD configured) — `tests/e2e/dashboard.spec.ts:L22-55`

## Deploy Verification
[Include if this issue involves bugs in specific environments or requires deployment testing]
- **Target environment:** [staging|test|nas|production]
- **Health endpoint:** [full URL to health check endpoint, e.g., https://example.com/health]
- **Verification command:** [optional — custom shell command to verify deployment, e.g., "curl -s https://example.com/api/status | jq .status"]

## Acceptance Criteria
- [ ] AC1: [measurable criterion]
- [ ] AC2: [measurable criterion]
- [ ] AC3: [measurable criterion]
EOF
)"
```

### Step 5.5: Write Explore Log

After the issue URL is confirmed created, write a status.json log so claude-spend counts this explore session as 1 SP:

```bash
ISSUE_NUM=<number from the created issue URL>
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOG_DIR="logs/explore/explore-${ISSUE_NUM}-${TIMESTAMP}"
mkdir -p "$LOG_DIR"
cat > "$LOG_DIR/status.json" <<EOF
{
  "state": "completed",
  "issue": "${ISSUE_NUM}",
  "stages": {
    "research": { "status": "completed", "started_at": "${NOW}", "completed_at": "${NOW}" },
    "plan": { "status": "completed", "started_at": "${NOW}", "completed_at": "${NOW}" },
    "create_issue": { "status": "completed", "started_at": "${NOW}", "completed_at": "${NOW}" }
  },
  "task_summary": {
    "completed": { "S": 1, "M": 0, "L": 0 },
    "failed": { "S": 0, "M": 0, "L": 0 },
    "sp_completed": 1,
    "sp_total": 1
  },
  "escalations": [],
  "log_dir": "${LOG_DIR}"
}
EOF
```

Only write this log after the issue is confirmed created. If the explore run fails before Step 5, skip this step entirely.

### Step 6: Report

Output the created issue URL and a brief summary:
```
Created issue #NNN: "Title"
URL: https://github.com/...

Ready for implementation: /implement-issue NNN main
```

## Task Format Specification

The `## Implementation Tasks` section must use this parseable convention:

```markdown
- [ ] `[agent-name]` **(M)** Task description — `src/path/file.ts:L10-40`
```

**Files suffix:** Append ` — \`path/to/file.ts:L10-40\`` (em dash, space, backtick-quoted path with optional line range) to every task description. Multiple files: ` — \`file1.ts:L5\`, \`file2.ts:L20-35\``. This tells subagents exactly where to look, eliminating broad codebase scans.

**Agent values** (adapt to your project's agents):
- Use whatever agent names are configured in `.claude/agents/`
- Common patterns: `[backend-developer]`, `[frontend-developer]`, `[playwright-test-developer]`, `[default]`
- `[playwright-test-developer]` for E2E tests (when `TEST_E2E_CMD` is configured)
- `[default]` for general tasks (config, tests, documentation, mixed)

**Parsing rule:** Regex `- \[[ x]\] \x60\[(.+?)\]\x60 (.+)` extracts agent and description. Task IDs assigned sequentially.

## Key Principles

- **One issue per problem** — don't combine unrelated work
- **Research before planning** — understand the codebase before proposing changes
- **Parseable output** — the task list format must be mechanically extractable by the orchestrator
- **YAGNI** — only plan what's needed, don't gold-plate
- **Minimal questions** — if the description is clear enough, proceed without asking

## Token Efficiency

Task sizing directly controls model cost via `model-config.sh`:

- **Prefer S-complexity tasks** — S and M tasks use sonnet; only L tasks use opus. Prefer S over M/L for smaller scope, not model savings.
- **Split M/L tasks into multiple S tasks** when the work is decomposable into independent steps.
- **Every task MUST include at least one file path. Tasks without file paths will cause subagents to scan broadly — this is the #1 token waste in the pipeline.**
- **Each task's affected file list reduces subagent exploration cost** — include file paths in the task description.

## Integration

**Produces:** An issue ready for `/implement-issue N main`
**Consumes:** Vague natural language descriptions
**Followed by:** `/implement-issue` skill (Phase 2)

## Red Flags

| Temptation | Why It Fails |
|------------|--------------|
| Skip research, jump to planning | Plan won't account for existing patterns |
| Create local plan files | The issue IS the plan — single source of truth |
| Over-plan with 20+ tasks | Keep it focused; split into multiple issues if needed |
| Combine multiple concerns in one issue | One issue = one problem = one PR |
| Ask too many clarifying questions | 0-2 questions max; research answers most questions |
| Single task modifies 5+ files | Split into focused subtasks |
| Task has no file paths | Subagent reads 13+ files to orient; include at least 1 file path per task |
