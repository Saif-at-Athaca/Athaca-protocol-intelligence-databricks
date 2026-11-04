-- =====================================================================
-- PI on Databricks POC: silver trial model pipeline (A02 design, built
-- and tested in A06)
--
-- Lakeflow Spark Declarative Pipeline (SQL), serverless. Target: catalog
-- pi, schema silver. Reads the AACT tables in pi.bronze and builds one
-- typed table per part of a trial. Everything here is a materialized view:
-- pipeline-owned, rebuilt from bronze, never edited by hand.
--
-- Rules this file follows (see docs/trial-model-schema.md):
--   * Every bronze row carries snapshot_version (YYYYMMDD, BIGINT) and
--     bronze is append-only (S03). Every silver key includes
--     snapshot_version, so a second AACT snapshot adds rows instead of
--     replacing them.
--   * A value is filled only when its status is 'reported'. Missing is
--     never 0. Status values: reported | not_applicable | ambiguous |
--     unusable | missing.
--   * Expectations only warn: a bad value becomes status 'unusable' and
--     stays in the table, so coverage ("N of M reporting") stays honest.
--   * Repeated elements (arms, interventions, conditions, endpoints) are
--     keyed by their natural values, not AACT's surrogate ids, which may
--     be regenerated between snapshots (to confirm on the S02 snapshot).
--   * Allowed-value lists below must match pi.silver.field_catalog.
--
-- Syntax follows the Lakeflow SQL reference. Not yet run: confirm in A06,
-- especially table constraints on materialized views.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. trial: one row per trial per snapshot
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW trial (
  nct_id                   STRING  NOT NULL COMMENT 'ClinicalTrials.gov NCT ID, e.g. NCT02312206',
  snapshot_version         BIGINT  NOT NULL COMMENT 'AACT snapshot this row comes from (YYYYMMDD)',
  source_doc_id            STRING  NOT NULL COMMENT 'pi.silver.source_document id of the AACT snapshot, e.g. aact:20261101',
  data_tier                STRING  NOT NULL COMMENT 'public | licensed | sponsor. Always public for AACT',

  brief_title              STRING           COMMENT 'Trial title (AACT studies.brief_title)',
  lead_sponsor             STRING           COMMENT 'Lead sponsor name (AACT studies.source)',
  overall_status           STRING           COMMENT 'Recruitment status, e.g. COMPLETED, TERMINATED',
  study_type               STRING           COMMENT 'INTERVENTIONAL | OBSERVATIONAL | EXPANDED_ACCESS',

  phase                    STRING           COMMENT 'Trial phase as registered, e.g. PHASE3, PHASE2/PHASE3. NULL unless phase_status = reported',
  phase_status             STRING  NOT NULL COMMENT 'Value status of phase',
  primary_purpose          STRING           COMMENT 'TREATMENT, DIAGNOSTIC, SUPPORTIVE_CARE, ... Feeds the diagnostic fallback (D3)',
  primary_purpose_status   STRING  NOT NULL,
  allocation               STRING           COMMENT 'RANDOMIZED | NON_RANDOMIZED | NA',
  allocation_status        STRING  NOT NULL,
  intervention_model       STRING           COMMENT 'SINGLE_GROUP | PARALLEL | CROSSOVER | FACTORIAL | SEQUENTIAL',
  masking                  STRING           COMMENT 'Blinding as registered: NONE | SINGLE | DOUBLE | TRIPLE | QUADRUPLE (number of masked roles)',
  masking_status           STRING  NOT NULL COMMENT 'Value status of masking (Positioning field)',
  is_blinded               BOOLEAN          COMMENT 'Derived: masking <> NONE. Compare open label vs blinded first; protocols say "double-blind" loosely',
  masked_participant       BOOLEAN,
  masked_care_provider     BOOLEAN,
  masked_investigator      BOOLEAN,
  masked_outcomes_assessor BOOLEAN,

  enrollment               INT              COMMENT 'Enrollment (participants). NULL unless enrollment_status = reported; never 0 for missing',
  enrollment_type          STRING           COMMENT 'ACTUAL | ESTIMATED. Shown next to enrollment, never mixed silently',
  enrollment_status        STRING  NOT NULL COMMENT 'Value status of enrollment (Positioning field)',
  arm_count                INT              COMMENT 'Number of arms as registered (AACT studies.number_of_arms)',
  arm_count_status         STRING  NOT NULL,

  min_age_years            DOUBLE           COMMENT 'Minimum age in years, parsed from text like "18 Years"; months and weeks converted',
  min_age_raw              STRING           COMMENT 'Verbatim AACT eligibilities.minimum_age',
  min_age_status           STRING  NOT NULL COMMENT 'Blank in the registry = no lower limit = not_applicable (to confirm with Paola)',
  max_age_years            DOUBLE           COMMENT 'Maximum age in years',
  max_age_raw              STRING           COMMENT 'Verbatim AACT eligibilities.maximum_age',
  max_age_status           STRING  NOT NULL COMMENT 'Blank in the registry = no upper limit = not_applicable',
  sex                      STRING           COMMENT 'ALL | FEMALE | MALE',
  eligibility_criteria     STRING           COMMENT 'Verbatim eligibility criteria text, never rewritten',

  start_date               DATE             COMMENT 'Study start. Month-only dates are stored as the 1st of the month',
  start_date_precision     STRING           COMMENT 'day | month',
  primary_completion_date  DATE,

  CONSTRAINT trial_pk PRIMARY KEY (nct_id, snapshot_version),

  -- warn-only checks: the update continues, the violation is recorded
  CONSTRAINT phase_value_iff_reported      EXPECT ((phase IS NOT NULL) = (phase_status = 'reported')),
  CONSTRAINT masking_value_iff_reported    EXPECT ((masking IS NOT NULL) = (masking_status = 'reported')),
  CONSTRAINT enrollment_value_iff_reported EXPECT ((enrollment IS NOT NULL) = (enrollment_status = 'reported')),
  CONSTRAINT min_age_value_iff_reported    EXPECT ((min_age_years IS NOT NULL) = (min_age_status = 'reported')),
  CONSTRAINT max_age_value_iff_reported    EXPECT ((max_age_years IS NOT NULL) = (max_age_status = 'reported')),
  CONSTRAINT enrollment_not_negative       EXPECT (enrollment IS NULL OR enrollment >= 0),
  CONSTRAINT age_range_ordered             EXPECT (min_age_years IS NULL OR max_age_years IS NULL OR min_age_years <= max_age_years)
)
CLUSTER BY (nct_id)
COMMENT 'Trial model, one row per trial per AACT snapshot. Each Positioning and coverage field has a <field>_status column.'
AS
WITH e AS (
  SELECT
    nct_id, snapshot_version, gender, criteria, minimum_age, maximum_age,
    try_cast(regexp_extract(minimum_age, r'^\s*([0-9]+(?:\.[0-9]+)?)', 1) AS DOUBLE) AS min_n,
    lower(regexp_extract(minimum_age, r'(?i)(year|month|week|day|hour|minute)', 1))  AS min_u,
    try_cast(regexp_extract(maximum_age, r'^\s*([0-9]+(?:\.[0-9]+)?)', 1) AS DOUBLE) AS max_n,
    lower(regexp_extract(maximum_age, r'(?i)(year|month|week|day|hour|minute)', 1))  AS max_u
  FROM pi.bronze.eligibilities
),
ages AS (
  SELECT *,
    round(min_n * CASE min_u WHEN 'year' THEN 1 WHEN 'month' THEN 1/12 WHEN 'week' THEN 1/52.1775
                             WHEN 'day' THEN 1/365.25 WHEN 'hour' THEN 1/8766 WHEN 'minute' THEN 1/525960 END, 2) AS min_years,
    round(max_n * CASE max_u WHEN 'year' THEN 1 WHEN 'month' THEN 1/12 WHEN 'week' THEN 1/52.1775
                             WHEN 'day' THEN 1/365.25 WHEN 'hour' THEN 1/8766 WHEN 'minute' THEN 1/525960 END, 2) AS max_years
  FROM e
),
base AS (
  SELECT
    s.nct_id, s.snapshot_version,
    s.brief_title, s.source AS lead_sponsor, s.overall_status, s.study_type,
    nullif(trim(s.phase), '')            AS phase_v,
    nullif(trim(d.primary_purpose), '')  AS purpose_v,
    nullif(trim(d.allocation), '')       AS allocation_v,
    nullif(trim(d.intervention_model), '') AS model_v,
    nullif(trim(d.masking), '')          AS masking_v,
    try_cast(d.subject_masked AS BOOLEAN)           AS masked_participant,
    try_cast(d.caregiver_masked AS BOOLEAN)         AS masked_care_provider,
    try_cast(d.investigator_masked AS BOOLEAN)      AS masked_investigator,
    try_cast(d.outcomes_assessor_masked AS BOOLEAN) AS masked_outcomes_assessor,
    s.enrollment AS enrollment_raw, try_cast(s.enrollment AS INT) AS enrollment_v,
    nullif(trim(s.enrollment_type), '')  AS enrollment_type,
    try_cast(s.number_of_arms AS INT)    AS arms_v,
    a.minimum_age, a.min_years, a.maximum_age, a.max_years,
    nullif(trim(a.gender), '')           AS sex,
    a.criteria,
    coalesce(try_to_date(s.start_date, 'yyyy-MM-dd'), try_to_date(s.start_date, 'yyyy-MM')) AS start_date,
    CASE WHEN try_to_date(s.start_date, 'yyyy-MM-dd') IS NOT NULL THEN 'day'
         WHEN try_to_date(s.start_date, 'yyyy-MM') IS NOT NULL THEN 'month' END AS start_date_precision,
    coalesce(try_to_date(s.primary_completion_date, 'yyyy-MM-dd'), try_to_date(s.primary_completion_date, 'yyyy-MM')) AS primary_completion_date
  FROM pi.bronze.studies s
  LEFT JOIN pi.bronze.designs d USING (nct_id, snapshot_version)
  LEFT JOIN ages a              USING (nct_id, snapshot_version)
),
statused AS (
  SELECT *,
    CASE WHEN phase_v IS NULL THEN 'missing'
         WHEN phase_v IN ('EARLY_PHASE1','PHASE1','PHASE1/PHASE2','PHASE2','PHASE2/PHASE3','PHASE3','PHASE4','NA') THEN 'reported'
         ELSE 'unusable' END AS phase_status,
    CASE WHEN purpose_v IS NULL THEN 'missing'
         WHEN purpose_v IN ('TREATMENT','PREVENTION','DIAGNOSTIC','SUPPORTIVE_CARE','SCREENING','HEALTH_SERVICES_RESEARCH',
                            'BASIC_SCIENCE','DEVICE_FEASIBILITY','OTHER') THEN 'reported'
         ELSE 'unusable' END AS primary_purpose_status,
    CASE WHEN allocation_v IS NULL THEN 'missing'
         WHEN allocation_v IN ('RANDOMIZED','NON_RANDOMIZED','NA') THEN 'reported'
         ELSE 'unusable' END AS allocation_status,
    CASE WHEN masking_v IS NULL THEN 'missing'
         WHEN masking_v IN ('NONE','SINGLE','DOUBLE','TRIPLE','QUADRUPLE') THEN 'reported'
         ELSE 'unusable' END AS masking_status,
    CASE WHEN nullif(trim(enrollment_raw), '') IS NULL THEN 'missing'
         WHEN enrollment_v IS NOT NULL AND enrollment_v >= 0 THEN 'reported'
         ELSE 'unusable' END AS enrollment_status,
    CASE WHEN arms_v IS NULL THEN 'missing' ELSE 'reported' END AS arm_count_status,
    CASE WHEN nullif(trim(minimum_age), '') IS NULL OR upper(trim(minimum_age)) = 'N/A' THEN 'not_applicable'
         WHEN min_years IS NULL THEN 'unusable' ELSE 'reported' END AS min_age_status,
    CASE WHEN nullif(trim(maximum_age), '') IS NULL OR upper(trim(maximum_age)) = 'N/A' THEN 'not_applicable'
         WHEN max_years IS NULL THEN 'unusable' ELSE 'reported' END AS max_age_status
  FROM base
)
SELECT
  nct_id, snapshot_version,
  concat('aact:', snapshot_version)                                      AS source_doc_id,
  'public'                                                               AS data_tier,
  brief_title, lead_sponsor, overall_status, study_type,
  CASE WHEN phase_status = 'reported' THEN phase_v END                   AS phase,            phase_status,
  CASE WHEN primary_purpose_status = 'reported' THEN purpose_v END       AS primary_purpose,  primary_purpose_status,
  CASE WHEN allocation_status = 'reported' THEN allocation_v END         AS allocation,       allocation_status,
  model_v                                                                AS intervention_model,
  CASE WHEN masking_status = 'reported' THEN masking_v END               AS masking,          masking_status,
  CASE WHEN masking_status = 'reported' THEN masking_v <> 'NONE' END     AS is_blinded,
  masked_participant, masked_care_provider, masked_investigator, masked_outcomes_assessor,
  CASE WHEN enrollment_status = 'reported' THEN enrollment_v END         AS enrollment,
  enrollment_type,                                                                            enrollment_status,
  CASE WHEN arm_count_status = 'reported' THEN arms_v END                AS arm_count,        arm_count_status,
  CASE WHEN min_age_status = 'reported' THEN min_years END               AS min_age_years,
  minimum_age                                                            AS min_age_raw,      min_age_status,
  CASE WHEN max_age_status = 'reported' THEN max_years END               AS max_age_years,
  maximum_age                                                            AS max_age_raw,      max_age_status,
  sex,
  criteria                                                               AS eligibility_criteria,
  start_date, start_date_precision, primary_completion_date
FROM statused;

-- ---------------------------------------------------------------------
-- 2. trial_arm: one row per arm
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW trial_arm (
  nct_id            STRING NOT NULL,
  snapshot_version  BIGINT NOT NULL,
  arm_key           STRING NOT NULL COMMENT 'Natural key: lower-case arm title (#n added if a trial repeats a title)',
  arm_title         STRING          COMMENT 'Verbatim arm title (AACT design_groups.title)',
  arm_type          STRING          COMMENT 'EXPERIMENTAL | ACTIVE_COMPARATOR | PLACEBO_COMPARATOR | SHAM_COMPARATOR | NO_INTERVENTION | OTHER',
  arm_description   STRING,
  CONSTRAINT trial_arm_pk PRIMARY KEY (nct_id, snapshot_version, arm_key),
  CONSTRAINT trial_arm_trial_fk FOREIGN KEY (nct_id, snapshot_version) REFERENCES trial,
  CONSTRAINT arm_type_allowed EXPECT (arm_type IN ('EXPERIMENTAL','ACTIVE_COMPARATOR','PLACEBO_COMPARATOR','SHAM_COMPARATOR','NO_INTERVENTION','OTHER'))
)
COMMENT 'Arms of each trial, one row per arm per snapshot.'
AS SELECT
  nct_id, snapshot_version,
  concat(lower(trim(title)),
         CASE WHEN n > 1 THEN concat('#', n) ELSE '' END) AS arm_key,
  title AS arm_title, group_type AS arm_type, description AS arm_description
FROM (
  SELECT *, row_number() OVER (PARTITION BY nct_id, snapshot_version, lower(trim(title)) ORDER BY title, description) AS n
  FROM pi.bronze.design_groups
);

-- ---------------------------------------------------------------------
-- 3. trial_intervention: one row per intervention
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW trial_intervention (
  nct_id                   STRING NOT NULL,
  snapshot_version         BIGINT NOT NULL,
  intervention_key         STRING NOT NULL COMMENT 'Natural key: <type>:<lower-case name>',
  intervention_name        STRING          COMMENT 'Verbatim name, e.g. NEOD001',
  intervention_type        STRING          COMMENT 'DRUG | BIOLOGICAL | DEVICE | ...',
  normalized_name          STRING          COMMENT 'Synonym-resolved name for treatment matching, e.g. birtamimab',
  normalized_method        STRING          COMMENT 'registry_direct (name as written) | registry_derived (from the reviewed synonym list)',
  intervention_description STRING,
  CONSTRAINT trial_intervention_pk PRIMARY KEY (nct_id, snapshot_version, intervention_key),
  CONSTRAINT trial_intervention_trial_fk FOREIGN KEY (nct_id, snapshot_version) REFERENCES trial
)
COMMENT 'Interventions of each trial, with a normalised name for comparable-trial matching (A08).'
AS SELECT
  i.nct_id, i.snapshot_version,
  concat(upper(i.intervention_type), ':', lower(trim(i.name)),
         CASE WHEN i.n > 1 THEN concat('#', i.n) ELSE '' END) AS intervention_key,
  i.name AS intervention_name, i.intervention_type,
  coalesce(syn.normalized_name, lower(trim(i.name)))           AS normalized_name,
  CASE WHEN syn.normalized_name IS NULL THEN 'registry_direct' ELSE 'registry_derived' END AS normalized_method,
  i.description AS intervention_description
FROM (
  SELECT *, row_number() OVER (PARTITION BY nct_id, snapshot_version, upper(intervention_type), lower(trim(name))
                               ORDER BY description) AS n
  FROM pi.bronze.interventions
) i
LEFT JOIN pi.silver.intervention_synonym syn ON syn.synonym = lower(trim(i.name));

-- ---------------------------------------------------------------------
-- 4. trial_condition: one row per condition term (free text or MeSH)
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW trial_condition (
  nct_id            STRING NOT NULL,
  snapshot_version  BIGINT NOT NULL,
  condition_key     STRING NOT NULL COMMENT 'Natural key: COND:<lower-case name> or MESH:<lower-case MeSH term>',
  term              STRING          COMMENT 'Verbatim condition name or MeSH term',
  term_source       STRING NOT NULL COMMENT 'conditions (as registered) | browse_conditions (MeSH, mesh-list only)',
  CONSTRAINT trial_condition_pk PRIMARY KEY (nct_id, snapshot_version, condition_key),
  CONSTRAINT trial_condition_trial_fk FOREIGN KEY (nct_id, snapshot_version) REFERENCES trial
)
COMMENT 'Conditions of each trial: registered names plus MeSH terms. build_cohort matches these against a reviewed term list.'
AS
SELECT DISTINCT nct_id, snapshot_version, concat('COND:', lower(trim(name))) AS condition_key,
       name AS term, 'conditions' AS term_source
FROM pi.bronze.conditions
UNION ALL
SELECT DISTINCT nct_id, snapshot_version, concat('MESH:', lower(trim(mesh_term))) AS condition_key,
       mesh_term AS term, 'browse_conditions' AS term_source
FROM pi.bronze.browse_conditions
WHERE mesh_type = 'mesh-list';

-- ---------------------------------------------------------------------
-- 5. trial_endpoint: one row per registered outcome
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW trial_endpoint (
  nct_id            STRING  NOT NULL,
  snapshot_version  BIGINT  NOT NULL,
  endpoint_key      STRING  NOT NULL COMMENT 'Natural key: <type>:<first 12 hex of sha2(lower-case measure)>. A reworded endpoint is a new endpoint',
  endpoint_type     STRING           COMMENT 'PRIMARY | SECONDARY | OTHER',
  measure           STRING           COMMENT 'Verbatim endpoint wording (Positioning field for PRIMARY)',
  time_frame        STRING,
  endpoint_description STRING,
  is_composite      BOOLEAN NOT NULL COMMENT 'Composite endpoint. Detected by the word "composite" only (weak; reviewer_status unreviewed). A composite stays ONE endpoint (R4)',
  CONSTRAINT trial_endpoint_pk PRIMARY KEY (nct_id, snapshot_version, endpoint_key),
  CONSTRAINT trial_endpoint_trial_fk FOREIGN KEY (nct_id, snapshot_version) REFERENCES trial,
  CONSTRAINT endpoint_type_allowed EXPECT (endpoint_type IN ('PRIMARY','SECONDARY','OTHER'))
)
COMMENT 'Registered outcomes of each trial, one row per endpoint per snapshot.'
AS SELECT DISTINCT
  nct_id, snapshot_version,
  concat(outcome_type, ':', substr(sha2(lower(trim(measure)), 256), 1, 12)) AS endpoint_key,
  outcome_type AS endpoint_type, measure, time_frame, description AS endpoint_description,
  coalesce(measure RLIKE '(?i)composite', false) AS is_composite
FROM pi.bronze.design_outcomes;

-- ---------------------------------------------------------------------
-- 6. trial_endpoint_component: one row per part of a composite endpoint
-- ---------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW trial_endpoint_component (
  nct_id            STRING NOT NULL,
  snapshot_version  BIGINT NOT NULL,
  endpoint_key      STRING NOT NULL,
  component_no      INT    NOT NULL COMMENT '1, 2, ... in the order written',
  component         STRING          COMMENT 'Component text split from the measure, e.g. All-cause Mortality',
  CONSTRAINT trial_endpoint_component_pk PRIMARY KEY (nct_id, snapshot_version, endpoint_key, component_no),
  CONSTRAINT component_endpoint_fk FOREIGN KEY (nct_id, snapshot_version, endpoint_key) REFERENCES trial_endpoint
)
COMMENT 'Parts of composite endpoints, split by a regex on "composite of ...". Unreviewed; checked against A04 for VITAL.'
AS SELECT
  e.nct_id, e.snapshot_version, e.endpoint_key,
  p.pos + 1 AS component_no, trim(p.part) AS component
FROM trial_endpoint e
LATERAL VIEW posexplode(
  split(regexp_extract(e.measure, r'(?i)composite of (.+)$', 1), r',\s*|\s+or\s+|\s+and\s+')
) p AS pos, part
WHERE e.is_composite AND regexp_extract(e.measure, r'(?i)composite of (.+)$', 1) <> '';
