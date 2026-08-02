-- =====================================================================
-- 06_star_queries.sql
-- The same four business questions, against the star schema.
-- Results must match sql/03_oltp_queries.sql exactly.
-- =====================================================================

USE healthcare_dw;

-- ---------------------------------------------------------------------
-- Q1: Monthly encounters by specialty
--
-- OLTP: encounters -> providers -> specialties, plus DATE_FORMAT on
--       300,000 rows to derive the month.
-- Star: the month is a stored column on dim_date; the specialty is a
--       stored column on dim_provider. Neither is derived, neither needs
--       a second hop.
-- ---------------------------------------------------------------------
SELECT
    d.calendar_month                AS month,
    pr.specialty_name,
    f.encounter_type,
    SUM(f.encounter_count)          AS encounters,
    COUNT(DISTINCT f.patient_key)   AS unique_patients
FROM fact_encounters f
JOIN dim_date        d  ON d.date_key     = f.date_key
JOIN dim_provider    pr ON pr.provider_key = f.provider_key
GROUP BY d.calendar_month, pr.specialty_name, f.encounter_type
ORDER BY d.calendar_month, pr.specialty_name, f.encounter_type;


-- ---------------------------------------------------------------------
-- Q2: Top diagnosis-procedure pairs
--
-- OLTP: 2,060,000 intermediate rows built and sorted to return 20.
-- Star: those pairs were formed ONCE by the ETL. This reads 1,200
--       pre-aggregated rows.
--
-- STATED HONESTLY: this speedup comes from PRECOMPUTATION, not from the
-- star shape. The equivalent bridge-to-bridge query is included below as
-- Q2b to show what the star schema alone buys, separately from the
-- aggregate table.
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
--
-- This is the honest star-schema-only comparison for Q2. It still forms
-- ~2.06M pair rows, because pairing diagnoses with procedures inherently
-- produces pairs. What changed is the width of those rows: integers in
-- the bridges instead of VARCHAR(200) descriptions dragged through the
-- sort, with the text joined on only after grouping.
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
--
-- OLTP: a self-join over encounters, ~30,000 indexed probes.
-- Star: the self-join was executed ONCE by the ETL and stored as
--       is_readmission_30d. This is now a GROUP BY over a stored flag.
--
-- This is the clearest demonstration of the actual mechanism: the work
-- did not get cheaper, it got moved to load time.
-- ---------------------------------------------------------------------
SELECT
    pr.specialty_name,
    SUM(f.is_index_admission)                                   AS inpatient_discharges,
    SUM(f.is_readmission_30d)                                   AS readmissions_30d,
    ROUND(100 * SUM(f.is_readmission_30d)
              / NULLIF(SUM(f.is_index_admission), 0), 2)        AS readmission_rate_pct
FROM fact_encounters f
JOIN dim_provider    pr ON pr.provider_key = f.provider_key
WHERE f.is_index_admission = 1
GROUP BY pr.specialty_name
ORDER BY readmission_rate_pct DESC, pr.specialty_name;
-- ^ secondary sort key: Cardiology and Psychiatry both land on 21.84%,
--   and without a tie-break the two engines order them differently. The
--   values were identical; only the row order was not.


-- ---------------------------------------------------------------------
-- Q4: Revenue by specialty and month
--
-- OLTP: billing -> encounters -> providers -> specialties, 4 tables.
-- Star: the money is already ON the encounter fact row, so the billing
--       join disappears entirely. Month and specialty are stored columns.
--
-- NOTE ON (allowed_amount + denied_amount):
-- The ETL splits the source's single allowed_amount column into two
-- measures -- allowed_amount for claims that will actually be paid, and
-- denied_amount for claims the payer rejected. The OLTP query sums the
-- source column indiscriminately, so reproducing its exact figure here
-- requires adding the two back together (754,318,058 + 84,420,895 =
-- 838,738,953, matching the OLTP total to the cent).
--
-- The split is kept because it is strictly more useful: this schema can
-- now report realisable revenue, denied revenue, and denial rate by
-- specialty without touching claim_status at all. The OLTP query cannot
-- distinguish them without another predicate -- and, more to the point,
-- most analysts writing it would never realise they had silently counted
-- $84.4M of rejected claims as revenue.
-- ---------------------------------------------------------------------
SELECT
    d.calendar_month            AS month,
    pr.specialty_name,
    SUM(f.encounter_count)      AS claims,
    ROUND(SUM(f.allowed_amount + f.denied_amount), 2) AS total_allowed
FROM fact_encounters f
JOIN dim_date        d  ON d.date_key      = f.date_key
JOIN dim_provider    pr ON pr.provider_key = f.provider_key
GROUP BY d.calendar_month, pr.specialty_name
ORDER BY d.calendar_month, pr.specialty_name;
