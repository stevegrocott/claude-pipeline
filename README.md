# Claude Pipeline

> Structured Claude Code development workflows, distributed as the **`pipeline-core`** plugin.

The pipeline uses **issues as the single source of truth** for plans and tasks. Rather than generating local plan files during implementation, plans are written to issues during a discovery phase and read back during implementation. Supports GitHub Issues and Jira (via ACLI), with GitHub and GitLab for git hosting.

**Install it as a plugin — see [Quick Start](#quick-start).** The orchestrator, platform scripts, hooks and schemas ship in a versioned bundle; you no longer copy a `.claude/` folder into each project.

> Originally forked from [aaddrick/claude-pipeline](https://github.com/aaddrick/claude-pipeline), which is no longer maintained. This repository has diverged substantially and is developed independently.

## How It Works

### Two-Phase Workflow

Instead of running 4 artifact-generating stages before implementation (setup → research → evaluate → plan), the pipeline uses a two-phase approach:

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

Orchestration runs on **feature branches** in the current working directory rather than git worktrees. Worktrees are used only for **parallel task execution within a batch** — tasks with non-overlapping file sets run in separate worktrees simultaneously and merge back to the feature branch.

## Quick Start

Install `pipeline-core` through Claude Code's plugin system. This repo is public, so no auth or token is needed.

Run these **inside an active Claude Code session**:

```
/plugin marketplace add stevegrocott/claude-pipeline
/plugin install pipeline-core@claude-pipeline
/reload-plugins
```

Then, in your project:

```
/adapting-claude-pipeline
```

The adaptation skill walks you through a brainstorming session about your project and customizes the pipeline for your tech stack, platform configuration, E2E testing, and MCP tool availability.

### What lands where

The plugin supplies the orchestrator, platform scripts, schemas, prompts and hooks. Three things stay **yours**, in your repo, and are never overwritten by an update:

| Path | Purpose |
|---|---|
| `.claude/config/platform.sh` | tracker, git host, test and deploy commands |
| `.claude/config/context.md` | project context given to every stage |
| `.claude/agents/*.md` | your stack's specialist agents |

You do **not** need a `.claude/scripts/` directory — the plugin provides it. If you have one from an earlier vendored install, it is now redundant.

### Verify it resolved to the cache, not a working tree

```bash
command -v pipeline-core-implement
```

The path must be under `~/.claude/plugins/cache/claude-pipeline/pipeline-core/<version>/`.
If it points into a local checkout (e.g. `/Users/you/projects/claude-pipeline/...`),
a directory registration is winning — see below.

### Remove any existing directory registration first

**This step is not optional if you have ever used a local checkout of this repo.**
A marketplace registered as a `directory` source takes precedence, and
`extraKnownMarketplaces` in `.claude/settings.json` will **not** override it — the
github source is silently ignored and you keep running the dev working tree.

Check what is currently registered:

```bash
jq '.["claude-pipeline"].source' ~/.claude/plugins/known_marketplaces.json
```

A directory registration looks like this — note it points straight at a working tree:

```json
{ "source": "directory", "path": "/Users/you/projects/claude-pipeline" }
```

If you see that, remove it and re-add from github:

```
/plugin marketplace remove claude-pipeline
/plugin marketplace add stevegrocott/claude-pipeline
```

### Versions

Releases are tagged (`v0.4.0` and up). `.claude-plugin/marketplace.json` declares the
`version` for the `pipeline-core` entry, asserted against
`plugins/pipeline-core/.claude-plugin/plugin.json` by `tests/marketplace-smoke.bats`,
so the two cannot drift silently.

To take a newer release:

```
/plugin marketplace update claude-pipeline
/plugin install pipeline-core@claude-pipeline
```

### Upgrading from a vendored `.claude/` install

Earlier versions were installed by copying the `.claude/` folder into each project.
If that is where you are:

1. Enable the plugin as in [Quick Start](#quick-start).
2. Keep `.claude/config/` and `.claude/agents/` — they are yours.
3. Delete `.claude/scripts/` — the plugin supplies it, and a stale copy is confusing
   rather than harmful (nothing reads it once the plugin is enabled).
4. If your `.claude/settings.json` registers hooks the plugin now ships
   (`pipeline-status-inject`, `block-gh-issue-create`, `pre-commit-skill-validate`,
   `post-pr-simplify`), drop those registrations or they fire twice.
5. Replace any `Bash(.claude/scripts/...)` permission entries with the
   `Bash(pipeline-core-*:*)` equivalents.

### Developing on the pipeline itself

Installing from the github source ends live-editing: changes in a local checkout no
longer reach consumers until committed, pushed, tagged and re-installed. That is what
makes installs reproducible off one machine, but it is a real change if you have been
developing against a directory registration.

`.claude/scripts/` in *this* repo is the canonical tree; `plugins/pipeline-core/` is
**generated** from it by `./sync.sh bundle` and guarded by
`.claude/scripts/implement-issue-test/test-bundle-parity.bats`. Edit the canonical
tree, regenerate, and commit both.

## What's Inside

Shipped in the `pipeline-core` plugin bundle:

- **23 skills** covering discovery, process discipline, workflow automation, and meta/pipeline maintenance
- **11 platform wrapper scripts** for GitHub/GitLab/Jira abstraction (including format converters)
- **5 hooks** — issue-body validation, pipeline status injection, skill-frontmatter validation, post-PR simplification, scaffold placeholder
- **2 orchestration scripts** for batch issue processing and end-to-end implementation
- **25 JSON schemas** for structured output at each pipeline stage
- **6 decision and validation scripts** (`decide-action.sh`, `decide-retry.sh`, `decide-model-fallback.sh`, `skill-validate.sh`, `skill-golden-lib.sh`, `skill-golden.sh`) bridging bash orchestration and skill-native policy evaluation
- **Quality gates** at every stage: spec compliance, code quality, test validation, acceptance testing

Supplied by your repo, never overwritten:

- **Specialist agents** in `.claude/agents/` (this repo ships 9 as reference templates)
- **Platform config** in `.claude/config/` — tracker, git host, test and deploy commands

Tested by **82 BATS files / 2,403 tests** across the orchestrator, platform wrappers, and consumer-facing marketplace suites.

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
| `triage` | light (haiku) | Classify issue as fast-path (surgical: no quality/test loops) or full (standard pipeline) via triage-classify skill |
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

- **Skill-native triage** — each issue is classified before implementation; fast-path skips quality and test loops for surgical single-file changes
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
| **Process** | brainstorming, TDD, systematic-debugging, writing-plans, dispatching-parallel-agents, test-validation | Enforce discipline and methodology |
| **Workflow** | handle-issues, implement-issue, process-pr, subagent-driven-development, executing-plans, fix-from-review, pr-review, pr-creation, complete-summary | Automate multi-step development workflows |
| **Domain** | bulletproof-frontend, ui-design-fundamentals, write-docblocks, review-ui, playwright-testing | Tech-stack-specific guidance |
| **Reference** | mcp-tools, using-skills | Tool selection and skill discovery |
| **Pipeline Policy** | escalation-policy, retry-policy, model-fallback, triage-classify | Document when to escalate/retry/bail and which model to use next — evaluated by decide-*.sh scripts |
| **Meta** | writing-skills, writing-agents, adapting-claude-pipeline, improvement-loop, create-session-summary, resume-session, pipeline-feedback, pipeline-recovery, pipeline-sync | Maintain and extend the pipeline itself |
| **Utility** | using-git-worktrees | Workspace isolation for feature work |

### Model Configuration

The pipeline uses a three-tier model abstraction (`model-config.sh`) — **pure data** — lookup arrays for tier/model/stage mappings only; no decision branches — that decouples stages from specific model names:

| Tier | Model | Used For |
|------|-------|----------|
| **light** | haiku | Mechanical stages: parse, validate, test, simplify, PR creation, docs, complete |
| **standard** | sonnet | Judgment stages: implement, review, fix, task-review, PR review |
| **advanced** | opus | Deep reasoning: complex implementation (L-complexity tasks), unknown stages |

Task complexity hints (`S`/`M`/`L`) from issue parsing override stage defaults — S and M use sonnet, L uses opus. Light-tier stages always use haiku regardless of complexity.

#### Decision layer

The three decision scripts read from `model-config.sh` and apply policy logic:

| Script | Companion skill |
|--------|----------------|
| `decide-action.sh` | `escalation-policy` |
| `decide-retry.sh` | `retry-policy` |
| `decide-model-fallback.sh` | `model-fallback` |

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

```bash
git clone https://github.com/stevegrocott/claude-spend.git
cd claude-spend && npm start
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

### Skill Frontmatter

All 38 skills carry structured YAML frontmatter that makes their contracts machine-readable:

```yaml
inputs: [issue_number, base_branch]
outputs: [pr_url, branch_name]
side_effects: [github_comments, git_push]
composes: [brainstorming, test-driven-development]
failure_modes: [api_timeout, merge_conflict]
```

A pre-commit hook (`skill-validate.sh`) validates every skill file against this schema before it can be committed, preventing undocumented inputs, outputs, or side effects from entering the pipeline.

## Hooks

- **Session Start** (`hooks/session-start.sh`): Injects `using-skills` into every conversation
- **Post-PR Simplify** (`hooks/post-pr-simplify.sh`): Runs code-simplifier after PR/MR creation (platform-agnostic)
- **RTK Command Rewrite** (`hooks/rtk-rewrite.sh`): PreToolUse hook that rewrites verbose Bash commands through [RTK](https://rtk.sh) (Rust Token Killer) to reduce token consumption. Opt-in via `RTK_ENABLED=1`. Registered as a repo-local hook in `.claude/settings.local.json` (not synced).

### Which hooks ship in the plugin

Migrating a repo to the `pipeline-core` plugin used to silently disable its guardrails, because the plugin's `hooks.json` registered only two hooks. Pipeline-owned hooks now ship in the plugin, generated from `.claude/hooks/` by `./sync.sh bundle` into `plugins/pipeline-core/hooks/scripts/` — the bundled tree is **produced, not hand-edited**.

Bundling is an explicit **allowlist**, not a directory mirror. Both the not-shipped set and the shipped set are named in `sync.sh` (`BUNDLE_HOOKS` / `PROJECT_LOCAL_HOOKS` / `PLUGIN_ONLY_HOOKS`), so a hook added later and forgotten fails a test rather than quietly never reaching consumers.

| Hook | Ships? | Why |
|---|---|---|
| `block-gh-issue-create.sh` | yes | Forces issue creation through `assert_issue_valid` — a core pipeline invariant |
| `pipeline-status-inject.sh` | yes | `UserPromptSubmit`; reads the consumer's own `status.json` |
| `pre-commit-skill-validate.sh` | yes | Validates SKILL.md frontmatter; resolves its validator from the plugin bundle |
| `post-pr-simplify.sh` | yes | Runs code-simplifier after PR creation |
| `scaffold-placeholder.sh` | yes | Plugin-only; no `.claude/hooks/` counterpart |
| `block-destructive-db-commands.sh` | no | Project-local — DB safety; not every consumer has a database |
| `rtk-rewrite.sh` | no | Project-local — routes commands through project-specific tooling |
| `session-start.sh` | no | Project-local session banner |
| `sync-reminder.sh` | no | **Retired** for plugin consumers — it reminds you to sync core pipeline changes upstream, which is meaningless once the plugin *is* the source of those files |

`test-bundle-parity.bats` enforces all of this: bundled hooks must match their canonical counterpart byte for byte, a bundled hook with no canonical counterpart fails, every hook in `.claude/hooks/` must be classified, and `sync.sh`'s allowlists must agree with the guard's.

## Testing

```bash
# Orchestrator tests (35 test files)
cd .claude/scripts/implement-issue-test
./run-tests.sh

# Platform wrapper tests (7 test files, 48 tests)
cd .claude/scripts/platform-test
./run-tests.sh
```

Decision skill tests use a golden-fixture harness (`skill-golden-lib.sh`) with mock Claude to verify escalation-policy, retry-policy, model-fallback, and triage-classify outputs without live API calls.

Test coverage includes: argument parsing, branch verification, comment helpers, constants, deploy verification, environment error detection, metrics export, fuzzy task parsing, helper functions, integration, JSON parsing, model config, pipeline profiles, PR review config, prompt file lists, quality loop, rate limiting, smart test targeting, stage runner, status functions, task batching, timeout escalation, and verdict parsing.

## Philosophy

One principle drives the design:

**Issues are the single source of truth.** Plans, research, and task lists live in issues (GitHub Issues or Jira), not in local files. This prevents drift between what was planned and what the pipeline executes.

Supporting principles:
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

### RTK (Rust Token Killer)

RTK rewrites verbose Bash command output (git, ls, grep, find) at the shell level before it enters the context window, reducing token consumption on read-heavy operations.

**Install:**
```bash
brew install rtk
# or
curl -fsSL https://rtk.sh | sh
```

**Enable:** Add `export RTK_ENABLED=1` to your shell profile, or set it per session. Register the hook in `.claude/settings.local.json` (this file is gitignored — create it if absent):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/rtk-rewrite.sh"
          }
        ]
      }
    ]
  }
}
```

The hook activates automatically once registered.

**Measure gain:** Run `claude-spend` before and after enabling RTK on a typical pipeline run. Token counts on Bash tool calls with git/ls/grep output will decrease proportional to output verbosity.

**Rollback:** `unset RTK_ENABLED` or set `RTK_ENABLED=0`. The hook no-ops immediately — no restart required.

## Context Mode

[Context Mode](https://github.com/mksglu/context-mode) is an opt-in Claude Code plugin
(MCP server + Claude Code plugin) that sandboxes large tool outputs into subprocesses
(~98% reduction on big snapshots), persists session state to SQLite across compaction,
and indexes markdown into an FTS5/BM25 search base. It is licensed under
**ELv2 (Elastic License 2.0)** — free to use, but with restrictions on hosting it as
a service. Review the license before deploying in a SaaS environment.

### Install

Context Mode is managed by Claude Code's plugin system — run these slash commands
**inside an active Claude Code session**:

```
/plugin marketplace add mksglu/context-mode
/plugin install context-mode@context-mode
/reload-plugins
```

Requires Node ≥ 22.5 or Bun. No cloud account or `ctx login` step is needed —
all state is stored locally in SQLite.

After installing, enable in this project:

```bash
export CONTEXT_MODE_ENABLED=1
```

To make this permanent, **do not edit `.claude/config/platform.sh` directly** in consumer repos — `platform.sh` is managed by `sync.sh` and will be overwritten on the next sync. Instead, choose one of:

- **Shell profile** (e.g. `~/.bashrc`, `~/.zshrc`): add `export CONTEXT_MODE_ENABLED=1` and restart your terminal.
- **Gitignored local env file** — create `.claude/env.local` (already in `.gitignore`) and add `export CONTEXT_MODE_ENABLED=1`, then source it from your shell profile: `source /path/to/project/.claude/env.local`. This keeps project-specific env vars in the project directory and out of your global shell config.

> **Upstream repo only:** Editing `.claude/config/platform.sh` is appropriate only in this upstream pipeline repository.

### Verify the integration

After installing, run the smoke-check script:

```bash
.claude/scripts/context-mode-check.sh
```

Or via the Claude Code slash command (if the skill is installed):

```
/context-mode:ctx-doctor
```

The script runs `ctx doctor` and `ctx stats`, then runs the orchestrator BATS parsing-assertion suite to confirm Context Mode does not break output parsing. Exit 0 = everything healthy.

### Hook interactions with the pipeline

Context Mode registers its hooks via the **plugin** (cached under `~/.claude/plugins/cache/context-mode/`), not via `settings.local.json`. Empirically (`/context-mode:ctx-doctor`, v1.0.168) it registers **six** hook scripts: `SessionStart`, `PreToolUse`, `PostToolUse`, `PreCompact`, `UserPromptSubmit`, and `Stop`. The pipeline uses `SessionStart`, `PreToolUse`, `PostToolUse`, and `UserPromptSubmit`:

| Hook event | Pipeline hook | Context Mode hook | Interaction (empirically verified) |
|---|---|---|---|
| `SessionStart` | `hooks/session-start.sh` — injects `using-skills` | session hydration (capture/restore) | No conflict — both fire in registration order; neither consumes the other's output. |
| `PreToolUse / Edit\|Write` | `pre-commit-skill-validate.sh`, path guard `python3 -c ...` | output sandboxing (capture) | No conflict — pipeline hooks gate destructive edits; Context Mode captures/compresses. Different data. |
| `PreToolUse / Bash` | `block-destructive-db-commands.sh`, `block-gh-issue-create.sh` | **advisory** `context_guidance` (suggests `ctx_execute` for output-heavy commands) | No conflict — Context Mode's Bash hook DOES inspect the command but only **adds advisory context** (non-blocking, exit 0); the pipeline's **blocking** guards (exit 2) still fire and win. Both observed firing this session without interference. |
| `UserPromptSubmit` | `pipeline-status-inject.sh` | session-memory injection | No conflict — both append context; additive, not mutually exclusive. |
| `PostToolUse` | `sync-reminder.sh`, `post-pr-simplify.sh` | output capture/index | No conflict — both observe completed tool calls; neither mutates the result. |

**Verdict (empirically validated 2026-06-28, v1.0.168):** Context Mode hooks and pipeline hooks are orthogonal. Context Mode's hooks are **advisory/capture** (they add context or index output, exit 0); the pipeline's are **blocking guards** (exit 2 to reject). Both classes fired together this session with no suppression — `ctx doctor`/`ctx stats` pass via the `context-mode` CLI, and the pipeline's `block-gh-issue-create` guard still blocked correctly while Context Mode's Bash guidance appeared as an advisory tip. If you observe unexpected behaviour after enabling Context Mode, run `.claude/scripts/context-mode-check.sh` to confirm the parsing-assertion checks still pass.

### Rollback

```bash
# 1. Immediately disable token/context compression (no restart required)
export CONTEXT_MODE_ENABLED=0

# 2. Permanently disable — upstream repo only: set in platform.sh
#    Consumer repos: set CONTEXT_MODE_ENABLED=0 in your shell profile
#    or in a gitignored local env file (.claude/env.local) instead
CONTEXT_MODE_ENABLED=0

# 3. Uninstall the plugin (inside a Claude Code session)
#    /plugin uninstall context-mode
#    /reload-plugins

# 4. Optionally purge local SQLite state
ctx purge

# Remove any Context Mode hooks from local settings (if added manually)
# Edit .claude/settings.local.json and delete ctx / Context Mode entries
# under "hooks".  The file is gitignored so edits are local only.
```

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
