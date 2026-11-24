#!/bin/bash
# Usage: read-mr-checks.sh <mr-number> [check-name]
# Returns: JSON {"head_sha": "...", "checks": [{name,status,conclusion,url}]}
#   With check-name: the failed-step log of that named check instead.
#   On gitlab: empty output, exit 0 (no checks API wired up).
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

if [[ $# -lt 1 || -z "$1" ]]; then
    echo "Usage: read-mr-checks.sh <mr-number> [check-name]" >&2
    exit 1
fi
MR="$1"
CHECK_NAME="${2:-}"

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

github_failed_log() {
    local url run_id job_id
    local -a args
    url="$(github_checks | jq -r --arg n "$CHECK_NAME" \
        '[.checks[] | select(.name == $n)][0].url // empty')"
    if [[ -z "$url" ]]; then
        echo "ERROR: no check named '$CHECK_NAME' on MR $MR" >&2
        exit 1
    fi
    if [[ "$url" =~ /runs/([0-9]+) ]]; then
        run_id="${BASH_REMATCH[1]}"
    else
        echo "ERROR: cannot derive run id from '$url'" >&2
        exit 1
    fi
    args=(run view "$run_id" --log-failed)
    if [[ "$url" =~ /job/([0-9]+) ]]; then
        job_id="${BASH_REMATCH[1]}"
        args+=(--job "$job_id")
    fi
    gh "${args[@]}"
}

case "$GIT_HOST" in
  github)
    if [[ -n "$CHECK_NAME" ]]; then
        github_failed_log
    else
        github_checks
    fi
    ;;
  gitlab) exit 0 ;;
  *)
    echo "ERROR: unrecognised GIT_HOST '$GIT_HOST'" \
      "(accepted: github, gitlab)" >&2
    exit 1
    ;;
esac
