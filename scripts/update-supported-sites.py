#!/usr/bin/env python3
"""Refresh the repository's neutral supported-sites summary."""
from __future__ import annotations

from pathlib import Path

TARGET = Path(__file__).resolve().parents[1] / "SUPPORTED_SITES.md"
CONTENT = """# Supported sites

Siphon uses [yt-dlp](https://github.com/yt-dlp/yt-dlp) for broad extractor coverage across more than 1,000 websites.

Supported services change frequently as websites and upstream extractors evolve. The reliable way to check a URL is to paste it into Siphon and let the app inspect it. For the current upstream compatibility catalog, see [yt-dlp's supported-sites documentation](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md).

Some services require an authenticated browser session, and availability can vary by region or account.
"""

TARGET.write_text(CONTENT, encoding="utf-8")
print(f"Updated {TARGET.relative_to(TARGET.parent)}")
