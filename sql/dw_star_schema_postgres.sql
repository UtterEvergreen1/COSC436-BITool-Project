-- =====================================================================
-- Algorithmic trading DW (PostgreSQL): star schema + generated data
--
-- Prerequisite: John's load_staging.py has loaded
--   staging.stg_market_ohlcv   (Kaggle S&P 500 daily OHLCV, real data)
--
-- Run (psql):
--   psql -h localhost -p 5433 -U dw_admin -d trading_dw -f dw_star_schema_postgres.sql
-- or paste into DBeaver / pgAdmin and run as a script.
--
-- What it does:
--   * Builds the star schema from Caleb's diagram in a separate "dw" schema
--     (staging -> dw mirrors the architecture diagram).
--   * DimInstrument, DimTime, FactMarketData come from the REAL staging data.
--   * DimStrategy, DimTrader, FactTrades, FactPositions are GENERATED
--     (the dataset has no trading activity). Trade prices and P&L use the
--     real closing prices, so P&L is consistent with the market data.
--
-- Differences from Caleb's diagram (all marked "ADDED" or "NOTE" below):
--   * FactTrades.Side added (BUY/SELL). Without it, P&L has no direction.
--     Drop the column and the CASE in the P&L formula if the team disagrees.
--   * DimTime is daily here because the data is daily (Hour/Minute/Second = 0).
--   * Types mapped to Postgres; names are lower-cased by Postgres (unquoted).
--
-- Safe to re-run: it drops and recreates the "dw" schema (not "staging").
-- Generated data is random: counts and totals differ on every run.
-- =====================================================================

-- Guard: stop before dropping anything if staging isn't loaded.
DO $$
DECLARE loaded boolean := false;
BEGIN
  IF to_regclass('staging.stg_market_ohlcv') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM staging.stg_market_ohlcv)' INTO loaded;
  END IF;
  IF NOT loaded THEN
    RAISE EXCEPTION 'staging.stg_market_ohlcv is missing or empty - run load_staging.py first';
  END IF;
END $$;

DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;
SET search_path TO dw, public;

-- 1. Dimensions -------------------------------------------------------
CREATE TABLE DimInstrument (
  InstrumentKey  INT          NOT NULL PRIMARY KEY,
  InstrumentName VARCHAR(128),
  Symbol         VARCHAR(32)  NOT NULL UNIQUE,
  AssetClass     VARCHAR(64),
  Exchange       VARCHAR(64)
);

CREATE TABLE DimTrader (
  TraderKey   INT          NOT NULL PRIMARY KEY,
  TraderName  VARCHAR(128) NOT NULL,
  TraderType  VARCHAR(64)
);

CREATE TABLE DimStrategy (
  StrategyKey         INT          NOT NULL PRIMARY KEY,
  StrategyName        VARCHAR(128) NOT NULL,
  StrategyType        VARCHAR(64),
  StrategyDescription VARCHAR(512)
);

CREATE TABLE DimTime (
  TimeKey   INT       NOT NULL PRIMARY KEY,   -- yyyymmdd, e.g. 20130208
  Timestamp TIMESTAMP NOT NULL,
  Date      DATE      NOT NULL,
  Year      SMALLINT,
  Quarter   SMALLINT,
  Month     SMALLINT,
  Day       SMALLINT,
  Hour      SMALLINT,
  Minute    SMALLINT,
  Second    SMALLINT
);

-- 2. Facts ------------------------------------------------------------
CREATE TABLE FactMarketData (
  MarketDataKey BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  InstrumentKey INT    NOT NULL REFERENCES DimInstrument (InstrumentKey),
  TimeKey       INT    NOT NULL REFERENCES DimTime (TimeKey),
  Open          NUMERIC(18,6),
  Close         NUMERIC(18,6),
  High          NUMERIC(18,6),
  Low           NUMERIC(18,6),
  Volume        NUMERIC(22,4)
);

CREATE TABLE FactTrades (
  TradeKey      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  InstrumentKey INT    NOT NULL REFERENCES DimInstrument (InstrumentKey),
  TimeKey       INT    NOT NULL REFERENCES DimTime (TimeKey),
  StrategyKey   INT    NOT NULL REFERENCES DimStrategy (StrategyKey),
  TraderKey     INT    NOT NULL REFERENCES DimTrader (TraderKey),
  Quantity      NUMERIC(18,4),
  Price         NUMERIC(18,6),
  ProfitLoss    NUMERIC(18,6),
  Side          VARCHAR(4) NOT NULL CHECK (Side IN ('BUY','SELL'))  -- ADDED, not in the diagram
);

CREATE TABLE FactPositions (
  PositionKey   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  InstrumentKey INT    NOT NULL REFERENCES DimInstrument (InstrumentKey),
  TimeKey       INT    NOT NULL REFERENCES DimTime (TimeKey),
  TraderKey     INT    NOT NULL REFERENCES DimTrader (TraderKey),
  StrategyKey   INT    NOT NULL REFERENCES DimStrategy (StrategyKey),
  Quantity      NUMERIC(18,4),
  MarketValue   NUMERIC(22,6)
);

-- Postgres doesn't index foreign keys automatically; Metabase joins/filters use these.
CREATE INDEX ix_fmd_instrument_time ON FactMarketData (InstrumentKey, TimeKey);
CREATE INDEX ix_fmd_time            ON FactMarketData (TimeKey);
CREATE INDEX ix_ft_instrument       ON FactTrades (InstrumentKey);
CREATE INDEX ix_ft_time             ON FactTrades (TimeKey);
CREATE INDEX ix_ft_strategy         ON FactTrades (StrategyKey);
CREATE INDEX ix_ft_trader           ON FactTrades (TraderKey);
CREATE INDEX ix_fp_instrument       ON FactPositions (InstrumentKey);
CREATE INDEX ix_fp_time             ON FactPositions (TimeKey);

-- 3. Dimensions: real data from staging -------------------------------
-- The dataset only has tickers: no company names or exchanges, so
-- InstrumentName = ticker (placeholder) and Exchange stays NULL.
INSERT INTO DimInstrument (InstrumentKey, InstrumentName, Symbol, AssetClass, Exchange)
SELECT ROW_NUMBER() OVER (ORDER BY ticker), ticker, ticker, 'Equity', NULL
FROM (SELECT DISTINCT ticker FROM staging.stg_market_ohlcv) t;

-- One row per calendar day across the data's date range.
-- NOTE: the data is daily, so Hour/Minute/Second are always 0.
INSERT INTO DimTime (TimeKey, Timestamp, Date, Year, Quarter, Month, Day, Hour, Minute, Second)
SELECT to_char(g.d, 'YYYYMMDD')::int,
       g.d,
       g.d::date,
       EXTRACT(YEAR    FROM g.d)::smallint,
       EXTRACT(QUARTER FROM g.d)::smallint,
       EXTRACT(MONTH   FROM g.d)::smallint,
       EXTRACT(DAY     FROM g.d)::smallint,
       0, 0, 0
FROM generate_series(
       (SELECT MIN(trade_date) FROM staging.stg_market_ohlcv)::timestamp,
       (SELECT MAX(trade_date) FROM staging.stg_market_ohlcv)::timestamp,
       INTERVAL '1 day') AS g(d);

-- 4. Dimensions: generated (synthetic) --------------------------------
INSERT INTO DimStrategy (StrategyKey, StrategyName, StrategyType, StrategyDescription) VALUES
  (1, 'Momentum Alpha',      'Trend Following', 'Buys assets with strong recent returns'),
  (2, 'Mean Reversion Beta', 'Mean Reversion',  'Fades short-term price extremes'),
  (3, 'Market Maker Gamma',  'Market Making',   'Quotes both sides to capture the spread'),
  (4, 'Breakout Delta',      'Trend Following', 'Enters on range breakouts');

INSERT INTO DimTrader (TraderKey, TraderName, TraderType) VALUES
  (1, 'Bot-Alpha',  'System'),
  (2, 'Bot-Beta',   'System'),
  (3, 'Bot-Gamma',  'System'),
  (4, 'Bot-Delta',  'System'),
  (5, 'Human Desk', 'Human');

-- 5. FactMarketData: real data ----------------------------------------
INSERT INTO FactMarketData (InstrumentKey, TimeKey, Open, Close, High, Low, Volume)
SELECT i.InstrumentKey,
       to_char(s.trade_date, 'YYYYMMDD')::int,
       s.open_price, s.close_price, s.high_price, s.low_price, s.volume
FROM staging.stg_market_ohlcv s
JOIN DimInstrument i ON i.Symbol = s.ticker
ORDER BY s.ticker, s.trade_date;

-- 6. FactTrades: generated, priced from real data ---------------------
-- ~2% of market-data rows become a trade (entry at that day's close).
-- Each trade is closed 1-10 trading days later at that day's real close,
-- so ProfitLoss = Quantity * (exit - entry), sign flipped for SELL.
-- Strategies differ only in how often they BUY (70/55/50/35 %). The S&P rose
-- over this period, which tilts results toward buying, but the per-trade
-- noise is large, so strategy rankings change from run to run. Treat all
-- P&L differences as an artifact of the generator, not a finding.
WITH md AS (
  SELECT InstrumentKey, TimeKey, Close,
         ROW_NUMBER() OVER (PARTITION BY InstrumentKey ORDER BY TimeKey) AS rn
  FROM FactMarketData
  WHERE Close IS NOT NULL
),
picks AS (
  SELECT m.InstrumentKey, m.TimeKey, m.Close, m.rn,
         1 + floor(random() * 4)::int  AS StrategyKey,
         1 + floor(random() * 5)::int  AS TraderKey,
         1 + floor(random() * 10)::int AS hold_days,
         random()                      AS r_side,
         (5000 + random() * 45000)::numeric AS notional
  FROM md m
  WHERE random() < 0.02
),
sided AS (
  SELECT p.*,
         CASE WHEN p.r_side < CASE p.StrategyKey
                                WHEN 1 THEN 0.70
                                WHEN 2 THEN 0.55
                                WHEN 3 THEN 0.50
                                ELSE 0.35 END
              THEN 'BUY' ELSE 'SELL' END AS Side,
         round(p.notional / p.Close, 4)  AS qty
  FROM picks p
)
INSERT INTO FactTrades (InstrumentKey, TimeKey, StrategyKey, TraderKey, Quantity, Price, ProfitLoss, Side)
SELECT s.InstrumentKey, s.TimeKey, s.StrategyKey, s.TraderKey,
       s.qty,
       s.Close,
       round(s.qty * (x.Close - s.Close) * CASE WHEN s.Side = 'BUY' THEN 1 ELSE -1 END, 6),
       s.Side
FROM sided s
JOIN md x ON x.InstrumentKey = s.InstrumentKey AND x.rn = s.rn + s.hold_days;

-- 7. FactPositions: generated, valued at real month-end closes --------
-- 20 randomly chosen instruments x 4 strategies, one snapshot per month
-- (last trading day of the month). ~30% of positions are short (negative).
-- The trader is the bot that runs the strategy (TraderKey = StrategyKey).
WITH month_end AS (
  SELECT DISTINCT ON (m.InstrumentKey, date_trunc('month', t.Date))
         m.InstrumentKey, m.TimeKey, m.Close
  FROM FactMarketData m
  JOIN DimTime t ON t.TimeKey = m.TimeKey
  WHERE m.Close IS NOT NULL
  ORDER BY m.InstrumentKey, date_trunc('month', t.Date), m.TimeKey DESC
),
tracked AS (
  SELECT InstrumentKey FROM DimInstrument ORDER BY random() LIMIT 20
),
snap AS (
  SELECT me.InstrumentKey, me.TimeKey, me.Close, s.StrategyKey,
         round((5000 + random() * 45000)::numeric / me.Close
               * CASE WHEN random() < 0.3 THEN -1 ELSE 1 END, 4) AS qty
  FROM month_end me
  JOIN tracked tr ON tr.InstrumentKey = me.InstrumentKey
  CROSS JOIN DimStrategy s
)
INSERT INTO FactPositions (InstrumentKey, TimeKey, TraderKey, StrategyKey, Quantity, MarketValue)
SELECT InstrumentKey, TimeKey, StrategyKey, StrategyKey, qty, round(qty * Close, 6)
FROM snap;

ANALYZE;

-- 8. Sanity checks ----------------------------------------------------
SELECT 'DimInstrument' AS tbl, COUNT(*) AS row_count FROM DimInstrument UNION ALL
SELECT 'DimStrategy',          COUNT(*) FROM DimStrategy     UNION ALL
SELECT 'DimTrader',            COUNT(*) FROM DimTrader       UNION ALL
SELECT 'DimTime',              COUNT(*) FROM DimTime         UNION ALL
SELECT 'FactMarketData',       COUNT(*) FROM FactMarketData  UNION ALL
SELECT 'FactTrades',           COUNT(*) FROM FactTrades      UNION ALL
SELECT 'FactPositions',        COUNT(*) FROM FactPositions;

-- FactMarketData must equal the staging row count.
SELECT (SELECT COUNT(*) FROM staging.stg_market_ohlcv) AS staging_rows,
       (SELECT COUNT(*) FROM FactMarketData)           AS fact_rows;

SELECT s.StrategyName, COUNT(*) AS trades, ROUND(SUM(f.ProfitLoss), 2) AS total_pnl
FROM FactTrades f JOIN DimStrategy s ON s.StrategyKey = f.StrategyKey
GROUP BY s.StrategyName ORDER BY total_pnl DESC;

-- 9. Optional: read-only Metabase user (run once as dw_admin) ---------
--   CREATE ROLE metabase_ro LOGIN PASSWORD 'change_me_ro';
--   GRANT USAGE ON SCHEMA dw TO metabase_ro;
--   GRANT SELECT ON ALL TABLES IN SCHEMA dw TO metabase_ro;
--   ALTER DEFAULT PRIVILEGES IN SCHEMA dw GRANT SELECT ON TABLES TO metabase_ro;
-- Note: this script recreates the dw schema, so re-run the GRANT lines after each run.
