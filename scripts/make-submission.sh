#!/usr/bin/env bash
# Assemble submission/ containing the six deliverables under the EXACT
# filenames the brief asks for.
#
# The repo keeps numbered, ordered filenames (01_, 02_, ...) because that
# is how the project is meant to be run and read. The brief asks for bare
# names. Rather than compromise either, this script produces a flat
# submission folder from the repo, so the two never drift apart.
#
# Regenerate after any edit:  bash scripts/make-submission.sh

set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf submission
mkdir -p submission

cp docs/query_analysis.txt        submission/query_analysis.txt
cp docs/design_decisions.txt      submission/design_decisions.txt
cp sql/04_star_schema.sql         submission/star_schema.sql
cp docs/star_schema_queries.txt   submission/star_schema_queries.txt
cp docs/etl_design.txt            submission/etl_design.txt
cp docs/reflection.md             submission/reflection.md

# Supporting material -- not required by the brief, but every deliverable
# above cites it, so a marker reading only submission/ should have it.
cp docs/00-findings-and-assumptions.md submission/findings-and-assumptions.md
cp sql/01_oltp_schema.sql         submission/oltp_schema.sql
cp sql/02_generate_data.sql       submission/generate_data.sql
cp sql/03_oltp_queries.sql        submission/oltp_queries.sql
cp sql/05_etl.sql                 submission/etl.sql
cp sql/06_star_queries.sql        submission/star_queries_runnable.sql
cp -r results                     submission/results

cat > submission/README.txt <<'EOF'
SUBMISSION CONTENTS
===================

The six required deliverables:

  query_analysis.txt        Part 2   -- four OLTP queries, measured
  design_decisions.txt      Part 3.1 -- grain, dimensions, metrics, bridges
  star_schema.sql           Part 3.2 -- complete dimensional DDL
  star_schema_queries.txt   Part 3.3 -- rewritten queries, before/after
  etl_design.txt            Part 3.4 -- load logic and refresh strategy
  reflection.md             Part 4   -- analysis and trade-offs

Supporting material, cited by the above:

  findings-and-assumptions.md   every source-schema defect and every stated
                                deviation from the brief, with its disposition
  oltp_schema.sql               the brief's schema, reproduced unaltered
  generate_data.sql             realistic-volume data generation
  oltp_queries.sql              the four queries, runnable
  etl.sql                       the working ETL implementation
  star_queries_runnable.sql     the four star queries, runnable
  results/                      raw EXPLAIN ANALYZE output behind every timing


TWO THINGS TO READ FIRST
========================

1. THE DATASET IS GENERATED, NOT THE BRIEF'S SAMPLE.

   The brief supplies 4 encounters. Part 2 asks for execution times and
   Part 4 for improvement factors, and neither is measurable at that size --
   every query returns in under a millisecond, the row explosion does not
   explode, and the Q3 self-join compares 16 pairs. The bottlenecks the
   brief asks us to find are asymptotic; they only appear at volume.

   generate_data.sql therefore builds 300,000 encounters (~2.3M rows). All
   randomness is derived by hashing the row number, so the dataset is
   byte-identical on every run and on every machine, and the timings are
   reproducible.

2. THREE DELIBERATE DEPARTURES FROM THE BRIEF'S TABLE LIST.

   Each is defended in design_decisions.txt rather than made silently:

   - dim_specialty is NOT built. Part 3.2 asks for specialty inside
     dim_provider AND as its own dimension; holding both is snowflaking,
     which is what a star schema exists to avoid.
   - dim_encounter_type is NOT built. Three values, no hierarchy, no
     attributes. Kept as a degenerate dimension on the fact row.
   - age_group is on the fact row, not dim_patient. Age changes with the
     calendar rather than with any source event, so storing it in the
     dimension would go stale and corrupt historical reporting.


REPRODUCING THE RESULTS
=======================

Requires MySQL 8.x. From the repository root:

    mysql < sql/01_oltp_schema.sql     #   ~1s
    mysql < sql/02_generate_data.sql   #  ~99s
    mysql < sql/03_oltp_queries.sql    #  ~27s   the "before"
    mysql < sql/04_star_schema.sql     #   ~1s
    mysql < sql/05_etl.sql             #  ~68s
    mysql < sql/06_star_queries.sql    #   ~7s   the "after"

sql/99_oltp_hardening.sql is an appendix and must NOT be run. It expresses
the source-schema fixes as DDL; executing it before the Part 2 measurements
would make those numbers describe our tuning rather than the schema the
brief asked us to analyse.
EOF

echo "submission/ rebuilt:"
ls -1 submission/
