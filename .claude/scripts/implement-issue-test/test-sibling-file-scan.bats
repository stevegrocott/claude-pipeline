#!/usr/bin/env bats
#
# test-sibling-file-scan.bats
# Tests for PR review sibling-file discovery logic:
#   - deduplication, 5-file cap, test/spec exclusion, diffed-file exclusion
#

load 'helpers/test-helper'

setup() {
    setup_test_env

    # Create a fake git repo
    git init --quiet "$TEST_TMP/repo"
    cd "$TEST_TMP/repo" || exit 1

    git commit --allow-empty -m "init" --quiet
    export BASE_BRANCH="main"
    git branch -M main
}

teardown() {
    teardown_test_env
}

# Helper: run the sibling-scan logic (mirrors orchestrator, bash 3 compatible).
# Pre-existing files on main serve as siblings.
# $1 = newline-separated list of "changed" files to add on a feature branch.
run_sibling_scan() {
    local changed_files="$1"

    git checkout -b feature-test --quiet 2>/dev/null

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        mkdir -p "$(dirname "$f")"
        echo "changed" > "$f"
        git add "$f"
    done <<< "$changed_files"
    git commit -m "feature changes" --quiet

    # --- sibling-scan logic (bash 3 compatible, mirrors orchestrator) ---
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null)

    local changed_files_nl
    changed_files_nl=$(git diff --name-only "$BASE_BRANCH"...HEAD -- 2>/dev/null)

    local seen_nl="" sib_f sib_dir
    local -a sibling_files_list=()
    while IFS= read -r sib_f; do
        [[ -z "$sib_f" ]] && continue
        sib_dir="${sib_f%/*}"
        [[ "$sib_dir" == "$sib_f" ]] && sib_dir="."
        for f in "$repo_root/$sib_dir"/*.ts "$repo_root/$sib_dir"/*.tsx; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *".test."* || "$f" == *".spec."* ]] && continue
            local rel="${f#"$repo_root"/}"
            printf '%s\n' "$changed_files_nl" | grep -qxF "$rel" && continue
            printf '%s\n' "$seen_nl" | grep -qxF "$rel" && continue
            seen_nl="${seen_nl}${rel}
"
            sibling_files_list+=("$rel")
            ((${#sibling_files_list[@]} >= 5)) && break 2
        done
    done <<< "$changed_files_nl"

    printf '%s\n' "${sibling_files_list[@]}"
}

# ─── Test: .test. and .spec. files are excluded ───

@test "sibling scan excludes .test.ts and .spec.tsx files" {
    mkdir -p src/routes
    echo "x" > src/routes/sibling.ts
    echo "x" > src/routes/sibling.test.ts
    echo "x" > src/routes/sibling.spec.tsx
    echo "x" > src/routes/helper.ts
    git add src/routes
    git commit -m "main files" --quiet

    run run_sibling_scan "src/routes/changed.ts"

    [[ "$output" != *".test."* ]]
    [[ "$output" != *".spec."* ]]
    [[ "$output" == *"src/routes/helper.ts"* ]]
    [[ "$output" == *"src/routes/sibling.ts"* ]]
}

# ─── Test: already-diffed files are excluded ───

@test "sibling scan excludes files already in the diff" {
    mkdir -p src/models
    echo "x" > src/models/other.ts
    git add src/models
    git commit -m "main files" --quiet

    run run_sibling_scan "src/models/changed.ts"

    [[ "$output" != *"src/models/changed.ts"* ]]
    [[ "$output" == *"src/models/other.ts"* ]]
}

# ─── Test: deduplication ───

@test "sibling scan deduplicates files from overlapping directories" {
    mkdir -p src/shared
    echo "x" > src/shared/util.ts
    echo "x" > src/shared/helper.ts
    git add src/shared
    git commit -m "main files" --quiet

    run run_sibling_scan $'src/shared/a.ts\nsrc/shared/b.ts'

    local count
    count=$(echo "$output" | grep -c "src/shared/util.ts" || true)
    [[ "$count" -eq 1 ]]

    count=$(echo "$output" | grep -c "src/shared/helper.ts" || true)
    [[ "$count" -eq 1 ]]
}

# ─── Test: cap at 5 ───

@test "sibling scan caps at 5 files" {
    mkdir -p src/big
    for i in $(seq 1 8); do
        echo "x" > "src/big/file${i}.ts"
    done
    git add src/big
    git commit -m "main files" --quiet

    run run_sibling_scan "src/big/changed.ts"

    local count
    count=$(echo "$output" | grep -c '\.ts' || true)
    [[ "$count" -le 5 ]]
    [[ "$count" -ge 1 ]]
}

# ─── Test: root-level files (sib_dir == sib_f fallback to ".") ───

@test "sibling scan handles root-level files" {
    echo "x" > sibling.ts
    git add sibling.ts
    git commit -m "main files" --quiet

    run run_sibling_scan "changed.ts"

    [[ "$output" == *"sibling.ts"* ]]
    local changed_lines
    changed_lines=$(echo "$output" | grep -c "^changed.ts$" || true)
    [[ "$changed_lines" -eq 0 ]]
}
