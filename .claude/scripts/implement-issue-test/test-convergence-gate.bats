#!/usr/bin/env bats
#
# test-convergence-gate.bats
# Regression coverage for issue #616 (surfaced via #620): the merge-block
# gate must not treat a task as incomplete when its declared deliverable
# files are present on the feature branch, even though the task's *recorded*
# stage status is "failed" (a later stage, e.g. fix-pr-review-iter-1,
# completed the abandoned work but never updated the task's own status in
# status.json).
#
# Also covers issue #618 (same #620 bug report): the flip side of the #616
# fix. Branch-evidence re-evaluation must not become a rubber stamp — a task
# whose declared path was genuinely never touched on the branch has to keep
# blocking the merge, and the block reason must name that task specifically
# rather than only reporting a count (#620 AC2, AC3, AC5).
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env

	export ISSUE_NUMBER=616
	export BASE_BRANCH=base
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0

	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

	ORCHESTRATOR_START_EPOCH=$(date +%s)
	DEGRADED_STAGES=()

	source_orchestrator_functions
	init_status

	# Real git repo standing in for the feature/base branch pair the fix
	# (#620 tasks 1-3) must diff against. Uses the same $base...HEAD idiom
	# already relied on by detect_change_scope() in the orchestrator.
	git init -q .
	git config user.email test@example.com
	git config user.name "Test"
	git commit -q --allow-empty -m "base"
	git branch -q "$BASE_BRANCH"
	git checkout -q -b feature
}

teardown() {
	teardown_test_env
}

# =============================================================================
# UNIT TESTS: task_files_modified_on_branch() (#620 task 1)
# Exercises the shipped helper directly against a real repo, rather than the
# test-local _task_has_file_evidence() mirror the gate-level tests below use.
# =============================================================================

@test "task_files_modified_on_branch: true for a file added on the branch" {
	echo "new" > added.txt
	git add added.txt
	git commit -q -m "add file"

	expect_ok "added file counts as branch evidence" \
		task_files_modified_on_branch "$BASE_BRANCH" added.txt
}

@test "task_files_modified_on_branch: true for a file modified on the branch" {
	git checkout -q "$BASE_BRANCH"
	echo "v1" > tracked.txt
	git add tracked.txt
	git commit -q -m "base file"
	git checkout -q feature
	git merge -q "$BASE_BRANCH" -m "sync base"
	echo "v2" > tracked.txt
	git commit -q -am "modify file"

	expect_ok "modified file counts as branch evidence" \
		task_files_modified_on_branch "$BASE_BRANCH" tracked.txt
}

@test "task_files_modified_on_branch: true for a file deleted on the branch" {
	git checkout -q "$BASE_BRANCH"
	echo "doomed" > removed.txt
	git add removed.txt
	git commit -q -m "base file"
	git checkout -q feature
	git merge -q "$BASE_BRANCH" -m "sync base"
	git rm -q removed.txt
	git commit -q -m "delete file"

	expect_ok "deleted file counts as branch evidence" \
		task_files_modified_on_branch "$BASE_BRANCH" removed.txt
}

@test "task_files_modified_on_branch: false for a path never touched on the branch" {
	echo "new" > added.txt
	git add added.txt
	git commit -q -m "add file"

	expect_not_ok "untouched path is not branch evidence" \
		task_files_modified_on_branch "$BASE_BRANCH" README.md
}

@test "task_files_modified_on_branch: true when only one of several declared paths matches" {
	mkdir -p src
	echo "new" > src/one.sh
	git add src
	git commit -q -m "add one"

	expect_ok "one matching path out of three is enough" \
		task_files_modified_on_branch "$BASE_BRANCH" \
		docs/missing.md src/one.sh other/absent.txt
}

@test "task_files_modified_on_branch: false with no declared paths" {
	echo "new" > added.txt
	git add added.txt
	git commit -q -m "add file"

	expect_not_ok "a task declaring no paths has no evidence" \
		task_files_modified_on_branch "$BASE_BRANCH"
}

@test "task_files_modified_on_branch: false when only empty-string paths are declared" {
	echo "new" > added.txt
	git add added.txt
	git commit -q -m "add file"

	expect_not_ok "empty-string paths are skipped, not matched" \
		task_files_modified_on_branch "$BASE_BRANCH" "" ""
}

@test "task_files_modified_on_branch: false when the branch has no changes vs base" {
	expect_not_ok "an empty diff yields no evidence" \
		task_files_modified_on_branch "$BASE_BRANCH" anything.txt
}

@test "task_files_modified_on_branch: false for a nonexistent base branch" {
	echo "new" > added.txt
	git add added.txt
	git commit -q -m "add file"

	expect_not_ok "an uncomputable diff must not be read as evidence" \
		task_files_modified_on_branch no-such-branch added.txt
}

@test "task_files_modified_on_branch: matches whole paths only, not substrings" {
	mkdir -p docs
	echo "doc" > docs/README.md
	git add docs
	git commit -q -m "add nested readme"

	# A task declaring the repo-root README.md must not be satisfied by
	# docs/README.md — the comparison is a whole-path equality test.
	expect_not_ok "docs/README.md must not satisfy a task declaring README.md" \
		task_files_modified_on_branch "$BASE_BRANCH" README.md
}

@test "task_files_modified_on_branch: a pre-rename path still counts as evidence" {
	# Rename detection (diff.renames, on by default) collapses a rename into
	# the post-rename path only, so a task declaring the path it started from
	# would look unevidenced and wrongly block the merge. The helper passes
	# --no-renames to keep both sides visible. Regression guard: dropping
	# --no-renames must fail this test.
	git checkout -q "$BASE_BRANCH"
	printf 'line1\nline2\nline3\nline4\nline5\n' > old-name.sh
	git add old-name.sh
	git commit -q -m "base file"
	git checkout -q feature
	git merge -q "$BASE_BRANCH" -m "sync base"
	git mv old-name.sh new-name.sh
	git commit -q -m "rename file"

	# Sanity: git really does collapse this to the new path by default, so the
	# test is proving --no-renames does the work rather than passing trivially.
	expect_glob "$(git diff --name-only "$BASE_BRANCH...HEAD")" 'new-name.sh' \
		"default rename detection hides the pre-rename path"

	expect_ok "a task declaring the pre-rename path is still evidenced" \
		task_files_modified_on_branch "$BASE_BRANCH" old-name.sh
	expect_ok "the post-rename path is evidenced too" \
		task_files_modified_on_branch "$BASE_BRANCH" new-name.sh
}

@test "task_files_modified_on_branch: a non-ASCII path counts as evidence under core.quotePath" {
	# With core.quotePath enabled (git's default) --name-only octal-escapes and
	# double-quotes non-ASCII paths, e.g. "docs/caf\303\251.md", which can never
	# equal the verbatim path a task declares. The helper passes -z, which emits
	# paths unquoted. Set the config explicitly so the test is deterministic
	# even if the developer's global config disables quoting.
	git config core.quotePath true

	mkdir -p docs
	printf 'accented\n' > "docs/café.md"
	printf 'spaced\n' > "docs/two words.md"
	git add docs
	git commit -q -m "add awkward paths"

	# Sanity: confirm the quoting this test exists to defend against is active.
	expect_glob "$(git diff --name-only "$BASE_BRANCH...HEAD")" '*caf\\303\\251*' \
		"core.quotePath really does escape the path in --name-only output"

	expect_ok "a non-ASCII path is matched verbatim, not octal-escaped" \
		task_files_modified_on_branch "$BASE_BRANCH" "docs/café.md"
	expect_ok "a path containing spaces is matched verbatim" \
		task_files_modified_on_branch "$BASE_BRANCH" "docs/two words.md"
}

# =============================================================================
# UNIT TESTS: reconcile_failed_tasks_with_branch_evidence() (#620 task 2)
# Exercises the shipped reconciliation function directly — wired to the real
# task_files_modified_on_branch()/update_task() it calls — rather than a
# test-local mirror. This is the production code path the orchestrator's
# implement stage runs before computing the PARTIAL-COMPLETION GATE verdict.
# =============================================================================

@test "reconcile: promotes a failed task with affected_files evidence to completed" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "completed", affected_files: []},
		{id: 2, description: "task two", status: "failed", affected_files: ["src/two.sh"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p src
	echo "two" > src/two.sh
	git add src
	git commit -q -m "implement task two"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	[ "$count" -eq 1 ]

	local status
	status=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	[ "$status" = "completed" ]
}

@test "reconcile: preserves the reconciled task's recorded review_attempts" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "failed", review_attempts: 3, affected_files: ["src/one.sh"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p src
	echo "one" > src/one.sh
	git add src
	git commit -q -m "implement task one"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	expect_glob "$count" '1' "the evidenced task reconciles"

	local status attempts
	status=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	attempts=$(jq -r '(.tasks[] | select(.id == 1)).review_attempts' "$STATUS_FILE")
	expect_glob "$status" 'completed' "the task is promoted"
	# update_task() rewrites review_attempts unconditionally; reconciliation
	# must carry the recorded count through rather than resetting the task's
	# review history to 0.
	expect_glob "$attempts" '3' "review_attempts survives reconciliation"
}

@test "reconcile: leaves a failed task failed when its declared path was never touched" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "failed", affected_files: ["docs/missing.md"]}
	]')
	set_tasks "$tasks_json"

	echo "unrelated" > unrelated.txt
	git add unrelated.txt
	git commit -q -m "unrelated change"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	[ "$count" -eq 0 ]

	local status
	status=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	[ "$status" = "failed" ]
}

@test "reconcile: falls back to description-extracted paths when affected_files is empty" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "wire platform.sh via resolver — `src/handler.sh`", status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	mkdir -p src
	echo "handled" > src/handler.sh
	git add src
	git commit -q -m "implement handler"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	[ "$count" -eq 1 ]

	local status
	status=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	[ "$status" = "completed" ]
}

@test "reconcile: a task with no declared paths anywhere remains failed" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "vague task with no path", status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	echo "something" > something.txt
	git add something.txt
	git commit -q -m "unrelated"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	[ "$count" -eq 0 ]
}

@test "reconcile: leaves completed and pending tasks untouched" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "already done", status: "completed", affected_files: ["a.txt"]},
		{id: 2, description: "not started", status: "pending", affected_files: ["b.txt"]}
	]')
	set_tasks "$tasks_json"

	echo "x" > a.txt
	git add a.txt
	git commit -q -m "commit"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	[ "$count" -eq 0 ]

	local status1 status2
	status1=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	status2=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	[ "$status1" = "completed" ]
	[ "$status2" = "pending" ]
}

@test "reconcile: #616 scenario end-to-end — two failed tasks with branch evidence both reconcile to completed" {
	# Same PR #616 (issue #614) task/stage state as the gate-mirror regression
	# below, but driven straight through the shipped
	# reconcile_failed_tasks_with_branch_evidence() rather than a mirror, to
	# prove AC1/AC4 hold for the actual production code path.
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "resolve_consumer_file()", status: "completed",
		 affected_files: ["plugins/pipeline-core/scripts/resolve-pipeline-root.sh"]},
		{id: 2, description: "wire platform.sh via resolver", status: "failed",
		 affected_files: ["plugins/pipeline-core/scripts/implement-issue-orchestrator.sh"]},
		{id: 3, description: "bats coverage", status: "failed",
		 affected_files: ["tests/marketplace-smoke.bats"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p plugins/pipeline-core/scripts tests
	echo "resolve_consumer_file() { :; }" > plugins/pipeline-core/scripts/resolve-pipeline-root.sh
	echo "# wired via resolver" > plugins/pipeline-core/scripts/implement-issue-orchestrator.sh
	echo "# bats coverage" > tests/marketplace-smoke.bats
	git add plugins tests
	git commit -q -m "implement #614"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	[ "$count" -eq 2 ]

	local completed_after
	completed_after=$(jq '[(.tasks // [])[] | select(.status == "completed")] | length' "$STATUS_FILE")
	[ "$completed_after" -eq 3 ]
}

@test "reconcile: #618 scenario end-to-end — one task reconciles, the genuine gap stays failed" {
	# Same PR #618 (issue #615) task/stage state as the gate-mirror regression
	# below: task 1's deliverable landed despite "failed", task 2's declared
	# path (README.md) was never touched — the one true gap that must survive
	# reconciliation and keep blocking the merge.
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "version field in marketplace entry", status: "failed",
		 affected_files: ["marketplace.json"]},
		{id: 2, description: "README install section", status: "failed",
		 affected_files: ["README.md"]},
		{id: 3, description: "bats version-match coverage", status: "completed",
		 affected_files: ["tests/marketplace-version-match.bats"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p tests
	echo '{"version": "0.3.0"}' > marketplace.json
	echo "# bats coverage" > tests/marketplace-version-match.bats
	git add marketplace.json tests
	git commit -q -m "implement #615 (partial)"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	[ "$count" -eq 1 ]

	local status1 status2
	status1=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	status2=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	[ "$status1" = "completed" ]
	[ "$status2" = "failed" ]
}

# =============================================================================
# UNIT TESTS: revalidate_partial_block_against_branch() (#620 task 2)
# The implement-stage reconciliation cannot see work a *later* stage lands —
# and per #620's root-cause analysis the deliverable in #616 was landed by
# fix-pr-review-iter-1, i.e. after the implement stage had already recorded
# implement:partial. These exercise the gate-time re-evaluation that runs
# immediately before the merge gate reads its verdict.
# =============================================================================

@test "revalidate: clears a stale implement:partial marker once every task is evidenced" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "completed", affected_files: ["src/one.sh"]},
		{id: 2, description: "task two", status: "failed", affected_files: ["src/two.sh"]}
	]')
	set_tasks "$tasks_json"

	# State the implement stage left behind: task 2 recorded failed, marker and
	# persisted reason both saying 1/2.
	DEGRADED_STAGES=("implement:partial:1/2")
	jq '.merge_blocked_reason = "Partial implementation: 1/2 tasks completed (implement:partial:1/2)."' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	# fix-pr-review-iter-1 lands the abandoned deliverable afterwards.
	mkdir -p src
	echo "one" > src/one.sh
	echo "two" > src/two.sh
	git add src
	git commit -q -m "fix-pr-review-iter-1 completes task two"

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	[ -z "$reason" ]
	[ ${#DEGRADED_STAGES[@]} -eq 0 ]

	local status2
	status2=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	[ "$status2" = "completed" ]
}

@test "revalidate: keeps blocking and corrects the count when a task is still unevidenced" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "version field", status: "failed", affected_files: ["marketplace.json"]},
		{id: 2, description: "README install section", status: "failed", affected_files: ["README.md"]},
		{id: 3, description: "bats coverage", status: "completed", affected_files: ["tests/v.bats"]}
	]')
	set_tasks "$tasks_json"

	DEGRADED_STAGES=("implement:partial:1/3")
	jq '.merge_blocked_reason = "Partial implementation: 1/3 tasks completed (implement:partial:1/3)."' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	mkdir -p tests
	echo '{"version": "0.3.0"}' > marketplace.json
	echo "# bats coverage" > tests/v.bats
	git add marketplace.json tests
	git commit -q -m "implement #615 (partial)"

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	# README.md never touched -> still blocked, but at the true 2/3 count.
	[ ${#DEGRADED_STAGES[@]} -eq 1 ]
	[ "${DEGRADED_STAGES[0]}" = "implement:partial:2/3" ]

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	[ "$reason" = "Partial implementation: 2/3 tasks completed (implement:partial:2/3)." ]
}

@test "revalidate: never clobbers a persisted convergence reason" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "failed", affected_files: ["src/one.sh"]}
	]')
	set_tasks "$tasks_json"

	DEGRADED_STAGES=("quality:convergence_failure:implement-task-1:iter=3")
	jq '.merge_blocked_reason = "Quality loop convergence failure: 80% of issues repeating."' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	mkdir -p src
	echo "one" > src/one.sh
	git add src
	git commit -q -m "task one landed"

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	[ "$reason" = "Quality loop convergence failure: 80% of issues repeating." ]

	# The convergence marker survives; only implement:partial:* is rewritten.
	[ ${#DEGRADED_STAGES[@]} -eq 1 ]
	[ "${DEGRADED_STAGES[0]}" = "quality:convergence_failure:implement-task-1:iter=3" ]
}

@test "revalidate: adds a partial marker when a resumed run has none but a task lacks evidence" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "completed", affected_files: ["src/one.sh"]},
		{id: 2, description: "task two", status: "failed", affected_files: ["docs/missing.md"]}
	]')
	set_tasks "$tasks_json"

	DEGRADED_STAGES=()

	mkdir -p src
	echo "one" > src/one.sh
	git add src
	git commit -q -m "task one only"

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	[ ${#DEGRADED_STAGES[@]} -eq 1 ]
	[ "${DEGRADED_STAGES[0]}" = "implement:partial:1/2" ]

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	[ "$reason" = "Partial implementation: 1/2 tasks completed (implement:partial:1/2)." ]
}

@test "revalidate: no tasks recorded -> leaves markers and reason untouched" {
	DEGRADED_STAGES=("pr_review:max_iterations:5")
	jq '.merge_blocked_reason = "PR review loop ended without an approved verdict."' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	[ ${#DEGRADED_STAGES[@]} -eq 1 ]
	[ "${DEGRADED_STAGES[0]}" = "pr_review:max_iterations:5" ]

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	[ "$reason" = "PR review loop ended without an approved verdict." ]
}

@test "revalidate: #616 end-to-end — deliverables landed by a later stage unblock the merge gate" {
	# Full #616 replay through the shipped code path: implement stage recorded
	# 1/3 and persisted the block, fix-pr-review-iter-1 then landed tasks 2 and
	# 3, and the gate must not block (AC1, AC4).
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "resolve_consumer_file()", status: "completed",
		 affected_files: ["plugins/pipeline-core/scripts/resolve-pipeline-root.sh"]},
		{id: 2, description: "wire platform.sh via resolver", status: "failed",
		 affected_files: ["plugins/pipeline-core/scripts/implement-issue-orchestrator.sh"]},
		{id: 3, description: "bats coverage", status: "failed",
		 affected_files: ["tests/marketplace-smoke.bats"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p plugins/pipeline-core/scripts
	echo "resolve_consumer_file() { :; }" > plugins/pipeline-core/scripts/resolve-pipeline-root.sh
	git add plugins
	git commit -q -m "implement #614 (task 1 only)"

	# Implement stage verdict at that moment: 1/3, block recorded.
	DEGRADED_STAGES=("implement:partial:1/3")
	jq '.merge_blocked_reason = "Partial implementation: 1/3 tasks completed (implement:partial:1/3)."' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	# fix-pr-review-iter-1 completes the abandoned work, never touching
	# .tasks[].status — the #616 root cause.
	mkdir -p tests
	echo "# wired via resolver" > plugins/pipeline-core/scripts/implement-issue-orchestrator.sh
	echo "# bats coverage" > tests/marketplace-smoke.bats
	git add plugins tests
	git commit -q -m "fix-pr-review-iter-1"

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local gate_result blocked_reason block_kind
	gate_result=$(_run_merge_gate)
	blocked_reason="${gate_result%%$'\x1e'*}"
	block_kind="${gate_result#*$'\x1e'}"

	[ -z "$blocked_reason" ]
	[ -z "$block_kind" ]
}

@test "revalidate: #618 end-to-end — the one genuine gap still blocks the merge gate" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "version field in marketplace entry", status: "failed",
		 affected_files: ["marketplace.json"]},
		{id: 2, description: "README install section", status: "failed",
		 affected_files: ["README.md"]},
		{id: 3, description: "bats version-match coverage", status: "completed",
		 affected_files: ["tests/marketplace-version-match.bats"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p tests
	echo '{"version": "0.3.0"}' > marketplace.json
	echo "# bats coverage" > tests/marketplace-version-match.bats
	git add marketplace.json tests
	git commit -q -m "implement #615 (partial)"

	DEGRADED_STAGES=("implement:partial:1/3")
	jq '.merge_blocked_reason = "Partial implementation: 1/3 tasks completed (implement:partial:1/3)."' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local gate_result blocked_reason block_kind
	gate_result=$(_run_merge_gate)
	blocked_reason="${gate_result%%$'\x1e'*}"
	block_kind="${gate_result#*$'\x1e'}"

	[ "$block_kind" = "partial" ]
	[ "$blocked_reason" = "Partial implementation: 2/3 tasks completed (implement:partial:2/3)." ]
}

@test "drift guard: the merge stage calls revalidate_partial_block_against_branch before the gate" {
	local script_content
	script_content=$(cat "$ORCHESTRATOR_SCRIPT")

	expect_glob "$script_content" \
		'*revalidate_partial_block_against_branch "$BASE_BRANCH"*' \
		"merge stage must re-evaluate branch evidence at gate time"

	# The call has to precede the gate's persisted-reason read, or the gate
	# would act on the pre-reconciliation value.
	local call_line gate_line
	call_line=$(grep -n '^ *revalidate_partial_block_against_branch "\$BASE_BRANCH"' \
		"$ORCHESTRATOR_SCRIPT" | head -1 | cut -d: -f1)
	gate_line=$(grep -n "_persisted=\$(jq -r '.merge_blocked_reason // empty'" \
		"$ORCHESTRATOR_SCRIPT" | head -1 | cut -d: -f1)

	[ -n "$call_line" ]
	[ -n "$gate_line" ]
	[ "$call_line" -lt "$gate_line" ]
}

# Re-implements the file-evidence check proposed in #620 task 1: a task's
# declared paths are "on the branch" when they differ between BASE_BRANCH
# and HEAD. This is the missing piece the orchestrator's PARTIAL-COMPLETION
# GATE (issue #577) does not yet consult — that gap is #620 tasks 1-3.
_task_has_file_evidence() {
	local base="$1"; shift
	local touched
	touched=$(git diff "$base"...HEAD --name-only 2>/dev/null)
	local p
	for p in "$@"; do
		[[ "$touched" == *"$p"* ]] && return 0
	done
	return 1
}

# Mirrors the orchestrator's merge-block Gate A/Gate B computation verbatim
# (implement-issue-orchestrator.sh, "Gate B — partial task completion...").
# The drift-guard tests below assert the real script still contains these
# exact fragments, so this mirror cannot silently go stale.
_run_merge_gate() {
	local merge_blocked_reason=""
	local merge_block_kind=""

	local _persisted
	_persisted=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null || printf '')

	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" == "0" ]]; then
		:
	else
		if [[ -n "$_persisted" && "$_persisted" != "Partial implementation:"* ]]; then
			merge_blocked_reason="$_persisted"
			merge_block_kind="convergence"
		else
			local _ds
			for _ds in "${DEGRADED_STAGES[@]+"${DEGRADED_STAGES[@]}"}"; do
				if [[ "$_ds" == quality:convergence_failure:* ]]; then
					merge_blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
					merge_block_kind="convergence"
					break
				fi
			done
		fi
	fi

	if [[ -z "$merge_blocked_reason" ]]; then
		if [[ "${BLOCK_MERGE_ON_PARTIAL:-1}" == "0" ]]; then
			:
		else
			if [[ "$_persisted" == "Partial implementation:"* ]]; then
				merge_blocked_reason="$_persisted"
				merge_block_kind="partial"
			else
				local _dsp
				for _dsp in "${DEGRADED_STAGES[@]+"${DEGRADED_STAGES[@]}"}"; do
					if [[ "$_dsp" == implement:partial:* ]]; then
						merge_blocked_reason="Partial implementation — not all tasks completed (degraded_stages: $_dsp)."
						merge_block_kind="partial"
						break
					fi
					if [[ "$_dsp" == pr_review:max_iterations:* || "$_dsp" == pr_review:wall_timeout ]]; then
						merge_blocked_reason="PR review loop ended without an approved verdict (degraded_stages: $_dsp)."
						merge_block_kind="partial"
						break
					fi
				done
			fi
		fi
	fi

	printf '%s\x1e%s' "$merge_blocked_reason" "$merge_block_kind"
}

@test "#616 regression: three tasks, two recorded failed, all deliverables on branch -> gate does not block" {
	# PR #616 (issue #614) task/stage data, reproduced from the #620 bug report.
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "resolve_consumer_file()", status: "completed",
		 files: ["plugins/pipeline-core/scripts/resolve-pipeline-root.sh"]},
		{id: 2, description: "wire platform.sh via resolver", status: "failed",
		 files: ["plugins/pipeline-core/scripts/implement-issue-orchestrator.sh"]},
		{id: 3, description: "bats coverage", status: "failed",
		 files: ["tests/marketplace-smoke.bats"]}
	]')
	set_tasks "$tasks_json"

	# Ground truth #616 reported: all three deliverables genuinely landed on
	# the branch (a later fix-pr-review-iter-1 stage completed the abandoned
	# work), invisible to .tasks[].status.
	mkdir -p plugins/pipeline-core/scripts tests
	echo "resolve_consumer_file() { :; }" > plugins/pipeline-core/scripts/resolve-pipeline-root.sh
	echo "# wired via resolver" > plugins/pipeline-core/scripts/implement-issue-orchestrator.sh
	echo "# bats coverage" > tests/marketplace-smoke.bats
	git add plugins tests
	git commit -q -m "implement #614"

	local task_count completed_tasks
	task_count=$(jq '(.tasks // []) | length' "$STATUS_FILE")
	completed_tasks=$(jq '[(.tasks // [])[] | select(.status == "completed")] | length' "$STATUS_FILE")
	[ "$task_count" -eq 3 ]
	[ "$completed_tasks" -eq 1 ]

	# Branch-evidence re-evaluation (the #620 fix): a "failed" task with its
	# declared files present on the branch is not actually incomplete.
	local verified_completed=$completed_tasks
	local id status
	while IFS=$'\t' read -r id status; do
		[[ "$status" == "failed" ]] || continue
		local -a files=()
		while IFS= read -r f; do
			files+=("$f")
		done < <(jq -r --argjson id "$id" '(.tasks[] | select(.id == $id)).files[]' "$STATUS_FILE")
		if _task_has_file_evidence "$BASE_BRANCH" "${files[@]}"; then
			verified_completed=$((verified_completed + 1))
		fi
	done < <(jq -r '(.tasks // [])[] | [.id, .status] | @tsv' "$STATUS_FILE")

	[ "$verified_completed" -eq 3 ]

	# Replay the orchestrator's PARTIAL-COMPLETION GATE (issue #577) using the
	# branch-verified count in place of the raw stage-status count.
	if (( verified_completed < task_count )); then
		DEGRADED_STAGES+=("implement:partial:${verified_completed}/${task_count}")
		jq --arg reason "Partial implementation: ${verified_completed}/${task_count} tasks completed (implement:partial:${verified_completed}/${task_count})." \
			'.merge_blocked_reason = (.merge_blocked_reason // $reason)' \
			"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
	fi

	local gate_result blocked_reason block_kind
	gate_result=$(_run_merge_gate)
	blocked_reason="${gate_result%%$'\x1e'*}"
	block_kind="${gate_result#*$'\x1e'}"

	[ -z "$blocked_reason" ]
	[ -z "$block_kind" ]
	[ ${#DEGRADED_STAGES[@]} -eq 0 ]
}

@test "#618 regression: task with a declared path never modified on the branch still blocks, named in the reason" {
	# PR #618 (issue #615) task/stage data, reproduced from the #620 bug report.
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "version field in marketplace entry", status: "failed",
		 files: ["marketplace.json"]},
		{id: 2, description: "README install section", status: "failed",
		 files: ["README.md"]},
		{id: 3, description: "bats version-match coverage", status: "completed",
		 files: ["tests/marketplace-version-match.bats"]}
	]')
	set_tasks "$tasks_json"

	# Ground truth #618 reported: task 1's deliverable landed despite being
	# recorded failed, task 3 genuinely completed, and task 2's declared path
	# (README.md) was never touched on the branch — the one true gap.
	mkdir -p tests
	echo '{"version": "0.3.0"}' > marketplace.json
	echo "# bats coverage" > tests/marketplace-version-match.bats
	git add marketplace.json tests
	git commit -q -m "implement #615 (partial)"

	local task_count completed_tasks
	task_count=$(jq '(.tasks // []) | length' "$STATUS_FILE")
	completed_tasks=$(jq '[(.tasks // [])[] | select(.status == "completed")] | length' "$STATUS_FILE")
	[ "$task_count" -eq 3 ]
	[ "$completed_tasks" -eq 1 ]

	# Branch-evidence re-evaluation (the #620 fix): task 1 gains evidence
	# (marketplace.json was touched); task 2 gains none (README.md was not)
	# and must remain an unresolved gap, named by id and description.
	local verified_completed=$completed_tasks
	local -a unverified_tasks=()
	local id status desc
	while IFS=$'\t' read -r id status; do
		[[ "$status" == "failed" ]] || continue
		local -a files=()
		while IFS= read -r f; do
			files+=("$f")
		done < <(jq -r --argjson id "$id" '(.tasks[] | select(.id == $id)).files[]' "$STATUS_FILE")
		if _task_has_file_evidence "$BASE_BRANCH" "${files[@]}"; then
			verified_completed=$((verified_completed + 1))
		else
			desc=$(jq -r --argjson id "$id" '(.tasks[] | select(.id == $id)).description' "$STATUS_FILE")
			unverified_tasks+=("task ${id} (${desc})")
		fi
	done < <(jq -r '(.tasks // [])[] | [.id, .status] | @tsv' "$STATUS_FILE")

	[ "$verified_completed" -eq 2 ]
	[ "${#unverified_tasks[@]}" -eq 1 ]
	[[ "${unverified_tasks[0]}" == "task 2 (README install section)" ]]

	# Replay the orchestrator's PARTIAL-COMPLETION GATE (issue #577) using the
	# branch-verified count, naming the still-unresolved task in the reason
	# (#620 AC3) rather than reporting only a count.
	if (( verified_completed < task_count )); then
		DEGRADED_STAGES+=("implement:partial:${verified_completed}/${task_count}")
		local reason
		reason="Partial implementation: ${verified_completed}/${task_count} tasks completed (implement:partial:${verified_completed}/${task_count}); lacking file evidence: $(IFS=,; echo "${unverified_tasks[*]}")."
		jq --arg reason "$reason" \
			'.merge_blocked_reason = (.merge_blocked_reason // $reason)' \
			"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
	fi

	local gate_result blocked_reason block_kind
	gate_result=$(_run_merge_gate)
	blocked_reason="${gate_result%%$'\x1e'*}"
	block_kind="${gate_result#*$'\x1e'}"

	[ -n "$blocked_reason" ]
	[[ "$blocked_reason" == "Partial implementation:"* ]]
	[[ "$blocked_reason" == *"task 2 (README install section)"* ]]
	[ "$block_kind" == "partial" ]
}

@test "sanity: #616's raw stage status (no branch-evidence re-evaluation) does block" {
	# Same task roster/statuses as the regression test above but WITHOUT the
	# branch-evidence re-evaluation step — i.e. today's (pre-fix) behaviour.
	# Proves the gate mirror actually discriminates blocked vs not-blocked
	# rather than trivially passing regardless of input.
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "resolve_consumer_file()", status: "completed"},
		{id: 2, description: "wire platform.sh via resolver", status: "failed"},
		{id: 3, description: "bats coverage", status: "failed"}
	]')
	set_tasks "$tasks_json"

	local task_count completed_tasks
	task_count=$(jq '(.tasks // []) | length' "$STATUS_FILE")
	completed_tasks=$(jq '[(.tasks // [])[] | select(.status == "completed")] | length' "$STATUS_FILE")

	if (( completed_tasks < task_count )); then
		DEGRADED_STAGES+=("implement:partial:${completed_tasks}/${task_count}")
		jq --arg reason "Partial implementation: ${completed_tasks}/${task_count} tasks completed (implement:partial:${completed_tasks}/${task_count})." \
			'.merge_blocked_reason = (.merge_blocked_reason // $reason)' \
			"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
	fi

	local gate_result blocked_reason
	gate_result=$(_run_merge_gate)
	blocked_reason="${gate_result%%$'\x1e'*}"

	[ -n "$blocked_reason" ]
	[[ "$blocked_reason" == "Partial implementation:"* ]]
}

# =============================================================================
# DRIFT GUARD: keep _run_merge_gate() (above) in lockstep with the real
# orchestrator so this regression test cannot silently decouple from the
# code it is meant to exercise.
# =============================================================================

@test "drift guard: Gate B fallback scan for implement:partial:* is unchanged in the orchestrator" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'if [[ "$_dsp" == implement:partial:* ]]; then'* ]]
	[[ "$script_content" == *'merge_blocked_reason="Partial implementation — not all tasks completed (degraded_stages: $_dsp)."'* ]]
}

@test "drift guard: PARTIAL-COMPLETION GATE persisted-reason format is unchanged in the orchestrator" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'DEGRADED_STAGES+=("implement:partial:${completed_tasks}/${task_count}")'* ]]
	[[ "$script_content" == *'"Partial implementation: ${completed_tasks}/${task_count} tasks completed (implement:partial:${completed_tasks}/${task_count})."'* ]]
}
