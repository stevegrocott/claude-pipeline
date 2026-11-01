#!/usr/bin/env bats
#
# tests/agent-reference-resolution.bats
# Every agent name referenced as usable in plugins/pipeline-core/ or
# .claude/skills/ must resolve to an agent definition, or sit on the
# allowlist below with a recorded reason.  Catches references like
# `--agent bulletproof-frontend-developer` that name an agent which exists
# nowhere (issue #784).
#
# Reference forms scanned (*.md and *.sh):
#   --agent NAME              CLI flag examples
#   `[NAME]`                  backtick task-format agent markers
#   **Agent:** NAME           skill dispatch directives
#   subagent_type="NAME"      Task-tool dispatch
#   run_stage ... "x.json" "NAME"   orchestrator stage agent argument
#
# Placeholders such as <name>, "$AGENT" or '...' never match the name regex
# (it requires a lowercase-letter start), so they need no allowlist entry.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

SCAN_ROOTS=(plugins/pipeline-core .claude/skills)

# Directories whose <name>.md defines a resolvable agent.
AGENT_DIRS=(.claude/agents .claude/local/agents plugins/pipeline-core/agents)

# Allowlist: "name|reason".  Every exemption is a recorded decision.
ALLOWLIST=(
	"default|task-format keyword meaning 'no --agent override', not an agent name"
	"x|markdown checkbox [x] written in backticks, not an agent"
	"agent|generic placeholder in task-format documentation"
	"agent-name|generic placeholder in task-format documentation"
	"agent-1|numbered placeholder in task-format examples"
	"agent-2|numbered placeholder in task-format examples"
	"agent-3|numbered placeholder in task-format examples"
	"other-agent|placeholder in task-format examples"
	"flag|prose in a comment about the --agent flag, not a name"
	"requires|prose in the '--agent requires a value' usage error"
	"code-simplifier|unshipped by design; post-pr-simplify.sh checks .claude/agents and .claude/local/agents and warns instead of blocking"
	"test-engineer|legacy alias documented as never-write; remapped to playwright-test-developer in issue-body-lib.sh and the orchestrator"
	"fullstack-engineer|legacy alias documented as never-write; normalizer downgrades it to default"
	"backend-developer|conventional name consumers give the fastify-backend-developer template (copied to .claude/local/agents/); cited as an example in writing-plans"
	"frontend-developer|conventional name consumers give the react-frontend-developer template (copied to .claude/local/agents/); cited as an example in writing-plans"
	"phpdoc-writer|PHP-project skill (write-docblocks) dispatching a consumer-supplied agent that this repo does not ship"
)

# Print "name<TAB>file:line" for every agent reference found.
collect_references() {
	local root="$1" name_re='[a-z][a-z0-9-]*'
	(
		cd "$REPO_ROOT" || exit 1
		grep -rnE --include='*.md' --include='*.sh' \
			-e "--agent[ =]+${name_re}" \
			-e "\`\[${name_re}\]\`" \
			-e "\*\*Agent:\*\* +${name_re}" \
			-e "subagent_type[=: ]+\"?${name_re}" \
			-e "run_stage .*\.json\" \"${name_re}\"" \
			"$root" 2>/dev/null
	) | while IFS= read -r hit; do
		local loc="${hit%%:*}" rest="${hit#*:}"
		local lineno="${rest%%:*}" text="${rest#*:}" m
		# A line can carry several references; emit each one.
		while IFS= read -r m; do
			[[ -n "$m" ]] && printf '%s\t%s:%s\n' "$m" "$loc" "$lineno"
		done < <(
			{
				grep -oE -e "--agent[ =]+${name_re}" <<<"$text" | sed -E 's/--agent[ =]+//'
				grep -oE -e "\`\[${name_re}\]\`" <<<"$text" | sed -E 's/`\[(.*)\]`/\1/'
				grep -oE -e "\*\*Agent:\*\* +${name_re}" <<<"$text" | sed -E 's/\*\*Agent:\*\* +//'
				grep -oE -e "subagent_type[=: ]+\"?${name_re}" <<<"$text" | sed -E 's/subagent_type[=: ]+"?//'
				grep -oE -e "\.json\" \"${name_re}\"" <<<"$text" | sed -E 's/\.json" "(.*)"/\1/'
			} || true
		)
	done
}

is_allowlisted() {
	local name="$1" entry
	for entry in "${ALLOWLIST[@]}"; do
		[[ "${entry%%|*}" == "$name" ]] && return 0
	done
	return 1
}

agent_resolves() {
	local name="$1" dir
	for dir in "${AGENT_DIRS[@]}"; do
		[[ -f "$REPO_ROOT/$dir/$name.md" ]] && return 0
	done
	return 1
}

@test "every referenced agent name resolves or is allowlisted" {
	local root name where
	local -a failures=()
	local -i seen=0

	for root in "${SCAN_ROOTS[@]}"; do
		while IFS=$'\t' read -r name where; do
			[[ -n "$name" ]] || continue
			seen+=1
			agent_resolves "$name" && continue
			is_allowlisted "$name" && continue
			failures+=("$name  ($where)")
		done < <(collect_references "$root")
	done

	# Guard against a vacuous pass if the scan itself breaks.
	[[ "$seen" -gt 20 ]] || {
		echo "scan found only $seen references — extraction is broken" >&2
		return 1
	}

	if [[ "${#failures[@]}" -gt 0 ]]; then
		echo "Agent references that resolve nowhere and are not allowlisted:" >&2
		printf '  %s\n' "${failures[@]}" >&2
		return 1
	fi
}

@test "allowlist entries each carry a reason and none shadow a real agent" {
	local entry name reason
	for entry in "${ALLOWLIST[@]}"; do
		name="${entry%%|*}"
		reason="${entry#*|}"
		[[ -n "$name" && "$reason" != "$entry" && -n "$reason" ]] || {
			echo "allowlist entry lacks a reason: $entry" >&2
			return 1
		}
		if agent_resolves "$name"; then
			echo "allowlist entry '$name' resolves to a real agent; remove it" >&2
			return 1
		fi
	done
}

@test "detector flags an unresolvable name (RED check)" {
	local tmp="$BATS_TEST_TMPDIR/fx"
	mkdir -p "$tmp/plugins/pipeline-core"
	echo 'run: foo.sh --agent no-such-agent-xyz' >"$tmp/plugins/pipeline-core/a.md"
	REPO_ROOT="$tmp" run collect_references plugins/pipeline-core
	[ "$status" -eq 0 ]
	[[ "$output" == *"no-such-agent-xyz"* ]]
	REPO_ROOT="$REPO_ROOT" run agent_resolves no-such-agent-xyz
	[ "$status" -ne 0 ]
}
