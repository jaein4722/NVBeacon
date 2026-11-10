#!/usr/bin/env python3
"""Regenerate bundled notices from the exact Xcode Package.resolved checkouts."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BORINGSSL_REVISION = "0226f30467f540a3f62ef48d453f93927da199b6"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkouts", type=Path, default=ROOT / ".build/ios-packages/checkouts")
    parser.add_argument("--check", action="store_true", help="Fail if bundled notices are stale")
    args = parser.parse_args()
    lock = ROOT / "Mobile/NVBeacon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    pins = json.loads(lock.read_text())["pins"]
    checkouts = {p.name.lower(): p for p in args.checkouts.iterdir() if p.is_dir()}
    sections = ["NVBeacon for iOS — Open Source Licenses\n\n"
                "Generated from the pinned dependencies by scripts/generate_ios_notices.py.\n"
                "This product includes software developed by Niels Provos."]

    def add(title, body):
        sections.append(f"{title}\n{'=' * 72}\n{body.strip()}")

    for pin in sorted(pins, key=lambda p: p["identity"]):
        package = checkouts[pin["identity"].lower()]
        revision = pin["state"]["revision"]
        actual = subprocess.check_output(["git", "-C", str(package), "rev-parse", "HEAD"], text=True).strip()
        if actual != revision:
            raise SystemExit(f"{pin['identity']}: checkout differs from Package.resolved")
        # Read from Git objects, not potentially edited checkout files.
        files = subprocess.check_output(["git", "-C", str(package), "ls-tree", "-r", "--name-only", revision], text=True).splitlines()

        def read(path):
            return subprocess.check_output(["git", "-C", str(package), "show", f"{revision}:{path}"], text=True)

        notices = [p for p in files if Path(p).name.lower().split('.')[0] in ("license", "notice", "copying")]
        if not notices:
            raise SystemExit(f"No license found for {pin['identity']}")
        add(f"{package.name} — {pin['state'].get('version', revision)}", f"Source: {pin['location']}\nRevision: {revision}")
        for path in sorted(notices):
            add(f"{package.name}/{path}", read(path))
        if pin["identity"] == "citadel":
            for path in [p for p in files if p.startswith("Sources/CCitadelBcrypt/") and p.endswith((".c", ".h"))]:
                for comment in re.findall(r"/\*.*?\*/", read(path), re.S):
                    if "Copyright" in comment and ("Redistribution" in comment or "Permission" in comment):
                        add(f"Citadel/{path} — embedded license", comment)
        if pin["identity"] == "swift-crypto":
            if BORINGSSL_REVISION not in read("Sources/CCryptoBoringSSL/hash.txt"):
                raise SystemExit("BoringSSL changed: update its pinned upstream license before regenerating")
            add(f"BoringSSL — {BORINGSSL_REVISION}",
                f"Source: https://github.com/google/boringssl/blob/{BORINGSSL_REVISION}/LICENSE\n\n"
                + (ROOT / "scripts/licenses/boringssl-0226f304-LICENSE.txt").read_text())
    output = ROOT / "Mobile/NVBeacon/ThirdPartyNotices.txt"
    text = "\n".join(line.rstrip() for line in "\n\n".join(sections).splitlines()).rstrip() + "\n"
    if args.check:
        if not output.exists() or output.read_text() != text:
            raise SystemExit("ThirdPartyNotices.txt is stale; run scripts/generate_ios_notices.py")
        print(f"Notices verified for {len(pins)} pinned dependencies")
    else:
        output.write_text(text)
        print(f"Generated {output.relative_to(ROOT)} for {len(pins)} pinned dependencies")


if __name__ == "__main__":
    main()
