#!/usr/bin/env python3
"""Convert Jira ADF (Atlassian Document Format) JSON to markdown.

Reads a Jira workitem JSON from stdin (as returned by acli --json),
outputs JSON { title, body, status } with body as markdown text.
"""

import json
import sys


def adf_to_md(node):
    """Recursively convert an ADF node to markdown."""
    if isinstance(node, str):
        return node
    if not isinstance(node, dict):
        return ""

    t = node.get("type", "")
    content = node.get("content", [])
    text = node.get("text", "")

    # Inline text with marks
    if t == "text":
        marks = [m["type"] for m in node.get("marks", [])]
        if "code" in marks:
            return "`" + text + "`"
        if "strong" in marks:
            return "**" + text + "**"
        if "em" in marks:
            return "*" + text + "*"
        return text

    # Block nodes
    hashes = {1: "#", 2: "##", 3: "###", 4: "####", 5: "#####", 6: "######"}
    if t == "doc":
        return "\n".join(adf_to_md(c) for c in content)
    if t == "heading":
        level = node.get("attrs", {}).get("level", 2)
        prefix = hashes.get(level, "##")
        inline = "".join(adf_to_md(c) for c in content)
        return prefix + " " + inline
    if t == "paragraph":
        return "".join(adf_to_md(c) for c in content)
    if t == "bulletList":
        items = []
        for item in content:
            item_text = "\n".join(adf_to_md(c) for c in item.get("content", []))
            items.append("- " + item_text)
        return "\n".join(items)
    if t == "orderedList":
        items = []
        for i, item in enumerate(content, 1):
            item_text = "\n".join(adf_to_md(c) for c in item.get("content", []))
            items.append(str(i) + ". " + item_text)
        return "\n".join(items)
    if t == "listItem":
        return "\n".join(adf_to_md(c) for c in content)
    if t == "codeBlock":
        lang = node.get("attrs", {}).get("language", "")
        code = "".join(adf_to_md(c) for c in content)
        return "```" + lang + "\n" + code + "\n```"

    # Fallback: recurse into content
    return "".join(adf_to_md(c) for c in content)


def main():
    data = json.load(sys.stdin)
    fields = data.get("fields", {})
    desc = fields.get("description", "")

    if isinstance(desc, dict):
        body = adf_to_md(desc)
    elif isinstance(desc, str):
        body = desc
    else:
        body = ""

    result = {
        "title": fields.get("summary", ""),
        "body": body,
        "status": fields.get("status", {}).get("name", ""),
    }
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
