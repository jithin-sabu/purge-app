#!/usr/bin/env python3
"""Checks the translated .strings tables in purge/*.lproj.

Fails on anything that would break at runtime: a table that doesn't parse, a
key listed twice, or a translation whose format placeholders (%@, %lld, …)
differ from the English key. Safety explanations from explanations.json with
no translation are reported as warnings only: the app falls back to English
for those, which is safe, so a new explanation never has to wait on a
translator to land.

It also reads every Swift file under purge/ and fails when a literal the app
localizes has no entry in a translated Localizable.strings (#187). That covers
String(localized:), Text, Button, Label and the other SwiftUI initializers and
modifiers that take a LocalizedStringKey, given a string literal or a ternary
of two. Interpolations match any placeholder, since the check can't see their
types. Text built from a variable, or a literal passed as a plain String, is
not localized at all, and this check can't see it either: pass
String(localized:) in those places.

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
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?[-+#0 ]*\d*(?:\.\d+)?(hh|ll|h|l|q|z|t|j|L)?([@diuoxXfFeEgGcsp])")
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


# Conversions that read the same kind of argument. A translation may swap %d
# for %i, but not %d for %f or %lld for %d: those read a different type or
# size, and the formatted value comes out wrong.
CONVERSION_CLASS = {c: "d" for c in "di"} | {c: "u" for c in "uoxX"} | {c: "f" for c in "fFeEgG"}


def placeholders(s):
    """Placeholder types in argument order, so a translation may reorder them
    with positional specifiers (%2$@ %1$@) and still compare equal."""
    found, auto = [], 0
    for match in PLACEHOLDER.finditer(s.replace("%%", "")):
        position, length, conversion = match.group(1), match.group(2) or "", match.group(3)
        if position:
            index = int(position)
        else:
            auto += 1
            index = auto
        found.append((index, length + CONVERSION_CLASS.get(conversion, conversion)))
    return sorted(found)


# A string literal right after one of these is a localization key, and so is
# each side of `cond ? "a" : "b"` there. They are the calls the app uses that
# take a LocalizedStringKey, String.LocalizationValue or LocalizedStringResource.
# Text("a" + b), Text(cond ? "a" : b) and the like are plain Strings, and
# `source_keys` skips them. The condition holds no comma or colon, so a ternary
# in a later argument, such as `systemImage:`, is never read as a key.
LOCALIZED_LITERAL = re.compile(
    r"(?:(?<![\w.])(?:String\(localized:|NSLocalizedString\(|LocalizedStringKey\(|LocalizedStringResource\("
    r"|IntentDescription\(|Text\(|Button\(|Label\(|Toggle\(|Picker\(|Menu\(|Section\(|Link\(|TextField\("
    r"|SecureField\(|LabeledContent\(|GroupBox\(|DisclosureGroup\(|ProgressView\(|CommandMenu\(|Window\("
    r"|WindowGroup\(|MenuBarExtra\()"
    r"|\.(?:help|accessibilityLabel|accessibilityHint|accessibilityValue|navigationTitle|alert"
    r"|confirmationDialog|badge)\("
    r"|:\s*LocalizedStringResource\s*=)"
    r"\s*(?P<ternary>[^\"()\n?,:]*\?\s*)?(?=\")"
)
TERNARY_ELSE = re.compile(r'\s*:\s*(?=")')
TABLE_ARGUMENT = re.compile(r'\s*,\s*table:\s*"(\w+)"')
# A complete string literal on one line, so a `//` inside one isn't read as a comment.
ONE_LINE_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')
# Stands in for each interpolation in a source key and each placeholder in a
# table key, so "\(size) free" matches "%@ free".
INTERPOLATION = "\x00"
SWIFT_ESCAPES = {"0": "\0", "\\": "\\", "t": "\t", "n": "\n", "r": "\r", '"': '"', "'": "'"}


def skip_interpolation(text, i):
    """i is just past `\\(`. Returns the index just past its closing `)`."""
    depth = 1
    while i < len(text):
        c = text[i]
        if c == '"':
            i = read_swift_literal(text, i)[1]
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise StringsError("unterminated interpolation")


def literal_end(text, i, multiline):
    """Index of the closing quote of the literal whose content starts at i."""
    close = '"""' if multiline else '"'
    while i < len(text):
        if text.startswith(close, i):
            return i
        if text[i] == "\\":
            i = skip_interpolation(text, i + 2) if text.startswith("(", i + 1) else i + 2
        elif text[i] == "\n" and not multiline:
            break
        else:
            i += 1
    raise StringsError("unterminated string")


def decode_literal(body):
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        escape = body[i + 1]
        if escape == "(":
            out.append(INTERPOLATION)
            i = skip_interpolation(body, i + 2)
        elif escape == "\n":
            i += 2  # Line continuation in a multi-line literal.
        elif escape == "u":
            close = body.index("}", i)
            out.append(chr(int(body[i + 3:close], 16)))
            i = close + 1
        elif escape in SWIFT_ESCAPES:
            out.append(SWIFT_ESCAPES[escape])
            i += 2
        else:
            raise StringsError(f"unknown escape \\{escape}")
    return "".join(out)


def read_swift_literal(text, i):
    """Reads the Swift string literal starting at text[i]. Returns its text with
    each interpolation as INTERPOLATION, and the index just past it."""
    if text.startswith('"""', i):
        start = text.index("\n", i) + 1
        close = literal_end(text, start, multiline=True)
        lines = text[start:close].split("\n")
        indent = lines.pop()  # The closing delimiter's indentation is stripped from every line.
        body = "\n".join(line[len(indent):] if line.startswith(indent) else line.lstrip() for line in lines)
        return decode_literal(body), close + 3
    close = literal_end(text, i + 1, multiline=False)
    return decode_literal(text[i + 1:close]), close + 1


def source_keys():
    """Returns [(key, table, path, line)] for each localized literal in purge/."""
    found = []
    for path in sorted(APP.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in LOCALIZED_LITERAL.finditer(text):
            line_start = text.rfind("\n", 0, match.start()) + 1
            if "//" in ONE_LINE_LITERAL.sub('""', text[line_start:match.start()]):
                continue  # In a comment.
            line = text.count("\n", 0, match.start()) + 1
            try:
                key, end = read_swift_literal(text, match.end())
                keys = [key]
                if match.group("ternary") is not None:
                    other = TERNARY_ELSE.match(text, end)
                    if not other:
                        continue  # One side isn't a literal, so the whole is a String.
                    key, end = read_swift_literal(text, other.end())
                    keys.append(key)
            except (StringsError, ValueError, IndexError) as error:
                raise StringsError(f"{path.relative_to(ROOT)}:{line}: can't read the string literal: {error}")
            rest = text[end:].lstrip()
            if rest[:1] in ("+", "."):
                continue  # Part of a String expression, not a key on its own.
            table = TABLE_ARGUMENT.match(text, end)
            found += [(key, table.group(1) if table else "Localizable", path, line) for key in keys]
    return found


def match_form(key):
    """A table key with each placeholder as INTERPOLATION and %% as %."""
    return "%".join(PLACEHOLDER.sub(INTERPOLATION, part) for part in key.split("%%"))


def source_match_form(key):
    """The table key Swift looks up for a source literal, in match_form. A
    literal with no interpolation is the key as written, and may itself be a
    format for String(format:). One with interpolations escapes each % as %%."""
    if INTERPOLATION in key:
        key = "%%".join(part.replace(INTERPOLATION, "%@") for part in key.split("%"))
    return match_form(key)


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

    try:
        keys = source_keys()
    except StringsError as error:
        keys = []
        errors.append(str(error))
    print(f"purge/**/*.swift: {len(keys)} localized literals")
    for lproj in sorted(APP.glob("*.lproj")):
        if not (lproj / "Localizable.strings").exists():
            continue
        translated = {}
        for key, table, path, line in keys:
            if table not in translated:
                translated[table] = {match_form(k) for k in tables.get(lproj / f"{table}.strings", set())}
            # Text that is only placeholders and punctuation reads the same in every language.
            if source_match_form(key) in translated[table] or not any(c.isalpha() for c in key):
                continue
            shown = key.replace(INTERPOLATION, "\\(…)").replace("\n", "\\n")
            errors.append(f'{path.relative_to(ROOT)}:{line}: no {lproj.stem} text in {table}.strings for "{shown}"')

    for warning in warnings:
        print(f"::warning::{warning}" if "GITHUB_ACTIONS" in os.environ else f"warning: {warning}")
    for error in errors:
        print(f"::error::{error}" if "GITHUB_ACTIONS" in os.environ else f"error: {error}")
    if errors:
        sys.exit(1)
    print("Localization check passed" + (f" with {len(warnings)} warning(s)" if warnings else ""))


if __name__ == "__main__":
    main()
