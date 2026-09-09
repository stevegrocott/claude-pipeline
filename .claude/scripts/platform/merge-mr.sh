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

# Comma-separated list of EXACT check names the consumer has declared
# informational (issue #861). A check named here never blocks the merge: it
# is dropped before the concluded-failure test, and a PR that GitHub reports
# as UNSTABLE only because of such a check is merged instead of refused.
#
# Exact names only — no globs, no prefixes. A too-broad allowlist hides real
# regressions, so every ignored check name is echoed into the merge log
# before the merge proceeds.
#
# Empty by default: with no allowlist the gate behaves exactly as it did
# before #861.
MERGE_MR_NON_BLOCKING_CHECKS="${MERGE_MR_NON_BLOCKING_CHECKS:-}"

# Renders MERGE_MR_NON_BLOCKING_CHECKS as a JSON array for jq --argjson.
# Surrounding whitespace is trimmed and empty entries dropped, so
# "a, b," yields ["a","b"]. Emits [] when unset or unparseable.
_non_blocking_checks_json() {
  jq -cn --arg raw "${MERGE_MR_NON_BLOCKING_CHECKS:-}" '
    $raw | split(",")
      | map(gsub("^[ \t]+|[ \t]+$"; ""))
      | map(select(length > 0))
  ' 2>/dev/null || echo '[]'
}

# Returns success when any entry in a statusCheckRollup JSON array has
# concluded in a failing state. CheckRun entries report status/conclusion
# (conclusion is only trustworthy once status is COMPLETED); legacy
# commit-status entries report state directly.
#
# Checks whose name (CheckRun) or context (commit status) appears in
# MERGE_MR_NON_BLOCKING_CHECKS are excluded from the test entirely.
_has_concluded_check_failure() {
  local rollup_json="$1"
  local allow
  allow="$(_non_blocking_checks_json)"

  jq -e --argjson allow "$allow" '
    [.[]? |
      (.name // .context // "") as $n |
      select(($allow | index($n)) == null) |
      if .__typename == "CheckRun" then
        (select(.status == "COMPLETED") | .conclusion)
      else
        .state
      end
    ] | any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or
        . == "TIMED_OUT" or . == "ACTION_REQUIRED" or
        . == "STARTUP_FAILURE")
  ' <<<"$rollup_json" >/dev/null 2>&1
}

# Returns success when any entry in a statusCheckRollup array has NOT yet
# concluded. Allowlisted or not: a check that is still running means the PR
# is not finished, so the UNSTABLE shortcut below must keep waiting rather
# than merge on a partial picture.
_has_pending_check() {
  local rollup_json="$1"

  jq -e '
    [.[]? |
      if .__typename == "CheckRun" then
        (.status != "COMPLETED")
      else
        (.state == "PENDING" or .state == "EXPECTED")
      end
    ] | any(. == true)
  ' <<<"$rollup_json" >/dev/null 2>&1
}

# Comma-separated names of the allowlisted checks that DID conclude in
# failure, for the merge log. Empty string when nothing was waved through.
_ignored_failed_checks() {
  local rollup_json="$1"
  local allow
  allow="$(_non_blocking_checks_json)"

  jq -r --argjson allow "$allow" '
    [.[]? |
      (.name // .context // "") as $n |
      select(($allow | index($n)) != null) |
      if .__typename == "CheckRun" then
        (select(.status == "COMPLETED" and (.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT" or .conclusion == "ACTION_REQUIRED" or .conclusion == "STARTUP_FAILURE")) | .name)
      else
        (select(.state == "FAILURE" or .state == "ERROR" or .state == "CANCELLED" or .state == "TIMED_OUT" or .state == "ACTION_REQUIRED" or .state == "STARTUP_FAILURE") | .context)
      end
    ] | join(", ")
  ' <<<"$rollup_json" 2>/dev/null || echo ""
}

# Names the first check in a statusCheckRollup array that concluded in a
# failing state, for the refusal message. Shared by both poll paths so the two
# refusals cannot drift apart (issue #853).
_first_failed_check() {
  local rollup_json="$1"
  local allow
  allow="$(_non_blocking_checks_json)"

  jq -r --argjson allow "$allow" '
    [.[]? |
      (.name // .context // "") as $n |
      select(($allow | index($n)) == null) |
      if .__typename == "CheckRun" then
        (select(.status == "COMPLETED" and (.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT" or .conclusion == "ACTION_REQUIRED" or .conclusion == "STARTUP_FAILURE")) | .name)
      else
        (select(.state == "FAILURE" or .state == "ERROR" or .state == "CANCELLED" or .state == "TIMED_OUT" or .state == "ACTION_REQUIRED" or .state == "STARTUP_FAILURE") | .context)
      end
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
      UNSTABLE)
        # UNSTABLE means a non-required check is red or still running. When
        # every red check is on the MERGE_MR_NON_BLOCKING_CHECKS allowlist
        # and nothing is still running, the PR is as green as it will ever
        # get — merge it, naming what was ignored (issue #861). Any
        # non-allowlisted failure still refuses, and a still-running check
        # still waits, so this cannot merge an untested PR.
        local unstable_rollup
        unstable_rollup=$(jq -c '.statusCheckRollup // []' <<<"$json" \
          2>/dev/null || echo "[]")

        if _has_concluded_check_failure "$unstable_rollup"; then
          echo "PR #$pr has check \"$(_first_failed_check "$unstable_rollup")\" that concluded in failure (mergeStateStatus: $merge_state); refusing to wait" >&2
          return 1
        fi

        local ignored
        ignored=$(_ignored_failed_checks "$unstable_rollup")
        if [[ -n "$ignored" ]] \
          && ! _has_pending_check "$unstable_rollup"; then
          echo "PR #$pr: ignoring non-blocking check(s) \"$ignored\" (MERGE_MR_NON_BLOCKING_CHECKS); every other check passed — proceeding to merge" >&2
          return 0
        fi

        echo "Waiting for PR #$pr to become mergeable (mergeStateStatus: $merge_state, ${elapsed}s elapsed)..." >&2
        sleep "$interval"
        elapsed=$((elapsed + interval))
        ;;
      *)
        local rollup
        rollup=$(jq -c '.statusCheckRollup // []' <<<"$json" 2>/dev/null || echo "[]")

        if _has_concluded_check_failure "$rollup"; then
          echo "PR #$pr has check \"$(_first_failed_check "$rollup")\" that concluded in failure (mergeStateStatus: $merge_state); refusing to wait" >&2
          return 1
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
