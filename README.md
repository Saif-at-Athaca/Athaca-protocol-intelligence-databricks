# Protocol Intelligence — Databricks Integration

Databricks POC workspace for **ATHACA Protocol Intelligence**: Unity Catalog medallion layout, Asset Bundles, data ingest (AACT), and (later) Databricks Apps wiring to Landscape and Positioning workflows.

This repo is intentionally separate from the production PI web app ([Protocol-Intelligence-New-UI](https://github.com/Athaca/Protocol-Intelligence-New-UI)) so bundle deploys, notebooks, and large data artifacts do not mix with the EC2/Next.js release line.

## Layout

| Path | Purpose |
|------|---------|
| `databricks.yml` | Databricks Asset Bundle (dev/prod targets) |
| `resources/` | Bundle resources (jobs, schemas, volumes) |
| `notebooks/` | Ingest and QA notebooks (S03+) |
| `scripts/` | Local helpers (AACT snapshot download — S02) |
| `docs/` | Runbooks, data lineage notes, branch policy |
| `tests/` | CI unit tests (bundle config, scripts) |

## Prerequisites

- Python 3.12+
- [Databricks CLI](https://docs.databricks.com/dev-tools/cli/databricks-cli.html) v0.218+ (for `databricks bundle validate`)
- Optional: `DATABRICKS_HOST` + token or OAuth profile for deploy

## Quick start

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt

# Lint + tests (same as CI)
ruff check .
pytest tests/ -v

# Validate bundle (no workspace login required for syntax)
databricks bundle validate
```

Copy `.env.example` to `.env` for local AACT download paths (never commit `.env`).

## Branch policy (S01)

- **`main`** — protected; merge via PR only.
- **Feature branches** — `feature/<task-id>-short-description` (e.g. `feature/s03-bronze-load`).
- Every PR runs **Ruff**, **pytest**, and **`databricks bundle validate`**.

See [docs/branch-policy.md](docs/branch-policy.md).

## Workbook tasks (Saif)

| ID | Status in repo |
|----|----------------|
| **S01** | Repo structure, bundle skeleton, CI on PR |
| **S02** | AACT snapshot download script + [version note](docs/data/aact-snapshot.md) |
| S03+ | Follow-on PRs after Unity Catalog (J07) |

## Related PI behavior

Use the main PI app for reference semantics (Design Landscape denominators, Scenario Analysis, RWD). This repo implements the **Databricks** path only.

## Publish to GitHub (Athaca)

This clone is ready on disk at `protocol-intelligence-databricks`. Remote is preset to:

`git@github.com:Athaca/protocol-intelligence-databricks.git`

1. Create an **empty** repository with that name under the Athaca org (no README).
2. Run `./scripts/push_to_github.sh` from this directory.

Alternatively, after `origin auth login` or `gh auth login`, use Cursor Origin or `gh repo create`.
