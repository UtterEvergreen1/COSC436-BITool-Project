# Schema contract v2

Status: **proposed by Daniel C., Sun Nov 1.** Tested against the real S&P 500 data in PostgreSQL.
Changes after this go through a pull request and are announced to the team.
Source of truth: `sql/01_schema.sql` (DDL), `sql/03_load_dw.sql` (loading).

## Run order

```
docker compose exec warehouse psql -U dw_admin -d trading_dw -v ON_ERROR_STOP=1 -f /sql/01_schema.sql
python etl/load_staging.py data/all_stocks_5yr.csv             # staging.stg_market_ohlcv
python etl/make_sample_backtest.py                             # data/backtest/*.csv (test data)
docker compose exec warehouse psql -U dw_admin -d trading_dw -v ON_ERROR_STOP=1 -f /sql/02_staging_backtest.sql
# load the three backtest CSVs into staging.stg_bt_* (COPY ... CSV HEADER)
docker compose exec warehouse psql -U dw_admin -d trading_dw -v ON_ERROR_STOP=1 -f /sql/03_load_dw.sql
```
`01` drops and recreates schema `dw`, so always run `01` before `03`. `02` recreates the empty
staging tables, so run it just before the COPY of the CSVs. Run all of the `docker compose exec`
commands from the repo root: the SQL folder is mounted at `/sql` inside the container.

Or run the whole pipeline at once: `python etl/run_etl.py` (it needs `data/backtest/*.csv`, which
`make_sample_backtest.py` writes).

## Tables and grain

| Table | Grain (one row per...) | Real or simulated |
|---|---|---|
| DimDate | calendar day in the data range (1,826 rows) | real |
| DimInstrument | ticker (505 rows) | real |
| DimStrategy | strategy | simulated |
| DimTrader | trader or trading system | simulated |
| FactMarketData | instrument per trading day (daily OHLCV bar, 619,040 rows) | real |
| FactTrades | completed round-trip trade (entry + matching exit) by one strategy in one instrument | simulated |
| FactPositions | strategy, trader, instrument and trading day with a non-flat end-of-day position; **derived from FactTrades** | simulated |
| FactBacktestResults | strategy per backtest run | simulated |

## Columns

**DimDate:** DateKey (yyyymmdd, PK), FullDate, Year, Quarter, Month, MonthName, Day, DayOfWeek (ISO 1=Mon), DayName, IsWeekend, IsTradingDay, TradingDayNum
**DimInstrument:** InstrumentKey (PK), Symbol (unique), AssetClass, FirstDate, LastDate, BarCount
**DimStrategy:** StrategyKey (PK), StrategyName (unique), StrategyType, StrategyDescription, Parameters
**DimTrader:** TraderKey (PK), TraderName (unique), TraderType ('System' or 'Human')
**FactMarketData:** MarketDataKey (PK), InstrumentKey, DateKey, Open, High, Low, Close, Volume; unique (InstrumentKey, DateKey)
**FactTrades:** TradeKey (PK), InstrumentKey, StrategyKey, TraderKey, EntryDateKey, ExitDateKey, Side ('BUY' = long, 'SELL' = short), Quantity, EntryPrice, ExitPrice, **ProfitLoss (computed by the database)**
**FactPositions:** PositionKey (PK), InstrumentKey, DateKey, StrategyKey, TraderKey, Quantity (signed), MarketValue; unique (StrategyKey, TraderKey, InstrumentKey, DateKey)
**FactBacktestResults:** BacktestKey (PK), StrategyKey, StartDateKey, EndDateKey, NumTrades, WinRate, TotalPnL, TotalReturn, MaxDrawdown, Sharpe

### What changed from Milestone 1

| Before | Now | Why |
|---|---|---|
| DimTime (down to seconds) | DimDate | data is daily |
| FactTrades.TimeKey, Price | EntryDateKey, ExitDateKey, EntryPrice, ExitPrice | a trade opens and closes on different days |
| ProfitLoss loaded as a value | ProfitLoss computed from Quantity, prices, Side | cannot disagree with the prices |
| FactPositions: monthly, random | daily, derived from FactTrades | positions always equal the trades |
| DimInstrument.InstrumentName, Exchange | removed | no source data; name only duplicated the ticker |
| FactMarketData.Volume NUMERIC | BIGINT | matches staging |
| random() trade generation | removed | trades come from the backtest |
| (none) | FactBacktestResults, DimStrategy.Parameters | strategy-level results for the report |

Orders are not modelled: each trade row stands for one entry order and one exit order.

## For Dan: backtest output (three CSVs, with a header row, dates as YYYY-MM-DD)

**strategies.csv**: `strategy_name, strategy_type, description, parameters, trader_name, trader_type`
One row per strategy. `trader_type` is `System` or `Human`. Strategy and trader names must be unique.

**trades.csv**: `strategy_name, symbol, side, entry_date, exit_date, quantity, entry_price, exit_price`
- `side` is `BUY` (long) or `SELL` (short). Not `LONG`/`SHORT`.
- Entry and exit both happen at that day's **Close**. `entry_price` and `exit_price` must equal the real Close for that symbol and date (validation will check this).
- `entry_date` and `exit_date` must be trading days, and `exit_date >= entry_date`.
- Every trade must be **closed** by the last bar. Force-close open trades on 2018-02-07. No open trades in the table.
- `quantity > 0`. Do **not** send profit/loss; the database computes it.
- Use a fixed seed and fixed parameters so a re-run gives the same file.
- Many tickers have short histories (the shortest has 44 bars). Skip tickers with fewer bars than your longest lookback (`DimInstrument.BarCount`, or count in the CSV) and say so in the report.
- Prefer at most one open trade per strategy per symbol at a time. If trades overlap, FactPositions nets them, which is correct but harder to explain.

**results.csv**: `strategy_name, start_date, end_date, num_trades, win_rate, total_pnl, total_return, max_drawdown, sharpe`
- `win_rate` is a fraction 0-1; `total_return` and `max_drawdown` are fractions (drawdown negative).
- Document the formulas (capital base, Sharpe annualisation, risk-free rate) in the backtest README. Do not leave them implicit.

## For John: validation checks to implement (store the results)

Already enforced by the database (the load fails, nothing is silently dropped): primary and foreign keys, `ExitDateKey >= EntryDateKey`, `Quantity/EntryPrice/ExitPrice > 0`, side in BUY/SELL, unique grain per fact table, FactTrades row count equals staged trades.

To check and record in `etl_run_log` / a validation-results table:
1. Row counts: staging market rows = FactMarketData rows (619,040).
2. Known data problems in the source file (1 row with high < low: AOS 2014-05-19; 11 null opens, 8 null highs, 8 null lows). Report counts, do not delete.
3. FactTrades EntryPrice/ExitPrice equal FactMarketData Close on the entry/exit date (expect 0 mismatches).
4. Entry and exit dates are trading days (`DimDate.IsTradingDay`).
5. FactPositions row count equals the distinct (strategy, instrument, trading day) held, recomputed from FactTrades.
6. No duplicate (ticker, date) in staging.
