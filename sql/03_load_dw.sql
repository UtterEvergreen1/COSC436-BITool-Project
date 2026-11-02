INSERT INTO FactTrades (InstrumentKey, StrategyKey, TraderKey, EntryDateKey, ExitDateKey,
                        Side, Quantity, EntryPrice, ExitPrice)
SELECT i.InstrumentKey, st.StrategyKey, tr.TraderKey,
    to_char(b.entry_date, 'YYYYMMDD')::int, to_char(b.exit_date, 'YYYYMMDD')::int,
    b.side, b.quantity, b.entry_price, b.exit_price
FROM staging.stg_bt_trades b
JOIN DimInstrument i ON i.Symbol = b.symbol
JOIN DimStrategy st ON st.StrategyName = b.strategy_name
JOIN DimTrader tr ON tr.TraderName s.trader_name
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

INSERT INTO FactPositions (InstrumentKey, DateKey, StrategyKey, TraderKey, Quantity, MarketValue)
SELECT t.InstrumentKey, d.DateKey, t.StrategyKey, t.TraderKey,
    SUM(CASE WHEN t.Side = 'BUY' THEN t.Quantity ELSE -t.Quantity END),
    SUM(CASE WHEN t.Side = 'BUY' THEN t.Quantity ELSE -t.Quantity END * m.Close)
FROM FactTrades t
JOIN DimDate d ON d.DateKey >= t.EntryDateKey AND d.DateKey < t.ExitDateKey AND d.IsTradingDay
JOIN FactMarketData m ON m.InstrumentKey = t.InstrumentKey AND m.DateKey = d.DateKey
GROUP BY t.InstrumentKey, d.DateKey, t.StrategyKey, t.TraderKey;

INSERT INTO FactBacktestResults (StrategyKey, StartDateKey, EndDateKey, NumTrades,
                                WinRate, TotalPnL, TotalReturn, MaxDrawdown, Sharpe)
SELECT st.StrategyKey, to_char(r.start_date, 'YYYYMMDD')::int, to_char(r.end_date, 'YYYYMMDD')::int,
        r.num_trades, r.win_rate, r.total_pnl, r.total_return, r.max_drawdown, r.sharpe
FROM staging.stg bt results r
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
