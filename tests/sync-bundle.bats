#!/usr/bin/env bats
#
# tests/sync-bundle.bats
# `sync.sh bundle` regenerates plugins/pipeline-core/scripts/ from
# .claude/scripts/ (issue #623 task 4) — the bundle is PRODUCED from the
# canonical tree rather than hand-edited, so drift like the one that shipped
# v0.3.0 without the #619 turn-budget fix can't happen silently.
#
# Runs against a fake temp repo (a copy of sync.sh plus fake .claude/scripts
# and plugins/pipeline-core/scripts trees) rather than the real repo, so the
# generator's copy/overwrite/remove behaviour can be asserted against known
# fixtures without depending on — or mutating — real repo content.
#
# The two trees are reconciled as of issue #623 task 2, so a live
# `./sync.sh bundle` is a safe no-op; test-bundle-parity.bats is the guard
# that keeps it that way.
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SYNC_SH="$REPO_ROOT/sync.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	cp "$SYNC_SH" "$TEST_TMP/sync.sh"
	mkdir -p "$TEST_TMP/.claude/scripts" "$TEST_TMP/plugins/pipeline-core/scripts"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# Structural — sync.sh must define bundle_scripts and wire it into a bundle
# command.
# =============================================================================

@test "sync.sh defines a bundle_scripts function" {
	grep -qE '^bundle_scripts\(\) \{' "$SYNC_SH" || {
		printf 'FAIL: bundle_scripts() not defined in sync.sh\n' >&2
		return 1
	}
}

@test "sync.sh bundle case calls bundle_scripts" {
	awk '/^[[:space:]]+bundle\)/{f=1} f{print} /^[[:space:]]+;;/{f=0}' \
		"$SYNC_SH" | grep -q 'bundle_scripts' || {
		printf 'FAIL: bundle) case does not call bundle_scripts\n' >&2
		return 1
	}
}

# The generator (sync.sh) and the drift guard (test-bundle-parity.bats) each
# carry their own list of bundled subdirectories. If they disagree, the
# generator regenerates a directory the guard never checks (or vice versa) and
# drift goes silent again — exactly the #623 failure mode. Comments alone
# don't enforce that, so assert the two lists are byte-identical.
@test "bundle subdir list matches the parity guard's subdir list" {
	local parity_bats bundle_list parity_list
	parity_bats="$REPO_ROOT/.claude/scripts/implement-issue-test"
	parity_bats+="/test-bundle-parity.bats"

	[[ -f "$parity_bats" ]] || {
		printf 'FAIL: parity guard not found: %s\n' "$parity_bats" >&2
		return 1
	}

	bundle_list=$(sed -n 's/^BUNDLE_SCRIPT_SUBDIRS=(\(.*\))$/\1/p' "$SYNC_SH")
	parity_list=$(sed -n 's/^PARITY_SUBDIRS=(\(.*\))$/\1/p' "$parity_bats")

	[[ -n "$bundle_list" ]] || {
		printf 'FAIL: BUNDLE_SCRIPT_SUBDIRS not found in sync.sh\n' >&2
		return 1
	}
	[[ -n "$parity_list" ]] || {
		printf 'FAIL: PARITY_SUBDIRS not found in %s\n' "$parity_bats" >&2
		return 1
	}

	[[ "$bundle_list" == "$parity_list" ]] || {
		printf 'FAIL: subdir lists diverged\n  sync.sh:  %s\n  parity:   %s\n' \
			"$bundle_list" "$parity_list" >&2
		return 1
	}
}

# =============================================================================
# Integration — run `sync.sh bundle` against a fake repo.
# =============================================================================

@test "(AC) bundle copies a canonical script the bundle is missing" {
	printf '#!/usr/bin/env bash\necho hi\n' \
		> "$TEST_TMP/.claude/scripts/new-script.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	local bundled="$TEST_TMP/plugins/pipeline-core/scripts/new-script.sh"
	[[ -f "$bundled" ]] || fail "new-script.sh was not copied into the bundle"
	diff -q "$TEST_TMP/.claude/scripts/new-script.sh" "$bundled" || \
		fail "copied script content differs from canonical"
}

@test "(AC) bundle overwrites a stale bundled script with canonical content" {
	printf '#!/usr/bin/env bash\necho new\n' \
		> "$TEST_TMP/.claude/scripts/existing.sh"
	printf '#!/usr/bin/env bash\necho old\n' \
		> "$TEST_TMP/plugins/pipeline-core/scripts/existing.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	grep -q 'echo new' "$TEST_TMP/plugins/pipeline-core/scripts/existing.sh" || \
		fail "stale bundled script was not overwritten with canonical content"
}

@test "(AC) bundle removes a bundled script with no canonical counterpart" {
	printf '#!/usr/bin/env bash\necho orphan\n' \
		> "$TEST_TMP/plugins/pipeline-core/scripts/orphan.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	[[ ! -f "$TEST_TMP/plugins/pipeline-core/scripts/orphan.sh" ]] || \
		fail "orphaned bundled script was not removed"
}

@test "(AC4) bundle produces no diff when trees are already in sync" {
	printf '#!/usr/bin/env bash\necho same\n' \
		> "$TEST_TMP/.claude/scripts/same.sh"
	cp "$TEST_TMP/.claude/scripts/same.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/same.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	diff -q "$TEST_TMP/.claude/scripts/same.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/same.sh" || \
		fail "bundle introduced drift on an already-synced pair"
}

@test "bundle does not touch non-.sh content in the bundle" {
	mkdir -p "$TEST_TMP/plugins/pipeline-core/scripts/platform"
	echo "keep me" > "$TEST_TMP/plugins/pipeline-core/scripts/platform/foo.txt"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'bundle exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	[[ -f "$TEST_TMP/plugins/pipeline-core/scripts/platform/foo.txt" ]] || \
		fail "bundle touched files outside the top-level *.sh scope"
}

@test "bundle is idempotent — a second run makes no further changes" {
	printf '#!/usr/bin/env bash\necho v1\n' \
		> "$TEST_TMP/.claude/scripts/a.sh"

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ]

	run bash "$TEST_TMP/sync.sh" bundle
	[ "$status" -eq 0 ] || {
		printf 'second bundle run exited %d:\n%s\n' "$status" "$output" >&2
		return 1
	}

	diff -q "$TEST_TMP/.claude/scripts/a.sh" \
		"$TEST_TMP/plugins/pipeline-core/scripts/a.sh" || \
		fail "second bundle run diverged from canonical"
}
