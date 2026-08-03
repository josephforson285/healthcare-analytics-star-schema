# ETL Logic — a walkthrough of Part 3.4

A teaching companion to [`etl_design.txt`](etl_design.txt). That file is the
deliverable; this one explains *how* it was built and *why* each decision went
the way it did, with the real code beside each answer.

The brief asks ten questions across four sections. Every one is answered below,
in the brief's own order.

---

## The one fact that shapes every answer

Before any of the ten questions, one thing has to be established, because it
makes several standard answers unavailable:

```sql
SELECT COUNT(*) FROM information_schema.columns
WHERE table_schema='healthcare_oltp'
  AND (column_name LIKE '%updated%' OR column_name LIKE '%created%'
       OR column_name LIKE '%modified%' OR column_name LIKE '%version%');
-- returns 0
```

**Zero change-tracking columns across all ten source tables.** No `updated_at`,
no `created_at`, no version number, nothing.

That is finding **B9** in the [findings register](00-findings-and-assumptions.md),
and it means the textbook answer to "how do you load incrementally" —
`WHERE updated_at > :last_load` — simply cannot be written here. Sections 1.3
and 4 below are both workarounds for this single missing feature.

---

## 1. Dimension Load Logic

### Q: How do you populate `dim_patient` from the `patients` table?

Two inserts, and the order matters.

**First the unknown member**, before any real data:

```sql
INSERT INTO dim_patient (patient_key, patient_id, mrn, first_name, last_name,
                          date_of_birth, gender, effective_from, effective_to, is_current)
VALUES (-1, -1, 'UNKNOWN', 'Unknown', 'Unknown',
        NULL, 'U', '1900-01-01', '9999-12-31', 1);
```

`patient_key = -1` is inserted **explicitly**, not auto-assigned. This is where a
fact row points when its patient lookup fails.

Why it exists at all: the alternative is dropping the encounter. That loses real
clinical activity in order to keep the model tidy, which is backwards. With an
unknown member the encounter is still counted, revenue still reconciles, and the
data-quality gap shows up as a visible row on a report instead of a silent
shortfall nobody notices.

**Then one row per source patient.** This was the first version, and it is worth
seeing before the version that replaced it:

```sql
-- FIRST ATTEMPT -- superseded, see "bad patient data" below
INSERT INTO dim_patient (patient_id, mrn, first_name, last_name, date_of_birth,
                          gender, effective_from, effective_to, is_current)
SELECT
    p.patient_id,
    p.mrn,
    p.first_name,
    p.last_name,
    p.date_of_birth,
    COALESCE(p.gender, 'U'),                    -- GUARD B1
    '1900-01-01', '9999-12-31', 1
FROM healthcare_oltp.patients p;
```

Three things are happening beyond a plain copy:

| In the code | Why |
|---|---|
| `COALESCE(p.gender, 'U')` | **GUARD B1** — `gender` is nullable in the source. A `NULL` in a grouping column silently drops rows from `GROUP BY` output, so it becomes an explicit `'U'` instead |
| `'1900-01-01', '9999-12-31', 1` | opens version 1, valid from the beginning of time until further notice |
| `patient_key` auto-assigned | the fact points at **this**, never at `patient_id` — so a re-keyed source cannot corrupt history |

50,000 rows in, 50,001 out. A straight `SELECT` — no join, no aggregation.

That version turned out to be insufficient, which is the next section.

**Note on what is deliberately absent:** age. A patient's age changes with the
calendar rather than with any source event, so a stored age band would rot
silently and corrupt historical reporting. Age at the time of care is computed
once during the fact load and stored on the fact row, because it is a property
of the *encounter*.

#### What happens when bad patient data arrives?

This was tested rather than assumed, and the first answer was **it just enters**.
Four deliberately broken patients were inserted into the source and the load run:

| Injected | Result before validation existed |
|---|---|
| `gender = 'Z'` | loaded as `'Z'` |
| both names `NULL` | loaded as `NULL`/`NULL` |
| `date_of_birth = '2099-01-01'` | **loaded — a patient born in 2099** |
| `date_of_birth = NULL` | loaded as `NULL` |

`COALESCE(p.gender, 'U')` handles a *NULL* gender and does nothing about a
*wrong* one. Nothing at all looked at the date of birth.

There are now **three layers**, and it matters that they do different jobs:

**Layer 1 — normalise in the ETL.** A staging table validates before the insert:

```sql
-- domain closure: NULL *and* any unexpected value both become 'U'
CASE WHEN p.gender IN ('F','M') THEN p.gender ELSE 'U' END,

-- temporal sanity: cannot be born in the future or before 1900
CASE WHEN p.date_of_birth BETWEEN '1900-01-01' AND CURDATE()
     THEN p.date_of_birth ELSE NULL END,
```

An implausible date becomes `NULL` rather than propagating into
`patient_age_years` across 300,000 fact rows.

**Layer 2 — count what was corrected.** The staging table carries flags, so a
correction is *countable* rather than silently absorbed:

```sql
(p.gender IS NULL OR p.gender NOT IN ('F','M'))               AS flag_gender,
(p.date_of_birth IS NOT NULL
 AND p.date_of_birth NOT BETWEEN '1900-01-01' AND CURDATE())  AS flag_dob,
(p.first_name IS NULL AND p.last_name IS NULL)                AS flag_noname
```

**Layer 3 — CHECK constraints, so the table refuses bad writes for ever.**

```sql
CONSTRAINT chk_p_gender CHECK (gender IN ('F','M','U')),
CONSTRAINT chk_p_dob    CHECK (date_of_birth IS NULL OR date_of_birth >= '1900-01-01'),
```

Layer 1 protects the load path. Layer 3 protects everything else — a manual
`UPDATE dim_patient SET gender='Z'` now fails with `ERROR 3819` instead of
succeeding.

**Why "not born in the future" is only in the ETL and not a CHECK:** MySQL
rejects non-deterministic functions inside a constraint —
`CHECK (d <= CURRENT_DATE)` fails with `ERROR 3814`. So the lower bound is a
constraint and the upper bound is ETL logic. Worth knowing, because the split
looks arbitrary until you hit that error.

Re-running the same four bad patients after all this:

| Injected | Result now | Counted |
|---|---|---|
| `gender = 'Z'` | normalised to `'U'` | ✅ |
| both names `NULL` | **kept** as-is | ✅ |
| `date_of_birth = '2099-01-01'` | set to `NULL` | ✅ |
| `date_of_birth = NULL` | stays `NULL` | — |

`rows_rejected: 3`, with `notes: gender=1 dob=1 noname=1`.

Note that the nameless patient is **kept**. That is the same principle as the
unknown member: a patient who exists with no recorded name is still a real
patient, and dropping the row would lose every encounter attached to them. The
row loads, the gap is flagged, and someone can go and look.

### Q: How do you populate `dim_date` (one-time load)?

This is the only dimension with **no source table** — there is no calendar
anywhere in `healthcare_oltp`. So it is *generated*, not extracted.

```sql
INSERT INTO dim_date (date_key, full_date, year, quarter, month, calendar_month,
                      day_of_month, day_of_week, day_of_year, week_of_year, is_weekend)
SELECT
    CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED),   -- 20240612
    d, YEAR(d), QUARTER(d), MONTH(d),
    DATE_FORMAT(d, '%Y-%m'),                      -- '2024-06'
    DAYOFMONTH(d), WEEKDAY(d) + 1, DAYOFYEAR(d), WEEK(d, 3),
    IF(WEEKDAY(d) >= 5, 1, 0)
FROM (
    SELECT DATE('2023-01-01') + INTERVAL seq DAY AS d
    FROM ( /* digit tables cross-joined to produce 0..3999 */ ) s
    WHERE seq <= DATEDIFF('2025-12-31', '2023-01-01')
) cal;
```

Read it inside-out:

1. **Cross-join digit tables** (`0-9 × 0-9 × 0-9 × 0-3`) → integers `0…3999`
2. **`DATE('2023-01-01') + INTERVAL seq DAY`** → turn each integer into a date
3. **`WHERE seq <= DATEDIFF(...)`** → cut off at 1,096 days
4. **Derive every attribute** from that one date

Three deliberate choices:

**`date_key` is `YYYYMMDD`, not a sequence.** This is the decision that paid off
much later: `FLOOR(date_key / 100)` gives you the month *arithmetically*, which
is why Q1 never joins `dim_date` at all and runs 2× faster than the OLTP
original.

The trade-off, worth knowing: `YYYYMMDD` is **useless for day arithmetic**.
`20230201 - 20230131 = 70`, not 1. Day differences require joining `dim_date` and
using `DATEDIFF` on `full_date`. A sequential key would be the reverse — good at
day maths, useless for month extraction. `YYYYMMDD` was right here because Q1 and
Q4 group by month and nothing groups by day-difference.

**The range extends to 2025-12-31** — a full year past the data. A late-arriving
fact must always find a date key, because a missing one fails the foreign key and
aborts the entire load.

**Loaded once, never refreshed.** Nothing in the source can change it. You would
only touch it every few years to extend the range.

### Q: How do you handle updates to dimensions?

Not every dimension needs the same answer, so the first step was deciding the
SCD type per table:

| Dimension | Type | Reasoning |
|---|---|---|
| `dim_date` | never refreshed | nothing in the source can change it |
| `dim_department` | **Type 1** — overwrite | a floor or capacity changing is a *correction*, not a historical event |
| `dim_specialty` | **Type 1** | same |
| `dim_diagnosis` / `dim_procedure` | **Type 1** | reference data, conformed on code |
| `dim_encounter_type` | static, 3 rows | enumerated in the ETL, not sourced |
| `dim_patient` | **Type 2** — versioned | a correction must not rewrite history |
| `dim_provider` | **Type 2** | same |

**Six of the eight need no update logic at all.** Type 1 tables are fully
rebuilt each load — no comparison needed, because you always write whatever the
source currently says.

**The two Type 2 tables** are where it gets interesting, because with no
`updated_at` the only available signal is comparing content:

```
FOR each patient in source:
    incoming := MD5(mrn | first_name | last_name | date_of_birth | gender)
    current  := MD5(same columns, from the stored dim row WHERE is_current = 1)

    IF no current row:      INSERT new, is_current = 1
    ELIF hashes differ:     UPDATE old SET effective_to = TODAY - 1, is_current = 0
                            INSERT new SET effective_from = TODAY, is_current = 1
    ELSE:                   do nothing
```

**This was demonstrated live during the build.** Patient 1001's gender was
changed in the source, and `dim_patient` produced two rows — the old one closed
with `is_current = 0`, a new one opened. That is why encounters from 2023 keep
pointing at the old `patient_key`, and last year's published figures still
reconcile.

Two things stated honestly rather than glossed:

**The hash tells you *that* something changed, not *when*.** So `effective_from`
gets stamped with the load date, not the true event date. Direct consequence of
B9 — with a source timestamp it would be accurate.

**No dimension stores its hash.** In every case the hash covers only attributes
that table already holds, so it is recomputed at comparison time rather than
persisted. `dim_patient`'s stored hash was verified to match a recomputation on
50,000 of 50,000 rows before being dropped.

---

## 2. Fact Table Load Logic

### Q: For each encounter, how do you look up dimension keys?

```sql
FROM      healthcare_oltp.encounters e
LEFT JOIN healthcare_oltp.patients   p    ON p.patient_id     = e.patient_id
LEFT JOIN dim_patient                dp   ON dp.patient_id    = e.patient_id  AND dp.is_current = 1
LEFT JOIN dim_provider               dpr  ON dpr.provider_id  = e.provider_id AND dpr.is_current = 1
LEFT JOIN dim_department             dd   ON dd.department_id  = e.department_id
LEFT JOIN healthcare_oltp.providers  psrc ON psrc.provider_id = e.provider_id
LEFT JOIN dim_specialty              dsp  ON dsp.specialty_id = psrc.specialty_id
LEFT JOIN dim_encounter_type         det  ON det.type_name    = TRIM(e.encounter_type)
```

Then every key is resolved defensively:

```sql
COALESCE(dp.patient_key,   -1),          -- GUARD B1
COALESCE(dpr.provider_key, -1),          -- GUARD B1
COALESCE(dd.department_key, -1),          -- GUARD B1
COALESCE(dsp.specialty_key, -1),
COALESCE(det.encounter_type_key, -1),    -- GUARD B4
```

Three details that are easy to miss:

**`LEFT JOIN`, never `INNER`.** The source FKs are nullable (B1). An inner join
would silently *drop* any encounter whose patient or provider reference is
missing — losing real facts to protect referential neatness.

**`AND dp.is_current = 1` on the Type 2 lookups.** On an initial load every row
is current, so it is a no-op. It becomes essential the moment a dimension has
more than one version, and writing it from the start avoids a load that works
today and quietly double-counts later.

**`det.type_name = TRIM(e.encounter_type)`** — this is GUARD B4 doing real work.
The source column is free-text `VARCHAR(50)` with no `CHECK`, so `'ER'`, `'er'`
and `'Emergency'` are all storable. Anything that fails to match one of the three
known values lands on the `-1` unknown member, where it is visible, rather than
silently becoming a fourth encounter type.

**A production refinement not implemented:** a strictly correct Type 2 lookup
matches the version in effect *on the encounter date*:

```sql
WHERE patient_id = e.patient_id
  AND e.encounter_date BETWEEN effective_from AND effective_to
```

With one version per row the two are identical. They diverge the moment history
exists, and the date-ranged form is the one that keeps old reports reconciling.
Noted rather than built, because it cannot be tested against a single-version
dimension.

### Q: How do you calculate pre-aggregated metrics?

Four separate passes into temporary tables, then joined in. Doing it in one
statement would mean scanning the junction tables once per column.

**8a — Billing, collapsed to encounter grain first:**

```sql
INSERT INTO _bill
SELECT
    b.encounter_id,
    SUM(COALESCE(b.claim_amount, 0)),
    SUM(CASE WHEN b.claim_status = 'Denied' THEN 0 ELSE COALESCE(b.allowed_amount,0) END),
    SUM(CASE WHEN b.claim_status = 'Denied' THEN COALESCE(b.allowed_amount,0) ELSE 0 END),
    CASE WHEN SUM(b.claim_status='Denied')  > 0 THEN 'Denied'
         WHEN SUM(b.claim_status='Pending') > 0 THEN 'Pending'
         ELSE 'Paid' END
FROM healthcare_oltp.billing b
GROUP BY b.encounter_id;                   -- GUARD B7
```

That `GROUP BY` is **GUARD B7**. `billing.encounter_id` is not `UNIQUE` in the
source, so a double-billed encounter would be counted twice by a naive join.
Aggregating first neutralises it once, at load, instead of in every downstream
query forever.

It also splits `allowed` from `denied`, which surfaced that the OLTP query had
been silently counting **$84.4M of rejected claims as revenue**.

**8b — Counts, with `DISTINCT` not `COUNT(*)`:**

```sql
INSERT INTO _dx
SELECT ed.encounter_id, COUNT(DISTINCT ed.diagnosis_id)   -- GUARD B2
FROM healthcare_oltp.encounter_diagnoses ed
GROUP BY ed.encounter_id;
```

`DISTINCT` is GUARD B2/B3: the source permits the same diagnosis twice on one
encounter, and the stored count must not inherit that.

**8c — The readmission flag, the highest-value computation in the whole ETL:**

```sql
INSERT INTO _readmit
SELECT DISTINCT i.encounter_id
FROM healthcare_oltp.encounters i
JOIN healthcare_oltp.encounters r
  ON  r.patient_id     =  i.patient_id
  AND r.encounter_id  <>  i.encounter_id
  AND r.encounter_date >  i.discharge_date
  AND r.encounter_date <= i.discharge_date + INTERVAL 30 DAY
WHERE i.encounter_type = 'Inpatient' AND i.discharge_date IS NOT NULL;
```

This is Q3's **entire self-join**, executed once, at load. The query then becomes
a `GROUP BY` over a stored `TINYINT`.

> **The work did not get cheaper. It moved.** Once per nightly load, instead of
> once per analyst per question.

That framing matters: if nobody asks the readmission question, the star schema is
*slower* overall, because the ETL did work nobody needed. Pre-aggregation is a
bet that the same expensive questions get asked repeatedly.

There is a second, non-performance payoff: the 30-day definition now lives in
**one place**. Ten analysts hand-writing that self-join would produce several
subtly different definitions — some restricting the return to inpatient, some
using `>=` instead of `>`, some forgetting to exclude the index encounter.

**8d — Assemble**, with two derived measures computed inline:

```sql
CASE WHEN e.discharge_date IS NULL OR e.discharge_date < e.encounter_date
     THEN NULL
     ELSE TIMESTAMPDIFF(MINUTE, e.encounter_date, e.discharge_date)
END,                                                       -- GUARD B8
TIMESTAMPDIFF(YEAR, p.date_of_birth, e.encounter_date),
```

`GUARD B8`: nothing in the source prevents `discharge_date < encounter_date`. A
negative length of stay would poison every average built on it, so it is rejected
to `NULL` rather than propagated.

### Q: How do you handle missing data?

One policy, applied consistently:

| Situation | Response |
|---|---|
| Missing dimension reference | → unknown member (`-1`), **row is KEPT** |
| Missing measure | → `COALESCE` to `0` |
| Missing date | → `NULL` key where nullable; a `NULL` `encounter_date` is *rejected*, since a fact with no date cannot be placed on any timeline |
| Impossible value (negative LOS, discharge before admit) | → `NULL` the derived measure, keep the row |
| Duplicate junction row | → collapsed by the bridge primary key |

**The governing principle: never drop a fact to preserve tidiness.** An encounter
that happened belongs in the warehouse even if its provider reference is broken.

Verified after every load: **0 facts landing on an unknown member**, so the
guards are correct no-ops on this data rather than silently absorbing problems.

---

## 3. Bridge Table Load Logic

Both bridges load **after** the fact table, because they need `encounter_key` —
which the fact insert assigns.

### Q: How do you populate `bridge_encounter_diagnoses`?

```sql
INSERT IGNORE INTO bridge_encounter_diagnoses
    (encounter_key, diagnosis_key, diagnosis_sequence)
SELECT
    f.encounter_key,
    ddx.diagnosis_key,
    ed.diagnosis_sequence
FROM healthcare_oltp.encounter_diagnoses ed
JOIN fact_encounters f  ON f.encounter_id  = ed.encounter_id
JOIN healthcare_oltp.diagnoses sd ON sd.diagnosis_id = ed.diagnosis_id
JOIN dim_diagnosis   ddx ON ddx.icd10_code = sd.icd10_code;   -- GUARD B6
```

858,360 rows in, 858,360 out. Nothing is aggregated — the bridge grain *is* the
source grain.

Two deliberate choices:

**Joining `dim_diagnosis` on `icd10_code`, not `diagnosis_id`** — that is GUARD
B6. The dimension was conformed on the clinical code, so if the source ever holds
two ids for `I10`, both bridge rows resolve to the same dimension row and the
counts stay whole.

**`INSERT IGNORE`** against `PRIMARY KEY (encounter_key, diagnosis_key)`. The key
already makes duplicates impossible; `IGNORE` makes the intent explicit rather
than relying on a constraint violation to enforce a business rule. The same
diagnosis coded twice on one visit is a data-entry artifact, not two diagnoses.

### Q: How do you populate `bridge_encounter_procedures`?

```sql
INSERT IGNORE INTO bridge_encounter_procedures
    (encounter_key, procedure_key, procedure_date_key)
SELECT
    f.encounter_key,
    dpx.procedure_key,
    CAST(DATE_FORMAT(ep.procedure_date, '%Y%m%d') AS UNSIGNED)
FROM healthcare_oltp.encounter_procedures ep
JOIN fact_encounters f   ON f.encounter_id  = ep.encounter_id
JOIN healthcare_oltp.procedures sp ON sp.procedure_id = ep.procedure_id
JOIN dim_procedure   dpx ON dpx.cpt_code    = sp.cpt_code;    -- GUARD B6
```

721,035 rows in, 721,035 out. Same shape as the diagnosis bridge, with
`procedure_date_key` as its one extra attribute.

**Why that column belongs here and not on the fact:** a procedure has its own
date, distinct from the encounter's. During a five-day inpatient stay, procedures
happen on different days — so the date is a property of the
encounter-procedure **pair**, not of the encounter.

It is also what makes this a Kimball *bridge* rather than a bare link table —
the same role `diagnosis_sequence` plays next door.

**A note on the pruning pass, because this column was briefly dropped and then
restored.** The rule applied across the schema is *"store nothing that another
column in the same row already determines."* `procedure_date_key` does not
violate it. It was removed instead on the weaker ground that no query reads it —
which contradicted a principle already applied elsewhere in the same pass, where
ten other unread columns were kept because a warehouse serves questions beyond
the four it launched with. `diagnosis_sequence` on the sibling bridge is the same
kind of column, equally unread, and was never questioned. Restoring it makes the
rule hold without exception.

### The aggregate table, built last

`agg_diagnosis_procedure_pair` is built **from** the bridges. It forms the
~2.06M pair rows once and stores the ~1,200 distinct results.

```sql
ROUND(SUM(f.allowed_amount / (f.diagnosis_count * f.procedure_count)), 2)
```

That division is the important part. Revenue is **allocated**, not summed —
divided by the encounter's own pair count before being added into each pair.

| | Total |
|---|---|
| `agg` table `total_allowed` | **$754,318,058** |
| True revenue on the fact | **$754,318,058** — matches to the cent |
| What a naive `SUM()` would give | **$5,172,322,018** |

Without that division, this table would carry a 6.9× inflated revenue figure
baked permanently into storage, where nobody would ever question it. It is the
one place in the model where a money column survives beside a many-to-many join,
and the allocation is what makes that safe.

---

## 4. Refresh Strategy

### Q: How often would you load? (daily / incremental / full refresh)

**Nightly, off-peak.** Clinical analytics answers questions about yesterday and
last quarter; nobody makes a decision on an encounter that closed forty minutes
ago. Hourly loading would add operational risk for no analytical benefit.

**What gets fully reloaded vs incremental:**

| Table | Strategy | Why |
|---|---|---|
| `dim_date` | never | extend the range every few years |
| `dim_department` / `dim_specialty` | full reload | 13 rows each |
| `dim_diagnosis` / `dim_procedure` | full reload | 41 and 31 rows |
| `dim_provider` | full compare, SCD2 | 61 rows |
| `dim_patient` | full compare, SCD2 | 50,001 rows — hashing all of them costs seconds |
| **`fact_encounters`** | **incremental** | 300,000 rows |
| bridges | incremental, follow the fact | |
| aggregate table | full rebuild | 1,200 rows |

**Dimensions are compared in full because they are small.** Building incremental
logic for a 50,000-row table would add a failure mode to save no measurable time.
Correctness beats cleverness at that scale.

### The incremental fact load — with no source timestamp

Two mechanisms, because one is not sufficient.

**Mechanism 1 — high-water mark, catches NEW encounters:**

```sql
last_hwm := SELECT high_water_mark FROM etl_load_log
            WHERE load_finished_at IS NOT NULL ORDER BY load_id DESC LIMIT 1;

SELECT * FROM source.encounters WHERE encounter_id > last_hwm;
```

`encounter_id` is monotonic, so this captures everything created since the last
successful load — **no timestamp required.** This is why `etl_load_log` exists.

**Mechanism 2 — rolling 30-day restatement, catches CHANGED encounters:**

The high-water mark cannot see *edits* to encounters it already loaded, and in
this domain edits are the normal case: a claim moving `Pending → Paid`, a
diagnosis code amended after review, a discharge date corrected.

```sql
DELETE FROM fact_encounters WHERE date_key >= key_of(TODAY - 30 DAYS);
-- then re-derive those rows from source, and their bridge rows
```

**Why 30 days specifically** — measured from the data, not habit:

```
claim lag: min 1 day, max 20 days, average 10.5
```

A 30-day window covers the full billing tail with margin. If the payer contract
allowed 60-day adjudication, the window would be 90 days.

**Cost:** roughly 12,500 encounters reprocessed nightly that mostly have not
changed. That is the price of the source having no `updated_at`, paid every night.

**Why DELETE-and-reinsert rather than UPDATE:** the fact row's measures derive
from four separate source aggregates. Recomputing the row is simpler and less
error-prone than working out which of nine measures moved, and at 12,500 rows the
difference is not measurable.

### Q: How would you handle late-arriving facts?

| Case | Handling |
|---|---|
| Arrives **within 30 days** | automatic — the restatement window catches it |
| **New** encounter older than 30 days | caught by the high-water mark; a backdated record still gets a new `encounter_id` |
| **Edit** to an encounter older than 30 days | **not caught by either mechanism** |

That last row is a known, accepted gap, stated rather than hidden. Mitigation is a
weekly reconciliation job:

> compare `COUNT(*)` and `SUM(allowed_amount)` per month, source vs warehouse;
> any month that diverges is queued for full restatement

That turns undetectable silent drift into a *detected discrepancy with a defined
repair path* — the best available answer without source-side change tracking.

**Late-arriving dimensions** resolve themselves: dimensions load before facts in
every run, and are fully compared rather than incrementally filtered. Should a
lookup still fail, the `-1` unknown member catches it and the next load repairs
the key once the dimension row exists.

### Failure handling

Each load writes a row to `etl_load_log` at start and closes it at the end. An
unclosed row (`load_finished_at IS NULL`) marks a crashed run, and the next load
reads its high-water mark from the last **successful** load — so a failure
re-processes rather than skips.

Each phase commits separately. Because the incremental fact load is
DELETE-then-INSERT over a bounded window, and the dimension loads are idempotent
comparisons, **rerunning a failed load is safe.** That property is worth more in
operations than any performance optimisation in this document.

---

## How `etl_load_log` is used

It is the only piece of state that survives between runs, and it does three
jobs.

```sql
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
);
```

**Job 1 — it holds the high-water mark, which is the whole incremental strategy.**

With no `updated_at` in the source, `high_water_mark` is what makes an
incremental fact load possible at all:

```sql
last_hwm := SELECT high_water_mark FROM etl_load_log
            WHERE load_finished_at IS NOT NULL      -- only SUCCESSFUL loads
            ORDER BY load_id DESC LIMIT 1;

SELECT * FROM source.encounters WHERE encounter_id > last_hwm;
```

Without this table there is no incremental load, only a nightly full rebuild.

**Job 2 — it makes failure safe.** A row is written at the start and closed at
the end:

```sql
INSERT INTO etl_load_log (load_started_at, load_type, notes)
VALUES (NOW(), 'FULL', 'Initial full load of the dimensional model');
SET @load_id = LAST_INSERT_ID();
-- ... the entire load ...
UPDATE etl_load_log SET load_finished_at = NOW(), ... WHERE load_id = @load_id;
```

An open row — `load_finished_at IS NULL` — marks a crashed run. Because the
next load reads its watermark from the last row where `load_finished_at IS NOT
NULL`, **a crash causes re-processing rather than skipping.** That, plus the fact
that the incremental load is DELETE-then-INSERT over a bounded window and the
dimension loads are idempotent comparisons, is what makes rerunning a failed load
safe.

**Job 3 — it records what the load had to correct.**

`rows_rejected` was originally **hardcoded to 0** — the log reported zero
rejections without measuring anything, which is worse than not having the column.
It is now fed by the validation flags:

```sql
rows_rejected = COALESCE(@patient_flagged, 0),
notes         = CONCAT(..., '. Patient values corrected: ', @patient_flag_detail)
```

A clean load reads:

```
rows_inserted: 300000
rows_rejected: 0
        notes: Full load OK. Facts: 300000, dx bridge: 858360,
               px bridge: 721035, agg pairs: 1200.
               Patient values corrected: gender=0 dob=0 noname=0
```

and the same load with four broken patients in the source reads
`rows_rejected: 3` with `gender=1 dob=1 noname=1`.

**Why that matters more than it looks.** Every guard in this ETL *silently fixes*
things — a bad gender becomes `'U'`, an impossible date becomes `NULL`, a missing
provider becomes key `-1`. Silent fixes are correct behaviour, because the
alternative is dropping real clinical activity. But silent fixes with **no
counter** are indistinguishable from clean data. The log is what turns "we
handled it" into "we handled 3 of them, here is the breakdown, go look at the
source."

**What it does not yet do:** the counters cover the patient dimension only.
`rows_updated` is still `0` because the implemented ETL never versions anything —
it is a full load. Both are honest placeholders for the incremental path rather
than measured values, and are marked as such here rather than left to look
complete.

---

## The one change that would replace half of this

```sql
ALTER TABLE encounters
    ADD COLUMN updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                                    ON UPDATE CURRENT_TIMESTAMP,
    ADD INDEX idx_updated_at (updated_at);
-- same for billing
```

Two columns and an index would replace the entire 30-day restatement window with
an exact predicate, and close the older-than-30-days gap completely. It would
also make SCD Type 2 `effective_from` dates accurate rather than load-dated.

Written as runnable DDL in [`99_oltp_hardening.sql`](../sql/99_oltp_hardening.sql)
and **deliberately never executed** — the source system is not ours to change.
That file is the recommendation you attach to a ticket, not a step in the
pipeline.

---

## Summary — the ten questions and where each lands

| Brief's question | Answer in one line |
|---|---|
| Populate `dim_patient`? | Unknown member first, then straight `SELECT` with `COALESCE` on nullable `gender` |
| Populate `dim_date`? | Generated from cross-joined digit tables; `YYYYMMDD` key; one-time load |
| Handle dimension updates? | Six are Type 1 (overwrite). Two are Type 2 via **content hashing**, since the source has no timestamp |
| Look up dimension keys? | `LEFT JOIN` + `COALESCE(key, -1)`, with `is_current = 1` on the Type 2 lookups |
| Calculate pre-aggregated metrics? | Four staged passes; billing collapsed to grain first (B7); the readmission self-join run once |
| Handle missing data? | Unknown member, `COALESCE` to 0, `NULL` impossible values — **never drop a fact** |
| Populate diagnosis bridge? | `INSERT IGNORE`, joined on ICD-10 **code** not id (B6) |
| Populate procedure bridge? | Same, plus `procedure_date_key` — a property of the pair, not the encounter |
| How often to load? | Nightly. Dimensions full compare, facts incremental |
| Late-arriving facts? | High-water mark + rolling 30-day window, sized from the measured 1–20 day claim lag |
