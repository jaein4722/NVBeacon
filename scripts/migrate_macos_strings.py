#!/usr/bin/env python3
"""One-time migration: move the macOS app's inline `text(en, ko, zh)` / `t(en, ko, zh)`
strings into Shared/Localization and replace each call with a key lookup.

    python3 scripts/migrate_macos_strings.py            # report only
    python3 scripts/migrate_macos_strings.py --write    # rewrite sources and JSON

Interpolations become `%@` placeholders, passed as arguments in English order;
a translation that orders them differently gets positional `%1$@` placeholders.
Strings whose English is the same but whose translations differ are reported, and
`CONTEXTS` assigns them context-qualified keys.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "NVBeacon"
LOCALIZATION = ROOT / "Shared" / "Localization"

# (file name, English) → context, for English text with two meanings.
CONTEXTS = {
    ("GPUHistoryView.swift", "Unavailable"): "measurement",  # 측정 불가: no value, not "cannot be used"
    ("GPUModels.swift", "Enabled"): "status",  # notification permission state; the toggle label is "Enabled"
    ("SettingsView.swift", "New Server"): "action",  # the button; "New Server" alone is the default name
}

# Same English and meaning, but the call sites had drifted: the text to keep.
UNIFY = {
    ("Idle %@s · <=%@MB", "ko"): "유휴 %@초 · %@MB 이하",
    ("%@s", "ko"): "%@초",
}

CALL = re.compile(r"(?<![\w.])t\(|\.text\(")


def parse_literal(src, i):
    """Parse a Swift string literal starting at src[i] == '"'.
    Returns (segments, end) with segments [('text', str) | ('expr', source)]."""
    assert src[i] == '"'
    if src.startswith('"""', i):
        raise ValueError("multi-line literal")
    i += 1
    segments, text = [], []
    escapes = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
    while True:
        c = src[i]
        if c == '"':
            break
        if c == "\n":
            raise ValueError("unterminated literal")
        if c == "\\":
            n = src[i + 1]
            if n == "(":
                if text:
                    segments.append(("text", "".join(text)))
                    text = []
                start = i + 2
                end = skip_balanced(src, start)
                segments.append(("expr", src[start:end]))
                i = end + 1
                continue
            if n == "u":
                m = re.match(r"\\u\{([0-9a-fA-F]+)\}", src[i:])
                text.append(chr(int(m.group(1), 16)))
                i += len(m.group(0))
                continue
            text.append(escapes[n])
            i += 2
            continue
        text.append(c)
        i += 1
    if text:
        segments.append(("text", "".join(text)))
    return segments, i + 1


def skip_balanced(src, i):
    """Index of the ')' closing an interpolation whose body starts at i."""
    depth = 0
    while True:
        c = src[i]
        if c == '"':
            _, i = parse_literal(src, i)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                return i
            depth -= 1
        i += 1


def skip_space(src, i):
    while src[i] in " \t\n":
        i += 1
    return i


def parse_call(src, open_paren):
    """Parse `( "a", "b", "c" )`. Returns (literals, end) or None if an argument is not a literal."""
    i = skip_space(src, open_paren + 1)
    literals = []
    while True:
        if src[i] != '"':
            return None
        segments, i = parse_literal(src, i)
        literals.append(segments)
        i = skip_space(src, i)
        if src[i] == ",":
            i = skip_space(src, i + 1)
            continue
        if src[i] == ")":
            return literals, i + 1
        return None


def exprs(segments):
    return [s for kind, s in segments if kind == "expr"]


def template(segments, order=None, positional=False):
    """Build the stored text. order maps the n-th expression to its English argument number."""
    has_args = any(kind == "expr" for kind, _ in segments)
    out, n = [], 0
    for kind, value in segments:
        if kind == "text":
            out.append(value.replace("%", "%%") if has_args else value)
        else:
            number = order[n] if order else n + 1
            out.append(f"%{number}$@" if positional else "%@")
            n += 1
    return "".join(out)


def argument_order(english, translated):
    """English argument number for each expression of a translation, in its order."""
    remaining = list(enumerate(english, start=1))
    order = []
    for expr in translated:
        match = next((pair for pair in remaining if pair[1] == expr), None)
        if match is None:
            raise ValueError(f"interpolation {expr!r} is not in the English text")
        remaining.remove(match)
        order.append(match[0])
    if remaining:
        raise ValueError(f"interpolations {[e for _, e in remaining]!r} are missing from a translation")
    return order


def swift_literal(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return f'"{escaped}"'


def main():
    write = "--write" in sys.argv
    entries = {}  # key → {"ko": {text: [sites]}, "zh-Hans": {...}}
    skipped, errors = [], []
    rewritten = {}
    for path in sorted(SOURCES.glob("*.swift")):
        src = path.read_text()
        out, last = [], 0
        for m in CALL.finditer(src):
            open_paren = m.end() - 1
            line = src.count("\n", 0, m.start()) + 1
            site = f"{path.name}:{line}"
            if src[max(0, m.start() - 5):m.start() + 1].endswith("func t") or src[max(0, m.start() - 10):m.start()].endswith("func"):
                continue
            if m.start() < last:
                continue
            try:
                parsed = parse_call(src, open_paren)
            except (ValueError, IndexError, KeyError) as error:
                errors.append(f"{site}: {error}")
                continue
            if parsed is None:
                skipped.append(f"{site}: {src[m.start():src.find(chr(10), m.start())].strip()}")
                continue
            literals, end = parsed
            if len(literals) != 3:
                skipped.append(f"{site}: {len(literals)} literals")
                continue
            english, korean, chinese = literals
            english_exprs = exprs(english)
            try:
                translations = {}
                for code, segments in (("ko", korean), ("zh-Hans", chinese)):
                    order = argument_order(english_exprs, exprs(segments))
                    reordered = order != sorted(order)
                    translations[code] = template(segments, order, positional=reordered)
            except ValueError as error:
                errors.append(f"{site}: {error}")
                continue
            english_text = template(english)
            context = CONTEXTS.get((path.name, english_text))
            if context and path.name == "SettingsView.swift" and english_text == "New Server" and "Button(" not in src[m.start() - 12:m.start()]:
                context = None
            key = f"{context}::{english_text}" if context else english_text
            entry = entries.setdefault(key, {"en": english_text, "ko": {}, "zh-Hans": {}})
            for code, text in translations.items():
                text = UNIFY.get((key, code), text)
                entry[code].setdefault(text, []).append(site)
            arguments = "".join(f", {e}" for e in english_exprs)
            out.append(src[last:open_paren])
            out.append(f"({swift_literal(key)}{arguments})")
            last = end
        out.append(src[last:])
        rewritten[path] = "".join(out)

    conflicts = {k: v for k, v in entries.items() if len(v["ko"]) > 1 or len(v["zh-Hans"]) > 1}
    print(f"{len(entries)} keys, {sum(len(s) for e in entries.values() for s in e['ko'].values())} call sites")
    for item in skipped:
        print("skipped", item)
    for item in errors:
        print("error", item)
    for key, value in conflicts.items():
        print(f"conflict {key!r}")
        for code in ("ko", "zh-Hans"):
            if len(value[code]) > 1:
                for text, sites in value[code].items():
                    print(f"    {code} {text!r}: {', '.join(sites)}")
    if errors or conflicts or not write:
        return 1 if (errors or conflicts) else 0

    LOCALIZATION.mkdir(parents=True, exist_ok=True)
    names = {"en": "English", "ko": "한국어", "zh-Hans": "简体中文"}
    for code in ("en", "ko", "zh-Hans"):
        path = LOCALIZATION / f"{code}.json"
        existing = json.loads(path.read_text())["strings"] if path.exists() else {}
        for key, value in entries.items():
            existing[key] = value["en"] if code == "en" else next(iter(value[code]))
        write_json(path, names[code], existing)
    for path, text in rewritten.items():
        path.write_text(text)
    return 0


def write_json(path, name, strings):
    data = {"name": name, "strings": dict(sorted(strings.items()))}
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
