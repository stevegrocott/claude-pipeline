---
name: pipeline-sync
description: Sync core pipeline files between claude-pipeline and project repos. Use when the user says "sync pipeline", "upstream this fix", "pull latest pipeline", "push to upstream", or when they've fixed a bug in a project's .claude/hooks/ or a universal skill that should be shared. Also use after editing .claude/scripts/ in the pipeline repo, where the fix belongs in the canonical tree and `./sync.sh bundle` regenerates the plugin bundle rather than any file being copied to a consumer. Includes a PostToolUse hook that auto-detects core file edits.
inputs:
  - name: direction
    type: string
    required: true
    description: Sync direction — "to" pushes core files from claude-pipeline into the project, "from" pulls a fix from the project back to claude-pipeline, "diff" shows what differs without modifying anything
  - name: project_path
    type: file_path
    required: true
    description: Absolute path to the project repository to sync with (e.g. ~/Projects/my-project)
outputs:
  - name: diff_output
    type: string
    description: List of files that differ between the pipeline and the project (always produced; non-empty only when files diverge)
side_effects:
  - may_modify_project_files: syncs core hooks and universal skills into the project when direction is "to" (never .claude/scripts/ — consumers get those from the pipeline-core plugin)
  - may_modify_pipeline_files: pulls changed core files into the claude-pipeline repo when direction is "from"
  - may_create_git_commits: commits the pulled fix in claude-pipeline when direction is "from"
composes: []
failure_modes:
  - id: sync_sh_missing
    mitigation: verify the claude-pipeline repo location and that sync.sh exists at its root; if missing, ask the user to locate or reinstall the pipeline
  - id: project_dir_not_found
    mitigation: confirm the project_path with the user; do not attempt to create the directory
---

# Pipeline Sync

Manage core pipeline files across the claude-pipeline repo and project repos that use the pipeline.

Hooks and universal skills are shared across all projects. When one of those is fixed in a project's copy, it needs to flow back to the pipeline repo and out to other projects. Without this, fixes get stranded and the same bug gets rediscovered repeatedly.

The orchestration engine itself (`.claude/scripts/` — orchestrators, `platform/`, schemas, prompts) is **not** part of that loop as of #632. It ships in the `pipeline-core` plugin, so its fixes belong in this repo's canonical tree and reach consumers through a plugin update, never through `sync.sh`.

## Hook: Automatic Core File Detection

A PostToolUse hook at `scripts/detect-core-edit.sh` fires on every Edit/Write. When the edited file is a core pipeline file (script, hook, or universal skill), it outputs a reminder with the sync command. This means you don't need to remember to check — the hook tells you.

The hook is registered in `settings.json` and must be present for automatic detection to work. If it's missing, add it during `/adapting-claude-pipeline`:

```json
{
  "matcher": "Edit|Write",
  "hooks": [{
    "type": "command",
    "command": "\"$CLAUDE_PROJECT_DIR/.claude/skills/pipeline-sync/scripts/detect-core-edit.sh\"",
    "timeout": 5
  }]
}
```

## Prerequisites

`sync.sh` at the root of the claude-pipeline repo. Verify:
```bash
ls ~/Projects/claude-pipeline/sync.sh
```

## Workflows

### 1. Push upstream changes TO a project

```bash
cd ~/Projects/claude-pipeline
./sync.sh diff ~/Projects/<project-name>    # Check first
./sync.sh to ~/Projects/<project-name>      # Push core files
```

Never touches project-specific files (agents, `config/platform.sh`, prompts).

### 2. Pull a fix FROM a project

`from` mirrors `to`, so it covers exactly two things: `.claude/hooks/` and the
universal skills listed in `UNIVERSAL_SKILLS`.

```bash
cd ~/Projects/claude-pipeline
./sync.sh diff ~/Projects/<project-name>    # See what changed
./sync.sh from ~/Projects/<project-name>    # Pull the fix (hooks + universal skills)
git diff                                     # Review — empty means nothing was in scope
git checkout -b fix/<name>
git add -A && git commit -m "fix: <description>"
```

**`from` does not pull `.claude/scripts/`** (issue #632). Fixing a script in a
consumer and running `from` is a silent no-op: `git diff` comes back empty and
the fix stays stranded in that one repo. This bites most on the consumers that
have not migrated to the plugin yet — they still carry a stale `.claude/scripts/`
copy that looks editable but is not the source of truth.

Upstream a script fix directly instead:

```bash
cd ~/Projects/claude-pipeline
# edit the canonical file, e.g. .claude/scripts/platform/create-mr.sh
./sync.sh bundle                             # regenerate plugins/pipeline-core/scripts/
git add .claude/scripts plugins/pipeline-core/scripts
git commit -m "fix: <description>"
```

Consumers pick it up by updating the plugin, not by a sync. Skipping
`./sync.sh bundle` leaves the bundle stale and turns `Bundle Parity & Syntax`
red on the PR.

### 3. PR to upstream (stevegrocott/claude-pipeline)

```bash
cd ~/Projects/claude-pipeline
git push origin fix/<branch-name>
gh pr create --repo stevegrocott/claude-pipeline \
  --head scullers68:fix/<branch-name> --base main \
  --title "fix: <title>" --body "<summary + context + test plan>"
```

### 4. Pull upstream updates and distribute

```bash
cd ~/Projects/claude-pipeline
git fetch upstream && git merge upstream/main && git push origin main
./sync.sh to ~/Projects/allied-universal-assign
./sync.sh to ~/Projects/<other-project>
```

## File Classification

For the full breakdown of which files are core (synced) vs adapted (project-specific), read `references/file-classification.md`. In summary:

| Synced (core) | Never synced (project-specific) |
|---------------|-------------------------------|
| `hooks/**` | `agents/*.md`, `prompts/*.md` |
| Universal skills (brainstorming, TDD, etc.) | Project-only skills |
| `config/platform.sh`, `config/context.md` — seeded only if absent | an existing `config/` (consumer-owned; never overwritten) |

`scripts/**` is **not** synced (issue #632). `.claude/scripts/` is the pipeline's
own dogfood tree; consumers get the same scripts from the `pipeline-core` plugin
bundle via the `bin/pipeline-core-*` entrypoints and `pipeline-core-platform-dir`.
Copying it into a consumer leaves orphaned test suites and dead `platform/`
wrappers that cannot be repaired by re-syncing. `sync.sh` now fails with a named
reason if the sync scope ever overlaps the plugin bundle again.

## Adding a New Universal Skill

1. Add the skill name to `UNIVERSAL_SKILLS` in `sync.sh`
2. `./sync.sh from ~/Projects/<project>` to pull it
3. Commit and PR upstream
