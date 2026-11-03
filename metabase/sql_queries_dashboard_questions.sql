-- =====================================================================
-- Metabase dashboard questions, schema v2 (run 01-04 first: these read mv_monthly_pnl)
--
-- Create one SQL question per block (New > SQL query), paste the query, then in the
-- variable panel set the types below. Column aliases are the axis labels.
--   strategy    Text  (optional)
--   start_date  Date  (optional)
--   end_date    Date  (optional)
--   ticker      Text  (REQUIRED, default value AAPL)  -- Q6 only
-- On the dashboard, add a Text filter "Strategy", a Date filter "From", a Date filter
-- "To" and a Text filter "Ticker", and connect each to the matching variable.
-- Chart types in brackets.
-- =====================================================================

-- Q1  Cumulative P&L by strategy  [Line; X = Month, Y = Cumulative P&L ($), series = Strategy]
SELECT MonthStart AS "Month",
       StrategyName AS "Strategy",
       ROUND(SUM(PnL) OVER (PARTITION BY StrategyName ORDER BY MonthStart), 2) AS "Cumulative P&L ($)"
FROM dw.mv_monthly_pnl
WHERE 1 = 1
  [[AND StrategyName = {{strategy}}]]
  [[AND MonthStart >= {{start_date}}]]
  [[AND MonthStart <= {{end_date}}]]
ORDER BY 1, 2;

-- Q2  Win rate by strategy  [Bar; X = Strategy, Y = Win rate (%)]
SELECT StrategyName AS "Strategy",
       ROUND(100.0 * SUM(Wins) / NULLIF(SUM(Trades), 0), 1) AS "Win rate (%)"
FROM dw.mv_monthly_pnl
WHERE 1 = 1
  [[AND StrategyName = {{strategy}}]]
  [[AND MonthStart >= {{start_date}}]]
  [[AND MonthStart <= {{end_date}}]]
GROUP BY 1
ORDER BY 1;

-- Q3  Backtest summary  [Table]
SELECT s.StrategyName                AS "Strategy",
       r.NumTrades                   AS "Trades",
       ROUND(100 * r.WinRate, 1)     AS "Win rate (%)",
       ROUND(r.TotalPnL, 0)          AS "Total P&L ($)",
       ROUND(100 * r.TotalReturn, 1) AS "Total return (%)",
       ROUND(100 * r.MaxDrawdown, 1) AS "Max drawdown (%)",
       ROUND(r.Sharpe, 2)            AS "Sharpe ratio"
FROM dw.FactBacktestResults r
JOIN dw.DimStrategy s ON s.StrategyKey = r.StrategyKey
ORDER BY 1;

-- Q4  Net exposure at month-end  [Line; X = Month, Y = Net exposure ($), series = Strategy]
WITH month_end AS (
  SELECT Year, Month, MAX(DateKey) AS DateKey
  FROM dw.DimDate WHERE IsTradingDay
  GROUP BY Year, Month
)
SELECT make_date(me.Year::int, me.Month::int, 1) AS "Month",
       s.StrategyName                            AS "Strategy",
       ROUND(SUM(p.MarketValue), 2)              AS "Net exposure ($)"
FROM dw.FactPositions p
JOIN month_end me  ON me.DateKey    = p.DateKey
JOIN dw.DimStrategy s ON s.StrategyKey = p.StrategyKey
WHERE 1 = 1
  [[AND s.StrategyName = {{strategy}}]]
  [[AND make_date(me.Year::int, me.Month::int, 1) >= {{start_date}}]]
  [[AND make_date(me.Year::int, me.Month::int, 1) <= {{end_date}}]]
GROUP BY 1, 2
ORDER BY 1, 2;

-- Q5  Top 10 instruments by P&L  [Bar; X = Ticker, Y = Total P&L ($)]
SELECT i.Symbol AS "Ticker",
       ROUND(SUM(t.ProfitLoss), 2) AS "Total P&L ($)"
FROM dw.FactTrades t
JOIN dw.DimInstrument i ON i.InstrumentKey = t.InstrumentKey
JOIN dw.DimStrategy s   ON s.StrategyKey   = t.StrategyKey
JOIN dw.DimDate d       ON d.DateKey       = t.ExitDateKey
WHERE 1 = 1
  [[AND s.StrategyName = {{strategy}}]]
  [[AND d.FullDate >= {{start_date}}]]
  [[AND d.FullDate <= {{end_date}}]]
GROUP BY i.Symbol
ORDER BY 2 DESC
LIMIT 10;

-- Q6  Price history for one ticker  [Line; X = Date, Y = Close price ($)]
SELECT d.FullDate AS "Date",
       m.Close    AS "Close price ($)"
FROM dw.FactMarketData m
JOIN dw.DimDate d       ON d.DateKey       = m.DateKey
JOIN dw.DimInstrument i ON i.InstrumentKey = m.InstrumentKey
WHERE i.Symbol = {{ticker}}
  [[AND d.FullDate >= {{start_date}}]]
  [[AND d.FullDate <= {{end_date}}]]
ORDER BY 1;
