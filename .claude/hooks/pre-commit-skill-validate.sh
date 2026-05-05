#!/usr/bin/env bash
#
# pre-commit-skill-validate.sh — PreToolUse hook that validates SKILL.md
# YAML frontmatter against the schema BEFORE an Edit or Write tool call
# is allowed to apply.
#
# Wiring (settings.json):
#   PreToolUse / matcher "Edit|Write" — fires for every Edit/Write call.
#   The hook itself filters to paths ending in "/SKILL.md".
#
# Hook stdin format:
#   {"tool_name":"Edit"|"Write","tool_input":{...},...}
#
# Behaviour:
#   - tool_name not Edit/Write          → exit 0 (allow, silent)
#   - file_path not "*/SKILL.md"        → exit 0 (allow, silent)
#   - skill-validate.sh missing         → exit 0 (fail open — never block
#                                        on missing tooling)
#   - post-edit frontmatter passes      → exit 0 (allow)
#   - post-edit frontmatter fails       → exit 2 (block, stderr explains)
#
# Post-edit content is reconstructed in a temporary skill directory so
# that skill-validate.sh can be invoked unmodified via SKILLS_DIR + the
# resolved skill name.
#

set -u
set -o pipefail

readonly SCRIPT_NAME="${0##*/}"

# ---------------------------------------------------------------------------
# Resolve the project root and the skill-validate.sh script. Honour
# CLAUDE_PROJECT_DIR (set by the harness) and a SKILL_VALIDATE_SCRIPT
# override (used by tests) before falling back to a path relative to this
# script.
# ---------------------------------------------------------------------------
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve to the project root: CLAUDE_PROJECT_DIR when set by the harness,
# otherwise two levels up from this hook (hooks/ → .claude/ → project root).
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." && pwd)}"
SKILL_VALIDATE="${SKILL_VALIDATE_SCRIPT:-$PROJECT_DIR/.claude/scripts/skill-validate.sh}"

# ---------------------------------------------------------------------------
# Python helper that does the JSON parsing, post-edit reconstruction, and
# materialisation. Stored once and invoked via `python3 -c "$PY_BUILD"` so
# the hook's stdin (the original PreToolUse JSON) flows through to python
# unmodified — using a heredoc here would steal stdin.
# ---------------------------------------------------------------------------
read -r -d '' PY_BUILD <<'PY' || true
import json
import os
import sys

tmp_root = sys.argv[1]

try:
    payload = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)

tool = payload.get("tool_name", "")
if tool not in ("Edit", "Write"):
    sys.exit(0)

ti = payload.get("tool_input") or {}
file_path = ti.get("file_path") or ""
if not file_path or not file_path.endswith("/SKILL.md"):
    sys.exit(0)

# Skill name = directory containing SKILL.md
skill_name = os.path.basename(os.path.dirname(file_path))
if not skill_name:
    sys.exit(0)

# Compute the post-edit content
if tool == "Write":
    new_content = ti.get("content", "") or ""
else:  # Edit
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            existing = f.read()
    except OSError:
        # Edit on a non-existent file — let Claude Code surface that
        # error; nothing useful for us to validate.
        sys.exit(0)

    old = ti.get("old_string", "") or ""
    new = ti.get("new_string", "") or ""
    replace_all = bool(ti.get("replace_all"))

    if old == "":
        # Edit semantics require a non-empty old_string; if it is
        # empty there's nothing meaningful to simulate.
        sys.exit(0)

    if replace_all:
        new_content = existing.replace(old, new)
    else:
        new_content = existing.replace(old, new, 1)

# Materialise the post-edit content under a private skills tree so that
# skill-validate.sh can be invoked unmodified via SKILLS_DIR.
skills_dir = os.path.join(tmp_root, "skills")
target_dir = os.path.join(skills_dir, skill_name)
os.makedirs(target_dir, exist_ok=True)

target = os.path.join(target_dir, "SKILL.md")
with open(target, "w", encoding="utf-8") as f:
    f.write(new_content)

print(skills_dir)
print(skill_name)
print(file_path)
PY

# ---------------------------------------------------------------------------
# build_post_edit_state <tmp_root>
#
# Reads PreToolUse JSON from stdin. When the call is an Edit or Write on
# a "*/SKILL.md" path, computes the post-edit content and materialises it
# at <tmp_root>/skills/<skill_name>/SKILL.md.
#
# On success, prints three lines to stdout:
#   1. SKILLS_DIR (i.e. <tmp_root>/skills)
#   2. <skill_name> (the parent directory of SKILL.md)
#   3. <file_path> (the original path, for error messages)
#
# Prints nothing and exits 0 when the call should be ignored.
# ---------------------------------------------------------------------------
build_post_edit_state() {
	local tmp_root="$1"

	python3 -c "$PY_BUILD" "$tmp_root"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	# If skill-validate.sh isn't available, fail open. We never want this
	# hook to block edits because of missing tooling.
	[[ -f "$SKILL_VALIDATE" ]] || exit 0

	local tmp_root
	tmp_root=$(mktemp -d 2>/dev/null) || exit 0
	trap 'rm -rf "$tmp_root"' EXIT

	local info
	info=$(build_post_edit_state "$tmp_root") || exit 0
	[[ -n "$info" ]] || exit 0

	local skills_dir skill_name file_path
	{
		IFS= read -r skills_dir
		IFS= read -r skill_name
		IFS= read -r file_path
	} <<< "$info"

	[[ -n "$skills_dir" && -n "$skill_name" ]] || exit 0

	# Run skill-validate.sh against the simulated post-edit state.
	local validate_output
	if validate_output=$(SKILLS_DIR="$skills_dir" \
		bash "$SKILL_VALIDATE" --skill "$skill_name" 2>&1); then
		exit 0
	fi

	# Validation failed — block and surface the error.
	{
		printf '%s: SKILL.md frontmatter validation failed\n' \
			"$SCRIPT_NAME"
		printf '  file:  %s\n' "$file_path"
		printf '  skill: %s\n' "$skill_name"
		printf '\n'
		printf '%s\n' "$validate_output"
		printf '\n'
		printf 'Edit blocked. Fix the frontmatter to match '
		printf '.claude/scripts/schemas/skill-frontmatter.json '
		printf 'and try again.\n'
	} >&2
	exit 2
}

main "$@"
