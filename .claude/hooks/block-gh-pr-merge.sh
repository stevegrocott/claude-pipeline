#!/usr/bin/env bash
#
# block-gh-pr-merge.sh — PreToolUse(Bash) guard.
#
# Hard-blocks any agent Bash command that invokes `gh pr merge` (or
# `glab mr merge`) directly, forcing every merge through merge-mr.sh, which
# refuses a PR whose required check has already concluded in failure.
#
# Rationale (issue #853): #848 established that merge-mr.sh's refusal is, on a
# repo that cannot enable branch protection, the ONLY thing between a failing
# check and the base branch — GitHub returns 403 "Upgrade to GitHub Pro or make
# this repository public" for required-status-check enforcement there. But the
# merge in process-pr was LLM-mediated: SKILL.md Step 4b *instructed* the model
# to call merge-mr.sh, and nothing bound it. A model that shelled out to
# `gh pr merge` directly bypassed the guard entirely. That is consistent with
# the observed incident, where merge-mr.sh refused at 13:51 and the PR was
# merged at 13:54 with `e2e: fail`.
#
# A SKILL.md instruction is a request; this hook is a gate. It is the same
# pattern as block-gh-issue-create.sh, which forces issue creation through
# create-issue.sh so assert_issue_valid always runs.
#
# Why this does NOT block the legitimate entrypoint:
#   PreToolUse(Bash) fires on the command the AGENT runs. When the agent runs
#   `merge-mr.sh <pr>`, that is the command the hook inspects; the script's
#   INTERNAL `gh pr merge` runs as a subprocess of the script, never as a
#   Bash-tool call, so the hook never sees it. The same holds for
#   surgical-fast-path.sh, which merges directly but carries its own
#   equivalent _fast_path_check_concluded_failure guard immediately before.
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
# Match at a COMMAND position only: start of command or after a separator
# (; & | && || newline opening-paren), tolerant of leading env-var assignments
# and env/sudo/command/nice/nohup wrappers (including the `env -u VAR` /
# `env --unset VAR` two-token option forms).
#
# Anchoring to a command boundary is deliberate: a bare search also matches the
# phrase inside a quoted argument (e.g. a git commit message that mentions
# "gh pr merge"), causing annoying false blocks. merge-mr.sh is invoked by path
# so its command never starts with `gh pr merge`; its internal call is a script
# subprocess the hook never sees.
pattern = re.compile(
    r"(?:^|[;&|\n(]|&&|\|\|)\s*"
    r"(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*"
    r"(?:(?:sudo|command|nohup|nice)\s+)*"
    r"(?:env\s+(?:-u\s+\S+\s+|--unset\s+\S+\s+|-\S+\s+|[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*)?"
    r"(?:gh\s+pr\s+merge|glab\s+mr\s+merge)\b")
if pattern.search(cmd):
    sys.stderr.write(
        "BLOCKED: direct `gh pr merge` / `glab mr merge` is prohibited. Merge "
        "via the platform wrapper instead:\n"
        "  \"$(pipeline-core-platform-dir)\"/merge-mr.sh <pr-number>\n"
        "It refuses a PR whose required check has concluded in failure "
        "(issue #853). If you believe the merge is safe, fix or re-run the "
        "failing check first — do not work around this hook.\n")
    sys.exit(2)
sys.exit(0)
'
