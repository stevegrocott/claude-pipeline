#!/bin/bash
# Usage: read-mr-checks.sh <mr-number> [--failed-log <check-name>]
# Returns: JSON {"head_sha": "...", "checks": [{name,status,conclusion,url}]}
#   With --failed-log: the failed-step log of a FAILED run of that named
#   check instead, with gh's job, step and timestamp columns removed. When
#   that prints nothing (e.g. the run is still in progress) and the URL names
#   a job, the whole job log from the jobs API, with its byte order mark and
#   leading timestamps removed. Empty output, exit 0 when no failed run has
#   that name, for a non-Actions URL, or when no log can be read; in the last
#   case gh's error text goes to stderr.
#   On gitlab (no checks API wired up): {"head_sha":null,"checks":[]}, and
#   empty output with --failed-log. Always exit 0.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../resolve-pipeline-root.sh
source "$SCRIPT_DIR/../resolve-pipeline-root.sh"
PLATFORM_SH_FILE="$(resolve_consumer_file platform.sh)" || {
    echo "FATAL: platform.sh not found (checked \$PIPELINE_CONFIG_DIR," \
        "<repo-root>/.claude/config/, and the legacy fallback)." \
        "Cannot continue without consumer platform config." >&2
    exit 1
}
# shellcheck disable=SC1090
source "$PLATFORM_SH_FILE"

USAGE="Usage: read-mr-checks.sh <mr-number> [--failed-log <check-name>]"
if [[ $# -lt 1 || -z "$1" ]]; then
    echo "$USAGE" >&2
    exit 1
fi
MR="$1"
CHECK_NAME=""
FAILED_LOG=false
if [[ $# -ge 2 ]]; then
    if [[ "$2" == "--failed-log" && $# -eq 3 && -n "$3" ]]; then
        FAILED_LOG=true
        CHECK_NAME="$3"
    else
        echo "$USAGE" >&2
        exit 1
    fi
fi

github_checks() {
    local pr_json
    pr_json="$(gh pr view "$MR" --json headRefOid,statusCheckRollup)"
    jq '{
        head_sha: .headRefOid,
        checks: [(.statusCheckRollup // [])[] | {
            name: (.name // .context),
            status: (.status // .state),
            conclusion: (.conclusion // null),
            url: (.detailsUrl // .targetUrl // null)
        }]
    }' <<< "$pr_json"
}

# gh prints each log line as "<job>\t<step>\t<timestamp> <text>". Strip the
# three columns so a caller can anchor on the text (e.g. "^not ok").
_strip_log_columns() {
    awk '{
        if (sub(/^[^\t]*\t[^\t]*\t/, "")) {
            sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z ?/, "")
        }
        print
    }'
}

# The jobs API prints each line as "<timestamp> <text>" and starts the log
# with a byte order mark. LC_ALL=C so awk matches the mark byte by byte.
_strip_api_log_prefix() {
    LC_ALL=C awk '{
        if (NR == 1) {
            sub(/^\357\273\277/, "")
        }
        sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z ?/, "")
        print
    }'
}

# True when the file opens like a job log: a timestamp, after any byte order
# mark. A success status alone does not show the reply is a log.
_is_api_log() {
    local first=""
    IFS= read -r first < "$1" || true
    first="${first#$'\357\273\277'}"
    [[ "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ]]
}

# The body is a subshell so the EXIT trap removes the temp dir on any exit.
github_failed_log() (
    local url run_id job_id="" tmp_dir
    local -a args
    # One name can cover several runs (push and pull_request triggers, or a
    # rerun); only a failed one has a failed-step log.
    url="$(github_checks | jq -r --arg n "$CHECK_NAME" '
        ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED",
         "STARTUP_FAILURE"] as $failed
        | [.checks[]
            | select(.name == $n)
            | select((.conclusion // .status // "") as $c | $failed | index($c))
          ][0].url // empty')"
    if [[ -z "$url" ]]; then
        return 0
    fi
    if [[ "$url" =~ /runs/([0-9]+) ]]; then
        run_id="${BASH_REMATCH[1]}"
    else
        return 0
    fi
    args=(run view "$run_id" --log-failed)
    if [[ "$url" =~ /job/([0-9]+) ]]; then
        job_id="${BASH_REMATCH[1]}"
        args+=(--job "$job_id")
    fi
    tmp_dir="$(mktemp -d)" || return 0
    trap 'rm -rf "$tmp_dir"' EXIT
    gh "${args[@]}" > "$tmp_dir/log" 2> "$tmp_dir/err" || true
    if [[ -s "$tmp_dir/log" ]]; then
        _strip_log_columns < "$tmp_dir/log" || true
        return 0
    fi
    # gh refuses --log-failed until every job in the run has finished, but
    # the jobs API serves a finished job's log at once.
    if [[ -n "$job_id" ]]; then
        # On an HTTP error gh api prints the error body on stdout, so the
        # output counts as a log only when the call succeeds.
        if gh api "repos/{owner}/{repo}/actions/jobs/$job_id/logs" \
            > "$tmp_dir/log" 2> "$tmp_dir/api_err" \
            && _is_api_log "$tmp_dir/log"; then
            _strip_api_log_prefix < "$tmp_dir/log" || true
            return 0
        fi
        # Report the last error gh gave; a successful reply that is not a
        # log has none, so the run view error stands.
        if [[ -s "$tmp_dir/api_err" ]]; then
            cat "$tmp_dir/api_err" > "$tmp_dir/err"
        fi
    fi
    cat "$tmp_dir/err" >&2
)

case "$GIT_HOST" in
  github)
    if [[ "$FAILED_LOG" == true ]]; then
        github_failed_log
    else
        github_checks
    fi
    ;;
  gitlab)
    if [[ "$FAILED_LOG" != true ]]; then
        echo '{"head_sha":null,"checks":[]}'
    fi
    exit 0
    ;;
  *)
    echo "ERROR: unrecognised GIT_HOST '$GIT_HOST'" \
      "(accepted: github, gitlab)" >&2
    exit 1
    ;;
esac
