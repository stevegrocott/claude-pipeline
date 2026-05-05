---
name: mcp-tools
description: Use when you need framework documentation, structured code navigation, or are unsure which exploration tool to use. Reference for available MCP tools and when to prefer each.
inputs:
  - name: query
    type: string
    required: true
    description: What you are looking for — framework docs, code structure, or a text/file pattern
  - name: library_name
    type: string
    required: false
    description: Library or framework name when resolving documentation via Context7
outputs:
  - name: documentation
    type: string
    description: Framework API reference or usage patterns retrieved from Context7
  - name: code_structure
    type: string
    description: Class hierarchy, method signatures, or call graph from Serena
  - name: search_results
    type: string
    description: Matching file paths or text lines from Grep or Glob
side_effects: []
composes: []
failure_modes:
  - id: tool_not_found
    mitigation: Fall back to the next option in the decision matrix (Context7 → web search; Serena → Grep + manual reading); note the unavailability in output
  - id: library_not_in_context7
    mitigation: If context7.resolve_library_id returns no match, fall back to web search for the library's documentation
---

# MCP Tools Reference

## When to Use This Skill

Before exploring a codebase or looking up framework documentation, check which MCP tools are available and use the most efficient one.

## Available Tools

### Context7 — Framework & Library Documentation

**Use when:** You need API docs, usage patterns, or configuration reference for a framework or library.

**Workflow:**
1. `context7.resolve_library_id` — find the library by name
2. `context7.get_library_docs` — retrieve relevant documentation

**Prefer over web search** for framework APIs. Faster, more targeted, fewer tokens.

### Serena — Structured Code Navigation

**Use when:** You need to understand code structure — class hierarchies, method signatures, call graphs, file relationships.

**Prefer over Grep/Glob** when you need structural understanding, not just text matching.

### Grep / Glob — Text Search & File Discovery

**Use when:** You need to find text patterns across files or discover files by name/path.

## Decision Matrix

| Need | First choice | Fallback |
|---|---|---|
| Framework/library API docs | Context7 | Web search |
| Library usage patterns | Context7 | Web search |
| Class/method/call structure | Serena | Grep + manual reading |
| Text search across files | Grep | — |
| File discovery by name/path | Glob | — |
| Current events / release notes | Web search | — |

## Critical: Fully Qualified Tool Names

Always use the MCP server prefix to avoid "tool not found" errors:

- `context7.resolve_library_id` — not `resolve_library_id`
- `context7.get_library_docs` — not `get_library_docs`

## When Tools Are Not Available

If a tool call fails with "tool not found", fall back to the next option in the decision matrix. Do not retry the same tool. Note in your output that the MCP tool was unavailable.
