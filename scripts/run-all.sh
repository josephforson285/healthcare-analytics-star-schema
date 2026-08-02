#!/usr/bin/env bash
# Full end-to-end rebuild from nothing. ~3.5 minutes.
# Run from anywhere; paths resolve relative to the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n=== %-34s ' "$1"; }
t0=$(date +%s)

step "01 OLTP schema";      s=$(date +%s); mysql < sql/01_oltp_schema.sql;                     echo "$(( $(date +%s)-s ))s"
step "02 generate data";    s=$(date +%s); mysql < sql/02_generate_data.sql   > /dev/null;     echo "$(( $(date +%s)-s ))s"
step "03 OLTP queries";     s=$(date +%s); mysql < sql/03_oltp_queries.sql    > /dev/null;     echo "$(( $(date +%s)-s ))s"
step "04 star schema DDL";  s=$(date +%s); mysql < sql/04_star_schema.sql;                     echo "$(( $(date +%s)-s ))s"
step "05 ETL";              s=$(date +%s); mysql < sql/05_etl.sql             > /dev/null;     echo "$(( $(date +%s)-s ))s"
step "06 star queries";     s=$(date +%s); mysql < sql/06_star_queries.sql    > /dev/null;     echo "$(( $(date +%s)-s ))s"

printf '\n=== total: %ss\n' "$(( $(date +%s)-t0 ))"
