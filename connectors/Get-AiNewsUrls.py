#!/usr/bin/env python
"""Emit AI-news article URLs for the notebooklm-toolkit to ingest.

Reads x-ai-news-researcher's database through its own NewsStore, so the
ranking convention (relevance_score desc) stays in one place instead of being
re-implemented as raw SQL here.

Runs with zero LLM involvement: it imports the same functions the project's
MCP server exposes rather than going through the MCP protocol, which would
put a model in the loop and defeat the point of a scheduled pipeline.

Usage:
    python Get-AiNewsUrls.py --days 7 --per-day 1
    python Get-AiNewsUrls.py --date-from 2026-08-22 --date-to 2026-08-28 --per-day 3
    python Get-AiNewsUrls.py --days 7 --top 20 --json

Output: one URL per line on stdout (consume directly from PowerShell), or a
JSON array with metadata when --json is given. Diagnostics go to stderr so
stdout stays clean for piping.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

DEFAULT_BACKEND = Path("C:/GitSource/x-ai-news-researcher/backend")


def build_store(backend: Path):
    if not backend.is_dir():
        sys.exit(f"backend not found: {backend}")
    sys.path.insert(0, str(backend))
    import os

    os.chdir(backend)  # settings resolve the sqlite path relative to the backend
    from app.config import settings
    from app.store.news_store import NewsStore
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker

    engine = create_engine(settings.database_url)
    return NewsStore(sessionmaker(bind=engine)())


def daterange(a: dt.date, b: dt.date):
    for i in range((b - a).days + 1):
        yield a + dt.timedelta(days=i)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", type=Path, default=DEFAULT_BACKEND)
    ap.add_argument("--days", type=int, help="look back N days from the newest post in the DB")
    ap.add_argument("--date-from", dest="date_from")
    ap.add_argument("--date-to", dest="date_to")
    ap.add_argument("--per-day", type=int, default=1, help="top N per day (default 1)")
    ap.add_argument("--top", type=int, help="ignore --per-day; take the top N over the whole range")
    ap.add_argument("--min-score", type=float, default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    store = build_store(args.backend)

    # Anchor on the newest post rather than today: the fetcher may be behind,
    # and an empty result is worse than a slightly older window.
    newest = store.query_posts(sort="date_desc", per_page=1)
    if not newest:
        sys.exit("no posts in database")
    anchor = newest[0].posted_at.date()

    if args.date_from and args.date_to:
        d_from = dt.date.fromisoformat(args.date_from)
        d_to = dt.date.fromisoformat(args.date_to)
    else:
        days = args.days or 7
        d_to = anchor
        d_from = anchor - dt.timedelta(days=days - 1)

    print(f"[range] {d_from} .. {d_to} (newest post in DB: {anchor})", file=sys.stderr)

    picked, seen = [], set()

    def take(posts, n):
        out = 0
        for p in posts:
            if out >= n:
                break
            if not p.url or p.url in seen:
                continue
            seen.add(p.url)
            picked.append(p)
            out += 1

    if args.top:
        take(store.query_posts(date_from=d_from, date_to=d_to, min_score=args.min_score,
                               sort="score_desc", per_page=args.top * 5), args.top)
    else:
        for day in daterange(d_from, d_to):
            take(store.query_posts(date_from=day, date_to=day, min_score=args.min_score,
                                   sort="score_desc", per_page=args.per_day * 5), args.per_day)

    if not picked:
        sys.exit("no posts matched the given range/filters")

    if args.json:
        rows = [{"url": p.url, "source": p.source, "score": p.relevance_score,
                 "points": p.points, "posted_at": p.posted_at.isoformat() if p.posted_at else None}
                for p in picked]
        sys.stdout.write(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
    else:
        for p in picked:
            sys.stdout.write(p.url + "\n")

    print(f"[picked] {len(picked)} url(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
