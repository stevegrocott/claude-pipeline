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
