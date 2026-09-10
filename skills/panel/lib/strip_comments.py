#!/usr/bin/env python3
"""Strip properly-closed HTML comments from a charter file.

Contract (see tests/test-panel-fixes.sh):
  * Only PROPERLY CLOSED ``<!-- ... -->`` spans are removed.
  * An unclosed/malformed ``<!--`` is left intact, so a ``<<FILL`` marker hiding
    behind it is still visible to the validator: malformed input must never
    become a validation bypass (fail closed).
  * Comments may span multiple lines.
  * Text before/after a comment on the same line is preserved.
  * Multiple comments per file/line are handled.

Usage: strip_comments.py <file>   -> stripped text on stdout
"""
import re
import sys

# Non-greedy, DOTALL: matches only complete <!-- ... --> spans. An unterminated
# "<!--" has no match and is therefore preserved verbatim.
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


def strip_comments(text: str) -> str:
    return COMMENT.sub("", text)


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: strip_comments.py <file>\n")
        return 2
    try:
        with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        sys.stderr.write(f"strip_comments.py: {exc}\n")
        return 2
    sys.stdout.write(strip_comments(text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
