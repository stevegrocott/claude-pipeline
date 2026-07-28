# Pipeline File Classification

## Core Files (synced across all projects)

These files are the orchestration engine. Changes to them should flow back to claude-pipeline and out to all projects via `sync.sh`.

### Always synced
| Path | Purpose |
|------|---------|
| `hooks/session-start.sh` | Session initialization |
| `hooks/post-pr-simplify.sh` | Post-PR code review trigger |

`settings.json` is merged, not copied: `sync.sh to` calls `register_detect_hook()`,
which adds only the `detect-core-edit.sh` entry and leaves the consumer's
permissions, env and project hooks alone.

### Delivered by the plugin, NOT synced (issue #632)

`.claude/scripts/**` is the pipeline's own dogfood tree and is never copied into
a consumer. Consumers install the same scripts as part of the `pipeline-core`
plugin and reach them through `bin/pipeline-core-*` and `pipeline-core-platform-dir`.

| Path | Where a consumer gets it |
|------|--------------------------|
| `scripts/implement-issue-orchestrator.sh` | `pipeline-core-implement` |
| `scripts/batch-orchestrator.sh`, `scripts/batch-runner.sh` | `pipeline-core-batch` |
| `scripts/create-followup-issue.sh` | `pipeline-core-create-followup-issue` |
| `scripts/platform/*.sh`, `scripts/platform/*.py` | `"$(pipeline-core-platform-dir)"/…` |
| `scripts/schemas/*.json`, `scripts/prompts/*` | read from the plugin bundle |
| `scripts/implement-issue-test/`, `scripts/platform-test/` | not shipped — they test THIS repo's copies |

Syncing these left 132 orphaned files in `stevegrocott/beegee-farm-3`, 53 of them
`.bats` suites pointed at orchestrators the plugin migration had removed. The
`platform/` copy could not be repaired by re-syncing either — upstream's version
needs `../resolve-pipeline-root.sh`, which the migration deletes. `sync.sh`'s
`assert_no_plugin_shadow()` now fails the sync, naming each offending path, if
the scope ever widens back over the bundle.

### Universal skills (synced)
Process-focused, stack-agnostic skills. See `UNIVERSAL_SKILLS` array in `sync.sh` for the definitive list.

Key ones: brainstorming, explore, implement-issue, handle-issues, systematic-debugging, test-driven-development, writing-plans, writing-skills, pipeline-sync.

## Adapted Files (never synced, project-specific)

These files are rewritten during `/adapting-claude-pipeline` for each project's tech stack.

| Path | Why project-specific |
|------|---------------------|
| `agents/*.md` | Rewritten for project stack (e.g., totara-php-developer vs fastify-backend-developer) |
| `config/platform.sh` | Project's tracker (GitHub/Jira), git host, test commands, base URLs — SEEDED once if the consumer has none, then never overwritten |
| `config/context.md` | Project context — seeded once, then never overwritten |
| `prompts/*.md` | Project-specific review checklists |
| Project-only skills | Skills created for a specific project (e.g., playwright-verification, server-health-check) |

## How to Decide

When you edit a `.claude/` file, ask:

1. **Would this change benefit other projects?** → Core file, sync it
2. **Is this specific to this project's stack or domain?** → Adapted file, don't sync
3. **Is this a bug fix in a script?** → Almost always core, sync it
4. **Is this a new skill?** → Usually project-specific unless it's process-focused

## Adding a New Universal Skill

1. Create the skill in any project
2. Add its name to `UNIVERSAL_SKILLS` in `sync.sh`
3. `./sync.sh from <project>` to pull it to claude-pipeline
4. Commit and PR upstream
