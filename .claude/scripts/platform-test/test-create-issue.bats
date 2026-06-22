#!/usr/bin/env bats
#
# test-create-issue.bats
# Tests for platform/create-issue.sh
#

# --separate-stderr requires bats >= 1.5.0
bats_require_minimum_version 1.5.0

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

# =============================================================================
# DEFENSIVE GUARDS
# Inner guards for issue_num and issue_url prefix are unreachable via
# well-formed gh output because the outer URL-format check exits first.
# We strip that outer check with a pattern-anchored sed range so the inner
# guards are exercised.  The range anchor is a stable string in the if-
# condition, not a line number, so it survives additions to that block.
# =============================================================================

# Strip the outer URL-format guard from the working copy of create-issue.sh
# so the inner issue_num / issue_url-prefix guards become reachable.
#
# The sed range /start/,/end/d anchors on the if-condition text and the
# closing fi, not on line offsets.  Adding or removing lines inside the
# block does not break the deletion.
_patch_create_issue_no_url_guard() {
	local target="$TEST_TMP/scripts/platform/create-issue.sh"
	sed \
		-e '/if \[\[.*=~.*\^https/,/^[[:space:]]*issue_num=/{' \
		-e '/^[[:space:]]*issue_num=/!d' \
		-e '}' \
		"$target" > "${target}.patched"
	mv "${target}.patched" "$target"
}

@test "create-issue github: non-numeric issue_num emits WARNING and skips gh api" {
    export TRACKER="github"
    export GH_API_ARGS="$TEST_TMP/gh_api_args.log"
    _patch_create_issue_no_url_guard

    # gh returns a URL whose trailing segment is non-numeric (abc).
    # After the outer URL check is stripped, issue_num becomes "abc" and
    # the inner numeric guard fires, emitting a WARNING to stderr.
    cat > "$TEST_TMP/bin/gh" << 'GH_EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$TEST_TMP/mock_calls.log"
case "$1" in
    issue) [[ "$2" == "create" ]] && echo "https://github.com/test/issues/abc" ;;
    api)
        printf '%s\n' "$*" >> "$GH_API_ARGS"
        echo "12345"
        ;;
esac
exit 0
GH_EOF
    chmod +x "$TEST_TMP/bin/gh"

    run --separate-stderr run_platform_script create-issue.sh \
        --title "Guard test" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    [[ "$stderr" == *"WARNING"*"not numeric"* ]]
    [ ! -s "$GH_API_ARGS" ]
}

@test "create-issue github: non-github.com issue_url emits WARNING and skips gh api" {
    export TRACKER="github"
    export GH_API_ARGS="$TEST_TMP/gh_api_args.log"
    _patch_create_issue_no_url_guard

    # gh returns a well-formed URL with a numeric issue number but a host
    # that is not github.com.  After the outer URL check is stripped the
    # issue_url-prefix guard fires, emitting a WARNING to stderr.
    cat > "$TEST_TMP/bin/gh" << 'GH_EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$TEST_TMP/mock_calls.log"
case "$1" in
    issue) [[ "$2" == "create" ]] && echo "https://notgithub.com/test/issues/99" ;;
    api)
        printf '%s\n' "$*" >> "$GH_API_ARGS"
        echo "12345"
        ;;
esac
exit 0
GH_EOF
    chmod +x "$TEST_TMP/bin/gh"

    run --separate-stderr run_platform_script create-issue.sh \
        --title "Guard test" --body "body" --parent "42"

    [ "$status" -eq 0 ]
    [[ "$stderr" == *"lacks required https://github.com/ prefix"* ]]
    [ ! -s "$GH_API_ARGS" ]
}
