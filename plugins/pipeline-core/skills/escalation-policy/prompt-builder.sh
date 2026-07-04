#!/usr/bin/env bash
#
# prompt-builder.sh — escalation-policy golden test prompt builder
#
# Sourced by skill-golden.sh (and related test harnesses) to provide the
# build_prompt() function.  Must define exactly one function: build_prompt().
#
# build_prompt FIXTURE_BODY
#   Accepts the raw content of an escalation-policy fixture JSON file on $1.
#   Prints the full prompt that the escalation-policy skill receives on stdout.
#   The fixture may include a _fixture_meta key (test-only) which is stripped
#   before the stage_result is forwarded to Claude.
#
#   escalation_history is extracted from _fixture_meta.escalation_history when
#   present; otherwise an empty array is used (correct for first-attempt
#   fixtures where no prior escalation has occurred).
#
#   Output field: the prompt asks Claude to return its decision as "action"
#   (values: accept | escalate | bail | retry_same) matching the SKILL.md
#   output contract. SG_ROUTE_FIELD is exported as "action" so skill-golden.sh
#   extracts the correct field for manifest comparison.
#

# Resolve the skill directory at source time so it remains correct even
# when build_prompt is called after the working directory has changed.
# BASH_SOURCE[0] may be relative when sourced with a relative path, so
# we pin it to an absolute path now while the caller's cwd is stable.
# Override the default SG_ROUTE_FIELD ("route") — escalation-policy returns
# its primary decision under .action per SKILL.md output contract. Because
# this file is *sourced* by skill-golden.sh (not exec'd), the export persists
# into the caller.
export SG_ROUTE_FIELD=action

_ESCALATION_POLICY_DIR="$(
	cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)" || {
	printf 'prompt-builder: cannot resolve skill dir\n' >&2
}

build_prompt() {
	local fixture_body="$1"

	# Read the full SKILL.md spec — decision logic, input/output contracts,
	# flowchart, and common-mistakes table are all included.
	local skill_content
	skill_content=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{f=0;next} !f{print}' \
		"$_ESCALATION_POLICY_DIR/SKILL.md") || {
		printf 'prompt-builder: cannot read SKILL.md: %s/SKILL.md\n' \
			"$_ESCALATION_POLICY_DIR" >&2
		return 1
	}

	# Strip _fixture_meta — test-only key not present in real stage_results.
	local stage_result
	stage_result=$(printf '%s' "$fixture_body" \
		| jq 'del(._fixture_meta)') || {
		printf 'prompt-builder: failed to parse fixture JSON\n' >&2
		return 1
	}

	# Extract per-stage escalation history from test metadata when present;
	# fall back to an empty array for fixtures that represent first attempts.
	local escalation_history
	escalation_history=$(printf '%s' "$fixture_body" \
		| jq '._fixture_meta.escalation_history // []')

	cat <<ESCALATION_PROMPT
${skill_content}

Apply the decision logic above to the inputs below.

Output schema-enforced JSON with:
  action  — "accept" | "escalate" | "bail" | "retry_same"
  model   — target model tier when action == "escalate"; omit otherwise
  reason  — human-readable routing rationale

STAGE_RESULT:
<<<
${stage_result}
>>>

ESCALATION_HISTORY (records for this stage only):
<<<
${escalation_history}
>>>
ESCALATION_PROMPT
}
