#!/usr/bin/env bash
#
# prompt-builder.sh — model-fallback golden test prompt builder
#
# Sourced by skill-golden.sh (and decide-model-fallback.sh tests) to provide
# the build_prompt() function. Must define exactly one function:
# build_prompt().
#
# build_prompt FIXTURE_BODY
#   Prints the full prompt that the model-fallback skill receives on stdout.
#   FIXTURE_BODY is the raw JSON content of a fixture file with at least:
#     { "current_model": "...", "error_kind": "..." }
#
# The prompt embeds SKILL.md verbatim so the contract always reflects the
# current skill specification — no drift between the spec and what Claude
# is asked to follow.
#
# SG_ROUTE_FIELD: model-fallback's primary decision field is "next_model",
# not the lib default of "route". Exported so skill-golden-lib.sh extracts
# the correct field for the manifest comparison.
#

# Override the default SG_ROUTE_FIELD ("route") — model-fallback returns
# its primary decision under .next_model. Because this file is *sourced*
# by skill-golden.sh (not exec'd), the export persists into the caller.
export SG_ROUTE_FIELD=next_model

build_prompt() {
	local fixture_body="$1"
	local skill_dir
	local skill_md

	skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	skill_md="$(<"$skill_dir/SKILL.md")"

	cat <<MODEL_FALLBACK_PROMPT
You are the model-fallback decision skill for an issue-implementation
pipeline. Given the current model that failed and the error_kind that
caused the failure, decide which model to escalate to next — or whether
the model ceiling has been reached and no further escalation is possible.

Output exactly ONE JSON object on stdout — no markdown fences, no prose,
no preamble. Fields: next_model (string|null), at_ceiling (bool),
reason (string).

The escalation chain is linear and capped:
  haiku → sonnet → opus → (ceiling — no further fallback)

Some error_kinds are non-escalatable (a higher model cannot fix them);
those return next_model=null and at_ceiling=true regardless of the
current_model. See the SKILL SPECIFICATION for the full rules.

SKILL SPECIFICATION:
<<<
${skill_md}
>>>

FIXTURE INPUT (JSON):
<<<
${fixture_body}
>>>

Read current_model and error_kind from the fixture JSON above and apply
the decision logic from the SKILL SPECIFICATION. Return the JSON object
described in the Output Contract.
MODEL_FALLBACK_PROMPT
}
