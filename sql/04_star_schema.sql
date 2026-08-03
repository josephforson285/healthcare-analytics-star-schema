-- =====================================================================
-- 04_star_schema.sql
-- Dimensional model (Kimball star schema) for healthcare analytics.
--
-- Grain: ONE ROW PER ENCOUNTER in fact_encounters.
-- Rationale for every choice here is in docs/design_decisions.txt.
-- =====================================================================

DROP DATABASE IF EXISTS healthcare_dw;
CREATE DATABASE healthcare_dw
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;
USE healthcare_dw;

-- =====================================================================
-- DIMENSIONS
-- =====================================================================

CREATE TABLE dim_date (
    date_key        INT         NOT NULL PRIMARY KEY,   -- 20240612
    full_date       DATE        NOT NULL,
    year            SMALLINT    NOT NULL,
    quarter         TINYINT     NOT NULL,
    month           TINYINT     NOT NULL,
    calendar_month  CHAR(7)     NOT NULL,               -- '2024-06'
    day_of_month    TINYINT     NOT NULL,
    day_of_week     TINYINT     NOT NULL,               -- 1=Monday
    day_of_year     SMALLINT    NOT NULL,
    week_of_year    TINYINT     NOT NULL,
    is_weekend      TINYINT     NOT NULL,
    UNIQUE KEY uq_full_date (full_date),
    CONSTRAINT chk_d_month   CHECK (month       BETWEEN 1 AND 12),
    CONSTRAINT chk_d_quarter CHECK (quarter     BETWEEN 1 AND 4),
    CONSTRAINT chk_d_dow     CHECK (day_of_week BETWEEN 1 AND 7),
    CONSTRAINT chk_d_dom     CHECK (day_of_month BETWEEN 1 AND 31),
    CONSTRAINT chk_d_doy     CHECK (day_of_year BETWEEN 1 AND 366),
    CONSTRAINT chk_d_weekend CHECK (is_weekend  IN (0,1)),
    KEY idx_calendar_month (calendar_month),
    KEY idx_year_quarter (year, quarter)
) ENGINE=InnoDB COMMENT='Calendar dimension; one row per day';

-- ---------------------------------------------------------------------
-- dim_patient -- SCD Type 2.
-- ---------------------------------------------------------------------
CREATE TABLE dim_patient (
    patient_key     INT AUTO_INCREMENT PRIMARY KEY,     -- surrogate
    patient_id      INT          NOT NULL,              -- natural key
    mrn             VARCHAR(20),
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    date_of_birth   DATE,
    gender          CHAR(1),
    effective_from  DATE         NOT NULL DEFAULT '1900-01-01',
    effective_to    DATE         NOT NULL DEFAULT '9999-12-31',
    is_current      TINYINT      NOT NULL DEFAULT 1,
    CONSTRAINT chk_p_validity CHECK (effective_to >= effective_from),
    CONSTRAINT chk_p_current  CHECK (is_current IN (0,1)),
    CONSTRAINT chk_p_gender   CHECK (gender IN ('F','M','U')),
    CONSTRAINT chk_p_dob      CHECK (date_of_birth IS NULL
                                     OR date_of_birth >= '1900-01-01'),

    KEY idx_patient_id (patient_id),
    KEY idx_current (patient_id, is_current)
) ENGINE=InnoDB COMMENT='Patient dimension, SCD Type 2';


-- ---------------------------------------------------------------------
-- dim_department -- SCD Type 1.
-- -------------------------------------------------------------------
CREATE TABLE dim_department (
    department_key   INT AUTO_INCREMENT PRIMARY KEY,
    department_id    INT NOT NULL,
    department_name  VARCHAR(100),
    floor            INT,
    capacity         INT,
    KEY idx_department_id (department_id)
) ENGINE=InnoDB COMMENT='Department dimension (SCD Type 1)';

-- ---------------------------------------------------------------------
-- dim_specialty 
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
-- dim_provider -- SCD Type 2.
-- ---------------------------------------------------------------------
CREATE TABLE dim_provider (
    provider_key    INT AUTO_INCREMENT PRIMARY KEY,
    provider_id     INT          NOT NULL,
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    credential      VARCHAR(20),
    effective_from  DATE    NOT NULL DEFAULT '1900-01-01',
    effective_to    DATE    NOT NULL DEFAULT '9999-12-31',
    is_current      TINYINT NOT NULL DEFAULT 1,
    CONSTRAINT chk_pr_validity CHECK (effective_to >= effective_from),
    CONSTRAINT chk_pr_current  CHECK (is_current IN (0,1)),
    KEY idx_provider_id (provider_id),
    KEY idx_current (provider_id, is_current)
) ENGINE=InnoDB COMMENT='Provider dimension, SCD Type 2; own attributes only';

-- ---------------------------------------------------------------------
-- dim_encounter_type  
-- ---------------------------------------------------------------------
CREATE TABLE dim_encounter_type (
    encounter_type_key  INT AUTO_INCREMENT PRIMARY KEY,
    type_name           VARCHAR(20) NOT NULL,
    is_emergency        TINYINT     NOT NULL DEFAULT 0,
    is_overnight        TINYINT     NOT NULL DEFAULT 0,
    UNIQUE KEY uq_type_name (type_name),
    CONSTRAINT chk_et_emerg CHECK (is_emergency IN (0,1)),
    CONSTRAINT chk_et_night CHECK (is_overnight IN (0,1))
) ENGINE=InnoDB COMMENT='Encounter type dimension (Outpatient/Inpatient/ER)';

-- ---------------------------------------------------------------------
-- dim_diagnosis / dim_procedure  
-- ---------------------------------------------------------------------
CREATE TABLE dim_diagnosis (
    diagnosis_key      INT AUTO_INCREMENT PRIMARY KEY,
    diagnosis_id       INT NOT NULL,
    icd10_code         VARCHAR(10),
    icd10_description  VARCHAR(200),
    KEY idx_diagnosis_id (diagnosis_id),
    KEY idx_icd10 (icd10_code)
) ENGINE=InnoDB COMMENT='Diagnosis (ICD-10) dimension';

CREATE TABLE dim_procedure (
    procedure_key      INT AUTO_INCREMENT PRIMARY KEY,
    procedure_id       INT NOT NULL,
    cpt_code           VARCHAR(10),
    cpt_description    VARCHAR(200),
    KEY idx_procedure_id (procedure_id),
    KEY idx_cpt (cpt_code)
) ENGINE=InnoDB COMMENT='Procedure (CPT) dimension';


-- =====================================================================
-- FACT TABLE -- grain: ONE ROW PER ENCOUNTER
-- =====================================================================
CREATE TABLE fact_encounters (
    encounter_key            BIGINT AUTO_INCREMENT PRIMARY KEY,

    -- ---- degenerate dimensions (no attributes of their own) ----------
    encounter_id             INT         NOT NULL,    
    encounter_type           VARCHAR(20) NOT NULL,    
    claim_status             VARCHAR(20),            

    -- ---- dimension foreign keys --------------------------------------
    date_key                 INT         NOT NULL,   -- encounter date
    discharge_date_key       INT,                    -- NULL if not discharged
    patient_key              INT         NOT NULL,
    provider_key             INT         NOT NULL,
    department_key           INT         NOT NULL,
    specialty_key            INT         NOT NULL,    
                                                     
    encounter_type_key       INT         NOT NULL,

    -- ---- measures ----------------------------------------------------
    length_of_stay_minutes   INT,
    patient_age_years        SMALLINT,     -- age AT the encounter date
    diagnosis_count          TINYINT       NOT NULL DEFAULT 0,
    procedure_count          TINYINT       NOT NULL DEFAULT 0,
    claim_amount             DECIMAL(12,2) NOT NULL DEFAULT 0,
    allowed_amount           DECIMAL(12,2) NOT NULL DEFAULT 0,
    denied_amount            DECIMAL(12,2) NOT NULL DEFAULT 0,
    is_index_admission       TINYINT       NOT NULL DEFAULT 0,  -- inpatient + discharged
    is_readmission_30d       TINYINT       NOT NULL DEFAULT 0,  -- Q3, precomputed

    -- ---- referential integrity ---------------------------------------
    CONSTRAINT fk_f_date      FOREIGN KEY (date_key)      REFERENCES dim_date(date_key),
    CONSTRAINT fk_f_disch     FOREIGN KEY (discharge_date_key) REFERENCES dim_date(date_key),
    CONSTRAINT fk_f_patient   FOREIGN KEY (patient_key)   REFERENCES dim_patient(patient_key),
    CONSTRAINT fk_f_provider  FOREIGN KEY (provider_key)  REFERENCES dim_provider(provider_key),
    CONSTRAINT fk_f_dept      FOREIGN KEY (department_key) REFERENCES dim_department(department_key),
    CONSTRAINT fk_f_spec      FOREIGN KEY (specialty_key) REFERENCES dim_specialty(specialty_key),
    CONSTRAINT fk_f_enctype   FOREIGN KEY (encounter_type_key) REFERENCES dim_encounter_type(encounter_type_key),

    UNIQUE KEY uq_encounter (encounter_id),    

    -- ---- CHECK constraints -------------------------------------------
    CONSTRAINT chk_f_los      CHECK (length_of_stay_minutes IS NULL OR length_of_stay_minutes >= 0),
    CONSTRAINT chk_f_claim    CHECK (claim_amount   >= 0),
    CONSTRAINT chk_f_allowed  CHECK (allowed_amount >= 0),
    CONSTRAINT chk_f_denied   CHECK (denied_amount  >= 0),
    CONSTRAINT chk_f_money    CHECK (allowed_amount + denied_amount <= claim_amount),
    CONSTRAINT chk_f_dxcount  CHECK (diagnosis_count >= 0),
    CONSTRAINT chk_f_pxcount  CHECK (procedure_count >= 0),
    CONSTRAINT chk_f_index    CHECK (is_index_admission IN (0,1)),
    CONSTRAINT chk_f_readmit  CHECK (is_readmission_30d IN (0,1)),
    CONSTRAINT chk_f_age      CHECK (patient_age_years IS NULL
                                     OR patient_age_years BETWEEN 0 AND 130),

    CONSTRAINT chk_f_enctype  CHECK (encounter_type IN ('Outpatient','Inpatient','ER','Unknown')),
    CONSTRAINT chk_f_status   CHECK (claim_status IS NULL OR claim_status IN
                                     ('Paid','Pending','Denied','No Claim','Unknown')),

    -- ---- indexes -----------------------------------------------------
    KEY idx_date_specialty (date_key, specialty_key),  -- chosen by Q1 and Q4
    KEY idx_specialty (specialty_key),                 -- chosen by Q3
    KEY idx_enctype (encounter_type_key),              -- chosen by Q5
    KEY idx_patient (patient_key),                     -- FK
    KEY idx_provider (provider_key),                   -- FK
    KEY idx_dept (department_key)                      -- FK
) ENGINE=InnoDB COMMENT='Encounter fact; grain = one row per encounter';


-- =====================================================================
-- BRIDGE TABLES -- the two many-to-many relationships
-- =====================================================================

CREATE TABLE bridge_encounter_diagnoses (
    encounter_key      BIGINT  NOT NULL,
    diagnosis_key      INT     NOT NULL,
    diagnosis_sequence TINYINT NOT NULL,
    PRIMARY KEY (encounter_key, diagnosis_key),
    CONSTRAINT chk_bd_seq CHECK (diagnosis_sequence >= 1),
    CONSTRAINT fk_bd_enc FOREIGN KEY (encounter_key) REFERENCES fact_encounters(encounter_key),
    CONSTRAINT fk_bd_dx  FOREIGN KEY (diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key),
    KEY idx_dx_only (diagnosis_key)
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
-- AGGREGATE TABLE  
-- =====================================================================

CREATE TABLE agg_diagnosis_procedure_pair (
    diagnosis_key     INT NOT NULL,
    procedure_key     INT NOT NULL,
    encounter_count   INT NOT NULL,
    total_allowed     DECIMAL(14,2) NOT NULL DEFAULT 0,

    PRIMARY KEY (diagnosis_key, procedure_key),
    CONSTRAINT chk_agg_count CHECK (encounter_count > 0),
    CONSTRAINT chk_agg_money CHECK (total_allowed  >= 0),
    CONSTRAINT fk_agg_dx FOREIGN KEY (diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key),
    CONSTRAINT fk_agg_px FOREIGN KEY (procedure_key) REFERENCES dim_procedure(procedure_key),
    KEY idx_count (encounter_count DESC)
) ENGINE=InnoDB COMMENT='Pre-aggregated diagnosis x procedure pair counts';


-- =====================================================================
-- ETL CONTROL log
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
