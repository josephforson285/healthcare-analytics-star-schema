-- =====================================================================
-- 99_oltp_hardening.sql
--
-- *** NOT PART OF THE MAIN RUN. DO NOT EXECUTE BEFORE PART 2. ***
--
-- This file is an appendix, not a step. It answers "what would you change
-- if you owned the source system?" -- the findings in
-- docs/00-findings-and-assumptions.md section B, expressed as DDL.
--
-- It is deliberately NOT applied, for two reasons:
--
--   1. Running it before the Part 2 measurements would mean those numbers
--      describe a schema we tuned, not the schema we were asked to
--      analyse. The before/after comparison would prove nothing.
--   2. In practice you do not get to alter a live clinical OLTP system to
--      make your warehouse load easier. You inherit it and you defend
--      downstream. The ETL guards in sql/05_etl.sql are the real answer;
--      this file is the recommendation you attach to the ticket.
--
-- Every statement below is reversible and none of them change stored data
-- (except where noted -- the UNIQUE constraints would fail on a source
-- that already contains duplicates, which is itself the finding).
-- =====================================================================

USE healthcare_oltp;

-- ---------------------------------------------------------------------
-- B1: close the nullability holes.
-- A clinical encounter with no patient is not a partially-known row, it
-- is a corrupt one. Nullable-by-default lets the application store it.
-- ---------------------------------------------------------------------
ALTER TABLE encounters
    MODIFY patient_id     INT          NOT NULL,
    MODIFY provider_id    INT          NOT NULL,
    MODIFY encounter_date DATETIME     NOT NULL,
    MODIFY encounter_type VARCHAR(50)  NOT NULL;

ALTER TABLE patients
    MODIFY first_name    VARCHAR(100) NOT NULL,
    MODIFY last_name     VARCHAR(100) NOT NULL,
    MODIFY date_of_birth DATE         NOT NULL;

ALTER TABLE billing
    MODIFY encounter_id   INT           NOT NULL,
    MODIFY claim_amount   DECIMAL(12,2) NOT NULL,
    MODIFY allowed_amount DECIMAL(12,2) NOT NULL;

-- ---------------------------------------------------------------------
-- B2 / B3: a diagnosis or procedure cannot be recorded twice on the same
-- visit. Without these the junction tables permit clinically meaningless
-- rows that silently distort every count built on top of them.
--
-- These also give the dedupe self-join an index to use -- the statement
-- that ran for ten minutes during data loading (finding A4) would have
-- been instant against a schema that had these from the start.
-- ---------------------------------------------------------------------
ALTER TABLE encounter_diagnoses
    ADD CONSTRAINT uq_encounter_diagnosis UNIQUE (encounter_id, diagnosis_id);

ALTER TABLE encounter_procedures
    ADD CONSTRAINT uq_encounter_procedure UNIQUE (encounter_id, procedure_id);

-- ---------------------------------------------------------------------
-- B4 / B5: constrain the attribute domains.
--
-- A lookup table with a foreign key is the more normalised answer and is
-- what a production system should use. CHECK constraints are shown here
-- because they are a single reversible statement -- appropriate for an
-- appendix, where a new table plus a backfill plus an application change
-- is not.
--
-- This is the one genuine *normalisation* criticism of the source: the
-- entities were normalised carefully and the attribute domains were left
-- as free text, repeated across 300,000 rows.
-- ---------------------------------------------------------------------
ALTER TABLE encounters
    ADD CONSTRAINT chk_encounter_type
    CHECK (encounter_type IN ('Outpatient', 'Inpatient', 'ER'));

ALTER TABLE billing
    ADD CONSTRAINT chk_claim_status
    CHECK (claim_status IN ('Paid', 'Pending', 'Denied'));

-- ---------------------------------------------------------------------
-- B6: the clinical code is the real natural key. Allowing two rows with
-- the same ICD-10 or CPT code under different surrogate ids splits every
-- aggregate computed on that code -- and does so invisibly.
-- ---------------------------------------------------------------------
ALTER TABLE diagnoses  ADD CONSTRAINT uq_icd10 UNIQUE (icd10_code);
ALTER TABLE procedures ADD CONSTRAINT uq_cpt   UNIQUE (cpt_code);

-- ---------------------------------------------------------------------
-- B7: billing is 1:1 with encounters in intent but not in enforcement.
-- Nothing stops a second claim being raised against the same encounter,
-- which overstates revenue with no error and no warning.
--
-- If genuine re-billing is a real workflow, the correct fix is the
-- opposite: keep it 1:many and add a claim_sequence / void flag, so the
-- duplication is modelled explicitly instead of happening by accident.
-- ---------------------------------------------------------------------
ALTER TABLE billing
    ADD CONSTRAINT uq_billing_encounter UNIQUE (encounter_id);

-- ---------------------------------------------------------------------
-- B8: temporal sanity. A negative length of stay is currently storable,
-- and a procedure can be dated after the patient went home (5,014 such
-- rows appeared in generation before the clamp was added).
--
-- The procedure_date window cannot be expressed as a CHECK -- it spans
-- two tables -- so it needs a trigger, or an ETL guard. We use the ETL
-- guard; the trigger is noted for completeness.
-- ---------------------------------------------------------------------
ALTER TABLE encounters
    ADD CONSTRAINT chk_discharge_after_admit
    CHECK (discharge_date IS NULL OR discharge_date >= encounter_date);

ALTER TABLE billing
    ADD CONSTRAINT chk_allowed_le_claim
    CHECK (allowed_amount <= claim_amount);

-- ---------------------------------------------------------------------
-- B9: the single highest-value change on this list.
--
-- With no change-tracking column there is no way to detect which rows
-- were modified since the last warehouse load. The ETL currently
-- compensates with a rolling 30-day restatement window -- reprocessing
-- data that mostly has not changed, every single cycle.
--
-- These two columns would replace that with an exact predicate:
--     WHERE updated_at > :last_load_watermark
--
-- Cost: two timestamp columns. Benefit: the fact load stops being
-- approximate.
-- ---------------------------------------------------------------------
ALTER TABLE encounters
    ADD COLUMN created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ADD COLUMN updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                                    ON UPDATE CURRENT_TIMESTAMP,
    ADD INDEX idx_updated_at (updated_at);

ALTER TABLE billing
    ADD COLUMN created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ADD COLUMN updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                                    ON UPDATE CURRENT_TIMESTAMP,
    ADD INDEX idx_updated_at (updated_at);

-- ---------------------------------------------------------------------
-- Deliberately NOT recommended here: analytical indexes on the OLTP
-- tables.
--
-- It is tempting to "fix" the slow Part 2 queries by indexing the source
-- until they are fast. That is the wrong instrument. Analytical indexes
-- on a transactional system slow down every INSERT and UPDATE on the
-- write path -- the path that actually has to be fast in a clinical
-- system -- to speed up reports nobody runs during a patient encounter.
--
-- Separating the two workloads is the entire argument for building the
-- star schema. Indexing the OLTP system into an ad-hoc warehouse gets
-- you the costs of both and the benefits of neither.
-- ---------------------------------------------------------------------
