-- =====================================================================
-- olap_queries.sql  -  OLAP operations on the warehouse (schema dw)
-- Each block starts with "-- name: <id> | <operation> | <description>".
-- olap/run_timings.py reads this file; keep the marker format.
-- P&L is booked on the trade's exit date.
-- =====================================================================

-- name: q1_rollup | Roll-up | P&L per strategy rolled up from month to quarter to year (+ strategy total)
SELECT s.StrategyName, d.Year, d.Quarter, d.Month,
       COUNT(*) AS trades, ROUND(SUM(t.ProfitLoss), 2) AS pnl
FROM FactTrades t
JOIN DimDate d     ON d.DateKey     = t.ExitDateKey
JOIN DimStrategy s ON s.StrategyKey = t.StrategyKey
GROUP BY s.StrategyName, ROLLUP (d.Year, d.Quarter, d.Month)
ORDER BY s.StrategyName, d.Year, d.Quarter, d.Month;

-- name: q1_rollup_mv | Roll-up (materialized view) | Same result as q1_rollup, read from mv_monthly_pnl
SELECT StrategyName, Year, Quarter, Month,
       SUM(Trades) AS trades, ROUND(SUM(PnL), 2) AS pnl
FROM mv_monthly_pnl
GROUP BY StrategyName, ROLLUP (Year, Quarter, Month)
ORDER BY StrategyName, Year, Quarter, Month;

-- name: q2_drilldown | Drill-down | From quarter down to individual days: daily P&L of the first strategy in 2016 Q2
SELECT d.FullDate, COUNT(*) AS trades, ROUND(SUM(t.ProfitLoss), 2) AS pnl
FROM FactTrades t
JOIN DimDate d ON d.DateKey = t.ExitDateKey
WHERE t.StrategyKey = (SELECT MIN(StrategyKey) FROM DimStrategy)
  AND d.Year = 2016 AND d.Quarter = 2
GROUP BY d.FullDate
ORDER BY d.FullDate;

-- name: q3_slice | Slice | One date only (2017-06-30): the 10 most traded instruments
SELECT i.Symbol, m.Close, m.Volume
FROM FactMarketData m
JOIN DimInstrument i ON i.InstrumentKey = m.InstrumentKey
WHERE m.DateKey = 20170630
ORDER BY m.Volume DESC NULLS LAST
LIMIT 10;

-- name: q4_dice | Dice | Sub-cube on instrument AND time: symbols starting with A, 2016 Q1-Q2, average close and volume per quarter
SELECT i.Symbol, d.Quarter,
       ROUND(AVG(m.Close), 2) AS avg_close, SUM(m.Volume) AS total_volume
FROM FactMarketData m
JOIN DimInstrument i ON i.InstrumentKey = m.InstrumentKey
JOIN DimDate d       ON d.DateKey       = m.DateKey
WHERE i.Symbol LIKE 'A%' AND d.Year = 2016 AND d.Quarter IN (1, 2)
GROUP BY i.Symbol, d.Quarter
ORDER BY i.Symbol, d.Quarter;

-- name: q5_pivot | Pivot | Quarters as columns: P&L per strategy and year
SELECT s.StrategyName, d.Year,
       ROUND(SUM(t.ProfitLoss) FILTER (WHERE d.Quarter = 1), 2) AS q1,
       ROUND(SUM(t.ProfitLoss) FILTER (WHERE d.Quarter = 2), 2) AS q2,
       ROUND(SUM(t.ProfitLoss) FILTER (WHERE d.Quarter = 3), 2) AS q3,
       ROUND(SUM(t.ProfitLoss) FILTER (WHERE d.Quarter = 4), 2) AS q4,
       ROUND(SUM(t.ProfitLoss), 2) AS total
FROM FactTrades t
JOIN DimDate d     ON d.DateKey     = t.ExitDateKey
JOIN DimStrategy s ON s.StrategyKey = t.StrategyKey
GROUP BY s.StrategyName, d.Year
ORDER BY s.StrategyName, d.Year;

-- name: q6_exposure | Slice (dashboard query) | Net exposure per strategy at each month-end (largest fact table, FactPositions)
WITH month_end AS (
  SELECT Year, Month, MAX(DateKey) AS DateKey
  FROM DimDate WHERE IsTradingDay
  GROUP BY Year, Month
)
SELECT s.StrategyName, me.Year, me.Month, ROUND(SUM(p.MarketValue), 2) AS net_exposure
FROM FactPositions p
JOIN month_end me  ON me.DateKey    = p.DateKey
JOIN DimStrategy s ON s.StrategyKey = p.StrategyKey
GROUP BY s.StrategyName, me.Year, me.Month
ORDER BY s.StrategyName, me.Year, me.Month;
