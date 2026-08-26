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
# NAME FIELD MATCHES FILENAME
# =============================================================================
#
# The orchestrator and issue-body-lib resolve agent identity from the file's
# basename. If an agent's `name:` front-matter field diverges from its
# basename (e.g. a template copied and renamed without updating `name:`),
# name-based resolution silently picks the wrong agent (issue #818).

@test "every .claude/agents/*.md name: field matches its basename" {
	local file
	local basename
	local line
	local delim_count
	local name_value
	local -a failures=()

	for file in "$AGENTS_DIR"/*.md; do
		[[ -f "$file" ]] || continue
		basename="${file##*/}"
		basename="${basename%.md}"

		# Scan only the first `---`-delimited frontmatter block, matching
		# the production resolvers (_issue_body_agent_name,
		# _normalize_agent_name) — a `name:`-looking line in the agent's
		# prose body must not be mistaken for the declaration. Absence of a
		# `name:` key (or of the file entirely) leaves name_value empty,
		# which is reported as a violation rather than aborting the loop.
		delim_count=0
		name_value=""
		while IFS= read -r line; do
			if [[ "$line" == "---" ]]; then
				# Use an assignment, not ((delim_count++)): the
				# post-increment expression evaluates to the PRE
				# value, so the first delimiter makes (( )) return
				# exit status 1 and aborts the test under bats'
				# errexit (green on macOS bash 3.2, red on CI bash 5).
				delim_count=$((delim_count + 1))
				if ((delim_count >= 2)); then
					break
				fi
				continue
			fi
			if ((delim_count >= 1)) && [[ "$line" =~ ^name:[[:space:]]*(.*)$ ]]; then
				name_value="${BASH_REMATCH[1]}"
				break
			fi
		done < "$file"

		if [[ "$name_value" != "$basename" ]]; then
			failures+=(
				"${file##*/}: name: '${name_value}' does not match basename '${basename}'"
			)
		fi
	done

	if ((${#failures[@]} > 0)); then
		echo "Agent .md files with name: mismatched to filename:"
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
