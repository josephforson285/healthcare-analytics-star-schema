USE healthcare_dw;

-- ---------------------------------------------------------------------
-- Q1: Monthly encounters by specialty
-- ---------------------------------------------------------------------

SELECT
    CONCAT(FLOOR(a.ym / 100), '-', LPAD(a.ym % 100, 2, '0'))  AS month,
    sp.specialty_name,
    a.encounter_type,
    a.encounters,
    a.unique_patients
FROM (
    SELECT
        FLOOR(f.date_key / 100)         AS ym,     -- YYYYMMDD -> YYYYMM
        f.specialty_key,
        f.encounter_type,
        COUNT(*)                        AS encounters,
        COUNT(DISTINCT f.patient_key)   AS unique_patients
    FROM fact_encounters f
    GROUP BY ym, f.specialty_key, f.encounter_type
) a
JOIN dim_specialty sp ON sp.specialty_key = a.specialty_key
ORDER BY month, sp.specialty_name, a.encounter_type;


-- ---------------------------------------------------------------------
-- Q2: Top diagnosis-procedure pairs
-- Star: those pairs were formed ONCE by the ETL. This reads 1,200
--       pre-aggregated rows.
-- ---------------------------------------------------------------------
SELECT
    dd.icd10_code,
    dd.icd10_description,
    dp.cpt_code,
    dp.cpt_description,
    a.encounter_count
FROM agg_diagnosis_procedure_pair a
JOIN dim_diagnosis dd ON dd.diagnosis_key = a.diagnosis_key
JOIN dim_procedure dp ON dp.procedure_key = a.procedure_key
ORDER BY a.encounter_count DESC
LIMIT 20;


-- ---------------------------------------------------------------------
-- Q2b: the same question from the BRIDGES, with no aggregate table.
-- ---------------------------------------------------------------------
SELECT
    dd.icd10_code,
    dd.icd10_description,
    dp.cpt_code,
    dp.cpt_description,
    x.encounter_count
FROM (
    SELECT bd.diagnosis_key, bp.procedure_key,
           COUNT(DISTINCT bd.encounter_key) AS encounter_count
    FROM bridge_encounter_diagnoses  bd
    JOIN bridge_encounter_procedures bp ON bp.encounter_key = bd.encounter_key
    GROUP BY bd.diagnosis_key, bp.procedure_key
    ORDER BY encounter_count DESC
    LIMIT 20
) x
JOIN dim_diagnosis dd ON dd.diagnosis_key = x.diagnosis_key
JOIN dim_procedure dp ON dp.procedure_key = x.procedure_key
ORDER BY x.encounter_count DESC;


-- ---------------------------------------------------------------------
-- Q3: 30-day readmission rate by specialty
-- ---------------------------------------------------------------------
SELECT
    sp.specialty_name,
    SUM(f.is_index_admission)                                   AS inpatient_discharges,
    SUM(f.is_readmission_30d)                                   AS readmissions_30d,
    ROUND(100 * SUM(f.is_readmission_30d)
              / NULLIF(SUM(f.is_index_admission), 0), 2)        AS readmission_rate_pct
FROM fact_encounters f
JOIN dim_specialty   sp ON sp.specialty_key = f.specialty_key
WHERE f.is_index_admission = 1
GROUP BY sp.specialty_name
ORDER BY readmission_rate_pct DESC, sp.specialty_name;


-- ---------------------------------------------------------------------
-- Q4: Revenue by specialty and month
-- ---------------------------------------------------------------------

SELECT
    CONCAT(FLOOR(a.ym / 100), '-', LPAD(a.ym % 100, 2, '0'))  AS month,
    sp.specialty_name,
    a.claims,
    a.total_allowed
FROM (
    SELECT
        FLOOR(f.date_key / 100)     AS ym,
        f.specialty_key,
        COUNT(*)                    AS claims,
        ROUND(SUM(f.allowed_amount + f.denied_amount), 2) AS total_allowed
    FROM fact_encounters f
    GROUP BY ym, f.specialty_key
) a
JOIN dim_specialty sp ON sp.specialty_key = a.specialty_key
ORDER BY month, sp.specialty_name;


-- ---------------------------------------------------------------------
-- Q5 (supplementary): what dim_encounter_type is actually for.
-- ---------------------------------------------------------------------
SELECT
    et.type_name,
    et.is_emergency,
    et.is_overnight,
    COUNT(*)                                      AS encounters,
    ROUND(AVG(f.length_of_stay_minutes) / 60, 1)  AS avg_stay_hours,
    ROUND(SUM(f.allowed_amount + f.denied_amount) / COUNT(*), 2)
                                                  AS avg_revenue_per_encounter
FROM fact_encounters     f
JOIN dim_encounter_type  et ON et.encounter_type_key = f.encounter_type_key
GROUP BY et.type_name, et.is_emergency, et.is_overnight
ORDER BY encounters DESC;
