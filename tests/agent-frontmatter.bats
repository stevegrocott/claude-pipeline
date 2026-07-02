#!/usr/bin/env bats
#
# tests/agent-frontmatter.bats
# Every .claude/agents/*.md must open with a YAML front-matter fence (---)
# as its first non-empty line.  Claude Code uses the front-matter block to
# register the agent's name, model, and description; files that begin with
# HTML comments, markdown headings, or blank lines are silently skipped by
# the loader and the agent becomes unavailable.
#
# Acceptance criteria (issue #566 task 3):
#   * One test per run that iterates the full .claude/agents/*.md glob
#   * Reports every non-compliant file in a single failure message
#   * Passes cleanly when every file opens with ---
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# Agent definitions moved under plugins/pipeline-core/agents/ in the plugin
# migration (issue #571).  Before the git mv they still live in
# .claude/agents/.  Prefer the plugin location and fall back to the legacy
# path so this test passes on both sides of the restructure.
if [[ -d "$REPO_ROOT/plugins/pipeline-core/agents" ]]; then
	AGENTS_DIR="$REPO_ROOT/plugins/pipeline-core/agents"
else
	AGENTS_DIR="$REPO_ROOT/.claude/agents"
fi

# =============================================================================
# FRONT-MATTER OPENER
# =============================================================================

@test "every .claude/agents/*.md opens with --- as first non-empty line" {
	local file
	local first_non_empty
	local -a failures=()

	for file in "$AGENTS_DIR"/*.md; do
		[[ -f "$file" ]] || continue
		first_non_empty=$(grep -m1 . "$file")
		if [[ "$first_non_empty" != "---" ]]; then
			failures+=(
				"${file##*/}: first non-empty line is '${first_non_empty}'"
			)
		fi
	done

	if ((${#failures[@]} > 0)); then
		echo "Agent .md files missing YAML front-matter opener (---):"
		printf '  %s\n' "${failures[@]}"
		return 1
	fi
}

# =============================================================================
# EDGE-CASE: glob expands to nothing
# =============================================================================

@test ".claude/agents/ directory contains at least one .md file" {
	local -a found=()

	for file in "$AGENTS_DIR"/*.md; do
		[[ -f "$file" ]] && found+=("$file")
	done

	((${#found[@]} > 0))
}
