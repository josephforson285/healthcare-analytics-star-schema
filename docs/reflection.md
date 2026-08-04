# Reflection: OLTP to Star Schema

So far the observation gained in this migration and benefits.

---

## 1. Why is the star schema faster?

All four queries are faster.

### Fewer joins, and against smaller tables

| Query | OLTP chain | Star chain |
|---|---|---|
| Q1 | encounters → providers → specialties | fact → **dim_specialty only** (12 rows) |
| Q2 | enc_diagnoses → enc_procedures → diagnoses → procedures | agg table → 2 dims |
| Q3 | encounters → **encounters** (self-join) → providers → specialties | fact → dim_specialty |
| Q4 | billing → encounters → providers → specialties | fact → **dim_specialty only** |


### Work moved from query time to load time

| Stored on the fact | Replaces |
|---|---|
| `is_readmission_30d` | Q3's entire self-join |
| `allowed_amount`, `denied_amount` | the `billing` join in Q4 |
| `diagnosis_count`, `procedure_count` | counting across two junction tables |
| `length_of_stay_minutes`, `patient_age_years` | date arithmetic per row |
| `agg_diagnosis_procedure_pair` | 2,060,000 pair rows formed per execution |

**The work did not get cheaper. It moved** — once per nightly load instead of once
per analyst per question which help in making queries faster.  

 

### Why denormalization helps here

Normalization optimizes for **writes that must not lie**: store each fact once, so
there is one place to update and no way for copies to disagree. Every property
delivering that is what you want on a clinical write path.

None of it helps a read that touches 300,000 rows to return 288. There, storing
`specialty_name` twelve times is free.

**Normalization eliminates redundancy so updates are safe. Analytical queries don't
update anything.** So when it comes to reading or analytical queries, denormalization helped in getting data upfront hence making such operations faster.

---

## 2. Trade-offs: what was gained, what was lost

### Gained

**Speed — 11.90s of combined query time became 0.81s, 14.7×.**


**Definitions live in one place.** The 30-day readmission rule now exists once, in
the ETL. Ten analysts hand-writing that self-join would produce several subtly
different definitions.


### Lost

**Storage** — some indexes were used and at a cost we had storage increase.

**Staleness** — correct as of the last load. Useless for anything operational.
<!-- 
**A second copy of the data**, which must be reconciled or it drifts. -->

### Was it worth it?

Yes

---

## 3. Bridge tables: worth it?

### Why not denormalize diagnoses into the fact?

 

**Repeating groups** — `diagnosis_1` … `diagnosis_5`. Breaks on the sixth. Turns
"which encounters involved hypertension" into a five-way `OR`. A **1NF violation**,
and dimensional modelling does not license abandoning 1NF.
<!-- 
### The trade-off

**Bridges relocate the fan trap, not eliminate it.** Q2b still forms ~2.06M pair
rows — pairing diagnoses with procedures always produces pairs.

What they buy: the fan is **opt-in** (only Q2 touches a bridge; Q1, Q3, Q4 never
do), rows are **narrow** integers instead of two `VARCHAR(200)` columns, and
**no measure is reachable** — money stays on the fact, out of reach of a
bridge-to-bridge join.

**A schema where the wrong answer can't be written beats one where it's
just documented as inadvisable.** -->

### Differently in production?

2. **Make the bridges SCD-aware** — clinical coding is frequently amended after
   discharge, and the current design loses amendments older than the 30-day window.
3. **Partition `fact_encounters` by `date_key`**.

---

## 4. Performance quantification

Same machine, same data, median of 9 warm runs. **Every star query's output was
diffed row-by-row against its OLTP counterpart before any timing was recorded**.

| Query | OLTP | Star | Factor | Mechanism |
|---|---|---|---|---|
| Q1 Encounters by month/specialty | 0.566s | 0.294s | **1.92×** | integer-first aggregation |
| Q2 Diagnosis-procedure pairs | 9.874s | 0.024s | **411×** | pre-aggregated table |
| Q2b *same, bridges only* | 9.874s | 2.224s | *4.43×* | narrow rows, fewer tables |
| Q3 30-day readmissions | 0.421s | 0.331s | **1.27×** | self-join precomputed |
| Q4 Revenue by specialty/month | 1.034s | 0.162s | **6.38×** | join removed + integer-first |

**Combined: 11.90s → 0.81s, 14.7×.**
