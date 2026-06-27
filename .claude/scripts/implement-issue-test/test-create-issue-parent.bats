#!/usr/bin/env bats
#
# test-create-issue-parent.bats
# Tests for create-issue.sh --parent behaviour on the github tracker.
#
# Covers:
#   1. --parent <numeric>  → sub_issues POST is issued with the child numeric id
#   2. --parent ""         → no sub_issues POST, exits 0
#   3. --parent <non-numeric> (e.g. a Jira key) → no sub_issues POST, exits 0
#

# Stream separation on `run` (--separate-stderr) requires bats >= 1.5.0
bats_require_minimum_version 1.5.0

# Absolute path to the real script under test
# BATS_TEST_FILENAME is .claude/scripts/implement-issue-test/test-*.bats
# ../../.. from implement-issue-test reaches the repo root
CREATE_ISSUE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/.claude/scripts/platform/create-issue.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    export TEST_TMP

    # Mock bin directory
    mkdir -p "$TEST_TMP/bin"

    # Log files used by assertions
    GH_CALLS="$TEST_TMP/gh-calls.log"
    GH_API_ARGS="$TEST_TMP/gh-api-args.log"
    export GH_CALLS GH_API_ARGS

    # Mock gh:
    #   - "gh issue create ..."        → returns fake issue URL (issue 99)
    #   - "gh repo view ..."           → returns fake owner/repo
    #   - "gh api .../issues/<n> ..."  → returns fake numeric DB id
    #   - "gh api -X POST ... sub_issues ..." → records the call, returns {}
    cat > "$TEST_TMP/bin/gh" << 'MOCK'
#!/usr/bin/env bash
# Record every invocation
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"

case "$1" in
    issue)
        if [[ "$2" == "create" ]]; then
            # Return a fake GitHub issue URL; the script greps the trailing number.
            echo "https://github.com/test-owner/test-repo/issues/99"
        fi
        ;;
    repo)
        # "gh repo view --json nameWithOwner --jq '.nameWithOwner'"
        echo "test-owner/test-repo"
        ;;
    api)
        # Detect sub_issues POST — record args separately for assertion.
        if printf '%s ' "$@" | grep -q 'sub_issues'; then
            printf '%s\n' "$*" >> "${GH_API_ARGS:-/dev/null}"
            echo '{}'
        else
            # Issue lookup: return a numeric DB id (the real value is ~10 digits).
            echo "4557465351"
        fi
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TMP/bin/gh"

    # Prepend mock bin to PATH so create-issue.sh picks up the mock gh.
    export PATH="$TEST_TMP/bin:$PATH"

    # Force github tracker (platform.sh respects the env var via ${TRACKER:-github}).
    export TRACKER=github
}

teardown() {
    [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_run_create_issue() {
    # --separate-stderr keeps WARNING lines (emitted to stderr on linkage
    # failure / non-numeric parent) out of $output, so stdout-only assertions
    # like [[ "$output" == "99" ]] verify the issue-number contract correctly.
    run --separate-stderr bash "$CREATE_ISSUE_SH" "$@"
}

# =============================================================================
# Numeric parent — sub_issues POST must fire
# =============================================================================

@test "--parent 42: gh api sub_issues is called" {
    _run_create_issue --title "Test Issue" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    [ -f "$GH_API_ARGS" ] || {
        echo "sub_issues POST was never called (GH_API_ARGS not written)"
        return 1
    }
    grep -q 'sub_issues' "$GH_API_ARGS"
}

@test "--parent 42: sub_issues POST uses HTTP POST method" {
    _run_create_issue --title "Test Issue" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    [ -f "$GH_API_ARGS" ]
    grep -q '\-X POST\|POST' "$GH_API_ARGS"
}

@test "--parent 42: sub_issues POST includes sub_issue_id field" {
    _run_create_issue --title "Test Issue" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    [ -f "$GH_API_ARGS" ]
    grep -q 'sub_issue_id' "$GH_API_ARGS"
}

@test "--parent 42: sub_issues endpoint references parent issue number" {
    _run_create_issue --title "Test Issue" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    [ -f "$GH_API_ARGS" ]
    # The POST URL should contain the parent number (42)
    grep -q '42' "$GH_API_ARGS"
}

@test "--parent 42: script prints only the new issue number on stdout" {
    _run_create_issue --title "Test Issue" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    # stdout must be exactly the issue number extracted from the URL
    [[ "$output" == "99" ]]
}

@test "--parent #42 (with leading hash): sub_issues POST is still issued" {
    _run_create_issue --title "Test Issue" --body "body" --parent "#42"

    [ "$status" -eq 0 ]
    [ -f "$GH_API_ARGS" ]
    grep -q 'sub_issues' "$GH_API_ARGS"
}

# =============================================================================
# Empty parent — no sub_issues POST
# =============================================================================

@test "--parent '' (empty): script exits 0" {
    _run_create_issue --title "Test Issue" --body "body" --parent ""

    [ "$status" -eq 0 ]
}

@test "--parent '' (empty): no sub_issues POST is made" {
    _run_create_issue --title "Test Issue" --body "body" --parent ""

    [ "$status" -eq 0 ]
    [ ! -f "$GH_API_ARGS" ] || ! grep -q 'sub_issues' "$GH_API_ARGS"
}

@test "no --parent flag: no sub_issues POST is made" {
    _run_create_issue --title "Test Issue" --body "body"

    [ "$status" -eq 0 ]
    [ ! -f "$GH_API_ARGS" ] || ! grep -q 'sub_issues' "$GH_API_ARGS"
}

# =============================================================================
# Non-numeric parent (e.g. Jira key) — skip linking without error
# =============================================================================

@test "--parent KIKS-410 (non-numeric): script exits 0" {
    _run_create_issue --title "Test Issue" --body "body" --parent "KIKS-410"

    [ "$status" -eq 0 ]
}

@test "--parent KIKS-410 (non-numeric): no sub_issues POST is made" {
    _run_create_issue --title "Test Issue" --body "body" --parent "KIKS-410"

    [ "$status" -eq 0 ]
    [ ! -f "$GH_API_ARGS" ] || ! grep -q 'sub_issues' "$GH_API_ARGS"
}

@test "--parent KIKS-410 (non-numeric): issue is still created on stdout" {
    _run_create_issue --title "Test Issue" --body "body" --parent "KIKS-410"

    [ "$status" -eq 0 ]
    [[ "$output" == "99" ]]
}

@test "--parent EPIC (non-numeric word): no sub_issues POST is made" {
    _run_create_issue --title "Test Issue" --body "body" --parent "EPIC"

    [ "$status" -eq 0 ]
    [ ! -f "$GH_API_ARGS" ] || ! grep -q 'sub_issues' "$GH_API_ARGS"
}

# =============================================================================
# Linkage failure is non-fatal
# =============================================================================

@test "--parent 42: script exits 0 even when sub_issues POST fails" {
    # Override the mock gh to fail on sub_issues calls
    cat > "$TEST_TMP/bin/gh" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"

case "$1" in
    issue)
        [[ "$2" == "create" ]] && echo "https://github.com/test-owner/test-repo/issues/99"
        ;;
    repo)
        echo "test-owner/test-repo"
        ;;
    api)
        if printf '%s ' "$@" | grep -q 'sub_issues'; then
            echo "ERROR: sub_issues API unavailable" >&2
            exit 1
        else
            echo "4557465351"
        fi
        ;;
esac
MOCK
    chmod +x "$TEST_TMP/bin/gh"

    _run_create_issue --title "Test Issue" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    [[ "$output" == "99" ]]
}

@test "--parent 42: new issue number is printed even when sub_issues POST fails" {
    cat > "$TEST_TMP/bin/gh" << 'MOCK'
#!/usr/bin/env bash
case "$1" in
    issue) [[ "$2" == "create" ]] && echo "https://github.com/test-owner/test-repo/issues/99" ;;
    repo)  echo "test-owner/test-repo" ;;
    api)
        if printf '%s ' "$@" | grep -q 'sub_issues'; then exit 1; fi
        echo "4557465351"
        ;;
esac
MOCK
    chmod +x "$TEST_TMP/bin/gh"

    _run_create_issue --title "Test Issue" --body "body" --parent "42"

    [[ "$output" == "99" ]]
}

# =============================================================================
# Defensive guards (issue_num and URL prefix) — unreachable via normal gh
# output but tested here via a sed-patched copy with URL validation stripped.
# =============================================================================

# Produce a patched copy of create-issue.sh inside scripts_dir with the outer
# URL-validation block removed so the inner numeric/prefix guards are reachable.
_patch_create_issue_no_url_guard() {
	local scripts_dir="$1"
	sed \
		-e '/if \[\[.*=~.*\^https/,/^[[:space:]]*issue_num=/{' \
		-e '/^[[:space:]]*issue_num=/!d' \
		-e '}' \
		"$CREATE_ISSUE_SH" > "$scripts_dir/create-issue.sh"
	chmod +x "$scripts_dir/create-issue.sh"
}

@test "issue_num non-numeric guard: emits WARNING and skips sub-issue POST" {
    # The outer URL regex (^https://github.com/.+/issues/[0-9]+$) normally
    # prevents a non-numeric issue_num. Strip that block to reach the guard.
    local scripts_dir="$TEST_TMP/scripts/platform"
    local config_dir="$TEST_TMP/config"
    mkdir -p "$scripts_dir" "$config_dir"
    printf '%s\n' 'TRACKER="${TRACKER:-github}"' > "$config_dir/platform.sh"
    _patch_create_issue_no_url_guard "$scripts_dir"

    cat > "$TEST_TMP/bin/gh" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "$1" in
    issue) [[ "$2" == "create" ]] && echo "https://github.com/test/issues/abc" ;;
    api)
        printf '%s\n' "$*" >> "${GH_API_ARGS:-/dev/null}"
        echo "12345"
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TMP/bin/gh"

    run --separate-stderr bash "$scripts_dir/create-issue.sh" \
        --title "Test" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    [[ "$stderr" == *"WARNING"*"not numeric"* ]]
    [ ! -f "$GH_API_ARGS" ] || ! grep -q 'sub_issues' "$GH_API_ARGS"
}

@test "issue_url prefix guard: emits WARNING and skips sub-issue POST" {
    local scripts_dir="$TEST_TMP/scripts/platform"
    local config_dir="$TEST_TMP/config"
    mkdir -p "$scripts_dir" "$config_dir"
    printf '%s\n' 'TRACKER="${TRACKER:-github}"' > "$config_dir/platform.sh"
    _patch_create_issue_no_url_guard "$scripts_dir"

    cat > "$TEST_TMP/bin/gh" << 'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "$1" in
    issue)
        [[ "$2" == "create" ]] && \
            echo "https://notgithub.com/test/issues/99"
        ;;
    api)
        printf '%s\n' "$*" >> "${GH_API_ARGS:-/dev/null}"
        echo "12345"
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TMP/bin/gh"

    run --separate-stderr bash "$scripts_dir/create-issue.sh" \
        --title "Test" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    [[ "$stderr" == *"WARNING"*"github.com"* ]]
    [ ! -f "$GH_API_ARGS" ] || ! grep -q 'sub_issues' "$GH_API_ARGS"
}

# =============================================================================
# Body validation: ## Implementation Tasks trigger widening (issue #437 task 1)
# =============================================================================
#
# The validation trigger in create-issue.sh must fire for any body that
# contains ## Implementation Tasks — not only bodies marked with
# <!-- pipeline-autocreated -->.  Regression: the original
# <!-- pipeline-autocreated --> trigger must continue to work.
#
# Static analysis tests will fail until the if-condition is widened;
# functional tests will fail until assert_issue_valid is called for
# ## Implementation Tasks bodies.

@test "validation trigger includes '## Implementation Tasks' in the if-condition" {
	# The BODY comparison inside the if must reference ## Implementation Tasks
	# so bodies with that section are validated before gh issue create is called.
	grep -qE '\[\[.*"## Implementation Tasks"' "$CREATE_ISSUE_SH"
}

@test "validation trigger still includes 'pipeline-autocreated' in the if-condition" {
	# Original trigger must be preserved — widening must not drop the existing
	# pipeline-autocreated check.
	grep -qE '\[\[.*pipeline-autocreated' "$CREATE_ISSUE_SH"
}

@test "body with ## Implementation Tasks but invalid structure: exit 1 (issue not created)" {
	# A body that carries ## Implementation Tasks but has only prose (no valid
	# task lines, no Acceptance Criteria) must fail assert_issue_valid and
	# prevent issue creation.
	local body
	body=$(printf '## Implementation Tasks\n\nJust prose — no valid task format.\n')
	unset DEPLOY_VERIFY_CMD
	_run_create_issue --title "Test" --body "$body"
	[ "$status" -eq 1 ]
}

@test "body with ## Implementation Tasks but invalid structure: gh issue create not called" {
	# When assert_issue_valid rejects the body, the gh call must be suppressed.
	local body
	body=$(printf '## Implementation Tasks\n\nJust prose — no valid task format.\n')
	unset DEPLOY_VERIFY_CMD
	_run_create_issue --title "Test" --body "$body"
	[ ! -f "$GH_CALLS" ] || ! grep -q 'issue create' "$GH_CALLS"
}

@test "body with ## Implementation Tasks and valid structure: exit 0 (issue created)" {
	# A body with ## Implementation Tasks AND proper task format plus Acceptance
	# Criteria must pass assert_issue_valid and proceed to create the issue.
	local body
	body=$(printf 'Context.\n\n## Implementation Tasks\n\n- [ ] `[default]` **(S)** Fix the bug\n\n## Acceptance Criteria\n\n- [ ] Bug is fixed\n')
	unset DEPLOY_VERIFY_CMD
	_run_create_issue --title "Test" --body "$body"
	[ "$status" -eq 0 ]
}

@test "body without trigger sections: validation skipped, issue created (exit 0)" {
	# Bodies that carry neither <!-- pipeline-autocreated --> nor
	# ## Implementation Tasks must bypass assert_issue_valid entirely —
	# they may use prose task formats the validator does not understand.
	local body="Just a plain description with no special sections."
	unset DEPLOY_VERIFY_CMD
	_run_create_issue --title "Test" --body "$body"
	[ "$status" -eq 0 ]
}

@test "body with pipeline-autocreated but invalid structure: exit 1 (regression guard)" {
	# The original <!-- pipeline-autocreated --> trigger must still work after
	# the condition is widened to include ## Implementation Tasks.
	local body
	body=$(printf '<!-- pipeline-autocreated -->\nJust prose, no task lines.\n')
	unset DEPLOY_VERIFY_CMD
	_run_create_issue --title "Test" --body "$body"
	[ "$status" -eq 1 ]
}

# =============================================================================
# DEPLOY_VERIFY_CMD interaction with ## Implementation Tasks (issue #437 task 3)
#
# When DEPLOY_VERIFY_CMD is set, assert_issue_valid requires a
# ## Deploy Verification section (criterion 5).  Bodies that carry
# ## Implementation Tasks trigger validation; bodies that do not carry
# ## Implementation Tasks bypass it entirely — including its
# DEPLOY_VERIFY_CMD check.
# =============================================================================

@test "body with '## Implementation Tasks' but no '## Deploy Verification': exit 1 when DEPLOY_VERIFY_CMD set" {
	# assert_issue_valid criterion 5 must fire: DEPLOY_VERIFY_CMD is set but
	# the body omits ## Deploy Verification → validation fails → exit 1.
	local body
	body=$(printf '## Implementation Tasks\n\n- [ ] `[default]` **(S)** Fix the thing\n\n## Acceptance Criteria\n\n- [ ] Thing is fixed\n')
	export DEPLOY_VERIFY_CMD="./scripts/verify.sh"
	_run_create_issue --title "Test" --body "$body"
	[ "$status" -eq 1 ]
}

@test "body with '## Implementation Tasks' but no '## Deploy Verification': gh issue create not called when DEPLOY_VERIFY_CMD set" {
	# Validation must gate the gh call — when validation fails the issue must
	# not be created.
	local body
	body=$(printf '## Implementation Tasks\n\n- [ ] `[default]` **(S)** Fix the thing\n\n## Acceptance Criteria\n\n- [ ] Thing is fixed\n')
	export DEPLOY_VERIFY_CMD="./scripts/verify.sh"
	_run_create_issue --title "Test" --body "$body"
	[ ! -f "$GH_CALLS" ] || ! grep -q 'issue create' "$GH_CALLS"
}

@test "body without '## Implementation Tasks': accepted unchanged when DEPLOY_VERIFY_CMD set" {
	# Without the trigger section, assert_issue_valid is never called, so
	# DEPLOY_VERIFY_CMD criterion 5 is not reached — the body passes through
	# unmodified and the issue is created regardless.
	local body="Plain description with no trigger sections."
	export DEPLOY_VERIFY_CMD="./scripts/verify.sh"
	_run_create_issue --title "Test" --body "$body"
	[ "$status" -eq 0 ]
}

@test "body without '## Implementation Tasks': issue number printed to stdout when DEPLOY_VERIFY_CMD set" {
	# Confirm the gh issue create call succeeds and the issue number is
	# written to stdout — validation bypass must not silently swallow output.
	local body="Plain description with no trigger sections."
	export DEPLOY_VERIFY_CMD="./scripts/verify.sh"
	_run_create_issue --title "Test" --body "$body"
	[[ "$output" == "99" ]]
}
