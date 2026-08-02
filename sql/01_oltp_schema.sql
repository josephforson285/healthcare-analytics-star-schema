-- =====================================================================
-- 01_oltp_schema.sql
-- HealthTech Analytics - normalized (3NF) transactional schema
--
-- This is the PRODUCTION OLTP system, reproduced exactly as given in the
-- lab brief. It is deliberately left as-is: only the two indexes the brief
-- specifies (idx_encounter_date, idx_claim_date) are created.
--
-- Do NOT add "helpful" indexes here. Part 2 of the lab asks us to find the
-- bottlenecks in this schema. Tuning it first would hide the very problems
-- the star schema is meant to solve.
-- =====================================================================

DROP DATABASE IF EXISTS healthcare_oltp;
CREATE DATABASE healthcare_oltp
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;
USE healthcare_oltp;

-- ---------------------------------------------------------------------
-- Reference / lookup tables
-- Grain: one row per reference concept. These become dimensions later.
-- ---------------------------------------------------------------------

CREATE TABLE specialties (
    specialty_id    INT PRIMARY KEY,
    specialty_name  VARCHAR(100),
    specialty_code  VARCHAR(10)
) ENGINE=InnoDB;

CREATE TABLE departments (
    department_id   INT PRIMARY KEY,
    department_name VARCHAR(100),
    floor           INT,
    capacity        INT
) ENGINE=InnoDB;

CREATE TABLE diagnoses (
    diagnosis_id        INT PRIMARY KEY,
    icd10_code          VARCHAR(10),
    icd10_description   VARCHAR(200)
) ENGINE=InnoDB;

CREATE TABLE procedures (
    procedure_id     INT PRIMARY KEY,
    cpt_code         VARCHAR(10),
    cpt_description  VARCHAR(200)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Entity tables
-- ---------------------------------------------------------------------

-- Grain: one row per person.
CREATE TABLE patients (
    patient_id      INT PRIMARY KEY,
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    date_of_birth   DATE,
    gender          CHAR(1),
    mrn             VARCHAR(20) UNIQUE
) ENGINE=InnoDB;

-- Grain: one row per clinician.
-- Note the hierarchy hanging off this table: provider -> specialty,
-- provider -> department. In 3NF that costs a JOIN every single time we
-- want to group encounters by specialty. That cost is the whole point.
CREATE TABLE providers (
    provider_id     INT PRIMARY KEY,
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    credential      VARCHAR(20),
    specialty_id    INT,
    department_id   INT,
    FOREIGN KEY (specialty_id)  REFERENCES specialties(specialty_id),
    FOREIGN KEY (department_id) REFERENCES departments(department_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Transaction table -- the heartbeat of the system.
-- Grain: one row per patient visit.
-- ---------------------------------------------------------------------

CREATE TABLE encounters (
    encounter_id    INT PRIMARY KEY,
    patient_id      INT,
    provider_id     INT,
    encounter_type  VARCHAR(50),      -- 'Outpatient', 'Inpatient', 'ER'
    encounter_date  DATETIME,
    discharge_date  DATETIME,
    department_id   INT,
    FOREIGN KEY (patient_id)    REFERENCES patients(patient_id),
    FOREIGN KEY (provider_id)   REFERENCES providers(provider_id),
    FOREIGN KEY (department_id) REFERENCES departments(department_id),
    INDEX idx_encounter_date (encounter_date)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Junction tables -- TWO independent many-to-many relationships hanging
-- off the same parent. This is the fan trap. Joining both at once
-- multiplies rows (n_diagnoses x n_procedures per encounter) and inflates
-- every additive measure downstream.
-- ---------------------------------------------------------------------

-- Grain: one row per diagnosis recorded on a visit.
CREATE TABLE encounter_diagnoses (
    encounter_diagnosis_id  INT PRIMARY KEY,
    encounter_id            INT,
    diagnosis_id            INT,
    diagnosis_sequence      INT,       -- 1 = principal diagnosis
    FOREIGN KEY (encounter_id) REFERENCES encounters(encounter_id),
    FOREIGN KEY (diagnosis_id) REFERENCES diagnoses(diagnosis_id)
) ENGINE=InnoDB;

-- Grain: one row per procedure performed on a visit.
CREATE TABLE encounter_procedures (
    encounter_procedure_id  INT PRIMARY KEY,
    encounter_id            INT,
    procedure_id            INT,
    procedure_date          DATE,
    FOREIGN KEY (encounter_id) REFERENCES encounters(encounter_id),
    FOREIGN KEY (procedure_id) REFERENCES procedures(procedure_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Billing -- grain: one row per claim raised against an encounter.
-- Effectively 1:1 with encounters in this dataset.
-- ---------------------------------------------------------------------

CREATE TABLE billing (
    billing_id      INT PRIMARY KEY,
    encounter_id    INT,
    claim_amount    DECIMAL(12,2),
    allowed_amount  DECIMAL(12,2),
    claim_date      DATE,
    claim_status    VARCHAR(50),
    FOREIGN KEY (encounter_id) REFERENCES encounters(encounter_id),
    INDEX idx_claim_date (claim_date)
) ENGINE=InnoDB;
