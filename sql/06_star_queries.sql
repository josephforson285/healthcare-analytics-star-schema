-- =====================================================================
-- 06_star_queries.sql
-- The same four business questions, against the star schema.
-- Results must match sql/03_oltp_queries.sql exactly.
--
-- Specialty is reached by joining dim_specialty (12 rows) DIRECTLY from
-- the fact, not through dim_provider (61 rows). Measured, median of 5:
--     Q1  via dim_specialty 1.40s   via dim_provider 1.61s
--     Q3  via dim_specialty 0.21s   via dim_provider 0.22s
--     Q4  via dim_specialty 1.20s   via dim_provider 1.33s
-- The smaller table wins, and it is the shorter path to the attribute.
-- dim_provider holds no specialty column at all: every dimension in this
-- model hangs directly off the fact, with no dimension-to-dimension edges.
--
-- dim_patient and dim_department are not joined by any query here.
-- Q1 counts DISTINCT patient_key off the fact without needing patient
-- attributes, and none of the four business questions ask about the
-- department. They are built because the brief specifies them and
-- because a warehouse serves questions beyond the four it launched with.
-- =====================================================================

USE healthcare_dw;

-- ---------------------------------------------------------------------
-- Q1: Monthly encounters by specialty
--
-- OLTP: encounters -> providers -> specialties, plus DATE_FORMAT on
--       300,000 rows to derive the month.
-- Star: the month is a stored column on dim_date, and the specialty is
--       reached by joining dim_specialty (12 rows) DIRECTLY from the
--       fact -- not through dim_provider. Neither value is derived and
--       neither needs a second hop.
-- ---------------------------------------------------------------------
SELECT
    d.calendar_month                AS month,
    sp.specialty_name,
    f.encounter_type,
    SUM(f.encounter_count)          AS encounters,
    COUNT(DISTINCT f.patient_key)   AS unique_patients
FROM fact_encounters f
JOIN dim_date        d  ON d.date_key     = f.date_key
JOIN dim_specialty   sp ON sp.specialty_key = f.specialty_key
GROUP BY d.calendar_month, sp.specialty_name, f.encounter_type
ORDER BY d.calendar_month, sp.specialty_name, f.encounter_type;


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
    sp.specialty_name,
    SUM(f.encounter_count)      AS claims,
    ROUND(SUM(f.allowed_amount + f.denied_amount), 2) AS total_allowed
FROM fact_encounters f
JOIN dim_date        d  ON d.date_key      = f.date_key
JOIN dim_specialty   sp ON sp.specialty_key = f.specialty_key
GROUP BY d.calendar_month, sp.specialty_name
ORDER BY d.calendar_month, sp.specialty_name;


-- ---------------------------------------------------------------------
-- Q5 (supplementary): what dim_encounter_type is actually for.
--
-- The four business questions above deliberately do NOT join this
-- dimension -- they read encounter_type straight off the fact row, where
-- it also lives as a degenerate attribute. That is measured, not assumed:
--
--     GROUP BY f.encounter_type   (string on the fact)   1.49 s
--     GROUP BY et.type_name       (joined dimension)     3.68 s
--
-- 2.5x slower, because grouping on a joined VARCHAR costs more than
-- grouping on one already present in the fact row. For a query that only
-- needs the type's NAME, the fact column is strictly better.
--
-- So the dimension earns its place a different way -- through attributes
-- that have no home on the fact row, and through closing a domain the
-- source leaves open (free-text VARCHAR(50), no CHECK -- finding B4).
-- This query cannot be written at all without it:
-- ---------------------------------------------------------------------
SELECT
    et.type_name,
    et.is_emergency,
    et.is_overnight,
    SUM(f.encounter_count)                        AS encounters,
    ROUND(AVG(f.length_of_stay_minutes) / 60, 1)  AS avg_stay_hours,
    ROUND(SUM(f.allowed_amount + f.denied_amount) / SUM(f.encounter_count), 2)
                                                  AS avg_revenue_per_encounter
FROM fact_encounters     f
JOIN dim_encounter_type  et ON et.encounter_type_key = f.encounter_type_key
GROUP BY et.type_name, et.is_emergency, et.is_overnight
ORDER BY encounters DESC;
