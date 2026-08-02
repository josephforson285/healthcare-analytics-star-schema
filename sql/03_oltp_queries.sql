-- =====================================================================
-- 03_oltp_queries.sql
-- Part 2: the four business questions, answered against the normalized
-- OLTP schema. These are the "before" of the before/after comparison.
--
-- Written the way an analyst would naturally write them against this
-- schema -- no hand-tuning, no hint blocks, no pre-materialised helpers.
-- The point is to measure what the schema costs as given.
-- =====================================================================

USE healthcare_oltp;

-- ---------------------------------------------------------------------
-- Q1: Monthly encounters by specialty
-- Total encounters and unique patients, per month / specialty / type.
--
-- Join chain: encounters -> providers -> specialties  (3 tables, 2 joins)
-- The specialty is two hops from the fact. That is correct 3NF and it is
-- also the cost: every analytical grouping by specialty must traverse
-- the provider table first.
-- ---------------------------------------------------------------------
SELECT
    DATE_FORMAT(e.encounter_date, '%Y-%m')  AS month,
    s.specialty_name,
    e.encounter_type,
    COUNT(*)                                AS encounters,
    COUNT(DISTINCT e.patient_id)            AS unique_patients
FROM encounters  e
JOIN providers   p ON p.provider_id  = e.provider_id
JOIN specialties s ON s.specialty_id = p.specialty_id
GROUP BY month, s.specialty_name, e.encounter_type
ORDER BY month, s.specialty_name, e.encounter_type;


-- ---------------------------------------------------------------------
-- Q2: Top diagnosis-procedure pairs
--
-- This is the fan trap by design -- pairing diagnoses with procedures is
-- the actual question, so the double junction join is unavoidable here.
-- Joining 897k diagnosis rows to 750k procedure rows on encounter_id
-- materialises ~2.25M intermediate rows before a single group is formed.
--
-- Note COUNT(DISTINCT ed.encounter_id), NOT COUNT(*). COUNT(*) would
-- count pair-rows rather than encounters and overstate everything. No
-- monetary column may be summed in this shape at all -- see the fan trap
-- demonstration in README.md.
--
-- Join chain: encounter_diagnoses -> encounter_procedures
--             -> diagnoses -> procedures            (4 tables, 3 joins)
-- ---------------------------------------------------------------------
SELECT
    d.icd10_code,
    d.icd10_description,
    pr.cpt_code,
    pr.cpt_description,
    COUNT(DISTINCT ed.encounter_id)  AS encounter_count
FROM encounter_diagnoses  ed
JOIN encounter_procedures ep ON ep.encounter_id = ed.encounter_id
JOIN diagnoses            d  ON d.diagnosis_id  = ed.diagnosis_id
JOIN procedures           pr ON pr.procedure_id = ep.procedure_id
GROUP BY d.icd10_code, d.icd10_description, pr.cpt_code, pr.cpt_description
ORDER BY encounter_count DESC
LIMIT 20;


-- ---------------------------------------------------------------------
-- Q3: 30-day readmission rate by specialty
--
-- ASSUMPTION (stated in docs/00-findings-and-assumptions.md): the index
-- event is an Inpatient discharge; the readmission is ANY subsequent
-- encounter by the same patient within 30 days of that discharge. The
-- brief says only "return within 30 days" and does not restrict the
-- return type. Restricting it to Inpatient would roughly halve the rate.
--
-- Specialty is attributed to the INDEX admission's provider, not the
-- readmitting provider -- readmission is a quality measure against the
-- team that discharged the patient.
--
-- The self-join on encounters is the expensive shape: for each of ~30,000
-- inpatient discharges, find any later encounter by the same patient
-- inside a 30-day window. The equality predicate on patient_id can use
-- the auto-created FK index; the date range cannot be satisfied by the
-- same index, so each probe still scans that patient's encounters.
-- ---------------------------------------------------------------------
WITH index_admissions AS (
    SELECT e.encounter_id, e.patient_id, e.discharge_date, p.specialty_id
    FROM encounters e
    JOIN providers  p ON p.provider_id = e.provider_id
    WHERE e.encounter_type = 'Inpatient'
      AND e.discharge_date IS NOT NULL
),
flagged AS (
    SELECT
        i.encounter_id,
        i.specialty_id,
        MAX(r.encounter_id IS NOT NULL) AS readmitted
    FROM index_admissions i
    LEFT JOIN encounters  r
           ON  r.patient_id     =  i.patient_id
           AND r.encounter_id  <>  i.encounter_id
           AND r.encounter_date >  i.discharge_date
           AND r.encounter_date <= i.discharge_date + INTERVAL 30 DAY
    GROUP BY i.encounter_id, i.specialty_id
)
SELECT
    s.specialty_name,
    COUNT(*)                                       AS inpatient_discharges,
    SUM(f.readmitted)                              AS readmissions_30d,
    ROUND(100 * SUM(f.readmitted) / COUNT(*), 2)   AS readmission_rate_pct
FROM flagged     f
JOIN specialties s ON s.specialty_id = f.specialty_id
GROUP BY s.specialty_name
ORDER BY readmission_rate_pct DESC, s.specialty_name;


-- ---------------------------------------------------------------------
-- Q4: Revenue by specialty and month
--
-- Join chain: billing -> encounters -> providers -> specialties
--             (4 tables, 3 joins)
--
-- Grouped on the ENCOUNTER date rather than the claim date: revenue is
-- attributed to the period in which care was delivered, not the period
-- the paperwork cleared. Claims land 1-20 days after discharge here, so
-- grouping on claim_date would push a material share of December revenue
-- into January.
--
-- Only allowed_amount is summed. claim_amount is what was asked for;
-- allowed_amount is what the payer contract actually permits, and is the
-- honest revenue figure.
-- ---------------------------------------------------------------------
SELECT
    DATE_FORMAT(e.encounter_date, '%Y-%m')   AS month,
    s.specialty_name,
    COUNT(*)                                 AS claims,
    ROUND(SUM(b.allowed_amount), 2)          AS total_allowed
FROM billing     b
JOIN encounters  e ON e.encounter_id  = b.encounter_id
JOIN providers   p ON p.provider_id   = e.provider_id
JOIN specialties s ON s.specialty_id  = p.specialty_id
GROUP BY month, s.specialty_name
ORDER BY month, s.specialty_name;
