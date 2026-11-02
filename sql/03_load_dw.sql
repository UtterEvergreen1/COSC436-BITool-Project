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