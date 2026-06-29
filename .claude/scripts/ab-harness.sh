#!/usr/bin/env bash
#
# ab-harness.sh
# A/B harness comparing CONTEXT_MODE_ENABLED=0 (control) vs =1
# (treatment) on real issues via two isolated git worktrees.
#
# Two arm branches are forked from the base branch and checked out
# in separate worktrees.  batch-orchestrator.sh runs in parallel in
# each worktree with CONTEXT_MODE_ENABLED toggled.  Both arms are
# awaited; ab-report.sh is invoked to produce a comparison report.
# Worktrees and arm branches are removed on EXIT.
#
# Usage:
#   ab-harness.sh --issues "N1,N2,N3" --base-branch main
#   ab-harness.sh --manifest <path> --base-branch main
#
# Options:
#   --issues <list>        Comma-separated issue numbers
#   --manifest <path>      manifest.json with issues/base_branch keys
#   --base-branch <name>   Branch to fork arm branches from
#   --agent <name>         Agent for implement-issue (optional)
#   -h, --help             Show this help
#
# Outputs:
#   logs/ab-TIMESTAMP/
#     harness.log            This harness's log
#     control-run.log        Control arm (batch-orchestrator) output
#     treatment-run.log      Treatment arm output
#     preserved-control/     Arm logs preserved before cleanup
#     preserved-treatment/   Arm logs preserved before cleanup
#     report.md              Comparison report (from ab-report.sh)
#     ab-results.json        Structured results (from ab-report.sh)
#
# Exit codes:
#   0  Arms ran; report generated (check arm state for per-arm errors)
#   1  Fatal error (worktree setup, report failure, etc.)
#   3  Configuration / argument error
#

# -e (errexit) is intentionally omitted: every command that may fail is
# checked explicitly (|| die / if !), so failure paths stay visible and
# controllable rather than silently aborting on any non-zero exit.
set -uo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# =============================================================================
# USAGE / ERROR HELPERS
# =============================================================================

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

die_usage() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 3
}

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [options]

A/B harness comparing CONTEXT_MODE_ENABLED=0 (control) vs =1 (treatment).

Options:
    --issues <list>        Comma-separated issue numbers
    --manifest <path>      manifest.json with issues/base_branch keys
    --base-branch <name>   Branch to fork arm branches from
    --agent <name>         Agent for implement-issue stage (optional)
    -h, --help             Show this help

Exit codes:
    0  Arms ran; report generated
    1  Fatal error
    3  Configuration / argument error

Example:
    $SCRIPT_NAME --issues "537,538" --base-branch main
EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

MANIFEST=""
ISSUES=""
BASE_BRANCH=""
AGENT=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--issues)
			[[ -n "${2:-}" ]] || die_usage "--issues requires a value"
			ISSUES="$2"
			shift 2
			;;
		--manifest)
			[[ -n "${2:-}" ]] || \
				die_usage "--manifest requires a value"
			MANIFEST="$2"
			shift 2
			;;
		--base-branch)
			[[ -n "${2:-}" ]] || \
				die_usage "--base-branch requires a value"
			BASE_BRANCH="$2"
			shift 2
			;;
		--agent)
			[[ -n "${2:-}" ]] || die_usage "--agent requires a value"
			AGENT="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			die_usage "unknown option: $1"
			;;
		*)
			die_usage "unexpected argument: $1"
			;;
	esac
done

if [[ -n "$MANIFEST" ]]; then
	[[ -f "$MANIFEST" ]] || die_usage "manifest not found: $MANIFEST"
	if [[ -z "$ISSUES" ]]; then
		ISSUES=$(jq -r '.issues | join(",")' "$MANIFEST") \
			|| die "failed to parse issues from manifest"
	fi
	if [[ -z "$BASE_BRANCH" ]]; then
		BASE_BRANCH=$(jq -r '.base_branch' "$MANIFEST") \
			|| die "failed to parse base_branch from manifest"
	fi
	if [[ -z "$AGENT" ]]; then
		AGENT=$(jq -r '.agent // empty' "$MANIFEST" \
			2>/dev/null) \
			|| printf '%s: warn: jq failed parsing .agent in %s\n' \
				"$SCRIPT_NAME" "$MANIFEST" >&2
	fi
fi

[[ -n "$ISSUES" ]] \
	|| die_usage "must provide --issues or --manifest with issues"
[[ -n "$BASE_BRANCH" ]] \
	|| die_usage \
		"must provide --base-branch or --manifest with base_branch"

# =============================================================================
# RUNTIME CONFIGURATION
# =============================================================================

readonly AB_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Arm branch names — unique to this run so parallel runs do not clash
readonly CONTROL_BRANCH="ab-${AB_TIMESTAMP}-control"
readonly TREATMENT_BRANCH="ab-${AB_TIMESTAMP}-treatment"

# All output lands under logs/ab-TIMESTAMP/ (logs/ is gitignored)
readonly AB_LOG_DIR="$REPO_ROOT/logs/ab-$AB_TIMESTAMP"
readonly CONTROL_WT="$AB_LOG_DIR/worktrees/control"
readonly TREATMENT_WT="$AB_LOG_DIR/worktrees/treatment"

# Background arm PIDs (populated by launch_arm)
CONTROL_PID=""
TREATMENT_PID=""

# Guards for selective cleanup on EXIT
CONTROL_BRANCH_CREATED=false
TREATMENT_BRANCH_CREATED=false
CONTROL_WT_CREATED=false
TREATMENT_WT_CREATED=false

# Establish log dir before first log() call
mkdir -p "$AB_LOG_DIR"
readonly LOG_FILE="$AB_LOG_DIR/harness.log"

# =============================================================================
# LOGGING (stderr + file; never stdout — this script produces no stdout data)
# =============================================================================

log() {
	local msg="[$(date -Iseconds)] $*"
	printf '%s\n' "$msg" >> "$LOG_FILE"
	printf '%s\n' "$msg" >&2
}

log_warn() {
	local msg="[$(date -Iseconds)] WARN: $*"
	printf '%s\n' "$msg" >> "$LOG_FILE"
	printf '%s\n' "$msg" >&2
}

log_error() {
	local msg="[$(date -Iseconds)] ERROR: $*"
	printf '%s\n' "$msg" >> "$LOG_FILE"
	printf '%s\n' "$msg" >&2
}

# =============================================================================
# CLEANUP (EXIT TRAP)
# =============================================================================

# cleanup — called on EXIT.
#
# Execution order:
#   1. Preserve arm log dirs so they survive worktree removal.
#   2. Kill any still-running arm processes.
#   3. Remove worktrees (git worktree remove --force).
#   4. Prune stale worktree refs.
#   5. Delete arm branches.
#
# Non-fatal: all git/cp commands use || true so a partial cleanup
# does not mask the real exit code.

cleanup() {
	log "Cleanup: preserving arm artifacts before worktree removal"

	if $CONTROL_WT_CREATED; then
		local ctrl_save="$AB_LOG_DIR/preserved-control"
		mkdir -p "$ctrl_save"
		if [[ -f "$CONTROL_WT/status.json" ]]; then
			cp "$CONTROL_WT/status.json" \
				"$ctrl_save/status.json" 2>/dev/null || true
		fi
		if [[ -d "$CONTROL_WT/logs" ]]; then
			cp -r "$CONTROL_WT/logs" \
				"$ctrl_save/logs" 2>/dev/null || true
		fi
	fi

	if $TREATMENT_WT_CREATED; then
		local treat_save="$AB_LOG_DIR/preserved-treatment"
		mkdir -p "$treat_save"
		if [[ -f "$TREATMENT_WT/status.json" ]]; then
			cp "$TREATMENT_WT/status.json" \
				"$treat_save/status.json" 2>/dev/null || true
		fi
		if [[ -d "$TREATMENT_WT/logs" ]]; then
			cp -r "$TREATMENT_WT/logs" \
				"$treat_save/logs" 2>/dev/null || true
		fi
	fi

	if [[ -n "$CONTROL_PID" ]] \
			&& kill -0 "$CONTROL_PID" 2>/dev/null; then
		log "Cleanup: terminating control arm (PID $CONTROL_PID)"
		kill "$CONTROL_PID" 2>/dev/null || true
	fi
	if [[ -n "$TREATMENT_PID" ]] \
			&& kill -0 "$TREATMENT_PID" 2>/dev/null; then
		log "Cleanup: terminating treatment arm" \
			"(PID $TREATMENT_PID)"
		kill "$TREATMENT_PID" 2>/dev/null || true
	fi

	log "Cleanup: removing arm worktrees"

	if $CONTROL_WT_CREATED; then
		git -C "$REPO_ROOT" worktree remove --force \
			"$CONTROL_WT" 2>/dev/null || true
	fi
	if $TREATMENT_WT_CREATED; then
		git -C "$REPO_ROOT" worktree remove --force \
			"$TREATMENT_WT" 2>/dev/null || true
	fi

	git -C "$REPO_ROOT" worktree prune 2>/dev/null || true

	log "Cleanup: deleting arm branches"

	if $CONTROL_BRANCH_CREATED; then
		git -C "$REPO_ROOT" branch -D \
			"$CONTROL_BRANCH" 2>/dev/null || true
	fi
	if $TREATMENT_BRANCH_CREATED; then
		git -C "$REPO_ROOT" branch -D \
			"$TREATMENT_BRANCH" 2>/dev/null || true
	fi

	log "Cleanup complete. Artifacts preserved in $AB_LOG_DIR"
}

trap cleanup EXIT

# =============================================================================
# WORKTREE SETUP
# =============================================================================

# setup_arm_branch <arm_name> <arm_branch>
#
# Creates the arm branch from BASE_BRANCH without checking it out
# (git branch, not git checkout -b). The branch is used as the
# target for PRs created by batch-orchestrator.sh inside the arm.
setup_arm_branch() {
	local arm_name="$1"
	local arm_branch="$2"

	log "Creating $arm_name branch: $arm_branch (from $BASE_BRANCH)"
	if ! git -C "$REPO_ROOT" branch \
			"$arm_branch" "$BASE_BRANCH" 2>>"$LOG_FILE"; then
		log_error "failed to create $arm_name branch: $arm_branch"
		return 1
	fi
	return 0
}

# setup_arm_worktree <arm_name> <arm_branch> <arm_wt_path>
#
# Creates a git worktree at arm_wt_path checked out on arm_branch.
setup_arm_worktree() {
	local arm_name="$1"
	local arm_branch="$2"
	local arm_wt="$3"

	mkdir -p "$(dirname "$arm_wt")"
	log "Creating $arm_name worktree at $arm_wt"
	if ! git -C "$REPO_ROOT" worktree add \
			"$arm_wt" "$arm_branch" 2>>"$LOG_FILE"; then
		log_error "failed to create $arm_name worktree: $arm_wt"
		return 1
	fi
	return 0
}

# =============================================================================
# ARM LAUNCHER
# =============================================================================

# launch_arm <arm_name> <arm_wt> <arm_branch> <ctx_mode> <pid_varname>
#
# Runs batch-orchestrator.sh as a background child process of the
# calling shell.  CWD is set to the arm worktree so all relative git
# commands (git checkout, git pull, etc.) operate on the arm branch.
# CONTEXT_MODE_ENABLED is set per arm.
#
# The background PID is stored in the variable named by pid_varname
# (using printf -v so the caller can `wait` on it directly).
#
# Design note: this function is called as a plain invocation (not via
# $(...)), so the background process launched with & is a direct child
# of the main shell — `wait <pid>` in main() therefore works.
launch_arm() {
	local arm_name="$1"
	local arm_wt="$2"
	local arm_branch="$3"
	local context_mode="$4"
	local pid_varname="$5"
	local arm_log="$AB_LOG_DIR/${arm_name}-run.log"

	local -a agent_args=()
	if [[ -n "$AGENT" ]]; then
		agent_args=(--agent "$AGENT")
	fi

	log "Launching $arm_name arm" \
		"(CONTEXT_MODE_ENABLED=$context_mode)"
	log "$arm_name: issues=$ISSUES  branch=$arm_branch"

	(
		cd "$arm_wt" || exit 1
		export CONTEXT_MODE_ENABLED="$context_mode"
		bash "$SCRIPT_DIR/batch-orchestrator.sh" \
			--issues "$ISSUES" \
			--branch "$arm_branch" \
			${agent_args[@]+"${agent_args[@]}"} \
			>> "$arm_log" 2>&1
	) &

	# Store the subshell PID in the caller's variable.
	# The subshell is a direct child of the main shell, so
	# `wait "$pid_varname"` works in main().
	printf -v "$pid_varname" '%s' "$!"
}

# =============================================================================
# REPORTING HELPERS
# =============================================================================

# resolve_log_dir <worktree_path> <arm_name>
#
# Reads the arm's status.json to locate the batch log directory
# used by batch-orchestrator.sh (the log_dir field).
# Prints the absolute path to stdout; prints nothing on failure.
resolve_log_dir() {
	local wt_path="$1"
	local arm_name="$2"
	local status_file="$wt_path/status.json"

	# batch-orchestrator.sh may write status.json into a LOG_BASE
	# subdirectory rather than the worktree root. Search up to 3
	# levels deep so the harness finds it without assuming a fixed
	# layout, and emit a clear diagnostic showing both the expected
	# path and where the file was actually found.
	if [[ ! -f "$status_file" ]]; then
		local found
		found=$(find "$wt_path" -maxdepth 3 \
			-name "status.json" -print -quit 2>/dev/null)
		if [[ -n "$found" ]]; then
			log_warn "$arm_name: status.json not at worktree" \
				"root; using $found"
			status_file="$found"
		else
			log_warn "$arm_name: status.json not found" \
				"(checked $status_file and subdirs)"
			return
		fi
	fi

	local log_dir
	log_dir=$(jq -r '.log_dir // empty' "$status_file" \
		2>/dev/null) || log_dir=""

	if [[ -z "$log_dir" ]]; then
		log_warn "$arm_name: log_dir missing in status.json"
		return
	fi

	# Relative log_dir is relative to the worktree root
	if [[ "$log_dir" == /* ]]; then
		printf '%s\n' "$log_dir"
	else
		printf '%s\n' "$wt_path/$log_dir"
	fi
}

# invoke_report <control_log_dir> <treatment_log_dir>
#
# Calls ab-report.sh with both arm log directories. Writes results to
# AB_LOG_DIR. Warns (non-fatal) when ab-report.sh is not yet present.
invoke_report() {
	local ctrl_log="$1"
	local treat_log="$2"
	local report_script="$SCRIPT_DIR/ab-report.sh"

	if [[ ! -f "$report_script" ]]; then
		log_warn "ab-report.sh not found — skipping report"
		log_warn "Run manually when ab-report.sh is available:"
		log_warn "  $report_script \\"
		log_warn "    --control-log-dir \"$ctrl_log\" \\"
		log_warn "    --treatment-log-dir \"$treat_log\" \\"
		log_warn "    --output-dir \"$AB_LOG_DIR\""
		return 0
	fi

	log "Invoking ab-report.sh"
	local report_rc=0
	bash "$report_script" \
		--control-log-dir "$ctrl_log" \
		--treatment-log-dir "$treat_log" \
		--output-dir "$AB_LOG_DIR" \
		>> "$LOG_FILE" 2>&1 \
		|| report_rc=$?

	if (( report_rc != 0 )); then
		log_error "ab-report.sh failed (exit $report_rc)"
		return 1
	fi

	log "Report written to $AB_LOG_DIR/report.md"
	return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
	log "=========================================="
	log "A/B Harness Starting"
	log "=========================================="
	log "Issues:            $ISSUES"
	log "Base branch:       $BASE_BRANCH"
	log "Agent:             ${AGENT:-default}"
	log "Timestamp:         $AB_TIMESTAMP"
	log "Control branch:    $CONTROL_BRANCH"
	log "Treatment branch:  $TREATMENT_BRANCH"
	log "Log dir:           $AB_LOG_DIR"
	log "=========================================="

	# Verify base branch exists before touching anything
	if ! git -C "$REPO_ROOT" rev-parse \
			--verify "$BASE_BRANCH" >/dev/null 2>&1; then
		die "base branch does not exist: $BASE_BRANCH"
	fi

	# ------------------------------------------------------------------
	# Create arm branches (no checkout — branch pointer only)
	# ------------------------------------------------------------------
	if ! setup_arm_branch "control" "$CONTROL_BRANCH"; then
		die "aborting: control branch setup failed"
	fi
	CONTROL_BRANCH_CREATED=true

	if ! setup_arm_branch "treatment" "$TREATMENT_BRANCH"; then
		die "aborting: treatment branch setup failed"
	fi
	TREATMENT_BRANCH_CREATED=true

	# ------------------------------------------------------------------
	# Create arm worktrees (each checked out on its arm branch)
	# ------------------------------------------------------------------
	if ! setup_arm_worktree \
			"control" "$CONTROL_BRANCH" "$CONTROL_WT"; then
		die "aborting: control worktree setup failed"
	fi
	CONTROL_WT_CREATED=true

	if ! setup_arm_worktree \
			"treatment" "$TREATMENT_BRANCH" "$TREATMENT_WT"; then
		die "aborting: treatment worktree setup failed"
	fi
	TREATMENT_WT_CREATED=true

	# ------------------------------------------------------------------
	# Launch both arms in parallel
	# ------------------------------------------------------------------
	launch_arm \
		"control" "$CONTROL_WT" "$CONTROL_BRANCH" "0" CONTROL_PID
	log "Control arm PID: $CONTROL_PID"

	launch_arm \
		"treatment" "$TREATMENT_WT" "$TREATMENT_BRANCH" "1" \
		TREATMENT_PID
	log "Treatment arm PID: $TREATMENT_PID"

	log "Waiting for both arms to complete..."

	# ------------------------------------------------------------------
	# Wait for both arms; collect exit codes
	# ------------------------------------------------------------------
	local control_exit=0
	local treatment_exit=0

	wait "$CONTROL_PID" || control_exit=$?
	log "Control arm finished (exit $control_exit)"

	wait "$TREATMENT_PID" || treatment_exit=$?
	log "Treatment arm finished (exit $treatment_exit)"

	if (( control_exit != 0 )); then
		log_warn "Control arm exited non-zero: $control_exit"
	fi
	if (( treatment_exit != 0 )); then
		log_warn "Treatment arm exited non-zero: $treatment_exit"
	fi

	# ------------------------------------------------------------------
	# Resolve arm log directories from each arm's status.json
	# ------------------------------------------------------------------
	local control_log_dir treatment_log_dir
	control_log_dir=$(resolve_log_dir "$CONTROL_WT" "control")
	treatment_log_dir=$(resolve_log_dir "$TREATMENT_WT" "treatment")

	log "Control log dir:   ${control_log_dir:-unknown}"
	log "Treatment log dir: ${treatment_log_dir:-unknown}"

	# ------------------------------------------------------------------
	# Generate comparison report (non-fatal if ab-report.sh missing)
	# ------------------------------------------------------------------
	local report_exit=0
	invoke_report "$control_log_dir" "$treatment_log_dir" \
		|| report_exit=$?

	# ------------------------------------------------------------------
	# Final summary
	# ------------------------------------------------------------------
	log "=========================================="
	log "A/B Harness Complete"
	log "=========================================="
	log "Control:   exit=$control_exit" \
		" dir=${control_log_dir:-unknown}"
	log "Treatment: exit=$treatment_exit" \
		" dir=${treatment_log_dir:-unknown}"
	log "Harness log: $LOG_FILE"

	if [[ -f "$AB_LOG_DIR/report.md" ]]; then
		log "Report:  $AB_LOG_DIR/report.md"
	fi
	if [[ -f "$AB_LOG_DIR/ab-results.json" ]]; then
		log "Results: $AB_LOG_DIR/ab-results.json"
	fi

	return $report_exit
}

main "$@"
