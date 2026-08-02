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
| encounter_diagnoses | 899,976 |
| encounter_procedures | 750,000 |
| billing | 300,000 |

Encounter mix 70% Outpatient / 20% ER / 10% Inpatient; average length of stay
0.9h / 6.0h / 5.5 days respectively. Two years of activity (2023–2024),
$845.8M in allowed amounts.

## The core problem this schema has

An encounter has many diagnoses **and** many procedures, and the two are
independent. Joining both junction tables at once multiplies rows and inflates
every additive measure — the classic **fan trap**:

| | Rows | Total allowed |
|---|---|---|
| Truth | 300,000 | $845.8M |
| Naive join of both junction tables | 2,249,947 | $6,276.6M |

That is a 7.4× overstatement of revenue produced by a query that runs clean and
returns no error. It is a *correctness* failure that also happens to be slow,
and it is what forces the two central design decisions later: the fact table
grain, and whether to use bridge tables.

## Layout

```
docs/     design decisions, ETL design, query analysis, reflection
sql/      numbered, run in order
results/  raw EXPLAIN ANALYZE output — the evidence behind every timing claim
```

## Running it

Requires MySQL 8.x.

```bash
mysql < sql/01_oltp_schema.sql     # ~0s
mysql < sql/02_generate_data.sql   # ~40s
```
