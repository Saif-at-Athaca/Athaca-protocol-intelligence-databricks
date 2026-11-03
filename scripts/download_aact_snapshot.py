#!/usr/bin/env python3
"""Download AACT static export and record version in docs/data/aact-snapshot.md (S02)."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urljoin

import requests

REPO_ROOT = Path(__file__).resolve().parents[1]
DOWNLOAD_PAGES = (
    "https://aact.ctti-clinicaltrials.org/snapshots",
    "https://aact.ctti-clinicaltrials.org/download",
)
MANIFEST_PATH = REPO_ROOT / "docs" / "data" / "aact-snapshot.md"
RECORDED_BLOCK_START = "## Recorded snapshot"


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_download_links(session: requests.Session) -> tuple[str, list[tuple[str, str]]]:
    """Return (export_date_hint, [(label, url), ...]) from the CTTI download page."""
    html = ""
    last_error: Exception | None = None
    for page in DOWNLOAD_PAGES:
        try:
            resp = session.get(page, timeout=120, allow_redirects=True)
            resp.raise_for_status()
            html = resp.text
            break
        except requests.HTTPError as exc:
            last_error = exc
    if not html:
        raise RuntimeError(
            "Could not read AACT download pages (CTTI may require sign-in). "
            "Download manually after login, then use --record-only, "
            "or pass --url / AACT_DOWNLOAD_URL."
        ) from last_error

    date_match = re.search(
        r"(?:Export|Snapshot|Database).*?(\d{4}-\d{2}-\d{2})",
        html,
        re.IGNORECASE,
    )
    export_date = date_match.group(1) if date_match else "unknown"

    links: list[tuple[str, str]] = []
    for href in re.findall(r'href="([^"]+)"', html):
        if "pipe" in href.lower() and ("flat" in href.lower() or "zip" in href.lower()):
            url = urljoin(DOWNLOAD_PAGES[0], href)
            label = Path(href.split("?")[0]).name or "aact_pipe_flat.zip"
            links.append((label, url))
        elif href.lower().endswith(".zip") and "aact" in href.lower():
            url = urljoin(DOWNLOAD_PAGES[0], href)
            label = Path(href.split("?")[0]).name
            links.append((label, url))

    # Prefer pipe-delimited flat file bundle
    links.sort(key=lambda x: ("pipe" not in x[0].lower(), x[0]))
    return export_date, links


def download_file(session: requests.Session, url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with session.get(url, stream=True, timeout=600) as resp:
        resp.raise_for_status()
        with dest.open("wb") as out:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    out.write(chunk)


def write_manifest(
    *,
    status: str,
    snapshot_label: str,
    export_date: str,
    completed_utc: str,
    local_path: str,
    files: list[str],
    sha256: str,
) -> None:
    table = f"""| Field | Value |
|-------|--------|
| **Status** | {status} |
| **Source** | [AACT Downloads](https://aact.ctti-clinicaltrials.org/download) |
| **Snapshot label** | {snapshot_label} |
| **Export date (CTTI)** | {export_date} |
| **Download completed (UTC)** | {completed_utc} |
| **Local path** | `{local_path}` |
| **File(s)** | {", ".join(f"`{f}`" for f in files) if files else "—"} |
| **SHA-256** | `{sha256}` |
| **Used by** | S03 → `pi.bronze` (after J07) |
"""
    text = MANIFEST_PATH.read_text(encoding="utf-8")
    if RECORDED_BLOCK_START not in text:
        raise RuntimeError(f"Manifest template missing '{RECORDED_BLOCK_START}'")
    before, _ = text.split(RECORDED_BLOCK_START, 1)
    rest = text.split(RECORDED_BLOCK_START, 1)[1]
    after = rest.split("\n## ", 1)
    tail = f"\n## {after[1]}" if len(after) > 1 else "\n"
    MANIFEST_PATH.write_text(
        before + RECORDED_BLOCK_START + "\n\n" + table + tail,
        encoding="utf-8",
    )


def record_only(directory: Path, export_date: str, snapshot_label: str) -> int:
    files = sorted(p.name for p in directory.iterdir() if p.is_file())
    if not files:
        print(f"No files in {directory}", file=sys.stderr)
        return 1
    primary = directory / files[0]
    digest = _sha256(primary) if len(files) == 1 else "multi-file (see local dir)"
    write_manifest(
        status="Recorded manually",
        snapshot_label=snapshot_label,
        export_date=export_date,
        completed_utc=datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S"),
        local_path=str(directory.relative_to(REPO_ROOT)),
        files=files,
        sha256=digest if isinstance(digest, str) else str(digest),
    )
    print(f"Updated {MANIFEST_PATH}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Download AACT snapshot (S02)")
    parser.add_argument(
        "--dir",
        type=Path,
        default=None,
        help="Download directory (default: AACT_DOWNLOAD_DIR or data/aact)",
    )
    parser.add_argument(
        "--metadata-only",
        action="store_true",
        help="Fetch CTTI page and update manifest without downloading zip",
    )
    parser.add_argument(
        "--record-only",
        action="store_true",
        help="Record existing directory (--dir required)",
    )
    parser.add_argument("--export-date", default="unknown", help="Snapshot export date (CTTI)")
    parser.add_argument("--label", default="", help="With --record-only")
    parser.add_argument(
        "--url",
        default="",
        help="Direct zip URL (or set AACT_DOWNLOAD_URL) when CTTI requires authentication",
    )
    args = parser.parse_args()

    default_dir = REPO_ROOT / "data" / "aact"
    download_dir = args.dir or Path(os.environ.get("AACT_DOWNLOAD_DIR", default_dir))
    if args.record_only:
        if not args.dir:
            parser.error("--record-only requires --dir")
        label = args.label or args.dir.name
        return record_only(args.dir, args.export_date, label)

    session = requests.Session()
    session.headers["User-Agent"] = "protocol-intelligence-databricks/0.1 (S02)"

    direct_url = args.url or os.environ.get("AACT_DOWNLOAD_URL", "")
    if direct_url:
        label = Path(direct_url.split("?")[0]).name or "aact_snapshot.zip"
        export_date = args.export_date if args.export_date != "unknown" else "unknown"
        links = [(label, direct_url)]
    else:
        export_date, links = fetch_download_links(session)
        if args.export_date != "unknown":
            export_date = args.export_date
        if not links:
            print("Could not find AACT zip link on download page.", file=sys.stderr)
            return 1

    label, url = links[0]
    snapshot_label = label

    meta_env = os.environ.get("AACT_METADATA_ONLY", "").lower()
    if args.metadata_only or meta_env in ("1", "true", "yes"):
        write_manifest(
            status="Metadata only (no local file)",
            snapshot_label=snapshot_label,
            export_date=export_date,
            completed_utc=datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S"),
            local_path=str(download_dir.relative_to(REPO_ROOT)),
            files=[],
            sha256="—",
        )
        print(f"Manifest updated (metadata only). URL: {url}")
        return 0

    stamp = export_date if export_date != "unknown" else datetime.now(UTC).strftime("%Y-%m-%d")
    dest_dir = download_dir / stamp
    dest_file = dest_dir / snapshot_label

    print(f"Downloading {url} → {dest_file}")
    download_file(session, url, dest_file)
    digest = _sha256(dest_file)

    write_manifest(
        status="Downloaded",
        snapshot_label=snapshot_label,
        export_date=export_date,
        completed_utc=datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S"),
        local_path=str(dest_dir.relative_to(REPO_ROOT)),
        files=[dest_file.name],
        sha256=digest,
    )
    print(f"Updated {MANIFEST_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
