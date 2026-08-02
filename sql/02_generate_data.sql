-- =====================================================================
-- 02_generate_data.sql
-- Realistic-volume data generation for the OLTP schema.
--
-- WHY THIS FILE EXISTS
-- The lab brief ships 4 encounters. On 4 rows every query in Part 2 runs
-- in well under a millisecond, the fan trap does not fan, and the
-- self-join in Q3 compares 16 pairs. The bottlenecks the brief asks us to
-- find are ASYMPTOTIC -- they only appear as data grows. Measuring them
-- requires volume, so we generate it.
--
-- TARGET VOLUMES
--   specialties            12
--   departments            12   (aligned 1:1 with specialties)
--   providers              60
--   patients           50,000
--   diagnoses              40   (real ICD-10 codes)
--   procedures             30   (real CPT codes)
--   encounters        300,000   (2023-01-01 .. 2024-12-31)
--   encounter_diagnoses  ~900,000   (1-5 per encounter, avg 3)
--   encounter_procedures ~750,000   (1-4 per encounter, avg 2.5)
--   billing           300,000   (1:1 with encounters)
--
-- REPRODUCIBILITY AND RANDOMNESS
-- Every pseudo-random value is derived by hashing the row number:
--
--     CONV(SUBSTR(MD5(CONCAT(n, ':', salt)), 1, 8), 16, 10) / 4294967296
--
-- giving a uniform value in [0,1) that is identical on every run and on
-- every machine.
--
-- This deliberately does NOT use RAND(seed). MySQL's RAND(N) seeds a
-- linear congruential generator, and consecutive seeds produce output
-- that is strongly correlated rather than independent. An earlier version
-- of this script used RAND(n * 7 + 101) and friends; the result was a
-- rigid lattice -- patient_id advanced by exactly 257 and encounter_date
-- by exactly 10 days for every 4 steps in encounter_id. The dataset
-- looked random in aggregate (correct 70/20/10 type mix, correct means)
-- and was structurally degenerate underneath: no patient ever had two
-- encounters within 30 days of each other, so Q3 measured a readmission
-- rate of exactly 0.00% across all twelve specialties.
--
-- An MD5 hash has no such structure between adjacent inputs.
-- =====================================================================

USE healthcare_oltp;

SET FOREIGN_KEY_CHECKS = 0;
SET UNIQUE_CHECKS      = 0;
SET autocommit         = 0;

-- ---------------------------------------------------------------------
-- Load helper: a numbers table 1..1,000,000, built by cross-joining
-- digit tables, carrying eight precomputed hash-random columns.
-- Dropped at the end of this script.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS _numbers;
CREATE TABLE _numbers (n INT PRIMARY KEY) ENGINE=InnoDB;

INSERT INTO _numbers (n)
SELECT 1 + d0.d + d1.d*10 + d2.d*100 + d3.d*1000 + d4.d*10000 + d5.d*100000
FROM      (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d0
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d1
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d2
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d3
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d4
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d5;
COMMIT;

-- Eight independent uniform [0,1) streams, keyed on n. Precomputed once
-- here so the generation queries below stay readable.
ALTER TABLE _numbers
    ADD COLUMN r1 DOUBLE, ADD COLUMN r2 DOUBLE, ADD COLUMN r3 DOUBLE, ADD COLUMN r4 DOUBLE,
    ADD COLUMN r5 DOUBLE, ADD COLUMN r6 DOUBLE, ADD COLUMN r7 DOUBLE, ADD COLUMN r8 DOUBLE;

UPDATE _numbers SET
    r1 = CONV(SUBSTR(MD5(CONCAT(n,':1')),1,8),16,10) / 4294967296,
    r2 = CONV(SUBSTR(MD5(CONCAT(n,':2')),1,8),16,10) / 4294967296,
    r3 = CONV(SUBSTR(MD5(CONCAT(n,':3')),1,8),16,10) / 4294967296,
    r4 = CONV(SUBSTR(MD5(CONCAT(n,':4')),1,8),16,10) / 4294967296,
    r5 = CONV(SUBSTR(MD5(CONCAT(n,':5')),1,8),16,10) / 4294967296,
    r6 = CONV(SUBSTR(MD5(CONCAT(n,':6')),1,8),16,10) / 4294967296,
    r7 = CONV(SUBSTR(MD5(CONCAT(n,':7')),1,8),16,10) / 4294967296,
    r8 = CONV(SUBSTR(MD5(CONCAT(n,':8')),1,8),16,10) / 4294967296;
COMMIT;

-- ---------------------------------------------------------------------
-- specialties (12)
-- ---------------------------------------------------------------------
INSERT INTO specialties (specialty_id, specialty_name, specialty_code) VALUES
    ( 1, 'Cardiology',          'CARD'),
    ( 2, 'Internal Medicine',   'IM'),
    ( 3, 'Emergency',           'ER'),
    ( 4, 'Orthopedics',         'ORTHO'),
    ( 5, 'Pulmonology',         'PULM'),
    ( 6, 'Endocrinology',       'ENDO'),
    ( 7, 'Nephrology',          'NEPH'),
    ( 8, 'Gastroenterology',    'GI'),
    ( 9, 'Neurology',           'NEURO'),
    (10, 'Psychiatry',          'PSY'),
    (11, 'Family Medicine',     'FM'),
    (12, 'Oncology',            'ONC');

-- ---------------------------------------------------------------------
-- departments (12, aligned 1:1 with specialties so that a provider's
-- department is clinically consistent with their specialty)
-- ---------------------------------------------------------------------
INSERT INTO departments (department_id, department_name, floor, capacity) VALUES
    ( 1, 'Cardiology Unit',        3, 20),
    ( 2, 'Internal Medicine',      2, 30),
    ( 3, 'Emergency',              1, 45),
    ( 4, 'Orthopedics Unit',       4, 18),
    ( 5, 'Pulmonology Unit',       3, 16),
    ( 6, 'Endocrinology Clinic',   2, 12),
    ( 7, 'Nephrology / Dialysis',  5, 22),
    ( 8, 'Gastroenterology Unit',  4, 14),
    ( 9, 'Neurology Unit',         5, 20),
    (10, 'Behavioral Health',      6, 25),
    (11, 'Family Medicine Clinic', 1, 35),
    (12, 'Oncology / Infusion',    6, 28);

-- ---------------------------------------------------------------------
-- providers (60) -- ids 101..160, department aligned to specialty
-- ---------------------------------------------------------------------
INSERT INTO providers (provider_id, first_name, last_name, credential, specialty_id, department_id)
SELECT
    100 + n,
    ELT(1 + ((n * 3) % 20), 'James','Sarah','Michael','Amina','David','Grace','Daniel','Fatima',
                            'Kwame','Emily','Robert','Linda','Yaw','Nadia','Peter','Abena',
                            'Thomas','Chloe','Ibrahim','Esi'),
    ELT(1 + ((n * 7) % 20), 'Chen','Williams','Rodriguez','Mensah','Okafor','Patel','Nguyen','Boateng',
                            'Silva','Kim','Adjei','Hassan','Owusu','Novak','Dube','Asante',
                            'Ferreira','Oduro','Kimani','Lindqvist'),
    ELT(1 + (n % 4), 'MD','DO','NP','PA'),
    1 + (n % 12),
    1 + (n % 12)
FROM _numbers WHERE n <= 60;

-- ---------------------------------------------------------------------
-- patients (50,000)
-- ---------------------------------------------------------------------
INSERT INTO patients (patient_id, first_name, last_name, date_of_birth, gender, mrn)
SELECT
    1000 + n,
    ELT(1 + ((n * 11) % 20), 'John','Jane','Robert','Mary','Kofi','Ama','Samuel','Priya',
                             'Ahmed','Sofia','George','Ruth','Kwesi','Leila','Henry','Adwoa',
                             'Victor','Hannah','Musa','Akosua'),
    ELT(1 + ((n * 13) % 20), 'Doe','Smith','Johnson','Mensah','Ali','Sharma','Tran','Appiah',
                             'Costa','Park','Darko','Yusuf','Baffour','Horvath','Ncube','Amoah',
                             'Santos','Antwi','Wanjiru','Berg'),
    DATE_ADD('1930-01-01', INTERVAL FLOOR(r7 * 29200) DAY),  -- ~1930..2010
    IF(r8 < 0.51, 'F', 'M'),
    CONCAT('MRN', LPAD(n, 6, '0'))
FROM _numbers WHERE n <= 50000;
COMMIT;

-- ---------------------------------------------------------------------
-- diagnoses (40 real ICD-10 codes)
-- Ordered roughly most-common first: the generator skews toward low ids,
-- which produces a realistic long-tail diagnosis distribution.
-- ---------------------------------------------------------------------
INSERT INTO diagnoses (diagnosis_id, icd10_code, icd10_description) VALUES
    (3001,'I10',     'Essential (primary) hypertension'),
    (3002,'E11.9',   'Type 2 diabetes mellitus without complications'),
    (3003,'E78.5',   'Hyperlipidemia, unspecified'),
    (3004,'Z00.00',  'General adult medical examination'),
    (3005,'M54.5',   'Low back pain'),
    (3006,'J45.909', 'Unspecified asthma, uncomplicated'),
    (3007,'K21.9',   'GERD without esophagitis'),
    (3008,'F41.9',   'Anxiety disorder, unspecified'),
    (3009,'E03.9',   'Hypothyroidism, unspecified'),
    (3010,'F32.9',   'Major depressive disorder, single episode'),
    (3011,'I50.9',   'Heart failure, unspecified'),
    (3012,'J44.9',   'COPD, unspecified'),
    (3013,'N18.3',   'Chronic kidney disease, stage 3'),
    (3014,'I48.91',  'Unspecified atrial fibrillation'),
    (3015,'E66.9',   'Obesity, unspecified'),
    (3016,'D64.9',   'Anemia, unspecified'),
    (3017,'R07.9',   'Chest pain, unspecified'),
    (3018,'R10.9',   'Unspecified abdominal pain'),
    (3019,'J06.9',   'Acute upper respiratory infection'),
    (3020,'N39.0',   'Urinary tract infection, site not specified'),
    (3021,'M17.9',   'Osteoarthritis of knee, unspecified'),
    (3022,'G47.33',  'Obstructive sleep apnea'),
    (3023,'I25.10',  'Atherosclerotic heart disease of native coronary artery'),
    (3024,'R51.9',   'Headache, unspecified'),
    (3025,'J18.9',   'Pneumonia, unspecified organism'),
    (3026,'R42',     'Dizziness and giddiness'),
    (3027,'M79.10',  'Myalgia, unspecified site'),
    (3028,'B34.9',   'Viral infection, unspecified'),
    (3029,'H66.90',  'Otitis media, unspecified'),
    (3030,'Z79.4',   'Long term (current) use of insulin'),
    (3031,'L03.90',  'Cellulitis, unspecified'),
    (3032,'E86.0',   'Dehydration'),
    (3033,'R55',     'Syncope and collapse'),
    (3034,'K92.2',   'Gastrointestinal hemorrhage, unspecified'),
    (3035,'N17.9',   'Acute kidney failure, unspecified'),
    (3036,'I63.9',   'Cerebral infarction, unspecified'),
    (3037,'I21.4',   'Non-ST elevation myocardial infarction'),
    (3038,'A41.9',   'Sepsis, unspecified organism'),
    (3039,'S72.001A','Fracture of unspecified part of neck of femur, initial'),
    (3040,'T78.40XA','Allergy, unspecified, initial encounter');

-- ---------------------------------------------------------------------
-- procedures (30 real CPT codes)
-- ---------------------------------------------------------------------
INSERT INTO procedures (procedure_id, cpt_code, cpt_description) VALUES
    (4001,'99213','Office/outpatient visit, established patient, low complexity'),
    (4002,'99214','Office/outpatient visit, established patient, moderate complexity'),
    (4003,'85025','Complete blood count with automated differential'),
    (4004,'80053','Comprehensive metabolic panel'),
    (4005,'36415','Collection of venous blood by venipuncture'),
    (4006,'93000','Electrocardiogram, routine ECG with interpretation'),
    (4007,'80061','Lipid panel'),
    (4008,'83036','Hemoglobin A1c'),
    (4009,'81003','Urinalysis, automated, without microscopy'),
    (4010,'99203','Office/outpatient visit, new patient, low complexity'),
    (4011,'71046','Radiologic examination, chest, 2 views'),
    (4012,'84443','Thyroid stimulating hormone assay'),
    (4013,'99283','Emergency department visit, low complexity'),
    (4014,'99284','Emergency department visit, moderate complexity'),
    (4015,'99285','Emergency department visit, high complexity'),
    (4016,'93306','Echocardiography, transthoracic, complete'),
    (4017,'70450','CT head/brain without contrast'),
    (4018,'74177','CT abdomen and pelvis with contrast'),
    (4019,'94640','Pressurized inhalation treatment'),
    (4020,'90471','Immunization administration'),
    (4021,'99223','Initial hospital care, high complexity'),
    (4022,'99232','Subsequent hospital care, moderate complexity'),
    (4023,'99238','Hospital discharge day management, 30 minutes or less'),
    (4024,'72148','MRI lumbar spine without contrast'),
    (4025,'20610','Arthrocentesis, aspiration/injection, major joint'),
    (4026,'12001','Simple repair of superficial wounds'),
    (4027,'45378','Colonoscopy, diagnostic'),
    (4028,'43239','Upper GI endoscopy with biopsy'),
    (4029,'29881','Arthroscopy, knee, surgical, with meniscectomy'),
    (4030,'99291','Critical care, first 30-74 minutes');
COMMIT;

-- ---------------------------------------------------------------------
-- encounters (300,000)
--   type mix : 70% Outpatient, 20% ER, 10% Inpatient
--   date     : uniform over 730 days (2023-01-01 .. 2024-12-31)
--   LOS      : Outpatient 20-150 min, ER 1.5-11.5 h, Inpatient 1-10 days
--   dept     : inherited from the provider, so it stays clinically sane
-- ---------------------------------------------------------------------
INSERT INTO encounters
    (encounter_id, patient_id, provider_id, encounter_type, encounter_date, discharge_date, department_id)
SELECT
    b.n,
    b.patient_id,
    b.provider_id,
    b.encounter_type,
    b.encounter_date,
    CASE b.encounter_type
        WHEN 'Outpatient' THEN b.encounter_date + INTERVAL (20 + FLOOR(b.r5 * 130)) MINUTE
        WHEN 'ER'         THEN b.encounter_date + INTERVAL (90 + FLOOR(b.r5 * 600)) MINUTE
        ELSE                   b.encounter_date + INTERVAL (24 + FLOOR(b.r5 * 216)) HOUR
    END,
    b.department_id
FROM (
    SELECT
        r.n,
        1000 + 1 + FLOOR(r.r1 * 50000)                                              AS patient_id,
        p.provider_id,
        p.department_id,
        CASE WHEN r.r3 < 0.70 THEN 'Outpatient'
             WHEN r.r3 < 0.90 THEN 'ER'
             ELSE                   'Inpatient' END                                 AS encounter_type,
        TIMESTAMP('2023-01-01 00:00:00') + INTERVAL FLOOR(r.r4 * 1051200) MINUTE     AS encounter_date,
        r.r5
    FROM (
        SELECT n, r1, r2, r3, r4, r5
        FROM _numbers WHERE n <= 300000
    ) r
    JOIN providers p ON p.provider_id = 100 + 1 + FLOOR(r.r2 * 60)
) b;
COMMIT;

-- ---------------------------------------------------------------------
-- encounter_diagnoses (~900,000) -- 1 to 5 rows per encounter.
--
-- Diagnosis choice is skewed with POW(r, 1.7) so low ids (the common
-- chronic conditions listed first) dominate -- a realistic long tail.
--
-- Independent random draws per sequence WILL collide (~3% of rows picked
-- the same diagnosis twice on one encounter). The source schema has no
-- UNIQUE(encounter_id, diagnosis_id) to stop that, but it is clinically
-- nonsensical, so we generate freely and then dedupe. Deduping after the
-- fact preserves the skewed distribution; forcing distinctness during
-- generation (e.g. a fixed stride between sequences) would make every
-- encounter's diagnosis set an arithmetic progression -- distinct, but
-- with completely artificial co-occurrence structure.
-- ---------------------------------------------------------------------
-- Dedupe happens in a staging table, NOT in encounter_diagnoses itself.
-- Two reasons, both learned the hard way:
--   1. A self-join DELETE against the live 900k-row table is a nested loop
--      over 900k x 900k with no usable index -- it ran past ten minutes
--      before being killed. (Exactly the Q3 failure mode, met by accident.)
--   2. Adding a temp index to fix that then cannot be dropped: InnoDB
--      binds it to the encounter_id foreign key. The OLTP schema has to
--      stay byte-identical to the brief or Part 2 measures our tuning
--      instead of the brief's schema.
-- Staging sidesteps both: index freely on a table with no constraints,
-- then insert the already-clean result exactly once.
DROP TABLE IF EXISTS _ed_stage;
CREATE TABLE _ed_stage (
    encounter_id INT, diagnosis_id INT, seq INT,
    KEY k (encounter_id, diagnosis_id)
) ENGINE=InnoDB;

INSERT INTO _ed_stage (encounter_id, diagnosis_id, seq)
SELECT
    e.encounter_id,
    3001 + FLOOR(POW(CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':',s.n,':dx')),1,8),16,10)/4294967296, 1.7) * 40),
    s.n
FROM encounters e
JOIN _numbers s ON s.n <= 5
WHERE s.n <= 1 + FLOOR(CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':dxn')),1,8),16,10)/4294967296 * 5);

-- Drop repeats (keep the earliest sequence -- the more severe coding),
-- then renumber so diagnosis_sequence stays contiguous 1..n per encounter.
INSERT INTO encounter_diagnoses (encounter_diagnosis_id, encounter_id, diagnosis_id, diagnosis_sequence)
SELECT b.encounter_id * 10 + b.new_seq, b.encounter_id, b.diagnosis_id, b.new_seq
FROM (
    SELECT encounter_id, diagnosis_id,
           ROW_NUMBER() OVER (PARTITION BY encounter_id ORDER BY seq) AS new_seq
    FROM (
        SELECT encounter_id, diagnosis_id, seq,
               ROW_NUMBER() OVER (PARTITION BY encounter_id, diagnosis_id ORDER BY seq) AS dup_rank
        FROM _ed_stage
    ) a
    WHERE a.dup_rank = 1
) b;

DROP TABLE _ed_stage;
COMMIT;

-- ---------------------------------------------------------------------
-- encounter_procedures (~750,000) -- 1 to 4 rows per encounter.
--
-- Procedure date lands on the encounter date, or later for inpatients
-- (procedures happen throughout a stay, not just on admission). The
-- offset is clamped with LEAST(..., DATEDIFF(discharge, encounter)) so a
-- procedure can never be dated after the patient went home. Nothing in
-- the source schema enforces that -- there is no CHECK constraint tying
-- procedure_date to the encounter window -- so the generator has to.
--
-- Deduped for the same reason as diagnoses: the same procedure billed
-- twice on one encounter with no distinguishing attribute is a data
-- error, not a real repeat.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS _ep_stage;
CREATE TABLE _ep_stage (
    encounter_id INT, procedure_id INT, seq INT, procedure_date DATE,
    KEY k (encounter_id, procedure_id)
) ENGINE=InnoDB;

INSERT INTO _ep_stage (encounter_id, procedure_id, seq, procedure_date)
SELECT
    e.encounter_id,
    4001 + FLOOR(POW(CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':',s.n,':px')),1,8),16,10)/4294967296, 1.5) * 30),
    s.n,
    DATE(e.encounter_date)
        + INTERVAL LEAST(
              IF(e.encounter_type = 'Inpatient', FLOOR(CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':',s.n,':pxd')),1,8),16,10)/4294967296 * 4), 0),
              DATEDIFF(e.discharge_date, e.encounter_date)
          ) DAY
FROM encounters e
JOIN _numbers s ON s.n <= 4
WHERE s.n <= 1 + FLOOR(CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':pxn')),1,8),16,10)/4294967296 * 4);

INSERT INTO encounter_procedures (encounter_procedure_id, encounter_id, procedure_id, procedure_date)
SELECT b.encounter_id * 10 + b.new_seq, b.encounter_id, b.procedure_id, b.procedure_date
FROM (
    SELECT encounter_id, procedure_id, procedure_date,
           ROW_NUMBER() OVER (PARTITION BY encounter_id ORDER BY seq) AS new_seq
    FROM (
        SELECT encounter_id, procedure_id, seq, procedure_date,
               ROW_NUMBER() OVER (PARTITION BY encounter_id, procedure_id ORDER BY seq) AS dup_rank
        FROM _ep_stage
    ) a
    WHERE a.dup_rank = 1
) b;

DROP TABLE _ep_stage;
COMMIT;

-- ---------------------------------------------------------------------
-- billing (300,000) -- one claim per encounter.
--   claim_amount   : scaled by encounter type
--   allowed_amount : 55%-85% of claim (payer contract adjustment)
--   claim_date     : 1-20 days after discharge
--   claim_status   : 75% Paid, 15% Pending, 10% Denied
-- ---------------------------------------------------------------------
INSERT INTO billing (billing_id, encounter_id, claim_amount, allowed_amount, claim_date, claim_status)
SELECT
    b.encounter_id,
    b.encounter_id,
    b.claim_amount,
    ROUND(b.claim_amount * (0.55 + b.r3 * 0.30), 2),
    b.claim_date,
    CASE WHEN b.r4 < 0.75 THEN 'Paid'
         WHEN b.r4 < 0.90 THEN 'Pending'
         ELSE                   'Denied' END
FROM (
    SELECT
        e.encounter_id,
        ROUND(
            CASE e.encounter_type
                WHEN 'Outpatient' THEN   150 + CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':amt')),1,8),16,10)/4294967296 *   450
                WHEN 'ER'         THEN   800 + CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':amt')),1,8),16,10)/4294967296 *  3200
                ELSE                    5000 + CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':amt')),1,8),16,10)/4294967296 * 55000
            END, 2)                                                          AS claim_amount,
        DATE(e.discharge_date)
            + INTERVAL (1 + FLOOR(CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':lag')),1,8),16,10)/4294967296 * 20)) DAY  AS claim_date,
        CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':adj')),1,8),16,10)/4294967296                                       AS r3,
        CONV(SUBSTR(MD5(CONCAT(e.encounter_id,':sts')),1,8),16,10)/4294967296                                       AS r4
    FROM encounters e
) b;
COMMIT;

-- ---------------------------------------------------------------------
-- Clean up the load helper and restore session settings.
-- ---------------------------------------------------------------------
DROP TABLE _numbers;

SET FOREIGN_KEY_CHECKS = 1;
SET UNIQUE_CHECKS      = 1;
SET autocommit         = 1;

ANALYZE TABLE patients, providers, encounters,
              encounter_diagnoses, encounter_procedures, billing;
