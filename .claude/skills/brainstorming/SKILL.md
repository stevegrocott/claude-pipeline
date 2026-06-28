---
name: brainstorming
description: "You MUST use this before any creative work - creating features, building components, adding functionality, or modifying behavior. Explores user intent, requirements and design before implementation."
inputs:
  - name: idea
    type: string
    required: false
    description: The rough idea, feature request, or problem statement to refine into a validated design
outputs:
  - name: design_document
    type: file_path
    description: Validated design saved to docs/plans/YYYY-MM-DD-<topic>-design.md (standalone invocation only)
side_effects:
  - writes_file: "docs/plans/YYYY-MM-DD-<topic>-design.md"
  - commits_to_git
composes:
  - writing-plans
failure_modes:
  - id: premature_implementation
    mitigation: Do not write code or implementation plans until the design is fully explored and explicitly validated by the user
---

# Brainstorming Ideas Into Designs

## Overview

Help turn ideas into fully formed designs and specs through natural collaborative dialogue.

Start by understanding the current project context, then ask questions one at a time to refine the idea. Once you understand what you're building, present the design in small sections (200-300 words), checking after each section whether it looks right so far.

## The Process

**Understanding the idea:**
- Check out the current project state first (files, docs, recent commits)
- Ask questions one at a time to refine the idea
- Prefer multiple choice questions when possible, but open-ended is fine too
- Only one question per message - if a topic needs more exploration, break it into multiple questions
- Focus on understanding: purpose, constraints, success criteria

**Exploring approaches:**
- Propose 2-3 different approaches with trade-offs
- Present options conversationally with your recommendation and reasoning
- Lead with your recommended option and explain why

**Presenting the design:**
- Once you believe you understand what you're building, present the design
- Break it into sections of 200-300 words
- Ask after each section whether it looks right so far
- Cover: architecture, components, data flow, error handling, testing
- Be ready to go back and clarify if something doesn't make sense

## After the Design

**Documentation:**
- Standalone invocation: Write the validated design to `docs/plans/YYYY-MM-DD-<topic>-design.md` and commit to git
- Via `/explore`: Output is captured in the GitHub Issue body (no local file needed)
- Use elements-of-style:writing-clearly-and-concisely skill if available

**Implementation (if continuing):**
- Ask: "Ready to set up for implementation?"
- Create a feature branch from main
- Use writing-plans to create detailed implementation plan

## Key Principles

- **One question at a time** - Don't overwhelm with multiple questions
- **Multiple choice preferred** - Easier to answer than open-ended when possible
- **YAGNI ruthlessly** - Remove unnecessary features from all designs
- **Explore alternatives** - Always propose 2-3 approaches before settling
- **Incremental validation** - Present design in sections, validate each
- **Be flexible** - Go back and clarify when something doesn't make sense
