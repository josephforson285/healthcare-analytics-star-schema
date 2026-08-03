# How the brief was approached, part by part

The brief walked in its own order. For each section: what it asked for, how it
was approached, and what was produced — including the places where the brief's
own instructions could not be followed as written, and why.

---

## Project Overview

> *"You've joined HealthTech Analytics as a junior data engineer. The clinical
> team built a normalized transactional database (3NF), but analytics queries are
> slow. Your job: analyze the OLTP schema, identify performance issues, then
> design and build an optimized star schema."*

**The approach in one line:** treat it as inherited production work, not as an
exercise. That framing settled the single most consequential decision before any
SQL was written.

**One rule was set up front and never broken:**

> The OLTP schema stays byte-identical to the brief.

It was tempting to "fix" the source — add the missing `UNIQUE` constraints, index
the columns the slow queries want. That would have been wrong twice over:

1. **It destroys the comparison.** Tune the source, then measure it, and the
   "before" number describes *my tuning* rather than the schema the brief asked
   me to analyse. The entire before/after exercise becomes meaningless.
2. **It is not how the job works.** You rarely get to alter a live clinical OLTP
   system to make your warehouse load easier. You inherit it and defend
   downstream.

Every source defect therefore got a **disposition** rather than a fix, recorded in
[`00-findings-and-assumptions.md`](00-findings-and-assumptions.md):

| Disposition | Meaning |
|---|---|
| `DOCUMENT` | Recorded, source untouched, surfaces in the reflection |
| `ETL GUARD` | Neutralised at load time, since the source can't change |
| `DECISION` | Forces a design choice, recorded with rationale |
| `FIXED` | A defect in *my* code, corrected |

The fixes I *would* apply if I owned the source were written as real,
syntax-checked DDL in [`99_oltp_hardening.sql`](../sql/99_oltp_hardening.sql) and
deliberately never executed. That file is the recommendation you attach to a
ticket, not a step in the pipeline.

---

## Part 1: Normalized OLTP Schema

> *"The production system uses 8 normalized tables. Study the schema and
> understand how data is organized."*

**How it was approached:** by naming the **grain of every table** — "what does one
row mean, in a sentence" — before touching anything. Do this and the star schema
design later becomes almost mechanical.

| Table | Grain | Becomes |
|---|---|---|
| `patients` | one person | `dim_patient` |
| `specialties`, `departments`, `diagnoses`, `procedures` | one reference concept | dimensions, nearly as-is |
| `providers` | one clinician, with a hierarchy hanging off it | `dim_provider` + `dim_specialty` + `dim_department` |
| `encounters` | **one visit — the transaction** | `fact_encounters` |
| `encounter_diagnoses` | one diagnosis on a visit | **junction / many-to-many** |
| `encounter_procedures` | one procedure on a visit | **a second, independent many-to-many** |
| `billing` | one claim on an encounter | measures on the fact row |

That last pair is the whole intellectual core of the lab:

> An encounter has **many diagnoses** and **many procedures**, and the two are
> **independent of each other**.

Rather than describe that, it was **measured** — on one encounter, then on all of
them:

| | Rows | Total allowed |
|---|---|---|
| Truth | 300,000 | $838.7M |
| Naive join of both junction tables | 2,062,317 | $5,752.3M |

A **6.9× overstatement of revenue**, from a query with correct syntax, correct
foreign keys, and no error or warning. This is the **fan trap**, and having it
measured *before* designing anything meant Decisions 1 and 4 later were settled by
evidence rather than by quoting Kimball.

**Two defects in the brief's own Part 1** were found here and recorded:

- The sample `INSERT INTO billing` appears **before** `INSERT INTO encounters`,
  referencing encounters 7001/7002 that don't exist yet. With foreign keys
  enforced, the brief's own script fails.
- The schema is properly in 3NF but has **nine constraint gaps** — every non-PK
  column nullable, no `UNIQUE` on either junction table, free-text
  `encounter_type` with no `CHECK`, `billing.encounter_id` not unique despite
  being 1:1, and no audit columns anywhere. *Normalized* and *well-constrained*
  are different properties.

---

## Part 2: Find the Performance Problem

> *"You're given 4 business questions. Write the SQL to answer each one using the
> normalized schema above. Run the queries, measure performance, and identify
> bottlenecks."*
>
> *"Measure: What's the query execution time?"*

### The problem with this as written

The brief supplies **4 encounters**. At that size every query returns in roughly
0.3ms — and so does every star schema query. You would be reporting measurement
noise as an improvement factor.

Worse, the bottlenecks the brief's own hints point at are **asymptotic** — they
only exist at volume:

- Q2's *"row explosion"* doesn't explode: 3 diagnoses × 3 procedures = 9 rows.
- Q3's *"self-joins on large tables"* compares 16 pairs.
- Q1 and Q4's join chains cost nothing across three tables of 3 rows.

**So the first decision was made before any SQL: the lab cannot be done honestly
without generating data.** This is worth naming as a general habit — when a brief
asks you to measure something, check the thing is measurable before you build
around it.

### What was built instead

[`02_generate_data.sql`](../sql/02_generate_data.sql): 300,000 encounters,
~2.3M rows, two years of activity, 70/20/10 outpatient/ER/inpatient mix with
realistic lengths of stay.

**Every random value is derived by hashing the row number**, so the dataset is
byte-identical on every run and every machine. Without that, no timing claim is
checkable by a marker.

### The four queries, measured

Written the way an analyst naturally would — no hints, no hand-tuning, no
pre-built helpers. `EXPLAIN ANALYZE` output kept in [`results/`](../results/) as
evidence.

| Query | Time | Peak rows | Cause |
|---|---|---|---|
| Q1 Encounters by month/specialty | 1.12s | 300,000 | derived month + `COUNT(DISTINCT)` |
| Q2 Diagnosis-procedure pairs | **22.56s** | **2,060,000** | the fan trap |
| Q3 30-day readmissions | 0.80s | 300,000 | none worth reporting |
| Q4 Revenue by specialty/month | 2.05s | 300,000 | longest join chain |

*(These are the session-A timings recorded in `query_analysis.txt`. The Part 3.3
table further down uses a later session, where both OLTP and star sides were
re-measured together — wall-clock on this machine moves ~2x between sessions while
plans and row counts stay identical. Always compare within a session, never across.
Full detail: [`results/measurement_sessions.txt`](../results/measurement_sessions.txt).)*

**Q2's plan shows the problem exactly** — 2.06 million rows built and sorted to
return 20, with ~19 of the 22.5 seconds inside the sort:

```
-> Group aggregate: count(distinct ...)   (actual time=19191..21501 rows=1200)
    -> Sort: d.icd10_code, ...            (actual time=19190..19379 rows=2.06e+6)
        -> Nested loop inner join         (actual time=9.68..14433  rows=2.06e+6)
```

### Three predictions that were wrong

The brief's hints set expectations that measurement contradicted:

| Hint / expectation | Reality |
|---|---|
| Q3: *"self-joins on large tables"* → slowest | **Fastest** at 0.80s |
| Missing indexes are the bottleneck | InnoDB indexes FK columns **automatically** |
| Q1 would improve under the star schema | The obvious rewrite was **28% slower**; it took an integer-first rewrite to reach 1.97× faster (Part 3.3) |

That second one reshaped the whole writeup. `encounters.patient_id`,
`provider_id` and `department_id` are all indexed even though the brief never
declares them, so Q3's self-join is ~30,000 cheap indexed probes rather than a
quadratic scan. Three of four queries perform *better* than the hints imply, and
the honest bottleneck is aggregation and join width — not missing indexes.

The temptation in a before/after lab is to overstate the "before". This is stated
up front in [`query_analysis.txt`](query_analysis.txt) precisely because it
constrains what can honestly be claimed later.

**Deliverable:** [`query_analysis.txt`](query_analysis.txt), in the brief's
requested format.

---

## Part 3.1: Design Decisions

> *"Now that you've experienced the performance pain, design an optimized
> dimensional model."*

Kimball's four steps in order — business process → **grain** → dimensions → facts.
Declaring the grain *second*, before any table exists, is the discipline that
prevents the fan trap. Almost every dimensional modelling mistake traces back to
picking the grain last.

### Decision 1 — Grain

> *"Option A: one row per encounter / Option B: one row per diagnosis within an
> encounter / Option C: one row per procedure within an encounter"*

**Chosen: Option A**, and the Part 2 measurement is the argument. Options B and C
bake the 6.9× inflation permanently into the warehouse — `SUM(allowed_amount)`
becomes wrong by default, for every user, forever. **The obvious query becomes
the wrong query.**

The general rule this illustrates: *grain should be the finest level at which the
measures are still additive.* `allowed_amount` is additive per encounter. There
is no such thing as "the revenue of a diagnosis" when a visit has four of them
and one bill.

### Decision 2 — Dimensions

> *"Date dimension… Patient dimension… Provider dimension… Specialty dimension…
> Department dimension… Encounter type dimension… Others?"*

All six built, plus `dim_diagnosis` and `dim_procedure` which the bridges
require. **One deliberate departure from the brief's column hints:**

| Departure | Reason |
|---|---|
| **`age_group` moved to the fact** | The brief lists it under `dim_patient`. Age changes with the **calendar**, not with any source event, so an SCD mechanism driven by source changes would never fire — the value would simply rot. Age at the time of care is a property of the *encounter*. |

**A note on `dim_specialty`, because I got this wrong the first time.** My initial
design omitted it, arguing that holding specialty in `dim_provider` *and* as its
own dimension is snowflaking. That was overconfident. Snowflaking is specifically
`fact → dim_provider → dim_specialty`; if the fact carries `specialty_key`
directly, `dim_specialty` is an ordinary star point and there is nothing wrong
with it.

`dim_specialty` was then built, and `fact_encounters.specialty_key` joins it
directly — a proper star point.

**A second correction followed.** `specialty_name` was initially duplicated onto
`dim_provider` as well, defended as denormalisation that saves a join. It saves
nothing: the fact carries `provider_key`, `specialty_key` and `department_key`
independently, so all three dimensions are one hop away and there was never a
second hop to avoid. It also drifted — the SCD2 hash covers `specialty_id`, not
`specialty_name`, so renaming a specialty left `dim_provider` stale while
`dim_specialty` updated. Removed.

**A third correction after that.** Enforced foreign keys were then added from
`dim_provider` to `dim_specialty` and `dim_department` to close the enforcement
gap — which created **snowflake edges**, the exact shape argued against
throughout. Also removed. `dim_provider` now holds only its own attributes, and
the warehouse has **zero dimension-to-dimension foreign keys**.

Three passes to land on the simple answer, each recorded rather than tidied
away, because the wrong turns are the part worth reading.

`dim_encounter_type` was likewise omitted at first and is now built. Three rows
is small, but it closes a free-text domain the source leaves open (finding B4)
and gives `is_emergency` / `is_overnight` somewhere to live — neither of which a
bare string on the fact row can do.

### Decision 3 — Pre-aggregated metrics

> *"What metrics should be stored directly in the fact table to avoid expensive
> joins? diagnosis_count… procedure_count… total_allowed… Others?"*

All three, plus: `length_of_stay_minutes`, `patient_age_years`,
`claim_amount`, `denied_amount`, `is_index_admission`,
`encounter_count`, and — the highest-value one —

**`is_readmission_30d`.** This executes Q3's entire self-join *once*, in the ETL,
and stores the answer as a `TINYINT`.

That column is the clearest statement of what the whole exercise is about:

> **The work did not get cheaper. It moved.** The same self-join runs once per
> nightly load instead of once per analyst per question.

Also `principal_diagnosis_key`, denormalised from the sequence-1 diagnosis, so
the common case (most clinical reporting wants only the primary diagnosis) skips
the bridge entirely.

### Decision 4 — Bridge tables

> *"Will you use bridge tables for many-to-many relationships? Why or why not?"*

**Yes — necessary, not optional.** The alternatives are:

- **Repeating groups** (`diagnosis_1`…`diagnosis_5`) — breaks on the sixth
  diagnosis, turns "which encounters involved hypertension" into a five-way `OR`,
  and violates **1NF**. Dimensional modelling does not license abandoning 1NF.
- **Diagnosis-level grain** — which is Decision 1's Option B, and reintroduces the
  measured 6.9× inflation.

**The honest trade-off, stated rather than glossed:** bridges do **not** eliminate
the fan trap. They *relocate* it. Pairing diagnoses with procedures inherently
produces pairs. What bridges buy is that the fan becomes **opt-in** (Q1, Q3, Q4
never touch one), rows are narrow integers rather than `VARCHAR(200)`
descriptions, and — decisively — **no measure is reachable**, because money lives
on the fact table which a bridge-to-bridge join doesn't include.

> A schema where the wrong answer is **impossible to write** beats a schema where
> it is merely documented as inadvisable.

**Deliverable:** [`design_decisions.txt`](design_decisions.txt).

---

## Part 3.2: Build the Star Schema

> *"Create complete DDL for your star schema… Primary keys (surrogate keys for
> dimensions), foreign key relationships, appropriate indexes, comments
> explaining each table's purpose."*

**Deliverable:** [`04_star_schema.sql`](../sql/04_star_schema.sql) — 6 dimensions,
1 fact, 2 bridges, 1 aggregate table, 1 ETL control table. Surrogate keys
throughout, SCD Type 2 structure on `dim_patient` and `dim_provider`, composite
indexes leading with `date_key` because essentially every analytical query filters
on time first.

One thing worth noting from the build: `year_month` is a **reserved word** in
MySQL (used in `INTERVAL` expressions), so the column is `calendar_month`.

Beyond the brief: **`agg_diagnosis_procedure_pair`**, ~1,200 rows. Q2 asks a
question that costs 2.06M rows to answer from scratch every time. Kimball's
answer is aggregate navigation — compute it once. Its `total_allowed` is
**allocated** (`allowed_amount / (diagnosis_count × procedure_count)`), not
summed, so the column **reconciles to true revenue** rather than a multiple of it.
Verified at $754,318,058 exactly.

---

## Part 3.3: Translate Queries to Star Schema

> *"Execution time estimate (e.g. ~150ms vs. 1.8s original)"*

**Departure:** measured, not estimated. Same machine, same data, median of 3 warm
runs.

**And one rule applied before any timing was recorded: diff the output first.**
Every star query's full result was compared row-by-row against its OLTP
counterpart. That caught two real bugs:

- **Q3** — Cardiology and Psychiatry both score 21.84%; with no secondary sort key
  the engines ordered the tie differently. Values were identical, a tie-break was
  missing.
- **Q4** — the star version under-reported by **$84,420,895**. My ETL splits the
  source's single `allowed_amount` into allowed vs denied, so the equivalent
  figure needed both added back.

> *A faster query that returns different numbers is not an optimisation.* Timing
> first and diffing later would have shipped a headline speedup on a query that was
> quietly $84M short.

### Results

| Query | OLTP | Star | Factor |
|---|---|---|---|
| Q1 Encounters by month/specialty | 0.606s | 0.308s | **1.97× faster** |
| Q2 Diagnosis-procedure pairs | 10.188s | 0.026s | 392× |
| Q2b *same, bridges only* | 10.188s | 2.072s | *4.9×* |
| Q3 30-day readmissions | 0.429s | 0.349s | 1.23× |
| Q4 Revenue by specialty/month | 1.081s | 0.189s | 5.72× |

**Two reporting decisions shaped this table more than any technical choice.**

**Attribute the speedup to the actual mechanism.** Q2's 392× comes from a
pre-aggregated table — **precomputation, not dimensional modelling**. An
equivalent aggregate could have been built directly on the OLTP schema and would
have performed the same. So **Q2b was written and measured separately**: the same
question from the bridges with no aggregate table. **5.5× is the honest
star-schema-only figure**, and both appear in every summary.

**Report the failure.** Q1 got slower, and it gets its own section rather than a
footnote. `EXPLAIN ANALYZE` puts 1,381ms of a 1,586ms query inside
`COUNT(DISTINCT patient_key)` — an operation dimensional modelling does nothing
for — while `fact_encounters` is **2.3× larger on disk** (108MB vs 47.6MB) because
of thirteen precomputed columns Q1 never reads.

That is the trade in its clearest form: precomputation makes the queries that use
it much faster, and every other query slightly slower.

**Deliverable:** [`star_schema_queries.txt`](star_schema_queries.txt).

---

## Part 3.4: ETL Logic

> *"How would you handle updates to dimensions? … How often would you load?
> (daily? incremental? full refresh?) … How would you handle late-arriving
> facts?"*

**This part is blocked by a defect in the source**, and saying so is the strongest
available answer.

> **No table in the source has `created_at`, `updated_at`, or any version column.
> There is no way to ask the source what changed.**

Every choice in [`etl_design.txt`](etl_design.txt) is a workaround for that:

| Question | Answer |
|---|---|
| Dimension updates | **Content hashing** (`row_hash`) replaces the missing timestamp — recompute per row, compare, version on difference. Exact for detecting *that* something changed; cannot tell you *when*, so `effective_from` is the load date rather than the true event date. |
| How often | Nightly. Clinical analytics answers questions about yesterday, not forty minutes ago. |
| Incremental or full | Dimensions **full compare** (largest is 50,000 rows — correctness beats cleverness). Facts **incremental** on the `encounter_id` high-water mark. |
| Late-arriving facts | High-water mark catches *new* encounters but not *edits*. So every load also **reprocesses a rolling 30-day window** — chosen from the data, since claims land 1–20 days after discharge. |

The gap that remains — edits older than 30 days — is stated as a known limitation
with a defined repair path (weekly reconciliation by month, restate any month that
diverges), rather than hidden.

And the single recommendation that would fix all of it: add `updated_at` to
`encounters` and `billing`. Two columns and an index would replace the entire
restatement window with an exact predicate. Written as DDL in
[`99_oltp_hardening.sql`](../sql/99_oltp_hardening.sql), deliberately not run.

**Eight named data-quality guards** live in [`05_etl.sql`](../sql/05_etl.sql), one
per source defect — `GUARD B1` through `GUARD B8` — since the source can't be
altered. Example: `billing.encounter_id` isn't `UNIQUE`, so the ETL aggregates
billing to encounter grain *first*, neutralising a potential double-count once at
load instead of in every downstream query.

---

## Part 4: Analysis & Reflection

> *"Why Is the Star Schema Faster? … Trade-offs: What Did You Gain? What Did You
> Lose? … Bridge Tables: Worth It? … Performance Quantification."*

**Deliverable:** [`reflection.md`](reflection.md). The four required questions,
answered from measurement. The position it argues:

The **performance** case is weaker than the 14.1× headline suggests. Strip out the
aggregate table and the star schema delivers 4.9× / 1.23× / 5.72× / 1.97×.
Real, but not transformative at this volume.

What makes it worth it is the **correctness** case. A schema where the obvious
query returns a number 6.9× too large is not slow, it is *dangerous*, and no
amount of indexing fixes that. The star schema's real contribution is making the
correct query the easy one — and the wrong one unwriteable.

---

## Three things that went wrong

Recorded rather than quietly cleaned up, because they were the most instructive
part of the work.

### 1. A dedupe that ran for ten minutes

A `DELETE` with a self-join on `(encounter_id, diagnosis_id)` — a pair no index
covers — became a nested loop over 897k rows and ran past ten minutes before
being killed. Adding an index fixed the speed but the index **couldn't be
dropped**: InnoDB binds any index led by `encounter_id` to that foreign key.
Resolved by deduping in an unconstrained staging table.

**This is exactly the Q3 failure mode the brief warns about, met by accident
during data loading.** When Q3 later turned out to be fast, I already knew why —
and knew the difference an index makes here is *minutes versus sub-second*.

### 2. A dataset that passed every check and was structurally dead

The generator used `RAND(n*7+101)`-style seeding. The data passed everything I
thought to check — 70/20/10 mix, correct means, correct totals, correct counts.

It was a **rigid lattice**. MySQL's `RAND(N)` seeds a linear congruential
generator, and consecutive seeds produce *correlated* output. `patient_id`
advanced by exactly 257 and `encounter_date` by exactly 10 days for every 4 steps
in `encounter_id`.

It surfaced only because **Q3 reported a readmission rate of exactly 0.00% across
all twelve specialties.** No patient in 300,000 encounters ever had two visits
within 30 days — the arithmetic made it impossible. Fixed with MD5-derived
randomness; rates then landed at a plausible 21–22%.

**The most valuable lesson here:** a dataset can pass every summary statistic you
think to check and still be structurally dead. Aggregate checks caught nothing.
What caught it was a **domain-plausibility check** — *hospitals have readmissions,
so zero is impossible.*

### 3. Zero of six deliverable files, well into the work

The analysis was done and correct, but for a stretch there were **no required
files on disk**. Caught by auditing against the brief's deliverables table rather
than against my own sense of progress.

*The work being finished is not the same as the submission being finished.* The
same audit later caught that the brief asks for `star_schema.sql` while mine was
`sql/04_star_schema.sql` — which is why
[`scripts/make-submission.sh`](../scripts/make-submission.sh) now assembles a flat
folder with the exact required names.

---

## The method, in seven lines

1. **Check the brief is doable as written** before building anything.
2. **Set one governing constraint** and let it settle the ambiguous calls.
3. **Measure before designing** — earn every design decision with evidence.
4. **Declare the grain second**, before any table exists.
5. **Diff before timing** — correctness is not a later step.
6. **Attribute results to the actual mechanism**, not the flattering one.
7. **Report what failed**, including your own wrong predictions.

The technical content of this lab is a star schema. The transferable part is
steps 1, 5 and 7.
