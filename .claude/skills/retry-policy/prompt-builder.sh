#!/usr/bin/env bash
#
# prompt-builder.sh — retry-policy golden test prompt builder
#
# Sourced by skill-golden.sh (and related test harnesses) to provide the
# build_prompt() function.  Must define exactly one function: build_prompt().
#
# build_prompt FIXTURE_BODY
#   Accepts the raw content of a retry-policy fixture JSON file on $1.
#   Prints the full prompt that the retry-policy skill receives on stdout.
#   The fixture may include a _fixture_meta key (test-only) which is stripped
#   before the inputs are forwarded to Claude.
#
#   Fixture top-level fields used:
#     stage_result   — failed stage result envelope (see SKILL.md input contract)
#     retry_count    — integer: retries already attempted at current model tier
#     error_history  — array of prior failure records at the same model tier;
#                      defaults to [] when absent
#
#   Output field: the prompt asks Claude to return its decision as "action"
#   (values: retry | escalate | bail) for compatibility with the schema and
#   the skill-golden framework.  SG_ROUTE_FIELD is set to "action" here so
#   the harness extracts the correct field when comparing against the manifest.
#

# Override the default SG_ROUTE_FIELD ("route") — retry-policy returns its
# primary decision under .action.  Exported so skill-golden-lib.sh extracts
# the correct field for the manifest comparison.
export SG_ROUTE_FIELD=action

# Resolve the skill directory at source time so it remains correct even when
# build_prompt is called after the working directory has changed.
# BASH_SOURCE[0] may be relative when sourced with a relative path, so we pin
# it to an absolute path now while the caller's cwd is stable.
_RETRY_POLICY_DIR="$(
	cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)" || {
	printf 'prompt-builder: cannot resolve skill dir\n' >&2
}

build_prompt() {
	local fixture_body="$1"

	# Read the full SKILL.md spec — decision logic, input/output contracts,
	# max-retries table, back-off strategy, flowchart, and common-mistakes
	# table are all included so Claude has everything it needs.
	local skill_content
	skill_content=$(<"$_RETRY_POLICY_DIR/SKILL.md") || {
		printf 'prompt-builder: cannot read SKILL.md: %s/SKILL.md\n' \
			"$_RETRY_POLICY_DIR" >&2
		return 1
	}

	# Extract stage_result — the failed stage envelope.
	local stage_result
	stage_result=$(printf '%s' "$fixture_body" \
		| jq '.stage_result') || {
		printf 'prompt-builder: failed to parse stage_result from fixture\n' >&2
		return 1
	}

	# Extract retry_count — number of retries already attempted at this tier.
	local retry_count
	retry_count=$(printf '%s' "$fixture_body" \
		| jq '.retry_count') || {
		printf 'prompt-builder: failed to parse retry_count from fixture\n' >&2
		return 1
	}

	# Extract error_history — prior failures at the same model tier.
	# Fall back to empty array for fixtures that represent first attempts.
	local error_history
	error_history=$(printf '%s' "$fixture_body" \
		| jq '.error_history // []')

	cat <<RETRY_PROMPT
${skill_content}

---

Apply the decision logic above to the inputs below.

Output schema-enforced JSON with:
  action      — "retry" | "escalate" | "bail"
  reason      — human-readable rationale for the decision
  backoff_ms  — milliseconds to wait before retrying (ONLY when
                action == "retry" AND error_kind == "rate_limit"; omit otherwise)

STAGE_RESULT:
<<<
${stage_result}
>>>

RETRY_COUNT (retries already attempted at current model tier):
<<<
${retry_count}
>>>

ERROR_HISTORY (prior failures at same model tier for this stage):
<<<
${error_history}
>>>
RETRY_PROMPT
}
