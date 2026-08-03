# Reflection: OLTP to Star Schema

Analysis of the transformation, the measurements that justify it, and the
places where the expected result did not appear.

---

## 1. Why is the star schema faster?

It is faster for three of the four queries, and the reasons differ enough per
query that a single explanation would be misleading.

### Joins: fewer, and against smaller tables

| Query | OLTP chain | Star chain |
|---|---|---|
| Q1 | encounters → providers → specialties | fact → dim_date, dim_provider |
| Q2 | enc_diagnoses → enc_procedures → diagnoses → procedures | agg table → 2 dims |
| Q3 | encounters → **encounters** (self-join) → providers → specialties | fact → dim_provider |
| Q4 | billing → encounters → providers → specialties | fact → dim_date, dim_provider |

The join *count* barely moves — 2–3 joins either way. What changes is what sits
on the other end. In the OLTP schema, Q4 joins `billing` (300,000 rows) to
`encounters` (300,000 rows) before it can sum anything. In the star schema the
money is already on the fact row, and the two remaining joins hit a 1,096-row
and a 61-row dimension. **Join depth is a poor proxy for cost; the size of what
you join to is the real variable.**

### Where data is pre-computed

Everything expensive was moved from query time to load time:

| Stored on the fact | Replaces |
|---|---|
| `is_readmission_30d` | Q3's entire self-join |
| `allowed_amount`, `denied_amount` | the `billing` join in Q4 |
| `diagnosis_count`, `procedure_count` | counting rows across two junction tables |
| `length_of_stay_minutes` | `TIMESTAMPDIFF` on every row |
| `patient_age_years`, `patient_age_band` | date arithmetic against `date_of_birth` |
| `dim_date.calendar_month` | `DATE_FORMAT` recomputed for 300,000 rows |
| `agg_diagnosis_procedure_pair` | 2,060,000 pair rows formed per execution |

**The work did not get cheaper. It moved.** The same readmission self-join still
runs — once per nightly load instead of once per analyst per question. If nobody
asks the readmission question, the star schema is strictly *slower* overall,
because the ETL performed 68 seconds of work nobody needed.

That framing matters more than the speedup numbers. A star schema is a bet that
the same expensive questions will be asked repeatedly. It is a good bet in
analytics and a terrible one for a transactional workload, which is the entire
reason the two systems are separate.

### Why denormalization helps analytical queries

Normalization optimizes for **writes that must not lie**: store each fact once,
so there is exactly one place to update and no way for two copies to disagree.
Every property that delivers this — data stored once, attributes owned by the
entity they describe, integrity enforced by foreign keys — is a property you
want on the write path of a clinical system.

None of it helps a read that touches 300,000 rows and returns 288. There,
storing `specialty_name` sixty times is free (60 rows), and it removes a join
from three of the four queries.

The sharper version: **normalization eliminates redundancy so that updates are
safe. Analytical queries do not update anything.** The guarantee is being paid
for and not used, so a second copy of the data trades it away deliberately.

---

## 2. Trade-offs: what was gained, what was lost

### Gained

**Speed.** 12.30s of combined query time became 0.87s — 14.1× overall, with all
four queries faster. But the distribution matters more than the aggregate, and
two of them only got there after the queries themselves were rewritten.

**Correctness that is structural rather than documented.** This is the larger
gain and it does not appear in any timing table. In the OLTP schema, joining
both junction tables and summing `allowed_amount` reports **$5,752.3M against a
true $838.7M** — a 6.9× overstatement, from a query that raises no error. In the
star schema, neither bridge contains a monetary column. The wrong answer is not
discouraged by a comment; it is *unwriteable*.

**Definitions live in one place.** The 30-day readmission rule now exists once,
in the ETL, rather than being re-implemented by every analyst. Ten people
writing that self-join by hand would produce several subtly different
definitions — some restricting the return to inpatient, some using `>=` instead
of `>`, some forgetting to exclude the index encounter. Consistency here is
arguably worth more than the 0.08 seconds Q3 gained.

**Better-modelled measures.** Splitting `allowed_amount` into allowed vs denied
surfaced that the OLTP query had been silently counting **$84.4M of rejected
claims as revenue**. Nobody writing that query would have noticed.

### Lost

**Storage.** `fact_encounters` is 105.2 MB against `encounters` at 47.6 MB — 2.2×,
for the same 300,000 rows. Thirteen precomputed measure columns, and 69.6 MB of
that is indexes rather than data.

**ETL complexity.** ~490 lines carrying explicit data-quality guards, an
SCD Type 2 mechanism, a high-water mark, and a rolling restatement window. That
is ~490 lines of code that can break, and the queries silently return wrong
answers when it does. The OLTP schema needs none of it.

**Staleness.** The warehouse is correct as of the last load. Not suitable for
anything operational.

**A second copy of the data**, which must be reconciled or it drifts.

### Was it worth it?

Yes, but narrowly, and for a reason different from the one the exercise sets up.

The performance case alone is weaker than the 14.1× headline suggests. Strip out
the aggregate table — which is precomputation, not dimensional modelling — and
the star schema delivers 4.9× on Q2, 1.23× on Q3, 5.72× on Q4 and 1.97× on Q1.
Real, and for Q4 and Q1 only after the queries were rewritten to aggregate on
integer keys rather than on VARCHARs joined in from dimensions.

What makes it worth it is the fan trap. A schema in which the obvious query
returns a number 6.9× too large is not slow, it is *dangerous*, and no amount of
indexing fixes that. The star schema's real contribution here is making the
correct query the easy one.

The honest scope caveat: at 300,000 encounters this is a close call. At 300
million it would not be — Q2's 22.5 seconds becomes hours, and the argument
stops being about elegance.

---

## 3. Bridge tables: worth it?

### Why not denormalize diagnoses and procedures into the fact?

There are only two ways to do it, and both are worse.

**Repeating groups** — `diagnosis_1` … `diagnosis_5` as columns. Breaks the
moment a patient presents with six. Turns "how many encounters involved
hypertension" into a five-way `OR`. This is a First Normal Form violation, and
dimensional modelling does not license abandoning 1NF.

**Change the fact grain to diagnosis level** — which reintroduces the exact
inflation measured in Q2. `SUM(allowed_amount)` becomes wrong by default, for
every user, permanently. The obvious query becomes the wrong query.

### The trade-off, stated honestly

**Bridges do not eliminate the fan trap. They relocate it.** Q2b still forms
~2.06M pair rows against the bridges, because pairing diagnoses with procedures
inherently produces pairs — that is the question, and no schema answers it
without forming them.

What bridges actually buy:

- **The fan is opt-in.** Only queries that join a bridge can trigger it. Q1, Q3
  and Q4 never touch one and cannot be affected. In the OLTP schema, any query
  reaching for a diagnosis code was exposed.
- **Rows are narrow.** Bridge rows are 3–4 integers; the OLTP version dragged
  two `VARCHAR(200)` descriptions through the sort because they appear in the
  `GROUP BY`. That accounts for most of Q2b's 4.9×.
- **No measure is reachable.** The decisive one. Money lives on the fact table,
  which a bridge-to-bridge join does not include.

That last point is the argument. **A schema where the wrong answer is impossible
to write beats a schema where it is merely documented as inadvisable.**

### Would I do it differently in production?

Three changes:

1. **Add a weighting factor to the bridge** — `1/n` per encounter, Kimball's
   standard technique for safely allocatable bridged measures. Not needed for
   these four questions; needed the moment someone asks "what revenue is
   attributable to diabetes". The aggregate table already applies this idea, and
   it is why `total_allowed` there reconciles to $754,318,058 exactly rather than
   to a multiple of it.
2. **Make the bridges SCD-aware.** Clinical coding is frequently amended after
   discharge. The current design overwrites within the 30-day window and loses
   amendments after it.
3. **Partition `fact_encounters` by `date_key`.** Unnecessary at 300,000 rows;
   the difference between a working and a broken warehouse at 300 million.

---

## 4. Performance quantification

> **Measurement variance — read before the numbers below.** Every timing was
> re-measured in a second session on the same machine. All figures moved by
> almost exactly 2× — uniformly, across both OLTP and star columns — while the
> query plans and intermediate row counts stayed **identical to the row**. That
> is machine speed varying, not query behaviour. Treat absolute seconds as ±25%
> at best; the **ratios** held across both sessions and the conclusions rest on
> those. Full comparison and the ruled-out hypotheses:
> [`results/measurement_sessions.txt`](../results/measurement_sessions.txt).


All figures: MySQL 8.4.10, same machine, 300,000 encounters (~2.3M rows), median
of 3 warm runs. Raw plans in [`results/`](../results/). **Every star query's full
output was diffed row-by-row against its OLTP counterpart before any timing was
recorded** — all four are byte-identical.

| Query | OLTP | Star | Factor | Mechanism |
|---|---|---|---|---|
| Q1 Encounters by month/specialty | 0.606s | 0.308s | **1.97× faster** | integer-first aggregation (see below) |
| Q2 Diagnosis-procedure pairs | 10.188s | 0.026s | **392× faster** | pre-aggregated pair table |
| Q2b *same, bridges only* | 10.188s | 2.072s | *4.9× faster* | narrow rows, fewer tables |
| Q3 30-day readmissions | 0.429s | 0.349s | **1.23× faster** | self-join precomputed to a flag |
| Q4 Revenue by specialty/month | 1.081s | 0.189s | **5.72× faster** | billing join gone + integer-first |

### Query 2 — 10.188s → 0.026s, 392×

The OLTP plan built 2,060,000 intermediate rows and sorted them to return 20;
~19 of the 22.5 seconds was that sort. The star version reads 1,200 rows
computed once at load.

**Attributed honestly: this is precomputation, not dimensional modelling.** An
equivalent aggregate could have been built directly off the OLTP schema and
would have performed identically. **Q2b is the fair star-schema-only number:
4.9×.** What the star schema contributes is a stable, constraint-enforced grain
to aggregate *from* — the same aggregate built off the raw junction tables would
have to defend against duplicates, split ICD-10 codes, and NULL keys on every
run.

### Query 3 — 0.429s → 0.349s, 1.23×

The self-join is gone, not optimized — executed once by the ETL and stored as a
`TINYINT`. Worth noting this is the *smallest* of the three real improvements,
because the OLTP version was already fast: the brief predicted a self-join
disaster, and InnoDB's automatic FK index on `patient_id` meant it never
happened. 30,000 indexed probes, not a quadratic scan. The gain is 0.08 seconds.

### Query 1 — the one that was slower, and why it no longer is

The most useful result here, so it gets stated plainly rather than buried.

Written the obvious way — join `dim_date` and `dim_specialty`, then
`GROUP BY d.calendar_month, sp.specialty_name` — Q1 measured **0.746s against
the OLTP query's 0.581s.** A 1.3× regression, on the query a star schema is
supposed to help most.

The first diagnosis was wrong. It blamed `COUNT(DISTINCT patient_key)` for being
immune to dimensional modelling, and the fact table for being twice the size of
`encounters` on disk. Both are true. Neither was the cause.

**The actual cause was grouping on two VARCHARs pulled in from joined
dimensions.** That cost more than the joins saved — and the same effect had
already been measured on `dim_encounter_type`, where grouping on a joined string
ran 2.5× slower than grouping on one already in the fact row. The lesson was
sitting in the project and simply wasn't applied to Q1.

The fix needed **no schema change**:

- `FLOOR(date_key / 100)` turns `YYYYMMDD` into `YYYYMM`. The month falls out of
  the surrogate key arithmetically, so `dim_date` isn't joined at all — a payoff
  from choosing a readable `date_key` over a meaningless sequence.
- Group by `specialty_key`, an integer on the fact, not `specialty_name`.
  `dim_specialty` then joins to the **864 output rows** instead of 300,000 input
  rows.

| Version | Time |
|---|---|
| Naive star — join, then group on names | 0.746s |
| OLTP original | 0.581s |
| **Integer-first — group, then join names** | **0.287s** |

A 1.3× regression became a 2.0× improvement, output byte-identical across all
864 rows. **Q4 gained 3.3× from exactly the same rewrite.**

**What this actually demonstrates** is more useful than the original "star
schemas aren't uniformly faster" conclusion it replaced: a star schema removes
joins from the critical path, and it is still entirely possible to put the cost
back by sorting and grouping wide text instead of narrow keys. The schema was
never the problem — the query was.

An aggregate table at month/specialty/type grain would make this a
sub-millisecond lookup and is deliberately not built. At 0.3s it isn't needed,
and adding a summary table for every query that could be faster is how a
warehouse becomes an unmaintainable pile of them.

---

## 5. What this exercise actually demonstrated

**A dataset can pass every summary statistic and still be structurally dead.**
The first generated dataset used MySQL's `RAND(seed)`, whose LCG produces
correlated output for consecutive seeds. It had the correct 70/20/10 encounter
mix, correct means, correct totals — and was a rigid lattice underneath, with
`patient_id` advancing by exactly 257 for every 4 steps in `encounter_id`. It
surfaced only because Q3 reported a readmission rate of **exactly 0.00% across
all twelve specialties**: no patient ever had two encounters within 30 days,
because the arithmetic made it impossible. Aggregate checks passed; a
domain-plausibility check failed.

**Normalized and well-constrained are different properties.** The source schema
is properly in 3NF and has nine constraint gaps: every non-PK column nullable,
no `UNIQUE` on either junction table, free-text `encounter_type` with no
`CHECK`, `billing.encounter_id` not unique despite being 1:1, and no audit
columns anywhere. That last one blocks the brief's own Part 3.4 requirement —
there is no way to detect changed rows — and forced the rolling 30-day
restatement window in `etl_design.txt`. Normalization is about redundancy;
constraints are about validity. Passing one says nothing about the other.

**Measure before claiming.** Three predictions made from the brief's hints were
wrong: Q3 was expected to be the slowest and was the fastest; Q1 was expected to
improve and initially got WORSE, until the query rather than the schema was
fixed; the "missing index" bottleneck the hints imply does not
exist, because InnoDB indexes foreign key columns automatically. Every one of
those was caught by running the query rather than reasoning about it.

**The honest summary:** the star schema here bought a 6.9× correctness guarantee
and a 1.23×–392× performance change whose largest component is not dimensional
modelling at all — and two of the four queries only reached their figures after
being rewritten to aggregate on integer keys rather than on joined text. A star
schema makes fast queries possible; it does not make slow ones fast. Both are worth having. Neither is what a
before/after table alone would have shown.
