#!/usr/bin/env bash
#
# test-helper.bash
# Common test setup and helper functions for implement-issue-orchestrator tests
#

# =============================================================================
# TEST ENVIRONMENT SETUP
# =============================================================================

# Directory where the script under test lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Path to script under test
ORCHESTRATOR_SCRIPT="$SCRIPT_DIR/implement-issue-orchestrator.sh"

# Temp directory for test artifacts
TEST_TMP=""

# Create isolated test environment
setup_test_env() {
    TEST_TMP=$(mktemp -d)
    export TEST_TMP

    # Create minimal directory structure
    mkdir -p "$TEST_TMP/logs"
    mkdir -p "$TEST_TMP/schemas"

    # Copy schemas from real location
    if [[ -d "$SCRIPT_DIR/schemas" ]]; then
        cp -r "$SCRIPT_DIR/schemas/"* "$TEST_TMP/schemas/" 2>/dev/null || true
    fi

    # Copy model-config.sh so run_stage can resolve models
    if [[ -f "$SCRIPT_DIR/model-config.sh" ]]; then
        cp "$SCRIPT_DIR/model-config.sh" "$TEST_TMP/model-config.sh"
    fi

    # Copy platform config (sourced by orchestrator functions)
    # Preserve directory structure: TEST_TMP/.claude/config/platform.sh
    if [[ -f "$SCRIPT_DIR/../config/platform.sh" ]]; then
        mkdir -p "$TEST_TMP/.claude/config"
        cp "$SCRIPT_DIR/../config/platform.sh" "$TEST_TMP/.claude/config/platform.sh"
    fi

    # Copy platform wrapper scripts
    # Preserve directory structure: TEST_TMP/.claude/scripts/platform/
    if [[ -d "$SCRIPT_DIR/platform" ]]; then
        mkdir -p "$TEST_TMP/.claude/scripts"
        cp -r "$SCRIPT_DIR/platform" "$TEST_TMP/.claude/scripts/platform"
    fi

    # Create symlink for backward compatibility: TEST_TMP/config and TEST_TMP/platform
    # (in case any code still references the old flattened structure)
    [[ -d "$TEST_TMP/.claude/config" ]] && ln -s "./.claude/config" "$TEST_TMP/config" 2>/dev/null || true
    [[ -d "$TEST_TMP/.claude/scripts/platform" ]] && ln -s "./.claude/scripts/platform" "$TEST_TMP/platform" 2>/dev/null || true

    # Change to test directory
    cd "$TEST_TMP" || exit 1
}

# Clean up test environment
teardown_test_env() {
    if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
        rm -rf "$TEST_TMP"
    fi
}

# =============================================================================
# PORTABLE TIMEOUT (macOS does not ship GNU timeout)
# =============================================================================

if ! command -v timeout &>/dev/null; then
    timeout() {
        local duration="$1"; shift
        perl -e '
            use POSIX ":sys_wait_h";
            alarm shift @ARGV;
            $SIG{ALRM} = sub { kill 15, $pid; waitpid($pid, 0); exit 124 };
            $pid = fork // die "fork: $!";
            if ($pid == 0) { exec @ARGV; die "exec: $!" }
            waitpid($pid, 0);
            exit ($? >> 8);
        ' "$duration" "$@"
    }
    export -f timeout
fi

# =============================================================================
# MOCK FUNCTIONS
# =============================================================================

# Mock for claude CLI
mock_claude() {
    local response_file="${MOCK_CLAUDE_RESPONSE:-}"
    local exit_code="${MOCK_CLAUDE_EXIT_CODE:-0}"

    if [[ -n "$response_file" && -f "$response_file" ]]; then
        cat "$response_file"
    else
        echo '{"result": "mock response", "structured_output": {"status": "success"}}'
    fi

    return "$exit_code"
}

# Mock for gh CLI
mock_gh() {
    local exit_code="${MOCK_GH_EXIT_CODE:-0}"
    echo "Mock gh: $*"
    return "$exit_code"
}

# Mock for git CLI
mock_git() {
    local exit_code="${MOCK_GIT_EXIT_CODE:-0}"
    echo "Mock git: $*"
    return "$exit_code"
}

# Install mocks into PATH
install_mocks() {
    local mock_bin="$TEST_TMP/bin"
    mkdir -p "$mock_bin"

    # Create mock claude
    cat > "$mock_bin/claude" << 'MOCK_EOF'
#!/usr/bin/env bash
source "${BASH_SOURCE%/*}/../mock_functions.bash"
mock_claude "$@"
MOCK_EOF
    chmod +x "$mock_bin/claude"

    # Create mock gh
    cat > "$mock_bin/gh" << 'MOCK_EOF'
#!/usr/bin/env bash
source "${BASH_SOURCE%/*}/../mock_functions.bash"
mock_gh "$@"
MOCK_EOF
    chmod +x "$mock_bin/gh"

    # Export mock functions
    cat > "$TEST_TMP/mock_functions.bash" << 'FUNC_EOF'
mock_claude() {
    local response_file="${MOCK_CLAUDE_RESPONSE:-}"
    if [[ -n "$response_file" && -f "$response_file" ]]; then
        cat "$response_file"
    else
        echo '{"result": "mock response", "structured_output": {"status": "success"}}'
    fi
    return "${MOCK_CLAUDE_EXIT_CODE:-0}"
}

mock_gh() {
    echo "Mock gh: $*"
    return "${MOCK_GH_EXIT_CODE:-0}"
}

mock_git() {
    echo "Mock git: $*"
    return "${MOCK_GIT_EXIT_CODE:-0}"
}
FUNC_EOF

    # Prepend mock bin to PATH
    export PATH="$mock_bin:$PATH"
}

# =============================================================================
# ASSERTION HELPERS
# =============================================================================

# Assert file exists
assert_file_exists() {
    local file="$1"
    local msg="${2:-File should exist: $file}"

    if [[ ! -f "$file" ]]; then
        echo "FAIL: $msg"
        return 1
    fi
    return 0
}

# Assert directory exists
assert_dir_exists() {
    local dir="$1"
    local msg="${2:-Directory should exist: $dir}"

    if [[ ! -d "$dir" ]]; then
        echo "FAIL: $msg"
        return 1
    fi
    return 0
}

# Assert file contains string
assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-File should contain: $pattern}"

    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $msg"
        return 1
    fi
    return 0
}

# Assert JSON field equals value
assert_json_field() {
    local file="$1"
    local field="$2"
    local expected="$3"
    local msg="${4:-JSON field $field should equal $expected}"

    local actual
    actual=$(jq -r "$field" "$file" 2>/dev/null)

    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $msg (got: $actual)"
        return 1
    fi
    return 0
}

# Assert exit code
assert_exit_code() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-Exit code should be $expected}"

    if [[ "$actual" -ne "$expected" ]]; then
        echo "FAIL: $msg (got: $actual)"
        return 1
    fi
    return 0
}

# Assert string equals
assert_equals() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-Values should be equal}"

    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $msg"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        return 1
    fi
    return 0
}

# Assert string contains
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-String should contain: $needle}"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "FAIL: $msg"
        return 1
    fi
    return 0
}

# Fail with message (compatible with bats-assert)
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

# Assert string not empty
assert_not_empty() {
    local value="$1"
    local msg="${2:-Value should not be empty}"

    if [[ -z "$value" ]]; then
        echo "FAIL: $msg"
        return 1
    fi
    return 0
}

# =============================================================================
# SOURCE SCRIPT FUNCTIONS
# =============================================================================

# Source only the functions from the orchestrator (not main execution)
source_orchestrator_functions() {
    # Extract just the functions, not the main execution or argument parsing
    local func_file="$TEST_TMP/orchestrator_functions.bash"

    # Start with shebang
    cat > "$func_file" << 'HEADER'
#!/usr/bin/env bash
# Extracted functions for testing - DO NOT RUN DIRECTLY
HEADER

    # Use awk to extract only function definitions, constants, and config vars
    # This skips argument parsing and immediate execution code
    awk '
        # Extract readonly constant declarations
        /^readonly [A-Z_]+=/ { print; next }

        # Extract configurable limit declarations (MAX_* and ORCHESTRATOR_START_EPOCH)
        /^MAX_[A-Z_]+=/ { print; next }
        /^ORCHESTRATOR_START_EPOCH=/ { print; next }

        # Extract array declarations (DEGRADED_STAGES)
        /^declare -a [A-Z_]+=/ { print; next }

        # Skip the argument parsing section entirely
        /^while \[\[.*\$#.*\]\]; do$/,/^done$/ { next }

        # Skip the validation check and its block
        /^if \[\[ -z "\$ISSUE_NUMBER"/ { next }

        # Skip variable initializations that are not readonly
        /^ISSUE_NUMBER=""$/ { next }
        /^BASE_BRANCH=""$/ { next }
        /^AGENT=""$/ { next }
        /^STATUS_FILE=.*status\.json/ { next }

        # Skip LOG_BASE line that uses ISSUE_NUMBER at runtime
        /^LOG_BASE=.*ISSUE_NUMBER/ { next }

        # Skip the echo header lines
        /^echo "Implement Issue/ { next }
        /^echo "Issue:/ { next }
        /^echo "Branch:/ { next }
        /^echo "Agent:/ { next }
        /^echo "Status file:/ { next }
        /^echo "Log dir:/ { next }

        # Skip mkdir for LOG_BASE (done in test setup)
        /^mkdir -p "\$LOG_BASE/ { next }

        # Skip LOG_FILE assignment (set in test defaults)
        /^LOG_FILE="\$LOG_BASE/ { next }

        # Skip STAGE_COUNTER init (set in test defaults)
        /^STAGE_COUNTER=0$/ { next }

        # Skip _CONSECUTIVE_TIMEOUTS and _TIMED_OUT_STAGE_NAMES init (set in test defaults)
        /^_CONSECUTIVE_TIMEOUTS=0$/ { next }
        /^_TIMED_OUT_STAGE_NAMES=""$/ { next }

        # Skip main invocation
        /^main "\$@"$/ { next }

        # Extract function definitions (function_name() { ... })
        /^[a-z_]+\(\) \{$/,/^\}$/ { print; next }

        # Skip platform config sourcing (test setup creates platform.sh in the right place)
        /^source "\$SCRIPT_DIR\/\.\.\/config\/platform\.sh"/ { next }

        # Extract SCRIPT_DIR, SCHEMA_DIR, PLATFORM_DIR, and REPO
        /^SCRIPT_DIR=/ { print; next }
        /^SCHEMA_DIR=/ { print; next }
        /^PLATFORM_DIR=/ { print; next }
        /^REPO=/ { print; next }
    ' "$ORCHESTRATOR_SCRIPT" >> "$func_file"

    # Add test default variables at the end
    cat >> "$func_file" << 'EOF'

# Test defaults - override these in tests before calling functions
ISSUE_NUMBER="${ISSUE_NUMBER:-123}"
BASE_BRANCH="${BASE_BRANCH:-test}"
AGENT="${AGENT:-}"
STATUS_FILE="${STATUS_FILE:-status.json}"
LOG_BASE="${LOG_BASE:-logs/test}"
LOG_FILE="${LOG_FILE:-$LOG_BASE/orchestrator.log}"
STAGE_COUNTER="${STAGE_COUNTER:-0}"
_CONSECUTIVE_TIMEOUTS="${_CONSECUTIVE_TIMEOUTS:-0}"
_TIMED_OUT_STAGE_NAMES="${_TIMED_OUT_STAGE_NAMES:-}"
QUIET="${QUIET:-false}"
EOF

    # Source model-config.sh first (provides resolve_model, _next_model_up)
    if [[ -f "$TEST_TMP/model-config.sh" ]]; then
        source "$TEST_TMP/model-config.sh"
    fi

    # Source platform config (provides TRACKER, GIT_HOST, etc.)
    if [[ -f "$TEST_TMP/config/platform.sh" ]]; then
        source "$TEST_TMP/config/platform.sh"
    fi

    # Source it
    source "$func_file"

    # Source model-config for resolve_model() and related functions
    if [[ -f "$TEST_TMP/model-config.sh" ]]; then
        source "$TEST_TMP/model-config.sh"
    fi
}
