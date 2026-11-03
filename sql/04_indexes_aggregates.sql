-- =====================================================================
-- 04_indexes_aggregates.sql  -  Performance tuning (run AFTER 03_load_dw.sql)
--
-- 01_schema.sql creates only the primary keys and UNIQUE constraints on
-- purpose, so query timings can be measured before and after this file
-- (olap/run_timings.py does that). Safe to re-run.
-- Re-running 01_schema.sql drops all of this; run 04 again afterwards.
-- After reloading trades, refresh the view:
--     REFRESH MATERIALIZED VIEW dw.mv_monthly_pnl;
-- =====================================================================
\set ON_ERROR_STOP on
SET search_path TO dw, public;

-- Indexes -------------------------------------------------------------
-- The UNIQUE (InstrumentKey, DateKey) index on FactMarketData leads with
-- InstrumentKey, so it cannot serve "all instruments on one date".
CREATE INDEX IF NOT EXISTS ix_fmd_date          ON FactMarketData (DateKey);
CREATE INDEX IF NOT EXISTS ix_ft_exit_date      ON FactTrades (ExitDateKey);
CREATE INDEX IF NOT EXISTS ix_ft_entry_date     ON FactTrades (EntryDateKey);
CREATE INDEX IF NOT EXISTS ix_ft_strategy_exit  ON FactTrades (StrategyKey, ExitDateKey);
CREATE INDEX IF NOT EXISTS ix_ft_instrument     ON FactTrades (InstrumentKey);
CREATE INDEX IF NOT EXISTS ix_fp_date           ON FactPositions (DateKey);

-- Aggregate: monthly realised P&L per strategy ---------------------------
-- A trade's P&L is booked on its exit date.
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_pnl;
CREATE MATERIALIZED VIEW mv_monthly_pnl AS
SELECT s.StrategyKey,
       s.StrategyName,
       d.Year,
       d.Quarter,
       d.Month,
       make_date(d.Year::int, d.Month::int, 1)        AS MonthStart,
       COUNT(*)                                       AS Trades,
       COUNT(*) FILTER (WHERE t.ProfitLoss > 0)       AS Wins,
       SUM(t.ProfitLoss)                              AS PnL
FROM FactTrades t
JOIN DimDate     d ON d.DateKey     = t.ExitDateKey
JOIN DimStrategy s ON s.StrategyKey = t.StrategyKey
GROUP BY s.StrategyKey, s.StrategyName, d.Year, d.Quarter, d.Month;

CREATE UNIQUE INDEX ix_mv_monthly_pnl ON mv_monthly_pnl (StrategyKey, Year, Month);

ANALYZE;
