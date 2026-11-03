# AACT static snapshot (S02)

This file is updated by `scripts/download_aact_snapshot.py`. Do not edit the **Recorded snapshot** block by hand unless the script is unavailable.

## Recorded snapshot

| Field | Value |
|-------|--------|
| **Status** | _Not downloaded yet — run `python scripts/download_aact_snapshot.py`_ |
| **Source** | [AACT Downloads](https://aact.ctti-clinicaltrials.org/download) |
| **Snapshot label** | — |
| **Export date (CTTI)** | — |
| **Download completed (UTC)** | — |
| **Local path** | `data/aact/` (gitignored) |
| **File(s)** | — |
| **SHA-256** | — |
| **Used by** | S03 → `pi.bronze` (after J07) |

## AC2 lineage

- Bronze load notebooks must reference **Snapshot label** and **Export date** in table properties or a `_metadata` table.
- VITAL protocol Volume metadata (S04) uses the same pattern in `docs/data/vital-protocol.md` (future).

## Manual fallback

If automated download fails (network or CTTI layout change):

1. Download the current **Pipe-delimited flat files** zip from CTTI.
2. Extract under `data/aact/<YYYY-MM-DD>/`.
3. Re-run: `python scripts/download_aact_snapshot.py --record-only --dir data/aact/<YYYY-MM-DD>`
