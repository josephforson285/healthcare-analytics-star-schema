# Healthcare Analytics: OLTP to Star Schema

Data engineering mini project. Takes a normalized (3NF) clinical transactional
database, measures where analytical queries fall over, then designs and builds
a Kimball star schema that fixes it — with real, reproducible numbers on both
sides of the comparison.

## Why this repo generates its own data

The lab brief ships 4 encounters. At that size every query returns in under a
millisecond, so there is no bottleneck to find and no speedup to report. The
problems the brief points at — JOIN chains, row explosion across two junction
tables, self-joins — are **asymptotic**. They only appear at volume.

So `sql/02_generate_data.sql` builds a realistic dataset: **300,000 encounters
and ~2.3M rows total** across two years. Every random value is seeded from the
row number, so the data is byte-identical on every run and timings are
comparable across runs and machines.

## Dataset

| Table | Rows |
|---|---|
| specialties | 12 |
| departments | 12 |
| providers | 60 |
| patients | 50,000 |
| diagnoses | 40 (real ICD-10) |
| procedures | 30 (real CPT) |
| encounters | 300,000 |
| encounter_diagnoses | 858,360 |
| encounter_procedures | 721,035 |
| billing | 300,000 |

Encounter mix 70% Outpatient / 20% ER / 10% Inpatient; average length of stay
0.9h / 6.0h / 5.5 days respectively. Two years of activity (2023–2024),
$838.7M in allowed amounts.

## The core problem this schema has

An encounter has many diagnoses **and** many procedures, and the two are
independent. Joining both junction tables at once multiplies rows and inflates
every additive measure — the classic **fan trap**:

| | Rows | Total allowed |
|---|---|---|
| Truth | 300,000 | $838.7M |
| Naive join of both junction tables | 2,062,317 | $5,752.3M |

That is a 6.9x overstatement of revenue produced by a query that runs clean and
returns no error. It is a *correctness* failure that also happens to be slow,
and it is what forces the two central design decisions: the fact table grain,
and whether to use bridge tables.

## Results

Same four questions, same machine, same data. Median of 5 warm runs. Every star
query's output was diffed row-by-row against its OLTP counterpart before any
timing was recorded — all four are byte-identical.

| Query | OLTP | Star | Factor |
|---|---|---|---|
| Q1 Encounters by month/specialty | 0.606s | 0.308s | 1.97x faster |
| Q2 Diagnosis-procedure pairs | 10.188s | 0.026s | 392x faster |
| Q2b *same, bridges only, no aggregate table* | 10.188s | 2.072s | *4.9x faster* |
| Q3 30-day readmissions | 0.429s | 0.349s | 1.23x faster |
| Q4 Revenue by specialty/month | 1.081s | 0.189s | 5.72x faster |

Three things this table is careful about:

- **Q2b is the honest star-schema-only number.** The 392x includes a
  pre-aggregated table, which is precomputation, not dimensional modelling — the
  same aggregate could have been built on the OLTP schema.
- **Q1 was slower until the query was rewritten**, and that is the most useful
  result here. Joining `dim_date`/`dim_specialty` and then grouping on their
  VARCHAR columns cost more than the joins saved — 1.3x *slower* than OLTP.
  Grouping instead on `FLOOR(date_key/100)` and `specialty_key`, both integers
  already on the fact, and joining the text to the 864 output rows, took it to
  1.97x faster. No schema change. Q4 gained 3.3x from the same rewrite.
- **The largest gain is not performance.** Neither bridge contains a monetary
  column, so the 6.9x revenue inflation above is structurally unwriteable
  against the star schema rather than merely documented as inadvisable.

## Layout

```
docs/     design decisions, ETL design, query analysis, reflection
sql/      numbered, run in order
results/  raw EXPLAIN ANALYZE output — the evidence behind every timing claim
```

## Running it

Requires MySQL 8.x.

```bash
mysql < sql/01_oltp_schema.sql     #   ~1s  normalized source schema
mysql < sql/02_generate_data.sql   #  ~99s  300k encounters, seeded
mysql < sql/03_oltp_queries.sql    #  ~27s  the four questions, "before"
mysql < sql/04_star_schema.sql     #   ~1s  dimensional model DDL
mysql < sql/05_etl.sql             #  ~68s  load the warehouse
mysql < sql/06_star_queries.sql    #   ~7s  the four questions, "after"
```

`sql/99_oltp_hardening.sql` is an appendix, not a step — the source-schema
fixes expressed as DDL, deliberately never executed. Running it before the
Part 2 measurements would make those numbers describe our tuning rather than
the schema we were asked to analyse.

## Deliverables

| File | Part |
|---|---|
| [docs/query_analysis.txt](docs/query_analysis.txt) | 2 — four OLTP queries, measured, bottlenecks identified |
| [docs/design_decisions.txt](docs/design_decisions.txt) | 3.1 — grain, dimensions, pre-aggregates, bridges |
| [sql/04_star_schema.sql](sql/04_star_schema.sql) | 3.2 — complete dimensional DDL |
| [docs/star_schema_queries.txt](docs/star_schema_queries.txt) | 3.3 — rewritten queries with before/after |
| [docs/etl_design.txt](docs/etl_design.txt) | 3.4 — load logic and refresh strategy |
| [docs/reflection.md](docs/reflection.md) | 4 — analysis and trade-offs |

Supporting, beyond the brief:
[docs/00-findings-and-assumptions.md](docs/00-findings-and-assumptions.md)
records every source defect and stated deviation with its disposition, and
[results/](results/) holds the raw `EXPLAIN ANALYZE` output behind every timing
claim.

## Departure from the brief

All six dimensions the brief lists are built, plus `dim_diagnosis` and
`dim_procedure` which the bridge tables require. One deliberate difference:

- **`age_group` lives on the fact row, not `dim_patient`.** Age changes with
  the calendar rather than with any source event, so a value stored in the
  dimension would go stale and corrupt historical reporting. Age at the time of
  care is a property of the encounter.

`dim_specialty` is joined **directly from the fact** via `specialty_key`, and
`dim_provider` holds no specialty or department columns at all. Every dimension
sits one hop from the fact and there are **zero dimension-to-dimension foreign
keys** — no snowflake edges anywhere. Reasoning in `design_decisions.txt`.
