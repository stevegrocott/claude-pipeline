#!/usr/bin/env python3
"""Convert markdown text to Jira wiki markup.

Reads markdown from stdin, writes Jira wiki markup to stdout.
Handles the subset of markdown produced by the orchestrator's comment_issue().
"""

import re
import sys


def md_to_wiki(text):
    """Convert markdown to Jira wiki markup."""
    lines = text.split("\n")
    result = []
    in_code_block = False
    code_lang = ""

    for line in lines:
        # Code block fences
        m = re.match(r"^```(\w*)$", line)
        if m:
            if not in_code_block:
                code_lang = m.group(1)
                if code_lang:
                    result.append("{code:" + code_lang + "}")
                else:
                    result.append("{code}")
                in_code_block = True
            else:
                result.append("{code}")
                in_code_block = False
            continue

        # Inside code blocks, pass through unchanged
        if in_code_block:
            result.append(line)
            continue

        # Headings: ## Title -> h2. Title
        m = re.match(r"^(#{1,6})\s+(.*)", line)
        if m:
            level = len(m.group(1))
            result.append("h%d. %s" % (level, convert_inline(m.group(2))))
            continue

        # Unordered list items: - item -> * item
        m = re.match(r"^(\s*)- (.*)", line)
        if m:
            indent = m.group(1)
            # Nested depth: each 2 spaces = one extra *
            depth = len(indent) // 2 + 1
            result.append("*" * depth + " " + convert_inline(m.group(2)))
            continue

        # Ordered list items: 1. item -> # item
        m = re.match(r"^(\s*)\d+\.\s+(.*)", line)
        if m:
            indent = m.group(1)
            depth = len(indent) // 2 + 1
            result.append("#" * depth + " " + convert_inline(m.group(2)))
            continue

        # Regular lines
        result.append(convert_inline(line))

    return "\n".join(result)


def convert_inline(text):
    """Convert inline markdown formatting to wiki markup."""
    # Bold: **text** -> *text*
    text = re.sub(r"\*\*(.+?)\*\*", r"*\1*", text)
    # Italic: *text* -> _text_ (but not inside bold which is now *text*)
    # Handle _text_ style italic first (pass through as-is, already wiki format)
    # For *text* italic, we need to be careful not to conflict with bold
    # Since we already converted **bold** to *bold*, remaining single * pairs are italic
    # Actually, after bold conversion, single *text* IS the bold in wiki markup
    # So we need to handle italic differently - use _text_ in the orchestrator
    # For now, skip italic conversion to avoid conflicts with bold

    # Inline code: `text` -> {{text}}
    text = re.sub(r"`([^`]+)`", r"{{\1}}", text)

    # Links: [text](url) -> [text|url]
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"[\1|\2]", text)

    return text


def main():
    text = sys.stdin.read()
    sys.stdout.write(md_to_wiki(text))


if __name__ == "__main__":
    main()
