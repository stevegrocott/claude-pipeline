#!/usr/bin/env bats
#
# tests/pr-review-prior-prs.bats
# Coverage for issue #366 — "Code reviewer treats prior merged PRs as missing
# work on multi-PR issues".
#
# Pins the contract for the _prior_merged_prs_for_issue helper that the
# orchestrator gains in issue #366 (tasks 1 and 2):
#   * Calls `gh api` against the issue timeline and returns a newline-delimited
#     list of `PR#|title|merged_at|file1,file2,...` records — one per merged
#     cross-referenced PR.
#   * Returns empty (and surfaces no error) when the timeline contains no
#     merged PRs, when `gh` exits non-zero, or when TRACKER != github.
#   * The orchestrator's PR-review block injects a
#     "## Prior Merged PRs for Issue #N" section into review_prompt only when
#     the helper returns one or more rows; the section is absent for the empty
#     case.
#
# The helper is sourced in-process via an awk range extraction — the same
# pattern used by tests/agent-name-normalization.bats and
# tests/event-emission.bats.  Until the orchestrator change for issue #366
# (tasks 1 and 2) lands on the branch under test, the awk range matches
# nothing, the helper stays undefined, and the relevant tests fail RED — the
# convention documented in tests/stray-file-commit-isolation.bats and
# tests/agent-name-normalization.bats.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
ORCHESTRATOR="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Empty LOG_FILE → log/log_warn write only to stderr (no file needed).
	export LOG_FILE=""

	# Prepend an isolated bin dir so the `gh` stub takes precedence over the
	# real `gh` on PATH.
	export GH_STUB_DIR="$TEST_TMP/bin"
	mkdir -p "$GH_STUB_DIR"
	export PATH="$GH_STUB_DIR:$PATH"

	# Default: github tracker on issue #366 in a synthetic repo.  Individual
	# tests override these when exercising non-github / failure paths.
	export TRACKER="github"
	export ISSUE_NUMBER="366"
	export REPO="example/repo"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Source _prior_merged_prs_for_issue (and the log functions it depends on)
# from the orchestrator.  Header lines (readonly / set -o) are skipped so the
# test controls the environment.  When the orchestrator change has not landed
# the awk range matches nothing and the function stays undefined — the
# RED-until-merged convention used by tests/agent-name-normalization.bats.
_source_orchestrator_functions() {
	local func_file="$TEST_TMP/orchestrator_funcs.bash"
	awk '
		/^readonly /                                       { next }
		/^set -o /                                         { next }
		/^log\(\) \{$/,/^\}$/                              { print; next }
		/^log_warn\(\) \{$/,/^\}$/                         { print; next }
		/^log_error\(\) \{$/,/^\}$/                        { print; next }
		/^_prior_merged_prs_for_issue\(\) \{$/,/^\}$/      { print; next }
	' "$ORCHESTRATOR" > "$func_file"
	# shellcheck disable=SC1090
	source "$func_file"
}

# Install a `gh` stub.
#   $1 — JSON to echo for any invocation whose args contain "timeline"
#        (default: empty JSON array, mimicking gh api --jq with no matches)
#   $2 — JSON to echo for any other gh invocation, used for the per-PR file
#        list lookup (default: empty JSON array)
#
# Uses printf %q so the JSON payloads round-trip through the generated script
# unchanged regardless of quoting in the input.  `$*` inside the generated
# `case` is emitted as a literal — it expands at stub-invocation time, not at
# stub-write time.
_install_gh_stub() {
	local timeline_json="${1:-[]}"
	local files_json="${2:-[]}"

	{
		printf '#!/usr/bin/env bash\n'
		printf 'case " $* " in\n'
		printf '\t*timeline*)\n'
		printf "\t\tprintf '%%s' %q\n" "$timeline_json"
		printf '\t\t;;\n'
		printf '\t*nameWithOwner*)\n'
		printf "\t\tprintf '%%s' 'example/repo'\n"
		printf '\t\t;;\n'
		printf '\t*)\n'
		printf "\t\tprintf '%%s' %q\n" "$files_json"
		printf '\t\t;;\n'
		printf 'esac\n'
	} > "$GH_STUB_DIR/gh"
	chmod +x "$GH_STUB_DIR/gh"
}

# Install a gh stub that always exits non-zero — exercises the lookup-failure
# path that AC2 requires to be silent.
_install_gh_failure_stub() {
	{
		printf '#!/usr/bin/env bash\n'
		printf 'exit 1\n'
	} > "$GH_STUB_DIR/gh"
	chmod +x "$GH_STUB_DIR/gh"
}

# Install a tripwire `gh` stub that prints a marker on stderr and exits
# non-zero.  Used to assert that the helper does not call gh at all on the
# non-github tracker fast-path.
_install_gh_tripwire() {
	{
		printf '#!/usr/bin/env bash\n'
		printf 'printf "tripwire: gh invoked with: %%s\\n" "$*" >&2\n'
		printf 'exit 99\n'
	} > "$GH_STUB_DIR/gh"
	chmod +x "$GH_STUB_DIR/gh"
}

# Reference assembly of the "Prior Merged PRs for Issue #N" section.  This
# mirrors the injection the orchestrator must perform in review_prompt — when
# the helper returns rows, the section header and the rows appear; when the
# helper returns nothing, the section is absent entirely (no empty header,
# AC2).
_assemble_section() {
	local rows="$1"
	if [[ -n "$rows" ]]; then
		printf '## Prior Merged PRs for Issue #%s\n\n%s\n' \
			"$ISSUE_NUMBER" "$rows"
	fi
}

# ===========================================================================
# _prior_merged_prs_for_issue() — populated case
# ===========================================================================

@test "(1) helper returns a pipe-delimited record per merged cross-referenced PR" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	# Two merged PRs for issue #366 with disjoint file lists.
	_install_gh_stub \
		'[{"pr":363,"title":"feat: ship schema","merged":"2026-05-22T09:00:00Z"},{"pr":364,"title":"feat: add tests","merged":"2026-05-23T11:00:00Z"}]' \
		'src/a.ts,tests/a.bats'

	_source_orchestrator_functions
	declare -F _prior_merged_prs_for_issue >/dev/null || {
		printf 'FAIL: _prior_merged_prs_for_issue not defined; issue #366 task 1 not yet merged\n' >&2
		return 1
	}

	run --separate-stderr _prior_merged_prs_for_issue
	[ "$status" -eq 0 ]

	# One record per merged PR.
	[[ "$output" == *"363|"* ]] || {
		printf 'FAIL: expected PR# 363 record in output:\n%s\n' "$output" >&2
		return 1
	}
	[[ "$output" == *"364|"* ]] || {
		printf 'FAIL: expected PR# 364 record in output:\n%s\n' "$output" >&2
		return 1
	}

	# Title is preserved verbatim in the record.
	[[ "$output" == *"|feat: ship schema|"* ]] || {
		printf 'FAIL: expected "feat: ship schema" title in output:\n%s\n' "$output" >&2
		return 1
	}

	# Merged-at timestamp is preserved verbatim.
	[[ "$output" == *"|2026-05-22T09:00:00Z|"* ]] || {
		printf 'FAIL: expected merged-at "2026-05-22T09:00:00Z" in output:\n%s\n' "$output" >&2
		return 1
	}

	# The changed-file list appears as the final pipe-delimited field,
	# emitted as a comma-delimited list (not raw JSON).
	[[ "$output" == *"src/a.ts,tests/a.bats"* ]] || {
		printf 'FAIL: expected comma-delimited file list "src/a.ts,tests/a.bats" in output:\n%s\n' "$output" >&2
		return 1
	}
}

# ===========================================================================
# _prior_merged_prs_for_issue() — empty / skipped paths (AC2)
# ===========================================================================

@test "(2) helper returns empty output when the timeline has no merged PRs" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	_install_gh_stub '[]' '[]'

	_source_orchestrator_functions
	declare -F _prior_merged_prs_for_issue >/dev/null || {
		printf 'FAIL: _prior_merged_prs_for_issue not defined; issue #366 task 1 not yet merged\n' >&2
		return 1
	}

	run --separate-stderr _prior_merged_prs_for_issue
	[ "$status" -eq 0 ]
	[ -z "$output" ] || {
		printf 'FAIL: expected empty output for empty timeline, got:\n%s\n' "$output" >&2
		return 1
	}
}

@test "(3) helper returns empty and does not invoke gh when TRACKER != github" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	# Tripwire: any gh invocation fails the test by exiting 99 and emitting
	# a marker on stderr.  AC2 requires the non-github fast-path to be silent.
	_install_gh_tripwire
	export TRACKER="jira"

	_source_orchestrator_functions
	declare -F _prior_merged_prs_for_issue >/dev/null || {
		printf 'FAIL: _prior_merged_prs_for_issue not defined; issue #366 task 1 not yet merged\n' >&2
		return 1
	}

	run --separate-stderr _prior_merged_prs_for_issue
	[ "$status" -eq 0 ]
	[ -z "$output" ] || {
		printf 'FAIL: expected empty output for TRACKER=jira, got:\n%s\n' "$output" >&2
		return 1
	}
	[[ "$stderr" != *"tripwire: gh invoked"* ]] || {
		printf 'FAIL: helper invoked gh on the non-github fast-path. stderr:\n%s\n' \
			"$stderr" >&2
		return 1
	}
}

@test "(4) helper returns empty (no error surfaced) when gh exits non-zero" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	_install_gh_failure_stub

	_source_orchestrator_functions
	declare -F _prior_merged_prs_for_issue >/dev/null || {
		printf 'FAIL: _prior_merged_prs_for_issue not defined; issue #366 task 1 not yet merged\n' >&2
		return 1
	}

	run --separate-stderr _prior_merged_prs_for_issue
	[ "$status" -eq 0 ] || {
		printf 'FAIL: helper must not propagate gh failure (got status=%d). stderr:\n%s\n' \
			"$status" "$stderr" >&2
		return 1
	}
	[ -z "$output" ] || {
		printf 'FAIL: expected empty output on gh failure, got:\n%s\n' "$output" >&2
		return 1
	}
}

# ===========================================================================
# Assembled review prompt — section presence (AC1) and absence (AC2)
# ===========================================================================

@test "(5) assembled review prompt contains the Prior Merged PRs section when helper returns rows" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	_install_gh_stub \
		'[{"pr":363,"title":"feat: schema work shipped earlier","merged":"2026-05-22T09:00:00Z"}]' \
		'[{"filename":"src/foo.ts"}]'

	_source_orchestrator_functions
	declare -F _prior_merged_prs_for_issue >/dev/null || {
		printf 'FAIL: _prior_merged_prs_for_issue not defined; issue #366 task 1 not yet merged\n' >&2
		return 1
	}

	local rows section
	rows="$(_prior_merged_prs_for_issue)"
	section="$(_assemble_section "$rows")"

	[[ "$section" == *"## Prior Merged PRs for Issue #366"* ]] || {
		printf 'FAIL: expected section header in assembled prompt fragment:\n%s\n' \
			"$section" >&2
		return 1
	}
	[[ "$section" == *"363|"* ]] || {
		printf 'FAIL: expected PR# 363 record under section header:\n%s\n' \
			"$section" >&2
		return 1
	}
	[[ "$section" == *"feat: schema work shipped earlier"* ]] || {
		printf 'FAIL: expected PR title under section header:\n%s\n' "$section" >&2
		return 1
	}
}

@test "(6) assembled review prompt omits the Prior Merged PRs section when helper returns nothing" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	_install_gh_stub '[]' '[]'

	_source_orchestrator_functions
	declare -F _prior_merged_prs_for_issue >/dev/null || {
		printf 'FAIL: _prior_merged_prs_for_issue not defined; issue #366 task 1 not yet merged\n' >&2
		return 1
	}

	local rows section
	rows="$(_prior_merged_prs_for_issue)"
	section="$(_assemble_section "$rows")"

	[ -z "$section" ] || {
		printf 'FAIL: expected no section for empty helper output, got:\n%s\n' \
			"$section" >&2
		return 1
	}
	# Critical: no empty "## Prior Merged PRs for Issue #366" header may leak
	# through when there are no prior PRs (AC2).
	[[ "$section" != *"Prior Merged PRs for Issue"* ]] || {
		printf 'FAIL: empty-case assembled prompt still references the section header:\n%s\n' \
			"$section" >&2
		return 1
	}
}

# ===========================================================================
# Orchestrator source — task 2 injection block lands in implement-issue-orchestrator.sh
# ===========================================================================

@test "(7) orchestrator references the Prior Merged PRs section header in the review_prompt block" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	# Pin task 2's injection block to the orchestrator source: the literal
	# section header must appear somewhere in the PR-review prompt assembly.
	# Fails RED until issue #366 task 2 lands on the branch under test.
	grep -qF "Prior Merged PRs for Issue" "$ORCHESTRATOR" || {
		printf 'FAIL: orchestrator does not reference the "Prior Merged PRs for Issue" header — issue #366 task 2 not yet merged\n' >&2
		return 1
	}
}

# ===========================================================================
# Task 2 — injection block contract: current-PR filter and 10-row cap
# ===========================================================================

@test "(8) orchestrator passes the current PR number as exclude arg to the helper" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	# The injection block must call _prior_merged_prs_for_issue with
	# "$pr_number" as the second argument so the reviewer never sees the
	# current PR listed as prior work.
	# Fails RED until issue #366 task 2 lands on the branch under test.
	grep -qE \
		'_prior_merged_prs_for_issue[[:space:]].*"\$pr_number"' \
		"$ORCHESTRATOR" || {
		printf 'FAIL: orchestrator must call _prior_merged_prs_for_issue with "$pr_number" as exclude arg\n' >&2
		return 1
	}
}

@test "(9) orchestrator caps the prior-PRs block at ten entries" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"

	# The injection block must limit the rows returned by the helper to a
	# maximum of 10 so the review prompt does not balloon on long-lived issues
	# with many merged PRs.
	# Fails RED until issue #366 task 2 lands on the branch under test.
	grep -qE \
		'head[[:space:]]+-n[[:space:]]+10' \
		"$ORCHESTRATOR" || {
		printf 'FAIL: orchestrator must apply a 10-row cap (head -n 10) on prior PRs\n' >&2
		return 1
	}
}
