#!/usr/bin/env python3
"""Checks the translated .strings tables in purge/*.lproj.

Fails on anything that would break at runtime: a table that doesn't parse, a
key listed twice, or a translation whose format placeholders (%@, %lld, …)
differ from the English key. Safety explanations from explanations.json with
no translation are reported as warnings only: the app falls back to English
for those, which is safe, so a new explanation never has to wait on a
translator to land.

Usage: python3 scripts/check-localization.py
"""
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "purge"
EXPLANATIONS = APP / "Resources" / "explanations.json"
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?[-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|h|l|z|t|j)?([@diuoxXfFeEgGcsp])")
ESCAPES = {'"': '"', "\\": "\\", "n": "\n", "t": "\t", "r": "\r", "'": "'"}


class StringsError(Exception):
    pass


def parse_strings(text):
    """Returns [(key, value, line)] for an Apple .strings file."""
    entries, i, n = [], 0, len(text)

    def skip_blank(i):
        while i < n:
            if text[i].isspace():
                i += 1
            elif text.startswith("/*", i):
                end = text.find("*/", i + 2)
                if end < 0:
                    raise StringsError(f"line {text.count(chr(10), 0, i) + 1}: unterminated comment")
                i = end + 2
            elif text.startswith("//", i):
                end = text.find("\n", i)
                i = n if end < 0 else end + 1
            else:
                break
        return i

    def read_quoted(i):
        line = text.count("\n", 0, i) + 1
        if i >= n or text[i] != '"':
            raise StringsError(f"line {line}: expected a quoted string")
        out, i = [], i + 1
        while i < n:
            c = text[i]
            if c == '"':
                return "".join(out), i + 1
            if c == "\\":
                nxt = text[i + 1] if i + 1 < n else ""
                if nxt in ESCAPES:
                    out.append(ESCAPES[nxt])
                    i += 2
                elif nxt in "uU" and re.fullmatch(r"[0-9a-fA-F]{4}", text[i + 2:i + 6]):
                    out.append(chr(int(text[i + 2:i + 6], 16)))
                    i += 6
                else:
                    raise StringsError(f"line {line}: unknown escape \\{nxt}")
            else:
                out.append(c)
                i += 1
        raise StringsError(f"line {line}: unterminated string")

    while True:
        i = skip_blank(i)
        if i >= n:
            return entries
        line = text.count("\n", 0, i) + 1
        key, i = read_quoted(i)
        i = skip_blank(i)
        if i >= n or text[i] != "=":
            raise StringsError(f"line {line}: expected '=' after {key!r}")
        value, i = read_quoted(skip_blank(i + 1))
        i = skip_blank(i)
        if i >= n or text[i] != ";":
            raise StringsError(f"line {line}: expected ';' after the value for {key!r}")
        entries.append((key, value, line))
        i += 1


def placeholders(s):
    """Placeholder conversions in argument order, so a translation may reorder
    them with positional specifiers (%2$@ %1$@) and still compare equal."""
    found, auto = [], 0
    for match in PLACEHOLDER.finditer(s.replace("%%", "")):
        position, conversion = match.group(1), match.group(2)
        if position:
            index = int(position)
        else:
            auto += 1
            index = auto
        found.append((index, "@" if conversion == "@" else "s" if conversion == "s" else "n"))
    return sorted(found)


def main():
    errors, warnings = [], []
    tables = {}
    for path in sorted(APP.glob("*.lproj/*.strings")):
        rel = path.relative_to(ROOT)
        try:
            entries = parse_strings(path.read_text(encoding="utf-8"))
        except (StringsError, UnicodeDecodeError) as error:
            errors.append(f"{rel}: {error}")
            continue
        seen = {}
        for key, value, line in entries:
            if key in seen:
                errors.append(f"{rel}:{line}: duplicate key (first on line {seen[key]}): {key!r}")
            seen[key] = line
            if placeholders(key) != placeholders(value):
                errors.append(f"{rel}:{line}: placeholders differ from the English key: {key!r}")
            if not value.strip() and key.strip():
                errors.append(f"{rel}:{line}: empty translation for {key!r}")
        tables[path] = {key for key, _, _ in entries}
        print(f"{rel}: {len(entries)} entries")

    records = json.loads(EXPLANATIONS.read_text(encoding="utf-8"))
    wanted = {r[field] for r in records for field in ("display_name", "explanation") if r.get(field)}
    for lproj in sorted(APP.glob("*.lproj")):
        table = lproj / "Explanations.strings"
        if not table.exists():
            continue
        missing = sorted(wanted - tables.get(table, set()))
        for text in missing:
            warnings.append(f"{table.relative_to(ROOT)}: no translation yet, shows in English: {text[:80]!r}")

    for warning in warnings:
        print(f"::warning::{warning}" if "GITHUB_ACTIONS" in os.environ else f"warning: {warning}")
    for error in errors:
        print(f"::error::{error}" if "GITHUB_ACTIONS" in os.environ else f"error: {error}")
    if errors:
        sys.exit(1)
    print("Localization check passed" + (f" with {len(warnings)} warning(s)" if warnings else ""))


if __name__ == "__main__":
    main()
