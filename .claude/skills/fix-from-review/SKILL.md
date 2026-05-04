---
name: fix-from-review
description: Use when applying code review feedback — reads specific file and line locations from review comments and applies targeted fixes
inputs:
  - name: review_feedback
    type: string
    required: true
    description: Code review comments containing file paths, line numbers, and descriptions of what to fix
outputs:
  - name: fixes_applied
    type: json
    description: Summary of each review item and the fix applied
  - name: commit_sha
    type: string
    description: SHA of the single commit containing all fixes
side_effects:
  - modifies_source_files
  - runs_lint_on_changed_files
  - creates_git_commit
failure_modes:
  - id: fix_requires_broad_context
    mitigation: For minor issues defer and note in the summary. For major issues read the minimum additional context needed.
  - id: review_item_ambiguous
    mitigation: Note the item as ambiguous in the summary. Do not guess at the file or line location.
---

# Fix From Review

Address code review feedback by making targeted fixes. Work from the review comments — do not explore.

## Rules

1. **The review feedback is provided in the prompt.** It contains file paths, line numbers, and descriptions of what to fix.
2. **For each issue: read only the specific file and line mentioned.** Do not read the whole file unless the fix requires understanding a function signature not visible in the immediate context.
3. **Do NOT explore the repository.** No `ls`, no `find`, no `glob`, no `grep` for patterns. The review tells you exactly where to look.
4. **Do NOT read files not mentioned in the review.** If the review says "fix line 42 of foo.php", read foo.php around line 42. Do not read bar.php "for context".
5. **Do NOT refactor or improve** code beyond what the review requested. Fix only what was flagged.
6. **Commit after all fixes are applied.** One commit, not one per fix.

## Process

```
1. Parse the review feedback — extract file, line, issue for each item
2. For each issue (in file order to minimize reads):
   a. Read the specific file section (±10 lines around the flagged line)
   b. Apply the fix
3. Run `php -l` (or equivalent lint) on each changed file
4. Commit all fixes with message: "fix: address PR review feedback"
5. Output summary of fixes applied
```

**Target: 2-4 turns maximum.** Turn 1: read review, read first file. Turn 2-3: apply fixes. Turn 4: commit.

## Severity Handling

- **major issues** — Must fix. These block merge.
- **minor issues** — Fix if trivial (< 2 lines changed). Skip if the fix would require reading additional files or understanding broader context — note as "deferred" in your summary.

## Anti-Patterns

| Temptation | Why it wastes time | Do instead |
|---|---|---|
| Read the full file to "understand context" | Review already provides context | Read only the flagged lines |
| Search for similar patterns elsewhere | Out of scope — review flagged specific locations | Fix only flagged locations |
| Refactor surrounding code | Scope creep — creates new review findings | Fix only what was flagged |
| Run the full test suite | Not your job — test stage handles this | Just lint the changed files |
| Read the issue description | You're fixing review feedback, not re-implementing | Work from the review comments |

## Why This Skill Exists

Without this skill, the fix agent reads the full codebase to "understand context" before making targeted fixes. On AGD-52, the fix stage cost $0.98 and took 9 minutes — Sonnet hit 26 turns exploring before Opus finished in 10 turns. The review feedback already contains everything needed: file, line, what's wrong.
