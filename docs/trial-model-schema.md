# POC trial model schema (A02)

**Owner:** Agullina · **Reviewer:** JJ (J06, Nov 5) · **Status:** draft, Nov 4, 2026

**Done when (Project Plan):** "Silver schema covers POC fields with provenance columns (source, version, page or section)". This schema carries all six provenance fields from the Developer Brief.

**Scope:** built for the POC Proposal's scope (Landscape and Positioning on four fields). The decision record and change flagging are out of scope; section 7 shows how this schema leaves room for them.

## 1. Files

| File | What it is |
|---|---|
| [`sql/silver/silver_pipeline_tables.sql`](../sql/silver/silver_pipeline_tables.sql) | The six silver trial tables, as a Lakeflow pipeline that reads AACT from `pi.bronze` (run in A06) |
| [`sql/silver/silver_reference_tables.sql`](../sql/silver/silver_reference_tables.sql) | The silver objects the pipeline doesn't own: `source_document`, `field_catalog` (30 fields), `intervention_synonym`, `protocol_field`, and the `trial_value_provenance` view |

## 2. How the layers fit

```
pi.bronze  AACT tables as received, every snapshot kept, snapshot_version on each row   S03
   │  Lakeflow pipeline (materialized views)
   ▼
pi.silver  typed trial model + field catalog + protocol values + provenance view        A02 / A06
   │  plain views, latest snapshot
   ▼
pi.public  comparison-ready views read by UC functions, the app and Genie               A07
```

## 3. What each object does

### The trial tables (`silver_pipeline_tables.sql`)

| Table | One row per | What it does | Main users |
|---|---|---|---|
| `trial` | trial per snapshot | The trial's single-valued facts: phase, purpose, allocation, blinding (`masking` + derived `is_blinded`), enrollment and its type, arm count, age range (in years, raw text kept), sex, criteria text, dates. Every field used for coverage or Positioning has a `<field>_status` column | `build_cohort` (A08), `design_distribution` / `coverage_report` (A09), `position_element` (A11), Genie |
| `trial_arm` | arm | Arm title and type (experimental, placebo, ...) | Landscape design view |
| `trial_intervention` | intervention | Name as written, type, and `normalized_name` (e.g. NEOD001 → birtamimab) for treatment matching | `build_cohort` |
| `trial_condition` | condition term | Registered condition names and MeSH terms, with `term_source` saying which | `build_cohort` |
| `trial_endpoint` | registered outcome | Endpoint level, wording, time frame, `is_composite` | Landscape endpoint view, Positioning |
| `trial_endpoint_component` | part of a composite | The parts of a composite endpoint, so it stays **one** endpoint with parts (R4) | Positioning, A04 check |

### The reference objects (`silver_reference_tables.sql`)

| Object | What it does |
|---|---|
| `source_document` | One row per source file version: each AACT snapshot (`aact:20261104`) and each protocol PDF. Holds the **source** and **version**, the file and its checksum |
| `field_catalog` | One row per field: which table and column holds it, its allowed values, and the provenance shared by every value of that field: AACT `table.column` (**page or section**), **extraction method**, default **confidence**, default **reviewer status**, **data tier** |
| `intervention_synonym` | The reviewed synonym list for treatment matching (J05); the pipeline reads it |
| `protocol_field` | Values extracted from protocol PDFs (A03/A05), one row per value, each with its own page, section, quote, method, model endpoint, prompt version, confidence, grounding check, reviewer status, run ID and MLflow trace ID |
| `trial_value_provenance` (view) | One row per registry value with all six provenance fields, built from the tables and the catalog. Stores nothing, so it can't drift. For citations (A13) and "where did this value come from?" |

## 4. The six provenance fields

| Brief's field | Registry values (AACT) | Protocol values |
|---|---|---|
| Source | `source_document.source_system` = `aact` | `protocol_pdf` |
| Version | `snapshot_version` on every row → `source_document.source_version` | `source_doc_id` → the PDF's version |
| Page or section | `field_catalog.aact_source` + NCT ID, e.g. "AACT studies.enrollment, NCT02312206" | `page_number`, `section`, `quote` |
| Extraction method | `field_catalog.extraction_method`: `registry_direct`, `registry_parsed`, `registry_derived`, `regex` | `pdf_text_llm`, `pdf_table`, `pdf_vision_llm`, `regex`, `manual_entry` |
| Confidence | `field_catalog.default_confidence`: 1.0 when copied as written, lower for rule-based values (0.95 synonym, 0.8 composite parts, 0.7 composite flag) | `confidence` per value (0–1) |
| Reviewer status | `field_catalog.default_reviewer_status`: `not_required` when copied, `unreviewed` when derived by a rule | `reviewer_status`: `unreviewed`, `approved`, `corrected`, `rejected` |

**Why registry provenance sits in the catalog:** for AACT values, all six depend only on the field and the snapshot (same column, same method, same snapshot for every trial). Copying them onto every row would repeat the catalog and could drift out of step with it; the view gives the one-row-per-value answer when it's needed. A Databricks Assistant review agreed. Unity Catalog lineage complements this but can't replace it: it shows which column feeds which, not values, versions, pages or confidence.

## 5. Value status: showing gaps honestly

| Status | Meaning | Example |
|---|---|---|
| `reported` | A usable value | Enrollment 260 |
| `not_applicable` | The source says there's nothing to report | Blank maximum age = no upper limit |
| `ambiguous` | Present but could mean more than one thing | Used by protocol extraction |
| `unusable` | Present but can't be parsed, or isn't an allowed value | Age written as free text |
| `missing` | Not reported | 4 of 37 sample trials have no enrollment |

**Rules:** a value is filled exactly when its status is `reported`; missing is never stored as 0. The pipeline's checks only warn, so a bad value becomes `unusable` and is still counted. Missing-value rates are computed from the status columns, so `not_applicable` isn't counted as missing.

## 6. Keys, snapshots and data tiers

- **Every silver key includes `snapshot_version`** (YYYYMMDD as a number), so a second AACT snapshot adds rows instead of replacing them. This needs bronze to keep every snapshot; the requirements on S03 (bronze contract) have been sent to Saif.
- **Repeated elements use natural keys:** arm title, `<type>:<intervention name>`, `COND:` / `MESH:` + term, `<endpoint type>:` + a hash of the wording. AACT's own row ids may change between snapshots, so they're not used.
- **Primary and foreign keys are declared** (informational, not enforced) to document the joins and help Genie.
- **Data tiers:** every row and catalog field carries `data_tier` (`public` for everything in the POC). Each view and function reads only its own tier; licensed or sponsor data, if added, gets its own schema and is combined with public data in the app as the signed-in user. Views and SQL functions read with their owner's permissions, so a public view reading licensed tables would leak them.

## 7. Built now vs. left for later

| Item | Now | Later |
|---|---|---|
| Typed tables, statuses, catalog, provenance view, `protocol_field` | ✅ | |
| `snapshot_version` in every key | ✅ | Change flagging = a view comparing two snapshots |
| `data_tier` everywhere | ✅ | Licensed and sponsor schemas |
| Decision record, change flags, review screen, MCP server | ❌ out of scope | Added on top; this schema doesn't need to change |

**What this asks of later tasks:** UC functions take a `snapshot_version` parameter that defaults to the latest (A08, A09, A11), and return the trial IDs and statuses behind each number.

### For A13 (not part of A02): linking findings to this schema

A13 (Nov 18, AC2) makes each finding carry its source trial IDs, data version and page or section. With this schema, each finding in `pi.outputs` stores, per cited value (e.g. a `finding_evidence` table):

- the trial ID, `snapshot_version` / `source_doc_id`, `field_path` and `element_key`;
- **the cited value and its `value_status`, copied** rather than pointed to, so the finding stays readable if silver is rebuilt, and a later decision record can reuse it as its evidence snapshot;
- page or section: from `trial_value_provenance` for registry values, page and quote from `protocol_field` for protocol values;
- `data_tier`, plus the run ID and MLflow trace ID.

A comparison is labelled **incomplete** (AC5) when any cited value's status isn't `reported`.

## 8. Example: VITAL (NCT02312206)

| Table | Values (sample data) |
|---|---|
| `trial` | phase PHASE3 · primary purpose TREATMENT · masking QUADRUPLE (`is_blinded` true) · enrollment 260 ACTUAL · arms 2 · min age 18 years · max age `not_applicable` (no limit) |
| `trial_intervention` | `DRUG:neod001` → normalised `birtamimab` (`registry_derived`); placebo |
| `trial_endpoint` | PRIMARY: "Time to Composite of All-cause Mortality or Cardiac Hospitalization", `is_composite` true |
| `trial_endpoint_component` | 1 All-cause Mortality · 2 Cardiac Hospitalization |
| provenance view | `design.enrollment` = 260 · reported · aact · snapshot version · "AACT studies.enrollment, NCT02312206" · registry_direct · 1.0 · not_required · public |

The protocol extraction (A03/A05) writes the same field paths into `protocol_field` with page numbers and quotes; comparing the two for VITAL is part of A04.

The design was checked on 37 sample trials: all keys unique, every status rule holds, coverage as expected (e.g. enrollment 33 of 37), and a simulated second snapshot found exactly the one value that was changed.

## 9. Known limitations

1. **Not run yet.** The pipeline runs in A06; table constraints on materialized views and some SQL forms still need confirming there.
2. **Column names come from a sample** (ClinicalTrials.gov data in AACT's shape), not the real snapshot. To check when the snapshot is loaded.
3. **Composite detection is weak:** the word "composite" only (1 of 269 sample endpoints). Values are `unreviewed`; VITAL is checked by hand in A04.
4. **Blank ages are treated as "no limit"** (ClinicalTrials.gov convention). To confirm with Paola.
5. **A reworded endpoint counts as a new endpoint**, because its key is based on the wording.

## 10. Questions for JJ (J06)

1. Approve this schema: typed silver tables, registry provenance through `field_catalog` and the provenance view, protocol values in `protocol_field`?
2. Approve the asks on later tasks (section 7) and on S03 (the bronze contract sent to Saif)?
3. Blank ages as "no limit": confirm with Paola.
