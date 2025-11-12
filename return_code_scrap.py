#!/usr/bin/env python3
"""

"""

import json
import re
import sys
from pathlib import Path
from typing import Dict

import lxml.html
import requests


URL = "https://www.mql5.com/en/docs/constants/errorswarnings/enum_trade_return_codes"
OUTPUT = Path("trade_retcodes.json")


def fetch_page(url: str) -> str:
    """Download the page and return its text."""
    headers = {"User-Agent": "Mozilla/5.0 (compatible; MQL5-scraper/1.0)"}
    resp = requests.get(url, headers=headers, timeout=15)
    resp.raise_for_status()
    return resp.text


def extract_table(html_text: str) -> lxml.html.HtmlElement:
    """Return the <table> that contains the enum values."""
    tree = lxml.html.fromstring(html_text)

    # The table has class containing "enum" (case-insensitive)
    table = tree.xpath("//table[contains(@class,'enum') or contains(@class,'Enum')]")
    if not table:
        raise ValueError("Trade return-codes table not found.")
    return table[0]


def parse_rows(table: lxml.html.HtmlElement) -> Dict[int, Dict[str, str]]:
    """Convert table rows into a dict: code → {constant, description}."""
    retcodes = {}

    # Skip header row (first <tr>)
    for row in table.xpath("./tbody/tr")[1:]:
        cells = row.xpath("./td")
        if len(cells) != 3:
            continue

        code_text = cells[0].text_content().strip()
        constant = cells[1].text_content().strip()
        description = cells[2].text_content().strip()

        # Some descriptions contain line-breaks – preserve them as \n
        description = re.sub(r"\s+\n\s+", "\n", description)

        try:
            code = int(code_text)
        except ValueError:
            continue  # malformed row

        retcodes[code] = {
            "constant": constant,
            "description": description
        }

    return retcodes


def save_json(data: Dict[int, Dict[str, str]], path: Path) -> None:
    """Write JSON with pretty indentation and UTF-8 encoding."""
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False, sort_keys=True)
    print(f"Saved {len(data)} return codes → {path}")


def main() -> None:
    try:
        html = fetch_page(URL)
        table = extract_table(html)
        codes = parse_rows(table)
        save_json(codes, OUTPUT)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()