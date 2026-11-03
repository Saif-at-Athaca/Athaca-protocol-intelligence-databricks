# How to download AACT (S02)

CTTI now requires a free [AACT account](https://aact.ctti-clinicaltrials.org/sign_up) to download full snapshots.

## Automated

```bash
# After copying a signed-in download link from the Snapshots page:
export AACT_DOWNLOAD_URL='https://...'
python scripts/download_aact_snapshot.py
```

Or:

```bash
python scripts/download_aact_snapshot.py --url 'https://...' --export-date 2026-11-01
```

## Manual + record

1. Sign in → **Snapshots** → download **Pipe-delimited flat files** (zip).
2. Extract under `data/aact/<YYYY-MM-DD>/`.
3. Record lineage:

```bash
python scripts/download_aact_snapshot.py --record-only \
  --dir data/aact/2026-11-01 \
  --export-date 2026-11-01 \
  --label aact_pipe_flat.zip
```

The script updates [aact-snapshot.md](aact-snapshot.md) for AC2.
