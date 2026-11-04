-- =====================================================================
-- PI on Databricks POC: silver trial model, non-pipeline objects (A02)
-- Owner: Agullina · Reviewer: JJ (J06) · Draft v2: 2026-11-04 (design B,
-- after a second Databricks Assistant review)
--
-- The typed trial tables are built by the pipeline in
-- silver_pipeline_tables.sql. This file holds what the pipeline does not
-- own: reference tables, the protocol extraction table and the provenance
-- view. Run sections 1-5 in the SQL editor before the first pipeline
-- update (the pipeline reads intervention_synonym); run section 6 after.
-- Assumes catalog `pi` and schema `pi.silver` exist (J07).
-- Not yet run against the workspace.
--
-- Data tiers: every object here reads only public-tier data. Licensed or
-- sponsor data, when added, gets its own schema and its own objects;
-- tiers are combined in the app as the signed-in user, never in a view or
-- SQL function (both run with their owner's permissions).
-- =====================================================================

USE CATALOG pi;
USE SCHEMA silver;

-- ---------------------------------------------------------------------
-- 1. source_document: one row per source file version
--    One row per AACT snapshot, and one per protocol PDF version.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS source_document (
  source_doc_id     STRING    NOT NULL COMMENT 'aact:<snapshot_version> for AACT, protocol:<protocol_id>:<version> for PDFs',
  source_system     STRING    NOT NULL COMMENT 'SOURCE: aact | protocol_pdf',
  data_tier         STRING    NOT NULL COMMENT 'public | licensed | sponsor',
  source_version    STRING    NOT NULL COMMENT 'VERSION as written: AACT export date (YYYY-MM-DD) or protocol version label',
  snapshot_version  BIGINT    NOT NULL COMMENT 'Sortable version: YYYYMMDD for AACT; a sequence number for protocol versions',
  document_date     DATE               COMMENT 'AACT export date or protocol document date',
  location_uri      STRING             COMMENT 'Download URL or UC Volume path',
  file_name         STRING,
  content_checksum  STRING             COMMENT 'SHA-256 of the file (from docs/data/aact-snapshot.md for AACT)',
  loaded_at         TIMESTAMP NOT NULL,
  loaded_by         STRING             COMMENT 'User or service principal that ran the load',
  CONSTRAINT source_document_pk PRIMARY KEY (source_doc_id)
)
COMMENT 'One row per source file version feeding the trial model: each AACT snapshot and each protocol PDF.';

ALTER TABLE source_document ADD CONSTRAINT source_system_ok CHECK (source_system IN ('aact', 'protocol_pdf'));
ALTER TABLE source_document ADD CONSTRAINT data_tier_ok     CHECK (data_tier IN ('public', 'licensed', 'sponsor'));

-- ---------------------------------------------------------------------
-- 2. field_catalog: one row per field of the trial model
--    Holds the provenance that is the same for every value of a field
--    (where it comes from in AACT, how it is extracted, its default
--    confidence and reviewer status) and the field's allowed values.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS field_catalog (
  field_path              STRING  NOT NULL COMMENT 'Dotted name, e.g. design.masking. Same names in protocol_field',
  label                   STRING  NOT NULL COMMENT 'Human label shown in the app',
  silver_table            STRING  NOT NULL COMMENT 'Silver table holding the value, e.g. trial',
  silver_column           STRING  NOT NULL COMMENT 'Column holding the value',
  status_column           STRING           COMMENT 'Column holding its value status, if it has one',
  value_type              STRING  NOT NULL COMMENT 'string | number | date | boolean | text',
  unit                    STRING           COMMENT 'Unit for numbers, e.g. participants, years',
  allowed_values          STRING           COMMENT 'Pipe-separated controlled vocabulary, if any (must match the pipeline)',
  repeats                 BOOLEAN NOT NULL COMMENT 'True if a trial can have several values (arms, endpoints)',
  used_by                 STRING  NOT NULL COMMENT 'landscape | positioning | cohort, pipe-separated',
  aact_source             STRING           COMMENT 'PAGE OR SECTION for registry values: AACT table.column',
  extraction_method       STRING  NOT NULL COMMENT 'METHOD: registry_direct | registry_parsed | registry_derived | regex',
  default_confidence      DOUBLE  NOT NULL COMMENT 'CONFIDENCE for registry values: 1.0 when copied as written',
  default_reviewer_status STRING  NOT NULL COMMENT 'REVIEWER STATUS for registry values: not_required (copied) | unreviewed (parsed by rule)',
  data_tier               STRING  NOT NULL COMMENT 'public | licensed | sponsor',
  description             STRING,
  CONSTRAINT field_catalog_pk PRIMARY KEY (field_path)
)
COMMENT 'The fields of the trial model and the provenance shared by every value of each field.';

ALTER TABLE field_catalog ADD CONSTRAINT method_ok
  CHECK (extraction_method IN ('registry_direct', 'registry_parsed', 'registry_derived', 'regex'));
ALTER TABLE field_catalog ADD CONSTRAINT reviewer_default_ok
  CHECK (default_reviewer_status IN ('not_required', 'unreviewed'));
ALTER TABLE field_catalog ADD CONSTRAINT confidence_range
  CHECK (default_confidence BETWEEN 0 AND 1);

INSERT INTO field_catalog VALUES
  ('study.brief_title',              'Title',                     'trial',                    'brief_title',             NULL,                     'text',    NULL,           NULL, false, 'landscape',             'studies.brief_title',             'registry_direct',  1.0, 'not_required', 'public', NULL),
  ('study.lead_sponsor',             'Sponsor',                   'trial',                    'lead_sponsor',            NULL,                     'string',  NULL,           NULL, false, 'landscape',             'studies.source',                  'registry_direct',  1.0, 'not_required', 'public', NULL),
  ('study.overall_status',           'Status',                    'trial',                    'overall_status',          NULL,                     'string',  NULL,           NULL, false, 'landscape|cohort',      'studies.overall_status',          'registry_direct',  1.0, 'not_required', 'public', NULL),
  ('study.study_type',               'Study type',                'trial',                    'study_type',              NULL,                     'string',  NULL,           NULL, false, 'cohort',                'studies.study_type',              'registry_direct',  1.0, 'not_required', 'public', 'Cohort rule example: interventional only'),
  ('design.phase',                   'Phase',                     'trial',                    'phase',                   'phase_status',           'string',  NULL,           'EARLY_PHASE1|PHASE1|PHASE1/PHASE2|PHASE2|PHASE2/PHASE3|PHASE3|PHASE4|NA', false, 'landscape|cohort', 'studies.phase', 'registry_direct', 1.0, 'not_required', 'public', 'Combined phases kept as written; the cohort rule decides how to treat them'),
  ('design.primary_purpose',         'Primary purpose',           'trial',                    'primary_purpose',         'primary_purpose_status', 'string',  NULL,           'TREATMENT|PREVENTION|DIAGNOSTIC|SUPPORTIVE_CARE|SCREENING|HEALTH_SERVICES_RESEARCH|BASIC_SCIENCE|DEVICE_FEASIBILITY|OTHER', false, 'landscape|cohort', 'designs.primary_purpose', 'registry_direct', 1.0, 'not_required', 'public', 'Feeds the diagnostic fallback (D3)'),
  ('design.allocation',              'Allocation',                'trial',                    'allocation',              'allocation_status',      'string',  NULL,           'RANDOMIZED|NON_RANDOMIZED|NA', false, 'landscape', 'designs.allocation', 'registry_direct', 1.0, 'not_required', 'public', NULL),
  ('design.intervention_model',      'Intervention model',        'trial',                    'intervention_model',      NULL,                     'string',  NULL,           'SINGLE_GROUP|PARALLEL|CROSSOVER|FACTORIAL|SEQUENTIAL', false, 'landscape', 'designs.intervention_model', 'registry_direct', 1.0, 'not_required', 'public', NULL),
  ('design.masking',                 'Blinding',                  'trial',                    'masking',                 'masking_status',         'string',  NULL,           'NONE|SINGLE|DOUBLE|TRIPLE|QUADRUPLE', false, 'landscape|positioning', 'designs.masking', 'registry_direct', 1.0, 'not_required', 'public', 'Registry counts masked roles; compare open label vs blinded (is_blinded) first'),
  ('design.is_blinded',              'Blinded',                   'trial',                    'is_blinded',              'masking_status',         'boolean', NULL,           NULL, false, 'landscape|positioning', 'designs.masking',                 'registry_derived', 1.0, 'not_required', 'public', 'masking <> NONE'),
  ('design.enrollment',              'Enrollment size',           'trial',                    'enrollment',              'enrollment_status',      'number',  'participants', NULL, false, 'landscape|positioning', 'studies.enrollment',              'registry_direct',  1.0, 'not_required', 'public', 'Read with enrollment_type'),
  ('design.enrollment_type',         'Enrollment type',           'trial',                    'enrollment_type',         NULL,                     'string',  NULL,           'ACTUAL|ESTIMATED', false, 'landscape|positioning', 'studies.enrollment_type', 'registry_direct', 1.0, 'not_required', 'public', NULL),
  ('design.arm_count',               'Number of arms',            'trial',                    'arm_count',               'arm_count_status',       'number',  'arms',         NULL, false, 'landscape',             'studies.number_of_arms',          'registry_direct',  1.0, 'not_required', 'public', 'Missing stays missing; never counted as 0'),
  ('population.min_age_years',       'Minimum age',               'trial',                    'min_age_years',           'min_age_status',         'number',  'years',        NULL, false, 'landscape|positioning', 'eligibilities.minimum_age',       'registry_parsed',  1.0, 'not_required', 'public', 'Parsed from text like "18 Years". Blank = no lower limit = not_applicable (to confirm with Paola)'),
  ('population.max_age_years',       'Maximum age',               'trial',                    'max_age_years',           'max_age_status',         'number',  'years',        NULL, false, 'landscape|positioning', 'eligibilities.maximum_age',       'registry_parsed',  1.0, 'not_required', 'public', 'Blank = no upper limit = not_applicable'),
  ('population.sex',                 'Sex',                       'trial',                    'sex',                     NULL,                     'string',  NULL,           'ALL|FEMALE|MALE', false, 'landscape', 'eligibilities.gender', 'registry_direct', 1.0, 'not_required', 'public', NULL),
  ('eligibility.criteria_text',      'Eligibility criteria',      'trial',                    'eligibility_criteria',    NULL,                     'text',    NULL,           NULL, false, 'landscape',             'eligibilities.criteria',          'registry_direct',  1.0, 'not_required', 'public', 'Verbatim, never rewritten'),
  ('timing.start_date',              'Start date',                'trial',                    'start_date',              NULL,                     'date',    NULL,           NULL, false, 'landscape|cohort',      'studies.start_date',              'registry_parsed',  1.0, 'not_required', 'public', 'Month-only dates stored as the 1st; see start_date_precision'),
  ('timing.primary_completion_date', 'Primary completion date',   'trial',                    'primary_completion_date', NULL,                     'date',    NULL,           NULL, false, 'landscape',             'studies.primary_completion_date', 'registry_parsed',  1.0, 'not_required', 'public', NULL),
  ('arm.title',                      'Arm',                       'trial_arm',                'arm_title',               NULL,                     'string',  NULL,           NULL, true,  'landscape',             'design_groups.title',             'registry_direct',  1.0, 'not_required', 'public', NULL),
  ('arm.type',                       'Arm type',                  'trial_arm',                'arm_type',                NULL,                     'string',  NULL,           'EXPERIMENTAL|ACTIVE_COMPARATOR|PLACEBO_COMPARATOR|SHAM_COMPARATOR|NO_INTERVENTION|OTHER', true, 'landscape', 'design_groups.group_type', 'registry_direct', 1.0, 'not_required', 'public', NULL),
  ('intervention.name',              'Intervention',              'trial_intervention',       'intervention_name',       NULL,                     'string',  NULL,           NULL, true,  'landscape|cohort',      'interventions.name',              'registry_direct',  1.0, 'not_required', 'public', 'Verbatim, e.g. NEOD001'),
  ('intervention.type',              'Intervention type',         'trial_intervention',       'intervention_type',       NULL,                     'string',  NULL,           NULL, true,  'landscape|cohort',      'interventions.intervention_type', 'registry_direct',  1.0, 'not_required', 'public', NULL),
  ('intervention.normalized_name',   'Intervention (normalised)', 'trial_intervention',       'normalized_name',         NULL,                     'string',  NULL,           NULL, true,  'cohort',                'interventions.name + intervention_synonym', 'registry_derived', 0.95, 'unreviewed', 'public', 'Synonym list reviewed in J05; method per row in normalized_method'),
  ('condition.term',                 'Condition',                 'trial_condition',          'term',                    NULL,                     'string',  NULL,           NULL, true,  'landscape|cohort',      'conditions.name | browse_conditions.mesh_term', 'registry_direct', 1.0, 'not_required', 'public', 'term_source says which'),
  ('endpoint.type',                  'Endpoint level',            'trial_endpoint',           'endpoint_type',           NULL,                     'string',  NULL,           'PRIMARY|SECONDARY|OTHER', true, 'landscape|positioning', 'design_outcomes.outcome_type', 'registry_direct', 1.0, 'not_required', 'public', NULL),
  ('endpoint.measure',               'Endpoint',                  'trial_endpoint',           'measure',                 NULL,                     'text',    NULL,           NULL, true,  'landscape|positioning', 'design_outcomes.measure',         'registry_direct',  1.0, 'not_required', 'public', 'Verbatim wording'),
  ('endpoint.time_frame',            'Endpoint time frame',       'trial_endpoint',           'time_frame',              NULL,                     'text',    NULL,           NULL, true,  'landscape',             'design_outcomes.time_frame',      'registry_direct',  1.0, 'not_required', 'public', NULL),
  ('endpoint.is_composite',          'Composite endpoint',        'trial_endpoint',           'is_composite',            NULL,                     'boolean', NULL,           NULL, true,  'landscape|positioning', 'design_outcomes.measure',         'regex',            0.7, 'unreviewed',   'public', 'Word "composite" only; weak (R4)'),
  ('endpoint.component',             'Composite component',       'trial_endpoint_component', 'component',               NULL,                     'string',  NULL,           NULL, true,  'positioning',           'design_outcomes.measure',         'regex',            0.8, 'unreviewed',   'public', 'Split from "composite of ..."');

-- ---------------------------------------------------------------------
-- 3. intervention_synonym: reviewed synonym list for treatment matching
--    Read by the pipeline (trial_intervention.normalized_name).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS intervention_synonym (
  synonym          STRING    NOT NULL COMMENT 'Lower-case name as it appears in registries, e.g. neod001',
  normalized_name  STRING    NOT NULL COMMENT 'Name it maps to, e.g. birtamimab',
  evidence         STRING             COMMENT 'Where the mapping comes from',
  reviewed_by      STRING,
  reviewed_at      TIMESTAMP,
  CONSTRAINT intervention_synonym_pk PRIMARY KEY (synonym)
)
COMMENT 'Reviewed intervention synonyms (J05). One row per registry spelling.';

INSERT INTO intervention_synonym VALUES
  ('neod001', 'birtamimab', 'Prothena: NEOD001 is the development code of birtamimab', NULL, NULL);

-- ---------------------------------------------------------------------
-- 4. protocol_field: one row per value extracted from a protocol PDF
--    Written by the extraction job (A03/A05). Provenance really differs
--    per value here (page, quote, model confidence), so it is stored on
--    every row. Same field_path names and status values as the registry
--    tables, so Positioning can line them up.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS protocol_field (
  protocol_id        STRING    NOT NULL COMMENT 'e.g. VITAL',
  nct_id             STRING             COMMENT 'NCT ID when known (VITAL = NCT02312206)',
  source_doc_id      STRING    NOT NULL COMMENT 'SOURCE + VERSION: source_document id of the PDF version',
  field_path         STRING    NOT NULL COMMENT 'From field_catalog, e.g. design.enrollment',
  element_key        STRING    NOT NULL COMMENT '"" for single fields; PRIMARY:1, PRIMARY:1:C1 for endpoint parts',
  value_text         STRING             COMMENT 'Normalised value as text (controlled vocabulary where one exists)',
  value_number       DOUBLE,
  value_date         DATE,
  value_raw          STRING             COMMENT 'Verbatim text as written in the protocol',
  value_type         STRING    NOT NULL COMMENT 'string | number | date | boolean | text',
  value_status       STRING    NOT NULL COMMENT 'reported | not_applicable | ambiguous | unusable | missing',
  page_number        INT                COMMENT 'PAGE: 1-based PDF page',
  section            STRING             COMMENT 'SECTION: protocol section heading, e.g. 3.1 Study Design',
  quote              STRING             COMMENT 'Verbatim supporting text from that page',
  extraction_method  STRING    NOT NULL COMMENT 'METHOD: pdf_text_llm | pdf_table | pdf_vision_llm | regex | manual_entry',
  model_endpoint     STRING             COMMENT 'Model Serving endpoint used, from config (AC7)',
  prompt_version     STRING,
  confidence         DOUBLE             COMMENT 'CONFIDENCE: 0 to 1',
  grounding_status   STRING             COMMENT 'Automatic quote-vs-page check: verified | partially_verified | unverified | not_applicable',
  reviewer_status    STRING    NOT NULL COMMENT 'REVIEWER STATUS: unreviewed | approved | corrected | rejected',
  reviewed_by        STRING,
  reviewed_at        TIMESTAMP,
  review_note        STRING             COMMENT 'Required for corrected and rejected',
  extraction_run_id  STRING             COMMENT 'Run that produced the row',
  mlflow_trace_id    STRING             COMMENT 'MLflow trace of the extraction (AC1)',
  data_tier          STRING    NOT NULL COMMENT 'public for the VITAL protocol (posted on ClinicalTrials.gov)',
  extracted_at       TIMESTAMP NOT NULL,
  CONSTRAINT protocol_field_pk PRIMARY KEY (source_doc_id, field_path, element_key),
  CONSTRAINT protocol_field_doc_fk FOREIGN KEY (source_doc_id) REFERENCES source_document,
  CONSTRAINT protocol_field_catalog_fk FOREIGN KEY (field_path) REFERENCES field_catalog
)
COMMENT 'Values extracted from protocol PDFs, one row per value, with per-value page, quote, confidence and review.';

ALTER TABLE protocol_field ADD CONSTRAINT pf_status_ok
  CHECK (value_status IN ('reported', 'not_applicable', 'ambiguous', 'unusable', 'missing'));
ALTER TABLE protocol_field ADD CONSTRAINT pf_value_iff_reported
  CHECK ((coalesce(value_text, CAST(value_number AS STRING), CAST(value_date AS STRING)) IS NOT NULL) = (value_status = 'reported'));
ALTER TABLE protocol_field ADD CONSTRAINT pf_method_ok
  CHECK (extraction_method IN ('pdf_text_llm', 'pdf_table', 'pdf_vision_llm', 'regex', 'manual_entry'));
ALTER TABLE protocol_field ADD CONSTRAINT pf_reported_has_page
  CHECK (value_status <> 'reported' OR page_number IS NOT NULL);
ALTER TABLE protocol_field ADD CONSTRAINT pf_confidence_range
  CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1);
ALTER TABLE protocol_field ADD CONSTRAINT pf_reviewer_ok
  CHECK (reviewer_status IN ('unreviewed', 'approved', 'corrected', 'rejected'));
ALTER TABLE protocol_field ADD CONSTRAINT pf_review_has_reviewer
  CHECK (reviewer_status = 'unreviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL));
ALTER TABLE protocol_field ADD CONSTRAINT pf_change_has_note
  CHECK (reviewer_status IN ('unreviewed', 'approved') OR review_note IS NOT NULL);
ALTER TABLE protocol_field ADD CONSTRAINT pf_tier_ok
  CHECK (data_tier IN ('public', 'licensed', 'sponsor'));

-- ---------------------------------------------------------------------
-- 5. Record the AACT snapshot (one row per snapshot, by the S03 load)
-- ---------------------------------------------------------------------
-- INSERT INTO source_document VALUES
--   ('aact:<YYYYMMDD>', 'aact', 'public', '<YYYY-MM-DD>', <YYYYMMDD>, DATE'<YYYY-MM-DD>',
--    'https://aact.ctti-clinicaltrials.org/download', '<zip name>', '<sha256>', current_timestamp(), current_user());

-- ---------------------------------------------------------------------
-- 6. trial_value_provenance: one row per registry value with all six
--    provenance fields (run after the pipeline has built the tables)
--
--    A plain view: nothing stored, so it can't drift from the tables or
--    the catalog. Values become text plus value_type. Functions read the
--    typed tables; this view answers "where did this value come from?"
--    and feeds citations (A13). Keep it out of the Genie space.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW trial_value_provenance
COMMENT 'One row per registry value: value, status and the six provenance fields (source, version, page or section, method, confidence, reviewer status).'
AS
WITH values_long AS (
  SELECT t.nct_id, t.snapshot_version, t.source_doc_id, v.field_path, '' AS element_key, v.value_text, v.value_status
  FROM trial t
  LATERAL VIEW stack(19,
    'study.brief_title',              t.brief_title,                           CASE WHEN t.brief_title IS NULL THEN 'missing' ELSE 'reported' END,
    'study.lead_sponsor',             t.lead_sponsor,                          CASE WHEN t.lead_sponsor IS NULL THEN 'missing' ELSE 'reported' END,
    'study.overall_status',           t.overall_status,                        CASE WHEN t.overall_status IS NULL THEN 'missing' ELSE 'reported' END,
    'study.study_type',               t.study_type,                            CASE WHEN t.study_type IS NULL THEN 'missing' ELSE 'reported' END,
    'design.phase',                   t.phase,                                 t.phase_status,
    'design.primary_purpose',         t.primary_purpose,                       t.primary_purpose_status,
    'design.allocation',              t.allocation,                            t.allocation_status,
    'design.intervention_model',      t.intervention_model,                    CASE WHEN t.intervention_model IS NULL THEN 'missing' ELSE 'reported' END,
    'design.masking',                 t.masking,                               t.masking_status,
    'design.is_blinded',              CAST(t.is_blinded AS STRING),            t.masking_status,
    'design.enrollment',              CAST(t.enrollment AS STRING),            t.enrollment_status,
    'design.enrollment_type',         t.enrollment_type,                       CASE WHEN t.enrollment_type IS NULL THEN 'missing' ELSE 'reported' END,
    'design.arm_count',               CAST(t.arm_count AS STRING),             t.arm_count_status,
    'population.min_age_years',       CAST(t.min_age_years AS STRING),         t.min_age_status,
    'population.max_age_years',       CAST(t.max_age_years AS STRING),         t.max_age_status,
    'population.sex',                 t.sex,                                   CASE WHEN t.sex IS NULL THEN 'missing' ELSE 'reported' END,
    'eligibility.criteria_text',      t.eligibility_criteria,                  CASE WHEN t.eligibility_criteria IS NULL THEN 'missing' ELSE 'reported' END,
    'timing.start_date',              CAST(t.start_date AS STRING),            CASE WHEN t.start_date IS NULL THEN 'missing' ELSE 'reported' END,
    'timing.primary_completion_date', CAST(t.primary_completion_date AS STRING), CASE WHEN t.primary_completion_date IS NULL THEN 'missing' ELSE 'reported' END
  ) v AS field_path, value_text, value_status
  UNION ALL
  SELECT a.nct_id, a.snapshot_version, t.source_doc_id, v.field_path, a.arm_key, v.value_text, 'reported'
  FROM trial_arm a JOIN trial t USING (nct_id, snapshot_version)
  LATERAL VIEW stack(2, 'arm.title', a.arm_title, 'arm.type', a.arm_type) v AS field_path, value_text
  UNION ALL
  SELECT i.nct_id, i.snapshot_version, t.source_doc_id, v.field_path, i.intervention_key, v.value_text, 'reported'
  FROM trial_intervention i JOIN trial t USING (nct_id, snapshot_version)
  LATERAL VIEW stack(3, 'intervention.name', i.intervention_name, 'intervention.type', i.intervention_type,
                        'intervention.normalized_name', i.normalized_name) v AS field_path, value_text
  UNION ALL
  SELECT c.nct_id, c.snapshot_version, t.source_doc_id, 'condition.term', c.condition_key, c.term, 'reported'
  FROM trial_condition c JOIN trial t USING (nct_id, snapshot_version)
  UNION ALL
  SELECT e.nct_id, e.snapshot_version, t.source_doc_id, v.field_path, e.endpoint_key, v.value_text, 'reported'
  FROM trial_endpoint e JOIN trial t USING (nct_id, snapshot_version)
  LATERAL VIEW stack(4, 'endpoint.type', e.endpoint_type, 'endpoint.measure', e.measure,
                        'endpoint.time_frame', e.time_frame, 'endpoint.is_composite', CAST(e.is_composite AS STRING)) v AS field_path, value_text
  UNION ALL
  SELECT p.nct_id, p.snapshot_version, t.source_doc_id, 'endpoint.component',
         concat(p.endpoint_key, ':C', p.component_no), p.component, 'reported'
  FROM trial_endpoint_component p JOIN trial t USING (nct_id, snapshot_version)
)
SELECT
  v.nct_id, v.snapshot_version, v.field_path, v.element_key,
  v.value_text, c.value_type, v.value_status,
  d.source_system,                                         -- SOURCE
  v.source_doc_id,
  d.source_version,                                        -- VERSION
  concat('AACT ', c.aact_source, ', ', v.nct_id) AS page_or_section, -- PAGE OR SECTION
  CASE WHEN v.field_path = 'intervention.normalized_name'
       THEN i.normalized_method ELSE c.extraction_method END AS extraction_method, -- METHOD
  CASE WHEN v.field_path = 'intervention.normalized_name' AND i.normalized_method = 'registry_direct'
       THEN 1.0 ELSE c.default_confidence END AS confidence,               -- CONFIDENCE
  CASE WHEN v.field_path = 'intervention.normalized_name' AND i.normalized_method = 'registry_direct'
       THEN 'not_required' ELSE c.default_reviewer_status END AS reviewer_status, -- REVIEWER STATUS
  d.data_tier
FROM values_long v
JOIN field_catalog c        ON c.field_path = v.field_path
LEFT JOIN source_document d ON d.source_doc_id = v.source_doc_id
LEFT JOIN trial_intervention i
  ON v.field_path = 'intervention.normalized_name'
 AND i.nct_id = v.nct_id AND i.snapshot_version = v.snapshot_version AND i.intervention_key = v.element_key;
