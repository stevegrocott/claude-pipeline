#!/bin/bash
# Usage: merge-mr.sh <mr-number>
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

MR="$1"

# Gate wait_for_mergeable on GitHub's richer `mergeStateStatus` field rather
# than the coarse `mergeable` field: a PR blocked only by a still-running
# check keeps waiting, while a PR with a check that has already concluded in
# failure is refused immediately instead of looping until the timeout.
# Defaults on; set MERGE_MR_MERGE_STATE_GATE=0 to opt back into the legacy
# `mergeable`-only behavior.
MERGE_MR_MERGE_STATE_GATE="${MERGE_MR_MERGE_STATE_GATE:-1}"

# Check-run names (comma-separated) whose failure must NOT block the merge —
# jobs the consumer runs as informational (`continue-on-error`, a known-red
# baseline being burned down). GitHub reports such a PR as UNSTABLE, which the
# gate below would otherwise refuse outright (issue #861: 7 of 13 approved PRs
# in one day, every blocking gate green). Names are matched exactly against
# CheckRun `.name` / commit-status `.context`. Empty by default: nothing is
# ignored unless the consumer says so in config/platform.sh.
MERGE_MR_NON_BLOCKING_CHECKS="${MERGE_MR_NON_BLOCKING_CHECKS:-}"

# The allowlist as a JSON array, for jq --argjson.
_non_blocking_checks_json() {
  # printf with a trailing newline: `jq -R` on a zero-line input emits nothing at
  # all, which would hand `--argjson` an empty string and make every caller fail
  # open. One (possibly empty) line always yields a JSON array.
  local json
  json=$(printf '%s\n' "$MERGE_MR_NON_BLOCKING_CHECKS" \
    | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' 2>/dev/null)
  case "$json" in
    \[*\]) printf '%s' "$json" ;;
    *) printf '[]' ;;
  esac
}

# jq filter body: the name a rollup entry is matched by (CheckRun vs status).
_JQ_CHECK_NAME='(if .__typename == "CheckRun" then .name else .context end)'

# jq filter body: true when the piped-in conclusion/state string is a
# concluded-failure value. Shared so the failing-state list can't drift
# between the three functions below (issue #861 follow-up).
_JQ_IS_FAILED_STATE='(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE")'

# jq filter body: a rollup entry's name/context if it concluded in failure,
# nothing otherwise. CheckRun entries report status/conclusion (conclusion is
# only trustworthy once status is COMPLETED); legacy commit-status entries
# report state directly.
_JQ_FAILED_CHECK_NAME='(if .__typename == "CheckRun" then (select(.status == "COMPLETED" and (.conclusion | '"$_JQ_IS_FAILED_STATE"')) | .name) else (select(.state | '"$_JQ_IS_FAILED_STATE"') | .context) end)'

# Names in the rollup that concluded in failure but are allowlisted — for the
# merge log, so an ignored red check is visible rather than silent.
_ignored_failed_checks() {
  local rollup_json="$1"
  jq -r --argjson ignore "$(_non_blocking_checks_json)" '
    [.[]? |
      select(('"$_JQ_CHECK_NAME"') as $n | $ignore | index($n)) |
      '"$_JQ_FAILED_CHECK_NAME"'
    ] | join(", ")
  ' <<<"$rollup_json" 2>/dev/null || echo ""
}

# Returns success when any rollup entry is still running or queued. Used so an
# UNSTABLE PR whose only red checks are allowlisted is merged only once every
# other check has actually finished — never while a blocking one is pending.
_has_pending_check() {
  local rollup_json="$1"
  jq -e '
    [.[]? |
      if .__typename == "CheckRun" then
        (.status != "COMPLETED")
      else
        (.state == "PENDING" or .state == "EXPECTED")
      end
    ] | any
  ' <<<"$rollup_json" >/dev/null 2>&1
}

# Returns success when any entry in a statusCheckRollup JSON array has
# concluded in a failing state. CheckRun entries report status/conclusion
# (conclusion is only trustworthy once status is COMPLETED); legacy
# commit-status entries report state directly.
_has_concluded_check_failure() {
  local rollup_json="$1"

  jq -e --argjson ignore "$(_non_blocking_checks_json)" '
    [.[]? |
      select((('"$_JQ_CHECK_NAME"') as $n | $ignore | index($n)) | not) |
      '"$_JQ_FAILED_CHECK_NAME"'
    ] | length > 0
  ' <<<"$rollup_json" >/dev/null 2>&1
}

# Names the first check in a statusCheckRollup array that concluded in a
# failing state, for the refusal message. Shared by both poll paths so the two
# refusals cannot drift apart (issue #853).
_first_failed_check() {
  local rollup_json="$1"

  jq -r --argjson ignore "$(_non_blocking_checks_json)" '
    [.[]? |
      select((('"$_JQ_CHECK_NAME"') as $n | $ignore | index($n)) | not) |
      '"$_JQ_FAILED_CHECK_NAME"'
    ] | first // "unknown check"
  ' <<<"$rollup_json" 2>/dev/null || echo "unknown check"
}

wait_for_mergeable() {
  local pr="$1"
  local interval="${MERGE_MR_POLL_INTERVAL:-10}"
  local max="${MERGE_MR_POLL_MAX:-90}"
  local elapsed=0

  if [ "$MERGE_MR_MERGE_STATE_GATE" != "1" ]; then
    while [ "$elapsed" -lt "$max" ]; do
      # The concluded-check-failure test is NOT part of the mergeStateStatus
      # gate that this branch opts out of (issue #853). MERGE_MR_MERGE_STATE_GATE
      # selects the coarser `mergeable` poll; it must not also disable the last
      # thing standing between a failing check and the base branch. On a repo
      # that cannot enable branch protection this refusal is the only gate, and
      # `mergeable` reports MERGEABLE for a PR whose checks have failed, so
      # without this the legacy path merges it.
      local legacy_json state rollup
      legacy_json=$(gh pr view "$pr" --json mergeable,statusCheckRollup 2>/dev/null || echo "{}")
      state=$(jq -r '.mergeable // "UNKNOWN"' <<<"$legacy_json" 2>/dev/null || echo "UNKNOWN")
      rollup=$(jq -c '.statusCheckRollup // []' <<<"$legacy_json" 2>/dev/null || echo "[]")

      if _has_concluded_check_failure "$rollup"; then
        echo "PR #$pr has check \"$(_first_failed_check "$rollup")\" that concluded in failure (mergeable: $state); refusing to wait" >&2
        return 1
      fi

      case "$state" in
        MERGEABLE)
          return 0
          ;;
        CONFLICTING)
          echo "PR has unresolvable merge conflicts" >&2
          return 1
          ;;
        *)
          echo "Waiting for PR #$pr to become mergeable (state: $state, ${elapsed}s elapsed)..." >&2
          sleep "$interval"
          elapsed=$((elapsed + interval))
          ;;
      esac
    done

    echo "Timed out waiting for GitHub to compute mergeability" >&2
    return 1
  fi

  while [ "$elapsed" -lt "$max" ]; do
    local json
    json=$(gh pr view "$pr" --json mergeStateStatus,statusCheckRollup 2>/dev/null || echo "{}")

    local merge_state
    merge_state=$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$json" 2>/dev/null || echo "UNKNOWN")

    case "$merge_state" in
      CLEAN|HAS_HOOKS)
        return 0
        ;;
      DIRTY)
        echo "PR has unresolvable merge conflicts" >&2
        return 1
        ;;
      *)
        local rollup
        rollup=$(jq -c '.statusCheckRollup // []' <<<"$json" 2>/dev/null || echo "[]")

        if _has_concluded_check_failure "$rollup"; then
          echo "PR #$pr has check \"$(_first_failed_check "$rollup")\" that concluded in failure (mergeStateStatus: $merge_state); refusing to wait" >&2
          return 1
        fi

        # UNSTABLE means "a check failed"; if every failed check is on the
        # non-blocking list and nothing is still running, that is the green
        # state the consumer asked for (issue #861). While anything is pending
        # keep waiting — a blocking check may still fail.
        if [ "$merge_state" = "UNSTABLE" ] && ! _has_pending_check "$rollup"; then
          local ignored
          ignored=$(_ignored_failed_checks "$rollup")
          if [ -n "$ignored" ]; then
            echo "PR #$pr is UNSTABLE only because of non-blocking check(s) [$ignored] (MERGE_MR_NON_BLOCKING_CHECKS); proceeding" >&2
            return 0
          fi
        fi

        echo "Waiting for PR #$pr to become mergeable (mergeStateStatus: $merge_state, ${elapsed}s elapsed)..." >&2
        sleep "$interval"
        elapsed=$((elapsed + interval))
        ;;
    esac
  done

  echo "Timed out waiting for GitHub to compute mergeability" >&2
  return 1
}

case "$GIT_HOST" in
  github)
    wait_for_mergeable "$MR" || exit 1
    case "$MERGE_STYLE" in
      squash) gh pr merge "$MR" --squash --delete-branch ;;
      merge) gh pr merge "$MR" --merge --delete-branch ;;
      rebase) gh pr merge "$MR" --rebase --delete-branch ;;
    esac
    ;;
  gitlab)
    case "$MERGE_STYLE" in
      squash) glab mr merge "$MR" --squash --remove-source-branch --yes ;;
      merge) glab mr merge "$MR" --remove-source-branch --yes ;;
      rebase) glab mr merge "$MR" --rebase --remove-source-branch --yes ;;
    esac
    ;;
esac
