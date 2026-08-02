-- Runs the whole project end to end. ~3 minutes.
SOURCE sql/01_oltp_schema.sql;
SOURCE sql/02_generate_data.sql;
SOURCE sql/04_star_schema.sql;
SOURCE sql/05_etl.sql;
