#!/usr/bin/env bash
#
# sync-reminder.sh — PostToolUse hook: remind to sync core pipeline changes
#
# When a core pipeline file (scripts/, hooks/, settings.json, or a universal
# skill) is edited, reads downstream-projects.txt and prints a reminder block
# listing per-project ./sync.sh to <path> commands.
#
# Exits 0 silently when:
#   - The edited file is not a core pipeline file
#   - downstream-projects.txt is missing or empty
#
# Hook format (stdin):
#   {"tool_name":"Edit|Write","tool_input":{"file_path":"..."},...}
# Exit: always 0 (reminder only — never blocks)
#

set -o pipefail

# ---------------------------------------------------------------------------
# Universal skills that are synced across projects (mirrors UNIVERSAL_SKILLS
# in sync.sh — keep these two lists in sync).
# ---------------------------------------------------------------------------
readonly -a UNIVERSAL_SKILLS=(
	brainstorming
	create-session-summary
	dispatching-parallel-agents
	executing-plans
	explore
	handle-issues
	implement-issue
	improvement-loop
	investigating-codebase-for-user-stories
	mcp-tools
	playwright-testing
	process-pr
	resume-session
	subagent-driven-development
	systematic-debugging
	test-driven-development
	using-git-worktrees
	using-skills
	writing-agents
	writing-plans
	writing-skills
	adapting-claude-pipeline
	pipeline-sync
	pr-creation
	pr-review
	complete-summary
	test-validation
	fix-from-review
)

# ---------------------------------------------------------------------------
# extract_file_path
#
# Reads JSON from stdin, returns the tool_input.file_path if the tool is
# Edit or Write. Outputs the path to stdout; outputs nothing if the tool is
# not Edit/Write or has no file_path.
# ---------------------------------------------------------------------------
extract_file_path() {
	local json=""
	local line

	while IFS= read -r line; do
		json+="$line"$'\n'
	done

	# Only process Edit or Write tool calls
	if [[ "$json" != *'"tool_name":"Edit"'*   && \
		  "$json" != *'"tool_name": "Edit"'*  && \
		  "$json" != *'"tool_name":"Write"'*  && \
		  "$json" != *'"tool_name": "Write"'* ]]; then
		return 0
	fi

	# Prefer python3 for reliable JSON parsing
	if command -v python3 > /dev/null 2>&1; then
		python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    if d.get("tool_name") in ("Edit", "Write"):
        print(d.get("tool_input", {}).get("file_path", ""), end="")
except Exception:
    pass
' <<< "$json"
		return
	fi

	# ---- Pure-bash fallback --------------------------------------------------
	local after="${json#*\"file_path\":}"
	after="${after# }"
	[[ "${after:0:1}" == '"' ]] || return 0
	after="${after:1}"

	local path="" i char prev=""
	for (( i=0; i<${#after}; i++ )); do
		char="${after:$i:1}"
		if [[ "$prev" == '\' ]]; then
			case "$char" in
				n)   path="${path%\\}"$'\n' ;;
				t)   path="${path%\\}"$'\t' ;;
				'"') path="${path%\\}\""    ;;
				'\') path="${path%\\}\\"    ;;
				*)   path+="$char"          ;;
			esac
			prev="$char"
			continue
		fi
		[[ "$char" == '"' ]] && break
		path+="$char"
		prev="$char"
	done

	printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# normalize_to_dotclaude_path
#
# Given an absolute or relative file path, strips everything up to and
# including the project root so the result starts with ".claude/...".
# Outputs the normalised path, or nothing if the path is not under .claude/.
# ---------------------------------------------------------------------------
normalize_to_dotclaude_path() {
	local file_path="$1"

	# Absolute path containing /.claude/
	if [[ "$file_path" == *"/.claude/"* ]]; then
		printf '.claude/%s' "${file_path#*/.claude/}"
		return
	fi

	# Relative path already starting with .claude/
	if [[ "$file_path" == ".claude/"* ]]; then
		printf '%s' "$file_path"
		return
	fi

	# Strip leading ./ then re-check
	local stripped="${file_path#./}"
	if [[ "$stripped" == ".claude/"* ]]; then
		printf '%s' "$stripped"
		return
	fi

	# Not a .claude/ path — output nothing
}

# ---------------------------------------------------------------------------
# is_core_file
#
# Returns 0 (true) if the normalised .claude-relative path belongs to a core
# pipeline file set; 1 (false) otherwise.
# ---------------------------------------------------------------------------
is_core_file() {
	local rel="$1"

	# Core directories: scripts/ and hooks/
	if [[ "$rel" == ".claude/scripts/"* || "$rel" == ".claude/hooks/"* ]]; then
		return 0
	fi

	# Core individual file: settings.json
	if [[ "$rel" == ".claude/settings.json" ]]; then
		return 0
	fi

	# Universal skills: .claude/skills/<skill-name>/...
	local skill
	for skill in "${UNIVERSAL_SKILLS[@]}"; do
		if [[ "$rel" == ".claude/skills/${skill}/"* || \
			  "$rel" == ".claude/skills/${skill}" ]]; then
			return 0
		fi
	done

	return 1
}

# ---------------------------------------------------------------------------
# read_downstream_projects
#
# Reads downstream-projects.txt (one path per line; # comments and blank
# lines ignored). Populates the caller-scoped PROJECTS array.
# ---------------------------------------------------------------------------
read_downstream_projects() {
	local registry="$1"
	PROJECTS=()

	while IFS= read -r line; do
		# Skip blank lines and comment lines
		[[ -z "$line" || "$line" == '#'* ]] && continue
		PROJECTS+=("$line")
	done < "$registry"
}

# ---------------------------------------------------------------------------
# print_reminder
# ---------------------------------------------------------------------------
print_reminder() {
	local file_path="$1"
	shift
	local -a projects=("$@")

	printf '\n'
	printf '╔══════════════════════════════════════════════════╗\n'
	printf '║  SYNC REMINDER — core pipeline file changed      ║\n'
	printf '╚══════════════════════════════════════════════════╝\n'
	printf '\n'
	printf 'Edited: %s\n' "$file_path"
	printf '\n'
	printf 'Sync to downstream projects:\n'
	printf '\n'
	local project
	for project in "${projects[@]}"; do
		printf '  ./sync.sh to %s\n' "$project"
	done
	printf '\n'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local file_path

	# Read and extract the edited file path from hook stdin
	file_path=$(extract_file_path)

	# Not an Edit/Write call, or no file_path — exit silently
	[[ -z "$file_path" ]] && exit 0

	# Normalise to a .claude/-relative path for matching
	local rel_path
	rel_path=$(normalize_to_dotclaude_path "$file_path")

	# Path is not under .claude/ — not a pipeline file, exit silently
	[[ -z "$rel_path" ]] && exit 0

	# Check if this .claude/ file is a core pipeline file
	is_core_file "$rel_path" || exit 0

	# Locate the project root (where sync.sh and downstream-projects.txt live)
	local project_root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
	local registry="$project_root/.claude/config/downstream-projects.txt"

	# No registry file — exit silently
	[[ -f "$registry" ]] || exit 0

	# Load downstream project paths
	local -a PROJECTS
	read_downstream_projects "$registry"

	# Empty registry — exit silently
	[[ "${#PROJECTS[@]}" -eq 0 ]] && exit 0

	# Output the sync reminder
	print_reminder "$file_path" "${PROJECTS[@]}"

	exit 0
}

main "$@"
