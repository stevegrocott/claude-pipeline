#!/usr/bin/env bats
#
# tests/sync-patch-agents.bats
# patch_agents() in sync.sh strips <!-- STACK-SPECIFIC: --> from line 1 of
# consumer .claude/agents/*.md files; leaves clean files and mid-file HTML
# comments untouched.
#
# Acceptance criteria (issue #568 task 2):
#   AC1: sync.sh to <project> strips <!-- STACK-SPECIFIC: --> from line 1
#   AC2: sync.sh to <project> does not modify files whose line 1 is ---
#   AC3: sync.sh to <project> does not strip HTML comments after line 1
#   AC4: these BATS tests cover all three cases and pass
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SYNC_SH="$REPO_ROOT/sync.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Minimal consumer structure required by resolve_project_dir in sync.sh.
	mkdir -p "$TEST_TMP/.claude/agents"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Reference implementation — pins the patch_agents contract independently of
# whether sync.sh has been updated yet.  POSIX-safe: uses tail, not sed -i.
# ---------------------------------------------------------------------------

_ref_patch_agents_dir() {
	local agents_dir="$1"
	local file first_line tmp

	for file in "$agents_dir"/*.md; do
		[[ -f "$file" ]] || continue
		IFS= read -r first_line < "$file"
		case "$first_line" in
			'<!-- STACK-SPECIFIC:'*)
				tmp=$(mktemp)
				tail -n +2 "$file" > "$tmp"
				mv "$tmp" "$file"
				;;
		esac
	done
}

# =============================================================================
# Reference tests — exercise the contract directly; always pass once written.
# =============================================================================

# ---------------------------------------------------------------------------
# AC2 — clean files are a no-op
# ---------------------------------------------------------------------------

@test "(ref AC2) clean agent file starting with --- is unchanged" {
	local agents_dir="$TEST_TMP/agents"
	mkdir -p "$agents_dir"
	printf '%s\n' '---' 'name: my-agent' '---' > "$agents_dir/clean.md"

	_ref_patch_agents_dir "$agents_dir"

	local first_line
	IFS= read -r first_line < "$agents_dir/clean.md"
	[[ "$first_line" == "---" ]] || {
		printf 'FAIL: clean file modified; line 1 is: %s\n' \
			"$first_line" >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# AC1 — broken files are stripped
# ---------------------------------------------------------------------------

@test "(ref AC1) <!-- STACK-SPECIFIC: --> at line 1 is stripped" {
	local agents_dir="$TEST_TMP/agents"
	mkdir -p "$agents_dir"
	printf \
		'<!-- STACK-SPECIFIC: for custom stack -->\n---\nname: my-agent\n---\n' \
		> "$agents_dir/broken.md"

	_ref_patch_agents_dir "$agents_dir"

	local first_line
	IFS= read -r first_line < "$agents_dir/broken.md"
	[[ "$first_line" == "---" ]] || {
		printf 'FAIL: first line after patch: %s (expected ---)\n' \
			"$first_line" >&2
		return 1
	}
}

@test "(ref AC1) body content is preserved after the comment is stripped" {
	local agents_dir="$TEST_TMP/agents"
	mkdir -p "$agents_dir"
	printf \
		'<!-- STACK-SPECIFIC: for custom stack -->\n---\nname: my-agent\n---\n' \
		> "$agents_dir/broken.md"

	_ref_patch_agents_dir "$agents_dir"

	grep -q 'name: my-agent' "$agents_dir/broken.md" || {
		printf 'FAIL: body content was lost after stripping the comment\n' >&2
		return 1
	}
}

@test "(ref) patch is idempotent — clean result is unchanged on second run" {
	local agents_dir="$TEST_TMP/agents"
	mkdir -p "$agents_dir"
	printf \
		'<!-- STACK-SPECIFIC: for custom stack -->\n---\nname: my-agent\n---\n' \
		> "$agents_dir/broken.md"

	_ref_patch_agents_dir "$agents_dir"   # first run: strips comment
	_ref_patch_agents_dir "$agents_dir"   # second run: should be no-op

	local first_line
	IFS= read -r first_line < "$agents_dir/broken.md"
	[[ "$first_line" == "---" ]] || {
		printf 'FAIL: second run changed the file; line 1 is: %s\n' \
			"$first_line" >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# AC3 — mid-file HTML comments are untouched
# ---------------------------------------------------------------------------

@test "(ref AC3) mid-file <!-- STACK-SPECIFIC: --> comment is NOT stripped" {
	local agents_dir="$TEST_TMP/agents"
	mkdir -p "$agents_dir"
	printf '%s\n' \
		'---' \
		'name: my-agent' \
		'---' \
		'' \
		'<!-- STACK-SPECIFIC: customize here -->' \
		> "$agents_dir/midfile.md"

	_ref_patch_agents_dir "$agents_dir"

	grep -qF '<!-- STACK-SPECIFIC: customize here -->' \
		"$agents_dir/midfile.md" || {
		printf 'FAIL: mid-file comment was removed\n' >&2
		return 1
	}
}

@test "(ref AC3) mid-file comment file still starts with ---" {
	local agents_dir="$TEST_TMP/agents"
	mkdir -p "$agents_dir"
	printf '%s\n' \
		'---' \
		'name: my-agent' \
		'---' \
		'' \
		'<!-- STACK-SPECIFIC: customize here -->' \
		> "$agents_dir/midfile.md"

	_ref_patch_agents_dir "$agents_dir"

	local first_line
	IFS= read -r first_line < "$agents_dir/midfile.md"
	[[ "$first_line" == "---" ]] || {
		printf 'FAIL: line 1 changed to: %s\n' "$first_line" >&2
		return 1
	}
}

# =============================================================================
# Structural — sync.sh must define patch_agents and wire it into the to handler.
# These fail RED until issue #568 task 1 lands.
# =============================================================================

@test "sync.sh defines a patch_agents function" {
	[[ -f "$SYNC_SH" ]] || fail "sync.sh not present"

	grep -qE '^patch_agents\(\) \{' "$SYNC_SH" || {
		printf 'FAIL: patch_agents() not defined in sync.sh\n' >&2
		return 1
	}
}

@test "sync.sh to handler calls patch_agents" {
	[[ -f "$SYNC_SH" ]] || fail "sync.sh not present"

	# Extract lines inside the to) case block and confirm patch_agents is there.
	awk '/^[[:space:]]+to\)/{f=1} f{print} /^[[:space:]]+;;/{f=0}' \
		"$SYNC_SH" | grep -q 'patch_agents' || {
		printf \
			'FAIL: to) handler in sync.sh does not call patch_agents\n' >&2
		return 1
	}
}

# =============================================================================
# Integration — call sync.sh to and verify agent files are handled correctly.
# AC2/AC3: verify no unintended damage (pass before and after task 1 lands).
# AC1:     verify patching occurs (RED until task 1 lands).
# =============================================================================

@test "(AC2) sync.sh to leaves clean agent files unchanged" {
	[[ -f "$SYNC_SH" ]] || fail "sync.sh not present"
	printf '%s\n' '---' 'name: my-agent' '---' \
		> "$TEST_TMP/.claude/agents/clean.md"

	run bash "$SYNC_SH" to "$TEST_TMP"
	[ "$status" -eq 0 ] || {
		printf 'sync.sh to exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	local first_line
	IFS= read -r first_line < "$TEST_TMP/.claude/agents/clean.md"
	[[ "$first_line" == "---" ]] || {
		printf 'FAIL: clean file modified; line 1 is: %s\n' \
			"$first_line" >&2
		return 1
	}
}

@test "(AC1) sync.sh to strips <!-- STACK-SPECIFIC: --> from broken agent files" {
	[[ -f "$SYNC_SH" ]] || fail "sync.sh not present"
	printf \
		'<!-- STACK-SPECIFIC: for custom stack -->\n---\nname: my-agent\n---\n' \
		> "$TEST_TMP/.claude/agents/broken.md"

	run bash "$SYNC_SH" to "$TEST_TMP"
	[ "$status" -eq 0 ] || {
		printf 'sync.sh to exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	local first_line
	IFS= read -r first_line < "$TEST_TMP/.claude/agents/broken.md"
	[[ "$first_line" == "---" ]] || {
		printf 'FAIL: first line after sync: %s (expected ---)\n' \
			"$first_line" >&2
		return 1
	}
}

@test "(AC3) sync.sh to does not strip mid-file <!-- STACK-SPECIFIC: --> comments" {
	[[ -f "$SYNC_SH" ]] || fail "sync.sh not present"
	printf '%s\n' \
		'---' \
		'name: my-agent' \
		'---' \
		'' \
		'<!-- STACK-SPECIFIC: customize here -->' \
		> "$TEST_TMP/.claude/agents/midfile.md"

	run bash "$SYNC_SH" to "$TEST_TMP"
	[ "$status" -eq 0 ] || {
		printf 'sync.sh to exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	grep -qF '<!-- STACK-SPECIFIC: customize here -->' \
		"$TEST_TMP/.claude/agents/midfile.md" || {
		printf 'FAIL: mid-file comment was removed by sync.sh to\n' >&2
		return 1
	}
}
