#!/usr/bin/env python3
"""Convert markdown text to Atlassian Document Format (ADF) JSON.

Reads markdown from stdin, writes ADF JSON to stdout.
Handles the subset of markdown produced by the orchestrator's comment_issue().

ADF spec: https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/
"""

import json
import re
import sys


def text_node(text):
    """Create a plain text node."""
    return {"type": "text", "text": text}


def text_node_mark(text, mark_type):
    """Create a text node with a mark (bold, italic, code, etc.)."""
    return {"type": "text", "text": text, "marks": [{"type": mark_type}]}


def convert_inline_to_nodes(text):
    """Convert inline markdown to ADF inline nodes.

    Handles: **bold**, `code`, [text](url)
    Returns a list of ADF inline nodes.
    """
    nodes = []
    pos = 0

    # Pattern matches: **bold**, `code`, [text](url)
    pattern = re.compile(
        r"(\*\*(.+?)\*\*)"      # bold
        r"|(`([^`]+)`)"          # inline code
        r"|(\[([^\]]+)\]\(([^)]+)\))"  # link
    )

    for m in pattern.finditer(text):
        # Add any text before this match
        if m.start() > pos:
            nodes.append(text_node(text[pos:m.start()]))

        if m.group(2):  # bold
            nodes.append(text_node_mark(m.group(2), "strong"))
        elif m.group(4):  # inline code
            nodes.append(text_node_mark(m.group(4), "code"))
        elif m.group(6):  # link
            nodes.append({
                "type": "text",
                "text": m.group(6),
                "marks": [{"type": "link", "attrs": {"href": m.group(7)}}]
            })

        pos = m.end()

    # Add remaining text
    if pos < len(text):
        nodes.append(text_node(text[pos:]))

    # If nothing was parsed, return the whole string as text
    if not nodes and text:
        nodes.append(text_node(text))

    return nodes


def paragraph(text):
    """Create a paragraph node from markdown text."""
    if not text.strip():
        return None
    return {
        "type": "paragraph",
        "content": convert_inline_to_nodes(text)
    }


def heading(level, text):
    """Create a heading node."""
    return {
        "type": "heading",
        "attrs": {"level": level},
        "content": convert_inline_to_nodes(text)
    }


def bullet_list_item(text, depth=1):
    """Create a bullet list item node."""
    return {
        "type": "listItem",
        "content": [{
            "type": "paragraph",
            "content": convert_inline_to_nodes(text)
        }]
    }


def ordered_list_item(text):
    """Create an ordered list item node."""
    return {
        "type": "listItem",
        "content": [{
            "type": "paragraph",
            "content": convert_inline_to_nodes(text)
        }]
    }


def code_block(code_lines, language=""):
    """Create a code block node."""
    node = {
        "type": "codeBlock",
        "content": [text_node("\n".join(code_lines))]
    }
    if language:
        node["attrs"] = {"language": language}
    return node


def status_node(text, color="neutral"):
    """Create a status/lozenge node (for emoji status indicators)."""
    return {
        "type": "status",
        "attrs": {"text": text, "color": color}
    }


def md_to_adf(text):
    """Convert markdown text to ADF document."""
    lines = text.split("\n")
    content = []
    i = 0

    while i < len(lines):
        line = lines[i]

        # Code block fences
        m = re.match(r"^```(\w*)$", line)
        if m:
            lang = m.group(1)
            code_lines = []
            i += 1
            while i < len(lines) and not re.match(r"^```$", lines[i]):
                code_lines.append(lines[i])
                i += 1
            content.append(code_block(code_lines, lang))
            i += 1  # skip closing ```
            continue

        # Headings
        m = re.match(r"^(#{1,6})\s+(.*)", line)
        if m:
            level = len(m.group(1))
            content.append(heading(level, m.group(2)))
            i += 1
            continue

        # Horizontal rule
        if re.match(r"^---+$", line):
            content.append({"type": "rule"})
            i += 1
            continue

        # Unordered list — collect consecutive items
        m = re.match(r"^(\s*)- (.*)", line)
        if m:
            items = []
            while i < len(lines):
                m = re.match(r"^(\s*)- (.*)", lines[i])
                if not m:
                    break
                items.append(bullet_list_item(m.group(2)))
                i += 1
            content.append({
                "type": "bulletList",
                "content": items
            })
            continue

        # Ordered list — collect consecutive items
        m = re.match(r"^(\s*)\d+\.\s+(.*)", line)
        if m:
            items = []
            while i < len(lines):
                m = re.match(r"^(\s*)\d+\.\s+(.*)", lines[i])
                if not m:
                    break
                items.append(ordered_list_item(m.group(2)))
                i += 1
            content.append({
                "type": "orderedList",
                "content": items
            })
            continue

        # Checkbox items (- [ ] or - [x]) — treat as bullet list
        m = re.match(r"^- \[[ x]\] (.*)", line)
        if m:
            items = []
            while i < len(lines):
                m = re.match(r"^- \[([x ])\] (.*)", lines[i])
                if not m:
                    break
                checked = m.group(1) == "x"
                prefix = "\u2705 " if checked else "\u2B1C "
                items.append(bullet_list_item(prefix + m.group(2)))
                i += 1
            content.append({
                "type": "bulletList",
                "content": items
            })
            continue

        # Empty lines — skip
        if not line.strip():
            i += 1
            continue

        # Regular paragraph
        p = paragraph(line)
        if p:
            content.append(p)
        i += 1

    return {
        "version": 1,
        "type": "doc",
        "content": content
    }


def main():
    text = sys.stdin.read()
    adf = md_to_adf(text)
    json.dump(adf, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
