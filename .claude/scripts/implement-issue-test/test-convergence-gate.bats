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
# Exercises the shipped helper directly against a real repo.
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

@test "task_files_modified_on_branch: ./-prefixed and /-rooted declared paths still match" {
	# _extract_task_files_from_desc() pulls tokens out of prose, where a path
	# is as likely to be written "./src/app.ts" or "/src/app.ts" as the
	# repo-root-relative form git emits. Normalising the declared side keeps
	# those from reading as unevidenced and falsely blocking the merge.
	mkdir -p src
	echo "app" > src/app.ts
	git add src
	git commit -q -m "add app"

	expect_ok "a ./-prefixed declared path is normalised before comparison" \
		task_files_modified_on_branch "$BASE_BRANCH" ./src/app.ts
	expect_ok "a /-rooted declared path is normalised before comparison" \
		task_files_modified_on_branch "$BASE_BRANCH" /src/app.ts
	expect_ok "repeated ./ segments are stripped" \
		task_files_modified_on_branch "$BASE_BRANCH" ././src/app.ts

	# Normalisation must not loosen matching into substring territory.
	expect_not_ok "normalisation must not turn a partial token into evidence" \
		task_files_modified_on_branch "$BASE_BRANCH" ./app.ts
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
# UNIT TESTS: _task_operational_deliverable() (#840 task 1)
# A task whose deliverable is an action against a live system (a device
# config write, a service restart) produces no repo diff, so it needs a
# marker distinct from `deliverable:comment:`/`deliverable:file:` (#634) that
# the branch-evidence gate can recognise instead of failing it for lacking a
# file diff.
# =============================================================================

@test "_task_operational_deliverable: recognises a declared operational marker" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "apply gate station config `deliverable:operational:ha-lovelace-save.sh --verify`", status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	local cmd
	cmd=$(_task_operational_deliverable 1)
	expect_ok "task 1 is recognised as an operational deliverable" \
		_task_operational_deliverable 1
	expect_glob "$cmd" 'ha-lovelace-save.sh --verify' \
		"the declared verification command is returned verbatim"
}

@test "_task_operational_deliverable: a colon-bearing verification command survives" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "restart service `deliverable:operational:curl -s http://gate/api/status | grep muted:true`", status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	local cmd
	cmd=$(_task_operational_deliverable 1)
	expect_glob "$cmd" 'curl -s http://gate/api/status | grep muted:true' \
		"only the leading operational: prefix is stripped"
}

@test "_task_operational_deliverable: does not recognise a comment deliverable" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "spike a ruling `deliverable:comment:ruling-840`", status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	expect_not_ok "a comment-kind deliverable is not an operational one" \
		_task_operational_deliverable 1
}

@test "_task_operational_deliverable: does not recognise a file deliverable" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "write report `deliverable:file:docs/ruling.md`", status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	expect_not_ok "a file-kind deliverable is not an operational one" \
		_task_operational_deliverable 1
}

@test "_task_operational_deliverable: a bare 'operational' with no command is unrecognised" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "apply config `deliverable:operational`", status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	expect_not_ok "a markerless operational deliverable fails closed" \
		_task_operational_deliverable 1
}

@test "_task_operational_deliverable: a task with no deliverable annotation is unrecognised" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "ordinary code task `src/app.ts`", status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	expect_not_ok "an unannotated task is not an operational deliverable" \
		_task_operational_deliverable 1
}

@test "_task_operational_deliverable: an unknown task id is unrecognised" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "apply config `deliverable:operational:verify.sh`", status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	expect_not_ok "a nonexistent task id has nothing to recognise" \
		_task_operational_deliverable 99
}

# =============================================================================
# UNIT TESTS: _operational_deliverable_evidenced() (#840 task 2)
# An operational deliverable changes a live system this process cannot reach
# from here, so it is evidenced by a RECORD of a run — an issue comment
# naming the verification command with output alongside it — never by
# rerunning the command.
# =============================================================================

@test "_operational_deliverable_evidenced: evidenced when a comment records the command and its output" {
	_fetch_issue_comment_bodies() {
		printf '%s\n' "Ran \`ha-lovelace-save.sh --verify\` -> muted:true"
	}

	expect_ok "command plus reported output counts as a recorded run" \
		_operational_deliverable_evidenced "ha-lovelace-save.sh --verify"
}

@test "_operational_deliverable_evidenced: not evidenced when the command is quoted with no output" {
	_fetch_issue_comment_bodies() {
		printf '%s\n' "Will run \`ha-lovelace-save.sh --verify\` shortly."
	}

	expect_not_ok \
		"the bare command with nothing reported back is not evidence" \
		_operational_deliverable_evidenced "ha-lovelace-save.sh --verify"
}

@test "_operational_deliverable_evidenced: not evidenced when no comment names the command" {
	_fetch_issue_comment_bodies() {
		printf '%s\n' "This comment never mentions the verification command."
	}

	expect_not_ok "an absent command has no run recorded" \
		_operational_deliverable_evidenced "ha-lovelace-save.sh --verify"
}

@test "_operational_deliverable_evidenced: fails closed when the tracker is unreachable" {
	_fetch_issue_comment_bodies() { return 1; }

	expect_not_ok "an unreachable tracker cannot supply evidence" \
		_operational_deliverable_evidenced "ha-lovelace-save.sh --verify"
}

@test "_operational_deliverable_evidenced: fails closed on an empty command" {
	_fetch_issue_comment_bodies() {
		printf '%s\n' "output here but no command declared"
	}

	expect_not_ok "an empty command has nothing to search for" \
		_operational_deliverable_evidenced ""
}

@test "_operational_deliverable_evidenced: matches the command among several unrelated comments" {
	_fetch_issue_comment_bodies() {
		printf '%s\n' "An unrelated comment."
		printf '%s\n' "Ran \`ha-lovelace-save.sh --verify\` -> muted:true"
		printf '%s\n' "Another unrelated comment."
	}

	expect_ok "the recorded run is found among unrelated comments" \
		_operational_deliverable_evidenced "ha-lovelace-save.sh --verify"
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
	expect_glob "$count" '1' "the evidenced task reconciles"

	local status
	status=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	expect_glob "$status" 'completed' "the task is promoted"
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
	expect_glob "$count" '0' "an unevidenced task does not reconcile"

	local status
	status=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	expect_glob "$status" 'failed' "the task stays failed"
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
	expect_glob "$count" '1' "the description-extracted path reconciles the task"

	local status
	status=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	expect_glob "$status" 'completed' "the task is promoted"
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
	expect_glob "$count" '0' "a task declaring no paths cannot be reconciled"
}

@test "reconcile: refuses to promote a task whose declared files are also declared by a still-failed sibling" {
	# Issue #620 review: when several tasks declare the same file, branch
	# evidence for that file cannot attribute it to one task — the first
	# task to land must not promote its siblings too.
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "failed", affected_files: ["shared.sh"]},
		{id: 2, description: "task two", status: "failed", affected_files: ["shared.sh"]},
		{id: 3, description: "task three", status: "failed", affected_files: ["shared.sh"]}
	]')
	set_tasks "$tasks_json"

	echo "landed" > shared.sh
	git add shared.sh
	git commit -q -m "one of the three tasks lands shared.sh"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	expect_glob "$count" '0' \
		"no task reconciles when its declared file set is shared with a still-failed sibling"

	local status1 status2 status3
	status1=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	status2=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	status3=$(jq -r '(.tasks[] | select(.id == 3)).status' "$STATUS_FILE")
	expect_glob "$status1" 'failed' "task 1 remains failed — ambiguous attribution"
	expect_glob "$status2" 'failed' "task 2 remains failed — ambiguous attribution"
	expect_glob "$status3" 'failed' "task 3 remains failed — ambiguous attribution"
}

@test "reconcile: does not promote an evidenced task while the test suite is red this run" {
	# Issue #620's proposed direction requires file evidence AND a green
	# test suite before treating a failed task as satisfied.
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "failed", affected_files: ["src/one.sh"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p src
	echo "one" > src/one.sh
	git add src
	git commit -q -m "implement task one"

	DEGRADED_STAGES=("test:full_suite_red")

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	expect_glob "$count" '0' "a red test suite blocks promotion even with file evidence"

	local status
	status=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	expect_glob "$status" 'failed' "the task remains failed while the test suite is red"
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
	expect_glob "$count" '0' "only failed tasks are candidates for reconciliation"

	local status1 status2
	status1=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	status2=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	expect_glob "$status1" 'completed' "a completed task is left untouched"
	expect_glob "$status2" 'pending' "a pending task is left untouched"
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
	expect_glob "$count" '2' "both evidenced failed tasks reconcile"

	local completed_after
	completed_after=$(jq '[(.tasks // [])[] | select(.status == "completed")] | length' "$STATUS_FILE")
	expect_glob "$completed_after" '3' "all three tasks read completed after reconciliation"
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
	expect_glob "$count" '1' "only the evidenced task reconciles"

	local status1 status2
	status1=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	status2=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	expect_glob "$status1" 'completed' "the evidenced task is promoted"
	expect_glob "$status2" 'failed' "the genuine gap survives reconciliation"
}

# =============================================================================
# UNIT TESTS: reconcile_failed_tasks_with_branch_evidence() and operational
# deliverables (#840 task 2). A task declaring `deliverable:operational:` has
# no repo diff to speak of by design (#840 task 1) — these prove it is judged
# on a recorded run of its verification command instead, ahead of the
# file-evidence path, rather than falling into "no declared file evidence".
# =============================================================================

@test "reconcile: promotes a failed operational-deliverable task with a recorded verification run" {
	_fetch_issue_comment_bodies() {
		printf '%s\n' \
			"Ran \`ha-lovelace-save.sh --verify\` -> muted:true"
	}

	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1,
		 description: "apply gate config `deliverable:operational:ha-lovelace-save.sh --verify`",
		 status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	expect_glob "$count" '1' \
		"a recorded verification run reconciles the operational task"

	local status kind
	status=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	kind=$(jq -r '(.tasks[] | select(.id == 1)).evidence_kind' "$STATUS_FILE")
	expect_glob "$status" 'completed' "the task is promoted"
	expect_glob "$kind" 'operational' \
		"the promotion is stamped with the operational evidence kind"
}

@test "reconcile: leaves a failed operational-deliverable task failed with no recorded run" {
	_fetch_issue_comment_bodies() {
		printf '%s\n' "No verification was ever reported here."
	}

	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1,
		 description: "apply gate config `deliverable:operational:ha-lovelace-save.sh --verify`",
		 status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	expect_glob "$count" '0' \
		"no recorded run means the operational task cannot reconcile"

	local status
	status=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	expect_glob "$status" 'failed' "the task stays failed"
}

@test "reconcile: does not promote an evidenced operational task while the test suite is red" {
	_fetch_issue_comment_bodies() {
		printf '%s\n' \
			"Ran \`ha-lovelace-save.sh --verify\` -> muted:true"
	}

	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1,
		 description: "apply gate config `deliverable:operational:ha-lovelace-save.sh --verify`",
		 status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	DEGRADED_STAGES=("test:full_suite_red")

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	expect_glob "$count" '0' \
		"a red test suite blocks promotion even with a recorded run"

	local status
	status=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	expect_glob "$status" 'failed' \
		"the operational task remains failed while the test suite is red"
}

@test "reconcile: an operational task with no repo files never falls into the file-evidence path" {
	# Regression guard: before #840 task 2, a task declaring no affected
	# files (which every operational task does, by design) hit "no declared
	# file evidence" and was left failed regardless of what actually
	# happened. This proves the operational check runs BEFORE that
	# short-circuit rather than being masked by it.
	_fetch_issue_comment_bodies() {
		printf '%s\n' \
			"Ran \`ha-lovelace-save.sh --verify\` -> muted:true"
	}

	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1,
		 description: "apply gate config `deliverable:operational:ha-lovelace-save.sh --verify`",
		 status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	expect_glob "$count" '1' \
		"the operational path reconciles the task despite no declared files"
}

@test "reconcile: an evidenced operational task and an evidenced file task both reconcile in the same run" {
	_fetch_issue_comment_bodies() {
		printf '%s\n' \
			"Ran \`ha-lovelace-save.sh --verify\` -> muted:true"
	}

	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1,
		 description: "apply gate config `deliverable:operational:ha-lovelace-save.sh --verify`",
		 status: "failed", affected_files: []},
		{id: 2, description: "task two", status: "failed",
		 affected_files: ["src/two.sh"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p src
	echo "two" > src/two.sh
	git add src
	git commit -q -m "implement task two"

	local count
	count=$(reconcile_failed_tasks_with_branch_evidence "$BASE_BRANCH")
	expect_glob "$count" '2' \
		"both the operational and file-evidenced tasks reconcile"

	local status1 status2 kind1 kind2
	status1=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	status2=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	kind1=$(jq -r '(.tasks[] | select(.id == 1)).evidence_kind' "$STATUS_FILE")
	kind2=$(jq -r '(.tasks[] | select(.id == 2)).evidence_kind // "file"' \
		"$STATUS_FILE")
	expect_glob "$status1" 'completed' "the operational task is promoted"
	expect_glob "$status2" 'completed' "the file-evidenced task is promoted"
	expect_glob "$kind1" 'operational' \
		"the operational task carries the operational evidence kind"
	expect_glob "$kind2" 'file' \
		"the file-evidenced task has no evidence_kind field (implicit file)"
}

# =============================================================================
# UNIT TESTS: _lacking_evidence_summary() evidence-kind labelling (#840
# task 3). A task still "failed" after reconciliation needs its evidence
# kind named in the merge-block message — otherwise "lacking evidence"
# reads as "no file changed" even for an operational task that was never
# going to produce one.
# =============================================================================

@test "_lacking_evidence_summary: names file evidence for a plain failed task" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 2, description: "README install section", status: "failed",
		 affected_files: ["README.md"]}
	]')
	set_tasks "$tasks_json"

	local summary
	summary=$(_lacking_evidence_summary)
	expect_glob "$summary" '*task 2 (README install section) \[file evidence: README.md\]*' \
		"a file-evidenced task must be labelled with the file kind and its path"
}

@test "_lacking_evidence_summary: names operational evidence for an unevidenced operational task" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1,
		 description: "apply gate config `deliverable:operational:ha-lovelace-save.sh --verify`",
		 status: "failed", affected_files: []}
	]')
	set_tasks "$tasks_json"

	local summary
	summary=$(_lacking_evidence_summary)
	expect_glob "$summary" '*task 1 (apply gate config*) \[operational evidence: ha-lovelace-save.sh --verify\]*' \
		"an operational task must be labelled with the operational kind and its verification command"
}

@test "_lacking_evidence_summary: labels each task with its own evidence kind in a mixed roster" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1,
		 description: "apply gate config `deliverable:operational:ha-lovelace-save.sh --verify`",
		 status: "failed", affected_files: []},
		{id: 2, description: "README install section", status: "failed",
		 affected_files: ["README.md"]}
	]')
	set_tasks "$tasks_json"

	local summary
	summary=$(_lacking_evidence_summary)
	expect_glob "$summary" '*\[operational evidence: ha-lovelace-save.sh --verify\]*' \
		"the operational task keeps its own kind"
	expect_glob "$summary" '*\[file evidence: README.md\]*' \
		"the file task keeps its own kind"
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
	expect_ok "the stale persisted reason must be cleared" test -z "$reason"
	expect_glob "${#DEGRADED_STAGES[@]}" '0' "the stale implement:partial marker must be dropped"

	local status2
	status2=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	expect_glob "$status2" 'completed' "the late-landed task is reconciled to completed"
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
	expect_glob "${#DEGRADED_STAGES[@]}" '1' "exactly one degraded-stage marker survives"
	expect_glob "${DEGRADED_STAGES[0]}" 'implement:partial:2/3' \
		"the marker must carry the branch-verified count"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_glob "$reason" 'Partial implementation: 2/3 tasks completed (implement:partial:2/3)*' \
		"reason must lead with the branch-verified count"
	expect_glob "$reason" '*task 2 (README install section)*' \
		"reason must name the task still lacking file evidence"
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
	expect_glob "$reason" 'Quality loop convergence failure: 80% of issues repeating.' \
		"a non-partial persisted reason must not be rewritten"

	# The convergence marker survives; only implement:partial:* is rewritten.
	expect_glob "${#DEGRADED_STAGES[@]}" '1' "the convergence marker must survive"
	expect_glob "${DEGRADED_STAGES[0]}" 'quality:convergence_failure:implement-task-1:iter=3' \
		"the convergence marker must be unchanged"
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

	expect_glob "${#DEGRADED_STAGES[@]}" '1' "a partial marker must be added"
	expect_glob "${DEGRADED_STAGES[0]}" 'implement:partial:1/2' \
		"the added marker must carry the branch-verified count"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_glob "$reason" 'Partial implementation: 1/2 tasks completed (implement:partial:1/2)*' \
		"reason must lead with the branch-verified count"
	expect_glob "$reason" '*task 2 (task two)*' \
		"reason must name the task still lacking file evidence"
}

@test "revalidate: no tasks recorded -> leaves markers and reason untouched" {
	DEGRADED_STAGES=("pr_review:max_iterations:5")
	jq '.merge_blocked_reason = "PR review loop ended without an approved verdict."' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	expect_glob "${#DEGRADED_STAGES[@]}" '1' "the unrelated marker must survive"
	expect_glob "${DEGRADED_STAGES[0]}" 'pr_review:max_iterations:5' \
		"the unrelated marker must be unchanged"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_glob "$reason" 'PR review loop ended without an approved verdict.' \
		"the unrelated persisted reason must be unchanged"
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

	expect_ok "gate must not block once every deliverable is evidenced on the branch" \
		test -z "$blocked_reason"
	expect_ok "block kind must be empty when the gate does not block" \
		test -z "$block_kind"
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

	expect_glob "$block_kind" 'partial' "block kind must be partial"
	expect_glob "$blocked_reason" 'Partial implementation: 2/3 tasks completed (implement:partial:2/3)*' \
		"reason must lead with the branch-verified count"
	expect_glob "$blocked_reason" '*task 2 (README install section)*' \
		"reason must name the task still lacking file evidence"
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

	expect_ok "the revalidate call must be present in the merge stage" \
		test -n "$call_line"
	expect_ok "the gate's persisted-reason read must be present" \
		test -n "$gate_line"
	expect_ok "revalidation must run before the gate reads the persisted reason" \
		test "$call_line" -lt "$gate_line"
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
		 affected_files: ["plugins/pipeline-core/scripts/resolve-pipeline-root.sh"]},
		{id: 2, description: "wire platform.sh via resolver", status: "failed",
		 affected_files: ["plugins/pipeline-core/scripts/implement-issue-orchestrator.sh"]},
		{id: 3, description: "bats coverage", status: "failed",
		 affected_files: ["tests/marketplace-smoke.bats"]}
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

	DEGRADED_STAGES=("implement:partial:1/3")
	jq '.merge_blocked_reason = "Partial implementation: 1/3 tasks completed (implement:partial:1/3)."' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	# Branch-evidence re-evaluation (the #620 fix), exercised through the
	# shipped function rather than a test-local mirror.
	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local gate_result blocked_reason block_kind
	gate_result=$(_run_merge_gate)
	blocked_reason="${gate_result%%$'\x1e'*}"
	block_kind="${gate_result#*$'\x1e'}"

	expect_ok "gate must not block once every declared file is evidenced on the branch" \
		test -z "$blocked_reason"
	expect_ok "block kind must be empty when the gate does not block" \
		test -z "$block_kind"
}

@test "#618 regression: task with a declared path never modified on the branch still blocks, named in the reason" {
	# PR #618 (issue #615) task/stage data, reproduced from the #620 bug report.
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

	# Ground truth #618 reported: task 1's deliverable landed despite being
	# recorded failed, task 3 genuinely completed, and task 2's declared path
	# (README.md) was never touched on the branch — the one true gap.
	mkdir -p tests
	echo '{"version": "0.3.0"}' > marketplace.json
	echo "# bats coverage" > tests/marketplace-version-match.bats
	git add marketplace.json tests
	git commit -q -m "implement #615 (partial)"

	DEGRADED_STAGES=("implement:partial:1/3")
	jq '.merge_blocked_reason = "Partial implementation: 1/3 tasks completed (implement:partial:1/3)."' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	# Branch-evidence re-evaluation (the #620 fix), exercised through the
	# shipped function rather than a test-local mirror (#620 AC3, AC5).
	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local gate_result blocked_reason block_kind
	gate_result=$(_run_merge_gate)
	blocked_reason="${gate_result%%$'\x1e'*}"
	block_kind="${gate_result#*$'\x1e'}"

	expect_glob "$block_kind" 'partial' "block kind must be partial"
	expect_glob "$blocked_reason" 'Partial implementation: 2/3 tasks completed (implement:partial:2/3)*' \
		"reason must lead with the branch-verified count"
	expect_glob "$blocked_reason" '*task 2 (README install section)*' \
		"reason must name the task still lacking file evidence (#620 AC5)"
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

	expect_glob "$blocked_reason" 'Partial implementation:*' \
		"raw stage status without branch-evidence re-evaluation must still block"
}

# =============================================================================
# DRIFT GUARD: keep _run_merge_gate() (above) in lockstep with the real
# orchestrator so this regression test cannot silently decouple from the
# code it is meant to exercise.
# =============================================================================

@test "drift guard: Gate B fallback scan for implement:partial:* is unchanged in the orchestrator" {
	# grep -F (fixed-string), not expect_glob: the fragments below contain
	# literal "[[" / "]]", which expect_glob's unquoted bash pattern match
	# would otherwise parse as bracket-expression glob syntax.
	expect_ok "Gate B fallback scan pattern must be unchanged" \
		grep -qF 'if [[ "$_dsp" == implement:partial:* ]]; then' "$ORCHESTRATOR_SCRIPT"
	expect_ok "Gate B fallback reason text must be unchanged" \
		grep -qF 'merge_blocked_reason="Partial implementation — not all tasks completed (degraded_stages: $_dsp)."' "$ORCHESTRATOR_SCRIPT"
}

@test "drift guard: PARTIAL-COMPLETION GATE persisted-reason format is unchanged in the orchestrator" {
	expect_ok "DEGRADED_STAGES partial marker must be unchanged" \
		grep -qF 'DEGRADED_STAGES+=("implement:partial:${completed_tasks}/${task_count}")' "$ORCHESTRATOR_SCRIPT"
	# Reason must report the raw stage verdict, the branch-verified verdict,
	# and the lacking-evidence list (#620 AC3) — not just a bare count.
	expect_ok "persisted reason must carry the raw verdict, branch-verified verdict, and lacking-evidence list" \
		grep -qF '_reason="Partial implementation: ${completed_tasks}/${task_count} tasks completed (implement:partial:${completed_tasks}/${task_count}); stage-reported ${_raw_completed_tasks}/${task_count}${_lacking_evidence:+; lacking evidence: ${_lacking_evidence}}."' "$ORCHESTRATOR_SCRIPT"
}
