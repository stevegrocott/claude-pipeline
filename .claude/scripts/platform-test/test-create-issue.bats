#!/usr/bin/env bats
#
# test-create-issue.bats
# Tests for platform/create-issue.sh
#

load 'helpers/test-helper'

setup() {
    setup_test_env
    install_mocks
}

teardown() {
    teardown_test_env
}

# =============================================================================
# GITHUB MODE
# =============================================================================

@test "create-issue github: calls gh issue create and returns issue number" {
    export TRACKER="github"
    run run_platform_script create-issue.sh --title "Bug fix" --body "Fix the bug"
    [ "$status" -eq 0 ]
    [[ "$output" == *"42"* ]]
    assert_mock_called_with "gh issue create --title Bug fix --body Fix the bug"
}

@test "create-issue github: passes labels to gh" {
    export TRACKER="github"
    run run_platform_script create-issue.sh --title "Bug" --body "Body" --labels "bug,critical"
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh issue create"
    assert_mock_called_with "--label bug,critical"
}

# =============================================================================
# JIRA MODE
# =============================================================================

@test "create-issue jira: calls acli jira create-issue and returns issue key" {
    export TRACKER="jira"
    export JIRA_PROJECT="TEST"
    run run_platform_script create-issue.sh --title "Jira task" --body "Task body"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST-123"* ]]
    assert_mock_called_with "acli jira create-issue"
    assert_mock_called_with "--project TEST"
    assert_mock_called_with "--summary Jira task"
}

@test "create-issue jira: uses configured issue type" {
    export TRACKER="jira"
    export JIRA_DEFAULT_ISSUE_TYPE="Bug"
    run run_platform_script create-issue.sh --title "A bug" --body "Bug details"
    [ "$status" -eq 0 ]
    assert_mock_called_with "--type Bug"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "create-issue github: fails when gh exits non-zero" {
    export TRACKER="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script create-issue.sh --title "Fail" --body "Should fail"
    [ "$status" -ne 0 ]
}

@test "create-issue github: gh error text is not printed as issue number" {
    export TRACKER="github"
    cat > "$TEST_TMP/bin/gh" << 'GH_EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$TEST_TMP/mock_calls.log"
echo "GraphQL: Could not resolve to a Repository with the login of 'no-such-repo'."
exit 1
GH_EOF
    chmod +x "$TEST_TMP/bin/gh"
    run run_platform_script create-issue.sh --title "Error test" --body "Should fail"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# =============================================================================
# GH API NEGATIVE ASSERTION (non-vacuous)
# =============================================================================

@test "create-issue github: gh api not invoked without --parent" {
    export TRACKER="github"
    export GH_API_ARGS="$TEST_TMP/gh_api_args.log"

    # Callable stub: records every 'gh api' invocation to GH_API_ARGS.
    # Because GH_API_ARGS is a real path (not /dev/null), the assertion
    # below fails if the stub IS invoked — so the "not called" check is
    # non-vacuous.
    cat > "$TEST_TMP/bin/gh" << 'GH_EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$TEST_TMP/mock_calls.log"
case "$1" in
    issue)
        [[ "$2" == "create" ]] && \
            echo "https://github.com/owner/repo/issues/42"
        ;;
    api)
        printf '%s\n' "$*" >> "$GH_API_ARGS"
        echo "99999"
        ;;
esac
exit "${MOCK_GH_EXIT_CODE:-0}"
GH_EOF
    chmod +x "$TEST_TMP/bin/gh"

    run run_platform_script create-issue.sh --title "No parent" --body "body"
    [ "$status" -eq 0 ]
    # GH_API_ARGS points to a real file; the stub writes to it if gh api
    # fires.  An empty or absent file proves gh api was never invoked.
    [ ! -s "$GH_API_ARGS" ]
}

@test "create-issue github: gh api IS invoked with --parent (inverted control)" {
    # Inverted control: proves the callable stub records calls when gh api
    # fires.  This makes the 'not called' assertion in the previous test
    # non-vacuous — if the stub can write here it would have written there.
    export TRACKER="github"
    export GH_API_ARGS="$TEST_TMP/gh_api_args.log"

    cat > "$TEST_TMP/bin/gh" << 'GH_EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$TEST_TMP/mock_calls.log"
case "$1" in
    issue)
        [[ "$2" == "create" ]] && \
            echo "https://github.com/owner/repo/issues/42"
        ;;
    api)
        printf '%s\n' "$*" >> "$GH_API_ARGS"
        echo "99999"
        ;;
esac
exit "${MOCK_GH_EXIT_CODE:-0}"
GH_EOF
    chmod +x "$TEST_TMP/bin/gh"

    run run_platform_script create-issue.sh \
        --title "With parent" --body "body" --parent "7"
    [ "$status" -eq 0 ]
    # Stub was invoked: GH_API_ARGS must be non-empty.
    [ -s "$GH_API_ARGS" ]
}
