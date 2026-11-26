#!/usr/bin/env python3
"""Tools for the shared interface strings in Shared/Localization.

    python3 scripts/translations.py check   # keys, placeholders and unused strings
    python3 scripts/translations.py ios     # write Mobile/NVBeacon/<lang>.lproj/Localizable.strings
    python3 scripts/translations.py ios --check   # fail if those files are out of date

The format is described in Shared/NVBeaconCore/Sources/NVBeaconCore/Translations.swift
and docs/DEVELOPMENT.md.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCALIZATION = ROOT / "Shared" / "Localization"
IOS = ROOT / "Mobile" / "NVBeacon"
SOURCE = "en"
SEPARATOR = "::"
# Keys only the iPhone and iPad app uses carry this context when their text differs
# from the desktop text with the same English.
IOS_CONTEXT = "ios"

# Literal lookups in each client: (folder, file pattern, regex with the key in group 1).
SWIFT_LITERAL = r'"((?:[^"\\]|\\.)*)"'
USAGE = [
    (ROOT / "Sources" / "NVBeacon", "*.swift", re.compile(r'(?:^|[^\w.])t\(' + SWIFT_LITERAL + r'|\.text\(' + SWIFT_LITERAL, re.M)),
    (ROOT / "Windows" / "Sources", "**/*.swift", re.compile(r'\.text\(' + SWIFT_LITERAL + r'[,)]')),
    (ROOT / "Windows" / "Sources" / "NVBeacon" / "UI", "*.js", re.compile(r'(?:^|[^\w.$])t\(' + SWIFT_LITERAL + r'[,)]', re.M)),
]
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(@|lld|ld|d)|%%")


def load():
    files = {}
    for path in sorted(LOCALIZATION.glob("*.json")):
        files[path.stem] = json.loads(path.read_text())
    return files


def english_text(key):
    return key.rsplit(SEPARATOR, 1)[-1]


def placeholders(text):
    result, number = {}, 1
    for match in PLACEHOLDER.finditer(text):
        if match.group(0) == "%%":
            continue
        position = int(match.group(1)) if match.group(1) else number
        if not match.group(1):
            number += 1
        result[position] = "@" if match.group(2) == "@" else "d"
    return result


def unescape(literal):
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), literal)


def check():
    files = load()
    english = files[SOURCE]["strings"]
    problems = []
    for code, data in files.items():
        if not data.get("name"):
            problems.append(f"{code}.json: no name")
        for key, text in data["strings"].items():
            if code == SOURCE:
                if text != english_text(key):
                    problems.append(f"en.json: {key!r} should read {english_text(key)!r}")
                continue
            if key not in english:
                problems.append(f"{code}.json: {key!r} is not in en.json")
            elif placeholders(text) != placeholders(english[key]):
                problems.append(f"{code}.json: placeholders of {key!r} differ: {text!r}")
    used = set()
    for folder, pattern, regex in USAGE:
        for path in sorted(folder.glob(pattern)):
            for match in regex.finditer(path.read_text()):
                key = unescape(next(group for group in match.groups() if group is not None))
                used.add(key)
                if not key.endswith(SEPARATOR) and key not in english:
                    problems.append(f"{path.relative_to(ROOT)}: {key!r} is not in en.json")
    ios_texts = ios_literals()
    unused = [key for key in english if key not in used and "error::" not in key
              and skeleton(english_text(key)) not in ios_texts]
    for key in unused:
        print(f"possibly unused (or looked up at run time): {key!r}")
    for problem in problems:
        print(problem)
    counts = ", ".join(f"{code} {len(data['strings'])}" for code, data in files.items())
    print(f"{len(english)} keys ({counts}); {len(problems)} problems")
    return 1 if problems else 0


# ---------- iOS ----------

def skeleton(text):
    """A text with every placeholder replaced by NUL, to compare keys with source literals."""
    return PLACEHOLDER.sub(lambda m: "%" if m.group(0) == "%%" else "\0", text)


def ios_literals():
    """The string literals of the iOS app, interpolations replaced by NUL. iOS looks texts
    up by these literals (Text("…"), String(localized: "…")), so they stand for its keys."""
    texts = set()
    for path in [*(ROOT / "Mobile").rglob("*.swift"), *(ROOT / "Shared").rglob("*.swift")]:
        for match in re.finditer(SWIFT_LITERAL, path.read_text()):
            literal = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "\0", match.group(1))
            texts.add(unescape(literal))
    return texts

def parse_strings(path):
    if not path.exists():
        return {}
    text = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.S)
    entries = {}
    for match in re.finditer(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text):
        entries[unescape(match.group(1))] = unescape(match.group(2))
    return entries


def strings_literal(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


def ios_table(strings):
    """iOS looks texts up by their English: plain keys, with `ios::` keys taking precedence."""
    table = {key: text for key, text in strings.items() if SEPARATOR not in key}
    prefix = IOS_CONTEXT + SEPARATOR
    table.update({key[len(prefix):]: text for key, text in strings.items() if key.startswith(prefix)})
    return table


def ios():
    files = load()
    stale = []
    for code, data in files.items():
        if code == SOURCE:
            continue  # English uses the source text; en.lproj only declares the language.
        table = ios_table(data["strings"])
        lines = [
            f"/* Generated from Shared/Localization/{code}.json by scripts/translations.py ios.",
            "   Edit the shared file and run the script again instead of editing this file. */",
            "",
        ]
        lines += [f"{strings_literal(key)} = {strings_literal(table[key])};" for key in sorted(table)]
        path = IOS / f"{code}.lproj" / "Localizable.strings"
        content = "\n".join(lines) + "\n"
        if "--check" in sys.argv:
            if not path.exists() or path.read_text() != content:
                stale.append(str(path.relative_to(ROOT)))
            continue
        path.parent.mkdir(exist_ok=True)
        path.write_text(content)
        print(f"{path.relative_to(ROOT)}: {len(table)} strings")
    for path in stale:
        print(f"{path} is out of date: run python3 scripts/translations.py ios")
    return 1 if stale else 0


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    sys.exit({"check": check, "ios": ios}[command]())
