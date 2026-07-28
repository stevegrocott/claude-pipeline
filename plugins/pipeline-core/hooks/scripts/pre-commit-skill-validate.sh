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
#   - skill-validate.sh unresolvable    → exit 0 (fail open — never block
#                                        on missing tooling) but WARN on
#                                        stderr, so the skip is visible
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
# Resolve the project root and the skill-validate.sh script.
#
# This hook ships in TWO trees and the copies are byte-identical (enforced by
# test-bundle-parity.bats), so resolution must work from either location:
#   .claude/hooks/                          repo-local  → ../scripts/
#   plugins/pipeline-core/hooks/scripts/    plugin      → ../../scripts/
#
# It must NOT assume the consumer still has .claude/scripts/. Migrating a repo
# to the pipeline-core plugin removes that directory, and the old default
# ("$PROJECT_DIR/.claude/scripts/skill-validate.sh") combined with the fail-open
# guard in main() turned this hook into a silent no-op in exactly that case —
# stevegrocott/beegee-farm-3 ran without SKILL.md validation from the day it
# migrated and nothing reported it (issue #640).
# ---------------------------------------------------------------------------
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve to the project root: CLAUDE_PROJECT_DIR when set by the harness,
# otherwise two levels up from this hook (hooks/ → .claude/ → project root).
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." && pwd)}"

# Bundled layout is <plugin root>/hooks/scripts/<this hook>. Only treat the
# grandparent as a plugin root when the directory shape actually matches, so
# the repo-local layout can never resolve to a stray <repo>/scripts/.
PLUGIN_ROOT=""
if [[ "$HOOK_DIR" == */hooks/scripts ]]; then
	PLUGIN_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
fi

# Print the first skill-validate.sh that exists, in resolution order:
#   1. SKILL_VALIDATE_SCRIPT   explicit override (tests, unusual layouts)
#   2. CLAUDE_PLUGIN_ROOT      set by the harness for plugin-hosted hooks
#   3. sibling scripts/        repo-local .claude/hooks → .claude/scripts
#   4. plugin scripts/         bundled hooks/scripts → <plugin root>/scripts
#   5. consumer .claude/       last resort for a non-plugin consumer whose
#                              hook is invoked from outside its own tree
# Returns non-zero (and prints nothing) when no validator is reachable.
resolve_skill_validate() {
	local candidate
	for candidate in \
		"${SKILL_VALIDATE_SCRIPT:-}" \
		"${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/skill-validate.sh}" \
		"$HOOK_DIR/../scripts/skill-validate.sh" \
		"${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/skill-validate.sh}" \
		"$PROJECT_DIR/.claude/scripts/skill-validate.sh"
	do
		if [[ -n "$candidate" && -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

SKILL_VALIDATE="$(resolve_skill_validate || true)"

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

	# Only now do we know this really is a SKILL.md edit. Fail open when no
	# validator is reachable — this hook must never block an edit because of
	# missing tooling — but say so on stderr. Failing open *silently* is what
	# hid the migrated-consumer no-op for an entire release (issue #640), and
	# deferring the check to here keeps the warning off every unrelated
	# Edit/Write the harness routes through this matcher.
	if [[ -z "$SKILL_VALIDATE" ]]; then
		{
			printf '%s: skill-validate.sh not found — SKILL.md ' \
				"$SCRIPT_NAME"
			printf 'frontmatter NOT validated for %s\n' "$file_path"
			printf '  looked under the plugin bundle and %s\n' \
				"$PROJECT_DIR/.claude/scripts/"
		} >&2
		exit 0
	fi

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
