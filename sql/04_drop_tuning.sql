-- Removes everything 04_indexes_aggregates.sql adds (used by olap/run_timings.py
-- to get the "before" measurements). Safe to re-run.
\set ON_ERROR_STOP on
SET search_path TO dw, public;
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_pnl;
DROP INDEX IF EXISTS ix_fmd_date, ix_ft_exit_date, ix_ft_entry_date,
                     ix_ft_strategy_exit, ix_ft_instrument, ix_fp_date;
ANALYZE;
