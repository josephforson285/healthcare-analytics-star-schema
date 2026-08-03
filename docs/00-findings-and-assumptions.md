# Findings & Assumptions Register

Everything discovered about the source system and the brief, with an explicit
disposition for each item. Written before any query was measured so that later
design choices can be traced back to evidence rather than preference.

**Governing rule:** the OLTP schema in `sql/01_oltp_schema.sql` is left
byte-identical to the brief. Adding a constraint or index there would mean the
Part 2 measurements describe our tuning rather than the system we were asked to
analyse, and the before/after comparison would prove nothing. In practice you
rarely control the source system anyway — you inherit it and defend downstream.

Dispositions used below:

- **DOCUMENT** — recorded, source left alone, surfaces in `reflection.md`.
- **ETL GUARD** — neutralised during the load into the star schema.
- **DECISION** — forces a design choice, recorded here with its rationale.
- **FIXED** — a defect in our own code, already corrected.

---

## A. Data generation defects (ours)

| # | Finding | Disposition |
|---|---|---|
| A1 | 26,476 duplicate `(encounter_id, diagnosis_id)` pairs | **FIXED** — deduped in staging, commit `8383078` |
| A2 | 26,097 duplicate `(encounter_id, procedure_id)` pairs | **FIXED** — same |
| A3 | 5,014 procedures dated after `discharge_date` | **FIXED** — offset clamped to length of stay |

A4. A self-join `DELETE` against the live 897k-row junction table ran past ten
minutes and was killed: no index covers `(encounter_id, diagnosis_id)`, so
InnoDB executed a nested loop. Adding an index fixed the speed but could not
then be dropped — InnoDB binds any index led by `encounter_id` to that foreign
key, and the schema had to return to its original state. Resolved by deduping
in an unconstrained staging table.

This is the same failure mode Q3 (readmissions) is expected to hit. Meeting it
accidentally during data loading is useful corroboration: unindexed self-joins
on large tables are not a theoretical concern.

---

## B. Source schema defects (the brief's)

The schema is normalised. It is not well-constrained — those are different
properties, and the gap between them is most of what follows.

| # | Finding | Consequence | Disposition |
|---|---|---|---|
| B1 | Every non-PK column is nullable; all 10 tables have exactly one `NOT NULL` column (the PK). `encounters.patient_id` may be NULL. | Orphan-ish facts; every ETL lookup must handle a missing key | **ETL GUARD** — unknown-member rows |
| B2 | No `UNIQUE (encounter_id, diagnosis_id)` | Same diagnosis codable twice per visit; inflates Q2 pair counts | **ETL GUARD** — dedupe on bridge load |
| B3 | No `UNIQUE (encounter_id, procedure_id)` | As above | **ETL GUARD** |
| B4 | `encounter_type VARCHAR(50)`, no lookup table, no `CHECK` | `'ER'`, `'er'`, `'Emergency'` all valid; uncontrolled attribute domain | **DOCUMENT** + **ETL GUARD** (normalise on load) |
| B5 | `claim_status VARCHAR(50)`, same | Status buckets can silently fragment | **DOCUMENT** + **ETL GUARD** |
| B6 | `icd10_code` / `cpt_code` not `UNIQUE` | One clinical code can exist under two surrogate ids, splitting counts | **ETL GUARD** — conform on code, not id |
| B7 | `billing.encounter_id` not `UNIQUE` despite being 1:1 | Nothing prevents double-billing an encounter; revenue overstates | **ETL GUARD** — aggregate, never assume 1:1 |
| B8 | No `CHECK (discharge_date >= encounter_date)`; nothing ties `procedure_date` to the encounter window | Negative length of stay is storable; corrupts any LOS metric | **ETL GUARD** — reject/flag on load |

B4 is worth calling out as a genuine normalisation criticism rather than a
missing-constraint nitpick. An uncontrolled text domain repeated across 300,000
rows is exactly the redundancy normalisation exists to remove — the brief
normalised the *entities* thoroughly and left the *attribute domains* alone.

### B9 — no audit columns anywhere (**DECISION**)

No table carries `created_at`, `updated_at`, or a version/sequence column.
There is therefore **no way to detect which rows changed since the last load**.

This blocks the Part 3.4 refresh strategy directly, so it is decided here:

1. **Dimensions — full reload each cycle.** The largest is `dim_patient` at
   50,000 rows. Rebuilding it costs seconds, and correctness beats cleverness
   at that size. (This is also why SCD Type 2 needs care — see below.)
2. **Facts — incremental on `encounter_id` high-water mark.** `encounter_id`
   is monotonic, so `WHERE encounter_id > :last_loaded_id` captures new
   encounters without any timestamp.
3. **Plus a rolling 30-day restatement window.** The high-water mark catches
   new encounters but misses *edits* to recent ones — a claim moving
   `Pending → Paid`, or a late diagnosis code. Claims land 1–20 days after
   discharge in this dataset, so every load also re-processes the last 30 days
   of encounters and overwrites those fact rows. This is the standard answer to
   late-arriving facts when the source offers no change tracking.
4. **Recommended source change:** add `updated_at TIMESTAMP DEFAULT
   CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP` to `encounters` and
   `billing`. That single change would replace the restatement window with a
   precise incremental predicate. It is out of scope to apply — the source is
   not ours — but naming it is part of the deliverable.

Consequence for SCD Type 2: without source timestamps, change detection must be
done by **comparing the incoming row against the current dimension row**
attribute by attribute. That is the only mechanism available here, and it is
why the ETL design compares hashes rather than trusting a modification date.

---

## C. Defects in the lab brief

| # | Finding | Our deviation |
|---|---|---|
| C1 | Sample `INSERT INTO billing` precedes `INSERT INTO encounters`, referencing encounters 7001/7002 that do not exist yet. With foreign keys enforced the brief's own script fails. | Load order corrected; superseded by generated data |
| C2 | Sample data is 4 encounters — unmeasurable. The bottlenecks the brief asks us to find are asymptotic. | Generated 300,000 encounters (~2.3M rows), seeded for reproducibility |
| C3 | Part 3.2 asks for `specialty` inside `dim_provider` **and** a separate `dim_specialty`. | Both built. `dim_specialty` is joined directly from the fact via `specialty_key`, so it is a star point, not a snowflake. The duplicate `specialty_name` on `dim_provider` was removed: it saved no join and drifted on rename. See `design_decisions.txt` |
| C4 | `dim_encounter_type` holds only 3 values. | Built. It closes the free-text domain of B4 and carries `is_emergency` / `is_overnight`, which have no home on the fact row. The four business queries still read `encounter_type` off the fact — joining the dimension for the name alone measured 2.5x slower (3.68s vs 1.49s) |
| C5 | Part 3.3 asks for execution time *estimates*. | Measured instead, with `EXPLAIN ANALYZE` output retained in `results/` |

C3 and C4 were initially resolved by NOT building the two dimensions, on the
argument that the brief's own list was internally inconsistent. That argument was
overconfident: snowflaking is specifically `fact -> dim_provider ->
dim_specialty`, and a fact carrying `specialty_key` directly makes
`dim_specialty` an ordinary star point. Both dimensions are now built.

What survived the reversal is narrower and better evidenced: the duplicate
`specialty_name` on `dim_provider` was removed, because it eliminated no join
(all three dimensions sit one hop from the fact) and it drifted on rename, since
the SCD2 hash covers `specialty_id` rather than `specialty_name`. Duplicating a
label across two dimensions is not the same pattern as collapsing a hierarchy
into one, and only the latter is a Kimball recommendation.

---

## D. Non-issues worth stating

**InnoDB creates indexes on foreign key columns automatically.** So
`encounters.patient_id`, `provider_id` and `department_id` are all indexed even
though the brief never declares them. Q1 and Q4 will therefore perform better
than the brief's hints suggest, and any bottleneck found there is aggregation
and join width — *not* missing indexes.

This is recorded because it constrains what may honestly be claimed later. The
temptation in a before/after lab is to overstate the "before". The measurements
in `query_analysis.txt` are what they are.
