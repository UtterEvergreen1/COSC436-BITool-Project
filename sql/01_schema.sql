-- Build (or rebuild) the `dw` schema. It drops and recreates the schema, so it
-- is safe to run again after every change. Run BEFORE 03_load_dw.sql.
--
-- Run order: 01_schema.sql -> load_staging.py -> 02_staging_backtest.sql ->
-- copy the three backtest CSVs -> 03_load_dw.sql -> validate.py

DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;
SET search_path TO dw, public;

CREATE TABLE DimDate (
  DateKey       INT         NOT NULL PRIMARY KEY,   
  FullDate      DATE        NOT NULL UNIQUE,
  Year          SMALLINT    NOT NULL,
  Quarter       SMALLINT    NOT NULL,                
  Month         SMALLINT    NOT NULL,                
  MonthName     VARCHAR(9)  NOT NULL,
  Day           SMALLINT    NOT NULL,
  DayOfWeek     SMALLINT    NOT NULL,                
  DayName       VARCHAR(9)  NOT NULL,
  IsWeekend     BOOLEAN     NOT NULL,
  IsTradingDay  BOOLEAN     NOT NULL,                
  TradingDayNum INT                                  
);

CREATE TABLE DimInstrument (
  InstrumentKey INT         NOT NULL PRIMARY KEY,
  Symbol        VARCHAR(32) NOT NULL UNIQUE,
  AssetClass    VARCHAR(64) NOT NULL,                -- 'Equity' for every row (S&P 500 constituents)
  FirstDate     DATE,                                
  LastDate      DATE,                                
  BarCount      INT                                  
);

CREATE TABLE DimStrategy (
  StrategyKey         INT          NOT NULL PRIMARY KEY,
  StrategyName        VARCHAR(128) NOT NULL UNIQUE,
  StrategyType        VARCHAR(64),
  StrategyDescription VARCHAR(512),
  Parameters          VARCHAR(256)                   -- for example "fast=20, slow=50"
);
 
CREATE TABLE DimTrader (
  TraderKey   INT          NOT NULL PRIMARY KEY,
  TraderName  VARCHAR(128) NOT NULL UNIQUE,
  TraderType  VARCHAR(16)  NOT NULL CHECK (TraderType IN ('System','Human'))
);

CREATE TABLE FactMarketData (
  MarketDataKey BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  InstrumentKey INT    NOT NULL REFERENCES DimInstrument (InstrumentKey),
  DateKey       INT    NOT NULL REFERENCES DimDate (DateKey),
  Open          NUMERIC(18,6),
  High          NUMERIC(18,6),
  Low           NUMERIC(18,6),
  Close         NUMERIC(18,6) NOT NULL,
  Volume        BIGINT,
  UNIQUE (InstrumentKey, DateKey)
);

CREATE TABLE FactTrades (
  TradeKey      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  InstrumentKey INT NOT NULL REFERENCES DimInstrument (InstrumentKey),
  StrategyKey   INT NOT NULL REFERENCES DimStrategy (StrategyKey),
  TraderKey     INT NOT NULL REFERENCES DimTrader (TraderKey),
  EntryDateKey  INT NOT NULL REFERENCES DimDate (DateKey),
  ExitDateKey   INT NOT NULL REFERENCES DimDate (DateKey),
  Side          VARCHAR(4)    NOT NULL CHECK (Side IN ('BUY','SELL')),
  Quantity      NUMERIC(18,4) NOT NULL CHECK (Quantity > 0),
  EntryPrice    NUMERIC(18,6) NOT NULL CHECK (EntryPrice > 0),
  ExitPrice     NUMERIC(18,6) NOT NULL CHECK (ExitPrice > 0),
  -- Computed by the database so it can never disagree with the prices.
  ProfitLoss    NUMERIC(22,6) GENERATED ALWAYS AS (
                  Quantity * (ExitPrice - EntryPrice)
                  * CASE WHEN Side = 'BUY' THEN 1 ELSE -1 END
                ) STORED,
  CHECK (ExitDateKey >= EntryDateKey)
);

CREATE TABLE FactPositions (
  PositionKey   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  InstrumentKey INT NOT NULL REFERENCES DimInstrument (InstrumentKey),
  DateKey       INT NOT NULL REFERENCES DimDate (DateKey),
  StrategyKey   INT NOT NULL REFERENCES DimStrategy (StrategyKey),
  TraderKey     INT NOT NULL REFERENCES DimTrader (TraderKey),
  Quantity      NUMERIC(18,4) NOT NULL,
  MarketValue   NUMERIC(22,6) NOT NULL,
  UNIQUE (StrategyKey, TraderKey, InstrumentKey, DateKey)
);

CREATE TABLE FactBacktestResults (
  BacktestKey   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  StrategyKey   INT NOT NULL REFERENCES DimStrategy (StrategyKey),
  StartDateKey  INT NOT NULL REFERENCES DimDate (DateKey),
  EndDateKey    INT NOT NULL REFERENCES DimDate (DateKey),
  NumTrades     INT           NOT NULL,
  WinRate       NUMERIC(7,4),            -- fraction 0-1
  TotalPnL      NUMERIC(22,6),
  TotalReturn   NUMERIC(12,6),           -- fraction, For example: 0.12 = +12%
  MaxDrawdown   NUMERIC(12,6),           -- fraction, reported as a negative number
  Sharpe        NUMERIC(12,6)
);