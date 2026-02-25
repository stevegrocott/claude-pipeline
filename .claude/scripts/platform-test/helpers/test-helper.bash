#!/usr/bin/env bash
#
# test-helper.bash
# Common test setup and helper functions for platform wrapper script tests
#

# =============================================================================
# TEST ENVIRONMENT SETUP
# =============================================================================

# Directory where the platform scripts under test live
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../platform" && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Temp directory for test artifacts
TEST_TMP=""

# Create isolated test environment
setup_test_env() {
    TEST_TMP=$(mktemp -d)
    export TEST_TMP

    # Create directories
    mkdir -p "$TEST_TMP/bin"
    mkdir -p "$TEST_TMP/logs"

    # Clear any mock call logs
    : > "$TEST_TMP/mock_calls.log"

    # -----------------------------------------------------------------
    # Create a mock platform.sh config in the location the platform
    # scripts expect: ../../config/platform.sh relative to SCRIPT_DIR.
    # Instead of modifying the real config we override the sourcing by
    # placing a shim config alongside the real platform scripts.
    # The platform scripts do:
    #   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    #   source "$SCRIPT_DIR/../../config/platform.sh"
    # So we create $TEST_TMP/config/platform.sh and symlink the scripts
    # into $TEST_TMP/scripts/platform/ so the relative path resolves.
    # -----------------------------------------------------------------
    mkdir -p "$TEST_TMP/scripts/platform"
    mkdir -p "$TEST_TMP/config"

    # Copy all platform scripts to the temp location
    cp "$SCRIPT_DIR"/*.sh "$TEST_TMP/scripts/platform/"

    # Set default platform config values
    export TRACKER="github"
    export TRACKER_CLI="gh"
    export JIRA_PROJECT="TEST"
    export JIRA_DEFAULT_ISSUE_TYPE="Task"
    export JIRA_DONE_TRANSITION="Done"
    export JIRA_IN_PROGRESS_TRANSITION="In Progress"
    export GIT_HOST="github"
    export GIT_CLI="gh"
    export MERGE_STYLE="squash"

    # Write the mock platform.sh that uses env vars
    cat > "$TEST_TMP/config/platform.sh" << 'PLATFORM_EOF'
#!/bin/bash
# Mock platform config - values come from environment
TRACKER="${TRACKER:-github}"
TRACKER_CLI="${TRACKER_CLI:-gh}"
JIRA_PROJECT="${JIRA_PROJECT:-TEST}"
JIRA_DEFAULT_ISSUE_TYPE="${JIRA_DEFAULT_ISSUE_TYPE:-Task}"
JIRA_DONE_TRANSITION="${JIRA_DONE_TRANSITION:-Done}"
JIRA_IN_PROGRESS_TRANSITION="${JIRA_IN_PROGRESS_TRANSITION:-In Progress}"
GIT_HOST="${GIT_HOST:-github}"
GIT_CLI="${GIT_CLI:-gh}"
MERGE_STYLE="${MERGE_STYLE:-squash}"
PLATFORM_EOF

    # Reset mock output env vars
    export MOCK_GH_EXIT_CODE=0
    export MOCK_GH_ISSUE_JSON='{"title":"Test Issue","body":"Test body","state":"OPEN"}'
    export MOCK_GH_ISSUES_JSON='[{"number":1,"title":"Issue 1","state":"OPEN"},{"number":2,"title":"Issue 2","state":"OPEN"}]'
    export MOCK_GH_PR_JSON='{"number":99,"title":"Test PR","body":"PR body","state":"OPEN"}'
    export MOCK_GH_PR_LIST_JSON='[{"number":99}]'
    export MOCK_GLAB_EXIT_CODE=0
    export MOCK_GLAB_MR_LIST_JSON='[{"iid":55}]'
    export MOCK_ACLI_EXIT_CODE=0
    export MOCK_ACLI_ISSUE_JSON='{"fields":{"summary":"Jira Issue","description":"Jira body","status":{"name":"To Do"}}}'
    export MOCK_ACLI_ISSUES_JSON='[{"key":"TEST-1","fields":{"summary":"Issue 1","status":{"name":"To Do"}}},{"key":"TEST-2","fields":{"summary":"Issue 2","status":{"name":"In Progress"}}}]'
}

# Clean up test environment
teardown_test_env() {
    if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
        rm -rf "$TEST_TMP"
    fi
}

# =============================================================================
# MOCK INSTALLATION
# =============================================================================

install_mocks() {
    local mock_bin="$TEST_TMP/bin"

    # -------------------------------------------------------------------
    # Mock gh CLI
    # -------------------------------------------------------------------
    cat > "$mock_bin/gh" << 'GH_EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$TEST_TMP/mock_calls.log"

case "$1" in
  issue)
    case "$2" in
      view)
        echo "${MOCK_GH_ISSUE_JSON}"
        ;;
      create)
        echo "https://github.com/owner/repo/issues/42"
        ;;
      comment)
        # succeed silently
        ;;
      close)
        # succeed silently
        ;;
      list)
        echo "${MOCK_GH_ISSUES_JSON}"
        ;;
    esac
    ;;
  pr)
    case "$2" in
      create)
        echo "https://github.com/owner/repo/pull/99"
        ;;
      view)
        echo "${MOCK_GH_PR_JSON}"
        ;;
      list)
        # Check if --jq flag is present; if so, extract from JSON
        _mock_has_jq=false
        _mock_jq_expr=""
        for arg in "$@"; do
          if [[ "$_mock_has_jq" == "pending" ]]; then
            _mock_jq_expr="$arg"
            _mock_has_jq=true
          fi
          if [[ "$arg" == "--jq" ]]; then
            _mock_has_jq="pending"
          fi
        done
        if [[ "$_mock_has_jq" == "true" ]]; then
          echo "${MOCK_GH_PR_LIST_JSON}" | jq -r "$_mock_jq_expr"
        else
          echo "${MOCK_GH_PR_LIST_JSON}"
        fi
        ;;
      comment)
        # succeed silently
        ;;
      merge)
        # succeed silently
        ;;
    esac
    ;;
esac

exit "${MOCK_GH_EXIT_CODE:-0}"
GH_EOF
    chmod +x "$mock_bin/gh"

    # -------------------------------------------------------------------
    # Mock glab CLI
    # -------------------------------------------------------------------
    cat > "$mock_bin/glab" << 'GLAB_EOF'
#!/usr/bin/env bash
echo "glab $*" >> "$TEST_TMP/mock_calls.log"

case "$1" in
  mr)
    case "$2" in
      create)
        echo "Creating merge request..."
        echo "!55"
        ;;
      merge)
        # succeed silently
        ;;
      list)
        echo "${MOCK_GLAB_MR_LIST_JSON}"
        ;;
      note)
        # succeed silently (handles both 'note' for adding and 'note list')
        ;;
    esac
    ;;
esac

exit "${MOCK_GLAB_EXIT_CODE:-0}"
GLAB_EOF
    chmod +x "$mock_bin/glab"

    # -------------------------------------------------------------------
    # Mock acli CLI
    # -------------------------------------------------------------------
    cat > "$mock_bin/acli" << 'ACLI_EOF'
#!/usr/bin/env bash
echo "acli $*" >> "$TEST_TMP/mock_calls.log"

case "$1" in
  jira)
    case "$2" in
      create-issue)
        echo "Issue TEST-123 created successfully"
        ;;
      get-issue)
        echo "${MOCK_ACLI_ISSUE_JSON}"
        ;;
      add-comment)
        # succeed silently
        ;;
      transition-issue)
        # succeed silently
        ;;
      list-issues)
        echo "${MOCK_ACLI_ISSUES_JSON}"
        ;;
    esac
    ;;
esac

exit "${MOCK_ACLI_EXIT_CODE:-0}"
ACLI_EOF
    chmod +x "$mock_bin/acli"

    # -------------------------------------------------------------------
    # Mock jq CLI - use system jq but we need it available
    # jq is required by many platform scripts so we don't mock it.
    # Instead ensure the real jq is findable. If it's already on PATH
    # before we prepend our mock bin, we're fine.
    # -------------------------------------------------------------------

    # Prepend mock bin to PATH
    export PATH="$mock_bin:$PATH"
}

# =============================================================================
# HELPERS
# =============================================================================

# Run a platform script from the test temp location (so it picks up mock config)
run_platform_script() {
    local script_name="$1"
    shift
    bash "$TEST_TMP/scripts/platform/$script_name" "$@"
}

# Get the contents of the mock call log
mock_calls() {
    cat "$TEST_TMP/mock_calls.log" 2>/dev/null || true
}

# Check if a specific command was called (substring match in call log)
assert_mock_called_with() {
    local pattern="$1"
    local msg="${2:-Mock should have been called with: $pattern}"
    local log
    log=$(mock_calls)
    if [[ "$log" != *"$pattern"* ]]; then
        echo "FAIL: $msg"
        echo "  Call log:"
        echo "  $log"
        return 1
    fi
    return 0
}

# Assert output contains string
assert_output_contains() {
    local needle="$1"
    local msg="${2:-Output should contain: $needle}"
    if [[ "$output" != *"$needle"* ]]; then
        echo "FAIL: $msg"
        echo "  Output: $output"
        return 1
    fi
    return 0
}

# Assert output equals string (trimmed)
assert_output_equals() {
    local expected="$1"
    local msg="${2:-Output should equal: $expected}"
    local trimmed
    trimmed="$(echo "$output" | xargs)"
    if [[ "$trimmed" != "$expected" ]]; then
        echo "FAIL: $msg"
        echo "  Expected: $expected"
        echo "  Actual:   $trimmed"
        return 1
    fi
    return 0
}
