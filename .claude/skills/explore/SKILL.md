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

**Test Surface Discovery (run after identifying affected files):**

Run Phases 0–3 of the `test-discovery` skill against the touched files (cap at 5 files). The skill itself documents what each phase does.

> **Graceful fallback:** If `.claude/skills/test-discovery/SKILL.md` does not exist, skip this sub-step and note "test-discovery skill unavailable" in the research findings.

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

**Deploy Verification section (scope-dependent):** Whether to include a `## Deploy Verification` section and what to put in it depends on which files are changed:

- **Backend or shared packages changed** (`apps/backend/`, `packages/`): Include the section with a full rebuild command (e.g., `bash scripts/deploy-nas-from-local.sh`). The NAS Docker image must be rebuilt to pick up backend changes.
- **Frontend-only changes** (`apps/frontend/`, CSS, components, pages): Include the section but use the `--health-only` flag (e.g., `bash scripts/deploy-nas-from-local.sh --health-only`). The NAS backend hasn't changed; a health-check curl (~5 s) is sufficient.
- **No NAS environment concern** (CI config, documentation, scripts unrelated to the deployed service): **Omit the section entirely.** An absent `## Deploy Verification` section means the orchestrator skips the deploy-verify stage.

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

## Relevant Existing Tests
**Unit tests:**
- `path/to/unit.test.ts:L1-30` — [what behavior is covered]

**Consumer tests:**
- `path/to/integration.test.ts:L1-30` — [what integration is covered]

**E2E specs:**
- `path/to/spec.e2e.ts:L1-30` — [what user flow is covered]

**Coverage gaps:**
- [what is not tested — inform implementation task descriptions]

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
- [ ] `[fastify-backend-developer]` **(S)** Description of backend task — `src/services/auth.ts:L45-80`
- [ ] `[react-frontend-developer]` **(M)** Description of frontend task — `src/components/Dashboard.tsx:L120-155`
- [ ] `[bash-script-craftsman]` **(S)** Description of script task — `.claude/scripts/deploy.sh:L30-65`
- [ ] `[default]` **(S)** Description of config/unit-test task — `tests/unit/auth.test.ts:L10-40`
- [ ] `[playwright-test-developer]` **(S)** Write E2E test for [user flow] (if TEST_E2E_CMD configured) — `tests/e2e/dashboard.spec.ts:L22-55`

## Deploy Verification
[Scope rule: include ONLY if this issue touches the NAS environment.
 - apps/backend/ or packages/ changed → full rebuild: bash scripts/deploy-nas-from-local.sh
 - apps/frontend/ only → health-only: bash scripts/deploy-nas-from-local.sh --health-only
 - No NAS concern (CI, docs, unrelated scripts) → OMIT this section entirely]
- **Target environment:** [staging|test|nas|production]
- **Health endpoint:** [full URL to health check endpoint, e.g., https://test-beegeefarm.grocott.com.au/health]
- **Verification command:** [bash scripts/deploy-nas-from-local.sh or bash scripts/deploy-nas-from-local.sh --health-only]

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

The issue body includes a **Relevant Existing Tests** section populated during Step 2 test surface discovery — implementers use this to know which tests to update and which coverage gaps remain.

## Task Format Specification

The `## Implementation Tasks` section must use this parseable convention:

```markdown
- [ ] `[agent-name]` **(M)** Task description — `src/path/file.ts:L10-40`
```

**Files suffix:** Append ` — \`path/to/file.ts:L10-40\`` (em dash, space, backtick-quoted path with optional line range) to every task description. Multiple files: ` — \`file1.ts:L5\`, \`file2.ts:L20-35\``. This tells subagents exactly where to look, eliminating broad codebase scans.
- **Paths must be real repo paths** — verify each path exists in the repository before writing it. Never invent or guess file paths.
- **Task descriptions must stay under ~200 characters** — keep the description concise; put details in the Research Findings section of the issue body instead.

**Agent values** — use agents defined in `.claude/agents/`:

| Agent | Use for |
|-------|---------|
| `[fastify-backend-developer]` | API routes, services, backend logic |
| `[react-frontend-developer]` | React components, pages, CSS, hooks |
| `[playwright-test-developer]` | **E2E tests only** (when `TEST_E2E_CMD` configured) |
| `[bash-script-craftsman]` | Shell scripts, CI scripts, bash tooling |
| `[cc-orchestration-writer]` | Claude Code orchestration scripts |
| `[research-agent]` | Investigation, codebase exploration |
| `[code-reviewer]` | Post-implementation review tasks |
| `[project-manager-backlog]` | Backlog/issue management tasks |
| `[spec-reviewer]` | Spec validation tasks |
| `[default]` | General tasks: config, unit tests, documentation, mixed |

**Agent name rules:**
- Agent name MUST be wrapped in square brackets inside backticks: `` `[agent-name]` `` — the bracket-less form `` `agent-name` `` is tolerated by the parser but must not be written deliberately.
- NEVER write `[test-engineer]` — it is a legacy alias that no longer maps to a real agent. Use `[playwright-test-developer]` for Playwright E2E tests, or `[default]` for general test/config tasks.
- `[playwright-test-developer]` is ONLY for Playwright E2E test files. For unit tests, config changes, or documentation, use `[default]`.
- NEVER write `[fullstack-engineer]` — it is not a pipeline agent. Split fullstack work into a `[fastify-backend-developer]` task (API/data layer) and a separate `[react-frontend-developer]` task (UI layer).

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
| File path doesn't exist in repo | Subagent wastes a full search cycle; verify paths before writing them |
| Task description over ~200 chars | Truncated in UI and hard to scan; put details in the issue body instead |
| Writing `[test-engineer]` as agent | Legacy alias — write `[playwright-test-developer]` for E2E or `[default]` for general tests |
| Missing square brackets: `` `agent-name` `` instead of `` `[agent-name]` `` | Parser accepts it, but explicit brackets make intent clear — always use brackets |
| Writing `[fullstack-engineer]` as agent | Unknown agent — normalizer silently downgrades to `default`, losing backend and frontend specialization; split into `[fastify-backend-developer]` + `[react-frontend-developer]` instead |
| Skip test discovery when affected files are identified | Implementers won't know which tests to update or extend; new tests may duplicate existing coverage and gaps remain invisible |
