-- =====================================================================
-- 05_etl.sql
-- Initial full load: healthcare_oltp -> healthcare_dw
--
-- Order matters. Dimensions first (the fact needs their surrogate keys),
-- then the fact, then the bridges (they need encounter_key), then the
-- aggregate table (it reads the bridges).
--
-- DATA QUALITY GUARDS
-- The source schema has no UNIQUE constraints on the junction tables, no
-- CHECK constraints on dates or amounts, and nullable columns throughout
-- (findings B1-B8 in docs/00-findings-and-assumptions.md). Since we may
-- not alter the source, every one of those defects is neutralised here
-- instead. Each guard is marked "GUARD Bn" against its finding.
-- =====================================================================

USE healthcare_dw;

SET autocommit = 0;

INSERT INTO etl_load_log (load_started_at, load_type, notes)
VALUES (NOW(), 'FULL', 'Initial full load of the dimensional model');
SET @load_id = LAST_INSERT_ID();


-- =====================================================================
-- 1. dim_date -- one-time load, 2023-01-01 .. 2025-12-31
--
-- Generated rather than sourced: no table in the OLTP system contains a
-- calendar. Range extends a year past the data so late-arriving facts
-- always find a date key.
-- =====================================================================
INSERT INTO dim_date (
    date_key, full_date, year, quarter, quarter_name, month, month_name,
    month_abbr, calendar_month, day_of_month, day_of_week, day_name,
    day_of_year, week_of_year, is_weekend)
SELECT
    CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED),
    d,
    YEAR(d),
    QUARTER(d),
    CONCAT('Q', QUARTER(d)),
    MONTH(d),
    MONTHNAME(d),
    DATE_FORMAT(d, '%b'),
    DATE_FORMAT(d, '%Y-%m'),
    DAYOFMONTH(d),
    WEEKDAY(d) + 1,                    -- 1 = Monday
    DAYNAME(d),
    DAYOFYEAR(d),
    WEEK(d, 3),                        -- ISO week
    IF(WEEKDAY(d) >= 5, 1, 0)
FROM (
    SELECT DATE('2023-01-01') + INTERVAL seq DAY AS d
    FROM (
        SELECT (a.n + b.n*10 + c.n*100 + d.n*1000) AS seq
        FROM      (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
        CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b
        CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c
        CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3) d
    ) s
    WHERE seq <= DATEDIFF('2025-12-31', '2023-01-01')
) cal;
COMMIT;


-- =====================================================================
-- 2. dim_patient -- SCD Type 2 structure, initial version of every row.
--
-- row_hash is the change-detection mechanism. The source has no
-- updated_at (finding B9), so on subsequent loads the ETL recomputes this
-- hash per incoming row and compares it with the stored one. A difference
-- means the attributes changed and a new version is required.
--
-- GUARD B1: gender is nullable in the source; mapped to 'Unknown' rather
-- than propagating NULL into a grouping column, where it would silently
-- drop rows from GROUP BY output.
-- =====================================================================
INSERT INTO dim_patient (
    patient_key, patient_id, mrn, first_name, last_name, full_name,
    date_of_birth, gender, gender_desc, effective_from, effective_to,
    is_current, row_hash)
VALUES
    (-1, -1, 'UNKNOWN', 'Unknown', 'Unknown', 'Unknown Patient',
     NULL, 'U', 'Unknown', '1900-01-01', '9999-12-31', 1, NULL);
-- ^ the "unknown member". Standard Kimball practice: a fact whose
--   dimension lookup fails points here rather than carrying a NULL FK,
--   so the row is still counted and the gap is visible instead of silent.

INSERT INTO dim_patient (
    patient_id, mrn, first_name, last_name, full_name, date_of_birth,
    gender, gender_desc, effective_from, effective_to, is_current, row_hash)
SELECT
    p.patient_id,
    p.mrn,
    p.first_name,
    p.last_name,
    CONCAT(COALESCE(p.first_name,''), ' ', COALESCE(p.last_name,'')),
    p.date_of_birth,
    COALESCE(p.gender, 'U'),
    CASE COALESCE(p.gender,'U') WHEN 'F' THEN 'Female'
                                WHEN 'M' THEN 'Male'
                                ELSE 'Unknown' END,                 -- GUARD B1
    '1900-01-01', '9999-12-31', 1,
    MD5(CONCAT_WS('|', p.mrn, p.first_name, p.last_name,
                       p.date_of_birth, p.gender))
FROM healthcare_oltp.patients p;
COMMIT;




-- =====================================================================
-- 3. dim_provider -- the provider's OWN attributes only.
--
-- No specialty or department columns, so this has no dependency on those
-- dimensions and no join to resolve their keys. It can load right after
-- dim_patient.
--
-- The hash still covers the source specialty_id and department_id even
-- though neither is stored, so a provider transferring specialty or
-- department is still detected and still opens a new SCD2 version. What
-- specialty an encounter belonged to is recorded on the fact row, which is
-- where the question is actually asked from.
-- =====================================================================
INSERT INTO dim_provider (
    provider_key, provider_id, first_name, last_name, full_name, credential,
    effective_from, effective_to, is_current, row_hash)
VALUES
    (-1, -1, 'Unknown', 'Unknown', 'Unknown Provider', NULL,
     '1900-01-01', '9999-12-31', 1, NULL);

INSERT INTO dim_provider (
    provider_id, first_name, last_name, full_name, credential,
    effective_from, effective_to, is_current, row_hash)
SELECT
    pr.provider_id,
    pr.first_name,
    pr.last_name,
    CONCAT(COALESCE(pr.first_name,''), ' ', COALESCE(pr.last_name,''),
           IF(pr.credential IS NULL, '', CONCAT(', ', pr.credential))),
    pr.credential,
    '1900-01-01', '9999-12-31', 1,
    MD5(CONCAT_WS('|', pr.first_name, pr.last_name, pr.credential,
                       pr.specialty_id, pr.department_id))
FROM healthcare_oltp.providers pr;
COMMIT;


-- =====================================================================
-- 4. dim_department -- SCD Type 1, straight copy plus unknown member.
-- =====================================================================
INSERT INTO dim_department (department_key, department_id, department_name, floor, capacity)
VALUES (-1, -1, 'Unknown', NULL, NULL);

INSERT INTO dim_department (department_id, department_name, floor, capacity)
SELECT department_id, COALESCE(department_name,'Unknown'), floor, capacity
FROM healthcare_oltp.departments;
COMMIT;


-- =====================================================================
-- 5. dim_specialty -- SCD Type 1, straight copy plus unknown member.
--
-- Joined directly from the fact via specialty_key, so a query grouping by
-- specialty need not touch dim_provider at all.
-- =====================================================================
INSERT INTO dim_specialty (specialty_key, specialty_id, specialty_name, specialty_code)
VALUES (-1, -1, 'Unknown', 'UNK');

INSERT INTO dim_specialty (specialty_id, specialty_name, specialty_code)
SELECT specialty_id, COALESCE(specialty_name,'Unknown'), COALESCE(specialty_code,'UNK')
FROM healthcare_oltp.specialties;
COMMIT;


-- =====================================================================
-- 6. dim_encounter_type -- three rows, enumerated rather than sourced.
--
-- GUARD B4: the source column is free-text VARCHAR(50) with no CHECK, so
-- the valid set cannot be derived from the data -- doing SELECT DISTINCT
-- would faithfully import 'er' and 'Emergency' as separate types if they
-- ever appeared. The domain is declared here instead, and anything the
-- fact load cannot match falls to the -1 unknown member where it is
-- visible on a report rather than silently becoming a fourth category.
--
-- is_emergency / is_overnight are the attributes that justify this being
-- a dimension at all rather than a bare string on the fact row.
-- =====================================================================
INSERT INTO dim_encounter_type (encounter_type_key, type_name, is_emergency, is_overnight)
VALUES (-1, 'Unknown', 0, 0);

INSERT INTO dim_encounter_type (type_name, is_emergency, is_overnight) VALUES
    ('Outpatient', 0, 0),
    ('Inpatient',  0, 1),
    ('ER',         1, 0);
COMMIT;




-- =====================================================================
-- 7. dim_diagnosis / dim_procedure
--
-- GUARD B6: the source has no UNIQUE on icd10_code or cpt_code, so the
-- same clinical code could exist under two surrogate ids and split every
-- aggregate built on it. Conforming on the CODE (not the id) collapses
-- any such split. MIN(diagnosis_id) keeps a deterministic representative.
--
-- icd10_chapter and cpt_category are derived roll-up levels the source
-- has no table for.
-- =====================================================================
INSERT INTO dim_diagnosis (diagnosis_key, diagnosis_id, icd10_code, icd10_description, icd10_chapter)
VALUES (-1, -1, 'UNK', 'Unknown diagnosis', 'Unknown');

INSERT INTO dim_diagnosis (diagnosis_id, icd10_code, icd10_description, icd10_chapter)
SELECT
    MIN(d.diagnosis_id),                                            -- GUARD B6
    d.icd10_code,
    MIN(d.icd10_description),
    CASE LEFT(d.icd10_code, 1)
        WHEN 'A' THEN 'Infectious and parasitic diseases'
        WHEN 'B' THEN 'Infectious and parasitic diseases'
        WHEN 'D' THEN 'Blood and immune disorders'
        WHEN 'E' THEN 'Endocrine, nutritional and metabolic'
        WHEN 'F' THEN 'Mental and behavioural disorders'
        WHEN 'G' THEN 'Nervous system'
        WHEN 'H' THEN 'Eye and ear'
        WHEN 'I' THEN 'Circulatory system'
        WHEN 'J' THEN 'Respiratory system'
        WHEN 'K' THEN 'Digestive system'
        WHEN 'L' THEN 'Skin and subcutaneous tissue'
        WHEN 'M' THEN 'Musculoskeletal and connective tissue'
        WHEN 'N' THEN 'Genitourinary system'
        WHEN 'R' THEN 'Symptoms and abnormal findings'
        WHEN 'S' THEN 'Injury and poisoning'
        WHEN 'T' THEN 'Injury and poisoning'
        WHEN 'Z' THEN 'Factors influencing health status'
        ELSE 'Other'
    END
FROM healthcare_oltp.diagnoses d
GROUP BY d.icd10_code;

INSERT INTO dim_procedure (procedure_key, procedure_id, cpt_code, cpt_description, cpt_category)
VALUES (-1, -1, 'UNK', 'Unknown procedure', 'Unknown');

INSERT INTO dim_procedure (procedure_id, cpt_code, cpt_description, cpt_category)
SELECT
    MIN(p.procedure_id),                                            -- GUARD B6
    p.cpt_code,
    MIN(p.cpt_description),
    CASE
        WHEN p.cpt_code BETWEEN '00100' AND '01999' THEN 'Anesthesia'
        WHEN p.cpt_code BETWEEN '10000' AND '69999' THEN 'Surgery'
        WHEN p.cpt_code BETWEEN '70000' AND '79999' THEN 'Radiology'
        WHEN p.cpt_code BETWEEN '80000' AND '89999' THEN 'Pathology and laboratory'
        WHEN p.cpt_code BETWEEN '90000' AND '99199' THEN 'Medicine'
        WHEN p.cpt_code BETWEEN '99200' AND '99499' THEN 'Evaluation and management'
        ELSE 'Other'
    END
FROM healthcare_oltp.procedures p
GROUP BY p.cpt_code;
COMMIT;


-- =====================================================================
-- 8. fact_encounters -- the main load.
--
-- Built in stages because several measures depend on aggregates of other
-- source tables, and doing it in one statement would mean scanning the
-- junction tables once per column.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 6a. Pre-aggregate billing to ENCOUNTER GRAIN.
--
-- GUARD B7: billing.encounter_id is not UNIQUE in the source, so a
-- double-billed encounter would be counted twice by a naive join. This
-- collapses billing to one row per encounter FIRST, so the defect is
-- neutralised once at load rather than in every downstream query.
-- ---------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS _bill;
CREATE TEMPORARY TABLE _bill (
    encounter_id   INT PRIMARY KEY,
    claim_amount   DECIMAL(14,2),
    allowed_amount DECIMAL(14,2),
    denied_amount  DECIMAL(14,2),
    claim_status   VARCHAR(20)
) ENGINE=InnoDB;

INSERT INTO _bill
SELECT
    b.encounter_id,
    SUM(COALESCE(b.claim_amount, 0)),
    SUM(CASE WHEN b.claim_status = 'Denied' THEN 0
             ELSE COALESCE(b.allowed_amount, 0) END),
    SUM(CASE WHEN b.claim_status = 'Denied' THEN COALESCE(b.allowed_amount, 0)
             ELSE 0 END),
    -- if an encounter somehow has several claims, the worst status wins
    CASE WHEN SUM(b.claim_status = 'Denied')  > 0 THEN 'Denied'
         WHEN SUM(b.claim_status = 'Pending') > 0 THEN 'Pending'
         ELSE 'Paid' END
FROM healthcare_oltp.billing b
GROUP BY b.encounter_id;                                            -- GUARD B7

-- ---------------------------------------------------------------------
-- 6b. Diagnosis and procedure counts, plus the principal diagnosis.
--
-- GUARD B2/B3: COUNT(DISTINCT ...) rather than COUNT(*), so duplicate
-- junction rows cannot inflate the stored counts even though the source
-- permits them.
-- ---------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS _dx;
CREATE TEMPORARY TABLE _dx (
    encounter_id    INT PRIMARY KEY,
    diagnosis_count TINYINT,
    principal_dx_id INT
) ENGINE=InnoDB;

INSERT INTO _dx
SELECT
    ed.encounter_id,
    COUNT(DISTINCT ed.diagnosis_id),                                -- GUARD B2
    -- principal = lowest sequence number; ties broken deterministically
    SUBSTRING_INDEX(
        GROUP_CONCAT(ed.diagnosis_id
                     ORDER BY ed.diagnosis_sequence, ed.diagnosis_id), ',', 1)
FROM healthcare_oltp.encounter_diagnoses ed
GROUP BY ed.encounter_id;

DROP TEMPORARY TABLE IF EXISTS _px;
CREATE TEMPORARY TABLE _px (
    encounter_id    INT PRIMARY KEY,
    procedure_count TINYINT
) ENGINE=InnoDB;

INSERT INTO _px
SELECT ep.encounter_id, COUNT(DISTINCT ep.procedure_id)             -- GUARD B3
FROM healthcare_oltp.encounter_procedures ep
GROUP BY ep.encounter_id;

-- ---------------------------------------------------------------------
-- 6c. THE READMISSION FLAG -- the single highest-value precomputation.
--
-- This runs Q3's entire self-join ONCE, here, at load time. Q3 then
-- becomes a GROUP BY over a stored column.
--
-- Definition (see docs/00-findings-and-assumptions.md): index event is an
-- inpatient discharge; a readmission is ANY subsequent encounter by the
-- same patient within 30 days of that discharge.
-- ---------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS _readmit;
CREATE TEMPORARY TABLE _readmit (encounter_id INT PRIMARY KEY) ENGINE=InnoDB;

INSERT INTO _readmit
SELECT DISTINCT i.encounter_id
FROM healthcare_oltp.encounters i
JOIN healthcare_oltp.encounters r
  ON  r.patient_id     =  i.patient_id
  AND r.encounter_id  <>  i.encounter_id
  AND r.encounter_date >  i.discharge_date
  AND r.encounter_date <= i.discharge_date + INTERVAL 30 DAY
WHERE i.encounter_type   = 'Inpatient'
  AND i.discharge_date IS NOT NULL;

-- ---------------------------------------------------------------------
-- 6d. Assemble the fact table.
--
-- GUARD B1: every dimension lookup uses LEFT JOIN + COALESCE to the -1
-- unknown member. An inner join would silently DROP encounters whose
-- patient or provider reference is missing -- losing facts to protect
-- referential neatness, which is exactly backwards.
--
-- GUARD B8: length_of_stay is clamped with GREATEST(...,0) and only
-- computed when discharge >= admission. Nothing in the source prevents a
-- negative stay, and a negative LOS would poison every average built on it.
-- ---------------------------------------------------------------------
INSERT INTO fact_encounters (
    encounter_id, encounter_type, claim_status,
    date_key, discharge_date_key, patient_key, provider_key, department_key,
    specialty_key, encounter_type_key,
    principal_diagnosis_key,
    encounter_count, length_of_stay_minutes, patient_age_years, patient_age_band,
    diagnosis_count, procedure_count,
    claim_amount, allowed_amount, denied_amount,
    is_index_admission, is_readmission_30d)
SELECT
    e.encounter_id,
    -- GUARD B4: encounter_type is free-text VARCHAR(50) in the source with no
    -- lookup table and no CHECK, so 'ER', 'er' and 'Emergency' are all
    -- storable and would fragment into separate groups on any report. The
    -- domain is closed here instead: anything outside the three known values
    -- lands in 'Unknown', where it is visible, rather than silently becoming
    -- a fourth encounter type nobody notices.
    CASE TRIM(e.encounter_type)
        WHEN 'Outpatient' THEN 'Outpatient'
        WHEN 'Inpatient'  THEN 'Inpatient'
        WHEN 'ER'         THEN 'ER'
        ELSE 'Unknown'
    END,
    -- GUARD B5: same treatment for claim_status.
    CASE TRIM(COALESCE(bl.claim_status, 'No Claim'))
        WHEN 'Paid'     THEN 'Paid'
        WHEN 'Pending'  THEN 'Pending'
        WHEN 'Denied'   THEN 'Denied'
        WHEN 'No Claim' THEN 'No Claim'
        ELSE 'Unknown'
    END,

    CAST(DATE_FORMAT(e.encounter_date, '%Y%m%d') AS UNSIGNED),
    CASE WHEN e.discharge_date IS NULL THEN NULL
         ELSE CAST(DATE_FORMAT(e.discharge_date, '%Y%m%d') AS UNSIGNED) END,
    COALESCE(dp.patient_key,   -1),                                 -- GUARD B1
    COALESCE(dpr.provider_key, -1),                                 -- GUARD B1
    COALESCE(dd.department_key, -1),                                -- GUARD B1
    COALESCE(dsp.specialty_key, -1),      -- direct star join, not via provider
    COALESCE(det.encounter_type_key, -1), -- GUARD B4: unmatched -> Unknown
    ddx.diagnosis_key,

    1,
    CASE WHEN e.discharge_date IS NULL OR e.discharge_date < e.encounter_date
         THEN NULL
         ELSE TIMESTAMPDIFF(MINUTE, e.encounter_date, e.discharge_date)
    END,                                                            -- GUARD B8
    TIMESTAMPDIFF(YEAR, p.date_of_birth, e.encounter_date),
    CASE
        WHEN p.date_of_birth IS NULL THEN 'Unknown'
        WHEN TIMESTAMPDIFF(YEAR, p.date_of_birth, e.encounter_date) < 18 THEN '0-17'
        WHEN TIMESTAMPDIFF(YEAR, p.date_of_birth, e.encounter_date) < 35 THEN '18-34'
        WHEN TIMESTAMPDIFF(YEAR, p.date_of_birth, e.encounter_date) < 50 THEN '35-49'
        WHEN TIMESTAMPDIFF(YEAR, p.date_of_birth, e.encounter_date) < 65 THEN '50-64'
        WHEN TIMESTAMPDIFF(YEAR, p.date_of_birth, e.encounter_date) < 85 THEN '65-84'
        ELSE '85+'
    END,

    COALESCE(dx.diagnosis_count, 0),
    COALESCE(px.procedure_count, 0),
    COALESCE(bl.claim_amount,   0),
    COALESCE(bl.allowed_amount, 0),
    COALESCE(bl.denied_amount,  0),

    IF(e.encounter_type = 'Inpatient' AND e.discharge_date IS NOT NULL, 1, 0),
    IF(rd.encounter_id IS NOT NULL, 1, 0)
FROM      healthcare_oltp.encounters e
LEFT JOIN healthcare_oltp.patients   p   ON p.patient_id     = e.patient_id
LEFT JOIN dim_patient                dp  ON dp.patient_id    = e.patient_id  AND dp.is_current = 1
LEFT JOIN dim_provider               dpr ON dpr.provider_id  = e.provider_id AND dpr.is_current = 1
LEFT JOIN dim_department             dd  ON dd.department_id = e.department_id
LEFT JOIN healthcare_oltp.providers  psrc ON psrc.provider_id  = e.provider_id
LEFT JOIN dim_specialty              dsp ON dsp.specialty_id  = psrc.specialty_id
LEFT JOIN dim_encounter_type         det ON det.type_name     = TRIM(e.encounter_type)
LEFT JOIN _bill    bl ON bl.encounter_id = e.encounter_id
LEFT JOIN _dx      dx ON dx.encounter_id = e.encounter_id
LEFT JOIN _px      px ON px.encounter_id = e.encounter_id
LEFT JOIN _readmit rd ON rd.encounter_id = e.encounter_id
LEFT JOIN healthcare_oltp.diagnoses  sd  ON sd.diagnosis_id  = dx.principal_dx_id
LEFT JOIN dim_diagnosis              ddx ON ddx.icd10_code   = sd.icd10_code;
COMMIT;


-- =====================================================================
-- 9. BRIDGES -- loaded after the fact, since they need encounter_key.
--
-- GUARD B2/B3: the bridge primary key is (encounter_key, diagnosis_key),
-- so duplicate source rows collapse rather than propagate. INSERT IGNORE
-- makes that explicit instead of relying on the constraint to error.
--
-- Conformed on CODE via dim_diagnosis (GUARD B6), so two source ids for
-- the same ICD-10 code map to a single dimension row.
-- =====================================================================
INSERT IGNORE INTO bridge_encounter_diagnoses
    (encounter_key, diagnosis_key, diagnosis_sequence, is_principal)
SELECT
    f.encounter_key,
    ddx.diagnosis_key,
    ed.diagnosis_sequence,
    IF(ed.diagnosis_sequence = 1, 1, 0)
FROM healthcare_oltp.encounter_diagnoses ed
JOIN fact_encounters f  ON f.encounter_id  = ed.encounter_id
JOIN healthcare_oltp.diagnoses sd ON sd.diagnosis_id = ed.diagnosis_id
JOIN dim_diagnosis   ddx ON ddx.icd10_code = sd.icd10_code;         -- GUARD B6

INSERT IGNORE INTO bridge_encounter_procedures
    (encounter_key, procedure_key, procedure_date_key)
SELECT
    f.encounter_key,
    dpx.procedure_key,
    CAST(DATE_FORMAT(ep.procedure_date, '%Y%m%d') AS UNSIGNED)
FROM healthcare_oltp.encounter_procedures ep
JOIN fact_encounters f   ON f.encounter_id  = ep.encounter_id
JOIN healthcare_oltp.procedures sp ON sp.procedure_id = ep.procedure_id
JOIN dim_procedure   dpx ON dpx.cpt_code    = sp.cpt_code;          -- GUARD B6
COMMIT;


-- =====================================================================
-- 10. agg_diagnosis_procedure_pair -- Kimball aggregate navigation.
--
-- Forms the ~2.06M pair rows ONCE, here, and stores the ~1,200 distinct
-- results. Q2 then reads 1,200 rows instead of building 2.06M.
--
-- total_allowed is ALLOCATED, not summed. Summing allowed_amount across
-- pair rows is precisely the fan trap that reported $5,752.3M against a
-- true $838.7M. Dividing each encounter's revenue by its own pair count
-- means the column totals back to real revenue instead of a multiple of
-- it. This is the "weighting factor" technique from design_decisions.txt,
-- applied to the aggregate rather than the bridge.
-- =====================================================================
INSERT INTO agg_diagnosis_procedure_pair (diagnosis_key, procedure_key, encounter_count, total_allowed)
SELECT
    bd.diagnosis_key,
    bp.procedure_key,
    COUNT(DISTINCT bd.encounter_key),
    ROUND(SUM(f.allowed_amount / (f.diagnosis_count * f.procedure_count)), 2)
FROM bridge_encounter_diagnoses  bd
JOIN bridge_encounter_procedures bp ON bp.encounter_key = bd.encounter_key
JOIN fact_encounters             f  ON f.encounter_key  = bd.encounter_key
WHERE f.diagnosis_count > 0 AND f.procedure_count > 0
GROUP BY bd.diagnosis_key, bp.procedure_key;
COMMIT;


-- =====================================================================
-- 11. Close the load log and refresh optimizer statistics.
-- =====================================================================
UPDATE etl_load_log
SET load_finished_at = NOW(),
    high_water_mark  = (SELECT MAX(encounter_id) FROM fact_encounters),
    rows_inserted    = (SELECT COUNT(*) FROM fact_encounters),
    rows_updated     = 0,
    rows_rejected    = 0,
    notes            = CONCAT('Full load OK. Facts: ',
                              (SELECT COUNT(*) FROM fact_encounters),
                              ', dx bridge: ',
                              (SELECT COUNT(*) FROM bridge_encounter_diagnoses),
                              ', px bridge: ',
                              (SELECT COUNT(*) FROM bridge_encounter_procedures),
                              ', agg pairs: ',
                              (SELECT COUNT(*) FROM agg_diagnosis_procedure_pair))
WHERE load_id = @load_id;
COMMIT;

SET autocommit = 1;

ANALYZE TABLE dim_date, dim_patient, dim_provider, dim_department,
              dim_diagnosis, dim_procedure, fact_encounters,
              bridge_encounter_diagnoses, bridge_encounter_procedures,
              agg_diagnosis_procedure_pair;
