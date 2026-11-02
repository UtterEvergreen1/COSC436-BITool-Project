-- P&L By Strategy over time

SELECT date_trunc('month', t.date) AS month, s.strategyname, SUM(f.profitloss) AS pnl
FROM dw.facttrades f
JOIN dw.dimtime t USING (timekey)
JOIN dw.dimstrategy s USING (strategykey)
GROUP BY 1, 2 ORDER BY 1;

-- Win rate by strategy

SELECT s.strategyname, ROUND(100.0 * AVG((f.profitloss > 0)::int), 1) AS win_rate_pct, COUNT(*) AS trades
FROM dw.facttrades f JOIN dw.dimstrategy s USING (strategykey)
GROUP BY 1;

-- Exposure by strategy

SELECT date_trunc('month', t.date) AS month, s.strategyname, SUM(p.marketvalue) AS net_exposure
FROM dw.factpositions p
JOIN dw.dimtime t USING (timekey)
JOIN dw.dimstrategy s USING (strategykey)
GROUP BY 1, 2 ORDER BY 1;

-- Trades by instrument

SELECT i.symbol, COUNT(*) AS trades
FROM dw.facttrades f JOIN dw.diminstrument i USING (instrumentkey)
GROUP BY 1 ORDER BY 2 DESC LIMIT 20;

-- Price history for one ticker

SELECT t.date, m.close
FROM dw.factmarketdata m
JOIN dw.dimtime t USING (timekey)
JOIN dw.diminstrument i USING (instrumentkey)
WHERE i.symbol = 'AAPL' ORDER BY 1;