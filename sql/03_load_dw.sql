-- Load the warehouse from staging.
--
-- Run AFTER 02_staging_backtest.sql AND the three backtest CSVs have been copied
-- into staging.stg_bt_* (see etl/run_etl.py or docs/schema_contract.md).
-- Run from the repo root: the SQL folder is mounted at /sql inside the container.
-- The `search_path` must include dw (run_etl.py sets it, or add
-- `SET search_path TO dw, public;` to your psql invocation).
--
-- Order matters: the dimensions and FactMarketData come from the real staging data
-- first, then the backtest flows into FactTrades / FactPositions / FactBacktestResults.

SET search_path TO dw, public;

-- Guard: this script assumes 01_schema.sql has built the `dw` schema. It also
-- truncates everything first, so it can be run again after a rebuild.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'dw') THEN
        RAISE EXCEPTION 'schema dw does not exist - run sql/01_schema.sql first';
    END IF;
END $$;

TRUNCATE TABLE dw.FactTrades, dw.FactPositions, dw.FactBacktestResults,
             dw.FactMarketData, dw.DimDate, dw.DimInstrument,
             dw.DimStrategy, dw.DimTrader;

-- 1. DimInstrument: one row per ticker (the Kaggle file has no names or exchanges).
INSERT INTO DimInstrument (InstrumentKey, Symbol, AssetClass, FirstDate, LastDate, BarCount)
SELECT ROW_NUMBER() OVER (ORDER BY ticker),
       ticker, 'Equity',
       MIN(trade_date), MAX(trade_date), COUNT(*)
FROM staging.stg_market_ohlcv
GROUP BY ticker;

-- 2. DimDate: one row per calendar day in the data's range, with the trading-day flag.
--    1,826 rows from 2013-02-08 to 2018-02-07; 1,259 of them are trading days.
--    TradingDayNum is the sequence number of the trading day (NULL on weekends/holidays).
WITH trading_days AS (
  SELECT trade_date, ROW_NUMBER() OVER (ORDER BY trade_date) AS TradingDayNum
  FROM staging.stg_market_ohlcv
  GROUP BY trade_date
)
INSERT INTO DimDate (DateKey, FullDate, Year, Quarter, Month, MonthName, Day, DayOfWeek,
                     DayName, IsWeekend, IsTradingDay, TradingDayNum)
SELECT to_char(g.d, 'YYYYMMDD')::int,
       g.d::date,
       EXTRACT(YEAR FROM g.d)::smallint,
       EXTRACT(QUARTER FROM g.d)::smallint,
       EXTRACT(MONTH FROM g.d)::smallint,
       TO_CHAR(g.d, 'Month'),
       EXTRACT(DAY FROM g.d)::smallint,
       EXTRACT(ISODOW FROM g.d)::smallint,
       TO_CHAR(g.d, 'Day'),
       EXTRACT(ISODOW FROM g.d) IN (6, 7),
       td.TradingDayNum IS NOT NULL,
       td.TradingDayNum
FROM generate_series(
       (SELECT MIN(trade_date) FROM staging.stg_market_ohlcv)::timestamp,
       (SELECT MAX(trade_date) FROM staging.stg_market_ohlcv)::timestamp,
       INTERVAL '1 day') AS g(d)
LEFT JOIN trading_days td ON td.trade_date = g.d;

-- 3. DimStrategy and DimTrader: one row each, from the backtest strategies.
INSERT INTO DimStrategy (StrategyKey, StrategyName, StrategyType, StrategyDescription, Parameters)
SELECT ROW_NUMBER() OVER (ORDER BY s.strategy_name),
       s.strategy_name, s.strategy_type, s.description, s.parameters
FROM staging.stg_bt_strategies s;

INSERT INTO DimTrader (TraderKey, TraderName, TraderType)
SELECT ROW_NUMBER() OVER (ORDER BY trader_name),
       trader_name, trader_type
FROM staging.stg_bt_strategies
GROUP BY trader_name, trader_type;

-- 4. FactMarketData: the real staging rows, keyed to the dimensions.
INSERT INTO FactMarketData (InstrumentKey, DateKey, Open, High, Low, Close, Volume)
SELECT i.InstrumentKey,
       to_char(s.trade_date, 'YYYYMMDD')::int,
       s.open_price, s.high_price, s.low_price, s.close_price, s.volume
FROM staging.stg_market_ohlcv s
JOIN DimInstrument i ON i.Symbol = s.ticker
ORDER BY s.ticker, s.trade_date;

-- 5. FactTrades: the backtest trades, keyed to the dimensions. The trader comes from
--    the strategy row (staging.stg_bt_strategies holds trader_name per strategy).
INSERT INTO FactTrades (InstrumentKey, StrategyKey, TraderKey, EntryDateKey, ExitDateKey,
                        Side, Quantity, EntryPrice, ExitPrice)
SELECT i.InstrumentKey, st.StrategyKey, tr.TraderKey,
    to_char(b.entry_date, 'YYYYMMDD')::int, to_char(b.exit_date, 'YYYYMMDD')::int,
    b.side, b.quantity, b.entry_price, b.exit_price
FROM staging.stg_bt_trades b
JOIN DimInstrument i ON i.Symbol = b.symbol
JOIN staging.stg_bt_strategies s ON s.strategy_name = b.strategy_name
JOIN DimStrategy st ON st.StrategyName = s.strategy_name
JOIN DimTrader tr ON tr.TraderName = s.trader_name
ORDER BY b.entry_date, b.strategy_name, b.symbol;

DO $$
DECLARE staged bigint; loaded bigint;
BEGIN
    SELECT COUNT(*) INTO staged FROM staging.stg_bt_trades;
    SELECT COUNT(*) INTO loaded FROM dw.FactTrades;
    IF staged <> loaded THEN
        RAISE EXCEPTION 'FactTrades row mismatch: % staged, % loaded (unknown symbol or strategy?)', staged, loaded;
    END IF;
END $$;

-- 6. FactPositions: one row per (strategy, trader, instrument, trading day) with a
--    non-flat end-of-day position, netting any overlapping trades.
INSERT INTO FactPositions (InstrumentKey, DateKey, StrategyKey, TraderKey, Quantity, MarketValue)
SELECT t.InstrumentKey, d.DateKey, t.StrategyKey, t.TraderKey,
    SUM(CASE WHEN t.Side = 'BUY' THEN t.Quantity ELSE -t.Quantity END),
    SUM(CASE WHEN t.Side = 'BUY' THEN t.Quantity ELSE -t.Quantity END * m.Close)
FROM FactTrades t
JOIN DimDate d ON d.DateKey >= t.EntryDateKey AND d.DateKey < t.ExitDateKey AND d.IsTradingDay
JOIN FactMarketData m ON m.InstrumentKey = t.InstrumentKey AND m.DateKey = d.DateKey
GROUP BY t.InstrumentKey, d.DateKey, t.StrategyKey, t.TraderKey
HAVING SUM(CASE WHEN t.Side = 'BUY' THEN t.Quantity ELSE -t.Quantity END) <> 0;  -- non-flat only

-- 7. FactBacktestResults: the per-strategy backtest summary.
INSERT INTO FactBacktestResults (StrategyKey, StartDateKey, EndDateKey, NumTrades,
                                 WinRate, TotalPnL, TotalReturn, MaxDrawdown, Sharpe)
SELECT st.StrategyKey, to_char(r.start_date, 'YYYYMMDD')::int, to_char(r.end_date, 'YYYYMMDD')::int,
        r.num_trades, r.win_rate, r.total_pnl, r.total_return, r.max_drawdown, r.sharpe
FROM staging.stg_bt_results r
JOIN DimStrategy st ON st.StrategyName = r.strategy_name;

ANALYZE;

-- Count rows

SELECT 'DimDate' AS tbl, COUNT(*) AS row_count FROM DimDate UNION ALL
SELECT 'DimInstrument', Count(*) FROM DimInstrument UNION ALL
SELECT 'DimStrategy', COUNT(*) FROM DimStrategy UNION ALL
SELECT 'DimTrader', COUNT(*) FROM DimTrader UNION ALL
SELECT 'FactMarketData', COUNT(*) FROM FactMarketData UNION ALL
SELECT 'FactTrades', COUNT(*) FROM FactTrades UNION ALL
SELECT 'FactPositions', COUNT(*) FROM FactPositions UNION ALL
SELECT 'FactBacktestResults', COUNT(*) FROM FactBacktestResults;
