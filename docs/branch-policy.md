# Branch and PR policy (S01)

## Branches

- **`main`** — integration branch; always deployable bundle config and passing CI.
- **Feature branches** — `feature/<workbook-id>-<slug>`  
  Examples: `feature/s03-bronze-load`, `feature/s06-app-shell`.

## Pull requests

1. Open PR against `main`.
2. Required checks (GitHub Actions):
   - Ruff lint
   - pytest
   - `databricks bundle validate`
3. At least one reviewer (JJ or Agullina for data model changes).

## Handoff

When a workbook task completes, post in the team channel (J01 cadence):

- PR link
- Done-when checklist from the workbook
- Any blockers for downstream tasks
