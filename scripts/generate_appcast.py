#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import html
import os
from email.utils import format_datetime
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a simple Sparkle appcast.")
    parser.add_argument("--output", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--archive-path", required=True)
    parser.add_argument("--release-url", required=True)
    parser.add_argument("--minimum-system-version", default="14.0")
    parser.add_argument("--app-name", default="GPUUsage")
    parser.add_argument("--notes-file")
    parser.add_argument("--ed-signature", default="")
    return parser.parse_args()


def render_notes_html(notes_text: str) -> str:
    lines = [line.rstrip() for line in notes_text.splitlines()]
    blocks: list[str] = []
    bullet_buffer: list[str] = []

    def flush_bullets() -> None:
        nonlocal bullet_buffer
        if bullet_buffer:
            items = "".join(f"<li>{html.escape(item)}</li>" for item in bullet_buffer)
            blocks.append(f"<ul>{items}</ul>")
            bullet_buffer = []

    for line in lines:
        stripped = line.strip()
        if not stripped:
            flush_bullets()
            continue
        if stripped.startswith("- "):
            bullet_buffer.append(stripped[2:])
        else:
            flush_bullets()
            blocks.append(f"<p>{html.escape(stripped)}</p>")

    flush_bullets()

    if not blocks:
        return "<p>Bug fixes and improvements.</p>"

    return "\n".join(blocks)


def main() -> None:
    args = parse_args()
    archive_path = Path(args.archive_path)
    archive_size = archive_path.stat().st_size

    notes_text = ""
    if args.notes_file:
        notes_path = Path(args.notes_file)
        if notes_path.exists():
            notes_text = notes_path.read_text(encoding="utf-8").strip()

    pub_date = format_datetime(dt.datetime.now(dt.timezone.utc))
    enclosure_signature = (
        f'\n                    sparkle:edSignature="{html.escape(args.ed_signature)}"'
        if args.ed_signature
        else ""
    )
    description_html = render_notes_html(notes_text)

    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{html.escape(args.app_name)} Updates</title>
    <link>{html.escape(args.release_url)}</link>
    <description>Latest updates for {html.escape(args.app_name)}</description>
    <language>en</language>
    <item>
      <title>Version {html.escape(args.version)}</title>
      <link>{html.escape(args.release_url)}</link>
      <sparkle:version>{html.escape(args.build_number)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(args.minimum_system_version)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{html.escape(args.release_url)}</sparkle:fullReleaseNotesLink>
      <pubDate>{pub_date}</pubDate>
      <description><![CDATA[
{description_html}
      ]]></description>
      <enclosure url="{html.escape(args.download_url)}"
                    type="application/octet-stream"
                    length="{archive_size}"{enclosure_signature} />
    </item>
  </channel>
</rss>
"""

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(xml, encoding="utf-8")


if __name__ == "__main__":
    main()
