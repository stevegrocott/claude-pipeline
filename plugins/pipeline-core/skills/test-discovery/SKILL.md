---
name: test-discovery
description: Use when implementing any feature or bug fix that touches existing source files — runs a 6-phase protocol to surface existing unit tests, consumer tests, E2E specs, and auth guards before any new test is written; prevents duplicate tests and auth-guard blind spots
inputs:
  - name: source_file
    type: file_path
    required: true
    description: The source file being changed or added (e.g., src/services/UserService.ts)
  - name: changed_functions
    type: string
    required: false
    description: Optional comma-separated list of changed function names; if omitted Phase 4b extracts them from git diff HEAD~1
outputs:
  - name: tests_checked
    type: yaml
    description: Structured discovery result — unit_tests, consumer_tests, e2e_specs, e2e_specs_primary, auth_risk, decision
side_effects:
  - reads_test_files
composes:
  - test-driven-development
failure_modes:
  - id: platform_context_missing
    mitigation: Warn and auto-detect test layout from package.json, pytest.ini, or go.mod in project root; continue with detected layout
  - id: no_tests_found
    mitigation: Set decision to write_new; proceed to Phase 6 dispatching test-driven-development
  - id: git_diff_unavailable
    mitigation: Skip Phase 4b changed function promotion; proceed with all e2e_specs as e2e_specs_primary
---

# Test Discovery

## Overview

Discover existing tests before writing new ones. Run 6 phases to find what already exists — unit tests, consumer tests, E2E specs, auth guards — then dispatch to the right action.

**Core principle:** Never write a new test without first knowing what already exists.

## TodoWrite Checklist

Create these todos with TodoWrite before starting any phase:

- [ ] **Phase 0** — Read `$PLATFORM_CONTEXT_FILE`; warn and auto-detect layout if missing
- [ ] **Phase 1** — Find co-located unit/spec tests via find; collect as `unit_tests[]`
- [ ] **Phase 2** — Run import-filter: `grep -rl "from.*${SOURCE_STEM}"` across test files; collect as `consumer_tests[]`
- [ ] **Phase 3** — Run mock-filter: `grep -EL "jest\.mock"` on consumer tests
- [ ] **Phase 4** — Find E2E specs referencing `$SOURCE_STEM`; collect as `e2e_specs[]`
- [ ] **Phase 4b** — Extract changed functions from `git diff HEAD~1`; promote matching E2E specs to `e2e_specs_primary`
- [ ] **Phase 5** — Trace auth guards; set `auth_risk: true` if a guard file was recently changed
- [ ] **Phase 6** — Evaluate decision; dispatch to `test-driven-development` for `write_new`/`both`; follow update steps for `update_existing`

## Phases

### Phase 0: Read Test Layout

Read `$PLATFORM_CONTEXT_FILE` (default: `.claude/config/context.md`) for project test conventions.

```bash
cat "${PLATFORM_CONTEXT_FILE:-.claude/config/context.md}" 2>/dev/null || echo "MISSING"
```

**If missing**, warn: `"PLATFORM_CONTEXT_FILE not found — using auto-detect"` then detect:

```bash
if [[ -f package.json ]]; then
  jq -r '.jest.testMatch // empty' package.json 2>/dev/null || echo "Node: __tests__/ or *.test.* co-located"
elif [[ -f pytest.ini ]] || [[ -f pyproject.toml ]]; then
  grep -E "testpaths|test_dir" pytest.ini pyproject.toml 2>/dev/null | head -3
elif [[ -f go.mod ]]; then
  echo "Go: *_test.go co-located with source"
fi
```

Set `layout` for subsequent phases.

### Phase 1: Discover Unit Tests

Find test files co-located with the source file:

```bash
SOURCE_BASENAME="${SOURCE_FILE##*/}"        # UserService.ts
SOURCE_STEM="${SOURCE_BASENAME%.*}"          # UserService (strip extension)
SOURCE_DIR="$(dirname "$SOURCE_FILE")"       # src/services

find "$SOURCE_DIR" "$SOURCE_DIR/__tests__" \
  -name "${SOURCE_STEM}.test.*" \
  -o -name "${SOURCE_STEM}.spec.*" \
  2>/dev/null
```

Collect results as `unit_tests[]`.

### Phase 2: Import Filter

Find all test files in the project that import the source file:

```bash
grep -rl "from.*${SOURCE_STEM}" --include="*.test.*" --include="*.spec.*" . 2>/dev/null
```

Collect results as `consumer_tests[]`. These are **consumer tests** — files that import the source but are not the primary co-located test. Merge unique entries into `unit_tests[]` for the Phase 6 decision step.

### Phase 3: Mock Filter

From consumer tests, exclude files that mock the source entirely — they test the mock, not the real code:

```bash
grep -EL "jest\.mock" "${consumer_tests[@]}" 2>/dev/null
```

Files passing this filter are **real unit tests** and the primary target for updates.

### Phase 4: E2E Spec Coverage

Find E2E specs referencing the source stem:

```bash
grep -rl "$SOURCE_STEM" --include="*.spec.*" --include="*.e2e.*" \
  e2e/ tests/e2e/ cypress/ playwright/ 2>/dev/null
```

Collect as `e2e_specs[]`.

### Phase 4b: Changed Function Promotion

Extract function names changed in the current branch:

```bash
git diff HEAD~1 -- "$SOURCE_FILE" \
  | grep '^+' \
  | grep -oE '(function |async function |const [a-zA-Z_])[a-zA-Z_][a-zA-Z0-9_]*\s*[=(]' \
  | grep -oE '[a-zA-Z_][a-zA-Z0-9_]+' \
  | sort -u
```

For each changed function name, promote any E2E spec that references it:

```bash
grep -l "$FUNC_NAME" "${e2e_specs[@]}" 2>/dev/null
```

Matching specs become `e2e_specs_primary[]`. All others remain in `e2e_specs[]`.

### Phase 5: Auth Guard Tracing

Check whether any authentication or authorization guard file was recently modified:

```bash
git diff HEAD~1 --name-only \
  | grep -iE '(middleware|guard|auth|protect|route)' \
  | grep -v '\.test\.' \
  | head -10
```

If any result appears: set `auth_risk: true`.

For Next.js projects (detected by `next.config.js` presence), also check:

```bash
[[ -f next.config.js ]] && \
  git diff HEAD~1 --name-only | grep -qE "middleware\.ts|_middleware" && \
  auth_risk=true
```

### Phase 6: Dispatch Decision

Evaluate results and set `decision`:

| Condition | Decision |
|-----------|----------|
| No unit tests and no consumer tests found | `write_new` |
| Tests exist but none cover changed functions | `write_new` |
| Tests exist and cover changed functions | `update_existing` |
| Both gaps and existing coverage | `both` |

**For `write_new` or `both`:**
→ Invoke `test-driven-development` skill for each uncovered function. Follow RED-GREEN-REFACTOR.

**For `update_existing`:**
1. Read the existing test file
2. Locate the `describe` block for the changed function
3. Add a new `it()` / `test()` case — write the failing assertion first (RED), verify it fails, then implement (GREEN)

**If `auth_risk: true` (any decision):**
Before feature tests, add a test asserting the endpoint/page returns 401/403 for unauthenticated requests.

## Structured Output

After all phases complete, emit `tests_checked`:

```yaml
tests_checked:
  source_file: "src/services/UserService.ts"
  unit_tests:
    - "src/services/__tests__/UserService.test.ts"
  consumer_tests:
    - "src/components/__tests__/UserCard.test.tsx"
  e2e_specs:
    - "e2e/user-profile.spec.ts"
  e2e_specs_primary:
    - "e2e/user-profile.spec.ts"     # promoted — tests getUserById
  auth_risk: false
  decision: "update_existing"        # write_new | update_existing | both
  notes: "Phase 0 used auto-detect (no context.md found)"
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Skipping Phase 0 layout read | Test paths vary by project; always read layout first |
| Using only Phase 1 co-located search | Phase 2 import filter catches consumer tests missed by path |
| Skipping Phase 3 mock filter | Mock-only tests verify mock behaviour; don't update them |
| Skipping Phase 4b on large diffs | Promotion ensures primary E2E specs are checked first |
| Writing new tests without Phase 5 | Auth regressions are silent; always check guard changes |
| Calling test-driven-development before Phase 6 | Decision determines whether to write new or update existing |
