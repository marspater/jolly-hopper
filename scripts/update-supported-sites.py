#!/usr/bin/env python3
"""Refresh SUPPORTED_SITES.md from yt-dlp's upstream supported-sites page."""
from __future__ import annotations

from datetime import date
from pathlib import Path
from urllib.request import urlopen

UPSTREAM = "https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/supportedsites.md"
TARGET = Path(__file__).resolve().parents[1] / "SUPPORTED_SITES.md"
MARKER = "## Cloned yt-dlp supported-sites list"

with urlopen(UPSTREAM, timeout=60) as response:
    upstream_markdown = response.read().decode("utf-8")

head = f"""# Supported sites

This repository-owned page mirrors the yt-dlp supported sites list for the VeloX About tab.

Attribution: this list is cloned from [`yt-dlp/supportedsites.md`](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md) by the yt-dlp project. The upstream content is maintained by yt-dlp contributors and distributed under yt-dlp's license. Source/update date: {date.today().isoformat()}.

## Maintainer refresh instructions

Refresh this file whenever yt-dlp support changes materially or before releases that advertise current extractor coverage:

```sh
python3 scripts/update-supported-sites.py
```

The script downloads `{UPSTREAM}`, preserves this repository's attribution and refresh instructions, and replaces the cloned list below.

{MARKER}

"""

TARGET.write_text(head + upstream_markdown, encoding="utf-8")
print(f"Updated {TARGET.relative_to(TARGET.parent)} from {UPSTREAM}")
