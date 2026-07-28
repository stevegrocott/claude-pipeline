#!/usr/bin/env bash
#
# block-gh-issue-create.sh — PreToolUse(Bash) guard.
#
# Hard-blocks any agent Bash command that invokes `gh issue create`
# directly, forcing all issue creation through the pipeline-core plugin
# entrypoints — pipeline-core-create-followup-issue and
# "$(pipeline-core-platform-dir)"/create-issue.sh — which run
# `assert_issue_valid` fail-closed.
#
# The message names the PLUGIN entrypoints, not .claude/scripts/ wrappers
# (issue #632): a consumer on the plugin has no .claude/scripts/ — the
# migration removed it — so naming those paths sends the blocked model to a
# path that does not exist in its repo.
#
# Rationale: #501 made "never call gh issue create" a SKILL instruction and
# #513 removed the permission friction that drove the fallback, but neither
# is a hard technical gate — a confused agent could still shell out to
# `gh issue create` with an unvalidated (prose) body, producing malformed
# issues that stall the pipeline. This hook makes that impossible.
#
# Why this does NOT block the legitimate entrypoints:
#   PreToolUse(Bash) fires on the command the AGENT runs. When the agent runs
#   `pipeline-core-create-followup-issue ...`, that is the command the hook
#   inspects; the script's INTERNAL `gh issue create` runs as a subprocess of
#   the script, never as a Bash-tool call, so the hook never sees it. Only a
#   direct agent `gh issue create` is matched.
#
# Code is passed via `python3 -c` (not a heredoc) so the hook's stdin remains
# the PreToolUse JSON payload. Exit 2 blocks (stderr surfaced to the model);
# exit 0 allows. Malformed payloads fail OPEN (never block unrelated tools).

exec python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
cmd = (data.get("tool_input", {}) or {}).get("command", "") or ""
# Match `gh issue create` only at a COMMAND position: start of command or
# after a separator (; & | && || newline opening-paren), tolerant of leading
# env-var assignments and env/sudo/command/nice/nohup wrappers (including the
# `env -u VAR` / `env --unset VAR` two-token option forms).
#
# Anchoring to a command boundary is deliberate: a bare \bgh...\b search also
# matches the phrase inside a quoted argument (e.g. a git commit message or an
# echo/grep that merely mentions "gh issue create"), causing annoying false
# blocks. The wrapper scripts are invoked by PATH (".../create-issue.sh") so
# their command never starts with `gh issue create`; their INTERNAL gh call is
# a script subprocess the hook never sees.
pattern = re.compile(
    r"(?:^|[;&|\n(]|&&|\|\|)\s*"
    r"(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*"
    r"(?:(?:sudo|command|nohup|nice)\s+)*"
    r"(?:env\s+(?:-u\s+\S+\s+|--unset\s+\S+\s+|-\S+\s+|[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*)?"
    r"gh\s+issue\s+create\b")
if pattern.search(cmd):
    sys.stderr.write(
        "BLOCKED: direct gh issue create is prohibited. Create issues via the "
        "pipeline-core plugin entrypoints: pipeline-core-create-followup-issue "
        "(follow-ups) or \"$(pipeline-core-platform-dir)\"/create-issue.sh — "
        "they run assert_issue_valid fail-closed so every issue has parseable "
        "tasks + acceptance criteria. "
        "See plugins/pipeline-core/skills/process-pr/SKILL.md Step 4g.\n")
    sys.exit(2)
sys.exit(0)
'
