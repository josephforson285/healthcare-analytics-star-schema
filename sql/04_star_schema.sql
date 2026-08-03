-- =====================================================================
-- 04_star_schema.sql
-- Dimensional model (Kimball star schema) for healthcare analytics.
--
-- Grain: ONE ROW PER ENCOUNTER in fact_encounters.
-- Rationale for every choice here is in docs/design_decisions.txt.
--
-- All six dimensions from the brief's Part 3.2 table list are built:
--   dim_date, dim_patient, dim_provider, dim_specialty,
--   dim_department, dim_encounter_type
--
-- Plus two the brief invites ("Others? diagnoses? procedures?") and the
-- bridge tables require:
--   dim_diagnosis, dim_procedure
--
-- One deliberate difference from the brief's column hints:
--   age_group ........... on the fact row, not dim_patient. Age changes
--                         with the calendar rather than with any source
--                         event, so an SCD mechanism driven by source
--                         changes would never fire for it and the stored
--                         value would rot. Age at the time of care is a
--                         property of the ENCOUNTER.
--
-- Note on dim_specialty: it is joined DIRECTLY FROM THE FACT via
-- specialty_key. specialty_name is also denormalised onto dim_provider.
-- Both are one hop from the fact, so neither path is a snowflake.
-- =====================================================================

DROP DATABASE IF EXISTS healthcare_dw;
CREATE DATABASE healthcare_dw
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;
USE healthcare_dw;


-- =====================================================================
-- DIMENSIONS
-- =====================================================================

-- ---------------------------------------------------------------------
-- dim_date -- one row per calendar day, 2023-01-01 .. 2025-12-31.
--
-- Exists so that DATE_FORMAT(encounter_date,'%Y-%m') -- which Q1 and Q4
-- recompute for 300,000 rows on every execution -- is computed once per
-- DAY at load time instead. Also supplies calendar attributes SQL cannot
-- derive on its own as the warehouse grows.
--
-- date_key is YYYYMMDD as an integer: human-readable in raw fact rows,
-- sorts correctly, and joins faster than a DATE.
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key        INT         NOT NULL PRIMARY KEY,   -- 20240612
    full_date       DATE        NOT NULL,
    year            SMALLINT    NOT NULL,
    quarter         TINYINT     NOT NULL,
    quarter_name    CHAR(2)     NOT NULL,               -- 'Q2'
    month           TINYINT     NOT NULL,
    month_name      VARCHAR(10) NOT NULL,
    month_abbr      CHAR(3)     NOT NULL,
    calendar_month  CHAR(7)     NOT NULL,               -- '2024-06'
    day_of_month    TINYINT     NOT NULL,
    day_of_week     TINYINT     NOT NULL,               -- 1=Monday
    day_name        VARCHAR(10) NOT NULL,
    day_of_year     SMALLINT    NOT NULL,
    week_of_year    TINYINT     NOT NULL,
    is_weekend      TINYINT     NOT NULL,
    UNIQUE KEY uq_full_date (full_date),
    KEY idx_calendar_month (calendar_month),
    KEY idx_year_quarter (year, quarter)
) ENGINE=InnoDB COMMENT='Calendar dimension; one row per day';

-- ---------------------------------------------------------------------
-- dim_patient -- SCD Type 2.
--
-- Age is NOT stored here. A patient's age band changes with the calendar
-- rather than with any source event, so a stored band would silently go
-- stale and corrupt historical reporting. Age at the time of care lives
-- on the fact row.
-- ---------------------------------------------------------------------
CREATE TABLE dim_patient (
    patient_key     INT AUTO_INCREMENT PRIMARY KEY,     -- surrogate
    patient_id      INT          NOT NULL,              -- natural key
    mrn             VARCHAR(20),
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    full_name       VARCHAR(201),
    date_of_birth   DATE,
    gender          CHAR(1),
    gender_desc     VARCHAR(10),
    -- SCD Type 2 machinery
    effective_from  DATE         NOT NULL DEFAULT '1900-01-01',
    effective_to    DATE         NOT NULL DEFAULT '9999-12-31',
    is_current      TINYINT      NOT NULL DEFAULT 1,
    row_hash        CHAR(32),        -- change detection; the source has no
                                     -- updated_at, so we compare content
    KEY idx_patient_id (patient_id),
    KEY idx_current (patient_id, is_current)
) ENGINE=InnoDB COMMENT='Patient dimension, SCD Type 2';

-- ---------------------------------------------------------------------
-- dim_provider -- SCD Type 2. Holds the provider's OWN attributes only.
--
-- specialty_name, specialty_code and home_department_name were originally
-- carried here as well, denormalised, on the argument that a query already
-- joining dim_provider would then avoid a second join. That argument was
-- wrong, and it is worth recording why.
--
-- The fact table carries provider_key, specialty_key AND department_key
-- independently. So a query wanting all three names joins all three
-- dimensions DIRECTLY off the fact -- one hop each. There was never a
-- "second hop" to save, which means the duplicated columns removed no
-- join at all. They were redundancy, not denormalisation.
--
-- Those are different things and only one of them is a Kimball pattern:
--     collapsing a HIERARCHY into ONE dimension   -> removes real joins
--     the SAME attribute in TWO dimensions        -> removes nothing
-- The test is simply whether the duplicate copy eliminates a join. Here
-- it did not.
--
-- It also actively drifted. The SCD2 hash below covers specialty_ID, not
-- specialty_NAME, so renaming a specialty in the source left this table
-- stale while dim_specialty updated -- two tables giving two different
-- answers to the same question, with no error raised.
--
-- specialty_id and home_department_id are KEPT. They earn their place in
-- the change-detection hash: a provider genuinely moving specialty or
-- department is a real historical event that must create a new version.
-- It is the redundant LABELS that are gone, not the relationships.
-- ---------------------------------------------------------------------
CREATE TABLE dim_provider (
    provider_key         INT AUTO_INCREMENT PRIMARY KEY,
    provider_id          INT          NOT NULL,
    first_name           VARCHAR(100),
    last_name            VARCHAR(100),
    full_name            VARCHAR(220),
    credential           VARCHAR(20),
    -- relationships kept for SCD2 change detection; names live in their
    -- own dimensions (dim_specialty, dim_department)
    specialty_id         INT,
    home_department_id   INT,
    effective_from       DATE    NOT NULL DEFAULT '1900-01-01',
    effective_to         DATE    NOT NULL DEFAULT '9999-12-31',
    is_current           TINYINT NOT NULL DEFAULT 1,
    row_hash             CHAR(32),
    KEY idx_provider_id (provider_id),
    KEY idx_current (provider_id, is_current)
) ENGINE=InnoDB COMMENT='Provider dimension, SCD Type 2; own attributes only';

-- ---------------------------------------------------------------------
-- dim_department -- SCD Type 1.
--
-- Kept separate from dim_provider even though a provider carries a home
-- department, because they answer different questions: where the care
-- happened (a property of the encounter, with its own FK on the source
-- table) versus where the clinician belongs. Identical in the current
-- data, but merging them would make a cardiologist covering an ER shift
-- unrepresentable.
-- ---------------------------------------------------------------------
CREATE TABLE dim_department (
    department_key   INT AUTO_INCREMENT PRIMARY KEY,
    department_id    INT NOT NULL,
    department_name  VARCHAR(100),
    floor            INT,
    capacity         INT,
    KEY idx_department_id (department_id)
) ENGINE=InnoDB COMMENT='Department dimension (SCD Type 1)';

-- ---------------------------------------------------------------------
-- dim_specialty -- as specified in the brief's Part 3.2 table list.
--
-- IMPORTANT: this is joined DIRECTLY FROM THE FACT via specialty_key, not
-- from dim_provider. That distinction is what keeps the model a star
-- rather than a snowflake:
--
--     star      fact -> dim_specialty          (what this is)
--     snowflake fact -> dim_provider -> dim_specialty   (what to avoid)
--
-- specialty_name is ALSO carried on dim_provider, deliberately. The
-- duplication is the trade dimensional modelling makes on purpose: a
-- query already joining dim_provider can read the specialty without a
-- second join, while a query that only needs specialty can join this
-- 12-row table directly and skip dim_provider entirely. Both paths are
-- one hop from the fact. Storing one VARCHAR twice across 12 and 60 rows
-- costs a few kilobytes and removes a join from either direction.
-- ---------------------------------------------------------------------
CREATE TABLE dim_specialty (
    specialty_key    INT AUTO_INCREMENT PRIMARY KEY,
    specialty_id     INT NOT NULL,
    specialty_name   VARCHAR(100),
    specialty_code   VARCHAR(10),
    KEY idx_specialty_id (specialty_id),
    KEY idx_specialty_name (specialty_name)
) ENGINE=InnoDB COMMENT='Specialty dimension; joined directly from the fact';

-- ---------------------------------------------------------------------
-- dim_encounter_type -- as specified in the brief's Part 3.2 table list.
--
-- Only three rows ('Outpatient', 'Inpatient', 'ER'). A dimension this
-- small earns its keep in two ways rather than by being large:
--
--   1. It closes the attribute domain. The source column is a free-text
--      VARCHAR(50) with no CHECK constraint (finding B4), so 'ER', 'er'
--      and 'Emergency' are all storable. A foreign key to a three-row
--      table makes a fourth value impossible rather than merely unlikely.
--   2. It gives the type somewhere to grow attributes -- is_emergency,
--      is_overnight, typical_duration_band -- that have no home when the
--      type is just a string on the fact row.
--
-- encounter_type is ALSO retained as a text column on the fact, same
-- reasoning as specialty above: existing queries keep working without a
-- join, and the FK is there when the dimension's attributes are wanted.
-- ---------------------------------------------------------------------
CREATE TABLE dim_encounter_type (
    encounter_type_key  INT AUTO_INCREMENT PRIMARY KEY,
    type_name           VARCHAR(20) NOT NULL,
    is_emergency        TINYINT     NOT NULL DEFAULT 0,
    is_overnight        TINYINT     NOT NULL DEFAULT 0,
    UNIQUE KEY uq_type_name (type_name)
) ENGINE=InnoDB COMMENT='Encounter type dimension (Outpatient/Inpatient/ER)';

-- ---------------------------------------------------------------------
-- dim_diagnosis / dim_procedure -- required by the bridges.
--
-- icd10_chapter and cpt_category are derived at load time. They cost
-- nothing at 40 and 30 rows and give analysts a roll-up level the source
-- system has no table for.
-- ---------------------------------------------------------------------
CREATE TABLE dim_diagnosis (
    diagnosis_key      INT AUTO_INCREMENT PRIMARY KEY,
    diagnosis_id       INT NOT NULL,
    icd10_code         VARCHAR(10),
    icd10_description  VARCHAR(200),
    icd10_chapter      VARCHAR(60),      -- derived from the leading letter
    KEY idx_diagnosis_id (diagnosis_id),
    KEY idx_icd10 (icd10_code)
) ENGINE=InnoDB COMMENT='Diagnosis (ICD-10) dimension';

CREATE TABLE dim_procedure (
    procedure_key      INT AUTO_INCREMENT PRIMARY KEY,
    procedure_id       INT NOT NULL,
    cpt_code           VARCHAR(10),
    cpt_description    VARCHAR(200),
    cpt_category       VARCHAR(60),      -- derived from the code range
    KEY idx_procedure_id (procedure_id),
    KEY idx_cpt (cpt_code)
) ENGINE=InnoDB COMMENT='Procedure (CPT) dimension';


-- =====================================================================
-- FACT TABLE -- grain: ONE ROW PER ENCOUNTER
-- =====================================================================
--
-- Every measure below is additive at this grain, which is the test a
-- grain declaration has to pass. allowed_amount is additive per
-- encounter; it would NOT be additive per diagnosis, which is why
-- diagnosis grain was rejected (see Decision 1).
--
-- The precomputed columns are where the speedup actually comes from. The
-- star shape reduces join depth; the precomputation is what moves work
-- from query time to load time. is_readmission_30d in particular executes
-- Q3's entire self-join ONCE, at load, instead of once per analyst.
-- =====================================================================
CREATE TABLE fact_encounters (
    encounter_key            BIGINT AUTO_INCREMENT PRIMARY KEY,

    -- ---- degenerate dimensions (no attributes of their own) ----------
    encounter_id             INT         NOT NULL,   -- drill-through to source
    encounter_type           VARCHAR(20) NOT NULL,   -- 3 values: no dim table
    claim_status             VARCHAR(20),            -- 3 values: no dim table

    -- ---- dimension foreign keys --------------------------------------
    date_key                 INT         NOT NULL,   -- encounter date
    discharge_date_key       INT,                    -- NULL if not discharged
    patient_key              INT         NOT NULL,
    provider_key             INT         NOT NULL,
    department_key           INT         NOT NULL,
    specialty_key            INT         NOT NULL,   -- direct star join, NOT
                                                     -- via dim_provider
    encounter_type_key       INT         NOT NULL,
    principal_diagnosis_key  INT,                    -- denormalised shortcut:
                                                     -- the seq=1 diagnosis, so
                                                     -- common queries can skip
                                                     -- the bridge entirely

    -- ---- measures ----------------------------------------------------
    encounter_count          TINYINT       NOT NULL DEFAULT 1,
                                  -- always 1, so every count is a SUM and
                                  -- all measures aggregate identically
    length_of_stay_minutes   INT,
    patient_age_years        SMALLINT,     -- age AT the encounter date
    patient_age_band         VARCHAR(10),  -- '0-17','18-34',...,'85+'
    diagnosis_count          TINYINT       NOT NULL DEFAULT 0,
    procedure_count          TINYINT       NOT NULL DEFAULT 0,
    claim_amount             DECIMAL(12,2) NOT NULL DEFAULT 0,
    allowed_amount           DECIMAL(12,2) NOT NULL DEFAULT 0,
    denied_amount            DECIMAL(12,2) NOT NULL DEFAULT 0,
    is_index_admission       TINYINT       NOT NULL DEFAULT 0,  -- inpatient + discharged
    is_readmission_30d       TINYINT       NOT NULL DEFAULT 0,  -- Q3, precomputed

    -- ---- referential integrity ---------------------------------------
    -- Kept ON here because the dataset is small and correctness during
    -- development matters more than load speed. A production warehouse at
    -- 300M rows would typically drop these and enforce integrity in the
    -- ETL instead, since the load is the only writer.
    CONSTRAINT fk_f_date      FOREIGN KEY (date_key)      REFERENCES dim_date(date_key),
    CONSTRAINT fk_f_disch     FOREIGN KEY (discharge_date_key) REFERENCES dim_date(date_key),
    CONSTRAINT fk_f_patient   FOREIGN KEY (patient_key)   REFERENCES dim_patient(patient_key),
    CONSTRAINT fk_f_provider  FOREIGN KEY (provider_key)  REFERENCES dim_provider(provider_key),
    CONSTRAINT fk_f_dept      FOREIGN KEY (department_key) REFERENCES dim_department(department_key),
    CONSTRAINT fk_f_spec      FOREIGN KEY (specialty_key) REFERENCES dim_specialty(specialty_key),
    CONSTRAINT fk_f_enctype   FOREIGN KEY (encounter_type_key) REFERENCES dim_encounter_type(encounter_type_key),
    CONSTRAINT fk_f_prindx    FOREIGN KEY (principal_diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key),

    UNIQUE KEY uq_encounter (encounter_id),   -- the grain, enforced

    -- ---- indexes -----------------------------------------------------
    -- Composite indexes lead with date_key because essentially every
    -- analytical query filters or groups by time first.
    KEY idx_date (date_key),
    KEY idx_date_provider (date_key, provider_key),
    KEY idx_provider (provider_key),
    KEY idx_patient (patient_key),
    KEY idx_type_readmit (encounter_type, is_readmission_30d),
    KEY idx_dept (department_key),
    KEY idx_specialty (specialty_key),
    KEY idx_date_specialty (date_key, specialty_key),
    KEY idx_enctype (encounter_type_key)
) ENGINE=InnoDB COMMENT='Encounter fact; grain = one row per encounter';


-- =====================================================================
-- BRIDGE TABLES -- the two many-to-many relationships
-- =====================================================================
--
-- These keep the fan trap OUTSIDE the fact table. A query that joins both
-- bridges still produces ~2M pair rows -- pairing diagnoses with
-- procedures inherently produces pairs -- but:
--   * the fan is opt-in; Q1/Q3/Q4 never touch a bridge
--   * bridge rows are 3-4 integers, not VARCHAR(200) descriptions
--   * NO MEASURE IS REACHABLE from a bridge-to-bridge join, so the 6.9x
--     revenue inflation measured in Q2 is structurally impossible rather
--     than merely discouraged
-- =====================================================================

CREATE TABLE bridge_encounter_diagnoses (
    encounter_key      BIGINT  NOT NULL,
    diagnosis_key      INT     NOT NULL,
    diagnosis_sequence TINYINT NOT NULL,
    is_principal       TINYINT NOT NULL DEFAULT 0,   -- sequence = 1
    PRIMARY KEY (encounter_key, diagnosis_key),
    CONSTRAINT fk_bd_enc FOREIGN KEY (encounter_key) REFERENCES fact_encounters(encounter_key),
    CONSTRAINT fk_bd_dx  FOREIGN KEY (diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key),
    KEY idx_dx (diagnosis_key),
    KEY idx_principal (is_principal, diagnosis_key)
) ENGINE=InnoDB COMMENT='Encounter <-> diagnosis bridge (many-to-many)';

CREATE TABLE bridge_encounter_procedures (
    encounter_key      BIGINT NOT NULL,
    procedure_key      INT    NOT NULL,
    procedure_date_key INT,
    PRIMARY KEY (encounter_key, procedure_key),
    CONSTRAINT fk_bp_enc FOREIGN KEY (encounter_key) REFERENCES fact_encounters(encounter_key),
    CONSTRAINT fk_bp_px  FOREIGN KEY (procedure_key) REFERENCES dim_procedure(procedure_key),
    KEY idx_px (procedure_key)
) ENGINE=InnoDB COMMENT='Encounter <-> procedure bridge (many-to-many)';


-- =====================================================================
-- AGGREGATE TABLE -- Kimball aggregate navigation
-- =====================================================================
--
-- Q2 asks for the most common diagnosis-procedure pairings. Answering it
-- from the bridges means forming ~2,060,000 pair rows to return 20, every
-- time it is asked. There are only ~1,200 distinct pairs, so the ETL
-- materialises them once.
--
-- STATED HONESTLY: the speedup Q2 gets from this table comes from
-- PRECOMPUTATION, not from the star schema shape. Claiming otherwise
-- would misattribute the result. What the star schema contributes is a
-- stable, clean grain to aggregate from.
-- =====================================================================
CREATE TABLE agg_diagnosis_procedure_pair (
    diagnosis_key     INT NOT NULL,
    procedure_key     INT NOT NULL,
    encounter_count   INT NOT NULL,
    total_allowed     DECIMAL(14,2) NOT NULL DEFAULT 0,
                        -- allocated, NOT summed: see 05_etl.sql. Summing
                        -- allowed_amount across pairs is the fan trap.
    PRIMARY KEY (diagnosis_key, procedure_key),
    CONSTRAINT fk_agg_dx FOREIGN KEY (diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key),
    CONSTRAINT fk_agg_px FOREIGN KEY (procedure_key) REFERENCES dim_procedure(procedure_key),
    KEY idx_count (encounter_count DESC)
) ENGINE=InnoDB COMMENT='Pre-aggregated diagnosis x procedure pair counts';


-- =====================================================================
-- ETL CONTROL -- supports the incremental strategy.
--
-- The source system has NO created_at/updated_at columns anywhere
-- (finding B9), so there is no way to detect changed rows. This table
-- holds the high-water mark and load history that the ETL uses instead.
-- =====================================================================
CREATE TABLE etl_load_log (
    load_id           INT AUTO_INCREMENT PRIMARY KEY,
    load_started_at   DATETIME NOT NULL,
    load_finished_at  DATETIME,
    load_type         VARCHAR(20),      -- 'FULL' | 'INCREMENTAL'
    high_water_mark   INT,              -- max encounter_id loaded
    rows_inserted     INT,
    rows_updated      INT,
    rows_rejected     INT,
    notes             VARCHAR(500)
) ENGINE=InnoDB COMMENT='ETL run history and incremental watermark';
