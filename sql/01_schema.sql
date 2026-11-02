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


