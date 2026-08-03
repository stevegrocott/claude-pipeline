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

# Stable path to batch-orchestrator.sh captured at load time. SCRIPT_DIR is
# clobbered to TEST_TMP once source_orchestrator_functions() sources the
# extracted SCRIPT_DIR= line, so resume tests must not resolve the batch
# script through SCRIPT_DIR after setup runs.
BATCH_ORCHESTRATOR_SCRIPT_PATH="$SCRIPT_DIR/batch-orchestrator.sh"

# Temp directory for test artifacts
TEST_TMP=""

# Extract `readonly -a NAME=(...)` array declarations out of a script file
# and wrap each one in a `declare -p NAME >/dev/null 2>&1 || { ... }` guard,
# so re-sourcing the result is a no-op when NAME is already global and
# readonly, and still populates it when it is not (see MODEL_CONFIG_ARRAYS_FILE
# below for the full cross-platform rationale).
#
# Handles both declaration styles found in model-config.sh:
#
#     readonly -a _FOO=(
#         a b c
#     )
#     readonly -a _BAR=(a b c)
#
# The guard's closing brace is emitted the moment a captured line ends in
# a closing paren, rather than requiring the closing paren to be alone on
# its own line at column 0. A single-line declaration's opening line IS
# its closing line — matching only `/^\)/` (line starts with `)`) never
# fires for it, so the guard's `{` is opened but never closed and the
# generated file has unbalanced braces. Matching `/\)[[:space:]]*$/`
# (line ends with `)`) instead catches both the single-line case (closes
# on the same line it opens) and the multi-line case (closes on the
# dedicated `)` line), since that line also ends in `)`.
# Usage: _extract_readonly_array_guards <script_file>
_extract_readonly_array_guards() {
    local script_file="$1"

    awk '
        /^readonly -a / {
            name = $3
            sub(/=.*/, "", name)
            print "declare -p " name " >/dev/null 2>&1 || {"
            capture = 1
        }
        capture { print }
        capture && /\)[[:space:]]*$/ { print "}"; capture = 0 }
    ' "$script_file"
}

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

        # Extract the stage-tier arrays into a standalone file so @test
        # bodies can repopulate them regardless of whether
        # source_orchestrator_functions()'s own model-config.sh source (run
        # from setup()) left them declared — bash scopes a `readonly -a`
        # declared inside a function differently across versions.  See
        # MODEL_CONFIG_ARRAYS_FILE for the full rationale.  Only the
        # `readonly -a ...=( ... )` blocks are pulled out — sourcing the
        # whole config would trip the idempotent guard and the surviving
        # readonly scalars.
        #
        # Each extracted block is wrapped in `declare -p <name> || { ... }`
        # so the re-source is a no-op when the array is already global and
        # readonly (Linux) and still populates it fresh when it is not
        # (macOS) — instead of assuming the unset state that only holds on
        # one platform. A trailing non-empty check turns a future
        # regression (e.g. the awk extraction breaking silently) into a
        # named diagnostic instead of downstream assertion noise.
        MODEL_CONFIG_ARRAYS_FILE="$TEST_TMP/model-config-arrays.sh"
        export MODEL_CONFIG_ARRAYS_FILE
        {
            _extract_readonly_array_guards "$TEST_TMP/model-config.sh"

            cat <<'ARRAYS_NONEMPTY_CHECK'
if [[ ${#_LIGHT_STAGES[@]} -eq 0 ]]; then
    echo "FATAL: _LIGHT_STAGES is empty after" \
        "MODEL_CONFIG_ARRAYS_FILE re-source" >&2
    return 1
fi
if [[ ${#_STANDARD_STAGES[@]} -eq 0 ]]; then
    echo "FATAL: _STANDARD_STAGES is empty after" \
        "MODEL_CONFIG_ARRAYS_FILE re-source" >&2
    return 1
fi
if [[ ${#_STAGE_PREFIXES[@]} -eq 0 ]]; then
    echo "FATAL: _STAGE_PREFIXES is empty after" \
        "MODEL_CONFIG_ARRAYS_FILE re-source" >&2
    return 1
fi
ARRAYS_NONEMPTY_CHECK
        } > "$MODEL_CONFIG_ARRAYS_FILE"
    fi

    # Copy platform config (sourced by orchestrator functions)
    # Preserve directory structure: TEST_TMP/.claude/config/platform.sh
    if [[ -f "$SCRIPT_DIR/../config/platform.sh" ]]; then
        mkdir -p "$TEST_TMP/.claude/config"
        cp "$SCRIPT_DIR/../config/platform.sh" "$TEST_TMP/.claude/config/platform.sh"
    fi

    # Copy resolve-pipeline-root.sh — every platform/*.sh wrapper sources
    # "$SCRIPT_DIR/../resolve-pipeline-root.sh" (one level up from platform/),
    # so it must live at TEST_TMP/.claude/scripts/resolve-pipeline-root.sh
    # for comment-issue.sh / comment-mr.sh to source successfully.
    # Unrelated to #652 — pre-existing test-infra gap found while running the
    # full suite for this branch; called out here rather than split out since
    # it's additive and guarded by the -f check below.
    if [[ -f "$SCRIPT_DIR/resolve-pipeline-root.sh" ]]; then
        mkdir -p "$TEST_TMP/.claude/scripts"
        cp "$SCRIPT_DIR/resolve-pipeline-root.sh" "$TEST_TMP/.claude/scripts/resolve-pipeline-root.sh"
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

# Make the real bash-backend escalation scripts reachable from TEST_TMP.
#
# run_stage funnels every outcome through a single decide-action.sh call,
# invoked as `bash "$SCRIPT_DIR/decide-action.sh" ...`.  Inside the test
# harness SCRIPT_DIR resolves to TEST_TMP (the extracted functions file
# lives there), so without these copies the invocation fails and run_stage
# bails on every stage — masking the CLI-argument and escalation assertions
# the stage-runner suite actually exercises.
#
# The bash backend (the default) is pure shell with no LLM dependency, so
# copying the three decide-* scripts plus model-config.sh yields a fully
# deterministic decision: success -> accept, structured_error -> escalate,
# ceiling/permission/no-output -> bail, rate_limit -> retry_same.  Schemas
# already land in TEST_TMP/schemas via setup_test_env.
install_decide_scripts() {
    local script
    for script in decide-action.sh decide-retry.sh decide-model-fallback.sh; do
        [[ -f "$SCRIPT_DIR/$script" ]] || {
            echo "FATAL: $script missing from $SCRIPT_DIR" >&2
            return 1
        }
        cp "$SCRIPT_DIR/$script" "$TEST_TMP/$script"
        chmod +x "$TEST_TMP/$script"
    done

    # Pin the bash backend so no decision path reaches for the live CLI.
    export ESCALATION_POLICY_BACKEND=bash
    export RETRY_POLICY_BACKEND=bash
    export MODEL_FALLBACK_BACKEND=bash
}

# Path to the array-only extract of model-config.sh, generated by
# setup_test_env (see MODEL_CONFIG_ARRAYS_FILE below).  @test bodies that
# exercise model/tier resolution must re-source this at @test scope with:
#
#     source "$MODEL_CONFIG_ARRAYS_FILE"
#
# Why this exists, and why it must be a bare `source` at @test scope rather
# than a helper function:
#
# CORRECTED (issue #743): there is no setup()->@test fork. bats-exec-test
# (bats-core 1.13.0/1.14.0) runs `{ setup "$@"; "$@"; } >>"$BATS_OUT" 2>&1`
# in bats_perform_test — a brace group, not a subshell — so setup() and the
# @test body execute back to back in the very same bash process. What
# differs cross-platform is not fork survival but whether bash treats a
# `readonly -a` declared *inside a function* as global or function-local.
#
# setup() calls source_orchestrator_functions(), which is a function that
# itself `source`s model-config.sh (to pull in resolve_model()). That file
# declares _STAGE_PREFIXES / _STANDARD_STAGES / _LIGHT_STAGES with
# `readonly -a`, plus the scalar guard `readonly _MODEL_CONFIG_LOADED=1`.
# Minimal repro of what happens to those declarations once the function
# returns:
#
#     inner() { readonly _S=1; readonly -a _A=(x y z); }
#     inner
#     declare -p _S   # -> declare -r _S="1"           (bash 3.2 AND 5.x)
#     declare -p _A   # bash 3.2.57 (macOS's frozen, pre-GPLv3 /bin/bash):
#                     #   "declare: _A: not found" -- local to inner(), gone
#                     # bash 5.3.x (Linux, and any non-Apple bash):
#                     #   declare -ar _A=([0]="x" [1]="y" [2]="z") -- global
#
# The readonly *scalar* is global on both platforms; only the readonly
# *array* is scoped to the function on bash 3.2 and escapes it on bash
# 4.x+/5.x. Confirmed against the actual harness by probing state right
# after setup() returns, before the @test body's re-source runs:
#   macOS bash 3.2.57  -> _MODEL_CONFIG_LOADED declared, _LIGHT_STAGES unset
#   Linux bash 5.3.9/15 -> both declared; _LIGHT_STAGES already readonly
#
# So on macOS, source_orchestrator_functions()'s own model-config.sh source
# leaves the arrays unset once it returns (function-local, discarded), and
# the @test body's `source "$MODEL_CONFIG_ARRAYS_FILE"` is the *first* time
# they're declared — it succeeds. On Linux the same source call leaves them
# already global and readonly, so the identical re-source hits
# `readonly variable` and aborts under BATS's `set -eET`, leaving
# _STAGE_PREFIXES / _STANDARD_STAGES / _LIGHT_STAGES empty for every
# subsequent test in the run. With the prefix table empty,
# _match_stage_prefix matches nothing and resolve_model collapses every
# stage to the advanced (opus) fallback tier, breaking model and max-turns
# assertions.
#
# model-config.sh's idempotent source guard (readonly _MODEL_CONFIG_LOADED,
# which — per above — survives on both platforms) means re-sourcing the
# whole file is not a fix either: on Linux the guard short-circuits and
# never reaches the array blocks; on macOS the scalar's own re-declaration
# would abort first. setup_test_env instead extracts just the
# `readonly -a ...=( ... )` blocks into MODEL_CONFIG_ARRAYS_FILE, with each
# block wrapped in `declare -p <name> >/dev/null 2>&1 || { ... }` so the
# re-declaration is skipped when the array is already global (Linux) and
# still runs when it is not (macOS) — instead of assuming either state.
# A trailing check asserts all three arrays are non-empty once the file is
# sourced, so a broken extraction fails with a named diagnostic instead of
# empty-array symptoms downstream.
#
# The source MUST run at @test scope: `readonly -a` inside a function
# creates a function-local array invisible to the caller (the same rule
# documented above), so wrapping it in a helper would silently leave the
# global arrays empty.
MODEL_CONFIG_ARRAYS_FILE=""

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
# HARD ASSERTIONS (expect_*)
#
# BATS does not abort a test body on a bare failing command — only the FINAL
# command's exit status decides pass/fail.  Verified with bats 1.13:
#
#     @test "intermediate failing assertion" {
#         [[ "abc" == "xyz" ]]   # <- returns 1, silently ignored
#         [[ "abc" == "abc" ]]
#     }                          # -> reported "ok"
#
# So every assertion except the last is inert when written as a bare
# `[[ ... ]]`, and the `return 1`-style assert_* helpers above have the same
# problem for the same reason.  The expect_* helpers below `exit 1` instead,
# which terminates the test's subshell and is reported as a failure, so a test
# can assert as many times as it needs without any of them being dropped.
# Prefer these over bare `[[ ... ]]` in any test that asserts more than once.
# =============================================================================

# expect_glob <actual> <pattern> [label]
# Fail unless <actual> matches the bash glob <pattern>.  The pattern is left
# unquoted at the match site, so *, ?, and [...] are wildcards.
expect_glob() {
    local actual="$1"
    local pattern="$2"
    local label="${3:-value should match pattern}"

    if [[ "$actual" != $pattern ]]; then
        printf 'FAIL: %s\n  expected pattern: %s\n  actual:           %s\n' \
            "$label" "$pattern" "$actual" >&2
        exit 1
    fi
}

# expect_ok <label> <command...>
# Fail unless <command> exits 0.
expect_ok() {
    local label="$1"
    shift

    if ! "$@"; then
        printf 'FAIL: %s\n  expected success from: %s\n' "$label" "$*" >&2
        exit 1
    fi
}

# expect_not_ok <label> <command...>
# Fail unless <command> exits non-zero.
expect_not_ok() {
    local label="$1"
    shift

    if "$@"; then
        printf 'FAIL: %s\n  expected failure from: %s\n' "$label" "$*" >&2
        exit 1
    fi
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
        /^[a-z_][a-z_0-9]*\(\) \{$/,/^\}$/ { print; next }

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
CLAUDE_CLI="${CLAUDE_CLI:-claude}"
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

# Source a single named function from batch-orchestrator.sh in isolation,
# without running its top-level argument parsing or main loop. Used to
# functionally test resume behaviour (init_status) without spinning up a
# full batch. The closing brace must be at column 0 (the project style),
# so the awk range captures exactly one function body.
source_batch_function() {
    local func_name="$1"
    local batch_script="$BATCH_ORCHESTRATOR_SCRIPT_PATH"
    local func_file="$TEST_TMP/batch_${func_name}.bash"

    awk -v fn="$func_name" '
        $0 ~ "^"fn"\\(\\) \\{$" { capture = 1 }
        capture { print }
        capture && /^\}$/ { capture = 0 }
    ' "$batch_script" > "$func_file"

    # Provide harmless stand-ins for collaborators init_status touches so the
    # extracted function runs without the rest of the script. Tests may
    # override these after sourcing.
    log() { :; }

    source "$func_file"
}

# Extract the body of a named function from a script file.
# Uses brace counting so nested blocks with closing braces at
# column 0 do not prematurely end the capture.
#
# OUTPUT INCLUDES THE FUNCTION DECLARATION LINE: awk evaluates all
# matching rules in order for each input line.  Rule 1 matches the
# declaration (e.g. `foo() {`) and sets capture=1; rule 2 then fires
# for that same line (capture is now true) and prints it.  Consequently
# the output starts with `func_name() {` — not just the body lines.
# Callers that grep the output for the function name (e.g.
# source_validate_issue_for_processing) rely on this guarantee.
#
# Brace-style assumption: the function header must appear on a single
# line matching /^name\(\) *\{$/ — that is, the opening brace must be
# on the same line as the parameter list (K&R / one-true-brace style),
# with zero or more spaces between ')' and '{'. Multi-line headers or
# Allman-style braces (brace on the next line) are NOT supported.
# Usage: _extract_function_body <func_name> <file>
_extract_function_body() {
	local func_name="$1"
	local script_file="$2"
	awk -v fn="$func_name" '
		$0 ~ "^"fn"\\(\\) *\\{$" { capture = 1; depth = 0 }
		capture {
			print
			depth += split($0, _o, /\{/) - 1
			depth -= split($0, _c, /\}/) - 1
			if (depth <= 0) capture = 0
		}
	' "$script_file"
}
