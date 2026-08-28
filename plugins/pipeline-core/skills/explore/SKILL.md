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
- Add a complexity hint: `- [ ] \`[agent]\` **(S)** Description` where S=small (~5 min), M=medium (~15 min), L=large (~30 min)

**Split M/L into ordered S sub-tasks — this is enforced, not advice.** Task granularity is the dominant quality lever: completion rate falls sharply with size (S ~90%, M ~67%, L ~63%), and `assert_issue_valid` now **hard-rejects** any `**(M)**`/`**(L)**` task that names more than two distinct file paths (see Task Format Specification). So do the decomposition *before* writing the task list, not after the gate bounces it:

1. **Draft the task, then test it against the S bar:** an S task touches ≤2 files and has a single, verifiable done-criterion. If a task you were about to mark `**(M)**` or `**(L)**` names >2 files, or bundles two independent done-criteria, it is decomposable — split it.
2. **Split by file scope and dependency order**, not by convenience. Each resulting S sub-task gets: (a) its own agent, (b) an explicit per-task done-criterion, (c) a file scope of ≤2 paths. Order them so each depends only on earlier sub-tasks (data/lib layer → callers → presentation → tests).
3. **Only keep a task at `**(M)**`/`**(L)**` when it is genuinely atomic** — the work cannot be divided into independently-verifiable steps *and* it touches ≤2 files (e.g. one dense algorithm in a single file). An atomic M/L naming ≤2 paths passes the gate; a decomposable one naming >2 paths does not.

Example — a single "**(L)** Add auth middleware, wire routes, add tests" naming 3+ files must become ordered S sub-tasks:
```
- [ ] `[fastify-backend-developer]` **(S)** Add token-verify middleware — `src/middleware/auth.ts:L1-40`
- [ ] `[fastify-backend-developer]` **(S)** Apply middleware to protected routes — `src/routes/index.ts:L20-55`
- [ ] `[default]` **(S)** Add middleware unit tests — `tests/unit/auth.test.ts:L1-60`
```
- **Parseable format required:** Every task line in `## Implementation Tasks` MUST begin with `- [ ] \`[agent-name]\``. Prose lines such as "Task 1: Do something" are **not parsed as tasks**. As of the hardened parser (issue #584) this failure is **loud, not silent**: if the section yields zero parseable tasks the run aborts with a per-line rejection report (`lint_task_lines`) naming each rejected line and its cause — `format` (matches no task pattern), `agent-unresolved` (agent name resolves to neither a known agent nor `default`), or `path-unresolved` (a backtick-quoted path neither exists nor has an existing parent). Do not rely on the parser to skip a mis-formatted line — it will now bounce the whole run.
- Frontend and backend changes in the same task should be split — backend first (data layer), then frontend (presentation)
- **Never author a standalone bundle-regen task.** Tasks run in isolated git worktrees, and the scheduler batches tasks whose file sets don't overlap into the same parallel batch. A task that only runs `./sync.sh bundle` declares `sync.sh` + `plugins/pipeline-core/scripts/`, disjoint from any `.claude/scripts/**` edits it's meant to follow — so it lands in the same batch, in a worktree that can't see those edits, and regenerates the bundle from stale sources. If the plan edits `.claude/scripts/**`, fold `./sync.sh bundle` into the **last** task that edits those scripts instead of giving it its own task.
- **E2E tests (REQUIRED for UI changes):** If `TEST_E2E_CMD` is configured in `.claude/config/platform.sh`, include an E2E task for ANY issue touching user-visible UI — CSS, components, layouts, forms, navigation, visual regressions. This is NOT optional for UI work.
  `- [ ] \`[playwright-test-developer]\` **(S)** Write Playwright E2E test for [flow description]`
  E2E tasks reference the `playwright-testing` skill and come after all implementation tasks so the feature exists before the test runs.
  **When to include:** Changes to components, pages, hooks, CSS, layouts, forms, navigation, or any file matching `FRONTEND_PATH_PATTERNS`.
  **When to skip:** Backend-only changes, config changes, documentation, CI/CD scripts.
  **Task descriptions must specify:** The page/component under test, the user action to perform, and the expected visual/behavioral outcome.
- Include acceptance criteria for the overall issue

### Step 5: Create Issue

**Before creating the issue, ask the user which epic to parent it under** using `AskUserQuestion`. Look up open epics in the project to offer relevant options. For Precis/KIKS, all issues must sit under KIKS-410 (the Precis initiative) within an appropriate epic. Present the most likely epics as options based on the research context (e.g., if the work is UI-related, suggest "KIKS-546 UI Enhancements").

**Deploy Verification section (scope-dependent):** Before deciding whether to include a `## Deploy Verification` section, read `.claude/config/platform.sh` and check `DEPLOY_VERIFY_CMD` and `FRONTEND_PATH_PATTERNS`:

- **`DEPLOY_VERIFY_CMD` is empty or unset:** **Omit the section entirely.** The orchestrator skips the deploy-verify stage when no command is configured — do not add the section even if files changed.
- **`DEPLOY_VERIFY_CMD` is set and all changed files match `FRONTEND_PATH_PATTERNS`:** Include the section; use `$DEPLOY_VERIFY_CMD --health-only` as the Verification command. Frontend-only changes do not require a full redeploy.
- **`DEPLOY_VERIFY_CMD` is set and any changed file does not match `FRONTEND_PATH_PATTERNS`:** Include the section; use `$DEPLOY_VERIFY_CMD` (no flag) as the Verification command. Backend or shared changes require a full redeploy.

The `## Deploy Verification` section body **must** include a `**Verification command:**` line (the orchestrator's body-scan gate requires it):

```
## Deploy Verification

**Verification command:** <DEPLOY_VERIFY_CMD or DEPLOY_VERIFY_CMD --health-only>

<optional notes about what the deploy does>
```

Create the issue using the platform wrapper with `--parent` set to the chosen epic:

```bash
PLATFORM_DIR="$(pipeline-core-platform-dir 2>/dev/null || echo .claude/scripts/platform)"
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

**Target environment:** [staging|test|nas|production]

**Health endpoint:** [full URL to health check endpoint, e.g., https://test-beegeefarm.grocott.com.au/health]

**Verification command:** [bash scripts/deploy-nas-from-local.sh or bash scripts/deploy-nas-from-local.sh --health-only]

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
- **Paths must be real repo paths, written repo-relative from the repo root** — verify each path exists in the repository before writing it. Never invent or guess file paths, and never write a bare basename like `` `model-config.sh` `` — use the full path (`` `.claude/scripts/model-config.sh` ``). `assert_issue_valid` treats every backtick-quoted token as a file path and rejects bare basenames as unresolved.
- **Task descriptions must stay under ~120 characters** — matches the orchestrator's `TASK_DESC_PROMOTE_CHARS` default (`.claude/scripts/implement-issue-orchestrator.sh`); keep the description concise and put details in the Research Findings section of the issue body instead.

**Parser hardening (issue #584) — the section extractor is tolerant, the failure mode is loud:** the two mirrored parsers (`_parse_task_lines` in the orchestrator and `_issue_body_parse_tasks` in `issue-body-lib.sh`) stay behaviourally identical and both now:
- **Match the heading case-insensitively** — `## Implementation Tasks`, `## implementation tasks`, `### IMPLEMENTATION TASKS`, etc. all resolve the same section.
- **Tolerate CRLF line endings** — carriage returns are stripped before matching, so a Windows/`gh`-sourced body parses identically to an LF body (no `\r` leaks into descriptions or defeats the anchored regexes).
- **Fail loudly on a 0-task section** — when the section yields no parseable tasks the PARSE ISSUE stage runs `lint_task_lines` and prints a **per-line rejection report** before aborting, tagging each rejected line with its cause (`format` / `agent-unresolved` / `path-unresolved`). There is no silent-skip path: a mis-formatted task list stops the run with an actionable reason instead of proceeding with an empty set.

**Granularity is enforced by `assert_issue_valid` (not advisory):** the shared validator every created issue passes through (`.claude/scripts/issue-body-lib.sh`) now applies a hard granularity criterion in addition to the structural checks:
- **HARD error — issue is rejected:** any `**(M)**` or `**(L)**` task whose files-suffix names **more than two distinct file paths** (line-range suffixes like `:L10-40` are ignored, so `file.ts:L10` and `file.ts:L90` count as one path). A hint-less task is treated as `**(M)**`. Split such a task into ordered S sub-tasks (see Step 4) before creating the issue.
- **WARNING — non-failing:** whenever the body contains any non-S task, the validator prints the M/L-vs-S count to stderr. This is a nudge to keep decomposing toward S; it does not block issue creation, but treat a large M/L count as a sign the plan is under-decomposed.

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
- **Split M/L tasks into multiple S tasks** when the work is decomposable into independent steps. **This is now enforced:** `assert_issue_valid` hard-rejects a decomposable M/L task (M/L hint AND >2 distinct file paths) and warns on the overall non-S mix — see the Task Format Specification. Decompose at explore time; do not rely on the gate to catch it.
- **Every task MUST include at least one file path, written repo-relative from the repo root. This is now ENFORCED, not advised:** `assert_issue_valid` (`.claude/scripts/issue-body-lib.sh`) hard-rejects any OPEN task whose description yields zero file paths (the diagnostic names the offending task), so an issue with a path-less task is bounced before creation. A bare basename like `` `model-config.sh` `` also fails as unresolved — write the full path (`` `.claude/scripts/model-config.sh` ``). Line-range suffixes count (`file.ts:L10-40` satisfies the rule) and directory-only paths count (`.claude/scripts/`); already-completed `[x]` tasks are exempt. Tasks without file paths otherwise cause subagents to scan broadly — the #1 token waste in the pipeline.
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
| Task has no file paths | **Rejected by `assert_issue_valid`** — an OPEN task with zero file paths fails validation before the issue is created (subagents would otherwise read 13+ files to orient). Include at least 1 file path per task |
| File path doesn't exist in repo | Subagent wastes a full search cycle; verify paths before writing them |
| File path is a bare basename, not repo-relative | **Rejected by `assert_issue_valid`** as an unresolved path; write the full path from the repo root instead of just the filename |
| Task description over ~120 chars | Orchestrator promotes it to the larger turn budget (`TASK_DESC_PROMOTE_CHARS`); put details in the issue body instead |
| Writing `[test-engineer]` as agent | Legacy alias — write `[playwright-test-developer]` for E2E or `[default]` for general tests |
| Missing square brackets: `` `agent-name` `` instead of `` `[agent-name]` `` | Parser accepts it, but explicit brackets make intent clear — always use brackets |
| Writing `[fullstack-engineer]` as agent | Unknown agent — normalizer silently downgrades to `default`, losing backend and frontend specialization; split into `[fastify-backend-developer]` + `[react-frontend-developer]` instead |
| Skip test discovery when affected files are identified | Implementers won't know which tests to update or extend; new tests may duplicate existing coverage and gaps remain invisible |
| Standalone `./sync.sh bundle` / bundle-regen task | Worktree isolation — the scheduler batches it alongside the disjoint `.claude/scripts/**` edits it must follow, so it runs in a worktree that can't see them and regenerates from stale sources. Fold it into the last script-editing task instead |
