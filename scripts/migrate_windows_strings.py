#!/usr/bin/env python3
"""One-time migration: move the Windows pages' `t(english, korean)` strings into
Shared/Localization and replace each call with `t(key, ...arguments)`.

    python3 scripts/migrate_windows_strings.py            # report only
    python3 scripts/migrate_windows_strings.py --write    # rewrite pages and JSON

Concatenated values ("Idle " + seconds + " s") become `%@` placeholders. A key the
macOS app already has keeps the macOS text when the Korean matches; when the Windows
Korean differs it gets a `windows::` key, so this step changes no visible text.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGES = ROOT / "Windows" / "Sources" / "NVBeacon" / "UI"
LOCALIZATION = ROOT / "Shared" / "Localization"
CALL = re.compile(r"(?<![\w.$])t\(")
# English with two meanings on Windows: site → context.
SITE_CONTEXTS = {
    "settings.js:439": "watch",  # 해제 (stop watching); elsewhere Remove is 삭제
    "history.js:203": "measurement",  # 측정 불가, as in the macOS GPU History window
}
HISTORY = re.compile(r'^(  \w+: )\["([^"]*)", "([^"]*)"\],$', re.M)


def parse_string(src, i):
    quote = src[i]
    i += 1
    out = []
    escapes = {"n": "\n", "t": "\t", '"': '"', "'": "'", "\\": "\\", "`": "`"}
    while src[i] != quote:
        c = src[i]
        if c == "\\":
            n = src[i + 1]
            if n == "u":
                out.append(chr(int(src[i + 2:i + 6], 16)))
                i += 6
                continue
            out.append(escapes[n])
            i += 2
            continue
        if quote == "`" and src.startswith("${", i):
            raise ValueError("template literal with substitution")
        out.append(c)
        i += 1
    return "".join(out), i + 1


def skip_space(src, i):
    while src[i] in " \t\n":
        i += 1
    return i


def parse_expression(src, i):
    """Read one top-level term up to `+`, `,` or the closing `)`. Returns (text, end)."""
    start, depth = i, 0
    while True:
        c = src[i]
        if c in "\"'`":
            _, i = parse_string(src, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and c in "+,":
            break
        elif depth == 0 and c == "?":
            raise ValueError("conditional inside an argument")
        i += 1
    return src[start:i].strip(), i


def parse_argument(src, i):
    """An argument as segments: [('text', value) | ('expr', source)]."""
    segments = []
    while True:
        i = skip_space(src, i)
        if src[i] in "\"'`":
            value, i = parse_string(src, i)
            segments.append(("text", value))
        else:
            text, i = parse_expression(src, i)
            segments.append(("expr", text))
        i = skip_space(src, i)
        if src[i] == "+":
            i += 1
            continue
        break
    if len(segments) > 1 and segments[0][0] == "expr" and segments[1][0] == "expr":
        raise ValueError("starts with two values: numeric addition?")
    return segments, i


def parse_call(src, open_paren):
    i = open_paren + 1
    arguments = []
    while True:
        segments, i = parse_argument(src, i)
        arguments.append(segments)
        if src[i] == ",":
            i += 1
            continue
        if src[i] == ")":
            return arguments, i + 1
        raise ValueError(f"unexpected {src[i]!r}")


def template(segments, order=None):
    has_args = any(kind == "expr" for kind, _ in segments)
    out, n = [], 0
    for kind, value in segments:
        if kind == "text":
            out.append(value.replace("%", "%%") if has_args else value)
        else:
            out.append(f"%{order[n]}$@" if order else "%@")
            n += 1
    return "".join(out)


def normalized(expr):
    return re.sub(r"\s+", "", expr)


def main():
    write = "--write" in sys.argv
    tables = {code: json.loads((LOCALIZATION / f"{code}.json").read_text()) for code in ("en", "ko")}
    english, korean = tables["en"]["strings"], tables["ko"]["strings"]
    found = {}  # key → {korean: [sites]}
    errors, rewritten = [], {}
    for path in sorted(PAGES.glob("*.js")):
        src = path.read_text()
        # Notification history titles: a table of [English, Korean] pairs, looked up by kind.
        if "const HISTORY_TITLES" in src:
            for m in HISTORY.finditer(src):
                key = m.group(2)
                if key in korean and korean[key] != m.group(3):
                    key = f"windows::{key}"
                found.setdefault(key, {}).setdefault(m.group(3), []).append(f"{path.name} HISTORY_TITLES")
            src = HISTORY.sub(lambda m: m.group(1) + json.dumps(m.group(2)) + ",", src)
            src = src.replace("t(...(HISTORY_TITLES[entry.kind] || [entry.kind, entry.kind]))", "t(HISTORY_TITLES[entry.kind] || entry.kind)")
        out, last = [], 0
        for m in CALL.finditer(src):
            if m.start() < last:
                continue
            site = f"{path.name}:{src.count(chr(10), 0, m.start()) + 1}"
            if src[max(0, m.start() - 6):m.start()] == "const " or src.startswith("t(HISTORY_TITLES", m.start()):
                continue
            try:
                arguments, end = parse_call(src, m.end() - 1)
                if len(arguments) != 2:
                    raise ValueError(f"{len(arguments)} arguments")
                en_segments, ko_segments = arguments
                en_exprs = [normalized(s) for k, s in en_segments if k == "expr"]
                ko_exprs = [normalized(s) for k, s in ko_segments if k == "expr"]
                if sorted(en_exprs) != sorted(ko_exprs):
                    raise ValueError(f"values differ: {en_exprs} / {ko_exprs}")
                remaining = list(enumerate(en_exprs, start=1))
                order = []
                for expr in ko_exprs:
                    pair = next(p for p in remaining if p[1] == expr)
                    remaining.remove(pair)
                    order.append(pair[0])
                en_text = template(en_segments)
                ko_text = template(ko_segments, order if order != sorted(order) else None)
            except (ValueError, IndexError, KeyError) as error:
                errors.append(f"{site}: {error}: {src[m.start():src.find(chr(10), m.start())].strip()}")
                continue
            key = en_text
            if site in SITE_CONTEXTS:
                key = f"{SITE_CONTEXTS[site]}::{en_text}"
            if key in korean and korean[key] != ko_text:
                key = f"windows::{en_text}"
            found.setdefault(key, {}).setdefault(ko_text, []).append(site)
            values = [s for k, s in en_segments if k == "expr"]
            out.append(src[last:m.start()])
            out.append("t(" + json.dumps(key, ensure_ascii=False) + "".join(f", {v}" for v in values) + ")")
            last = end
        out.append(src[last:])
        rewritten[path] = "".join(out)

    conflicts = {k: v for k, v in found.items() if len(v) > 1}
    shared = [k for k in found if k in english and not k.startswith("windows::")]
    contexts = [k for k in found if k.startswith("windows::")]
    print(f"{len(found)} keys: {len(shared)} shared with macOS, {len(contexts)} with different Korean, "
          f"{len(found) - len(shared) - len(contexts)} new")
    for item in errors:
        print("error", item)
    for key, value in conflicts.items():
        print(f"conflict {key!r}")
        for text, sites in value.items():
            print(f"    {text!r}: {', '.join(sites)}")
    if "--list" in sys.argv:
        for key in contexts:
            print(f"differs {key[9:]!r}: macOS {korean[key[9:]]!r}, Windows {next(iter(found[key]))!r}")
    if errors or conflicts or not write:
        return 1 if (errors or conflicts) else 0

    for key, value in found.items():
        english.setdefault(key, key.split("::")[-1])
        korean.setdefault(key, next(iter(value)))
    for code, data in tables.items():
        data["strings"] = dict(sorted(data["strings"].items()))
        (LOCALIZATION / f"{code}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    for path, text in rewritten.items():
        path.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())


# ---------- Windows Swift: `korean ? "…" : "…"` ----------

SWIFT_SOURCES = [ROOT / "Windows" / "Sources" / "NVBeacon", ROOT / "Windows" / "Sources" / "NVBeaconWindowsKit"]
TERNARY = re.compile(r'(\bkorean|Theme\.language == "ko") \? "')


def migrate_swift(write):
    sys.path.insert(0, str(ROOT / "scripts"))
    from migrate_macos_strings import parse_literal, skip_space, template as swift_template, swift_literal

    tables = {code: json.loads((LOCALIZATION / f"{code}.json").read_text()) for code in ("en", "ko")}
    english, korean = tables["en"]["strings"], tables["ko"]["strings"]
    found, errors, rewritten = {}, [], {}
    for folder in SWIFT_SOURCES:
        for path in sorted(folder.glob("*.swift")):
            src = path.read_text()
            out, last = [], 0
            for m in TERNARY.finditer(src):
                site = f"{path.name}:{src.count(chr(10), 0, m.start()) + 1}"
                try:
                    ko_segments, i = parse_literal(src, m.end() - 1)
                    i = skip_space(src, i)
                    if src[i] != ":":
                        raise ValueError("no ':' after the Korean text")
                    i = skip_space(src, i + 1)
                    if src[i] != '"':
                        raise ValueError("English is not a literal")
                    en_segments, end = parse_literal(src, i)
                    en_exprs = [s for k, s in en_segments if k == "expr"]
                    ko_exprs = [s for k, s in ko_segments if k == "expr"]
                    if sorted(en_exprs) != sorted(ko_exprs):
                        raise ValueError("values differ")
                    remaining = list(enumerate(en_exprs, start=1))
                    order = []
                    for expr in ko_exprs:
                        pair = next(p for p in remaining if p[1] == expr)
                        remaining.remove(pair)
                        order.append(pair[0])
                except (ValueError, IndexError, StopIteration) as error:
                    errors.append(f"{site}: {error}")
                    continue
                en_text = swift_template(en_segments)
                ko_text = swift_template(ko_segments, order, positional=order != sorted(order))
                key = en_text
                if key in korean and korean[key] != ko_text:
                    key = f"windows::{en_text}"
                found.setdefault(key, {}).setdefault(ko_text, []).append(site)
                receiver = "language" if m.group(1) == "korean" else "Theme.interface"
                out.append(src[last:m.start()])
                out.append(f"{receiver}.text({swift_literal(key)}{''.join(', ' + e for e in en_exprs)})")
                last = end
            out.append(src[last:])
            rewritten[path] = "".join(out)
    conflicts = {k: v for k, v in found.items() if len(v) > 1}
    print(f"Swift: {len(found)} keys, {sum(k.startswith('windows::') for k in found)} with different Korean")
    for item in errors:
        print("error", item)
    for key, value in conflicts.items():
        print(f"conflict {key!r}: {value}")
    if "--list" in sys.argv:
        for key in found:
            if key.startswith("windows::"):
                print(f"differs {key[9:]!r}: macOS {korean[key[9:]]!r}, Windows {next(iter(found[key]))!r}")
    if errors or conflicts or not write:
        return
    for key, value in found.items():
        english.setdefault(key, key.split("::")[-1])
        korean.setdefault(key, next(iter(value)))
    for code, data in tables.items():
        data["strings"] = dict(sorted(data["strings"].items()))
        (LOCALIZATION / f"{code}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    for path, text in rewritten.items():
        path.write_text(text)
