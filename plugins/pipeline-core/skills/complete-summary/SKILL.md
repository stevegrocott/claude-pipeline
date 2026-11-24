---
name: complete-summary
description: Generate the Changes section of a PR completion comment from the task list in the prompt — no header, footer, quality gates, or placeholders, and no file exploration
inputs:
  - name: issue_number
    type: string
    required: true
    description: GitHub issue number being closed by this PR
  - name: branch_name
    type: string
    required: true
    description: Feature branch name that was implemented
  - name: pr_number
    type: string
    required: true
    description: Pull request number to reference in the summary
outputs:
  - name: pr_comment
    type: string
    description: A `### Changes` heading followed by 1-5 bullets, one per completed task; the orchestrator adds the header, footer, and quality gates
side_effects: []
composes: []
failure_modes:
  - id: missing_context
    mitigation: if the prompt has no task list, output a single Changes bullet from the branch name; do not guess or explore
---

# Complete Summary

Write the **Changes section only** of the PR completion comment. The orchestrator posts the header, branch/PR lines, quality gates, and footer itself — you supply just the bullets describing what was implemented.

## Rules

1. **Do NOT read source files, run `git log`/`git diff`/`git show`, or explore the repository.** The work is done and reviewed.
2. **Use only the task list in the prompt** (each line: task id, status, description). Summarize the tasks with status `completed`; mention a `failed` task only as not completed.
3. **Do NOT write a header, footer, `---` rules, "Posted by" line, branch/PR lines, or a Quality Gates section.** Test and review outcomes are not yours to report.
4. **No placeholders.** Never emit `[...]` or "to fill in" text. Do not say the comment was not posted or that information is missing.
5. **Do NOT describe the comment** ("Generated the comment for PR...") — output the section itself.
6. **Keep it short:** 1-5 bullets, one line each.

## Output Format

```
### Changes
- <what the first task implemented>
- <what the second task implemented>
```

Output exactly this and nothing else.

## Process

```
1. Read the task list in the prompt
2. Write one bullet per completed task (merge trivial ones to stay within 5)
3. Output the `### Changes` heading and the bullets
```

**Target: 1-2 turns maximum.**
