#!/usr/bin/env bats
#
# test-bundle-parity.bats
# Bundle parity guard (issue #623) — the repo maintains two hand-edited
# copies of every pipeline script: .claude/scripts/ (what this repo's own
# pipeline runs) and plugins/pipeline-core/scripts/ (what consumers install
# via the plugin bundle). Nothing enforced agreement between them: v0.3.0
# was tagged and installed with a bundled orchestrator that did not contain
# the turn-budget fix from #619, because the fix had landed only in
# .claude/scripts/. This test diffs every *.sh pair by basename and reports
# drift instead of letting it ship silently.

bats_require_minimum_version 1.5.0

load 'helpers/test-helper.bash'

# SCRIPT_DIR (set by test-helper.bash) is .claude/scripts — the canonical
# tree. Repo root is two levels up (.claude/scripts -> .claude -> repo root).
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUNDLE_DIR="$REPO_ROOT/plugins/pipeline-core/scripts"

# Subdirectories checked in addition to top-level *.sh. Kept in lockstep with
# BUNDLE_SCRIPT_SUBDIRS in sync.sh's bundle_scripts() — both lists must name
# the same directories or the generator and this guard silently diverge on
# scope again. platform/ is where PR #624's drift shipped, so it must stay
# covered here, not just at the top level.
PARITY_SUBDIRS=(platform prompts schemas)

# Print, one per line, every file under $1 that this guard is responsible
# for: top-level *.sh, plus every file (any extension) under each of
# PARITY_SUBDIRS, as a path relative to $1.
_parity_relpaths() {
	local root="$1"
	local script sub

	for script in "$root"/*.sh; do
		[[ -f "$script" ]] || continue
		printf '%s\n' "${script#"$root"/}"
	done

	for sub in "${PARITY_SUBDIRS[@]}"; do
		[[ -d "$root/$sub" ]] || continue
		while IFS= read -r script; do
			printf '%s\n' "${script#"$root"/}"
		done < <(find "$root/$sub" -type f | sort)
	done
}

@test "bundle parity: every canonical script matches its plugins/pipeline-core/scripts counterpart" {
	[[ -d "$BUNDLE_DIR" ]] || fail "bundle directory not found: $BUNDLE_DIR"

	local report="" rel canonical counterpart pair_diff
	while IFS= read -r rel; do
		canonical="$SCRIPT_DIR/$rel"
		counterpart="$BUNDLE_DIR/$rel"

		if [[ ! -f "$counterpart" ]]; then
			report+=$'\n'"MISSING: $rel has no counterpart in plugins/pipeline-core/scripts/"
			continue
		fi

		diff -q "$canonical" "$counterpart" >/dev/null 2>&1 && continue

		pair_diff="$(diff -u "$counterpart" "$canonical")" || true
		report+=$'\n'"DIFF: $rel"$'\n'"$pair_diff"
	done < <(_parity_relpaths "$SCRIPT_DIR")

	local msg="canonical/bundle drift detected — run ./sync.sh bundle to"
	msg+=" regenerate the bundle from canonical, then review and commit"
	msg+=" the result:$report"
	[[ -z "$report" ]] || fail "$msg"
}

@test "bundle parity: every bundled script has a canonical counterpart" {
	local rel
	while IFS= read -r rel; do
		[[ -f "$SCRIPT_DIR/$rel" ]] || \
			fail "bundled file $rel has no canonical counterpart in .claude/scripts/"
	done < <(_parity_relpaths "$BUNDLE_DIR")
}

# =============================================================================
# Syntax guard (AC3) — a diff test only catches drift from the canonical
# tree; it says nothing about whether the shipped bundle actually parses.
# Run `bash -n` over every bundled script so a syntax error in
# plugins/pipeline-core/scripts/ fails CI instead of shipping in a tag.
# =============================================================================

@test "bundle syntax: every plugins/pipeline-core/scripts/**/*.sh passes bash -n" {
	local report="" script syntax_error

	while IFS= read -r script; do
		syntax_error="$(bash -n "$script" 2>&1)" && continue
		report+=$'\n'"SYNTAX ERROR: ${script#"$REPO_ROOT"/}"$'\n'"$syntax_error"
	done < <(find "$BUNDLE_DIR" -name '*.sh' -type f | sort)

	[[ -z "$report" ]] || fail "bash -n failed on the bundled tree:$report"
}

# =============================================================================
# Hook parity (issue #640)
#
# plugins/pipeline-core/hooks/scripts/ was a HAND-MAINTAINED copy with nothing
# enforcing agreement with .claude/hooks/. post-pr-simplify.sh was byte-
# identical across the two trees by luck, not by enforcement — exactly the
# situation #623 found for the 27 script pairs just before it shipped a broken
# release. Shipping more hooks into that unguarded tree would recreate the
# drift bug in a new location, so these guards land WITH the hooks.
#
# Which hooks ship is an explicit ALLOWLIST, not "whatever is in the dir":
# only pipeline-owned guardrails belong in a consumer's plugin install. The
# NOT-shipped set is named just as explicitly, so a hook added to
# .claude/hooks/ later and forgotten surfaces as an unclassified-hook failure
# instead of silently never reaching consumers.
# =============================================================================

HOOKS_DIR="$REPO_ROOT/.claude/hooks"
BUNDLE_HOOKS_DIR="$REPO_ROOT/plugins/pipeline-core/hooks/scripts"
PLUGIN_HOOKS_JSON="$REPO_ROOT/plugins/pipeline-core/hooks/hooks.json"

# Pipeline-owned hooks that ship in the plugin. Kept in lockstep with
# BUNDLE_HOOKS in sync.sh — enforced by the "allowlists agree" test below,
# not merely by comment, because a comment is what let scope drift last time.
PARITY_BUNDLE_HOOKS=(
	block-gh-issue-create.sh
	pipeline-status-inject.sh
	post-pr-simplify.sh
	pre-commit-skill-validate.sh
)

# Hooks in .claude/hooks/ that deliberately do NOT ship (issue #640):
#   block-destructive-db-commands.sh  DB safety; not every consumer has a DB
#   rtk-rewrite.sh                    rewrites commands through project tooling
#   session-start.sh                  project-local session banner; unwired
#   sync-reminder.sh                  RETIRED for plugin consumers — reminds
#                                     you to sync core pipeline changes, which
#                                     is meaningless once the plugin IS the
#                                     source of those files
# Kept in lockstep with PROJECT_LOCAL_HOOKS in sync.sh.
PARITY_PROJECT_LOCAL_HOOKS=(
	block-destructive-db-commands.sh
	rtk-rewrite.sh
	session-start.sh
	sync-reminder.sh
)

# Hooks that exist ONLY in the bundle and have no .claude/hooks/ counterpart
# by design. Kept in lockstep with PLUGIN_ONLY_HOOKS in sync.sh.
PARITY_PLUGIN_ONLY_HOOKS=(
	scaffold-placeholder.sh
)

# True when $1 appears in the remaining arguments.
_hook_in() {
	local needle="$1"
	shift
	local item
	for item in "$@"; do
		if [[ "$item" == "$needle" ]]; then
			return 0
		fi
	done
	return 1
}

# Print the elements of a literal bash array assignment in sync.sh, one per
# line. Handles both the single-line and one-entry-per-line forms and strips
# trailing comments, so the lockstep check reads sync.sh's real allowlist
# rather than a second copy of it maintained here.
_sync_array() {
	awk -v name="$1" '
		index($0, name "=(") == 1 { inside = 1; sub(/^[^(]*\(/, "") }
		inside {
			line = $0
			sub(/#.*/, "", line)
			closing = (index(line, ")") > 0)
			sub(/\).*/, "", line)
			n = split(line, parts, /[ \t]+/)
			for (i = 1; i <= n; i++) {
				if (parts[i] != "") print parts[i]
			}
			if (closing) exit
		}
	' "$REPO_ROOT/sync.sh"
}

@test "hook parity: every allowlisted hook matches its plugins/pipeline-core/hooks/scripts counterpart" {
	[[ -d "$BUNDLE_HOOKS_DIR" ]] || \
		fail "bundled hooks directory not found: $BUNDLE_HOOKS_DIR"

	local report="" hook canonical counterpart pair_diff
	for hook in "${PARITY_BUNDLE_HOOKS[@]}"; do
		canonical="$HOOKS_DIR/$hook"
		counterpart="$BUNDLE_HOOKS_DIR/$hook"

		if [[ ! -f "$canonical" ]]; then
			report+=$'\n'"MISSING CANONICAL: .claude/hooks/$hook is on the"
			report+=" bundle allowlist but does not exist"
			continue
		fi
		if [[ ! -f "$counterpart" ]]; then
			report+=$'\n'"MISSING: $hook has no counterpart in"
			report+=" plugins/pipeline-core/hooks/scripts/"
			continue
		fi

		diff -q "$canonical" "$counterpart" >/dev/null 2>&1 && continue

		pair_diff="$(diff -u "$counterpart" "$canonical")" || true
		report+=$'\n'"DIFF: $hook"$'\n'"$pair_diff"
	done

	local msg="canonical/bundle hook drift detected — run ./sync.sh bundle"
	msg+=" to regenerate the bundled hooks from .claude/hooks/, then review"
	msg+=" and commit the result:$report"
	[[ -z "$report" ]] || fail "$msg"
}

@test "hook parity: every bundled hook is allowlisted and has a canonical counterpart" {
	[[ -d "$BUNDLE_HOOKS_DIR" ]] || \
		fail "bundled hooks directory not found: $BUNDLE_HOOKS_DIR"

	local report="" bundled base
	for bundled in "$BUNDLE_HOOKS_DIR"/*; do
		[[ -f "$bundled" ]] || continue
		base="${bundled##*/}"

		if _hook_in "$base" "${PARITY_PLUGIN_ONLY_HOOKS[@]}"; then
			continue
		fi
		if ! _hook_in "$base" "${PARITY_BUNDLE_HOOKS[@]}"; then
			report+=$'\n'"UNEXPECTED: bundled hook $base is on no allowlist"
			report+=" — add it to PARITY_BUNDLE_HOOKS (and sync.sh's"
			report+=" BUNDLE_HOOKS) or PARITY_PLUGIN_ONLY_HOOKS, or delete it"
			continue
		fi
		if [[ ! -f "$HOOKS_DIR/$base" ]]; then
			report+=$'\n'"ORPHAN: bundled hook $base has no canonical"
			report+=" counterpart in .claude/hooks/"
		fi
	done

	[[ -z "$report" ]] || fail "bundled hooks tree is not generated from .claude/hooks/:$report"
}

@test "hook parity: every .claude/hooks script is classified as bundled or project-local" {
	local report="" hook base
	for hook in "$HOOKS_DIR"/*.sh; do
		[[ -f "$hook" ]] || continue
		base="${hook##*/}"

		if _hook_in "$base" "${PARITY_BUNDLE_HOOKS[@]}"; then
			continue
		fi
		if _hook_in "$base" "${PARITY_PROJECT_LOCAL_HOOKS[@]}"; then
			continue
		fi
		report+=$'\n'"UNCLASSIFIED: .claude/hooks/$base is neither on the"
		report+=" bundle allowlist nor named project-local — decide whether"
		report+=" plugin consumers need it and add it to PARITY_BUNDLE_HOOKS"
		report+=" or PARITY_PROJECT_LOCAL_HOOKS (and the matching sync.sh list)"
	done

	[[ -z "$report" ]] || fail "unclassified pipeline hook(s):$report"
}

@test "hook parity: sync.sh hook allowlists agree with this guard" {
	local report="" name expected actual
	local -a pairs=(
		"BUNDLE_HOOKS:${PARITY_BUNDLE_HOOKS[*]}"
		"PROJECT_LOCAL_HOOKS:${PARITY_PROJECT_LOCAL_HOOKS[*]}"
		"PLUGIN_ONLY_HOOKS:${PARITY_PLUGIN_ONLY_HOOKS[*]}"
	)

	local pair
	for pair in "${pairs[@]}"; do
		name="${pair%%:*}"
		expected="$(printf '%s\n' ${pair#*:} | sort)"
		actual="$(_sync_array "$name" | sort)"
		if [[ "$actual" != "$expected" ]]; then
			report+=$'\n'"$name: sync.sh has [$(printf '%s ' $actual)]"
			report+=" but this guard has [$(printf '%s ' $expected)]"
		fi
	done

	local msg="sync.sh's generator and this parity guard disagree on hook"
	msg+=" scope — they must name the same hooks or the bundle silently"
	msg+=" diverges again (issue #623/#640):$report"
	[[ -z "$report" ]] || fail "$msg"
}

@test "hook parity: project-local and retired hooks are not shipped to plugin consumers" {
	local report="" hook manifest=""
	[[ -f "$PLUGIN_HOOKS_JSON" ]] && manifest="$(cat "$PLUGIN_HOOKS_JSON")"

	for hook in "${PARITY_PROJECT_LOCAL_HOOKS[@]}"; do
		if [[ -f "$BUNDLE_HOOKS_DIR/$hook" ]]; then
			report+=$'\n'"SHIPPED: $hook is project-local/retired but exists"
			report+=" in plugins/pipeline-core/hooks/scripts/"
		fi
		if [[ "$manifest" == *"$hook"* ]]; then
			report+=$'\n'"REGISTERED: $hook is project-local/retired but is"
			report+=" referenced by plugins/pipeline-core/hooks/hooks.json"
		fi
	done

	[[ -z "$report" ]] || fail "non-shippable hook reached the plugin:$report"
}

@test "bundle syntax: every plugins/pipeline-core/hooks/scripts/*.sh passes bash -n" {
	local report="" script syntax_error

	while IFS= read -r script; do
		syntax_error="$(bash -n "$script" 2>&1)" && continue
		report+=$'\n'"SYNTAX ERROR: ${script#"$REPO_ROOT"/}"$'\n'"$syntax_error"
	done < <(find "$BUNDLE_HOOKS_DIR" -name '*.sh' -type f | sort)

	[[ -z "$report" ]] || fail "bash -n failed on the bundled hooks tree:$report"
}
