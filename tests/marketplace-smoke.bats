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

_validate_marketplace_version() {
	local mkt="$1"
	local core="$2"
	local mkt_version manifest_version
	mkt_version="$(jq -r '.plugins[] | select(.name == "pipeline-core") | .version // empty' "$mkt")"
	manifest_version="$(jq -r '.version // empty' "$core/.claude-plugin/plugin.json")"

	if [[ -z "$mkt_version" ]]; then
		echo "marketplace.json pipeline-core entry has no version: $mkt" >&2
		return 1
	fi
	if [[ -z "$manifest_version" ]]; then
		echo "plugin.json has no version: $core/.claude-plugin/plugin.json" >&2
		return 1
	fi
	if [[ "$mkt_version" != "$manifest_version" ]]; then
		echo "marketplace version ($mkt_version) != plugin.json version ($manifest_version)" >&2
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
    { "name": "pipeline-core", "source": "./plugins/pipeline-core", "version": "0.0.0" }
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

@test "synthetic scaffold: marketplace version matches plugin.json version" {
	_build_scaffold "$TEST_TMP"

	local mkt core
	mkt="$(_find_marketplace "$TEST_TMP")"
	core="$(_find_plugin_core "$TEST_TMP")"

	run _validate_marketplace_version "$mkt" "$core"
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

@test "synthetic scaffold (broken): marketplace version drifted from plugin.json fails" {
	_build_scaffold "$TEST_TMP"
	local core="$TEST_TMP/plugins/pipeline-core"
	local mkt="$TEST_TMP/.claude-plugin/marketplace.json"
	jq '.plugins[0].version = "9.9.9"' "$mkt" > "$mkt.tmp" && mv "$mkt.tmp" "$mkt"

	run _validate_marketplace_version "$mkt" "$core"
	[ "$status" -ne 0 ]
	[[ "$output" == *"9.9.9"* ]]
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

@test "real repo: marketplace.json pipeline-core version matches plugin.json" {
	local mkt core
	mkt="$(_find_marketplace "$REPO_ROOT")" \
		|| skip "marketplace.json not found"
	core="$(_find_plugin_core "$REPO_ROOT")" \
		|| skip "plugins/pipeline-core not found"

	local mkt_version
	mkt_version="$(jq -r '.plugins[] | select(.name == "pipeline-core") | .version // empty' "$mkt")"
	[[ -n "$mkt_version" ]] \
		|| skip "marketplace.json pipeline-core entry has no version yet (issue #615 task 1)"

	run _validate_marketplace_version "$mkt" "$core"
	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# ===========================================================================
# Bundled runtime — scripts + schemas ship in the plugin and self-resolve
# (issue #599 Task 9). A marketplace consumer with NO copied .claude/scripts
# must still get the orchestration engine + JSON schemas from the plugin, and
# resolve-pipeline-root.sh must locate a bundled schema via BASH_SOURCE alone
# (CLAUDE_PLUGIN_ROOT is unset in the model's Bash-tool shell — Task 1 finding).
# ===========================================================================

@test "bundle: pipeline-core ships the orchestrator scripts and schemas" {
	local scripts_dir="$REPO_ROOT/plugins/pipeline-core/scripts"
	[ -d "$scripts_dir" ] \
		|| { echo "scripts dir missing: $scripts_dir" >&2; return 1; }

	local orch
	for orch in \
		implement-issue-orchestrator.sh \
		explore-orchestrator.sh \
		batch-orchestrator.sh; do
		[ -f "$scripts_dir/$orch" ] \
			|| { echo "missing bundled orchestrator: $orch" >&2; return 1; }
	done

	# JSON schemas ship alongside the scripts under scripts/schemas/.
	[ -d "$scripts_dir/schemas" ] \
		|| { echo "schemas dir missing: $scripts_dir/schemas" >&2; return 1; }
	local schema_count
	schema_count=$(find "$scripts_dir/schemas" -maxdepth 1 -name '*.json' | wc -l)
	[ "$schema_count" -gt 0 ] \
		|| { echo "no *.json schemas under $scripts_dir/schemas" >&2; return 1; }
}

@test "bundle: resolve-pipeline-root.sh self-resolves a bundled schema (CLAUDE_PLUGIN_ROOT unset)" {
	local scripts_dir="$REPO_ROOT/plugins/pipeline-core/scripts"
	local resolver="$scripts_dir/resolve-pipeline-root.sh"
	[ -f "$resolver" ] \
		|| { echo "resolver missing: $resolver" >&2; return 1; }

	# Pick a real bundled schema and resolve it by its relative path.
	local schema
	schema="$(find "$scripts_dir/schemas" -maxdepth 1 -name '*.json' | head -1)"
	[ -n "$schema" ] || skip "no bundled schema to resolve"
	local rel="schemas/$(basename "$schema")"

	# Source the resolver FROM the bundle with CLAUDE_PLUGIN_ROOT unset, so the
	# only way it can find the schema is BASH_SOURCE self-location.
	run env -u CLAUDE_PLUGIN_ROOT bash -c '
		source "$1"
		resolve_pipeline_file "$2"
	' _ "$resolver" "$rel"

	[ "$status" -eq 0 ] || { echo "resolver failed: $output" >&2; return 1; }
	[ "$output" = "$scripts_dir/$rel" ] \
		|| { echo "resolved wrong: got '$output' want '$scripts_dir/$rel'" >&2; return 1; }
}

@test "bundle: resolve_consumer_file resolves platform.sh from a clean consumer repo root (PWD fallback)" {
	local resolver="$REPO_ROOT/plugins/pipeline-core/scripts/resolve-pipeline-root.sh"
	[ -f "$resolver" ] || { echo "resolver missing: $resolver" >&2; return 1; }

	local consumer="$TEST_TMP/consumer"
	mkdir -p "$consumer/.claude/config"
	printf '#!/usr/bin/env bash\n' > "$consumer/.claude/config/platform.sh"

	# No git repo at $consumer and no PIPELINE_CONFIG_DIR override, so
	# resolution can only succeed via resolve_consumer_file()'s $PWD fallback
	# (path 2) — the consumer repo root when `git rev-parse` finds no toplevel.
	run env -u PIPELINE_CONFIG_DIR -u CLAUDE_PLUGIN_ROOT bash -c '
		cd "$1" || exit 1
		source "$2"
		resolve_consumer_file platform.sh
	' _ "$consumer" "$resolver"

	[ "$status" -eq 0 ] || { echo "resolve_consumer_file failed: $output" >&2; return 1; }
	[ "$output" = "$consumer/.claude/config/platform.sh" ] \
		|| { echo "resolved wrong: got '$output' want" \
			"'$consumer/.claude/config/platform.sh'" >&2; return 1; }
}

@test "bundle: issue-body-lib validates a body naming an agent defined only in a consumer's .claude/agents/ (no ISSUE_BODY_AGENTS_DIR override)" {
	local lib="$REPO_ROOT/plugins/pipeline-core/scripts/issue-body-lib.sh"
	[ -f "$lib" ] || skip "bundle issue-body-lib.sh not present"

	# Consumer repo that ships an agent the bundle itself never ships
	# (plugins/pipeline-core/agents/ does not exist — issue #631).
	local consumer="$TEST_TMP/consumer"
	mkdir -p "$consumer/.claude/agents" "$consumer/src"
	git -C "$consumer" init -q
	printf '# Consumer-only agent\n' \
		> "$consumer/.claude/agents/consumer-only-agent.md"
	: > "$consumer/src/widget.sh"

	local body
	body=$(cat <<'BODY'
## Implementation Tasks

- [ ] `[consumer-only-agent]` **(S)** Do the thing — `src/widget.sh`

## Acceptance Criteria

- AC1: it works
BODY
)

	# Sourced straight from the bundle path, cwd inside the consumer repo,
	# no ISSUE_BODY_AGENTS_DIR override — this is the exact reproduction
	# from issue #631 ("from bundle, no override: unknown agent").
	run env -u ISSUE_BODY_AGENTS_DIR -u PIPELINE_CONFIG_DIR -u CLAUDE_PLUGIN_ROOT \
		bash -c '
			cd "$1" || exit 1
			source "$2"
			assert_issue_valid "$3"
		' _ "$consumer" "$lib" "$body"

	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "bundle-relative regression: an agent defined only in a consumer .claude/agents/ fails validation when no consumer dir is reachable" {
	local lib="$REPO_ROOT/plugins/pipeline-core/scripts/issue-body-lib.sh"
	[ -f "$lib" ] || skip "bundle issue-body-lib.sh not present"

	# Isolated, non-git tmp dir with no .claude/agents/ anywhere reachable —
	# reproduces the pre-fix bug where the agents dir resolved
	# bundle-relative (plugins/pipeline-core/agents/, which the bundle never
	# ships), so a consumer-only agent must still be rejected. Guards against
	# a "resolver failure silently degrades to always-valid" regression.
	local isolated="$TEST_TMP/isolated"
	mkdir -p "$isolated/src"
	: > "$isolated/src/widget.sh"

	local body
	body=$(cat <<'BODY'
## Implementation Tasks

- [ ] `[consumer-only-agent]` **(S)** Do the thing — `src/widget.sh`

## Acceptance Criteria

- AC1: it works
BODY
)

	run env -u ISSUE_BODY_AGENTS_DIR -u PIPELINE_CONFIG_DIR -u CLAUDE_PLUGIN_ROOT \
		bash -c '
			cd "$1" || exit 1
			source "$2"
			assert_issue_valid "$3"
		' _ "$isolated" "$lib" "$body"

	[ "$status" -ne 0 ] \
		|| { echo "expected failure (no consumer agents dir reachable), got success: $output" >&2; return 1; }
	[[ "$output" == *"unknown agent: consumer-only-agent"* ]] \
		|| { echo "expected 'unknown agent' diagnostic, got: $output" >&2; return 1; }
}

@test "bundle: implement-issue-orchestrator.sh loud-aborts when platform.sh cannot be resolved" {
	local orch="$REPO_ROOT/plugins/pipeline-core/scripts/implement-issue-orchestrator.sh"
	[ -f "$orch" ] || { echo "orchestrator missing: $orch" >&2; return 1; }

	# Isolated, non-git tmp dir with no PIPELINE_CONFIG_DIR override and no
	# reachable .claude/config/platform.sh — all three resolve_consumer_file()
	# lookup paths must miss, and the orchestrator must abort loudly instead
	# of silently continuing with no platform config (issue #614 AC1/AC4).
	run env -u PIPELINE_CONFIG_DIR -u CLAUDE_PLUGIN_ROOT \
		bash -c 'cd "$1" && exec "$2"' _ "$TEST_TMP" "$orch"

	[ "$status" -ne 0 ] \
		|| { echo "expected non-zero exit, got 0: $output" >&2; return 1; }
	[[ "$output" == *"platform.sh"* ]] \
		|| { echo "expected FATAL platform.sh message, got: $output" >&2; return 1; }
}

# ===========================================================================
# bin entrypoints — self-locating wrappers on the Bash-tool PATH (issue #599 Task 5)
#
# When pipeline-core is enabled its bin/ dir is added to PATH by convention, so
# skills invoke bundled scripts by prefixed name (pipeline-core-*). Each wrapper
# self-locates its sibling scripts/ dir via ${BASH_SOURCE[0]} — CLAUDE_PLUGIN_ROOT
# is NOT set in the model's Bash-tool shell (Task 1 finding), so it cannot be used.
# Skills use a dual-mode guard so they also work repo-local (no plugin):
#   X="$(command -v pipeline-core-<name> || echo .claude/scripts/<orch>.sh)"; "$X" ...
# ===========================================================================

# The distinct bin entrypoints and the sibling script each must exec.
_bin_entrypoints() {
	cat <<'MAP'
pipeline-core-implement|implement-issue-orchestrator.sh
pipeline-core-batch|batch-orchestrator.sh
pipeline-core-create-followup-issue|create-followup-issue.sh
pipeline-core-feedback-record|feedback-record.sh
pipeline-core-skill-golden|skill-golden.sh
pipeline-core-capture-usage-fixture|capture-usage-fixture.sh
MAP
}

@test "bin: every pipeline-core-* wrapper exists and is executable" {
	local bin_dir="$REPO_ROOT/plugins/pipeline-core/bin"
	[ -d "$bin_dir" ] || { echo "bin dir missing: $bin_dir" >&2; return 1; }

	local name script
	while IFS='|' read -r name script; do
		[ -n "$name" ] || continue
		[ -f "$bin_dir/$name" ] || { echo "missing wrapper: $name" >&2; return 1; }
		[ -x "$bin_dir/$name" ] || { echo "not executable: $name" >&2; return 1; }
	done < <(_bin_entrypoints)

	# The platform-dir resolver is also required.
	[ -x "$bin_dir/pipeline-core-platform-dir" ] \
		|| { echo "missing/not executable: pipeline-core-platform-dir" >&2; return 1; }
}

@test "bin: exec wrappers self-locate scripts/<orch>.sh via BASH_SOURCE and pass args" {
	local bin_dir="$REPO_ROOT/plugins/pipeline-core/bin"
	local name script
	while IFS='|' read -r name script; do
		[ -n "$name" ] || continue

		# Build a stub plugin layout: bin/<wrapper> + scripts/<orch>.sh (stub).
		local stub="$TEST_TMP/$name"
		mkdir -p "$stub/bin" "$stub/scripts"
		cp "$bin_dir/$name" "$stub/bin/$name"
		printf '#!/usr/bin/env bash\necho "RAN:%s args=$*"\n' "$script" \
			> "$stub/scripts/$script"
		chmod +x "$stub/scripts/$script"

		# Run from an unrelated cwd so resolution can only come from BASH_SOURCE.
		run bash -c 'cd / && "$1" --issue 7 --branch main' _ "$stub/bin/$name"
		[ "$status" -eq 0 ] || { echo "$name failed: $output" >&2; return 1; }
		[[ "$output" == "RAN:$script args=--issue 7 --branch main" ]] \
			|| { echo "$name resolved wrong: $output" >&2; return 1; }
	done < <(_bin_entrypoints)
}

@test "bin: pipeline-core-platform-dir prints the self-located scripts/platform dir" {
	local bin_dir="$REPO_ROOT/plugins/pipeline-core/bin"
	local stub="$TEST_TMP/platform"
	mkdir -p "$stub/bin" "$stub/scripts/platform"
	cp "$bin_dir/pipeline-core-platform-dir" "$stub/bin/"

	run bash -c 'cd / && "$1"' _ "$stub/bin/pipeline-core-platform-dir"
	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
	[ "$output" = "$stub/scripts/platform" ] \
		|| { echo "got: $output want: $stub/scripts/platform" >&2; return 1; }
}

@test "skills: no bundle skill has a bare .claude/scripts/*.sh invocation without a guard" {
	local skills_dir="$REPO_ROOT/plugins/pipeline-core/skills"
	[ -d "$skills_dir" ] || skip "bundle skills not present"

	# Command-position invocation: line starts (after optional ws / nohup / quote /
	# leading $) with .claude/scripts/....sh. Prose, tables, and dual-mode guards
	# (which reference the path only after `echo`) are not command-position, so they
	# do not match. Any match is an un-guarded hardcoded invocation and must fail.
	run grep -rnE '^[[:space:]]*(nohup[[:space:]]+)?"?\$?\.claude/scripts/[^ ]*\.sh' \
		"$skills_dir"
	[ "$status" -ne 0 ] \
		|| { echo "bare .claude/scripts invocation(s) found:" >&2; echo "$output" >&2; return 1; }
}

@test "skills: no bundle skill runs a bundled script via \${CLAUDE_PLUGIN_ROOT} (unset in Bash-tool shell)" {
	local skills_dir="$REPO_ROOT/plugins/pipeline-core/skills"
	[ -d "$skills_dir" ] || skip "bundle skills not present"

	run grep -rnE 'CLAUDE_PLUGIN_ROOT' "$skills_dir"
	[ "$status" -ne 0 ] \
		|| { echo "CLAUDE_PLUGIN_ROOT used in a skill (use a pipeline-core-* bin instead):" >&2; echo "$output" >&2; return 1; }
}

@test "bundle: no bundled script hardcodes ../config/platform.sh" {
	local scripts_dir="$REPO_ROOT/plugins/pipeline-core/scripts"
	[ -d "$scripts_dir" ] || skip "bundle scripts not present"

	# The bundle ships no config/ dir, so "$SCRIPT_DIR/../config/platform.sh"
	# resolves inside the plugin cache and misses. The unguarded form errors;
	# the [[ -f ]]-guarded form fails open, leaving TRACKER, GIT_CLI,
	# DEPLOY_VERIFY_CMD and the MAX_* caps unset instead of defaulted — a
	# silent deploy-verify skip. Everything must route through
	# resolve_consumer_file() instead.
	run grep -rnE 'SCRIPT_DIR/(\.\./)+config/platform\.sh' \
		--include='*.sh' "$scripts_dir"
	[ "$status" -ne 0 ] \
		|| { echo "hardcoded platform.sh source in bundled script(s):" >&2; echo "$output" >&2; return 1; }
}

@test "bundle: platform scripts resolve config and abort loudly when it is missing" {
	local rd="$REPO_ROOT/plugins/pipeline-core/scripts/platform/read-issue.sh"
	[ -f "$rd" ] || skip "read-issue.sh not present"

	grep -q 'resolve_consumer_file platform.sh' "$rd" \
		|| { echo "read-issue.sh does not use resolve_consumer_file" >&2; return 1; }

	# In an isolated non-git dir with no override and no reachable
	# .claude/config/platform.sh, all three lookup paths must miss and the
	# script must exit non-zero naming platform.sh — never continue unset.
	run env -u PIPELINE_CONFIG_DIR -u CLAUDE_PLUGIN_ROOT \
		bash -c 'cd "$1" && exec "$2" 123' _ "$TEST_TMP" "$rd"

	[ "$status" -ne 0 ] \
		|| { echo "expected non-zero exit when platform.sh unresolvable, got 0: $output" >&2; return 1; }
	[[ "$output" == *"platform.sh"* ]] \
		|| { echo "expected FATAL platform.sh message, got: $output" >&2; return 1; }
}

# ===========================================================================
# Pipeline hooks ship in the plugin (issue #640). Migrating a consumer to
# pipeline-core used to silently disable its guardrails: hooks.json registered
# only scaffold-placeholder and post-pr-simplify, so the issue-body guard, the
# status injector and the SKILL.md validator never reached a plugin consumer.
# stevegrocott/beegee-farm-3 — the one already-migrated repo — ran a no-op
# pre-commit-skill-validate.sh from the day it migrated, because the hook
# resolved its validator to .claude/scripts/skill-validate.sh, a path the
# migration removes, and then `[[ -f ... ]] || exit 0` failed open in silence.
#
# These tests drive the REAL bundled hook scripts with CLAUDE_PROJECT_DIR
# pointed at a consumer tree that has NO .claude/scripts/ and NO .claude/hooks/,
# and with CLAUDE_PLUGIN_ROOT unset (it is not set in the model's Bash-tool
# shell — issue #599 Task 1 finding), which is the exact shape of a migrated
# consumer.
# ===========================================================================

# Build a consumer repo that has adopted the plugin: a project dir with no
# .claude/scripts/ and no .claude/hooks/ at all. Echoes the consumer root.
_build_plugin_consumer() {
	local root="$1/consumer"
	mkdir -p "$root/.claude/skills" "$root/src"
	printf '%s\n' '{}' > "$root/.claude/settings.json"
	printf '%s\n' "$root"
}

# Echo a PreToolUse Write payload for $1 (file path) with body $2.
_write_payload() {
	python3 -c '
import json, sys
print(json.dumps({
    "tool_name": "Write",
    "tool_input": {"file_path": sys.argv[1], "content": sys.argv[2]},
}))' "$1" "$2"
}

@test "plugin hooks: hooks.json registers the issue-creation, status and skill-validation guards" {
	local core
	core="$(_find_plugin_core "$REPO_ROOT")" \
		|| skip "plugins/pipeline-core not created yet"
	local manifest="$core/hooks/hooks.json"
	[ -f "$manifest" ] || { echo "hooks.json not found: $manifest" >&2; return 1; }

	jq empty "$manifest" 2>/dev/null \
		|| { echo "hooks.json is not valid JSON: $manifest" >&2; return 1; }

	# event:script pairs a plugin consumer must receive.
	local -a required=(
		"PreToolUse:block-gh-issue-create.sh"
		"PreToolUse:pre-commit-skill-validate.sh"
		"UserPromptSubmit:pipeline-status-inject.sh"
	)

	local entry event script missing=""
	for entry in "${required[@]}"; do
		event="${entry%%:*}"
		script="${entry#*:}"
		jq -e --arg e "$event" --arg s "$script" \
			'.hooks[$e] // [] | map(.hooks[].command) | flatten
			 | map(select(endswith($s))) | length > 0' \
			"$manifest" >/dev/null 2>&1 \
			|| missing+=$'\n'"  $event -> $script"
	done

	[ -z "$missing" ] \
		|| { echo "hooks.json does not register:$missing" >&2; return 1; }

	# Every registered command must resolve to a real executable script.
	run _validate_hooks "$core"
	[ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "plugin consumer: the bundled issue-creation guard blocks a direct gh issue create" {
	local hook="$REPO_ROOT/plugins/pipeline-core/hooks/scripts/block-gh-issue-create.sh"
	[ -f "$hook" ] \
		|| { echo "bundled hook missing: $hook" >&2; return 1; }

	local consumer
	consumer="$(_build_plugin_consumer "$TEST_TMP")"

	local payload
	payload="$(python3 -c '
import json
print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": "gh issue create --title x --body y"},
}))')"

	run env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$consumer" \
		bash -c 'cd "$1" && printf "%s" "$3" | "$2"' \
		_ "$consumer" "$hook" "$payload"

	[ "$status" -eq 2 ] \
		|| { echo "expected exit 2 (blocked), got $status: $output" >&2; return 1; }
}

@test "plugin consumer: the bundled issue-creation guard allows the validated wrapper script" {
	local hook="$REPO_ROOT/plugins/pipeline-core/hooks/scripts/block-gh-issue-create.sh"
	[ -f "$hook" ] \
		|| { echo "bundled hook missing: $hook" >&2; return 1; }

	local consumer
	consumer="$(_build_plugin_consumer "$TEST_TMP")"

	local payload
	payload="$(python3 -c '
import json
print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": "pipeline-core-create-issue --title x"},
}))')"

	run env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$consumer" \
		bash -c 'cd "$1" && printf "%s" "$3" | "$2"' \
		_ "$consumer" "$hook" "$payload"

	[ "$status" -eq 0 ] \
		|| { echo "expected exit 0 (allowed), got $status: $output" >&2; return 1; }
}

@test "plugin consumer: the bundled skill validator resolves from the plugin and BLOCKS invalid frontmatter" {
	local hook="$REPO_ROOT/plugins/pipeline-core/hooks/scripts/pre-commit-skill-validate.sh"
	[ -f "$hook" ] \
		|| { echo "bundled hook missing: $hook" >&2; return 1; }
	[ -f "$REPO_ROOT/plugins/pipeline-core/scripts/skill-validate.sh" ] \
		|| { echo "bundle ships no skill-validate.sh" >&2; return 1; }

	local consumer
	consumer="$(_build_plugin_consumer "$TEST_TMP")"
	[ ! -e "$consumer/.claude/scripts" ] \
		|| { echo "consumer fixture must have no .claude/scripts/" >&2; return 1; }

	# Frontmatter missing every schema-required field but name/description —
	# skill-validate.sh rejects it, so the hook must exit 2.
	local payload
	payload="$(_write_payload "$consumer/.claude/skills/broken/SKILL.md" \
		'---
name: broken
---

Body.
')"

	run env -u CLAUDE_PLUGIN_ROOT -u SKILL_VALIDATE_SCRIPT \
		CLAUDE_PROJECT_DIR="$consumer" \
		bash -c 'cd "$1" && printf "%s" "$3" | "$2"' \
		_ "$consumer" "$hook" "$payload"

	# The beegee-farm-3 regression: status 0 here means the validator was
	# never found and the hook failed open in silence.
	[ "$status" -eq 2 ] \
		|| { echo "expected exit 2 (blocked); got $status — validator did not resolve from the plugin bundle. output: $output" >&2; return 1; }
	[[ "$output" == *"broken"* ]] \
		|| { echo "expected the skill name in the block message, got: $output" >&2; return 1; }
}

@test "plugin consumer: the bundled skill validator ALLOWS valid frontmatter" {
	local hook="$REPO_ROOT/plugins/pipeline-core/hooks/scripts/pre-commit-skill-validate.sh"
	[ -f "$hook" ] \
		|| { echo "bundled hook missing: $hook" >&2; return 1; }

	local consumer
	consumer="$(_build_plugin_consumer "$TEST_TMP")"

	# Positive control — proves the previous test's exit 2 comes from the
	# frontmatter being invalid, not from the hook blocking every SKILL.md.
	local payload
	payload="$(_write_payload "$consumer/.claude/skills/good-skill/SKILL.md" \
		'---
name: good-skill
description: Use when the bundled validator must accept a well-formed skill
inputs:
  - name: target
    type: string
outputs:
  - name: result
    type: string
side_effects:
  - none
composes:
  - mcp-tools
failure_modes:
  - id: boom
    mitigation: surface the error
---

Body.
')"

	run env -u CLAUDE_PLUGIN_ROOT -u SKILL_VALIDATE_SCRIPT \
		CLAUDE_PROJECT_DIR="$consumer" \
		bash -c 'cd "$1" && printf "%s" "$3" | "$2"' \
		_ "$consumer" "$hook" "$payload"

	[ "$status" -eq 0 ] \
		|| { echo "expected exit 0 (allowed), got $status: $output" >&2; return 1; }
}

@test "plugin consumer: the bundled status injector reads the consumer status.json" {
	local hook="$REPO_ROOT/plugins/pipeline-core/hooks/scripts/pipeline-status-inject.sh"
	[ -f "$hook" ] \
		|| { echo "bundled hook missing: $hook" >&2; return 1; }

	local consumer
	consumer="$(_build_plugin_consumer "$TEST_TMP")"
	printf '%s\n' \
		'{"state":"running","issue":"640","stage":"implement"}' \
		> "$consumer/status.json"

	run env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$consumer" \
		bash -c 'cd "$1" && "$2" </dev/null' _ "$consumer" "$hook"

	[ "$status" -eq 0 ] \
		|| { echo "expected exit 0, got $status: $output" >&2; return 1; }
	[[ "$output" == *"640"* ]] \
		|| { echo "expected the running issue in the injected context, got: $output" >&2; return 1; }
}
