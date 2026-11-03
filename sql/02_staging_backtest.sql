-- Recreate the backtest staging tables, empty.
-- Run BEFORE the three backtest CSVs are copied into staging.stg_bt_*
-- (see etl/run_etl.py or docs/schema_contract.md). Safe to re-run: the tables
-- are dropped and rebuilt, so stale rows can never be left over.

CREATE SCHEMA IF NOT EXISTS staging;

DROP TABLE IF EXISTS staging.stg_bt_strategies, staging.stg_bt_trades, staging.stg_bt_results;

CREATE TABLE staging.stg_bt_strategies (
  strategy_name VARCHAR(128) PRIMARY KEY,
  strategy_type VARCHAR(64),
  description   VARCHAR(512),
  parameters    VARCHAR(256),
  trader_name   VARCHAR(128) NOT NULL,
  trader_type   VARCHAR(16)  NOT NULL
);

CREATE TABLE staging.stg_bt_trades (
  strategy_name VARCHAR(128) NOT NULL,
  symbol        VARCHAR(32)  NOT NULL,
  side          VARCHAR(4)   NOT NULL,
  entry_date    DATE         NOT NULL,
  exit_date     DATE         NOT NULL,
  quantity      NUMERIC(18,4) NOT NULL,
  entry_price   NUMERIC(18,6) NOT NULL,
  exit_price    NUMERIC(18,6) NOT NULL
);

CREATE TABLE staging.stg_bt_results (
  strategy_name VARCHAR(128) PRIMARY KEY,
  start_date    DATE NOT NULL,
  end_date      DATE NOT NULL,
  num_trades    INT  NOT NULL,
  win_rate      NUMERIC(7,4),
  total_pnl     NUMERIC(22,6),
  total_return  NUMERIC(12,6),
  max_drawdown  NUMERIC(12,6),
  sharpe        NUMERIC(12,6)
);
