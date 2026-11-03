-- P&L By Strategy over time

SELECT date_trunc('month', d.FullDate) AS month, s.StrategyName, SUM(f.ProfitLoss) AS pnl
FROM dw.FactTrades f
JOIN dw.DimDate d ON d.DateKey = f.EntryDateKey
JOIN dw.DimStrategy s ON s.StrategyKey = f.StrategyKey
GROUP BY 1, 2 ORDER BY 1;

-- Win rate by strategy

SELECT s.StrategyName, ROUND(100.0 * AVG((f.ProfitLoss > 0)::int), 1) AS win_rate_pct, COUNT(*) AS trades
FROM dw.FactTrades f JOIN dw.DimStrategy s USING (StrategyKey)
GROUP BY 1;

-- Exposure by strategy

SELECT date_trunc('month', d.FullDate) AS month, s.StrategyName, SUM(p.MarketValue) AS net_exposure
FROM dw.FactPositions p
JOIN dw.DimDate d ON d.DateKey = p.DateKey
JOIN dw.DimStrategy s ON s.StrategyKey = p.StrategyKey
GROUP BY 1, 2 ORDER BY 1;

-- Trades by instrument

SELECT i.Symbol, COUNT(*) AS trades
FROM dw.FactTrades f JOIN dw.DimInstrument i USING (InstrumentKey)
GROUP BY 1 ORDER BY 2 DESC LIMIT 20;

-- Price history for one ticker

SELECT d.FullDate, m.Close
FROM dw.FactMarketData m
JOIN dw.DimDate d ON d.DateKey = m.DateKey
JOIN dw.DimInstrument i USING (InstrumentKey)
WHERE i.Symbol = 'AAPL' ORDER BY 1;
