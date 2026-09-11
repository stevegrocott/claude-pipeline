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

# Opt-in (issue #878): request one full CI run against the PR's FINAL head
# before merging. A consumer whose expensive suite runs once per PR (on open)
# and on demand via a label would otherwise merge a head that suite never
# covered — every review-fix push since PR-open is uncovered. When this names a
# label, merge-mr.sh adds it to the PR and waits for a check run created AFTER
# the label was applied. Empty by default: unset means no label, no extra wait,
# and not one extra API call.
MERGE_MR_FULL_RUN_LABEL="${MERGE_MR_FULL_RUN_LABEL:-}"

# The check-run name that label is expected to (re-)trigger.
MERGE_MR_FULL_RUN_CHECK="${MERGE_MR_FULL_RUN_CHECK:-e2e}"

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

# Names in the rollup that are still running but allowlisted — for the merge
# log, so an ignored in-flight check is visible rather than silent (issue #877).
_pending_ignored_checks() {
  local rollup_json="$1"
  jq -r --argjson ignore "$(_non_blocking_checks_json)" '
    [.[]? |
      select(('"$_JQ_CHECK_NAME"') as $n | $ignore | index($n)) |
      if .__typename == "CheckRun" then
        (select(.status != "COMPLETED") | .name)
      else
        (select(.state == "PENDING" or .state == "EXPECTED") | .context)
      end
    ] | join(", ")
  ' <<<"$rollup_json" 2>/dev/null || echo ""
}

# Returns success when any BLOCKING rollup entry is still running or queued.
# Checks named in MERGE_MR_NON_BLOCKING_CHECKS are excluded, exactly as they are
# from the failure test: a check that cannot fail the merge is not worth waiting
# for (issue #877 — a 25-33 min allowlisted job turned every merge into
# merge_pr_timeout and the batch counted a failure with all blocking checks
# green). Used so an UNSTABLE or BLOCKED PR whose only outstanding checks are
# allowlisted merges immediately, while a pending blocking check still waits.
_has_pending_check() {
  local rollup_json="$1"
  jq -e --argjson ignore "$(_non_blocking_checks_json)" '
    [.[]? |
      select((('"$_JQ_CHECK_NAME"') as $n | $ignore | index($n)) | not) |
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

# The PR's current head SHA; empty when it cannot be read.
_pr_head_sha() {
  gh pr view "$1" --json headRefOid --jq '.headRefOid' 2>/dev/null || printf ''
}

# Raw check-runs payload for <sha>. Kept in one place so the pre-label
# watermark and the post-label poll read the SAME source: ids compared across
# two different endpoints would not be comparing like with like.
_check_runs_json() {
  local sha="$1"
  gh api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" \
    2>/dev/null || printf '{}'
}

# Highest check-run id named MERGE_MR_FULL_RUN_CHECK on <sha>, or 0 when that
# check has never run there.
#
# This watermark is the whole mechanism. A suite that went green when the PR
# opened is still attached to the same head SHA when no new commit has landed,
# so a wait keyed on the SHA alone matches that stale run instantly and waits
# for nothing — the exact failure this feature exists to prevent (issue #878).
# Check-run ids are monotonically increasing, so "id greater than the
# pre-label maximum" is precisely "created after the label event".
#
# Returns 1 without printing when the payload is unreadable (auth failure,
# rate limit, malformed JSON). That must NOT degrade to 0: a zero watermark
# makes every run already on the head count as "new", which is precisely the
# stale-green acceptance this function exists to prevent. The caller refuses
# the merge instead.
_latest_full_run_id() {
  local sha="$1" id
  id=$(_check_runs_json "$sha" \
    | jq -r --arg name "$MERGE_MR_FULL_RUN_CHECK" '
        if (.check_runs | type) != "array" then "unreadable"
        else ([.check_runs[] | select(.name == $name) | .id] | max // 0)
        end' 2>/dev/null) || id="unreadable"
  case "$id" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$id" ;;
  esac
}

# State of the newest MERGE_MR_FULL_RUN_CHECK run on <sha> whose id exceeds
# <baseline>, as "<id> <status> <conclusion>". Empty when no post-label run
# exists yet.
_post_label_run_state() {
  local sha="$1" baseline="$2"
  _check_runs_json "$sha" \
    | jq -r --arg name "$MERGE_MR_FULL_RUN_CHECK" \
      --argjson baseline "$baseline" '
        [.check_runs[]? | select(.name == $name and .id > $baseline)]
        | sort_by(.id) | last
        | if . == null then ""
          else "\(.id) \(.status) \(.conclusion // "")" end
      ' 2>/dev/null || printf ''
}

# Adds MERGE_MR_FULL_RUN_LABEL to the PR and waits for the check run it
# triggers to succeed on the same head SHA (issue #878).
#
# No-op returning success when the variable is unset — that path makes no API
# call at all, so an unconfigured consumer behaves exactly as before.
wait_for_full_run() {
  local pr="$1"

  [ -n "$MERGE_MR_FULL_RUN_LABEL" ] || return 0

  local interval="${MERGE_MR_FULL_RUN_POLL_INTERVAL:-30}"
  local max="${MERGE_MR_FULL_RUN_POLL_MAX:-2700}"
  local elapsed=0

  local sha
  sha=$(_pr_head_sha "$pr")
  if [ -z "$sha" ]; then
    echo "Cannot read the head SHA of PR #$pr; refusing to merge without the" \
      "full run \"$MERGE_MR_FULL_RUN_LABEL\" was meant to request" >&2
    return 1
  fi

  local baseline
  if ! baseline=$(_latest_full_run_id "$sha"); then
    echo "Cannot read the check runs on $sha; refusing to merge without a" \
      "verifiable post-label $MERGE_MR_FULL_RUN_CHECK run" >&2
    return 1
  fi

  echo "Requesting a full run on PR #$pr head $sha: adding label" \
    "\"$MERGE_MR_FULL_RUN_LABEL\" (pre-label $MERGE_MR_FULL_RUN_CHECK run" \
    "id: $baseline)" >&2

  if ! gh pr edit "$pr" --add-label "$MERGE_MR_FULL_RUN_LABEL" \
    >/dev/null 2>&1; then
    echo "Could not add label \"$MERGE_MR_FULL_RUN_LABEL\" to PR #$pr;" \
      "refusing to merge without the full run it triggers" >&2
    return 1
  fi

  while [ "$elapsed" -lt "$max" ]; do
    local head_now
    head_now=$(_pr_head_sha "$pr")
    if [ -n "$head_now" ] && [ "$head_now" != "$sha" ]; then
      echo "PR #$pr head moved from $sha to $head_now while waiting;" \
        "refusing to merge a head the requested run did not cover" >&2
      return 1
    fi

    local state run_id run_status run_conclusion
    state=$(_post_label_run_state "$sha" "$baseline")
    if [ -n "$state" ]; then
      run_id=$(printf '%s' "$state" | awk '{print $1}')
      run_status=$(printf '%s' "$state" | awk '{print $2}')
      run_conclusion=$(printf '%s' "$state" | awk '{print $3}')

      if [ "$run_status" = "completed" ]; then
        case "$run_conclusion" in
          success|neutral|skipped)
            echo "Full run $MERGE_MR_FULL_RUN_CHECK (run $run_id) concluded" \
              "$run_conclusion on $sha; proceeding" >&2
            return 0
            ;;
          *)
            echo "Full run $MERGE_MR_FULL_RUN_CHECK (run $run_id) concluded" \
              "${run_conclusion:-unknown} on $sha; refusing to merge" >&2
            return 1
            ;;
        esac
      fi

      echo "Waiting for $MERGE_MR_FULL_RUN_CHECK run $run_id on $sha" \
        "(status: $run_status, ${elapsed}s elapsed)..." >&2
    else
      echo "Waiting for a $MERGE_MR_FULL_RUN_CHECK run newer than id" \
        "$baseline on $sha (${elapsed}s elapsed)..." >&2
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "Timed out waiting for a post-label $MERGE_MR_FULL_RUN_CHECK run on" \
    "$sha" >&2
  return 1
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
        if { [ "$merge_state" = "UNSTABLE" ] || [ "$merge_state" = "BLOCKED" ]; } \
          && ! _has_pending_check "$rollup"; then
          local ignored pending_ignored remaining
          ignored=$(_ignored_failed_checks "$rollup")
          pending_ignored=$(_pending_ignored_checks "$rollup")
          remaining="$ignored"
          if [ -n "$pending_ignored" ]; then
            if [ -n "$remaining" ]; then
              remaining="$remaining, $pending_ignored (still running)"
            else
              remaining="$pending_ignored (still running)"
            fi
          fi
          if [ -n "$remaining" ]; then
            echo "PR #$pr is $merge_state only because of non-blocking check(s) [$remaining] (MERGE_MR_NON_BLOCKING_CHECKS); proceeding" >&2
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

# Reports whether the PR has already reached a terminal state, so the caller can
# skip the mergeability poll entirely.
#
# A MERGED or CLOSED PR reports `mergeStateStatus: UNKNOWN` forever. Without
# this, wait_for_mergeable() polls it to MERGE_MR_POLL_MAX and reports a
# decline — the batch then counts a *failure* for a PR that actually merged and
# feeds the circuit breaker (issue #876: the inner orchestrator merged PR #6032,
# the batch re-merged it, waited 1,790s on UNKNOWN and recorded the issue failed).
#
# Returns:
#   0  already MERGED — the caller is done, nothing to merge
#   2  CLOSED without a merge — a refusal, not a transient state
#   1  still open (or state unreadable) — proceed to the mergeability wait
_pr_terminal_state() {
  local pr="$1" state
  state=$(gh pr view "$pr" --json state --jq '.state' 2>/dev/null) || state=""
  case "$state" in
    MERGED)
      echo "PR #$pr is already MERGED — nothing to do" >&2
      return 0
      ;;
    CLOSED)
      echo "PR #$pr is CLOSED without having been merged — refusing to merge" >&2
      return 2
      ;;
  esac
  return 1
}

case "$GIT_HOST" in
  github)
    # Check the terminal states before polling: a merged PR is success, a
    # closed one is a refusal, and neither ever leaves UNKNOWN (issue #876).
    _pr_terminal_state "$MR"
    case $? in
      0) exit 0 ;;
      2) exit 1 ;;
    esac
    # Opt-in: request one full CI run on this head and wait for it before the
    # mergeability poll. Inert unless MERGE_MR_FULL_RUN_LABEL names a label.
    wait_for_full_run "$MR" || exit 1
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
