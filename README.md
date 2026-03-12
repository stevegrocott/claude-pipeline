# Claude Pipeline

> Forked from [aaddrick/claude-pipeline](https://github.com/aaddrick/claude-pipeline) — a portable `.claude/` folder for structured Claude Code development workflows.

This fork modifies the pipeline to use **issues as the single source of truth** for plans and tasks. Instead of generating local plan files during implementation, plans are written to issues during a discovery phase and read back during implementation. Supports GitHub Issues and Jira (via ACLI), with GitHub and GitLab for git hosting.

## Changes from Upstream

### Two-Phase Workflow

The original pipeline runs 4 stages before implementation (setup → research → evaluate → plan) that generate local artifacts. This fork replaces that with a two-phase approach:

**Phase 1: Discovery (`/explore`)**
```
/explore "vague idea or bug observation"
```
Chains: understand → research codebase → evaluate approaches → plan → create issue

The issue body contains the full plan with a **parseable task list**:
```markdown
## Implementation Tasks
- [ ] `[backend-developer]` **(S)** Add migration for new column. Scope: 1 file. Done when: migration runs.
  - **Affected files:** `db/migrations/001_add_column.sql`
- [ ] `[backend-developer]` **(M)** Update service with new logic. Scope: 2 files. Done when: unit tests pass.
  - **Affected files:** `src/services/user.ts`, `src/services/user.test.ts`
- [ ] `[frontend-developer]` **(S)** Add UI component. Scope: 2 files. Done when: component renders.
  - **Affected files:** `src/components/Widget.tsx`, `src/components/Widget.test.tsx`
- [ ] `[playwright-test-developer]` **(S)** Write E2E test for widget flow. Scope: 1 file. Done when: test passes.
  - **Affected files:** `e2e/tests/widget.spec.ts`
```

**Phase 2: Implementation (`/implement-issue`)**
```
/implement-issue 42 main
```
Reads the issue body → extracts tasks → implements → tests → reviews → creates PR/MR.

### Feature Branches (No Worktrees for Orchestration)

The upstream pipeline uses git worktrees for isolation. This fork uses **feature branches** in the current working directory for orchestration, which is simpler. Git worktrees are optionally used for **parallel task execution within a batch** — tasks with non-overlapping file sets run in separate worktrees simultaneously and merge back to the feature branch.

## Quick Start

```bash
# 1. Copy the .claude folder into your project
git clone https://github.com/stevegrocott/claude-pipeline.git .claude-pipeline-source
cp -r .claude-pipeline-source/.claude .claude
rm -rf .claude-pipeline-source

# 2. Start Claude Code in your project
claude

# 3. Run the adaptation skill to customize for your codebase
> /adapting-claude-pipeline
```

The adaptation skill walks you through a brainstorming session about your project and customizes the pipeline for your tech stack, platform configuration, E2E testing, and MCP tool availability.

## Syncing Upstream Changes

Stack-specific files (agents, some skills, prompts) ship as **generic templates** in this repo. When you run `/adapting-claude-pipeline`, your customized versions are stored in `.claude/local/` (gitignored) and applied over the defaults.

This means upstream pulls update the generic templates without touching your customizations. After pulling, re-apply your local overrides:

```bash
# Pull upstream pipeline changes
git fetch pipeline main
git format-patch pipeline/main --stdout | git apply --check  # dry run
git format-patch pipeline/main --stdout | git apply           # apply

# Re-apply your local customizations on top
.claude/scripts/apply-local.sh

# Optional: review what upstream changed in templates
git diff HEAD~1 -- .claude/agents/ .claude/skills/ .claude/config/
```

**First time?** Run `/adapting-claude-pipeline` to create your `.claude/local/` customizations.

**New upstream templates?** If upstream adds new stack-specific files, copy them to `.claude/local/` and customize — `apply-local.sh` will keep them applied.

## What's Inside

- **26 skills** covering discovery, process discipline, workflow automation, domain guidance, and meta/pipeline maintenance
- **8 specialized agents** (backend/frontend developers, reviewers, validators, Playwright test developer, orchestration writer)
- **12 platform wrapper scripts** for GitHub/GitLab/Jira abstraction (including format converters)
- **2 hooks** for session initialization and post-PR simplification
- **2 orchestration scripts** for batch issue processing and end-to-end implementation
- **13 JSON schemas** for structured output at each pipeline stage
- **30 BATS test files** across orchestrator and platform wrapper test suites
- **Quality gates** at every stage: spec compliance, code quality, test validation, acceptance testing

## Architecture

### Two-Phase Workflow

```
Phase 1: Discovery
  /explore "idea"
    → understand → research → evaluate → plan
    → create issue (with structured plan)

Phase 2: Implementation
  /implement-issue N main
    → parse_issue → validate_plan → implement → quality_loop
    → test_loop → e2e_verify → acceptance_test → deploy_verify
    → docs → pr → pr_review → complete
```

### Orchestrator Pipeline Stages

The `implement-issue-orchestrator.sh` (~5,000 lines) runs 11 stages per issue:

| Stage | Model Tier | Description |
|-------|-----------|-------------|
| `parse_issue` | light (haiku) | Fetch issue body, extract tasks via fuzzy parser, compute batch assignments |
| `validate_plan` | light (haiku) | Verify agent names exist, check file paths, warn on oversized tasks |
| `implement` | standard (sonnet) | Execute tasks in dependency-aware batches (serial or parallel via worktrees) |
| `quality_loop` | mixed | Iterative simplify → review → fix cycle (up to 3 iterations) |
| `test_loop` | mixed | Smart test targeting with convergence detection (stops on repeated failures) |
| `e2e_verify` | light (haiku) | Run E2E tests when `TEST_E2E_CMD` configured |
| `acceptance_test` | light (haiku) | Validate against issue acceptance criteria |
| `deploy_verify` | light (haiku) | Optional: health check + custom verification against deployed environment |
| `docs` | light (haiku) | Auto-generate/update documentation if warranted |
| `pr` | light (haiku) | Create PR/MR with structured description |
| `pr_review` | standard (sonnet) | Iterative PR review cycle (up to 2 iterations) |

### Orchestration Hierarchy

```
handle-issues (skill) → batch-orchestrator.sh
                             |
                   implement-issue-orchestrator.sh (per issue)
                      parse → validate → implement → quality → test
                      → e2e → acceptance → deploy → docs → pr → review
                             |
                   process-pr (skill)
                      merge + follow-ups  OR  re-run implementation
```

### Key Orchestrator Features

- **Fuzzy task parsing** — handles missing backticks, asterisk bullets, leading whitespace, and missing square brackets with warnings
- **Task batching** — tasks with non-overlapping file sets are grouped into parallel batches; tasks sharing files run sequentially
- **Worktree parallelism** — parallel batches execute in isolated git worktrees and merge back
- **Pipeline profiles** — classifies issues as minimal/standard/full based on task count and complexity (see table below)
- **Smart test targeting** — runs only tests related to changed files; detects convergence (repeated identical failures) and breaks loops
- **Model escalation** — each stage has a fallback model one tier up (haiku→sonnet→opus) for resilience; double-timeout triggers automatic escalation
- **Metrics export** — tracks quality iterations, test iterations, PR review iterations, and escalations; feeds into [claude-spend](#spend-analysis-with-claude-spend)
- **Binary file sanitization** — scans commits for accidentally staged binary/data files and removes them before pushing
- **Resume support** — can resume from any stage after interruption

### Pipeline Profiles

The orchestrator classifies each run into a profile based on task complexity, then adjusts iteration limits accordingly:

| Profile | Trigger | Quality Loop | Test Loop | PR Review |
|---------|---------|-------------|-----------|-----------|
| **minimal** | Single S-task or diff < 20 lines | capped | 2 iterations max | 1 iteration |
| **standard** | Multiple S-tasks, diff ≥ 20 lines | default | default | default |
| **full** | Any M or L task present | up to 5 iterations | up to 7 iterations | up to 2 iterations |

### Skill Categories

| Category | Skills | Purpose |
|----------|--------|---------|
| **Discovery** | explore, investigating-codebase-for-user-stories | Turn ideas into fully-planned issues |
| **Process** | brainstorming, TDD, systematic-debugging, writing-plans, dispatching-parallel-agents | Enforce discipline and methodology |
| **Workflow** | handle-issues, implement-issue, process-pr, subagent-driven-development, executing-plans | Automate multi-step development workflows |
| **Domain** | bulletproof-frontend, ui-design-fundamentals, write-docblocks, review-ui, playwright-testing | Tech-stack-specific guidance |
| **Reference** | mcp-tools, using-skills | Tool selection and skill discovery |
| **Meta** | writing-skills, writing-agents, adapting-claude-pipeline, improvement-loop, create-session-summary, resume-session | Maintain and extend the pipeline itself |
| **Utility** | using-git-worktrees | Workspace isolation for feature work |

### Model Configuration

The pipeline uses a three-tier model abstraction (`model-config.sh`) that decouples stages from specific model names:

| Tier | Model | Used For |
|------|-------|----------|
| **light** | haiku | Mechanical stages: parse, validate, test, simplify, PR creation, docs, complete |
| **standard** | sonnet | Judgment stages: implement, review, fix, task-review, PR review |
| **advanced** | opus | Deep reasoning: complex implementation (L-complexity tasks), unknown stages |

Task complexity hints (`S`/`M`/`L`) from issue parsing override stage defaults — S and M use sonnet, L uses opus. Light-tier stages always use haiku regardless of complexity.

## Orchestrator Features

### Timeout Escalation

When a stage times out twice at the same model tier, the orchestrator automatically escalates to the next model up (e.g. Haiku → Sonnet → Opus). This prevents stuck stages from blocking the pipeline while keeping costs low for stages that complete normally.

### Fuzzy Task Parsing

The task parser handles common malformations in issue bodies:

```markdown
# All of these parse correctly:
- [ ] `[backend-developer]` Canonical format
- [ ] [backend-developer] Missing backticks
* [ ] `[backend-developer]` Asterisk bullet
  - [ ] `[backend-developer]` Leading whitespace
- [ ] `backend-developer` Missing square brackets
```

Tasks without a complexity hint default to **M** (medium).

### Binary File Sanitization

After each task implementation, the orchestrator scans commits for accidentally staged binary and data files (images, archives, database files, lock files) and removes them before pushing. Prevents bloating the repository with unintended artifacts.

### Metrics Export

At orchestrator completion, `metrics.json` is emitted to the log directory with structured data about the run: stage timings, model usage, escalations, iteration counts, and final status. This is the data that [claude-spend](#spend-analysis-with-claude-spend) parses for its pipeline analytics.

### Parallel E2E & Acceptance Testing

The `e2e-verify` and `acceptance-test` stages run concurrently using bash background jobs. Both must pass, but running them in parallel reduces wall-clock time.

### Per-Stage Timeouts

Each stage type has a tuned timeout instead of a flat default:

| Stage | Timeout |
|-------|---------|
| implement, fix | 30 min |
| pr-review | 30 min |
| task-review | 15 min |
| test-iter | 15 min |
| deploy-verify, fix-e2e | 15 min |
| e2e-verify | 10 min |
| test, docs, pr | 10 min |

## Spend Analysis with claude-spend

[claude-spend](https://github.com/stevegrocott/claude-spend) is a companion dashboard that visualises your Claude Code token usage. When used alongside claude-pipeline, it parses orchestrator logs to surface pipeline-specific analytics that go beyond basic token counting.

```
npx claude-spend
```

### How they work together

claude-pipeline writes structured logs to `logs/implement-issue/<timestamp>/` during each run. claude-spend scans these log directories and correlates them with Claude Code session data to produce pipeline-aware analytics.

### Pipeline Stage Performance
![Pipeline stage durations and speed insights](docs/screenshots/pipeline-speed-stages.png)

**What claude-spend shows from pipeline data:**
- **Stage duration time-series** — track how implement, pr_review, and pr stage times trend over days
- **Pipeline stage performance** — average duration per stage as a horizontal bar chart, instantly showing your bottleneck
- **Speed insights** — ranked picks like "implement stage averages 12 minutes — slowest pipeline stage"

### Quality & Run Outcomes
![Quality metrics, run outcomes, and churners](docs/screenshots/pipeline-quality-outcomes.png)

**What claude-spend shows from pipeline data:**
- **Completion % per day** — daily trend of successful vs failed runs
- **Avg quality iterations** — how many review loops each run needs (ideal is 1-2)
- **Avg test iterations** — how many test-fix cycles before tests pass
- **Run outcomes** — breakdown of error / completed / max_iterations / running states
- **Top churners** — which issues cause the most quality and test rework, with links

### Pipeline Insights
![Pipeline-specific actionable insights](docs/screenshots/pipeline-insights.png)

**Actionable insights derived from pipeline logs:**
- Quality loop churn detection (averaging N iterations per run)
- Completion rate warnings (only X% of runs complete successfully)
- Error rate tracking (Y% of runs end in error state)
- Stage bottleneck identification (slowest stage by average duration)
- Model escalation analysis (unnecessary Opus usage on simple tasks)
- One-click GitHub issue creation from any insight

Without claude-pipeline logs, these sections are empty — claude-spend's standalone features (token usage, model breakdown, session analysis) still work with any Claude Code installation.

## Platform Configuration

The pipeline is platform-agnostic. All issue tracker and git host interactions go through wrapper scripts in `.claude/scripts/platform/` that dispatch to the correct CLI based on `.claude/config/platform.sh`.

**Supported platforms:**

| | GitHub | GitLab | Jira |
|---|---|---|---|
| **Git hosting** | `gh` CLI | `glab` CLI | — |
| **Issue tracking** | `gh` CLI | `glab` CLI | `acli` (Atlassian CLI) |

**Platform wrapper scripts:**

| Script | Purpose |
|--------|---------|
| `create-issue.sh` | Create issue/ticket, returns ID/key |
| `read-issue.sh` | Read issue as normalised JSON `{title, body, status}` |
| `comment-issue.sh` | Add comment to issue |
| `transition-issue.sh` | Close (GitHub) or transition (Jira) |
| `list-issues.sh` | List issues as JSON array, supports `--jql` for Jira |
| `create-mr.sh` | Create PR/MR, returns number |
| `read-mr-comments.sh` | Read PR/MR comments as JSON array |
| `comment-mr.sh` | Add comment to PR/MR |
| `merge-mr.sh` | Merge with configured strategy (squash/merge/rebase) |
| `find-mr.sh` | Find open PR/MR by branch name |
| `markdown-to-wiki.py` | Convert Markdown to Jira wiki format |
| `adf-to-markdown.py` | Convert Atlassian Document Format to Markdown |

**Configuration:** Run `/adapting-claude-pipeline` to set your platform during brainstorming, or edit `.claude/config/platform.sh` directly:

```bash
TRACKER="jira"           # github | jira
TRACKER_CLI="acli"       # gh | acli
GIT_HOST="github"        # github | gitlab
GIT_CLI="gh"             # gh | glab
JIRA_PROJECT="PROJ"      # Jira project key
MERGE_STYLE="squash"     # squash | merge | rebase
```

**Jira users:** Install [ACLI](https://bobswift.atlassian.net/wiki/spaces/ACLI) and configure authentication before using the pipeline.

## E2E Testing

The pipeline includes a Playwright E2E testing skill and agent for browser-based testing.

- **`playwright-testing` skill** — POM conventions, selector strategy, waiting patterns, anti-patterns
- **`playwright-test-developer` agent** — Senior QA specialist that writes E2E tests following the skill's conventions
- **`/explore`** automatically generates E2E test tasks when `TEST_E2E_CMD` is configured in `platform.sh`

The orchestrator runs unit tests first, then E2E and acceptance tests in parallel (fail fast):

```bash
# In platform.sh
TEST_UNIT_CMD="npm test"
TEST_E2E_CMD="npx playwright test"
TEST_E2E_BASE_URL="http://localhost:3000"
```

## MCP Tools

The pipeline optionally integrates with MCP servers for enhanced code exploration and documentation lookup.

- **Context7** — Framework/library API documentation. Used by `/explore` and `/writing-agents` before falling back to web search.
- **Serena** — Structured code navigation (class hierarchies, method signatures, call graphs).
- **`mcp-tools` skill** — Decision matrix for choosing the right exploration tool.

MCP tools are optional. When unavailable, the pipeline falls back to Grep/Glob and web search. Remove the `mcp-tools` skill during `/adapting-claude-pipeline` if not using MCP servers.

## Usage

### Discovery → Implementation Flow

```bash
# Phase 1: Discover and plan
> /explore "users can't reset their password from the settings page"
# Creates issue #42 with full plan

# Phase 2: Implement
> /implement-issue 42 main
# Reads plan from issue, implements, creates PR/MR
```

### Batch Processing

```bash
> /handle-issues "open issues assigned to me, priority order"
```

Issues are processed sequentially on feature branches. Each issue goes through the full implementation pipeline.

### Day-to-Day Skills

```
/brainstorming          # Before any creative work
/systematic-debugging   # When you hit a bug
/writing-plans          # Create an implementation plan
/create-session-summary # Save context before /clear
/resume-session         # Resume from a saved summary
```

## Task Format Specification

The orchestrator parses tasks from issue bodies using this convention:

```markdown
- [ ] `[agent-name]` **(M)** Task description. Scope: 2 files. Done when: [criterion].
  - **Affected files:** `path/to/file.ts`, `path/to/other.ts`
```

**Required fields:**
- **Agent name** in backtick-wrapped square brackets — routes to the correct `.claude/agents/*.md`
- **Complexity hint** `(S)`, `(M)`, or `(L)` — controls model tier selection
- **Scope constraint** `Scope: N files` — hard limit on files the agent should modify
- **Done condition** `Done when: [criterion]` — explicit stopping condition
- **Affected files** — exact file paths to read/modify, prevents broad exploration

**Parsing:** The fuzzy parser handles common formatting variations (missing backticks, asterisk bullets, extra whitespace) and emits warnings on stderr. Tasks without a complexity hint default to M.

**Agent values** should match your `.claude/agents/` directory. The adaptation skill sets these up for your tech stack.

## Extending the Pipeline

Create new skills:
```
> /writing-skills
```

Create new agents:
```
> /writing-agents
```

After resolving a bug or observing a recurring problem:
```
> /improvement-loop
```

## Hooks

- **Session Start** (`hooks/session-start.sh`): Injects `using-skills` into every conversation
- **Post-PR Simplify** (`hooks/post-pr-simplify.sh`): Runs code-simplifier after PR/MR creation (platform-agnostic)

## Testing

```bash
# Orchestrator tests (23 test files, ~930 tests)
cd .claude/scripts/implement-issue-test
./run-tests.sh

# Platform wrapper tests (7 test files, 48 tests)
cd .claude/scripts/platform-test
./run-tests.sh
```

Test coverage includes: argument parsing, branch verification, comment helpers, constants, deploy verification, environment error detection, metrics export, fuzzy task parsing, helper functions, integration, JSON parsing, model config, pipeline profiles, PR review config, prompt file lists, quality loop, rate limiting, smart test targeting, stage runner, status functions, task batching, timeout escalation, and verdict parsing.

## Philosophy

This fork preserves the upstream's core philosophy while adding one key principle:

**Issues are the single source of truth.** Plans, research, and task lists live in issues (GitHub Issues or Jira), not in local files. This prevents drift between what was planned and what the pipeline executes.

Other preserved principles:
- **Skills are TDD for process documentation** — tested with subagents before deployment
- **Agents should be specialized, not general** — each has clear scope boundaries
- **Fix first, improve later** — pipeline changes happen after understanding the problem
- **Quality gates over trust** — every implementation goes through multiple reviews
- **Delete aggressively** — remove what you don't need

## Token Efficiency

Over 99% of token usage is Claude **reading** context, not writing. These practices reduce consumption significantly.

### Conversation Hygiene

- **One conversation per task.** Long conversations compound cost — message #80 costs 2x more than message #5 because the entire history is re-read each turn.
- **Be specific.** "Fix the bug in `src/auth.js` line 42" triggers far fewer tool calls than "fix the login bug". Specificity reduces exploratory reading.
- **Start fresh when switching topics.** Paste a short summary in your first message instead of carrying forward hundreds of messages.
- **Truncate build output.** Use `| tail -10` when running builds or test suites. Full build logs in context are re-read on every subsequent tool call.

### Model Selection

- **Use `/model` to switch tiers.** Haiku handles simple tasks (run tests, format code, quick questions) at a fraction of Opus cost.
- **The pipeline auto-selects models** via `model-config.sh`: haiku for mechanical stages (parse, test, simplify, PR creation), sonnet for implementation and reviews, opus for complex L-sized tasks.
- **S/M-complexity tasks use sonnet.** L-complexity tasks escalate to opus.
- **Model escalation** provides resilience — each stage has a fallback model one tier up. Double-timeout triggers automatic escalation.

### CLAUDE.md Size

Your CLAUDE.md is re-read on every message in every conversation. Each line compounds across the entire session.

- Keep it under 30-40 lines. Move rarely-needed sections to separate files.
- The `/adapting-claude-pipeline` skill includes a lean CLAUDE.md template.
- Remove technology checklists from agent definitions — put them in stage-specific prompts loaded only when needed.

### Pipeline-Specific

- **Agent definitions are loaded globally.** Keep `.claude/agents/*.md` files focused on role identity (under 40 lines). Technology checklists belong in `.claude/prompts/` — loaded once per stage, not every invocation.
- **Light-tier stages cap at 5 turns** via `--max-turns` to prevent open-ended exploration.
- **Parallel subagents** reduce wall-clock time and prevent context accumulation in a single session.
- **Scope constraints in task descriptions** (`Scope: N files`, `Done when:`, `Affected files:`) prevent agents from over-exploring and bloating context.
- **Pipeline profiles** automatically adjust iteration limits based on task complexity — minimal runs skip unnecessary review cycles.

## License

MIT — see [LICENSE](LICENSE)

## Credits

- Original pipeline: [aaddrick/claude-pipeline](https://github.com/aaddrick/claude-pipeline)
- Skills adapted from: [obra/superpowers](https://github.com/obra/superpowers)
- Spend dashboard: [claude-spend](https://github.com/stevegrocott/claude-spend)
- Fork maintained by: [stevegrocott](https://github.com/stevegrocott)
