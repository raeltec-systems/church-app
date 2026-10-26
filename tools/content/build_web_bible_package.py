#!/usr/bin/env python3
"""Build the bundled WEB source asset from eBible.org's official VPL ZIP.

Usage:
  python tools/content/build_web_bible_package.py path/to/engwebp_vpl.zip

The input is an official eBible.org package. The output preserves its VPL text
verbatim so source updates are reviewable.
"""

from __future__ import annotations

import argparse
import re
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "supabase/migrations/20261023020507_content_bible_translations.sql"
OUTPUT = ROOT / "apps/staff/assets/bible/engwebp_vpl.txt"
SOURCE_FILE = "engwebp_vpl.txt"
BOOK_ALIASES = {
    "1JO": "1JN",
    "2JO": "2JN",
    "3JO": "3JN",
    "EZE": "EZK",
    "JAM": "JAS",
    "JOE": "JOL",
    "JOH": "JHN",
    "MAR": "MRK",
    "NAH": "NAM",
    "PHI": "PHP",
    "SOL": "SNG",
}


def expected_chapters() -> dict[tuple[str, int], int]:
    sql = MANIFEST.read_text(encoding="utf-8")
    pattern = re.compile(
        r"values\(1,'WEB','([A-Z0-9]+)',array\[([0-9,]+)\]::smallint\[\]\);"
    )
    result: dict[tuple[str, int], int] = {}
    for book, raw_counts in pattern.findall(sql):
        for chapter, count in enumerate(map(int, raw_counts.split(",")), 1):
            result[(book, chapter)] = count
    if len(result) != 1189:
        raise ValueError(f"expected 1,189 WEB chapter counts, found {len(result)}")
    return result


def validate_vpl(source: str) -> None:
    expected = expected_chapters()
    seen: dict[tuple[str, int], set[int]] = {}
    blank_verses: list[tuple[str, int, int]] = []
    for line_number, line in enumerate(source.splitlines(), 1):
        fields = line.split(" ", 2)
        if len(fields) != 3 or ":" not in fields[1]:
            raise ValueError(f"invalid VPL row at line {line_number}")
        source_book = fields[0]
        book = BOOK_ALIASES.get(source_book, source_book)
        chapter_raw, verse_raw = fields[1].split(":", 1)
        try:
            chapter, verse = int(chapter_raw), int(verse_raw)
        except ValueError as error:
            raise ValueError(f"invalid reference at line {line_number}") from error
        key = (book, chapter)
        if key not in expected or verse < 1 or verse > expected[key]:
            raise ValueError(f"reference is outside the trusted manifest at line {line_number}")
        numbers = seen.setdefault(key, set())
        if verse in numbers:
            raise ValueError(f"duplicate reference at line {line_number}")
        numbers.add(verse)
        if not fields[2].strip():
            blank_verses.append((book, chapter, verse))

    if set(seen) != set(expected):
        missing = sorted(set(expected) - set(seen))
        raise ValueError(f"VPL is missing chapters: {missing[:5]}")
    for key, last_verse in expected.items():
        if seen[key] != set(range(1, last_verse + 1)):
            raise ValueError(f"VPL references do not match the trusted manifest in {key}")
    if blank_verses != [
        ("LUK", 17, 36),
        ("ACT", 8, 37),
        ("ACT", 15, 34),
        ("ACT", 24, 7),
        ("ROM", 16, 25),
    ]:
        raise ValueError(f"unexpected blank WEB verses: {blank_verses}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("official_zip", type=Path)
    args = parser.parse_args()
    with zipfile.ZipFile(args.official_zip) as package:
        source = package.read(SOURCE_FILE).decode("utf-8")
    validate_vpl(source)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    payload = source.encode("utf-8")
    OUTPUT.write_bytes(payload)
    print(f"Wrote {OUTPUT.relative_to(ROOT)} ({len(payload)} bytes)")


if __name__ == "__main__":
    main()
