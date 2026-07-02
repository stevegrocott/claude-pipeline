#!/usr/bin/env bats
#
# tests/marketplace-smoke.bats
# Smoke test for the pipeline plugin marketplace (issue #571).
#
# Asserts that a pipeline-core plugin scaffold "resolves":
#   * marketplace.json is valid JSON and lists a pipeline-core plugin
#   * every declared skill directory ships a SKILL.md
#   * every hook command in hooks.json points at a real, executable script
#     after ${CLAUDE_PLUGIN_ROOT} is expanded to the plugin root
#
# Two layers of coverage:
#   * Synthetic-scaffold tests build a minimal known-good (and known-bad)
#     plugin tree in a temp dir and exercise the resolver logic directly, so
#     the assertions are meaningful today — before the git mv (task 2) lands.
#   * Real-repo tests validate plugins/pipeline-core/ once it exists and skip
#     cleanly until the scaffold is created (issue #571 tasks 1-2).
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
	command -v jq >/dev/null || skip "jq not available"
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Resolvers / validators — the logic under test
# ---------------------------------------------------------------------------

# Echo the pipeline-core plugin root under a repo/marketplace tree; return
# non-zero when the scaffold is absent.
_find_plugin_core() {
	local root="$1"
	local core="$root/plugins/pipeline-core"
	if [[ -f "$core/.claude-plugin/plugin.json" || -f "$core/plugin.json" ]]
	then
		printf '%s\n' "$core"
		return 0
	fi
	return 1
}

# Echo the marketplace manifest path under a repo tree; non-zero when absent.
_find_marketplace() {
	local root="$1"
	local candidate
	for candidate in \
		"$root/.claude-plugin/marketplace.json" \
		"$root/marketplace.json"; do
		if [[ -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

_validate_marketplace() {
	local file="$1"
	if ! jq empty "$file" 2>/dev/null; then
		echo "marketplace.json is not valid JSON: $file" >&2
		return 1
	fi
	if ! jq -e '.plugins | map(.name) | index("pipeline-core")' \
		"$file" >/dev/null 2>&1; then
		echo "marketplace.json does not list a pipeline-core plugin" >&2
		return 1
	fi
}

_validate_skills() {
	local core="$1"
	local skills_dir="$core/skills"
	if [[ ! -d "$skills_dir" ]]; then
		echo "skills directory missing: $skills_dir" >&2
		return 1
	fi

	local dir
	local count=0
	local -a missing=()
	for dir in "$skills_dir"/*/; do
		[[ -d "$dir" ]] || continue
		if [[ -f "${dir}SKILL.md" ]]; then
			((count++))
		else
			missing+=("${dir%/}")
		fi
	done

	if ((${#missing[@]} > 0)); then
		echo "skill directories missing SKILL.md:" >&2
		printf '  %s\n' "${missing[@]}" >&2
		return 1
	fi
	if ((count == 0)); then
		echo "no skills found under $skills_dir" >&2
		return 1
	fi
}

_validate_hooks() {
	local core="$1"
	local file
	for file in "$core/hooks/hooks.json" "$core/hooks.json"; do
		[[ -f "$file" ]] && break
	done
	if [[ ! -f "$file" ]]; then
		echo "hooks.json not found under $core" >&2
		return 1
	fi
	if ! jq empty "$file" 2>/dev/null; then
		echo "hooks.json is not valid JSON: $file" >&2
		return 1
	fi

	local cmd
	local -a cmds=()
	while IFS= read -r cmd; do
		[[ -n "$cmd" ]] && cmds+=("$cmd")
	done < <(jq -r '.. | .command? // empty' "$file")

	if ((${#cmds[@]} == 0)); then
		echo "hooks.json declares no hook commands: $file" >&2
		return 1
	fi

	local script
	local -a bad=()
	for cmd in "${cmds[@]}"; do
		cmd="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$core}"
		cmd="${cmd//\$CLAUDE_PLUGIN_ROOT/$core}"
		read -r script _ <<< "$cmd"
		if [[ ! -f "$script" ]]; then
			bad+=("missing: $script")
		elif [[ ! -x "$script" ]]; then
			bad+=("not executable: $script")
		fi
	done

	if ((${#bad[@]} > 0)); then
		echo "hook scripts do not resolve:" >&2
		printf '  %s\n' "${bad[@]}" >&2
		return 1
	fi
}

# Build a minimal, valid pipeline-core marketplace scaffold under a root dir.
_build_scaffold() {
	local root="$1"
	local core="$root/plugins/pipeline-core"
	mkdir -p "$root/.claude-plugin" "$core/.claude-plugin" \
		"$core/skills/example-skill" "$core/hooks/scripts"

	cat > "$root/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "claude-pipeline",
  "plugins": [
    { "name": "pipeline-core", "source": "./plugins/pipeline-core" }
  ]
}
JSON

	cat > "$core/.claude-plugin/plugin.json" <<'JSON'
{ "name": "pipeline-core", "version": "0.0.0" }
JSON

	printf -- '---\nname: example-skill\n---\n' \
		> "$core/skills/example-skill/SKILL.md"

	cat > "$core/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/example.sh"
          }
        ]
      }
    ]
  }
}
JSON

	printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
		> "$core/hooks/scripts/example.sh"
	chmod +x "$core/hooks/scripts/example.sh"
}

# ===========================================================================
# Synthetic scaffold — positive path (proves the validators actually assert)
# ===========================================================================

@test "synthetic scaffold: marketplace.json lists pipeline-core" {
	_build_scaffold "$TEST_TMP"

	local mkt
	mkt="$(_find_marketplace "$TEST_TMP")"
	[ -n "$mkt" ]

	run _validate_marketplace "$mkt"
	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "synthetic scaffold: skills resolve — every skill dir has SKILL.md" {
	_build_scaffold "$TEST_TMP"

	local core
	core="$(_find_plugin_core "$TEST_TMP")"
	[ -n "$core" ]

	run _validate_skills "$core"
	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "synthetic scaffold: hooks resolve — every command is executable" {
	_build_scaffold "$TEST_TMP"

	local core
	core="$(_find_plugin_core "$TEST_TMP")"

	run _validate_hooks "$core"
	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# ===========================================================================
# Synthetic scaffold — negative paths (the validators must actually fail)
# ===========================================================================

@test "synthetic scaffold (broken): a skill dir without SKILL.md fails" {
	_build_scaffold "$TEST_TMP"
	local core="$TEST_TMP/plugins/pipeline-core"
	mkdir -p "$core/skills/orphan-skill"

	run _validate_skills "$core"
	[ "$status" -ne 0 ]
	[[ "$output" == *"orphan-skill"* ]]
}

@test "synthetic scaffold (broken): a hook command to a missing script fails" {
	_build_scaffold "$TEST_TMP"
	local core="$TEST_TMP/plugins/pipeline-core"
	rm -f "$core/hooks/scripts/example.sh"

	run _validate_hooks "$core"
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing"* ]]
}

@test "synthetic scaffold (broken): a non-executable hook script fails" {
	_build_scaffold "$TEST_TMP"
	local core="$TEST_TMP/plugins/pipeline-core"
	chmod -x "$core/hooks/scripts/example.sh"

	run _validate_hooks "$core"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not executable"* ]]
}

@test "synthetic scaffold (broken): marketplace without pipeline-core fails" {
	local root="$TEST_TMP/mkt"
	mkdir -p "$root/.claude-plugin"
	printf '%s\n' '{"name":"x","plugins":[{"name":"other"}]}' \
		> "$root/.claude-plugin/marketplace.json"

	run _validate_marketplace "$root/.claude-plugin/marketplace.json"
	[ "$status" -ne 0 ]
	[[ "$output" == *"pipeline-core"* ]]
}

# ===========================================================================
# Real repo — validate the shipped scaffold; skip until it is created
# ===========================================================================

@test "real repo: marketplace.json lists pipeline-core" {
	local mkt
	mkt="$(_find_marketplace "$REPO_ROOT")" \
		|| skip "marketplace.json not created yet (issue #571 task 1)"

	run _validate_marketplace "$mkt"
	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "real repo: pipeline-core skills and hooks resolve" {
	local core
	core="$(_find_plugin_core "$REPO_ROOT")" \
		|| skip "plugins/pipeline-core not created yet (issue #571 tasks 1-2)"

	run _validate_skills "$core"
	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

	run _validate_hooks "$core"
	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}
