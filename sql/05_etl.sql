-- =====================================================================
-- Initial full load: healthcare_oltp -> healthcare_dw--
-- DATA QUALITY GUARDS
-- =====================================================================

USE healthcare_dw;

SET autocommit = 0;

INSERT INTO etl_load_log (load_started_at, load_type, notes)
VALUES (NOW(), 'FULL', 'Initial full load of the dimensional model');
SET @load_id = LAST_INSERT_ID();


-- =====================================================================
-- 1. dim_date -- one-time load
-- =====================================================================
INSERT INTO dim_date (
    date_key, full_date, year, quarter, month, calendar_month,
    day_of_month, day_of_week, day_of_year, week_of_year, is_weekend)
SELECT
    CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED),
    d,
    YEAR(d),
    QUARTER(d),
    MONTH(d),
    DATE_FORMAT(d, '%Y-%m'),
    DAYOFMONTH(d),
    WEEKDAY(d) + 1,                    -- 1 = Monday
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
-- =====================================================================
INSERT INTO dim_patient (
    patient_key, patient_id, mrn, first_name, last_name,
    date_of_birth, gender, effective_from, effective_to, is_current)
VALUES
    (-1, -1, 'UNKNOWN', 'Unknown', 'Unknown',
     NULL, 'U', '1900-01-01', '9999-12-31', 1);

DROP TEMPORARY TABLE IF EXISTS _patient_stage;
CREATE TEMPORARY TABLE _patient_stage (
    patient_id      INT PRIMARY KEY,
    mrn             VARCHAR(20),
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    date_of_birth   DATE,
    gender          CHAR(1),
    flag_gender     TINYINT NOT NULL DEFAULT 0,  -- value was outside F/M
    flag_dob        TINYINT NOT NULL DEFAULT 0,  -- implausible, set to NULL
    flag_noname     TINYINT NOT NULL DEFAULT 0   -- no name at all
) ENGINE=InnoDB;

INSERT INTO _patient_stage
SELECT
    p.patient_id,
    p.mrn,
    p.first_name,
    p.last_name,

    CASE WHEN p.date_of_birth BETWEEN '1900-01-01' AND CURDATE()
         THEN p.date_of_birth ELSE NULL END,

    CASE WHEN p.gender IN ('F','M') THEN p.gender ELSE 'U' END,
   
    (p.gender IS NULL OR p.gender NOT IN ('F','M')),
    (p.date_of_birth IS NOT NULL
     AND p.date_of_birth NOT BETWEEN '1900-01-01' AND CURDATE()),
    (p.first_name IS NULL AND p.last_name IS NULL)
FROM healthcare_oltp.patients p;

INSERT INTO dim_patient (
    patient_id, mrn, first_name, last_name, date_of_birth,
    gender, effective_from, effective_to, is_current)
SELECT
    s.patient_id, s.mrn, s.first_name, s.last_name, s.date_of_birth,
    s.gender, '1900-01-01', '9999-12-31', 1
FROM _patient_stage s;


SET @patient_flagged = (SELECT COUNT(*) FROM _patient_stage
                        WHERE flag_gender = 1 OR flag_dob = 1 OR flag_noname = 1);
SET @patient_flag_detail = (SELECT CONCAT(
        'gender=', SUM(flag_gender), ' dob=', SUM(flag_dob),
        ' noname=', SUM(flag_noname)) FROM _patient_stage);
COMMIT;




-- =====================================================================
-- 3. dim_provider -- the provider's OWN attributes only.
-- =====================================================================
INSERT INTO dim_provider (
    provider_key, provider_id, first_name, last_name, credential,
    effective_from, effective_to, is_current)
VALUES
    (-1, -1, 'Unknown', 'Unknown', NULL,
     '1900-01-01', '9999-12-31', 1);

INSERT INTO dim_provider (
    provider_id, first_name, last_name, credential,
    effective_from, effective_to, is_current)
SELECT
    pr.provider_id,
    pr.first_name,
    pr.last_name,
    pr.credential,
    '1900-01-01', '9999-12-31', 1
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
-- =====================================================================
INSERT INTO dim_specialty (specialty_key, specialty_id, specialty_name, specialty_code)
VALUES (-1, -1, 'Unknown', 'UNK');

INSERT INTO dim_specialty (specialty_id, specialty_name, specialty_code)
SELECT specialty_id, COALESCE(specialty_name,'Unknown'), COALESCE(specialty_code,'UNK')
FROM healthcare_oltp.specialties;
COMMIT;


-- =====================================================================
-- 6. dim_encounter_type -- three rows, enumerated rather than sourced.
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
-- =====================================================================
INSERT INTO dim_diagnosis (diagnosis_key, diagnosis_id, icd10_code, icd10_description)
VALUES (-1, -1, 'UNK', 'Unknown diagnosis');

INSERT INTO dim_diagnosis (diagnosis_id, icd10_code, icd10_description)
SELECT
    MIN(d.diagnosis_id),                                            
    d.icd10_code,
    MIN(d.icd10_description)
FROM healthcare_oltp.diagnoses d
GROUP BY d.icd10_code;

INSERT INTO dim_procedure (procedure_key, procedure_id, cpt_code, cpt_description)
VALUES (-1, -1, 'UNK', 'Unknown procedure');

INSERT INTO dim_procedure (procedure_id, cpt_code, cpt_description)
SELECT
    MIN(p.procedure_id),                                             
    p.cpt_code,
    MIN(p.cpt_description)
FROM healthcare_oltp.procedures p
GROUP BY p.cpt_code;
COMMIT;


-- =====================================================================
-- 8. fact_encounters -- the main load.
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
GROUP BY b.encounter_id;                                            

-- ---------------------------------------------------------------------
-- 8b. Diagnosis and procedure counts.
-- ---------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS _dx;
CREATE TEMPORARY TABLE _dx (
    encounter_id    INT PRIMARY KEY,
    diagnosis_count TINYINT
) ENGINE=InnoDB;

INSERT INTO _dx
SELECT
    ed.encounter_id,
    COUNT(DISTINCT ed.diagnosis_id)                                 
FROM healthcare_oltp.encounter_diagnoses ed
GROUP BY ed.encounter_id;

DROP TEMPORARY TABLE IF EXISTS _px;
CREATE TEMPORARY TABLE _px (
    encounter_id    INT PRIMARY KEY,
    procedure_count TINYINT
) ENGINE=InnoDB;

INSERT INTO _px
SELECT ep.encounter_id, COUNT(DISTINCT ep.procedure_id)              
FROM healthcare_oltp.encounter_procedures ep
GROUP BY ep.encounter_id;

-- ---------------------------------------------------------------------
-- 8c. THE READMISSION FLAG -- the single highest-value precomputation.
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
-- 8d. Assemble the fact table.
-- ---------------------------------------------------------------------
INSERT INTO fact_encounters (
    encounter_id, encounter_type, claim_status,
    date_key, discharge_date_key, patient_key, provider_key, department_key,
    specialty_key, encounter_type_key,
    length_of_stay_minutes, patient_age_years,
    diagnosis_count, procedure_count,
    claim_amount, allowed_amount, denied_amount,
    is_index_admission, is_readmission_30d)
SELECT
    e.encounter_id,

    CASE TRIM(e.encounter_type)
        WHEN 'Outpatient' THEN 'Outpatient'
        WHEN 'Inpatient'  THEN 'Inpatient'
        WHEN 'ER'         THEN 'ER'
        ELSE 'Unknown'
    END,
 
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
    COALESCE(dp.patient_key,   -1),                                  
    COALESCE(dpr.provider_key, -1),                                  
    COALESCE(dd.department_key, -1),                                 
    COALESCE(dsp.specialty_key, -1),      
    COALESCE(det.encounter_type_key, -1),  

    CASE WHEN e.discharge_date IS NULL OR e.discharge_date < e.encounter_date
         THEN NULL
         ELSE TIMESTAMPDIFF(MINUTE, e.encounter_date, e.discharge_date)
    END,                                                             
    TIMESTAMPDIFF(YEAR, p.date_of_birth, e.encounter_date),

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
;
COMMIT;


-- =====================================================================
-- 9. BRIDGES -- loaded after the fact, since they need encounter_key.
-- =====================================================================
INSERT IGNORE INTO bridge_encounter_diagnoses
    (encounter_key, diagnosis_key, diagnosis_sequence)
SELECT
    f.encounter_key,
    ddx.diagnosis_key,
    ed.diagnosis_sequence
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
    rows_rejected    = COALESCE(@patient_flagged, 0),
    notes            = CONCAT('Full load OK. Facts: ',
                              (SELECT COUNT(*) FROM fact_encounters),
                              ', dx bridge: ',
                              (SELECT COUNT(*) FROM bridge_encounter_diagnoses),
                              ', px bridge: ',
                              (SELECT COUNT(*) FROM bridge_encounter_procedures),
                              ', agg pairs: ',
                              (SELECT COUNT(*) FROM agg_diagnosis_procedure_pair),
                              '. Patient values corrected: ',
                              COALESCE(@patient_flag_detail, 'none'))
WHERE load_id = @load_id;
COMMIT;

SET autocommit = 1;

ANALYZE TABLE dim_date, dim_patient, dim_provider, dim_department,
              dim_diagnosis, dim_procedure, fact_encounters,
              bridge_encounter_diagnoses, bridge_encounter_procedures,
              agg_diagnosis_procedure_pair;
